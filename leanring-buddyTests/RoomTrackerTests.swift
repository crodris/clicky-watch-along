//
//  RoomTrackerTests.swift
//  leanring-buddyTests
//
//  The ECC aligner and the tracker on synthetic rooms whose true motion is known.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

private let trackWidth = 320
private let trackHeight = 180

/// Soft shapes at fixed places (x, y, radius, brightness), like a lamp, a frame, and a plant, so the room never repeats
/// itself, which a registration could take for another place.
private let roomShapes: [(x: Double, y: Double, radius: Double, brightness: Double)] = [
    (40, 30, 18, 70), (150, 40, 25, -60), (260, 25, 14, 80), (300, 120, 22, -70),
    (90, 140, 20, 60), (200, 150, 16, -80), (130, 95, 12, 90), (240, 85, 28, 50),
]

/// A smooth room texture, like the shading of a wall and the edges of furniture, as a function, so a warped copy is exact.
private func roomTexture(x: Double, y: Double) -> Double {
    let shading = 128 + 20 * sin(x / 9 + 0.3) * cos(y / 13) + 15 * sin((x + 2 * y) / 23)
    let shapes = roomShapes.reduce(0.0) { total, shape in
        let squaredDistance = (x - shape.x) * (x - shape.x) + (y - shape.y) * (y - shape.y)
        return total + shape.brightness * exp(-squaredDistance / (2 * shape.radius * shape.radius))
    }
    // Hard edges, like a door frame, a shelf, and a lamp's pole, which a real room always has somewhere.
    var edges = 0.0
    if x > 60 && x < 110 && y > 20 && y < 90 { edges += 50 }
    if x > 180 && x < 290 && y > 100 && y < 112 { edges -= 60 }
    if x > 215 && x < 228 && y > 10 && y < 170 { edges += 40 }
    return shading + shapes + edges
}

/// A texture that shares nothing with the room's.
private func unrelatedTexture(x: Double, y: Double) -> Double {
    128 + 40 * sin(x / 5.3 + 2) * cos(y / 7.1 + 0.5) + 30 * cos((2 * x - y) / 11)
}

/// What a person looks like to the tracker: bright stripes that move on their own.
private func personTexture(x: Double, y: Double, phase: Double) -> Double {
    sin(x / 3 + phase) > 0 ? 250 : 5
}

private struct SyntheticFrame {
    let grayscale: RoomGrayscaleImage
    let roomMask: [Float]
}

/// The room seen through `warp` (a keyframe point p shows at warp(p)), with a person square covering `personRect`, which the
/// room mask marks with a margin, as the dilated segmentation does.
private func syntheticFrame(warp: EuclideanWarp, personRect: CGRect?, texture: (Double, Double) -> Double = roomTexture, personPhase: Double = 0) -> SyntheticFrame {
    var pixels = [Float](repeating: 0, count: trackWidth * trackHeight)
    var roomMask = [Float](repeating: 1, count: trackWidth * trackHeight)
    let cosine = cos(warp.angleRadians), sine = sin(warp.angleRadians)
    for row in 0..<trackHeight {
        for column in 0..<trackWidth {
            // The inverse warp: the keyframe point that lands on this pixel.
            let shiftedX = Double(column) - warp.translationX, shiftedY = Double(row) - warp.translationY
            let keyframeX = cosine * shiftedX + sine * shiftedY
            let keyframeY = -sine * shiftedX + cosine * shiftedY
            var value = texture(keyframeX, keyframeY)
            let pixelPoint = CGPoint(x: column, y: row)
            if let personRect, personRect.contains(pixelPoint) {
                value = personTexture(x: Double(column), y: Double(row), phase: personPhase)
            }
            if let personRect, personRect.insetBy(dx: -4, dy: -4).contains(pixelPoint) {
                roomMask[row * trackWidth + column] = 0
            }
            pixels[row * trackWidth + column] = Float(value)
        }
    }
    return SyntheticFrame(grayscale: RoomGrayscaleImage(width: trackWidth, height: trackHeight, pixels: pixels), roomMask: roomMask)
}

private let frameCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 319, y: 0), CGPoint(x: 319, y: 179), CGPoint(x: 0, y: 179)]

private func largestCornerError(_ foundWarp: EuclideanWarp, _ trueWarp: EuclideanWarp) -> Double {
    frameCorners.map { corner in
        let found = foundWarp.apply(to: corner), truth = trueWarp.apply(to: corner)
        return hypot(found.x - truth.x, found.y - truth.y)
    }.max() ?? .infinity
}

struct RoomTrackerTests {
    @Test func eccFindsAShiftAndARotationWhileAMaskedSquareMovesOnItsOwn() {
        let trueWarp = EuclideanWarp(angleRadians: 1.5 * .pi / 180, translationX: 6, translationY: -4)
        let keyframe = syntheticFrame(warp: .identity, personRect: CGRect(x: 120, y: 60, width: 60, height: 80), personPhase: 0)
        // The person moved somewhere else and changed, which the tracker must ignore.
        let current = syntheticFrame(warp: trueWarp, personRect: CGRect(x: 170, y: 50, width: 60, height: 90), personPhase: 2)
        let tracker = RoomTracker(keyframeGrayscale: keyframe.grayscale, keyframeRoomMask: keyframe.roomMask)

        let trackStep = tracker.track(currentGrayscale: current.grayscale, currentRoomMask: current.roomMask)

        #expect(trackStep.correlation >= RoomTrackingSettings.goodCorrelation)
        #expect(trackStep.framesLostInARow == 0)
        #expect(largestCornerError(trackStep.warp, trueWarp) < 0.5)
    }

    @Test func eccReportsALowCorrelationOnAnUnrelatedFrame() {
        let keyframe = syntheticFrame(warp: .identity, personRect: nil)
        let unrelated = syntheticFrame(warp: .identity, personRect: nil, texture: unrelatedTexture)
        let tracker = RoomTracker(keyframeGrayscale: keyframe.grayscale, keyframeRoomMask: keyframe.roomMask)

        let trackStep = tracker.track(currentGrayscale: unrelated.grayscale, currentRoomMask: unrelated.roomMask)

        #expect(trackStep.correlation < RoomTrackingSettings.goodCorrelation)
        #expect(trackStep.framesLostInARow == 1)
        // A lost frame keeps the last good warp, so the art does not jump.
        #expect(trackStep.warp == .identity)
    }

    @Test func visionFindsTheRoomsShiftFromTheKeyframe() throws {
        let trueWarp = EuclideanWarp(angleRadians: 0, translationX: 30, translationY: 20)
        let keyframe = syntheticFrame(warp: .identity, personRect: nil)
        let current = syntheticFrame(warp: trueWarp, personRect: nil)

        let keyframeImage = try #require(keyframe.grayscale.cgImage)
        let currentImage = try #require(current.grayscale.cgImage)
        let shift = try #require(translationFromTheKeyframe(keyframeImage: keyframeImage, currentImage: currentImage))

        #expect(abs(shift.dx - 30) <= 1)
        #expect(abs(shift.dy - 20) <= 1)
    }

    @Test func theTrackerFindsTheRoomAgainAfterATurnTooFastForECC() {
        let keyframe = syntheticFrame(warp: .identity, personRect: nil)
        let tracker = RoomTracker(keyframeGrayscale: keyframe.grayscale, keyframeRoomMask: keyframe.roomMask)
        // Half a texture period and more in one frame, which ECC cannot climb from the last warp.
        let fastTurn = EuclideanWarp(angleRadians: 0.5 * .pi / 180, translationX: -90, translationY: 25)
        let turnedFrame = syntheticFrame(warp: fastTurn, personRect: nil)

        var trackSteps: [RoomTrackStep] = []
        for _ in 0..<RoomTrackingSettings.framesLostBeforeRecovery {
            trackSteps.append(tracker.track(currentGrayscale: turnedFrame.grayscale, currentRoomMask: turnedFrame.roomMask))
        }

        let lastStep = trackSteps[trackSteps.count - 1]
        #expect(trackSteps.dropLast().allSatisfy { $0.framesLostInARow > 0 })
        #expect(lastStep.framesLostInARow == 0)
        #expect(largestCornerError(lastStep.warp, fastTurn) < 0.5)
    }

    @Test func theArtHidesOnlyAfterTheRoomIsLostForMoreThanFifteenFrames() {
        #expect(!RoomTrackStep(warp: .identity, correlation: 0, framesLostInARow: 15).theArtIsHidden)
        #expect(RoomTrackStep(warp: .identity, correlation: 0, framesLostInARow: 16).theArtIsHidden)
    }

    @Test func smoothedCornersMoveAThirdOfTheWayEachFrame() {
        let previous = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let current = [CGPoint(x: 100, y: 20), CGPoint(x: 100, y: 0)]

        #expect(smoothedCorners(previous: previous, current: current) == [CGPoint(x: 35, y: 7), CGPoint(x: 100, y: 0)])
        #expect(smoothedCorners(previous: nil, current: current) == current)
    }

    @Test func aScaledWarpMovesCameraPixelsAsTheTrackWarpMovesTrackPixels() {
        let trackWarp = EuclideanWarp(angleRadians: 0.02, translationX: 3, translationY: -2)
        let trackPoint = CGPoint(x: 100, y: 50)
        let cameraPoint = trackWarp.scaled(by: 4).apply(to: CGPoint(x: 400, y: 200))
        let trackResult = trackWarp.apply(to: trackPoint)

        #expect(abs(cameraPoint.x - trackResult.x * 4) < 1e-9)
        #expect(abs(cameraPoint.y - trackResult.y * 4) < 1e-9)
    }
}
