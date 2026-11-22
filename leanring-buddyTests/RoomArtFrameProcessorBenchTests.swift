//
//  RoomArtFrameProcessorBenchTests.swift
//  leanring-buddyTests
//
//  Plays a video through the room art frame processor, the way `--room-camera-file` does in the app, with art hung at the
//  bare wall spot, checks the keyframe it sends the depth service, and prints the processor's own "Room art: N fps" lines. It runs only when ROOM_ART_VIDEO names a video:
//  ROOM_ART_VIDEO=/path/pan.mp4 [ROOM_ART_IMAGE=/path/art.jpg] [ROOM_ART_SNAPSHOT_DIR=/path/out] \
//    tools/swift-check.sh --filter RoomArtFrameProcessorBench
//  ROOM_ART_SNAPSHOT_DIR saves a frame as the panel drew it every 2 seconds, so the art can be checked by eye.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clicky

private let benchEnvironment = ProcessInfo.processInfo.environment

struct RoomArtFrameProcessorBenchTests {
    @Test(.enabled(if: benchEnvironment["ROOM_ART_VIDEO"] != nil, "Set ROOM_ART_VIDEO to a video file"))
    func theProcessorHoldsTheFrameRateWithTheArtOnTheWall() async throws {
        let frameProcessor = RoomArtFrameProcessor()
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        let frameSource = LoopingVideoFileRoomCamera(videoFileURL: URL(fileURLWithPath: try #require(benchEnvironment["ROOM_ART_VIDEO"])))
        try await frameSource.start(deliveringFramesOn: frameProcessor.processingQueue) { cameraFrame in
            frameProcessor.process(cameraFrame)
        }
        defer { frameSource.stop() }
        try await Task.sleep(for: .seconds(1))

        let keyframe = try #require(await frameProcessor.takeAKeyframe(on: .wall, anchorInCameraPixels: nil))
        // The keyframe is a JPEG of the video's own frame with a mask the depth service can read, and the bare wall spot
        // lies inside it. The controller's tests use a stand-in processor, so this is where the real keyframe is checked.
        let keyframeSource = try #require(CGImageSourceCreateWithData(keyframe.measurementRequest.keyframeJPEGData as CFData, nil))
        let keyframeImage = try #require(CGImageSourceCreateImageAtIndex(keyframeSource, 0, nil))
        #expect(CGImageSourceCreateWithData(keyframe.measurementRequest.personMaskPNGData as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
        let anchor = keyframe.measurementRequest.anchor
        #expect(anchor.x > 0 && anchor.x < Double(keyframeImage.width) && anchor.y > 0 && anchor.y < Double(keyframeImage.height))
        print("Room art bench: bare wall spot (\(Int(anchor.x)), \(Int(anchor.y))), wall light \(keyframe.wallLight)")
        // A 16 by 20 inch print 2 meters from a camera with a 1000 pixel focal length.
        let wallFacingTheCamera = WallPlane(
            center: SIMD3((anchor.x - 640) * 2 / 1000, (anchor.y - 360) * 2 / 1000, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0),
            focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 1
        )
        let keyframeCorners = try #require(wallFacingTheCamera.keyframeCorners(widthMeters: 0.406, heightMeters: 0.508))
        frameProcessor.showTheItem(try artImage(), keyframeCorners: keyframeCorners, on: .wall)

        let snapshotFolder = benchEnvironment["ROOM_ART_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for snapshotNumber in 0..<6 {
            try await Task.sleep(for: .seconds(2))
            if let snapshotFolder, let frameImage = frameProcessor.renderTheLastFrame() {
                try savePNG(frameImage, to: snapshotFolder.appendingPathComponent("room-art-\(snapshotNumber).png"))
            }
        }
        let frameRateReport = try #require(frameProcessor.lastLoggedFrameRate())
        print("Room art bench: \(frameRateReport.logLine)")
        #expect(frameRateReport.framesPerSecond >= 24)
    }

    /// ROOM_ART_IMAGE, or a striped stand-in with a dark border.
    private func artImage() throws -> CGImage {
        if let artImagePath = benchEnvironment["ROOM_ART_IMAGE"],
           let imageSource = CGImageSourceCreateWithURL(URL(fileURLWithPath: artImagePath) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
            return image
        }
        let context = try #require(CGContext(data: nil, width: 400, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        for stripe in 0..<8 {
            context.setFillColor(CGColor(red: 0.9, green: 0.5 + Double(stripe) * 0.05, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 30, y: 30 + stripe * 55, width: 340, height: 30))
        }
        return try #require(context.makeImage())
    }

    private func savePNG(_ image: CGImage, to fileURL: URL) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try #require(CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
