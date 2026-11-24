import CoreImage
import Foundation
import Testing
@testable import Clicky

struct RoomArtLightReferenceTests {
    /// A frame of `width` by `height` in one sRGB color, as RGBA bytes.
    private func frameBytes(width: Int, height: Int, color: [UInt8]) -> [UInt8] {
        (0..<(width * height)).flatMap { _ in color + [255] }
    }

    /// `bytes` with each channel scaled by `gains` in linear light, as a camera's exposure and white balance change it.
    private func relit(_ bytes: [UInt8], by gains: SIMD3<Double>) -> [UInt8] {
        var relitBytes = bytes
        for byteIndex in 0..<bytes.count where byteIndex % 4 != 3 {
            relitBytes[byteIndex] = sRGBByte(ofLinearLight: RoomArtLightReference.linearLight(ofSRGBByte: bytes[byteIndex]) * gains[byteIndex % 4])
        }
        return relitBytes
    }

    private func reference(_ bytes: [UInt8], width: Int, height: Int, personConfidence: [UInt8]? = nil, warp: EuclideanWarp = .identity) -> RoomArtLightReference {
        RoomArtLightReference(width: width, height: height, rgbaBytes: bytes, personConfidence: personConfidence, keyframeToThisFrame: warp)
    }

    /// A wall over a floor, the wall bright enough that a lamp clips it.
    private func wallOverFloor(width: Int, height: Int) -> [UInt8] {
        (0..<(width * height)).flatMap { pixelIndex -> [UInt8] in pixelIndex / width < height / 2 ? [235, 233, 228, 255] : [90, 70, 60, 255] }
    }

    @Test func theGainsAreTheLightChangeInLinearLight() throws {
        let before = wallOverFloor(width: 40, height: 30)
        let gains = try #require(RoomArtLightReference.gains(
            from: reference(before, width: 40, height: 30), to: reference(relit(before, by: SIMD3(1.04, 1.02, 0.97)), width: 40, height: 30)
        ))
        #expect(abs(gains.x - 1.04) < 0.01)
        #expect(abs(gains.y - 1.02) < 0.01)
        #expect(abs(gains.z - 0.97) < 0.01)
    }

    @Test func aWallTheLampClipsIsLeftOutOfBothFrames() throws {
        // The lamp clips the wall in the new frame, so only the floor, unclipped in both, is compared. Each frame measured
        // on its own compared the old wall with the new floor and found the room darker.
        let before = wallOverFloor(width: 40, height: 30)
        let after = relit(before, by: SIMD3(1.5, 1.5, 1.5))
        #expect(after[0] >= RoomArtLightReference.clippedByte)
        let gains = try #require(RoomArtLightReference.gains(from: reference(before, width: 40, height: 30), to: reference(after, width: 40, height: 30)))
        #expect(abs(gains.x - 1.5) < 0.02, "\(gains)")
    }

    @Test func theLearnerInEitherFrameIsLeftOut() throws {
        // The learner, bright red, stands on the left in the old frame and on the right in the new one.
        let width = 20, height = 10
        var before = frameBytes(width: width, height: height, color: [100, 100, 100])
        var after = relit(before, by: SIMD3(1.2, 1.2, 1.2))
        var personBefore = [UInt8](repeating: 0, count: width * height), personAfter = personBefore
        for row in 0..<height {
            for column in 0..<4 {
                before.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 3), with: [240, 30, 30])
                personBefore[row * width + column] = 255
                let rightColumn = width - 1 - column
                after.replaceSubrange(((row * width + rightColumn) * 4)..<((row * width + rightColumn) * 4 + 3), with: [240, 30, 30])
                personAfter[row * width + rightColumn] = 255
            }
        }
        let gains = try #require(RoomArtLightReference.gains(
            from: reference(before, width: width, height: height, personConfidence: personBefore),
            to: reference(after, width: width, height: height, personConfidence: personAfter)
        ))
        #expect(abs(gains.x - 1.2) < 0.01)
        #expect(abs(gains.y - 1.2) < 0.01)
    }

    @Test func eachPixelIsFoundThroughTheTrackersTurn() throws {
        // The camera turned so the room moved 6 pixels left: compared by position, the wall's edge would count as floor.
        let width = 40, height = 30
        let before: [UInt8] = (0..<(width * height)).flatMap { pixelIndex in pixelIndex % width < 20 ? [200, 200, 200, 255] : [40, 40, 40, 255] }
        let movedLeft: [UInt8] = (0..<(width * height)).flatMap { pixelIndex in pixelIndex % width < 14 ? [200, 200, 200, 255] : [40, 40, 40, 255] }
        let after = relit(movedLeft, by: SIMD3(1.1, 1.1, 1.1))
        let gains = try #require(RoomArtLightReference.gains(
            from: reference(before, width: width, height: height),
            to: reference(after, width: width, height: height, warp: EuclideanWarp(angleRadians: 0, translationX: -6, translationY: 0))
        ))
        #expect(abs(gains.x - 1.1) < 0.01, "\(gains)")
    }

    @Test func aBigChangeIsHeldToTheRangeAndADarkChannelIsLeftAlone() throws {
        let before = frameBytes(width: 10, height: 10, color: [10, 100, 0])
        let gains = try #require(RoomArtLightReference.gains(
            from: reference(before, width: 10, height: 10), to: reference(frameBytes(width: 10, height: 10, color: [200, 100, 40]), width: 10, height: 10)
        ))
        #expect(gains.x == RoomArtLightReference.gainRange.upperBound)
        #expect(abs(gains.y - 1) < 1e-9)
        #expect(gains.z == 1)
    }

    @Test func tooLittleSharedRoomMeasuresNothing() {
        let bytes = frameBytes(width: 10, height: 10, color: [100, 100, 100])
        var personConfidence = [UInt8](repeating: 255, count: 100)
        personConfidence[0] = 0
        #expect(RoomArtLightReference.gains(
            from: reference(bytes, width: 10, height: 10, personConfidence: personConfidence), to: reference(bytes, width: 10, height: 10)
        ) == nil)
    }

    @Test func eachMeasurementMovesTheSmoothedGainsPartWay() {
        #expect(RoomArtLightReference.smoothed(previous: nil, measured: SIMD3(1.5, 1.5, 1.5)) == SIMD3(1.5, 1.5, 1.5))
        let once = RoomArtLightReference.smoothed(previous: SIMD3(1, 1, 1), measured: SIMD3(2, 2, 2))
        #expect(abs(once.x - (1 + RoomArtLightReference.smoothingShare)) < 1e-9)
        // Within ten measurements, two seconds at the processor's pace, the gains have nearly reached the new room.
        let settled = (0..<10).reduce(SIMD3<Double>(1, 1, 1)) { gains, _ in RoomArtLightReference.smoothed(previous: gains, measured: SIMD3(2, 2, 2)) }
        #expect(abs(settled.x - 2) < 0.05)
    }

    @Test func eachReferenceInUseKeepsItsOwnSmoothedGains() throws {
        let width = 20, height = 10
        let room = frameBytes(width: width, height: height, color: [100, 100, 100])
        let madeInTheRoom = reference(room, width: width, height: height)
        let madeInADimmerRoom = reference(relit(room, by: SIMD3(0.5, 0.5, 0.5)), width: width, height: height)
        let noLongerShown = reference(room, width: width, height: height)
        // The learner fills this one's frame, so its gains cannot be measured now.
        let hiddenByTheLearner = reference(room, width: width, height: height, personConfidence: [UInt8](repeating: 255, count: width * height))
        let current = reference(relit(room, by: SIMD3(1.2, 1.2, 1.2)), width: width, height: height)
        let gains = RoomArtLightReference.smoothedGainsInUse(
            references: [madeInTheRoom, madeInADimmerRoom, hiddenByTheLearner, madeInTheRoom],
            current: current,
            previous: [ObjectIdentifier(hiddenByTheLearner): SIMD3(1.3, 1.3, 1.3), ObjectIdentifier(noLongerShown): SIMD3(2, 2, 2)]
        )
        #expect(gains.count == 3)
        #expect(abs(try #require(gains[ObjectIdentifier(madeInTheRoom)]).x - 1.2) < 0.02)
        #expect(abs(try #require(gains[ObjectIdentifier(madeInADimmerRoom)]).x - 2.4) < 0.05)
        #expect(gains[ObjectIdentifier(hiddenByTheLearner)] == SIMD3(1.3, 1.3, 1.3))
        #expect(gains[ObjectIdentifier(noLongerShown)] == nil)
    }

    @Test @MainActor func aFurnitureLayerIsDrawnWithItsGains() throws {
        // An opaque gray layer drawn with its light doubled is drawn at twice its linear light.
        let width = 40, height = 30
        let layer = try #require(rgbaImage(frameBytes(width: width, height: height, color: [100, 100, 100]), width: width, height: height))
        let frame = try #require(rgbaImage(frameBytes(width: width, height: height, color: [10, 10, 10]), width: width, height: height))
        let placedArt = RoomArtFrameProcessor.PlacedArt.keyframeLayers(
            RoomFurnitureKeyframeLayers(itemLayer: layer, shadowLayer: nil, basePointInTheKeyframe: CGPoint(x: 20, y: 0), cameraNoiseStandardDeviation: 0, look: .paintedComposite),
            frameSize: CGSize(width: width, height: height),
            layerToKeyframe: .identity,
            roomLightWhenMade: nil
        )
        func drawnByte(lightGains: SIMD3<Double>) throws -> UInt8 {
            let drawn = RoomArtFrameProcessor.frameWithTheArt(
                frameImage: CIImage(cgImage: frame), placedArt: placedArt, artCorners: placedArt.currentCorners(after: .identity),
                personMask: nil, personLowestRowShare: nil, grainOffset: .zero, lightGains: lightGains
            )
            let drawnImage = try #require(CIContext().createCGImage(drawn, from: CGRect(x: 0, y: 0, width: width, height: height)))
            return try #require(rgbaBytes(of: drawnImage, width: width, height: height))[(15 * width + 20) * 4]
        }
        #expect(try drawnByte(lightGains: RoomArtLightReference.unchangedGains) == 100)
        let twiceAsBright = try drawnByte(lightGains: SIMD3(2, 2, 2))
        let expected = sRGBByte(ofLinearLight: RoomArtLightReference.linearLight(ofSRGBByte: 100) * 2)
        #expect(abs(Int(twiceAsBright) - Int(expected)) <= 2, "drawn \(twiceAsBright), expected \(expected)")
    }
}

/// A linear light value as an sRGB byte, clipped to 255.
func sRGBByte(ofLinearLight linear: Double) -> UInt8 {
    let clamped = min(max(linear, 0), 1)
    let encoded = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * pow(clamped, 1 / 2.4) - 0.055
    return UInt8((encoded * 255).rounded())
}
