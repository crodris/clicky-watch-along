//
//  RoomArtStageCostTests.swift
//  leanring-buddyTests
//
//  Prints the CPU time of each per-frame stage of the room art panel, which a busy machine distorts much less than wall
//  time. It runs only when ROOM_ART_STAGE_COSTS is set:
//  ROOM_ART_STAGE_COSTS=1 tools/swift-check.sh --filter RoomArtStageCost
//

import CoreVideo
import Foundation
import Testing
@testable import Clicky

private func threadCPUMilliseconds() -> Double {
    var time = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
    return Double(time.tv_sec) * 1000 + Double(time.tv_nsec) / 1_000_000
}

private func averageCPUMilliseconds(repeating repeatCount: Int, _ work: () -> Void) -> Double {
    let started = threadCPUMilliseconds()
    for _ in 0..<repeatCount { work() }
    return (threadCPUMilliseconds() - started) / Double(repeatCount)
}

struct RoomArtStageCostTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ROOM_ART_STAGE_COSTS"] != nil))
    func printTheCPUTimeOfEachStage() throws {
        var cameraFrameReference: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, roomCameraPixelFormat, [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &cameraFrameReference)
        let cameraFrame = try #require(cameraFrameReference)
        var maskReference: CVPixelBuffer?
        CVPixelBufferCreate(nil, 512, 384, kCVPixelFormatType_OneComponent8, nil, &maskReference)
        let personMask = try #require(maskReference)
        let (trackWidth, trackHeight) = trackSize(forFrameWidth: 1280, frameHeight: 720)

        let grayscaleMilliseconds = averageCPUMilliseconds(repeating: 50) {
            _ = RoomGrayscaleImage(width: trackWidth, height: trackHeight, pixels: trackGrayscalePixels(of: cameraFrame, width: trackWidth, height: trackHeight))
        }
        let maskMilliseconds = averageCPUMilliseconds(repeating: 50) {
            _ = roomMaskAtTrackSize(segmentationConfidence: firstPlaneScaled(of: personMask, toWidth: trackWidth, height: trackHeight), width: trackWidth, height: trackHeight)
        }
        var pixels = [Float](repeating: 0, count: trackWidth * trackHeight)
        for index in pixels.indices { pixels[index] = Float(100 + 60 * sin(Double(index % trackWidth) / 9) * cos(Double(index / trackWidth) / 13)) }
        let grayscale = RoomGrayscaleImage(width: trackWidth, height: trackHeight, pixels: pixels)
        let allRoom = [Float](repeating: 1, count: pixels.count)
        let tracker = RoomTracker(keyframeGrayscale: grayscale, keyframeRoomMask: allRoom)
        let trackMilliseconds = averageCPUMilliseconds(repeating: 20) {
            _ = tracker.track(currentGrayscale: grayscale, currentRoomMask: allRoom)
        }
        let keyframe = RoomECCKeyframe(grayscale: grayscale, roomMask: allRoom)
        let blurred = gaussianBlurredWithFiveTaps(grayscale)
        let oneIterationMilliseconds = averageCPUMilliseconds(repeating: 20) {
            _ = alignedWithECC(keyframe: keyframe, currentBlurred: blurred, currentRoomMask: allRoom, startingWarp: .identity, iterations: 1)
        }
        print(String(
            format: "Room art stage CPU: grayscale %.2f ms, person and room masks %.2f ms, track %.2f ms, one ECC iteration %.2f ms",
            grayscaleMilliseconds, maskMilliseconds, trackMilliseconds, oneIterationMilliseconds
        ))
    }
}
