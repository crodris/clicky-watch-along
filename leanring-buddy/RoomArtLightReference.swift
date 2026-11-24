import Foundation

/// The room's light in one camera frame, kept as a small copy of the frame so another frame's light can be compared with it
/// pixel by pixel. A painted or rendered item keeps the copy of the frame it was made on, and each frame its layer is scaled
/// by how the room's light changed since (`gains(from:to:)`), so a light turned on, or the camera's exposure or white
/// balance moving, changes the piece and its soft edge as it changes the room around them.
///
/// The two frames are compared pixel by pixel through the tracker's turn, and only where both show the room unclipped: a
/// mean of each frame on its own counted different pixels whenever a lamp pushed the bright wall to clipping in one frame,
/// and measured a room 1.35 times brighter as 0.4 times as bright.
///
/// A class, so two items made on one frame share one smoothed gain, kept by its `id`. Every field is a constant.
nonisolated final class RoomArtLightReference: Sendable {
    /// What the processor keeps each reference's smoothed gains by. An object's address is reused once it is freed, so it
    /// is no key.
    let id = UUID()
    /// The copy's size, in pixels.
    let width: Int
    let height: Int
    /// sRGB, top row first, four bytes per pixel.
    let rgbaBytes: [UInt8]
    /// One byte per pixel at the copy's size, the learner's confidence, or nil when the frame has no learner known.
    let personConfidence: [UInt8]?
    /// The tracker's turn from the keyframe to this frame, in this copy's pixels.
    let keyframeToThisFrame: EuclideanWarp

    init(width: Int, height: Int, rgbaBytes: [UInt8], personConfidence: [UInt8]?, keyframeToThisFrame: EuclideanWarp) {
        self.width = width
        self.height = height
        self.rgbaBytes = rgbaBytes
        self.personConfidence = personConfidence
        self.keyframeToThisFrame = keyframeToThisFrame
    }

    /// A pixel with any channel at or above this byte is clipped, so its light is not known and it is left out.
    static let clippedByte: UInt8 = 250
    /// A pixel whose person confidence byte is at or over this counts as the learner and is left out, as the tracker's room
    /// mask counts them (`roomMaskAtTrackSize`).
    static let personConfidenceByte: UInt8 = 77
    /// Fewer shared room pixels than this share of the copy measure nothing, since they say little about the room.
    static let leastSharedRoomShare = 0.1
    /// No channel's gain goes outside this range: a change bigger than this is a different room, or a measure gone wrong.
    static let gainRange: ClosedRange<Double> = 0.4...2.5
    /// A channel whose mean in the reference is this dark gives no gain, since dividing by it would only amplify noise.
    static let darkestReferenceChannel = 0.003
    /// How far each new measurement moves a smoothed gain, measured a few times a second, so a light coming on settles
    /// within about a second, as the camera's own exposure does, and one noisy measurement does not flicker the piece.
    static let smoothingShare = 0.3
    static let unchangedGains = SIMD3<Double>(1, 1, 1)
    /// Every second pixel of every second row is compared, a quarter of the copy, which holds the mean as well.
    static let sampleStep = 2
    /// Each sRGB byte in linear light, worked out once, since a measurement reads thousands of pixels.
    private static let linearLightOfEachByte: [Double] = (0...255).map { byte in
        let encoded = Double(byte) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    /// The per-channel gains, in linear light, that take an item made in `reference`'s light to `current`'s: the summed
    /// light of the pixels both frames show as unclipped room, where each reference pixel is found in `current` through the
    /// keyframe, as a ratio per channel held to `gainRange`. Every `sampleStep`-th pixel of every `sampleStep`-th row is read,
    /// since the measurement runs on the queue that draws each camera frame. Nil when too few pixels are shared, or when the
    /// copies differ in size, which copies made at the track size never do.
    static func gains(from reference: RoomArtLightReference, to current: RoomArtLightReference) -> SIMD3<Double>? {
        guard reference.width == current.width, reference.height == current.height else { return nil }
        // One turn takes a reference pixel to the current pixel: back to the keyframe, then on to the current frame.
        let referenceToCurrent = current.keyframeToThisFrame.after(reference.keyframeToThisFrame.inverted)
        let cosine = cos(referenceToCurrent.angleRadians), sine = sin(referenceToCurrent.angleRadians)
        var referenceTotal = SIMD3<Double>(0, 0, 0), currentTotal = SIMD3<Double>(0, 0, 0)
        var sharedPixels = 0, sampledPixels = 0
        for row in stride(from: 0, to: reference.height, by: sampleStep) {
            for column in stride(from: 0, to: reference.width, by: sampleStep) {
                sampledPixels += 1
                guard let referenceLight = reference.roomLight(atPixel: row * reference.width + column) else { continue }
                let currentX = cosine * Double(column) - sine * Double(row) + referenceToCurrent.translationX
                let currentY = sine * Double(column) + cosine * Double(row) + referenceToCurrent.translationY
                let currentColumn = Int(currentX.rounded()), currentRow = Int(currentY.rounded())
                guard currentColumn >= 0, currentColumn < current.width, currentRow >= 0, currentRow < current.height,
                      let currentLight = current.roomLight(atPixel: currentRow * current.width + currentColumn) else { continue }
                referenceTotal += referenceLight
                currentTotal += currentLight
                sharedPixels += 1
            }
        }
        guard sampledPixels > 0, Double(sharedPixels) >= Double(sampledPixels) * leastSharedRoomShare else { return nil }
        func gain(_ currentChannel: Double, over referenceChannel: Double) -> Double {
            guard referenceChannel / Double(sharedPixels) >= darkestReferenceChannel else { return 1 }
            return min(max(currentChannel / referenceChannel, gainRange.lowerBound), gainRange.upperBound)
        }
        return SIMD3(
            gain(currentTotal.x, over: referenceTotal.x),
            gain(currentTotal.y, over: referenceTotal.y),
            gain(currentTotal.z, over: referenceTotal.z)
        )
    }

    /// The smoothed gains after a new measurement: the first measurement as it is, and each later one moved toward by
    /// `smoothingShare`.
    static func smoothed(previous: SIMD3<Double>?, measured: SIMD3<Double>) -> SIMD3<Double> {
        guard let previous else { return measured }
        return previous + (measured - previous) * smoothingShare
    }

    /// Each in-use reference's smoothed gains after `current` is measured: a reference whose gains can be measured moves
    /// toward them from its gains in `previous`, one that cannot keeps its gains from before, and a reference no longer in use
    /// is dropped. References are told apart by `id`, so two items made on one frame share one entry.
    static func smoothedGainsInUse(
        references: [RoomArtLightReference], current: RoomArtLightReference, previous: [UUID: SIMD3<Double>]
    ) -> [UUID: SIMD3<Double>] {
        var gainsInUse: [UUID: SIMD3<Double>] = [:]
        for reference in references {
            let key = reference.id
            guard gainsInUse[key] == nil else { continue }
            if let measured = gains(from: reference, to: current) {
                gainsInUse[key] = smoothed(previous: previous[key], measured: measured)
            } else if let previousGains = previous[key] {
                gainsInUse[key] = previousGains
            }
        }
        return gainsInUse
    }

    /// An sRGB byte in linear light, 0 to 1.
    static func linearLight(ofSRGBByte byte: UInt8) -> Double {
        linearLightOfEachByte[Int(byte)]
    }

    /// The pixel's light in linear light, or nil when it is the learner or clipped.
    private func roomLight(atPixel pixelIndex: Int) -> SIMD3<Double>? {
        if let personConfidence, personConfidence[pixelIndex] >= Self.personConfidenceByte { return nil }
        let byteIndex = pixelIndex * 4
        let red = rgbaBytes[byteIndex], green = rgbaBytes[byteIndex + 1], blue = rgbaBytes[byteIndex + 2]
        guard red < Self.clippedByte, green < Self.clippedByte, blue < Self.clippedByte else { return nil }
        return SIMD3(Self.linearLight(ofSRGBByte: red), Self.linearLight(ofSRGBByte: green), Self.linearLight(ofSRGBByte: blue))
    }
}
