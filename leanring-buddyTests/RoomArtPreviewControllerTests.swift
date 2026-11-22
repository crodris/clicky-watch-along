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
/// at the anchor asked for, and hanging or putting back the art is recorded.
nonisolated private final class StandInFrameProcessor: RoomArtFrameProcessing, @unchecked Sendable {
    let processingQueue = DispatchQueue(label: "com.crodris.clicky.tests.room-art-frames")
    let metalLayer = CAMetalLayer()
    /// Where a keyframe with no anchor centers the art, as the bare wall spot would.
    static let bareWallSpot = CGPoint(x: 200, y: 150)

    private let lock = NSLock()
    private var onFirstSegmentedFrame: (@Sendable () -> Void)?
    private var onTheWallLostOrFound: (@Sendable (Bool) -> Void)?
    private var recordedArtHungCount = 0
    private var recordedArtPutBackCount = 0
    private var recordedKeyframeAnchors: [CGPoint?] = []
    private var latestLoop: RoomArtLoopSnapshot?

    var artHungCount: Int { lock.withLock { recordedArtHungCount } }
    var artPutBackCount: Int { lock.withLock { recordedArtPutBackCount } }
    var keyframeAnchors: [CGPoint?] { lock.withLock { recordedKeyframeAnchors } }

    func startASession(onFirstSegmentedFrame: @escaping @Sendable () -> Void, onTheWallLostOrFound: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            self.onFirstSegmentedFrame = onFirstSegmentedFrame
            self.onTheWallLostOrFound = onTheWallLostOrFound
        }
    }

    func endTheSession() {
        lock.withLock {
            onFirstSegmentedFrame = nil
            onTheWallLostOrFound = nil
        }
    }

    func process(_ cameraFrame: CVPixelBuffer) {
        let firstFrameCallback: (@Sendable () -> Void)? = lock.withLock {
            defer { onFirstSegmentedFrame = nil }
            return onFirstSegmentedFrame
        }
        if let firstFrameCallback { DispatchQueue.main.async { firstFrameCallback() } }
    }

    func takeAKeyframe(anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe? {
        lock.withLock { recordedKeyframeAnchors.append(anchorInCameraPixels) }
        return RoomArtKeyframe(
            wallRequest: RoomWallRequest(keyframeJPEGData: Data([1]), personMaskPNGData: Data([2]), anchor: anchorInCameraPixels ?? Self.bareWallSpot),
            wallLight: .neutral
        )
    }

    func showTheArt(_ flattenedArt: CGImage, keyframeCorners: RoomArtCorners) {
        lock.withLock { recordedArtHungCount += 1 }
    }

    func putBackTheArtFromBeforeTheMove() {
        lock.withLock { recordedArtPutBackCount += 1 }
    }

    func currentLoop() -> RoomArtLoopSnapshot? {
        lock.withLock { latestLoop }
    }

    func setTheLoop(_ loop: RoomArtLoopSnapshot?) {
        lock.withLock { latestLoop = loop }
    }

    /// The tracker lost the room (true) or found it again (false), reported on the main actor as the real processor does.
    func reportTheWall(lost wallIsLost: Bool) {
        guard let onTheWallLostOrFound = lock.withLock({ onTheWallLostOrFound }) else { return }
        DispatchQueue.main.async { onTheWallLostOrFound(wallIsLost) }
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

/// The Worker's two routes, answered from the test, with what each received.
@MainActor
private final class WorkerStub {
    var pageReading: Result<RoomArtPageReading, Error> = .success(.wallArt(RoomArtWallArtReading(
        title: "Water Lilies print",
        chosenSize: RoomArtSize(label: "16x20 in", widthCentimeters: 40.6, heightCentimeters: 50.8),
        chosenSizeIncludesFrame: false,
        whyThisSize: "It is the size selected on the page.",
        otherSizes: [],
        artworkCorners: RoomArtCorners(topLeft: CGPoint(x: 20, y: 25), topRight: CGPoint(x: 380, y: 25), bottomRight: CGPoint(x: 380, y: 475), bottomLeft: CGPoint(x: 20, y: 475))
    )))
    var wallReply: Result<WallPlane, Error> = .success(WallPlane(
        center: SIMD3(-0.3, -0.2, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 500,
        principalPoint: SIMD2(320, 180), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
    ))
    var secondsBeforeTheWallReplies = 0.0
    private(set) var pageRequests: [RoomArtPageRequest] = []
    private(set) var wallRequests: [RoomWallRequest] = []
    /// The page was being read before the wall replied, which only happens when the two run at once.
    private(set) var thePageWasAskedForBeforeTheWallReplied = false

    func readThePage(_ pageRequest: RoomArtPageRequest) async throws -> RoomArtPageReading {
        pageRequests.append(pageRequest)
        // The page reply waits up to 2 seconds for the wall request, so a flow that read the page first and only then
        // measured the wall never has the page asked for before the wall replied.
        _ = await conditionHolds(withinSeconds: 10) { !self.wallRequests.isEmpty }
        return try pageReading.get()
    }

    func measureTheWall(_ wallRequest: RoomWallRequest) async throws -> WallPlane {
        wallRequests.append(wallRequest)
        if await conditionHolds(withinSeconds: 10, { !self.pageRequests.isEmpty }) { thePageWasAskedForBeforeTheWallReplied = true }
        if secondsBeforeTheWallReplies > 0 {
            try await Task.sleep(for: .seconds(secondsBeforeTheWallReplies))
        }
        return try wallReply.get()
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
}

@MainActor
private struct RoomArtHarness {
    let controller: RoomArtPreviewController
    let panel: RecordingPanel
    let worker: WorkerStub
    let camera: SyntheticRoomCamera
    let frameProcessor: StandInFrameProcessor
    let recorder: HarnessRecorder

    /// The stub Worker is made here, not as a default argument, since a default argument is not on the main actor.
    init(
        picture: RoomArtPicture? = pictureJPEG(),
        camera: SyntheticRoomCamera = SyntheticRoomCamera(),
        worker givenWorker: WorkerStub? = nil,
        frontTab: RoomArtFrontTab? = storePageTab,
        appSecretIsSet: Bool = true,
        secondsToCaptureThePicture: Double = 0
    ) {
        let worker = givenWorker ?? WorkerStub()
        let panel = RecordingPanel()
        let recorder = HarnessRecorder()
        let frameProcessor = StandInFrameProcessor()
        controller = RoomArtPreviewController(
            environment: RoomArtPreviewController.Environment(
                appSecretIsSet: { appSecretIsSet },
                readTheFrontTab: { frontTab },
                capturePicture: {
                    recorder.pictureCaptureStarted = true
                    if secondsToCaptureThePicture > 0 { try? await Task.sleep(for: .seconds(secondsToCaptureThePicture)) }
                    return picture
                },
                readThePage: { pageRequest in try await worker.readThePage(pageRequest) },
                measureTheWall: { wallRequest in try await worker.measureTheWall(wallRequest) },
                makeFrameSource: { camera },
                clearTheLiveScene: { recorder.timesTheSceneWasClearedBeforeThePanel.append(panel.timesShown) },
                speak: { line, isAFailure in
                    recorder.spokenLines.append(line)
                    recorder.spokenLineFailureFlags.append(isAFailure)
                },
                loopAccentColor: { .orange },
                endTheSpokenLine: { recorder.timesTheSpokenLineWasEnded += 1 }
            ),
            frameProcessor: frameProcessor,
            panelPresenter: panel
        )
        self.panel = panel
        self.worker = worker
        self.camera = camera
        self.frameProcessor = frameProcessor
        self.recorder = recorder
    }

    func spokenLines() -> [String] { recorder.spokenLines }

    func artIsShowing() -> Bool {
        if case .showing = controller.phase { return true }
        return false
    }
}

// The longest wait inside a test is 120 s, so a regression that stalls every flow fails here, minutes before CI's 30 minute job limit.
@Suite(.timeLimit(.minutes(3)))
@MainActor
struct RoomArtPreviewControllerTests {
    @Test func theArtShowsOnceThePageAndTheWallAreReadTogether() async throws {
        let harness = RoomArtHarness()

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        #expect(harness.panel.timesShown == 1)
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }

        #expect(harness.spokenLines() == ["Here it is at 16 by 20 inches."])
        #expect(harness.controller.phase.statusLine == "On your wall at 16 by 20 inches")
        #expect(harness.frameProcessor.artHungCount == 1)
        // A scene or pop-out on screen is cleared once, before the panel shows over it.
        #expect(harness.recorder.timesTheSceneWasClearedBeforeThePanel == [0])
        #expect(harness.worker.thePageWasAskedForBeforeTheWallReplied)
        let pageRequest = try #require(harness.worker.pageRequests.first)
        #expect(pageRequest.pageURL == "https://shop.example/water-lilies")
        // The learner's words go to the Worker, so it knows which item on the page they mean.
        #expect(pageRequest.learnerRequest == whatTheLearnerSaid)
        // The first keyframe has no anchor, so the art centers on the bare wall spot.
        #expect(harness.frameProcessor.keyframeAnchors == [nil])
        #expect(harness.worker.wallRequests.first?.anchor == StandInFrameProcessor.bareWallSpot)

        harness.controller.close()
        #expect(harness.controller.phase == .closed)
        #expect(harness.panel.timesHidden == 1)
        #expect(!harness.camera.isDeliveringFrames)
    }

    @Test func aClickMovesTheArtWithANewWallMeasurementAndIsIgnoredWhileOneRuns() async throws {
        let harness = RoomArtHarness()
        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the art to show on the wall") { harness.artIsShowing() }
        harness.worker.secondsBeforeTheWallReplies = 0.3

        harness.controller.moveTheArt(toCameraPixel: CGPoint(x: 150, y: 120))
        // A second click during that measurement is ignored.
        harness.controller.moveTheArt(toCameraPixel: CGPoint(x: 500, y: 300))
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

        harness.controller.moveTheArt(toCameraPixel: CGPoint(x: 150, y: 120))

        try await waitFor("the move to fail back onto the first wall") {
            guard case .showing(_, let wall, moveFailure: .wallNotMeasured) = harness.controller.phase else { return false }
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

        harness.frameProcessor.reportTheWall(lost: true)
        try await waitFor("the controller to hear the wall is lost") { harness.controller.theWallIsLost }
        #expect(harness.controller.phase.statusLine(theWallIsLost: harness.controller.theWallIsLost) == "Lost the wall. Turn back, or click the wall to place it again.")

        harness.frameProcessor.reportTheWall(lost: false)
        try await waitFor("the controller to hear the wall is found") { !harness.controller.theWallIsLost }
        #expect(harness.controller.phase.statusLine(theWallIsLost: harness.controller.theWallIsLost) == "On your wall at 16 by 20 inches")
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

        #expect(harness.spokenLines() == ["I couldn't read the size from that page."])
        #expect(harness.panel.timesShown == 0)
        #expect(harness.worker.pageRequests.isEmpty && harness.worker.wallRequests.isEmpty)
    }

    @Test func aPageThatStatesNoSizeSaysSoInsteadOfHangingAGuess() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(.sizeNotOnThePage(title: "Water Lilies print"))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        try await waitFor("the panel to fail with no size on the page") { harness.controller.phase == .failed(.sizeNotOnThePage) }
        #expect(harness.spokenLines() == ["I couldn't find the size on that page."])
        harness.controller.close()
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
        #expect(harness.spokenLines() == ["I couldn't measure your wall. Is the depth service running?"])
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

    @Test func anItemThatIsNeitherWallArtNorFurnitureNorClothingSaysItDoesNotHang() async throws {
        let worker = WorkerStub()
        worker.pageReading = .success(.other(title: "Brass lamp"))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)

        try await waitFor("the panel to fail on an item that does not hang") { harness.controller.phase == .failed(.notWallArt) }
        #expect(harness.spokenLines() == ["That doesn't look like something that hangs on a wall."])
        harness.controller.close()
    }

    @Test func furnitureAndClothingSayOnlyWallArtWorksSoFar() async throws {
        let pictureCorners = RoomArtCorners(topLeft: CGPoint(x: 20, y: 25), topRight: CGPoint(x: 380, y: 25), bottomRight: CGPoint(x: 380, y: 475), bottomLeft: CGPoint(x: 20, y: 475))
        let furniture = RoomArtPageReading.furniture(RoomArtFurnitureReading(title: "Blue sofa", chosenSize: nil, whyThisSize: "No size on the page.", itemCorners: pictureCorners))
        let clothing = RoomArtPageReading.clothing(RoomArtClothingReading(
            title: "Great Wave tee", garment: .tshirt, sleeves: .short, chosenSizeLabel: "M", photoShows: .flatLay,
            printDescription: "", whyThisSize: "M is selected.", itemCorners: pictureCorners
        ))
        for pageReading in [furniture, clothing] {
            let worker = WorkerStub()
            worker.pageReading = .success(pageReading)
            let harness = RoomArtHarness(worker: worker)

            await harness.controller.showTheArtInTheRoom(learnerRequest: "how would this chair look in my room")

            try await waitFor("the panel to fail on an item that is not wall art yet") { harness.controller.phase == .failed(.onlyWallArtSoFar) }
            #expect(harness.spokenLines() == ["I can hang wall art so far. Furniture and clothes are coming next."])
            harness.controller.close()
        }
    }

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
        let furnitureWorker = WorkerStub()
        furnitureWorker.pageReading = .success(.other(title: "Brass lamp"))
        let measuredFailureHarness = RoomArtHarness(worker: furnitureWorker)
        await measuredFailureHarness.controller.showTheArtInTheRoom(learnerRequest: whatTheLearnerSaid)
        try await waitFor("the panel to fail on an item that does not hang") { measuredFailureHarness.controller.phase == .failed(.notWallArt) }

        for failureHarness in [noSecretHarness, httpHarness, noTextHarness, noTabHarness, noPictureHarness, cameraHarness, measuredFailureHarness] {
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
        harness.controller.moveTheArt(toCameraPixel: CGPoint(x: 100, y: 100))
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

        let keyframeCorners = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 250), frameSize: CGSize(width: 1280, height: 720))
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
        #expect(ContinuousClock.now - secondRequestStartedAt < .seconds(5))
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
        #expect(ContinuousClock.now - escapePressedAt < .seconds(5))
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
