//
//  RoomTrackerFakeCameraTests.swift
//  leanring-buddyTests
//
//  Measures the tracker on a recorded pan whose true motion is known: a folder of 1280 by 720 frames (0000.png, 0001.png, ...)
//  and truth.npy, one 3x3 matrix per frame that maps the source photo to that frame. It runs only when ROOM_ART_FAKECAM_DIR
//  names that folder, and prints the corner error and the milliseconds per frame:
//  ROOM_ART_FAKECAM_DIR=/path/to/fakecam tools/swift-check.sh --filter RoomTrackerFakeCamera
//

import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Testing
import Vision
import simd
@testable import Clicky

private let fakeCameraFolder = ProcessInfo.processInfo.environment["ROOM_ART_FAKECAM_DIR"]

/// The matrices in a float64 .npy file, row by row.
private func truthMatrices(npyFile: URL) throws -> [simd_double3x3] {
    let fileData = try Data(contentsOf: npyFile)
    // Version 1 files keep the header length as a little-endian UInt16 at byte 8, and the data starts after it.
    let headerLength = Int(fileData[8]) | Int(fileData[9]) << 8
    let values = fileData.dropFirst(10 + headerLength).withUnsafeBytes { rawBytes in
        Array(rawBytes.bindMemory(to: Double.self))
    }
    return stride(from: 0, to: values.count, by: 9).map { start in
        simd_double3x3(rows: [
            SIMD3(values[start], values[start + 1], values[start + 2]),
            SIMD3(values[start + 3], values[start + 4], values[start + 5]),
            SIMD3(values[start + 6], values[start + 7], values[start + 8]),
        ])
    }
}

private func applying(_ homography: simd_double3x3, to point: CGPoint) -> CGPoint {
    let mapped = homography * SIMD3(point.x, point.y, 1)
    return CGPoint(x: mapped.x / mapped.z, y: mapped.y / mapped.z)
}

private func grayscaleAtTrackSize(_ frameImage: CGImage, width: Int, height: Int) -> RoomGrayscaleImage {
    var bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeMutableBytes { bytesPointer in
        let context = CGContext(data: bytesPointer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.interpolationQuality = .high
        context?.draw(frameImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return RoomGrayscaleImage(width: width, height: height, pixels: bytes.map(Float.init))
}

struct RoomTrackerFakeCameraTests {
    @Test(.enabled(if: fakeCameraFolder != nil, "Set ROOM_ART_FAKECAM_DIR to a folder of frames and truth.npy"))
    func trackerFollowsARecordedPan() throws {
        let folder = URL(fileURLWithPath: try #require(fakeCameraFolder))
        let truth = try truthMatrices(npyFile: folder.appendingPathComponent("truth.npy"))
        let (trackWidth, trackHeight) = trackSize(forFrameWidth: 1280, frameHeight: 720)
        let cameraPixelsPerTrackPixel = 1280.0 / Double(trackWidth)
        let segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let sequenceHandler = VNSequenceRequestHandler()

        // An art-sized quad on the wall in the first frame, in camera pixels.
        let artCorners = [CGPoint(x: 140, y: 120), CGPoint(x: 460, y: 120), CGPoint(x: 460, y: 360), CGPoint(x: 140, y: 360)]
        var tracker: RoomTracker?
        var cornerErrors: [Double] = []
        var trackMilliseconds: [Double] = []
        var segmentMilliseconds: [Double] = []
        var lostFrameCount = 0
        let firstFrameInverse = truth[0].inverse

        for frameIndex in 0..<truth.count {
            let frameURL = folder.appendingPathComponent(String(format: "%04d.png", frameIndex))
            guard let imageSource = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
                  let frameImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { break }

            let segmentStarted = Date()
            try sequenceHandler.perform([segmentationRequest], on: frameImage)
            let maskBuffer = try #require(segmentationRequest.results?.first?.pixelBuffer)
            let trackRoomMask = roomMaskAtTrackSize(
                segmentationConfidence: firstPlaneScaled(of: maskBuffer, toWidth: trackWidth, height: trackHeight),
                width: trackWidth,
                height: trackHeight
            )
            segmentMilliseconds.append(Date().timeIntervalSince(segmentStarted) * 1000)

            let grayscale = grayscaleAtTrackSize(frameImage, width: trackWidth, height: trackHeight)
            guard let tracker else {
                tracker = RoomTracker(keyframeGrayscale: grayscale, keyframeRoomMask: trackRoomMask)
                continue
            }
            let trackStarted = Date()
            let trackStep = tracker.track(currentGrayscale: grayscale, currentRoomMask: trackRoomMask)
            trackMilliseconds.append(Date().timeIntervalSince(trackStarted) * 1000)
            if trackStep.framesLostInARow > 0 { lostFrameCount += 1 }

            // The truth from the first frame to this one: back to the photo, then out to this frame.
            let keyframeToThisFrame = truth[frameIndex] * firstFrameInverse
            let cameraWarp = trackStep.warp.scaled(by: cameraPixelsPerTrackPixel)
            let frameError = artCorners.map { corner in
                let found = cameraWarp.apply(to: corner), expected = applying(keyframeToThisFrame, to: corner)
                return hypot(found.x - expected.x, found.y - expected.y)
            }.max() ?? 0
            cornerErrors.append(frameError)
            if ProcessInfo.processInfo.environment["ROOM_ART_FAKECAM_VERBOSE"] != nil, frameIndex % 20 == 0 {
                let affinePart = simd_double2x2(rows: [SIMD2(keyframeToThisFrame[0][0], keyframeToThisFrame[1][0]), SIMD2(keyframeToThisFrame[0][1], keyframeToThisFrame[1][1])])
                print(String(format: "frame %d error %.2f correlation %.3f warp angle %.3f deg t (%.1f, %.1f) truth scale %.4f perspective (%.2e, %.2e)", frameIndex, frameError, trackStep.correlation, cameraWarp.angleRadians * 180 / .pi, cameraWarp.translationX, cameraWarp.translationY, sqrt(abs(affinePart.determinant)) / keyframeToThisFrame[2][2], keyframeToThisFrame[0][2], keyframeToThisFrame[1][2]))
            }
        }

        let sortedErrors = cornerErrors.sorted()
        let medianError = sortedErrors[sortedErrors.count / 2]
        let meanTrackMilliseconds = trackMilliseconds.reduce(0, +) / Double(trackMilliseconds.count)
        let meanSegmentMilliseconds = segmentMilliseconds.reduce(0, +) / Double(segmentMilliseconds.count)
        print(String(
            format: "Room art fake camera: %d frames, corner error median %.2f px, 95th %.2f px, max %.2f px (camera pixels), lost %d frames, track %.1f ms, segment %.1f ms",
            cornerErrors.count, medianError, sortedErrors[sortedErrors.count * 95 / 100], sortedErrors.last ?? 0, lostFrameCount, meanTrackMilliseconds, meanSegmentMilliseconds
        ))
        #expect(medianError < 8)
    }
}
