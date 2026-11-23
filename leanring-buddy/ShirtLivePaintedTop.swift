//
//  ShirtLivePaintedTop.swift
//  leanring-buddy
//
//  Paint once, then track it. OpenAI paints the store's top into one frozen frame (`ShirtPaintedStill`), and the painted
//  still used to stay frozen until the learner went back. Here the painted top is cut out of that still and moves with the
//  learner in the live camera view, so the one paid painting stays on them as they move.
//
//  - `ShirtLivePaintedTop` is the cut-out layer (the painting inside the paint mask, with the hands, the face, and the neck
//    left transparent so the live ones show), the whole still, and the torso the frame was frozen on. It maps the layer
//    from the frozen torso to the current one and draws it over the live frame, clipped to the live person mask.
//  - `ShirtLivePaintedTopReach` decides whether the learner is still close enough to the frozen pose for the layer to look
//    right, with hysteresis so a learner at a limit does not flicker.
//  - `ShirtLivePaintedTopFollower` is the state the frame processor keeps: the reach, how visible the live top is, and when
//    the learner is told to stand as they did.
//
//  Out of reach, the painted still shows instead, which always exists for either preview kind and never looks stretched.
//  There is no relighting: the frozen frame is seconds old from the same camera, so the room's light is the painting's own.
//
//  Points are in camera pixels with y down, as `BodyTorso` is. Core Image's y grows up, so a transform crosses
//  `ShirtTryOnRenderer.coreImageTransform(of:frameExtent:)` on the way in.
//

import CoreGraphics
import CoreImage
import Foundation
import simd

/// The status line while the painted top is out of reach and the painted still shows instead.
nonisolated let roomArtShirtPaintedOutOfReachLine = "Stand as you did to see it live"

// MARK: - The top

nonisolated struct ShirtLivePaintedTop: @unchecked Sendable {
    // @unchecked because CIImage is immutable, so sharing one across queues is safe.

    /// The painted top cut out of the painted still: premultiplied, in the frame's pixels, with its extent the frame's. Clear
    /// over the neck, the face, and the hands, and over everything the painting did not cover.
    let layer: CIImage
    /// The whole painted still, which shows while the learner is out of reach.
    let still: CIImage
    /// The paint mask, white where the painting drew the new top, gray in the frame's pixels. The layer draws there whatever
    /// the live person mask says, since a puffy sleeve or a coat stands off the learner's own outline, and clipping it to
    /// that outline cut the painted bulk away (the wall showed between a jacket's sleeve and its side). Only the band the
    /// paste grew past the mask, which holds the frozen room, is clipped to the live person.
    let paintedArea: CIImage
    /// The torso the frame was frozen on, which the layer's pixels belong to.
    let frozenTorso: BodyTorso
    /// A long sleeve is painted down each arm, so the arms must hold their angles for the layer to look right. A short sleeve
    /// stands off the arm, so only the upper arm counts.
    let followsTheForearms: Bool

    /// A protected region (a hand) rests on the top only below the frozen shoulder line moved down this many shoulder
    /// widths. Above it are the neck and the face, which stay transparent so the live ones show.
    static let holesBelowTheShoulderLineInShoulderWidths = 0.15
    /// The blur radii a hole's fill tries, in shoulder widths, smallest first. The largest covers a hand's width twice over.
    static let holeFillRadiiInShoulderWidths = [0.05, 0.12, 0.25]
    /// A blur has enough of the top around a hole pixel when this share of its box is top. The largest radius takes any.
    static let holeFillLeastSupportShare: Float = 0.15
    /// The painted top is drawn where the live person mask is over the first of these and fully over the second. The mask's
    /// soft edge holds the old top's dark blend with the room, which the painted top must cover, so this ramp starts lower than
    /// the renderer's 0.5 to 0.9 (`ShirtTryOnRenderer.personMaskRampForTheGarment`), which left a thin dark outline along the
    /// shoulders and arms. The painting's own colors reach the silhouette, so no bright garment is laid over the wall.
    static let personMaskRamp = (from: 0.08, to: 0.4)

    /// The paint mask is worked out on a copy about a third of the frame's size and scaled up, so its edge steps in blocks
    /// of about 3 pixels. Where the painted area meets the room the live person mask does not hide that edge, so it is
    /// softened twice over this radius, about the size of one step.
    static let paintedAreaSofteningRadiusPixels = 2

    // MARK: Cutting the layer out

    /// The live top for a painted still, or nil when the sizes disagree or no shoulders can anchor it. `painted` is the still
    /// as pasted (`shirtPaintedStillPasted`) and `masks` the ones it was painted with. CPU work on every pixel of the frame,
    /// so call it off the main actor.
    static func make(painted: CGImage, masks: ShirtPaintMasks, frozenTorso: BodyTorso, coverage: ShirtCoverage) -> ShirtLivePaintedTop? {
        let width = masks.width, height = masks.height
        guard width >= 3, height >= 3, painted.width == width, painted.height == height,
              masks.paintable.count == width * height, masks.protected.count == width * height,
              frozenTorso.shoulderWidth > 2,
              let stillBytes = rgbaBytes(of: painted, width: width, height: height),
              let pasteWeights = pasteWeights(of: masks),
              let layerBytes = premultipliedLayerBytes(stillRGBA: stillBytes, masks: masks, pasteWeights: pasteWeights, frozenTorso: frozenTorso),
              let layerImage = premultipliedImage(bytes: layerBytes, width: width, height: height),
              let paintedAreaImage = grayImage(bytes: softenedPaintedArea(masks), width: width, height: height) else { return nil }
        return ShirtLivePaintedTop(
            layer: CIImage(cgImage: layerImage), still: CIImage(cgImage: painted), paintedArea: CIImage(cgImage: paintedAreaImage, options: [.colorSpace: NSNull()]),
            frozenTorso: frozenTorso, followsTheForearms: coverage.sleeves == .long
        )
    }

    /// The paint mask with its blocky edge softened (`paintedAreaSofteningRadiusPixels`), first row at the top.
    static func softenedPaintedArea(_ masks: ShirtPaintMasks) -> [UInt8] {
        let paintable = masks.paintable.map { Float($0) / 255 }
        let onceSoftened = boxMeanFiltered(paintable, width: masks.width, height: masks.height, radius: paintedAreaSofteningRadiusPixels)
        let twiceSoftened = boxMeanFiltered(onceSoftened, width: masks.width, height: masks.height, radius: paintedAreaSofteningRadiusPixels)
        return twiceSoftened.map { UInt8(min(255, max(0, $0 * 255 + 0.5))) }
    }

    /// How much of the painting the paste took at each pixel, 0 to 255: the paint mask grown and feathered exactly as
    /// `shirtPaintedStillPasted` grows it (`furnitureCompositePasted`'s slack and feather). The band past the mask covers the
    /// old top's dark blend with the room, so a layer cut to the mask alone left that line showing along the shoulders.
    static func pasteWeights(of masks: ShirtPaintMasks) -> [UInt8]? {
        let frameExtent = CGRect(x: 0, y: 0, width: masks.width, height: masks.height)
        guard let paintableImage = grayImage(bytes: masks.paintable, width: masks.width, height: masks.height),
              let pasteMask = grownMaskImage(
                  paintableImage, frameExtent: frameExtent, radiusPixels: furnitureCompositePasteSlackPixels,
                  blurPixels: furnitureCompositePasteFeatherPixels, context: CIContext()
              ) else { return nil }
        return grayBytes(of: pasteMask, width: masks.width, height: masks.height)
    }

    /// The layer's bytes, premultiplied, first row at the top: the still where the paste took the painting (`pasteWeights`),
    /// and clear where the mask protects the neck, the face, and the hands, so the layer over the frozen frame is the still.
    ///
    /// A hand resting on the top is a hole in the mask, and a hand that moves away must not reveal the old shirt, so a hole
    /// the top encloses below the shoulder line is filled: opaque, with colors from a normalized blur of the painted top
    /// around it. Everything protected above that line stays clear.
    static func premultipliedLayerBytes(stillRGBA: [UInt8], masks: ShirtPaintMasks, pasteWeights: [UInt8], frozenTorso: BodyTorso) -> [UInt8]? {
        let width = masks.width, height = masks.height, pixelCount = width * height
        guard stillRGBA.count == pixelCount * 4, masks.paintable.count == pixelCount, masks.protected.count == pixelCount,
              pasteWeights.count == pixelCount else { return nil }
        let shoulderWidth = frozenTorso.shoulderWidth
        let shoulderSpan = SIMD2(
            Double(frozenTorso.imageRightShoulder.x - frozenTorso.imageLeftShoulder.x), Double(frozenTorso.imageRightShoulder.y - frozenTorso.imageLeftShoulder.y)
        ) / max(shoulderWidth, 1)
        // Perpendicular to the shoulder line, toward the bottom of the frame.
        var downTheBody = SIMD2(-shoulderSpan.y, shoulderSpan.x)
        if downTheBody.y < 0 { downTheBody = -downTheBody }
        let shoulderMiddle = SIMD2(Double(frozenTorso.shoulderMidpoint.x), Double(frozenTorso.shoulderMidpoint.y))
        let holesStartBelow = holesBelowTheShoulderLineInShoulderWidths * shoulderWidth

        let paintableIsSet = masks.paintable.map { $0 > 127 }
        // The top and everything it encloses, so a hand on the belly is inside it and a hand beside it is not.
        let silhouette = ShirtPaintMask.withTheHolesFilled(paintableIsSet, width: width, height: height)

        // A protected pixel inside the top and below the line is a hole to fill. Its ring, which the mask protects partly,
        // is one too, so the fill meets the top with no seam between them.
        var isHolePixel = [Bool](repeating: false, count: pixelCount)
        var holeBounds: (left: Int, top: Int, right: Int, bottom: Int)?
        for index in 0..<pixelCount where silhouette[index] && masks.protected[index] > 0 {
            let column = index % width, row = index / width
            let pointBelowTheShoulderLine = simd_dot(SIMD2(Double(column) + 0.5, Double(row) + 0.5) - shoulderMiddle, downTheBody)
            guard pointBelowTheShoulderLine > holesStartBelow else { continue }
            isHolePixel[index] = true
            if let bounds = holeBounds {
                holeBounds = (min(bounds.left, column), min(bounds.top, row), max(bounds.right, column), max(bounds.bottom, row))
            } else {
                holeBounds = (column, row, column, row)
            }
        }
        var holeFill: (colors: [UInt8], isFilled: [Bool])?
        if let holeBounds {
            let topPixels = (0..<pixelCount).map { paintableIsSet[$0] && !isHolePixel[$0] }
            holeFill = inpaintedColors(stillRGBA: stillRGBA, topPixels: topPixels, isHolePixel: isHolePixel, holeBounds: holeBounds, width: width, height: height, shoulderWidth: shoulderWidth)
        }

        var layerBytes = [UInt8](repeating: 0, count: pixelCount * 4)
        for index in 0..<pixelCount {
            let pasteShare = Float(pasteWeights[index]) / 255
            var red = stillRGBA[index * 4], green = stillRGBA[index * 4 + 1], blue = stillRGBA[index * 4 + 2]
            let alpha: Float
            if isHolePixel[index], let holeFill, holeFill.isFilled[index] {
                alpha = pasteShare
                // The ring around a hand is still the painted top, and only the hand's own pixels take the blurred colors.
                if !paintableIsSet[index] {
                    red = holeFill.colors[index * 3]; green = holeFill.colors[index * 3 + 1]; blue = holeFill.colors[index * 3 + 2]
                }
            } else {
                alpha = pasteShare * (1 - Float(masks.protected[index]) / 255)
            }
            guard alpha > 0.002 else { continue }
            layerBytes[index * 4] = UInt8(min(255, Float(red) * alpha + 0.5))
            layerBytes[index * 4 + 1] = UInt8(min(255, Float(green) * alpha + 0.5))
            layerBytes[index * 4 + 2] = UInt8(min(255, Float(blue) * alpha + 0.5))
            layerBytes[index * 4 + 3] = UInt8(min(255, alpha * 255 + 0.5))
        }
        return layerBytes
    }

    /// Colors for the hole pixels: the painted top's mean around each, from the smallest blur radius whose box holds enough of
    /// the top, so a pixel at a hole's edge takes its neighbors and a pixel at its middle takes the broader mean. The blurs
    /// are normalized (the blur of the color where the top is over the blur of where it is), so a hand or the room around
    /// the top never bleeds into them. Only the box around the holes, grown by the largest radius, is blurred. A hole pixel
    /// with no top near it at any radius stays unfilled.
    static func inpaintedColors(
        stillRGBA: [UInt8], topPixels: [Bool], isHolePixel: [Bool], holeBounds: (left: Int, top: Int, right: Int, bottom: Int),
        width: Int, height: Int, shoulderWidth: Double
    ) -> (colors: [UInt8], isFilled: [Bool]) {
        let pixelCount = width * height
        var colors = [UInt8](repeating: 0, count: pixelCount * 3)
        var isFilled = [Bool](repeating: false, count: pixelCount)
        // A small frame rounds two radii to the same pixels, and the same blur twice finds nothing new.
        var radii: [Int] = []
        for radius in holeFillRadiiInShoulderWidths.map({ max(1, Int(($0 * shoulderWidth).rounded())) }) where !radii.contains(radius) { radii.append(radius) }
        guard let longestRadius = radii.last else { return (colors, isFilled) }
        let boxLeft = max(0, holeBounds.left - longestRadius), boxRight = min(width - 1, holeBounds.right + longestRadius)
        let boxTop = max(0, holeBounds.top - longestRadius), boxBottom = min(height - 1, holeBounds.bottom + longestRadius)
        let boxWidth = boxRight - boxLeft + 1, boxHeight = boxBottom - boxTop + 1

        var weights = [Float](repeating: 0, count: boxWidth * boxHeight)
        var weightedReds = weights, weightedGreens = weights, weightedBlues = weights
        var remainingHoles: [(boxIndex: Int, frameIndex: Int)] = []
        for row in 0..<boxHeight {
            for column in 0..<boxWidth {
                let frameIndex = (boxTop + row) * width + boxLeft + column, boxIndex = row * boxWidth + column
                if topPixels[frameIndex] {
                    weights[boxIndex] = 1
                    weightedReds[boxIndex] = Float(stillRGBA[frameIndex * 4]) / 255
                    weightedGreens[boxIndex] = Float(stillRGBA[frameIndex * 4 + 1]) / 255
                    weightedBlues[boxIndex] = Float(stillRGBA[frameIndex * 4 + 2]) / 255
                } else if isHolePixel[frameIndex] {
                    remainingHoles.append((boxIndex, frameIndex))
                }
            }
        }
        for (radiusNumber, radius) in radii.enumerated() {
            guard !remainingHoles.isEmpty else { break }
            let isTheLargestRadius = radiusNumber == radii.count - 1
            let leastSupport = isTheLargestRadius ? 0.002 : holeFillLeastSupportShare
            let meanWeights = boxMeanFiltered(weights, width: boxWidth, height: boxHeight, radius: radius)
            let meanReds = boxMeanFiltered(weightedReds, width: boxWidth, height: boxHeight, radius: radius)
            let meanGreens = boxMeanFiltered(weightedGreens, width: boxWidth, height: boxHeight, radius: radius)
            let meanBlues = boxMeanFiltered(weightedBlues, width: boxWidth, height: boxHeight, radius: radius)
            remainingHoles = remainingHoles.filter { hole in
                let support = meanWeights[hole.boxIndex]
                guard support >= leastSupport else { return true }
                colors[hole.frameIndex * 3] = UInt8(max(0, min(255, meanReds[hole.boxIndex] / support * 255 + 0.5)))
                colors[hole.frameIndex * 3 + 1] = UInt8(max(0, min(255, meanGreens[hole.boxIndex] / support * 255 + 0.5)))
                colors[hole.frameIndex * 3 + 2] = UInt8(max(0, min(255, meanBlues[hole.boxIndex] / support * 255 + 0.5)))
                isFilled[hole.frameIndex] = true
                return false
            }
        }
        return (colors, isFilled)
    }

    /// An sRGB image of premultiplied RGBA `bytes`, first row at the top.
    private static func premultipliedImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard bytes.count == width * height * 4, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    // MARK: Following the learner

    /// The motion that carries the frozen torso onto `currentTorso`, in camera pixels with y down. With real hips on both it
    /// is the affine map of the two shoulders and the hips' middle, which follows a lean and a turn of the shoulders. With a
    /// hip estimated on either, it is the turn, scale, and shift of the shoulders alone, since an estimated hip says nothing
    /// the shoulders do not.
    func transform(to currentTorso: BodyTorso) -> CGAffineTransform {
        if !frozenTorso.hipsWereEstimated, !currentTorso.hipsWereEstimated,
           let affine = ShirtTryOnRenderer.affineTransform(from: Self.anchors(of: frozenTorso), to: Self.anchors(of: currentTorso)) {
            return affine
        }
        return ShirtTryOnRenderer.motion(from: frozenTorso, to: currentTorso)
    }

    private static func anchors(of torso: BodyTorso) -> [CGPoint] {
        [torso.imageLeftShoulder, torso.imageRightShoulder, torso.hipMidpoint]
    }

    /// The frame with the layer moved by `transform` (y down) drawn over it, its band past the paint mask clipped to the live
    /// person mask, dissolved with
    /// the painted still by `visibility`: 0 is the still, 1 is the live top. `personMask` is white where the person is, at any
    /// size, read as its values are (made with no color space), as the renderer reads it. The still is returned as it is at
    /// 0, and the live image alone at 1, so neither pays for the other.
    func composite(frame: CIImage, personMask: CIImage, transform: CGAffineTransform, visibility: Double) -> CIImage {
        guard visibility > 0 else { return still }
        let frameExtent = frame.extent
        let liveImage = liveImage(frame: frame, personMask: personMask, transform: transform)
        guard visibility < 1 else { return liveImage }
        return still.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: liveImage, kCIInputTimeKey: visibility]).cropped(to: frameExtent)
    }

    private func liveImage(frame: CIImage, personMask: CIImage, transform: CGAffineTransform) -> CIImage {
        let frameExtent = frame.extent
        let clearFrame = CIImage(color: .clear).cropped(to: frameExtent)
        // Over a clear frame, so the layer's coverage is defined over the whole frame, which the masks below multiply.
        let coreImageTransform = ShirtTryOnRenderer.coreImageTransform(of: transform, frameExtent: frameExtent)
        let movedLayer = layer.transformed(by: coreImageTransform).composited(over: clearFrame).cropped(to: frameExtent)
        let layerCoverage = ShirtTryOnRenderer.channel(movedLayer, 3)
        let movedPaintedArea = ShirtTryOnRenderer.channel(
            paintedArea.transformed(by: coreImageTransform).composited(over: CIImage(color: .black).cropped(to: frameExtent)).cropped(to: frameExtent), 0
        )
        let scaledPersonMask = ShirtTryOnRenderer.channel(ShirtTryOnRenderer.scaled(personMask, toFill: frameExtent), 0)
        let personOpacity = ShirtTryOnRenderer.ramp(scaledPersonMask, from: Self.personMaskRamp.from, to: Self.personMaskRamp.to)
        let drawnArea = movedPaintedArea.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: personOpacity]).cropped(to: frameExtent)
        let drawnAlpha = ShirtTryOnRenderer.multiplied(layerCoverage, drawnArea)
        // The blend takes straight colors and an opaque top, so the frame keeps its own alpha.
        return movedLayer.unpremultiplyingAlpha().settingAlphaOne(in: frameExtent)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: frame, kCIInputMaskImageKey: drawnAlpha])
            .cropped(to: frameExtent)
    }
}

/// `values` (first row at the top) averaged over a window `2 * radius + 1` pixels on each side, with the pixels past the
/// frame's edge counted as the edge's own. Two running sums, so the cost does not depend on the radius.
nonisolated func boxMeanFiltered(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
    guard radius > 0, width > 0, height > 0, values.count == width * height else { return values }
    let windowSize = Float(2 * radius + 1)
    var averagedAcross = [Float](repeating: 0, count: width * height)
    values.withUnsafeBufferPointer { source in
        averagedAcross.withUnsafeMutableBufferPointer { destination in
            for row in 0..<height {
                let rowStart = row * width
                var windowSum: Float = 0
                for offset in -radius...radius { windowSum += source[rowStart + min(max(offset, 0), width - 1)] }
                for column in 0..<width {
                    destination[rowStart + column] = windowSum / windowSize
                    let leavingColumn = min(max(column - radius, 0), width - 1), enteringColumn = min(max(column + radius + 1, 0), width - 1)
                    windowSum += source[rowStart + enteringColumn] - source[rowStart + leavingColumn]
                }
            }
        }
    }
    var averaged = [Float](repeating: 0, count: width * height)
    averagedAcross.withUnsafeBufferPointer { source in
        averaged.withUnsafeMutableBufferPointer { destination in
            // One running sum for each column, moved down a row at a time, so every pass reads whole rows.
            var columnSums = [Float](repeating: 0, count: width)
            for offset in -radius...radius {
                let row = min(max(offset, 0), height - 1)
                for column in 0..<width { columnSums[column] += source[row * width + column] }
            }
            for row in 0..<height {
                for column in 0..<width { destination[row * width + column] = columnSums[column] / windowSize }
                let leavingRow = min(max(row - radius, 0), height - 1), enteringRow = min(max(row + radius + 1, 0), height - 1)
                for column in 0..<width { columnSums[column] += source[enteringRow * width + column] - source[leavingRow * width + column] }
            }
        }
    }
    return averaged
}

// MARK: - The reach

/// Why the painted top cannot follow the learner now.
nonisolated enum ShirtLivePaintedTopReachProblem: Equatable, Sendable {
    /// Nobody is in view, or their shoulders are not.
    case noTorso
    /// Closer or farther than the painting can stretch to.
    case shouldersChangedSize
    /// The shoulders tilted too far.
    case shouldersRolled
    /// Turned to the side, so the shoulders are narrow for the torso's length.
    case turnedSideways
    /// An upper arm moved from where it hung in the painting.
    case upperArmMoved
    /// A forearm moved from where it hung in the painting, which matters only under a long sleeve.
    case forearmMoved
}

/// Whether the painted top can follow the learner: they stand close enough to how they stood in the painting that a flat
/// picture moved with their torso still looks like the top on them. Every limit has a hysteresis, so a learner at a limit
/// does not flicker: leaving takes passing a limit, and coming back takes being within `comebackShareOfEachLimit` of it.
nonisolated enum ShirtLivePaintedTopReach: Equatable, Sendable {
    case follows
    case outOfReach(ShirtLivePaintedTopReachProblem)

    /// The shoulders' width against the painting's. Past this the print and the seams stretch or shrink out of true.
    static let shoulderScaleRange = 0.7...1.4
    /// The shoulder line's tilt from the painting's, in degrees. More turns the picture's body out of its plane.
    static let largestShoulderRollDegrees = 25.0
    /// The shoulder width over the shoulder to hip length, against the painting's. A turn to the side narrows the shoulders
    /// and not the torso, so below this share the learner is no longer facing the camera. Real hips only, since estimated hips
    /// make the ratio constant.
    static let smallestSidewaysShare = 0.8
    /// An upper arm's angle against the shoulder line, from the painting's, in degrees. The sleeve's cloth bends with the arm.
    static let largestUpperArmTurnDegrees = 15.0
    /// The same for a forearm, which only a long sleeve covers.
    static let largestForearmTurnDegrees = 20.0
    /// Coming back takes being within this share of each limit's distance from the painting's pose.
    static let comebackShareOfEachLimit = 0.7

    /// Whether the painted top follows `currentTorso`, nil when nobody is in view. `wasFollowing` says which side of the
    /// hysteresis the learner is on: leaving takes passing a limit, coming back takes being within the comeback share of it.
    static func decide(frozenTorso: BodyTorso, currentTorso: BodyTorso?, followsTheForearms: Bool, wasFollowing: Bool) -> ShirtLivePaintedTopReach {
        guard let currentTorso, currentTorso.shouldersAreSeen, currentTorso.shoulderWidth > 1, frozenTorso.shoulderWidth > 1 else { return .outOfReach(.noTorso) }
        let share = wasFollowing ? 1.0 : comebackShareOfEachLimit

        let scale = currentTorso.shoulderWidth / frozenTorso.shoulderWidth
        let smallestScale = 1 - (1 - shoulderScaleRange.lowerBound) * share, largestScale = 1 + (shoulderScaleRange.upperBound - 1) * share
        guard (smallestScale...largestScale).contains(scale) else { return .outOfReach(.shouldersChangedSize) }

        let roll = abs(degreesTurned(from: shoulderLineAngle(of: frozenTorso), to: shoulderLineAngle(of: currentTorso)))
        guard roll <= largestShoulderRollDegrees * share else { return .outOfReach(.shouldersRolled) }

        if !frozenTorso.hipsWereEstimated, !currentTorso.hipsWereEstimated,
           let frozenRatio = shoulderWidthOverTorsoLength(of: frozenTorso), let currentRatio = shoulderWidthOverTorsoLength(of: currentTorso) {
            guard currentRatio / frozenRatio >= 1 - (1 - smallestSidewaysShare) * share else { return .outOfReach(.turnedSideways) }
        }

        for (frozenArm, currentArm) in zip(armAngles(of: frozenTorso), armAngles(of: currentTorso)) {
            // An arm the painting saw must be seen now, since where it went is not known. One the painting never saw is not held to anything.
            if let frozenUpperArm = frozenArm.upperArm {
                guard let currentUpperArm = currentArm.upperArm,
                      abs(degreesTurned(from: frozenUpperArm, to: currentUpperArm)) <= largestUpperArmTurnDegrees * share else { return .outOfReach(.upperArmMoved) }
            }
            if followsTheForearms, let frozenForearm = frozenArm.forearm {
                guard let currentForearm = currentArm.forearm,
                      abs(degreesTurned(from: frozenForearm, to: currentForearm)) <= largestForearmTurnDegrees * share else { return .outOfReach(.forearmMoved) }
            }
        }
        return .follows
    }

    /// The direction of the line from the image left shoulder to the image right one, in radians.
    private static func shoulderLineAngle(of torso: BodyTorso) -> Double {
        atan2(Double(torso.imageRightShoulder.y - torso.imageLeftShoulder.y), Double(torso.imageRightShoulder.x - torso.imageLeftShoulder.x))
    }

    private static func shoulderWidthOverTorsoLength(of torso: BodyTorso) -> Double? {
        let torsoLength = hypot(Double(torso.hipMidpoint.x - torso.shoulderMidpoint.x), Double(torso.hipMidpoint.y - torso.shoulderMidpoint.y))
        return torsoLength > 1 ? torso.shoulderWidth / torsoLength : nil
    }

    /// Each arm's upper arm (shoulder to elbow) and forearm (elbow to wrist) as an angle from the shoulder line in radians,
    /// image left first, nil for a part with a joint not seen. Measured from the shoulder line, so a rolled torso holds its
    /// arms' angles.
    private static func armAngles(of torso: BodyTorso) -> [(upperArm: Double?, forearm: Double?)] {
        let lineAngle = shoulderLineAngle(of: torso)
        func angle(from start: CGPoint, to end: CGPoint) -> Double? {
            let offset = CGPoint(x: end.x - start.x, y: end.y - start.y)
            return hypot(offset.x, offset.y) > 1 ? atan2(Double(offset.y), Double(offset.x)) - lineAngle : nil
        }
        func arm(shoulder: CGPoint, elbow: CGPoint?, wrist: CGPoint?) -> (upperArm: Double?, forearm: Double?) {
            guard let elbow else { return (nil, nil) }
            return (angle(from: shoulder, to: elbow), wrist.flatMap { angle(from: elbow, to: $0) })
        }
        return [
            arm(shoulder: torso.imageLeftShoulder, elbow: torso.imageLeftElbow, wrist: torso.imageLeftWrist),
            arm(shoulder: torso.imageRightShoulder, elbow: torso.imageRightElbow, wrist: torso.imageRightWrist),
        ]
    }

    /// The turn from one angle to another, in degrees from -180 to 180.
    private static func degreesTurned(from earlier: Double, to later: Double) -> Double {
        var turn = (later - earlier) * 180 / .pi
        while turn > 180 { turn -= 360 }
        while turn <= -180 { turn += 360 }
        return turn
    }
}

// MARK: - The follower

/// What the frame processor keeps while the painted top follows the learner: the reach, how visible the live top is, and
/// whether the learner has been told to stand as they did. Pure, with each step's time passed in, so a test steps it by hand.
nonisolated struct ShirtLivePaintedTopFollower: Sendable {
    /// The live top and the painted still fade into each other over this long, which is also the form Reduce Motion gets: a
    /// crossfade.
    static let fadeSeconds = 0.3
    /// A frame after a stall moves the fade by at most this much time.
    static let longestStepSeconds = 0.1
    /// The learner is told to stand as they did only after being out of reach this long, so the moment before the first
    /// pose arrives and a brief step past a limit show no line.
    static let secondsOutOfReachBeforeTheHint = 0.5

    let top: ShirtLivePaintedTop
    /// Starts out of reach, so the still shows until the learner is within the comeback share of every limit.
    private(set) var reach = ShirtLivePaintedTopReach.outOfReach(.noTorso)
    /// 0 is the painted still and 1 is the live top.
    private(set) var visibility = 0.0
    private(set) var hintIsShowing = false
    private var outOfReachSince: TimeInterval?
    private var lastStepAt: TimeInterval?
    /// The motion from the last frame that was in reach, which a fade back to the still keeps drawing the live top with
    /// instead of a motion from a pose it cannot follow.
    private var followingTransform: CGAffineTransform?

    init(top: ShirtLivePaintedTop) {
        self.top = top
    }

    /// No step has run yet, so the processor still has to clear what the frozen path left behind.
    var hasStarted: Bool { lastStepAt != nil }

    /// Moves the state to the frame at `time` (seconds on any steady clock) with `currentTorso`, nil when nobody is in view.
    /// Returns whether the hint is showing now when that changed, and nil otherwise.
    mutating func advance(currentTorso: BodyTorso?, at time: TimeInterval) -> Bool? {
        let secondsSinceTheLastStep = lastStepAt.map { min(max(time - $0, 0), Self.longestStepSeconds) } ?? 0
        lastStepAt = time
        reach = ShirtLivePaintedTopReach.decide(
            frozenTorso: top.frozenTorso, currentTorso: currentTorso, followsTheForearms: top.followsTheForearms, wasFollowing: reach == .follows
        )
        if reach == .follows, let currentTorso { followingTransform = top.transform(to: currentTorso) }
        let targetVisibility = reach == .follows ? 1.0 : 0.0
        let fadeStep = secondsSinceTheLastStep / Self.fadeSeconds
        visibility = visibility < targetVisibility ? min(targetVisibility, visibility + fadeStep) : max(targetVisibility, visibility - fadeStep)

        let hintShouldShow: Bool
        if reach == .follows {
            outOfReachSince = nil
            hintShouldShow = false
        } else {
            let outOfReachFirstSeenAt = outOfReachSince ?? time
            outOfReachSince = outOfReachFirstSeenAt
            hintShouldShow = time - outOfReachFirstSeenAt >= Self.secondsOutOfReachBeforeTheHint
        }
        guard hintShouldShow != hintIsShowing else { return nil }
        hintIsShowing = hintShouldShow
        return hintShouldShow
    }

    /// What the panel shows for `frame` now: the painted still, the live top, or a dissolve between them. The still shows
    /// while there is no person mask yet.
    func image(frame: CIImage, personMask: CIImage?) -> CIImage {
        guard visibility > 0, let personMask, let followingTransform else { return top.still }
        return top.composite(frame: frame, personMask: personMask, transform: followingTransform, visibility: visibility)
    }
}
