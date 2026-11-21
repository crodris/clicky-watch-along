//
//  RoomArtPreviewControllerTests.swift
//  leanring-buddyTests
//
//  The whole "show me how this would look in my room" flow through the real frame processor, with synthetic camera frames,
//  a stub Worker, a recorded voice, and a panel that only records being shown, so it needs no camera, window, or network.
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
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

/// A camera that shows one textured room frame 30 times a second, or fails to start.
nonisolated private final class SyntheticRoomCamera: RoomFrameSource, @unchecked Sendable {
    private let startFailure: RoomCameraError?
    private var frameTimer: DispatchSourceTimer?

    init(startFailure: RoomCameraError? = nil) {
        self.startFailure = startFailure
    }

    func start(deliveringFramesOn deliveryQueue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws {
        if let startFailure { throw startFailure }
        let roomFrame = Self.makeRoomFrame(width: 640, height: 360)
        let frameTimer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        frameTimer.schedule(deadline: .now(), repeating: 1.0 / 30)
        frameTimer.setEventHandler { onFrame(roomFrame) }
        self.frameTimer = frameTimer
        frameTimer.resume()
    }

    func stop() {
        frameTimer?.cancel()
    }

    static func makeRoomFrame(width: Int, height: Int) -> CVPixelBuffer {
        var pixelBufferReference: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, roomCameraPixelFormat, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &pixelBufferReference)
        let pixelBuffer = pixelBufferReference!
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let lumaRowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            for column in 0..<width {
                // A plain wall with a shelf and a lamp on the right.
                var brightness = 200 + 10 * sin(Double(column) / 40) * cos(Double(row) / 30)
                if column > 470 && column < 600 && row > 180 && row < 200 { brightness = 60 }
                if column > 520 && column < 540 && row > 60 && row < 180 { brightness = 90 }
                luma[row * lumaRowBytes + column] = UInt8(brightness)
            }
        }
        let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
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
        // The page reply waits for the wall request, so a flow that read the page first and only then measured the wall
        // would never get here with a wall request.
        _ = await waitUntil { !self.wallRequests.isEmpty }
        return try pageReading.get()
    }

    func measureTheWall(_ wallRequest: RoomWallRequest) async throws -> WallPlane {
        wallRequests.append(wallRequest)
        thePageWasAskedForBeforeTheWallReplied = await waitUntil(seconds: 2) { !self.pageRequests.isEmpty } || thePageWasAskedForBeforeTheWallReplied
        if secondsBeforeTheWallReplies > 0 {
            try await Task.sleep(for: .seconds(secondsBeforeTheWallReplies))
        }
        return try wallReply.get()
    }
}

@MainActor
private func waitUntil(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
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

@MainActor
private struct RoomArtHarness {
    let controller: RoomArtPreviewController
    let panel: RecordingPanel
    let worker: WorkerStub
    let spokenLines: () -> [String]

    /// The stub Worker is made here, not as a default argument, since a default argument is not on the main actor.
    init(picture: RoomArtPicture? = pictureJPEG(), camera: SyntheticRoomCamera = SyntheticRoomCamera(), worker givenWorker: WorkerStub? = nil) {
        let worker = givenWorker ?? WorkerStub()
        let panel = RecordingPanel()
        let spokenLinesBox = SpokenLines()
        controller = RoomArtPreviewController(
            environment: RoomArtPreviewController.Environment(
                readTheFrontTab: { RoomArtFrontTab(url: "https://shop.example/water-lilies", title: "Water Lilies print", text: "Sizes: 8x10 in, 16x20 in") },
                capturePicture: { picture },
                readThePage: { pageRequest in try await worker.readThePage(pageRequest) },
                measureTheWall: { wallRequest in try await worker.measureTheWall(wallRequest) },
                makeFrameSource: { camera },
                speak: { line in spokenLinesBox.lines.append(line) }
            ),
            panelPresenter: panel
        )
        self.panel = panel
        self.worker = worker
        self.spokenLines = { spokenLinesBox.lines }
    }
}

@MainActor
private final class SpokenLines {
    var lines: [String] = []
}

@MainActor
struct RoomArtPreviewControllerTests {
    @Test func theArtShowsOnceThePageAndTheWallAreReadTogether() async throws {
        let harness = RoomArtHarness()

        await harness.controller.showTheArtInTheRoom()
        #expect(harness.panel.timesShown == 1)
        #expect(await waitUntil { if case .showing = harness.controller.phase { return true } else { return false } })

        #expect(harness.spokenLines() == ["Here it is at 16x20 in."])
        #expect(harness.controller.phase.statusLine == "On your wall at 16x20 in")
        #expect(harness.worker.thePageWasAskedForBeforeTheWallReplied)
        let pageRequest = try #require(harness.worker.pageRequests.first)
        #expect(pageRequest.pageURL == "https://shop.example/water-lilies")
        let wallRequest = try #require(harness.worker.wallRequests.first)
        // The keyframe is the camera's own frame, at its full size.
        let keyframeSource = try #require(CGImageSourceCreateWithData(wallRequest.keyframeJPEGData as CFData, nil))
        let keyframeImage = try #require(CGImageSourceCreateImageAtIndex(keyframeSource, 0, nil))
        #expect(keyframeImage.width == 640 && keyframeImage.height == 360)
        #expect(CGImageSourceCreateWithData(wallRequest.personMaskPNGData as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
        // The bare wall spot is on the plain wall, left of the shelf and lamp, in the upper part of the frame.
        #expect(wallRequest.anchor.x < 470 && wallRequest.anchor.y > 60 && wallRequest.anchor.y < 220)

        harness.controller.close()
        #expect(harness.controller.phase == .closed)
        #expect(harness.panel.timesHidden == 1)
    }

    @Test func aClickMovesTheArtWithANewWallMeasurementAndIsIgnoredWhileOneRuns() async throws {
        let harness = RoomArtHarness()
        await harness.controller.showTheArtInTheRoom()
        #expect(await waitUntil { if case .showing = harness.controller.phase { return true } else { return false } })
        harness.worker.secondsBeforeTheWallReplies = 0.3

        harness.controller.moveTheArt(toCameraPixel: CGPoint(x: 150, y: 120))
        // A second click during that measurement is ignored.
        harness.controller.moveTheArt(toCameraPixel: CGPoint(x: 500, y: 300))
        #expect(await waitUntil { harness.worker.wallRequests.count == 2 })
        #expect(await waitUntil { if case .showing = harness.controller.phase { return true } else { return false } })

        #expect(harness.worker.wallRequests.count == 2)
        #expect(harness.worker.wallRequests.last?.anchor == CGPoint(x: 150, y: 120))
        // The page was read once, and "Here it is" is said once.
        #expect(harness.worker.pageRequests.count == 1)
        #expect(harness.spokenLines() == ["Here it is at 16x20 in."])
        harness.controller.close()
    }

    @Test func aWallReplyAfterThePanelClosedIsDropped() async throws {
        let worker = WorkerStub()
        worker.secondsBeforeTheWallReplies = 0.4
        let harness = RoomArtHarness(worker: worker)
        await harness.controller.showTheArtInTheRoom()
        #expect(await waitUntil { !worker.wallRequests.isEmpty })

        harness.controller.close()
        try await Task.sleep(for: .seconds(0.8))

        #expect(harness.controller.phase == .closed)
        #expect(harness.spokenLines().isEmpty)
    }

    @Test func noPictureSaysSoAndOpensNothing() async {
        let harness = RoomArtHarness(picture: nil)

        await harness.controller.showTheArtInTheRoom()

        #expect(harness.spokenLines() == ["I don't see a picture in Chrome's front tab."])
        #expect(harness.panel.timesShown == 0)
        #expect(harness.controller.phase == .closed)
    }

    @Test func aDepthServiceThatIsDownAsksWhetherItRuns() async {
        let worker = WorkerStub()
        worker.wallReply = .failure(RoomArtWorkerError.workerReturned(statusCode: 502, body: #"{"error":"The depth service is not answering"}"#))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom()

        #expect(await waitUntil { harness.controller.phase == .failed(.depthServiceUnavailable) })
        #expect(harness.spokenLines() == ["I couldn't measure your wall. Is the depth service running?"])
        harness.controller.close()
    }

    @Test func artThatDoesNotHangOnAWallSaysSo() async {
        let worker = WorkerStub()
        worker.pageReading = .success(.notWallArt(title: "Blue sofa"))
        let harness = RoomArtHarness(worker: worker)

        await harness.controller.showTheArtInTheRoom()

        #expect(await waitUntil { harness.controller.phase == .failed(.notWallArt) })
        #expect(harness.spokenLines() == ["That doesn't look like something that hangs on a wall."])
        harness.controller.close()
    }

    @Test func aRefusedCameraAsksForAccess() async {
        let harness = RoomArtHarness(camera: SyntheticRoomCamera(startFailure: .cameraAccessDenied))

        await harness.controller.showTheArtInTheRoom()

        #expect(harness.controller.phase == .failed(.cameraAccessDenied))
        #expect(harness.spokenLines() == ["I need camera access for that. You can turn it on in System Settings."])
        #expect(harness.worker.wallRequests.isEmpty)
        harness.controller.close()
    }

    @Test func escapeClosesAnOpenPanelAndNothingElse() async {
        let harness = RoomArtHarness()
        #expect(!harness.controller.closeOnEscape())

        await harness.controller.showTheArtInTheRoom()

        #expect(harness.controller.closeOnEscape())
        #expect(harness.controller.phase == .closed)
        #expect(harness.panel.timesHidden == 1)
    }
}
