//
//  RoomArtPreviewControllerTests.swift
//  leanring-buddyTests
//
//  The whole "show me how this would look in my room" flow with a stand-in frame processor, synthetic camera frames, a
//  stub Worker, a recorded voice, and a panel that only records being shown, so it needs no camera, window, network,
//  Vision, or Metal. CI's hosted tests run in a background login session where Vision's person segmentation and Metal
//  drawing never produce a frame, so the real processor is covered by the gated RoomArtFrameProcessorBenchTests instead.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import SceneKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Clicky

@MainActor
private final class RecordingPanel: RoomArtPanelPresenting {
    var timesShown = 0
    var timesHidden = 0
    func show() { timesShown += 1 }
    func hide() { timesHidden += 1 }
}

/// Stands in for `RoomArtFrameProcessor`: the first frame of a session counts as segmented, a keyframe is a fixed stand-in
/// at the anchor asked for, and placing or putting back the item and the shirt calls are recorded.
nonisolated private final class StandInFrameProcessor: RoomArtFrameProcessing, @unchecked Sendable {
    let processingQueue = DispatchQueue(label: "com.crodris.clicky.tests.room-art-frames")
    let metalLayer = CAMetalLayer()
    /// Where a keyframe with no anchor centers the item, as the bare wall or floor spot would.
    static let bareSpot = CGPoint(x: 200, y: 150)
    static let bareWallSpot = CGPoint(x: 220, y: 90)
    /// A gray 640 by 360 keyframe, the size the stub Worker's planes are measured for, so a render or a painting can read it.
    static let keyframeJPEG: Data = {
        let context = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(gray: 0.6, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let jpegData = NSMutableData()
        guard let image = context?.makeImage(), let destination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return jpegData as Data
    }()

    private let lock = NSLock()
    private var keyframeJPEGThatCannotBeDecoded = false
    /// Hands out keyframes whose JPEG bytes do not decode, as a keyframe the encoder broke would.
    func handOutKeyframesThatCannotBeDecoded() { lock.withLock { keyframeJPEGThatCannotBeDecoded = true } }
    private var onFirstSegmentedFrame: (@Sendable () -> Void)?
    private var onTheSurfaceLostOrFound: (@Sendable (Bool) -> Void)?
    private var onTheShirtFramingSettled: (@Sendable (ShirtFramingKind) -> Void)?
    private var recordedSurfacesShownOn: [RoomArtSurfaceKind] = []
    private var recordedItemPutBackCount = 0
    private var recordedKeyframeAnchors: [CGPoint?] = []
    private var recordedKeyframeSurfaces: [RoomArtSurfaceKind] = []
    private var recordedShirtTryOnStarted = false
    private var recordedGarmentWorn = false
    private var latestLoop: RoomArtLoopSnapshot?
    private var recordedFurnitureLayersShown: [(look: RoomFurnitureLook, keyframeNumber: Int)] = []
    private var recordedLoopOutlines: [(point: CGPoint, keyframeNumber: Int)] = []
    private var keyframesTaken = 0
    /// Whether a freeze finds a shirt drawn, and what the freezes, stills, and resumes were.
    private var aShirtIsDrawn = true
    private var recordedFreezes = 0
    private var recordedPaintedStillsShown = 0
    private var recordedResumes = 0
    private var frameIsFrozen = false
    private var recordedPaintedAreaOutlines = 0
    var paintedAreaOutlines: Int { lock.withLock { recordedPaintedAreaOutlines } }

    var freezes: Int { lock.withLock { recordedFreezes } }
    var paintedStillsShown: Int { lock.withLock { recordedPaintedStillsShown } }
    var resumes: Int { lock.withLock { recordedResumes } }
    var isFrozen: Bool { lock.withLock { frameIsFrozen } }
    func setAShirtIsDrawn(_ isDrawn: Bool) { lock.withLock { aShirtIsDrawn = isDrawn } }

    /// Each furniture look the controller handed over, with the keyframe it was made for.
    var furnitureLayersShown: [(look: RoomFurnitureLook, keyframeNumber: Int)] { lock.withLock { recordedFurnitureLayersShown } }
    var loopOutlines: [(point: CGPoint, keyframeNumber: Int)] { lock.withLock { recordedLoopOutlines } }

    var artHungCount: Int { lock.withLock { recordedSurfacesShownOn.count } }
    var surfacesShownOn: [RoomArtSurfaceKind] { lock.withLock { recordedSurfacesShownOn } }
    var artPutBackCount: Int { lock.withLock { recordedItemPutBackCount } }
    var keyframeAnchors: [CGPoint?] { lock.withLock { recordedKeyframeAnchors } }
    var keyframeSurfaces: [RoomArtSurfaceKind] { lock.withLock { recordedKeyframeSurfaces } }
    var shirtTryOnStarted: Bool { lock.withLock { recordedShirtTryOnStarted } }
    var garmentWorn: Bool { lock.withLock { recordedGarmentWorn } }

    func startASession(onFirstSegmentedFrame: @escaping @Sendable () -> Void, onTheSurfaceLostOrFound: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            self.onFirstSegmentedFrame = onFirstSegmentedFrame
            self.onTheSurfaceLostOrFound = onTheSurfaceLostOrFound
            onTheShirtFramingSettled = nil
            recordedShirtTryOnStarted = false
            recordedGarmentWorn = false
        }
    }

    func endTheSession() {
        lock.withLock {
            onFirstSegmentedFrame = nil
            onTheSurfaceLostOrFound = nil
            onTheShirtFramingSettled = nil
        }
    }

    func process(_ cameraFrame: CVPixelBuffer) {
        let firstFrameCallback: (@Sendable () -> Void)? = lock.withLock {
            defer { onFirstSegmentedFrame = nil }
            return onFirstSegmentedFrame
        }
        if let firstFrameCallback { DispatchQueue.main.async { firstFrameCallback() } }
    }

    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe? {
        let (keyframeNumber, keyframeJPEGData) = lock.withLock {
            recordedKeyframeAnchors.append(anchorInCameraPixels)
            recordedKeyframeSurfaces.append(surfaceKind)
            keyframesTaken += 1
            return (keyframesTaken, keyframeJPEGThatCannotBeDecoded ? Data([1, 2, 3]) : Self.keyframeJPEG)
        }
        return RoomArtKeyframe(
            measurementRequest: RoomWallRequest(keyframeJPEGData: keyframeJPEGData, personMaskPNGData: Data([2]), anchor: anchorInCameraPixels ?? Self.bareSpot),
            wallLight: .neutral,
            wallSpotAnchor: Self.bareWallSpot,
            keyframeNumber: keyframeNumber
        )
    }

    func showTheWallArt(_ flattenedArtImage: CGImage, keyframeCorners: RoomArtCorners) {
        lock.withLock { recordedSurfacesShownOn.append(.wall) }
    }

    func showTheFurnitureLayers(_ layers: RoomFurnitureKeyframeLayers, keyframeNumber: Int) {
        lock.withLock { recordedFurnitureLayersShown.append((layers.look, keyframeNumber)) }
    }

    func outlineTheLoop(around point: CGPoint, on surfaceKind: RoomArtSurfaceKind, inKeyframeNumber keyframeNumber: Int) {
        lock.withLock { recordedLoopOutlines.append((point, keyframeNumber)) }
    }

    func putBackTheItemFromBeforeTheMove() {
        lock.withLock { recordedItemPutBackCount += 1 }
    }

    func startTheShirtTryOn(onTheFramingSettled: @escaping @Sendable (ShirtFramingKind) -> Void) {
        lock.withLock {
            recordedShirtTryOnStarted = true
            onTheShirtFramingSettled = onTheFramingSettled
        }
    }

    func wearTheGarment(_ garment: ShirtGarment) {
        lock.withLock { recordedGarmentWorn = true }
    }

    func freezeTheShirtFrame() async -> ShirtFrozenFrame? {
        lock.withLock {
            recordedFreezes += 1
            guard aShirtIsDrawn else { return nil }
            frameIsFrozen = true
            return standInFrozenFrame()
        }
    }

    func showThePaintedStill(_ paintedImage: CGImage) {
        lock.withLock { recordedPaintedStillsShown += 1 }
    }

    func resumeTheLiveShirt() {
        lock.withLock {
            recordedResumes += 1
            frameIsFrozen = false
        }
    }

    func outlineTheAreaBeingPainted(_ outline: [CGPoint]) {
        lock.withLock { recordedPaintedAreaOutlines += 1 }
    }

    func currentLoop() -> RoomArtLoopSnapshot? {
        lock.withLock { latestLoop }
    }

    func setTheLoop(_ loop: RoomArtLoopSnapshot?) {
        lock.withLock { latestLoop = loop }
    }

    /// The tracker lost the room (true) or found it again (false), reported on the main actor as the real processor does.
    func reportTheSurface(lost surfaceIsLost: Bool) {
        guard let onTheSurfaceLostOrFound = lock.withLock({ onTheSurfaceLostOrFound }) else { return }
        DispatchQueue.main.async { onTheSurfaceLostOrFound(surfaceIsLost) }
    }

    /// The debounced framing settled, reported on the main actor as the real processor does.
    func settleTheShirtFraming(on settledKind: ShirtFramingKind) {
        guard let onTheShirtFramingSettled = lock.withLock({ onTheShirtFramingSettled }) else { return }
        DispatchQueue.main.async { onTheShirtFramingSettled(settledKind) }
    }
}

/// A small gray frozen frame with a torso in its middle, which is all the controller passes on.
nonisolated private func standInFrozenFrame() -> ShirtFrozenFrame {
    let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
    let image = context.makeImage()!
    return ShirtFrozenFrame(
        cameraImage: image, previewImage: image,
        personMask: [UInt8](repeating: 255, count: 64 * 36), previewGarmentCoverage: [UInt8](repeating: 0, count: 64 * 36),
        torso: BodyTorso(
            imageLeftShoulder: CGPoint(x: 22, y: 8), imageRightShoulder: CGPoint(x: 42, y: 8), imageLeftHip: CGPoint(x: 24, y: 30), imageRightHip: CGPoint(x: 40, y: 30),
            hipsWereEstimated: false, shouldersAreSeen: true
        )
    )
}

/// The shirt painting's two steps, answered from the test: the masks, and the Worker's painting.
@MainActor
private final class ShirtPaintingStub {
    var masksAreMade = true
    var paintingResult: Result<Void, Error> = .success(())
    var secondsBeforeThePaintingReturns = 0.0
    private(set) var requests: [ShirtPaintingRequest] = []

    func apply(to environment: inout RoomArtPreviewController.Environment) {
        environment.makeTheShirtPaintMasks = { frozenFrame in
            guard self.masksAreMade else { return nil }
            return ShirtPaintMasks(
                width: frozenFrame.width, height: frozenFrame.height,
                paintable: [UInt8](repeating: 255, count: frozenFrame.width * frozenFrame.height),
                protected: [UInt8](repeating: 0, count: frozenFrame.width * frozenFrame.height),
                oldShirt: [UInt8](repeating: 0, count: frozenFrame.width * frozenFrame.height)
            )
        }
        environment.paintTheShirt = { paintingRequest in
            self.requests.append(paintingRequest)
            if self.secondsBeforeThePaintingReturns > 0 { try await Task.sleep(for: .seconds(self.secondsBeforeThePaintingReturns)) }
            try self.paintingResult.get()
            return paintingRequest.keyframe
        }
    }
}

/// A camera that delivers one small frame 30 times a second, or fails to start. Its start can take a while, the way the
/// real one waits on macOS's camera prompt.
nonisolated private final class SyntheticRoomCamera: RoomFrameSource, @unchecked Sendable {
    private let startFailure: RoomCameraError?
    private let secondsToStart: Double
    private let lock = NSLock()
    private var frameTimer: DispatchSourceTimer?

    init(startFailure: RoomCameraError? = nil, secondsToStart: Double = 0) {
        self.startFailure = startFailure
        self.secondsToStart = secondsToStart
    }

    /// Whether frames are being delivered: started and not stopped since.
    var isDeliveringFrames: Bool {
        lock.withLock { frameTimer.map { !$0.isCancelled } ?? false }
    }

    func start(deliveringFramesOn deliveryQueue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws {
        if secondsToStart > 0 { try? await Task.sleep(for: .seconds(secondsToStart)) }
        if let startFailure { throw startFailure }
        var pixelBufferReference: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, roomCameraPixelFormat, nil, &pixelBufferReference)
        guard let roomFrame = pixelBufferReference else { throw RoomCameraError.noCamera }
        let frameTimer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        frameTimer.schedule(deadline: .now(), repeating: 1.0 / 30)
        frameTimer.setEventHandler { onFrame(roomFrame) }
        lock.withLock { self.frameTimer = frameTimer }
        frameTimer.resume()
    }

    func stop() {
        lock.withLock { frameTimer?.cancel() }
    }
}

private let pictureCorners = RoomArtCorners(topLeft: CGPoint(x: 20, y: 25), topRight: CGPoint(x: 380, y: 25), bottomRight: CGPoint(x: 380, y: 475), bottomLeft: CGPoint(x: 20, y: 475))

private let sideTableReading = RoomArtPageReading.furniture(RoomArtFurnitureReading(
    title: "LACK side table",
    chosenSize: RoomArtFurnitureSize(label: "55x45 cm", widthCentimeters: 55, heightCentimeters: 45, depthCentimeters: 55),
    whyThisSize: "It is the only size.",
    itemCorners: pictureCorners
))

private func shirtReading(photoShows: RoomArtGarmentPhoto = .flatLay) -> RoomArtPageReading {
    .clothing(RoomArtClothingReading(
        title: "Linen shirt", garment: .shirt, sleeves: .short, chosenSizeLabel: "M", photoShows: photoShows,
        printDescription: "", whyThisSize: "M is selected.", itemCorners: pictureCorners
    ))
}

/// A plain image the size of a cut-out piece of furniture, wider than it is tall.
private func furnitureCutoutImage() -> CGImage {
    let context = CGContext(data: nil, width: 60, height: 45, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 60, height: 45))
    return context.makeImage()!
}

/// A garment from a plain photo whose whole middle is the cutout, which is all the controller needs to pass on.
private func testGarment() -> ShirtGarment? {
    let context = CGContext(data: nil, width: 100, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 120))
    var maskPixels = [UInt8](repeating: 0, count: 100 * 120)
    for row in 10..<110 { for column in 15..<85 { maskPixels[row * 100 + column] = 255 } }
    return ShirtGarment.make(workingPhoto: context.makeImage()!, cutoutMask: ShirtCutoutMask(width: 100, height: 120, pixels: maskPixels))
}

/// The Worker's three routes, answered from the test, with what each received.
@MainActor
private final class WorkerStub {
    var pageReading: Result<RoomArtPageReading, Error> = .success(.wallArt(RoomArtWallArtReading(
        title: "Water Lilies print",
        chosenSize: RoomArtSize(label: "16x20 in", widthCentimeters: 40.6, heightCentimeters: 50.8),
        chosenSizeIncludesFrame: false,
        whyThisSize: "It is the size selected on the page.",
        otherSizes: [],
        artworkCorners: pictureCorners
    )))
    var wallReply: Result<WallPlane, Error> = .success(WallPlane(
        center: SIMD3(-0.3, -0.2, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 500,
        principalPoint: SIMD2(320, 180), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
    ))
    // The floor point 4 m out, inside the 640 by 360 frame, so a side table has a spot where all of it shows.
    var floorReply: Result<FloorPlane, Error> = .success(FloorPlane(
        center: SIMD3(0.4, 0.9, 4.0), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1), focalLengthPixels: 500,
        principalPoint: SIMD2(320, 180), distanceMeters: 2.4, floorTiltDegrees: 2, planeInlierShare: 0.9
    ))
    var secondsBeforeThePageReplies = 0.0
    /// Replies for the next page reads, in order, each after its own wait, which a cancel does not cut short, the way a
    /// reply already on its way still arrives. The default reply answers at once when the list is empty.
    var queuedPageReplies: [(seconds: Double, reply: Result<RoomArtPageReading, Error>)] = []
    var secondsBeforeTheWallReplies = 0.0
    /// A page read's wait ended early because its task was cancelled, which a close does.
    private(set) var aPageReadWasCancelled = false
    private(set) var pageRequests: [RoomArtPageRequest] = []
    private(set) var wallRequests: [RoomWallRequest] = []
    private(set) var floorRequests: [RoomWallRequest] = []
    /// The center the floor reply measures, which a clicked spot keeps.
    var floorRequestsReply: SIMD3<Double> { (try? floorReply.get())?.center ?? .zero }

    func readThePage(_ pageRequest: RoomArtPageRequest) async throws -> RoomArtPageReading {
        pageRequests.append(pageRequest)
        if !queuedPageReplies.isEmpty {
            let queuedReply = queuedPageReplies.removeFirst()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + queuedReply.seconds) { continuation.resume() }
            }
            return try queuedReply.reply.get()
        }
        if secondsBeforeThePageReplies > 0 {
            do {
                try await Task.sleep(for: .seconds(secondsBeforeThePageReplies))
            } catch {
                aPageReadWasCancelled = true
                throw error
            }
        }
        return try pageReading.get()
    }

    func measureTheWall(_ wallRequest: RoomWallRequest) async throws -> WallPlane {
        wallRequests.append(wallRequest)
        if secondsBeforeTheWallReplies > 0 {
            try await Task.sleep(for: .seconds(secondsBeforeTheWallReplies))
        }
        return try wallReply.get()
    }

    func measureTheFloor(_ floorRequest: RoomWallRequest) async throws -> FloorPlane {
        floorRequests.append(floorRequest)
        return try floorReply.get()
    }
}

/// What the stand-ins for Vision's two cutouts give back, and how often they were asked.
@MainActor
private final class CutoutStub {
    var furnitureCutout: CGImage? = furnitureCutoutImage()
    var garment: ShirtGarment? = testGarment()
    var secondsBeforeTheGarmentIsReady = 0.0
    private(set) var furnitureCutoutsAsked = 0
    private(set) var garmentsAsked = 0

    func cutOutTheFurniture() -> CGImage? {
        furnitureCutoutsAsked += 1
        return furnitureCutout
    }

    func makeTheGarment() async -> ShirtGarment? {
        garmentsAsked += 1
        if secondsBeforeTheGarmentIsReady > 0 { try? await Task.sleep(for: .seconds(secondsBeforeTheGarmentIsReady)) }
        return garment
    }
}

/// Holds whoever waits on it until the test opens it, such as a painting on its way or the wait for furniture's look.
@MainActor
private final class TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var timesWaitedOn = 0
    /// How many waiters went on past the gate. The waiter's own code after `wait()` runs on the main actor with no
    /// suspension before it, so a test that sees this count rise knows that code has run.
    private(set) var timesPassed = 0

    func wait() async {
        timesWaitedOn += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        timesPassed += 1
    }

    func open() {
        isOpen = true
        let waitersToResume = waiters
        waiters = []
        for waiter in waitersToResume { waiter.resume() }
    }
}

/// The furniture's better looks, answered from the test: the store's model, the generation service, and the render.
@MainActor
private final class FurnitureLookStub: RoomFurnitureGenerating {
    /// Each painting waits here before it answers, while set, so a test can look at the panel while the painting comes.
    var paintingGate: TestGate?
    /// The store model search waits here before it answers, while set.
    var storeModelGate: TestGate?
    /// Each render waits here before it answers, while set.
    var renderGate: TestGate?
    var storeModel: RoomFurnitureLoadedModel?
    var generatedModelData: Data?
    var maskPNG: Data? = Data([7])
    var paintedImage: CGImage?
    /// The first painting whose layer is kept, counting from 1; the ones before it stand for paintings at the wrong
    /// height, and nil keeps none.
    var firstKeptPainting: Int? = 1
    /// How many paintings fail with a 502 before the stub answers.
    var failingPaintings = 0
    var renderSucceeds = true
    private(set) var storeModelSearches: [String] = []
    private(set) var modelsGenerated = 0
    private(set) var paintings = 0
    private(set) var renders: [RoomFurnitureLook] = []
    /// The product image each generation service was sent, which must be the furniture's cutout and never the page picture.
    private(set) var productJPEGsSent: [Data] = []
    /// What the model was asked to be cached by, which must be the page picture.
    private(set) var modelCacheKeysSent: [Data] = []

    func generateAModel(productJPEG: Data, itemTitle: String, cacheKeyData: Data) async throws -> Data {
        productJPEGsSent.append(productJPEG)
        modelCacheKeysSent.append(cacheKeyData)
        modelsGenerated += 1
        guard let generatedModelData else { throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: "") }
        return generatedModelData
    }

    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data, keyframeWidth: Int, keyframeHeight: Int, productJPEG: Data, maskPNG: Data, itemTitle: String, itemSizeWords: String
    ) async throws -> CGImage {
        productJPEGsSent.append(productJPEG)
        paintings += 1
        if let paintingGate { await paintingGate.wait() }
        guard let paintedImage else { throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: "") }
        if paintings <= failingPaintings { throw RoomFurnitureGenerationError.workerReturned(statusCode: 502, body: "") }
        return paintedImage
    }

    static func thatPaintsAtOnce() -> FurnitureLookStub {
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        return looks
    }

    static func layers(_ look: RoomFurnitureLook) -> RoomFurnitureKeyframeLayers {
        RoomFurnitureKeyframeLayers(itemLayer: furnitureCutoutImage(), shadowLayer: nil, basePointInTheKeyframe: CGPoint(x: 320, y: 300), cameraNoiseStandardDeviation: 0, look: look)
    }

    static func model(_ look: RoomFurnitureLook) -> RoomFurnitureLoadedModel {
        RoomFurnitureLoadedModel(rootNode: SCNNode(), look: look, originForTheLog: "a test")
    }

    func apply(to environment: inout RoomArtPreviewController.Environment) {
        environment.findTheStoreModel = { pageURL in
            self.storeModelSearches.append(pageURL)
            if let storeModelGate = self.storeModelGate { await storeModelGate.wait() }
            return self.storeModel
        }
        environment.furnitureGeneration = self
        environment.loadAGeneratedModel = { _ in Self.model(.generatedModel) }
        environment.compositeMaskPNG = { _, _, _, _ in self.maskPNG }
        environment.renderTheFurniture = { renderRequest in
            self.renders.append(renderRequest.look)
            if let renderGate = self.renderGate { await renderGate.wait() }
            return self.renderSucceeds ? Self.layers(renderRequest.look) : nil
        }
        environment.paintedItemLayers = { _, _, _, _ in
            guard let firstKeptPainting = self.firstKeptPainting, self.paintings >= firstKeptPainting else { return nil }
            return Self.layers(.paintedComposite)
        }
    }
}

private struct TimedOutWaiting: Error {}

/// Polls `condition` every 20 ms for up to `seconds`, and says whether it held.
@MainActor
private func conditionHolds(withinSeconds seconds: Double, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

/// Waits up to `seconds` for `condition`, and on a timeout records an issue that names what never happened and stops the test.
@MainActor
// A wait ends as soon as its condition holds, so a long limit only costs time on a failure. The CI runner shares a Mac
// whose load average reached 144 from parallel builds, where these tests took over 30 s and timed out at 5 s.
private func waitFor(_ whatShouldHappen: String, seconds: Double = 120, _ condition: () -> Bool) async throws {
    guard await conditionHolds(withinSeconds: seconds, condition) else {
        Issue.record("Timed out after \(seconds) s waiting for: \(whatShouldHappen)")
        throw TimedOutWaiting()
    }
}

private func pictureJPEG() -> RoomArtPicture {
    let context = CGContext(data: nil, width: 400, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
    let jpegData = NSMutableData()
    let destination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return RoomArtPicture(jpegData: jpegData as Data, width: 400, height: 500)
}

/// What the learner said, which reaches the Worker so it knows which item on the page they mean.
private let whatTheLearnerSaid = "how would this look in my room"

private let storePageTab = RoomArtFrontTab(url: "https://shop.example/water-lilies", title: "Water Lilies print", text: "Sizes: 8x10 in, 16x20 in")

@MainActor
private final class HarnessRecorder {
    var spokenLines: [String] = []
    /// For each spoken line, whether the controller said it reports a failure, so the cursor shakes.
    var spokenLineFailureFlags: [Bool] = []
    var pictureCaptureStarted = false
    /// How many times the controller asked to end its spoken line, which every close does.
    var timesTheSpokenLineWasEnded = 0
    /// How many times the panel had shown each time the live scene was cleared.
    var timesTheSceneWasClearedBeforeThePanel: [Int] = []
    /// How many times the learner asked the open panel for a painting or a return to the preview.
    var timesTheLearnerAskedThePanel = 0
}

@MainActor
private struct RoomArtHarness {
    let controller: RoomArtPreviewController
    let panel: RecordingPanel
    let worker: WorkerStub
    let cutouts: CutoutStub
    let camera: SyntheticRoomCamera
    let frameProcessor: StandInFrameProcessor
    let recorder: HarnessRecorder

    /// The stub Worker is made here, not as a default argument, since a default argument is not on the main actor.
    init(
        picture: RoomArtPicture? = pictureJPEG(),
        camera: SyntheticRoomCamera = SyntheticRoomCamera(),
        worker givenWorker: WorkerStub? = nil,
        cutouts givenCutouts: CutoutStub? = nil,
        frontTab: RoomArtFrontTab? = storePageTab,
        appSecretIsSet: Bool = true,
        secondsToCaptureThePicture: Double = 0,
        furnitureLooks: FurnitureLookStub? = nil,
        furnitureLookDeadline: TestGate? = nil,
        shirtPainting: ShirtPaintingStub? = nil
    ) {
        let worker = givenWorker ?? WorkerStub()
        let cutouts = givenCutouts ?? CutoutStub()
        let panel = RecordingPanel()
        let recorder = HarnessRecorder()
        let frameProcessor = StandInFrameProcessor()
        var environment = RoomArtPreviewController.Environment(
                appSecretIsSet: { appSecretIsSet },
                readTheFrontTab: { frontTab },
                capturePicture: {
                    recorder.pictureCaptureStarted = true
                    if secondsToCaptureThePicture > 0 { try? await Task.sleep(for: .seconds(secondsToCaptureThePicture)) }
                    return picture
                },
                readThePage: { pageRequest in try await worker.readThePage(pageRequest) },
                measureTheWall: { wallRequest in try await worker.measureTheWall(wallRequest) },
                measureTheFloor: { floorRequest in try await worker.measureTheFloor(floorRequest) },
                cutOutTheFurniture: { _, _ in cutouts.cutOutTheFurniture() },
                makeTheShirtGarment: { _, _ in await cutouts.makeTheGarment() },
                makeFrameSource: { camera },
                clearTheLiveScene: { recorder.timesTheSceneWasClearedBeforeThePanel.append(panel.timesShown) },
                speak: { line, isAFailure in
                    recorder.spokenLines.append(line)
                    recorder.spokenLineFailureFlags.append(isAFailure)
                },
                loopAccentColor: { .orange },
                endTheSpokenLine: { recorder.timesTheSpokenLineWasEnded += 1 }
            )
        // Furniture needs its painting to show, so a test that names no looks gets a service that paints at once.
        (furnitureLooks ?? FurnitureLookStub.thatPaintsAtOnce()).apply(to: &environment)
        if let furnitureLookDeadline { environment.waitTheLongestForAFurnitureLook = { await furnitureLookDeadline.wait() } }
        shirtPainting?.apply(to: &environment)
        environment.theLearnerAskedThePanel = { recorder.timesTheLearnerAskedThePanel += 1 }
        controller = RoomArtPreviewController(environment: environment, frameProcessor: frameProcessor, panelPresenter: panel)
        self.panel = panel
        self.worker = worker
        self.cutouts = cutouts
        self.camera = camera
        self.frameProcessor = frameProcessor
        self.recorder = recorder
    }

    func spokenLines() -> [String] { recorder.spokenLines }

    func artIsShowing() -> Bool {
        if case .showing = controller.phase { return true }
        return false
    }

    func statusLine() -> String {
        controller.phase.statusLine(theSurfaceIsLost: controller.theSurfaceIsLost, shirtCoachingLine: controller.shirtCoachingLine)
    }
}

// The longest wait inside a test is 120 s, so a regression that stalls every flow fails here, minutes before CI's 30 minute job limit.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct RoomArtPreviewControllerTests {
    @Test func theArtShowsOnceThePageIsReadAndTheWallMeasured() async throws {
        let harness = RoomArtHarness()

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        #expect(harness.panel.timesShown == 1)
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }

        #expect(harness.spokenLines() == ["Here it is at 16 by 20 inches."])
        #expect(harness.controller.phase.statusLine == "On your wall at 16 by 20 inches")
        #expect(harness.frameProcessor.surfacesShownOn == [.wall])
        // A scene or pop-out on screen is cleared once, before the panel shows over it.
        #expect(harness.recorder.timesTheSceneWasClearedBeforeThePanel == [0])
        let pageRequest = try #require(harness.worker.pageRequests.first)
        #expect(pageRequest.pageURL == "https://shop.example/water-lilies")
        // The learner's words go to the Worker, so it knows which item on the page they mean.
        #expect(pageRequest.learnerRequest == whatTheLearnerSaid)
        // The first keyframe has no anchor, so the art centers on the bare wall spot, and only the wall is measured.
        #expect(harness.frameProcessor.keyframeAnchors == [nil])
        #expect(harness.frameProcessor.keyframeSurfaces == [.wall])
        #expect(harness.worker.wallRequests.first?.anchor == StandInFrameProcessor.bareSpot)
        #expect(harness.worker.floorRequests.isEmpty)

        harness.controller.close()
        #expect(harness.controller.phase == .closed)
        #expect(harness.panel.timesHidden == 1)
        #expect(!harness.camera.isDeliveringFrames)
    }

    @Test func thePageIsReadWhileTheCameraStartsAndTheVideoStaysCoveredUntilItsFirstFrame() async throws {
        // The camera takes 2 seconds to start, so the item waits for it long enough to be seen even on a loaded machine.
        let camera = SyntheticRoomCamera(secondsToStart: 2)
        let harness = RoomArtHarness(camera: camera)

        let openingTask = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the page request") { !harness.worker.pageRequests.isEmpty }
        // The page is asked about before the camera has delivered anything, so nothing waits on a keyframe to read it.
        #expect(!camera.isDeliveringFrames)
        #expect(!harness.controller.theFirstFrameIsIn)
        try await waitFor("the item to wait for the camera") {
            if case .waitingForTheCamera = harness.controller.phase { return true }
            return false
        }
        #expect(harness.statusLine() == "Starting the camera…")
        await openingTask.value
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }
        #expect(harness.controller.theFirstFrameIsIn)
        harness.controller.close()
        #expect(!harness.controller.theFirstFrameIsIn)
    }

    @Test func aClickMovesTheArtWithANewWallMeasurementAndIsIgnoredWhileOneRuns() async throws {
        let harness = RoomArtHarness()
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }
        harness.worker.secondsBeforeTheWallReplies = 0.3

        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 150, y: 120))
        // A second click during that measurement is ignored.
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 500, y: 300))
        try await waitFor("the click's wall request") { harness.worker.wallRequests.count == 2 }
        try await waitFor("the art to show at the click") { harness.artIsShowing() }

        #expect(harness.worker.wallRequests.count == 2)
        #expect(harness.worker.wallRequests.last?.anchor == CGPoint(x: 150, y: 120))
        #expect(harness.frameProcessor.artHungCount == 2)
        // The page was read once, and "Here it is" is said once.
        #expect(harness.worker.pageRequests.count == 1)
        #expect(harness.spokenLines() == ["Here it is at 16 by 20 inches."])
        harness.controller.close()
    }

    @Test func aFailedMoveKeepsTheArtWhereItWasAndTheCameraRunningAndSpeaksNothing() async throws {
        let harness = RoomArtHarness()
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }
        let firstWall = try harness.worker.wallReply.get()
        harness.worker.wallReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 422, body: #"{"error":"Too little bare wall around that point"}"#))

        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 150, y: 120))

        try await waitFor("the move to fail back onto the first wall") {
            guard case .showing(_, .wall(let wall), moveFailure: .wallNotMeasured) = harness.controller.phase else { return false }
            return wall == firstWall
        }
        #expect(harness.controller.phase.statusLine == "Couldn't measure the wall")
        #expect(harness.spokenLines() == ["Here it is at 16 by 20 inches."])
        #expect(harness.camera.isDeliveringFrames)
        // The art the click took down goes back, and nothing new is hung.
        #expect(harness.frameProcessor.artPutBackCount == 1)
        #expect(harness.frameProcessor.artHungCount == 1)
        harness.controller.close()
    }

    @Test func aLostWallSaysSoInTheStatusLineUntilItIsFound() async throws {
        let harness = RoomArtHarness()
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }

        harness.frameProcessor.reportTheSurface(lost: true)
        try await waitFor("the controller to hear the wall is lost") { harness.controller.theSurfaceIsLost }
        #expect(harness.statusLine() == "Lost the wall. Turn back, or click the wall to place it again.")

        harness.frameProcessor.reportTheSurface(lost: false)
        try await waitFor("the controller to hear the wall is found") { !harness.controller.theSurfaceIsLost }
        #expect(harness.statusLine() == "On your wall at 16 by 20 inches")
        harness.controller.close()
    }

    @Test func aWallReplyAfterThePanelClosedIsDropped() async throws {
        let worker = WorkerStub()
        worker.secondsBeforeTheWallReplies = 0.4
        let harness = RoomArtHarness(worker: worker)
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the wall request") { !worker.wallRequests.isEmpty }

        harness.controller.close()
        try await Task.sleep(for: .seconds(0.8))

        #expect(harness.controller.phase == .closed)
        #expect(harness.spokenLines().isEmpty)
        #expect(harness.frameProcessor.artHungCount == 0)
    }

    @Test func aPageReplyAfterThePanelClosedIsDroppedAndMeasuresNothing() async throws {
        let worker = WorkerStub()
        // The reply would come long after the close, so a loaded machine cannot let it land before the close does.
        worker.secondsBeforeThePageReplies = 60
        let harness = RoomArtHarness(worker: worker)
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the page request") { !worker.pageRequests.isEmpty }

        harness.controller.close()
        try await waitFor("the close to cancel the page read") { worker.aPageReadWasCancelled }

        #expect(harness.controller.phase == .closed)
        #expect(harness.spokenLines().isEmpty)
        #expect(worker.wallRequests.isEmpty && worker.floorRequests.isEmpty)
        // The close stops the request itself, not only what its reply would do.
        #expect(worker.aPageReadWasCancelled)
    }

    @Test func anEarlierRequestsFailedPageReadNeverFailsTheNewerOne() async throws {
        let worker = WorkerStub()
        let firstPageReading = try worker.pageReading.get()
        // The first read fails late, after the learner asked again, and the second read succeeds.
        worker.queuedPageReplies = [
            (seconds: 0.4, reply: .failure(URLError(.timedOut))),
            (seconds: 0.8, reply: .success(firstPageReading)),
        ]
        let harness = RoomArtHarness(worker: worker)
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the first page request") { worker.pageRequests.count == 1 }

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the art from the second request to show") { harness.artIsShowing() }

        #expect(worker.pageRequests.count == 2)
        #expect(harness.spokenLines() == ["Here it is at 16 by 20 inches."])
        harness.controller.close()
    }

    @Test func noAppSecretSaysSoBeforeTheCameraOpens() async {
        let harness = RoomArtHarness(appSecretIsSet: false)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        #expect(harness.spokenLines() == ["Clicky needs its app secret for this. See the README's Worker setup."])
        #expect(harness.panel.timesShown == 0)
        #expect(!harness.recorder.pictureCaptureStarted)
    }

    @Test func aPageThatIsNotHTTPSSaysSoBeforeTheCameraOpens() async {
        let harness = RoomArtHarness(frontTab: RoomArtFrontTab(url: "http://shop.example/water-lilies", title: "Water Lilies print", text: "16x20 in"))

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        #expect(harness.spokenLines() == ["I can only read store pages served over https."])
        #expect(harness.panel.timesShown == 0)
    }

    @Test(arguments: [String?.none, "", "  \n "])
    func pageTextThatCouldNotBeReadSaysSoBeforeAnyWorkerCall(pageText: String?) async {
        let harness = RoomArtHarness(frontTab: RoomArtFrontTab(url: "https://shop.example/water-lilies", title: "Water Lilies print", text: pageText))

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        #expect(harness.spokenLines() == ["I couldn't read that page."])
        #expect(harness.panel.timesShown == 0)
        #expect(harness.worker.pageRequests.isEmpty && harness.worker.wallRequests.isEmpty)
    }

    @Test func aPageThatStatesNoSizeSaysSoAndMeasuresNothing() async throws {
        let unsizedTable = RoomArtPageReading.furniture(RoomArtFurnitureReading(title: "LACK side table", chosenSize: nil, whyThisSize: "No size.", itemCorners: pictureCorners))
        for pageReading in [RoomArtPageReading.sizeNotOnThePage(title: "Water Lilies print"), unsizedTable] {
            let worker = WorkerStub()
            worker.pageReading = .success(pageReading)
            let harness = RoomArtHarness(worker: worker)

            await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

            try await waitFor("the panel to fail with no size on the page") { harness.controller.phase == .failed(.sizeNotOnThePage) }
            #expect(harness.spokenLines() == ["I couldn't find the size on that page."])
            // No measurement runs for a size the model would have to guess.
            #expect(worker.wallRequests.isEmpty && worker.floorRequests.isEmpty)
            #expect(harness.frameProcessor.keyframeSurfaces.isEmpty)
            harness.controller.close()
        }
    }

    @Test func escapeWhileThePictureIsCapturedStopsTheRequest() async throws {
        let harness = RoomArtHarness(secondsToCaptureThePicture: 0.3)

        let openingTask = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the picture capture to start") { harness.recorder.pictureCaptureStarted }
        #expect(harness.controller.closeOnEscape())
        await openingTask.value

        #expect(harness.panel.timesShown == 0)
        #expect(harness.controller.phase == .closed)
        #expect(harness.spokenLines().isEmpty)
        #expect(!harness.controller.closeOnEscape())
    }

    @Test func aPushToTalkPressWhileThePictureIsCapturedStopsTheRequest() async throws {
        let harness = RoomArtHarness(secondsToCaptureThePicture: 0.3)

        // A press cancels the reply task the request runs in.
        let openingTask = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the picture capture to start") { harness.recorder.pictureCaptureStarted }
        openingTask.cancel()
        await openingTask.value

        #expect(harness.panel.timesShown == 0)
        #expect(harness.controller.phase == .closed)
        #expect(harness.spokenLines().isEmpty)
    }

    @Test func aPanelClosedWhileTheCameraStartsStopsTheCameraOnceItRuns() async throws {
        let camera = SyntheticRoomCamera(secondsToStart: 0.3)
        let harness = RoomArtHarness(camera: camera)

        let openingTask = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the panel to show") { harness.panel.timesShown == 1 }
        harness.controller.close()
        await openingTask.value

        #expect(!camera.isDeliveringFrames)
        try await Task.sleep(for: .seconds(0.2))
        #expect(harness.worker.wallRequests.isEmpty)
    }

    @Test func noPictureSaysSoAndOpensNothing() async {
        let harness = RoomArtHarness(picture: nil)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        #expect(harness.spokenLines() == ["I don't see a picture in Chrome's front tab."])
        #expect(harness.panel.timesShown == 0)
        #expect(harness.controller.phase == .closed)
    }

    @Test func aDepthServiceThatIsDownAsksWhetherItRuns() async throws {
        let worker = WorkerStub()
        worker.wallReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 502, body: #"{"error":"The depth service is not answering"}"#))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        try await waitFor("the panel to fail asking about the depth service") { harness.controller.phase == .failed(.depthServiceUnavailable) }
        #expect(harness.spokenLines() == ["I couldn't measure your room. Is the depth service running?"])
        #expect(!harness.camera.isDeliveringFrames)
        harness.controller.close()
    }

    @Test func aRefusedAppSecretSaysSo() async throws {
        let worker = WorkerStub()
        worker.wallReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 401, body: #"{"error":"Missing or wrong x-clicky-app-secret"}"#))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        try await waitFor("the panel to fail on the app secret") { harness.controller.phase == .failed(.appSecretMissing) }
        #expect(harness.spokenLines() == ["Clicky needs its app secret for this. See the README's Worker setup."])
        harness.controller.close()
    }

    @Test func anItemThatIsNeitherWallArtNorFurnitureNorClothingSaysSoAndMeasuresNothing() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(.other(title: "Brass lamp"))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        try await waitFor("the panel to fail on an item that cannot be tried") { harness.controller.phase == .failed(.notSomethingToTry) }
        #expect(harness.spokenLines() == ["That doesn't look like wall art, furniture, or a shirt."])
        #expect(worker.wallRequests.isEmpty && worker.floorRequests.isEmpty)
        harness.controller.close()
    }

    // MARK: Furniture

    @Test func furnitureIsMeasuredOnTheFloorAndStandsThereAtItsSize() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the table to stand on the floor") { harness.artIsShowing() }
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        #expect(harness.recorder.spokenLineFailureFlags == [false])
        #expect(harness.controller.phase.statusLine == "On your floor, 21.5 inches wide and 17.5 tall")
        #expect(harness.cutouts.furnitureCutoutsAsked == 1)
        // The floor is measured from the bare floor spot, and the wall on the same keyframe at its bare wall spot, which the
        // depth service answers from the floor's cached depth.
        #expect(harness.frameProcessor.keyframeSurfaces == [.floor])
        #expect(worker.floorRequests.count == 1 && worker.wallRequests.count == 1)
        #expect(worker.wallRequests.first?.anchor == StandInFrameProcessor.bareWallSpot)
        #expect(worker.wallRequests.first?.keyframeJPEGData == worker.floorRequests.first?.keyframeJPEGData)
        // The painting is the piece's look, and the flat cutout is never drawn.
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        guard case .showing(.furniture(let furniture), .floor, nil) = harness.controller.phase else {
            Issue.record("The table is not showing on the floor: \(harness.controller.phase)")
            return
        }
        // The piece's corners use the cutout's own shape, 60 by 45, at the page's 45 cm height.
        #expect(abs(furniture.drawnWidthMeters - 0.6) < 1e-9)
        harness.controller.close()
    }

    @Test func aFloorThatIsNotFoundSaysToTiltTheScreenAndAClickOnTheFloorPlacesThePiece() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        worker.floorReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 422, body: #"{"error":"No floor under that point"}"#))
        // No wall either, so no floor can be inferred from it.
        worker.wallReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 422, body: #"{"error":"Too little bare wall"}"#))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the panel to wait for a click on the floor") { harness.controller.phase.waitingForAFloorClickItem != nil }
        #expect(harness.spokenLines() == ["I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor."])
        #expect(harness.recorder.spokenLineFailureFlags == [true])
        #expect(harness.statusLine() == "Tilt the screen down so the floor shows, then click the floor")
        // The camera keeps running, so the learner can tilt the screen down.
        #expect(harness.camera.isDeliveringFrames)

        // A click that finds no floor again only shows in the status line.
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 330))
        try await waitFor("the click's floor request") { worker.floorRequests.count == 2 }
        try await waitFor("the panel to wait for a click again") { harness.controller.phase.waitingForAFloorClickItem != nil }
        #expect(harness.spokenLines().count == 1)

        worker.floorReply = .success(FloorPlane(
            center: SIMD3(0.4, 0.9, 2.2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1), focalLengthPixels: 500,
            principalPoint: SIMD2(320, 180), distanceMeters: 2.4, floorTiltDegrees: 2, planeInlierShare: 0.9
        ))
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 320, y: 340))
        try await waitFor("the table to stand where the learner clicked") { harness.artIsShowing() }
        #expect(worker.floorRequests.last?.anchor == CGPoint(x: 320, y: 340))
        #expect(harness.frameProcessor.keyframeAnchors == [nil, CGPoint(x: 300, y: 330), CGPoint(x: 320, y: 340)])
        #expect(harness.spokenLines() == [
            "I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor.",
            "Here it is, 21.5 inches wide and 17.5 tall.",
        ])
        harness.controller.close()
    }

    @Test func withNoFloorInViewThePieceStandsAgainstTheWall() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        worker.floorReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 422, body: #"{"error":"No floor under that point"}"#))
        // A wall 4 m away, so a floor 1.05 m below the camera puts the table inside the 640 by 360 frame.
        worker.wallReply = .success(WallPlane(
            center: SIMD3(-0.3, -0.2, 4), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 500,
            principalPoint: SIMD2(320, 180), distanceMeters: 4, wallAngleDegrees: 0, planeInlierShare: 0.9
        ))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the table to stand against the wall") { harness.artIsShowing() }
        guard case .showing(_, .floor(let floor), nil) = harness.controller.phase else {
            Issue.record("The table is not on a floor: \(harness.controller.phase)")
            return
        }
        #expect(floor.inferredFromTheWall)
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        harness.controller.close()
    }

    @Test func aDepthServiceThatIsDownFailsTheFloorWithNoWallRequest() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        worker.floorReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 502, body: #"{"error":"The depth service is not answering"}"#))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the panel to fail on the depth service") { harness.controller.phase == .failed(.depthServiceUnavailable) }
        #expect(worker.wallRequests.isEmpty)
        harness.controller.close()
    }

    @Test func aFloorThatIsNotLevelWithTheWallIsADeskAndNotTheFloor() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        // The wall leans 30 degrees from the measured floor's normal, and was measured so far to the left that the table
        // inferred against it would be out of the frame, so the panel asks for a click on the floor.
        worker.wallReply = .success(WallPlane(
            center: SIMD3(-3, -0.2, 2), right: SIMD3(1, 0, 0), up: simd_normalize(SIMD3(0, -0.866, -0.5)), focalLengthPixels: 500,
            principalPoint: SIMD2(320, 180), distanceMeters: 2, wallAngleDegrees: 30, planeInlierShare: 0.9
        ))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the panel to wait for a click on the floor") { harness.controller.phase.waitingForAFloorClickItem != nil }
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        harness.controller.close()
    }

    // MARK: The furniture's better looks

    @Test func theStoresModelIsTheFallbackWhenNoPaintingCanCome() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        // This service refuses the painting, so the render shows instead of the cutout.
        try await waitFor("the store's model as the fallback") { harness.artIsShowing() }
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.storeModel])
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.keyframeNumber) == [1])
        #expect(looks.storeModelSearches == [storePageTab.url])
        #expect(looks.paintings == 1 && looks.modelsGenerated == 0)
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        harness.controller.close()
    }

    @Test func withAStoreModelOnlyThePaintingShowsAndTheRenderIsHeldBack() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        looks.paintedImage = furnitureCutoutImage()
        let paintingGate = TestGate()
        looks.paintingGate = paintingGate
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        // The render is made while the painting comes, and nothing shows until the painting arrives.
        try await waitFor("the render and the painting request") { looks.renders == [.storeModel] && paintingGate.timesWaitedOn == 1 }
        #expect(harness.frameProcessor.furnitureLayersShown.isEmpty)
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        #expect(harness.statusLine() == "Arranging it in your room…")
        #expect(harness.spokenLines().isEmpty)

        paintingGate.open()
        try await waitFor("the painting") { harness.artIsShowing() }
        // A render shown before the painting would come first in this list.
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        harness.controller.close()
    }

    @Test func nothingButTheLoopShowsUntilThePaintingFadesIn() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        let paintingGate = TestGate()
        looks.paintingGate = paintingGate
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the painting to be asked for") { paintingGate.timesWaitedOn == 1 }
        guard case .arranging = harness.controller.phase else {
            Issue.record("The table is not being arranged: \(harness.controller.phase)")
            return
        }
        #expect(harness.statusLine() == "Arranging it in your room…")
        #expect(harness.controller.loopState.isDrawing)
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty && harness.frameProcessor.furnitureLayersShown.isEmpty)
        #expect(harness.spokenLines().isEmpty)
        // A click while the piece is arranged waits, as it does during a measurement.
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 320))
        #expect(harness.frameProcessor.keyframeAnchors.count == 1)

        paintingGate.open()
        try await waitFor("the painting to show") { harness.artIsShowing() }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        #expect(harness.controller.loopState.isFadingOut)
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        harness.controller.close()
    }

    @Test func aPaintingThatDoesNotComeWithinTheWaitDrawsNothingAndALatePaintingStillShowsThePiece() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        let paintingGate = TestGate()
        looks.paintingGate = paintingGate
        let deadline = TestGate()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks, furnitureLookDeadline: deadline)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the painting and the wait to start") { paintingGate.timesWaitedOn == 1 && deadline.timesWaitedOn == 1 }
        #expect(!harness.artIsShowing())

        deadline.open()
        try await waitFor("the line that the piece could not be drawn") { harness.spokenLines() == [roomFurnitureNotDrawnLine] }
        #expect(harness.recorder.spokenLineFailureFlags == [true])
        #expect(harness.statusLine() == "I couldn't draw it this time. Click the floor to try again")
        #expect(harness.controller.loopState.isDrawing)
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty && harness.frameProcessor.furnitureLayersShown.isEmpty)

        paintingGate.open()
        try await waitFor("the late painting") { harness.artIsShowing() }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        #expect(harness.spokenLines() == [roomFurnitureNotDrawnLine, "Here it is, 21.5 inches wide and 17.5 tall."])
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        harness.controller.close()
    }

    @Test func aWaitThatRunsOutShowsTheStoresModelWhenItIsRendered() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        looks.paintedImage = furnitureCutoutImage()
        let paintingGate = TestGate()
        looks.paintingGate = paintingGate
        let deadline = TestGate()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks, furnitureLookDeadline: deadline)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the render and the wait") { looks.renders == [.storeModel] && deadline.timesWaitedOn == 1 }

        deadline.open()
        try await waitFor("the render once the wait ran out") { harness.artIsShowing() }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.storeModel])
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        paintingGate.open()
        try await waitFor("the late painting over the render") { harness.frameProcessor.furnitureLayersShown.count == 2 }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.storeModel, .paintedComposite])
        harness.controller.close()
    }

    @Test func aClickArrangesThePieceAgainUntilItsNewPaintingArrives() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the first painting") { harness.artIsShowing() }

        let paintingGate = TestGate()
        looks.paintingGate = paintingGate
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 320))
        try await waitFor("the click's painting to be asked for") { paintingGate.timesWaitedOn == 1 }
        #expect(harness.statusLine() == "Arranging it in your room…")
        #expect(harness.controller.loopState.isDrawing)
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.keyframeNumber) == [1])

        paintingGate.open()
        try await waitFor("the click's painting") { harness.artIsShowing() }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.keyframeNumber) == [1, 2])
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        #expect(harness.spokenLines().count == 1)
        harness.controller.close()
    }

    @Test func theWaitRunningOutAfterThePaintingShowedChangesNothing() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        looks.paintedImage = furnitureCutoutImage()
        let deadline = TestGate()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks, furnitureLookDeadline: deadline)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the painting") { harness.artIsShowing() && deadline.timesWaitedOn == 1 }
        deadline.open()
        try await waitFor("the wait to run out") { deadline.timesPassed == 1 }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        #expect(harness.controller.loopState.isFadingOut)
        harness.controller.close()
    }

    @Test func aPaintingThatCannotComeWaitsForTheModelSearchAndItsRender() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        let storeModelGate = TestGate()
        looks.storeModelGate = storeModelGate
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        // The painting is refused while the store's page is still searched, so the piece waits for that render.
        // The refused painting's ending runs on the main actor with no suspension after the stub throws, so it has run by
        // the time this wait sees the count.
        try await waitFor("the painting to be refused") { looks.paintings == 1 }
        #expect(harness.spokenLines().isEmpty)
        #expect(harness.statusLine() == "Arranging it in your room…")

        storeModelGate.open()
        try await waitFor("the render as the fallback") { harness.artIsShowing() }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.storeModel])
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        harness.controller.close()
    }

    @Test func aRenderStillRunningWhenThePanelClosedDoesNotHoldTheNextPanelsFallback() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        let renderGate = TestGate()
        looks.renderGate = renderGate
        looks.paintedImage = furnitureCutoutImage()
        looks.paintingGate = TestGate()
        // The wait never runs out here, so only the render's own state can let the fallback through.
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks, furnitureLookDeadline: TestGate())

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the render to start") { renderGate.timesWaitedOn == 1 }
        harness.controller.close()

        // The next panel's page has no model and its painting is refused, so it says at once that it could not draw.
        looks.storeModel = nil
        looks.paintingGate = nil
        looks.paintedImage = nil
        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the line that the piece could not be drawn", seconds: 10) { harness.spokenLines() == [roomFurnitureNotDrawnLine] }
        renderGate.open()
        harness.controller.close()
    }

    @Test func aRetryClickWhoseMeasurementFailsSaysItCouldNotDrawAgainAndKeepsThePanel() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the line that the piece could not be drawn") { harness.spokenLines() == [roomFurnitureNotDrawnLine] }

        // The depth service is down for the click the panel asked for.
        worker.floorReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 502, body: "{}"))
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 320))
        try await waitFor("the retry's failure") { harness.spokenLines().count == 2 }
        // Clicky says why the click could not help, and every line is a failure.
        #expect(harness.spokenLines() == [roomFurnitureNotDrawnLine, RoomArtFailure.depthServiceUnavailable.spokenLine])
        #expect(harness.recorder.spokenLineFailureFlags == [true, true])
        #expect(harness.statusLine() == RoomArtFailure.depthServiceUnavailable.statusLine)
        guard case .couldNotDraw = harness.controller.phase else {
            Issue.record("A failed retry ended the panel: \(harness.controller.phase)")
            return
        }
        #expect(harness.controller.isOpen)
        #expect(harness.camera.isDeliveringFrames)
        harness.controller.close()
    }

    @Test func aRenderThatFinishesAfterThePieceCouldNotBeDrawnShowsIt() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        let renderGate = TestGate()
        looks.renderGate = renderGate
        looks.paintedImage = furnitureCutoutImage()
        looks.paintingGate = TestGate()
        let deadline = TestGate()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks, furnitureLookDeadline: deadline)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the render and the wait to start") { renderGate.timesWaitedOn == 1 && deadline.timesWaitedOn == 1 }
        deadline.open()
        try await waitFor("the line that the piece could not be drawn") { harness.spokenLines() == [roomFurnitureNotDrawnLine] }

        renderGate.open()
        try await waitFor("the late render") { harness.artIsShowing() }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.storeModel])
        #expect(harness.spokenLines() == [roomFurnitureNotDrawnLine, "Here it is, 21.5 inches wide and 17.5 tall."])
        harness.controller.close()
    }

    @Test func aKeyframeThatCannotBeDecodedSaysItCouldNotDrawAtOnce() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        looks.paintedImage = furnitureCutoutImage()
        // The wait never runs out here, so only the ends of the painting and the render can let the fallback through.
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks, furnitureLookDeadline: TestGate())
        harness.frameProcessor.handOutKeyframesThatCannotBeDecoded()

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the line that the piece could not be drawn", seconds: 10) { harness.spokenLines() == [roomFurnitureNotDrawnLine] }
        #expect(looks.renders.isEmpty && looks.paintings == 0)
        harness.controller.close()
    }

    @Test func withNoStoreModelAGeneratedModelIsShown() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.generatedModelData = Data([1, 2, 3])
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        // The painting is refused, so the generated model's render is the fallback.
        try await waitFor("the generated model as the fallback") { !harness.frameProcessor.furnitureLayersShown.isEmpty }
        #expect(looks.paintings == 1)
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.generatedModel])
        harness.controller.close()
    }

    @Test func withNoModelAtAllThePaintedCompositeIsShown() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the painted composite") { !harness.frameProcessor.furnitureLayersShown.isEmpty }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        #expect(looks.modelsGenerated == 1 && looks.paintings == 1)
        harness.controller.close()
    }

    @Test func bothGenerationServicesGetTheFurnituresCutoutAndNeverThePagePicture() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("both services to be asked") { looks.modelsGenerated == 1 && looks.paintings == 1 }
        #expect(looks.productJPEGsSent.count == 2)
        for productJPEG in looks.productJPEGsSent {
            // The page picture is 400 by 500, and the cutout is 60 by 45.
            let sentImage = try #require(decodedImage(from: productJPEG))
            #expect(sentImage.width == 60 && sentImage.height == 45)
        }
        #expect(looks.productJPEGsSent[0] == looks.productJPEGsSent[1])
        // The model is cached by the page picture, which is stable between requests, and not by the cutout.
        let cacheKeyData = try #require(looks.modelCacheKeysSent.first)
        let cacheKeyImage = try #require(decodedImage(from: cacheKeyData))
        #expect(looks.modelCacheKeysSent.count == 1 && cacheKeyImage.width == 400 && cacheKeyImage.height == 500)
        harness.controller.close()
    }

    @Test func twoPaintingsAtTheWrongHeightDrawNothingAndAClickTriesAgain() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        looks.firstKeptPainting = nil
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the line after the second refused painting") { harness.spokenLines() == [roomFurnitureNotDrawnLine] }
        try await Task.sleep(for: .milliseconds(200))
        #expect(looks.paintings == 2)
        #expect(harness.frameProcessor.furnitureLayersShown.isEmpty)
        #expect(harness.frameProcessor.surfacesShownOn.isEmpty)
        #expect(!harness.artIsShowing())
        // A click on the floor measures there and arranges the piece again.
        looks.firstKeptPainting = 3
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 320))
        try await waitFor("the click's painting") { harness.artIsShowing() }
        #expect(harness.frameProcessor.keyframeAnchors.last == CGPoint(x: 300, y: 320))
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.keyframeNumber) == [2])
        harness.controller.close()
    }

    @Test func aPaintingAtTheWrongHeightIsAskedForOnceMore() async throws {
        // With no model, a refused painting would leave the piece undrawn, so a second painting is asked for first.
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        looks.firstKeptPainting = 2
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the second painting") { !harness.frameProcessor.furnitureLayersShown.isEmpty }
        #expect(looks.paintings == 2)
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        harness.controller.close()
    }

    @Test func aFailedPaintingRequestIsAskedForOnceMore() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.paintedImage = furnitureCutoutImage()
        looks.failingPaintings = 1
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the second painting after the 502") { !harness.frameProcessor.furnitureLayersShown.isEmpty }
        #expect(looks.paintings == 2)
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        harness.controller.close()
    }

    @Test func onlyAPaintingFailureThatMayPassIsAskedForAgain() {
        #expect(roomFurniturePaintingIsWorthAskingForAgain(after: RoomFurnitureGenerationError.workerReturned(statusCode: 502, body: "")))
        #expect(roomFurniturePaintingIsWorthAskingForAgain(after: RoomFurnitureGenerationError.workerReturned(statusCode: 504, body: "")))
        #expect(roomFurniturePaintingIsWorthAskingForAgain(after: URLError(.timedOut)))
        #expect(!roomFurniturePaintingIsWorthAskingForAgain(after: RoomFurnitureGenerationError.serviceIsNotSetUp(body: "")))
        #expect(!roomFurniturePaintingIsWorthAskingForAgain(after: RoomFurnitureGenerationError.workerReturned(statusCode: 401, body: "")))
        #expect(!roomFurniturePaintingIsWorthAskingForAgain(after: RoomFurnitureGenerationError.workerReturned(statusCode: 400, body: "")))
        #expect(!roomFurniturePaintingIsWorthAskingForAgain(after: RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "")))
    }

    @Test func aModelThatDoesNotRenderFallsBackToThePainting() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        looks.renderSucceeds = false
        looks.paintedImage = furnitureCutoutImage()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the painted composite after the failed render") { !harness.frameProcessor.furnitureLayersShown.isEmpty }
        #expect(looks.renders == [.storeModel])
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.look) == [.paintedComposite])
        harness.controller.close()
    }

    @Test func aClickRendersTheModelAgainForTheNewKeyframe() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        looks.storeModel = FurnitureLookStub.model(.storeModel)
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the first render") { harness.frameProcessor.furnitureLayersShown.count == 1 }

        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 320))
        try await waitFor("the render for the click's keyframe") { harness.frameProcessor.furnitureLayersShown.count == 2 }
        #expect(harness.frameProcessor.furnitureLayersShown.map(\.keyframeNumber) == [1, 2])
        #expect(looks.storeModelSearches.count == 1)
        harness.controller.close()
    }

    @Test func aGenerationServiceThatIsNotSetUpDrawsNothingAndIsNotAskedAgain() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let looks = FurnitureLookStub()
        let harness = RoomArtHarness(worker: worker, furnitureLooks: looks)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the line that the piece could not be drawn") { harness.spokenLines().count == 1 }
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 300, y: 320))
        try await waitFor("the click's placement to fail the same way") { harness.spokenLines().count == 2 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.spokenLines() == [roomFurnitureNotDrawnLine, roomFurnitureNotDrawnLine])
        #expect(harness.frameProcessor.keyframeAnchors.count == 2)
        #expect(looks.paintings == 1)
        #expect(harness.frameProcessor.furnitureLayersShown.isEmpty && harness.frameProcessor.surfacesShownOn.isEmpty)
        harness.controller.close()
    }

    @Test func aPieceNoSpotShowsWholeAsksTheLearnerToStepBack() async throws {
        let worker = WorkerStub()
        // A 6 m sofa, the largest size the reader keeps, wider than the 640 by 360 frame shows at any spot no farther than
        // the measured one.
        worker.pageReading = .success(.furniture(RoomArtFurnitureReading(
            title: "Long sofa",
            chosenSize: RoomArtFurnitureSize(label: "600x85x95 cm", widthCentimeters: 600, heightCentimeters: 85, depthCentimeters: 95),
            whyThisSize: "It is the only size.",
            itemCorners: pictureCorners
        )))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this sofa look in my room")

        try await waitFor("the sofa and the step back line") { harness.spokenLines().count == 2 }
        #expect(harness.spokenLines().last == roomFurnitureStepBackLine)
        #expect(harness.recorder.spokenLineFailureFlags.last == false)
        harness.controller.close()
    }

    @Test func aPieceThatFitsIsMovedIntoTheFrameButAClickedSpotIsKept() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")
        try await waitFor("the table to stand on the floor") { harness.artIsShowing() }
        guard case .showing(_, .floor(let firstFloor), nil) = harness.controller.phase else {
            Issue.record("The table is not on a floor: \(harness.controller.phase)")
            return
        }
        // The stub floor's own point is off to the side, so the piece moved toward the lower middle, where all of it
        // shows, and no step back line was said.
        #expect(firstFloor.center != worker.floorRequestsReply)
        #expect(harness.spokenLines() == ["Here it is, 21.5 inches wide and 17.5 tall."])
        // The loop moved from the measured spot to the middle of the table's footprint, on the first keyframe.
        let expectedLoopCenter = try #require(roomFurnitureFootprintCenterInTheKeyframe(floor: firstFloor, widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55))
        let loopOutline = try #require(harness.frameProcessor.loopOutlines.first)
        #expect(harness.frameProcessor.loopOutlines.count == 1)
        #expect(hypot(loopOutline.point.x - expectedLoopCenter.x, loopOutline.point.y - expectedLoopCenter.y) < 1)
        #expect(loopOutline.keyframeNumber == 1)

        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 600, y: 340))
        try await waitFor("the click's placement") { harness.frameProcessor.furnitureLayersShown.count == 2 }
        guard case .showing(_, .floor(let clickedFloor), nil) = harness.controller.phase else {
            Issue.record("The table is not on a floor after the click: \(harness.controller.phase)")
            return
        }
        #expect(clickedFloor.center == worker.floorRequestsReply)
        // A click keeps its spot, so the loop stays where the learner clicked.
        #expect(harness.frameProcessor.loopOutlines.count == 1)
        harness.controller.close()
    }

    @Test func furnitureThatCannotBeCutOutSaysSo() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(sideTableReading)
        let cutouts = CutoutStub()
        cutouts.furnitureCutout = nil
        let harness = RoomArtHarness(worker: worker, cutouts: cutouts)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this table look in my room")

        try await waitFor("the panel to fail on the cutout") { harness.controller.phase == .failed(.furnitureNotCutOut) }
        #expect(harness.spokenLines() == ["I couldn't cut the furniture out of its photo."])
        #expect(worker.floorRequests.isEmpty)
        harness.controller.close()
    }

    // MARK: The shirt

    @Test func aShirtCoachesTheLearnerOnceThenShowsOnThemWithNoMeasurement() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading())
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")
        try await waitFor("the garment to be ready") { harness.controller.phase == .waitingToSeeTheLearner(title: "Linen shirt") }
        #expect(harness.frameProcessor.shirtTryOnStarted && harness.frameProcessor.garmentWorn)
        // The loop traces the learner while the shirt is on its way.
        #expect(!harness.controller.loopState.isHidden && !harness.controller.loopState.isFadingOut)
        #expect(harness.statusLine() == "Looking for you…")

        harness.frameProcessor.settleTheShirtFraming(on: .standBack)
        try await waitFor("the coaching in the status line") { harness.controller.shirtCoachingLine != nil }
        #expect(harness.statusLine() == "Stand back so I can see your shoulders and chest.")
        // The first advice is said once, and not as a failure.
        #expect(harness.spokenLines() == ["Stand back so I can see your shoulders and chest."])
        #expect(harness.recorder.spokenLineFailureFlags == [false])

        harness.frameProcessor.settleTheShirtFraming(on: .noPerson)
        try await waitFor("the newer coaching in the status line") { harness.statusLine() == "I can't see you yet. Step in front of the camera." }
        #expect(harness.spokenLines().count == 1)

        harness.frameProcessor.settleTheShirtFraming(on: .ready)
        try await waitFor("the shirt to show on the learner") { harness.controller.phase == .showingTheShirt(title: "Linen shirt") }
        #expect(harness.spokenLines() == ["Stand back so I can see your shoulders and chest.", "Here's a preview. Say right there to put it on you."])
        #expect(harness.statusLine() == "On you")
        #expect(harness.controller.loopState.isFadingOut)
        // A shirt needs no depth: no keyframe, no wall, no floor.
        #expect(harness.frameProcessor.keyframeSurfaces.isEmpty)
        #expect(worker.wallRequests.isEmpty && worker.floorRequests.isEmpty)
        // A click on a shirt changes nothing.
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 100, y: 100))
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))

        // A learner who steps away after the shirt showed gets the status line only.
        harness.frameProcessor.settleTheShirtFraming(on: .standBack)
        try await waitFor("the coaching to return to the status line") { harness.controller.shirtCoachingLine != nil }
        #expect(harness.spokenLines().count == 2)
        harness.controller.close()
    }

    // MARK: The painted still

    /// A panel showing the live preview of the shirt, with the painting answered by `shirtPainting`.
    private func harnessShowingTheLiveShirt(shirtPainting: ShirtPaintingStub) async throws -> RoomArtHarness {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading())
        let harness = RoomArtHarness(worker: worker, shirtPainting: shirtPainting)
        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")
        try await waitFor("the garment to be ready") { harness.controller.phase == .waitingToSeeTheLearner(title: "Linen shirt") }
        harness.frameProcessor.settleTheShirtFraming(on: .ready)
        try await waitFor("the live preview to show") { harness.controller.phase == .showingTheShirt(title: "Linen shirt") }
        return harness
    }

    @Test func rightThereFreezesTheFramePaintsTheShirtAndGoBackReturnsToTheLivePreview() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.secondsBeforeThePaintingReturns = 0.3
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)
        #expect(harness.controller.shirtStillVoiceTargets == .livePreview)

        harness.controller.paintTheShirt()
        guard case .paintingTheShirt(let title, _) = harness.controller.phase else {
            Issue.record("The shirt is not being painted: \(harness.controller.phase)")
            return
        }
        #expect(title == "Linen shirt")
        #expect(harness.statusLine() == "Putting it on you…")
        // The loop traces the frozen torso while the painting is made.
        #expect(!harness.controller.loopState.isHidden && !harness.controller.loopState.isFadingOut)
        #expect(harness.controller.shirtStillVoiceTargets == .paintedStill)
        try await waitFor("the frame to freeze") { harness.frameProcessor.isFrozen }
        // A second request during the painting starts nothing.
        harness.controller.paintTheShirt()

        try await waitFor("the painted still to show") { harness.controller.phase == .showingThePaintedShirt(title: "Linen shirt") }
        #expect(harness.frameProcessor.freezes == 1 && harness.frameProcessor.paintedStillsShown == 1)
        // The loop traced the outline of the area being painted.
        try await waitFor("the painted area's outline") { harness.frameProcessor.paintedAreaOutlines == 1 }
        #expect(shirtPainting.requests.count == 1)
        #expect(harness.spokenLines().last == "Here it is on you.")
        #expect(harness.recorder.spokenLineFailureFlags.last == false)
        #expect(harness.statusLine() == "On you · say go back for the live view")
        #expect(harness.controller.loopState.isFadingOut)

        // The Worker hears the garment in its own words: the page's kind and sleeves, and the color the garment measured.
        let paintingRequest = try #require(shirtPainting.requests.first)
        #expect(paintingRequest.garment.kind == .shirt && paintingRequest.garment.sleeves == .short)
        #expect(paintingRequest.garment.baseColorHex.hasPrefix("#") && paintingRequest.garment.baseColorHex.count == 7)
        #expect(paintingRequest.itemTitle == "Linen shirt")
        #expect(!paintingRequest.productJPEG.isEmpty)

        harness.controller.goBackToTheLiveShirt()
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        #expect(harness.frameProcessor.resumes == 1 && !harness.frameProcessor.isFrozen)
        // The preview's line is not said again on the way back.
        #expect(harness.spokenLines().filter { $0 == "Here's a preview. Say right there to put it on you." }.count == 1)
        // Back to live again changes nothing.
        harness.controller.goBackToTheLiveShirt()
        #expect(harness.frameProcessor.resumes == 1)

        // A second painting is a new look, and its line is said again.
        harness.controller.paintTheShirt()
        try await waitFor("the second painted still") { harness.controller.phase == .showingThePaintedShirt(title: "Linen shirt") }
        #expect(harness.spokenLines().filter { $0 == "Here it is on you." }.count == 2)
        harness.controller.close()
    }

    @Test func theButtonPaintsAndGoesBackAsTheVoiceDoesAndIgnoresAClickRightAfterItChanges() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.secondsBeforeThePaintingReturns = 0.3
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)
        let later = ProcessInfo.processInfo.systemUptime + 60

        harness.controller.pressTheShirtButton(atUptime: later)
        #expect(harness.controller.shirtStillVoiceTargets == .paintedStill)
        // A click asks the panel as the voice does, so "Here it is on you." is not dropped after an earlier press.
        #expect(harness.recorder.timesTheLearnerAskedThePanel == 1)
        // The button is Back to live now, and the second click of a double-click lands right after it changed.
        harness.controller.pressTheShirtButton()
        #expect(harness.controller.shirtStillVoiceTargets == .paintedStill)
        #expect(harness.recorder.timesTheLearnerAskedThePanel == 1)

        try await waitFor("the painted still") { harness.controller.phase == .showingThePaintedShirt(title: "Linen shirt") }
        harness.controller.pressTheShirtButton(atUptime: later + 60)
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        #expect(harness.recorder.timesTheLearnerAskedThePanel == 2)
        #expect(shirtButtonPressCounts(atUptime: 10.4, theButtonChangedAt: 10) && !shirtButtonPressCounts(atUptime: 10.39, theButtonChangedAt: 10))
        harness.controller.close()
    }

    @Test func aRefusedAppSecretSaysSoInsteadOfTryAgain() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.paintingResult = .failure(RoomFurnitureGenerationError.workerReturned(statusCode: 401, body: ""))
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        harness.controller.paintTheShirt()
        try await waitFor("the app secret line") { harness.spokenLines().last == RoomArtFailure.appSecretMissing.spokenLine }
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        harness.controller.close()
    }

    @Test func theCoachingStaysWhenTheLearnerIsOutOfViewOnTheWayBack() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.secondsBeforeThePaintingReturns = 0.5
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)
        harness.controller.paintTheShirt()
        // The learner steps out of view while the frame is frozen.
        harness.frameProcessor.settleTheShirtFraming(on: .standBack)
        try await waitFor("the coaching to be noted") { harness.controller.shirtCoachingLine != nil }

        harness.controller.goBackToTheLiveShirt()
        #expect(harness.statusLine() == "Stand back so I can see your shoulders and chest.")
        harness.controller.close()
    }

    @Test func goingBackBeforeThePaintingStartsFreezesNothing() async throws {
        let shirtPainting = ShirtPaintingStub()
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        // Both on the main actor in one turn, so the painting's task has not run when the learner goes back.
        harness.controller.paintTheShirt()
        harness.controller.goBackToTheLiveShirt()
        try await Task.sleep(for: .seconds(0.5))
        #expect(harness.frameProcessor.freezes == 0 && !harness.frameProcessor.isFrozen)
        #expect(shirtPainting.requests.isEmpty)
        harness.controller.close()
    }

    @Test func goingBackDuringAPaintingCancelsItAndItsReplyChangesNothing() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.secondsBeforeThePaintingReturns = 0.5
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        harness.controller.paintTheShirt()
        try await waitFor("the painting to be sent") { shirtPainting.requests.count == 1 }
        harness.controller.goBackToTheLiveShirt()
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))

        try await Task.sleep(for: .seconds(0.8))
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        #expect(harness.frameProcessor.paintedStillsShown == 0)
        #expect(!harness.spokenLines().contains("Here it is on you."))
        harness.controller.close()
    }

    @Test func aPaintingThatFailsSaysWhyAndReturnsToTheLivePreview() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.paintingResult = .failure(RoomFurnitureGenerationError.workerReturned(statusCode: 502, body: ""))
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        harness.controller.paintTheShirt()
        try await waitFor("the failure line") { harness.spokenLines().last == "I couldn't put it on you that time. Say right there to try again." }
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        #expect(harness.recorder.spokenLineFailureFlags.last == true)
        #expect(harness.frameProcessor.resumes == 1 && !harness.frameProcessor.isFrozen)
        #expect(harness.frameProcessor.paintedStillsShown == 0)
        harness.controller.close()
    }

    @Test func aWorkerWithNoOpenAIKeySaysSo() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.paintingResult = .failure(RoomFurnitureGenerationError.serviceIsNotSetUp(body: ""))
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        harness.controller.paintTheShirt()
        try await waitFor("the not set up line") { harness.spokenLines().last == "Painting a shirt on you needs Clicky's OpenAI key." }
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        harness.controller.close()
    }

    @Test func nobodyInViewOrNoShirtFoundPaintsNothing() async throws {
        let shirtPainting = ShirtPaintingStub()
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        harness.frameProcessor.setAShirtIsDrawn(false)
        harness.controller.paintTheShirt()
        try await waitFor("the step in front line") { harness.spokenLines().last == "Step in front of the camera, then say right there." }
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))

        harness.frameProcessor.setAShirtIsDrawn(true)
        shirtPainting.masksAreMade = false
        harness.controller.paintTheShirt()
        try await waitFor("the shirt not found line") { harness.spokenLines().last == "I couldn't find your shirt in that frame. Try again with your shirt in view." }
        #expect(harness.controller.phase == .showingTheShirt(title: "Linen shirt"))
        // Each failure resumes the live preview, which a freeze that found nothing never left.
        #expect(harness.frameProcessor.resumes == 2 && !harness.frameProcessor.isFrozen)
        #expect(shirtPainting.requests.isEmpty)
        harness.controller.close()
    }

    @Test func closingDuringAPaintingShowsNothingAfterward() async throws {
        let shirtPainting = ShirtPaintingStub()
        shirtPainting.secondsBeforeThePaintingReturns = 0.5
        let harness = try await harnessShowingTheLiveShirt(shirtPainting: shirtPainting)

        harness.controller.paintTheShirt()
        try await waitFor("the painting to be sent") { shirtPainting.requests.count == 1 }
        harness.controller.close()
        try await Task.sleep(for: .seconds(0.8))
        #expect(harness.controller.phase == .closed)
        #expect(harness.frameProcessor.paintedStillsShown == 0)
        #expect(!harness.spokenLines().contains("Here it is on you."))
        #expect(harness.controller.shirtStillVoiceTargets == .none)
    }

    @Test func paintingIsRefusedBeforeTheLivePreviewShows() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading())
        let shirtPainting = ShirtPaintingStub()
        let harness = RoomArtHarness(worker: worker, shirtPainting: shirtPainting)
        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")
        try await waitFor("the garment to be ready") { harness.controller.phase == .waitingToSeeTheLearner(title: "Linen shirt") }
        #expect(harness.controller.shirtStillVoiceTargets == .none)

        harness.controller.paintTheShirt()
        #expect(harness.controller.phase == .waitingToSeeTheLearner(title: "Linen shirt"))
        #expect(harness.frameProcessor.freezes == 0)
        harness.controller.close()
    }

    @Test func aLearnerInViewBeforeTheGarmentIsReadySeesTheShirtTheMomentItIs() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading())
        let cutouts = CutoutStub()
        cutouts.secondsBeforeTheGarmentIsReady = 0.5
        let harness = RoomArtHarness(worker: worker, cutouts: cutouts)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")
        try await waitFor("the shirt try-on to start") { harness.frameProcessor.shirtTryOnStarted }
        #expect(harness.controller.phase == .preparingTheShirt(title: "Linen shirt"))
        #expect(harness.statusLine() == "Getting the shirt ready…")
        harness.frameProcessor.settleTheShirtFraming(on: .ready)

        try await waitFor("the shirt to show on the learner") { harness.controller.phase == .showingTheShirt(title: "Linen shirt") }
        #expect(harness.spokenLines() == ["Here's a preview. Say right there to put it on you."])
        // Stepping away once the shirt shows moves only the status line, even with no advice said before.
        harness.frameProcessor.settleTheShirtFraming(on: .standBack)
        try await waitFor("the coaching in the status line") { harness.controller.shirtCoachingLine != nil }
        #expect(harness.spokenLines() == ["Here's a preview. Say right there to put it on you."])
        harness.controller.close()
    }

    @Test func aShirtPhotographedOnAModelIsRefusedAndNoGarmentIsMade() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading(photoShows: .onModel))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")

        try await waitFor("the panel to refuse the model photo") { harness.controller.phase == .failed(.shirtPhotoOnAModel) }
        #expect(harness.spokenLines() == ["I can only try on a shirt from a flat photo of it, and this photo shows it on a model."])
        #expect(harness.recorder.spokenLineFailureFlags == [true])
        #expect(harness.cutouts.garmentsAsked == 0)
        #expect(!harness.frameProcessor.shirtTryOnStarted)
        harness.controller.close()
    }

    @Test func aGarmentThatCannotBeCutOutSaysSo() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading())
        let cutouts = CutoutStub()
        cutouts.garment = nil
        let harness = RoomArtHarness(worker: worker, cutouts: cutouts)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")

        try await waitFor("the panel to fail on the garment") { harness.controller.phase == .failed(.garmentNotCutOut) }
        #expect(harness.spokenLines() == ["I couldn't lift the shirt out of its photo."])
        #expect(!harness.frameProcessor.garmentWorn)
        harness.controller.close()
    }

    @Test func aGarmentThatIsReadyAfterThePanelClosedChangesNothing() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(shirtReading())
        let cutouts = CutoutStub()
        cutouts.secondsBeforeTheGarmentIsReady = 0.4
        let harness = RoomArtHarness(worker: worker, cutouts: cutouts)

        await harness.controller.showTheArtInTheRoom(learnerRequest: "could I see this shirt on me")
        try await waitFor("the garment to be asked for") { cutouts.garmentsAsked == 1 }
        harness.controller.close()
        try await Task.sleep(for: .seconds(0.8))

        #expect(harness.controller.phase == .closed)
        #expect(!harness.frameProcessor.garmentWorn)
        #expect(harness.spokenLines().isEmpty)
    }

    // MARK: Every kind

    @Test func everyFailureLineIsSpokenAsAFailureAndHereItIsIsNot() async throws {
        // Lines the controller speaks before the camera opens.
        let noSecretHarness = RoomArtHarness(appSecretIsSet: false)
        await noSecretHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        let httpHarness = RoomArtHarness(frontTab: RoomArtFrontTab(url: "http://shop.example/print", title: "Print", text: "A print"))
        await httpHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        let noTextHarness = RoomArtHarness(frontTab: RoomArtFrontTab(url: "https://shop.example/print", title: "Print", text: nil))
        await noTextHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        let noTabHarness = RoomArtHarness(frontTab: nil)
        await noTabHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        let noPictureHarness = RoomArtHarness(picture: nil)
        await noPictureHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        // A failure the panel enters after it opened.
        let cameraHarness = RoomArtHarness(camera: SyntheticRoomCamera(startFailure: .noCamera))
        await cameraHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        let lampWorker = WorkerStub()
        lampWorker.pageReading = .success(.other(title: "Brass lamp"))
        let readFailureHarness = RoomArtHarness(worker: lampWorker)
        await readFailureHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the panel to fail on an item that cannot be tried") { readFailureHarness.controller.phase == .failed(.notSomethingToTry) }
        let dressWorker = WorkerStub()
        dressWorker.pageReading = .success(.clothing(RoomArtClothingReading(
            title: "Dress", garment: .dress, sleeves: .none, chosenSizeLabel: "S", photoShows: .flatLay, printDescription: "", whyThisSize: "S.", itemCorners: pictureCorners
        )))
        let dressHarness = RoomArtHarness(worker: dressWorker)
        await dressHarness.controller.showTheArtInTheRoom(learnerRequest: "could I see this dress on me")
        try await waitFor("the panel to fail on a dress") { dressHarness.controller.phase == .failed(.onlyTopsSoFar) }

        for failureHarness in [noSecretHarness, httpHarness, noTextHarness, noTabHarness, noPictureHarness, cameraHarness, readFailureHarness, dressHarness] {
            #expect(failureHarness.recorder.spokenLineFailureFlags == [true], "\(failureHarness.spokenLines())")
            failureHarness.controller.close()
        }

        let successHarness = RoomArtHarness()
        await successHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the art to show on the wall") { successHarness.artIsShowing() }
        #expect(successHarness.recorder.spokenLineFailureFlags == [false])
        successHarness.controller.close()
    }

    @Test func theLoopDrawsFromTheKeyframeUntilTheArtShowsAndThenFadesAndClearsOnClose() async throws {
        let worker = WorkerStub()
        // The wall replies late, so the loop is on screen for a while, even on a loaded machine.
        worker.secondsBeforeTheWallReplies = 3
        let harness = RoomArtHarness(worker: worker)
        #expect(harness.controller.loopState == .hidden)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the measurement to start the loop") { !harness.controller.loopState.isHidden }
        #expect(harness.controller.loopState.beganAt != nil && !harness.controller.loopState.isFadingOut)
        let beganAt = harness.controller.loopState.beganAt

        try await waitFor("the art to show on the wall") { harness.artIsShowing() }
        #expect(harness.controller.loopState == .fadingOut(beganAt: try #require(beganAt)))

        harness.controller.theLoopFadeFinished()
        #expect(harness.controller.loopState == .hidden)

        // A click's measurement draws it again, and closing the panel removes it at once.
        harness.controller.placeTheItem(atCameraPixel: CGPoint(x: 100, y: 100))
        #expect(harness.controller.loopState.beganAt != beganAt && !harness.controller.loopState.isFadingOut)
        harness.controller.close()
        #expect(harness.controller.loopState == .hidden)
    }

    @Test func theLoopFadesWhenTheMeasurementFails() async throws {
        let worker = WorkerStub()
        worker.wallReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 422, body: ""))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        try await waitFor("the panel to fail on the wall") { harness.controller.phase == .failed(.wallNotMeasured) }
        #expect(harness.controller.loopState.isFadingOut)
        harness.controller.close()
    }

    @Test func theLoopOutlineComesFromTheProcessorsNewestSnapshotInPanelPoints() async {
        let harness = RoomArtHarness()
        let panelSize = CGSize(width: 960, height: 540)
        #expect(harness.controller.currentLoopOutline(cameraSize: CGSize(width: 1280, height: 720), panelSize: panelSize) == nil)

        let keyframeCorners = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 250), frameSize: CGSize(width: 1280, height: 720), on: .wall)
        harness.frameProcessor.setTheLoop(RoomArtLoopSnapshot(keyframeCorners: keyframeCorners, currentCorners: keyframeCorners))

        let outline = harness.controller.currentLoopOutline(cameraSize: CGSize(width: 1280, height: 720), panelSize: panelSize)
        #expect(outline?.boundingRect.isEmpty == false)
        // No camera frame yet, so nothing can be placed.
        #expect(harness.controller.currentLoopOutline(cameraSize: .zero, panelSize: panelSize) == nil)
    }

    @Test func aRefusedCameraAsksForAccess() async {
        let harness = RoomArtHarness(camera: SyntheticRoomCamera(startFailure: .cameraAccessDenied))

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        #expect(harness.controller.phase == .failed(.cameraAccessDenied))
        #expect(harness.spokenLines() == ["I need camera access for that. You can turn it on in System Settings."])
        #expect(harness.worker.wallRequests.isEmpty)
        harness.controller.close()
    }

    @Test func aSecondRequestStopsTheFirstRequestsPictureDownload() async throws {
        let harness = RoomArtHarness(secondsToCaptureThePicture: 120)
        let firstRequest = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the first picture capture to start") { harness.recorder.pictureCaptureStarted }
        let secondRequest = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        // The 120 second capture only ends early when the second request cancels it.
        let secondRequestStartedAt = ContinuousClock.now
        await firstRequest.value
        #expect(ContinuousClock.now - secondRequestStartedAt < .seconds(30))
        #expect(harness.controller.closeOnEscape())
        await secondRequest.value
    }

    @Test func escapeStopsASlowPictureDownloadAtOnce() async throws {
        // The picture takes 120 s, and a close that did not cancel it would leave the request waiting that long.
        let harness = RoomArtHarness(secondsToCaptureThePicture: 120)
        let openingTask = Task { await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the picture capture to start") { harness.recorder.pictureCaptureStarted }
        let escapePressedAt = ContinuousClock.now
        #expect(harness.controller.closeOnEscape())
        await openingTask.value
        #expect(ContinuousClock.now - escapePressedAt < .seconds(30))
        #expect(harness.panel.timesShown == 0)
        #expect(harness.spokenLines().isEmpty)
    }

    @Test func everyCloseEndsTheSpokenLine() async throws {
        // Escape on an open panel.
        let escapedHarness = RoomArtHarness()
        await escapedHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        #expect(escapedHarness.recorder.timesTheSpokenLineWasEnded == 0)
        #expect(escapedHarness.controller.closeOnEscape())
        #expect(escapedHarness.recorder.timesTheSpokenLineWasEnded == 1)

        // Escape while the picture is still being captured.
        let openingHarness = RoomArtHarness(secondsToCaptureThePicture: 0.3)
        let openingTask = Task { await openingHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid) }
        try await waitFor("the picture capture to start") { openingHarness.recorder.pictureCaptureStarted }
        #expect(openingHarness.controller.closeOnEscape())
        await openingTask.value
        #expect(openingHarness.recorder.timesTheSpokenLineWasEnded == 1)

        // The Close button, after a failure whose line is still playing.
        let failedHarness = RoomArtHarness(camera: SyntheticRoomCamera(startFailure: .cameraAccessDenied))
        await failedHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        #expect(failedHarness.controller.phase == .failed(.cameraAccessDenied))
        failedHarness.controller.close()
        #expect(failedHarness.recorder.timesTheSpokenLineWasEnded == 1)
    }

    @Test func escapeClosesAnOpenPanelAndNothingElse() async {
        let harness = RoomArtHarness()
        #expect(!harness.controller.closeOnEscape())

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        #expect(harness.controller.closeOnEscape())
        #expect(harness.controller.phase == .closed)
        #expect(harness.panel.timesHidden == 1)
    }
}

private extension RoomArtPhase {
    /// The piece waiting for a click on the floor, nil in any other phase.
    var waitingForAFloorClickItem: RoomArtPlacedItem? {
        if case .waitingForAFloorClick(let item) = self { return item }
        return nil
    }
}

private extension RoomArtLoopState {
    var isDrawing: Bool {
        if case .drawing = self { return true }
        return false
    }
}
