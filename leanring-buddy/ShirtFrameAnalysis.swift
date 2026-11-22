//
//  ShirtFrameAnalysis.swift
//  leanring-buddy
//
//  The per-frame questions of the shirt try-on that Core Image's built-in filters cannot ask: which pixels are the learner's
//  current shirt (a distance to its color), where the neck is, and where the old shirt ends. They run on a 320 pixel wide copy
//  of the frame on the CPU, which is about 60,000 pixels and well under a millisecond, and the renderer scales the answers up
//  as masks. A custom Core Image kernel would answer them at full size, but a Metal kernel needs a separate build step this
//  app does not have, and the string kernel language is deprecated.
//
//  Colors are 8-bit sRGB values (0 to 255) and every point is in the small bitmap's pixels, top left origin, y down.
//

import CoreGraphics
import Foundation
import simd

/// The old shirt's color and a pixel's distance to it, measured in a Lab-like space as the spike did.
nonisolated enum ShirtColorMath {
    /// A pixel within this distance of the old shirt's color is the old shirt. The lightness difference counts a third, since
    /// folds and shadows move lightness far more than they move the cloth's hue.
    static let oldShirtDistanceLimit: Float = 16
    /// The old shirt's light is read only from pixels whose chromaticity (each linear channel's share of their sum) is within
    /// this of its color's. A panel of another fabric near its color passes the color rule on its lightness, and its lighter
    /// cloth would read as brighter light on the new shirt. Light scales the linear channels together, so a fold or a shadow
    /// leaves the chromaticity where it was; a gray panel on a navy shirt is about 0.19 away, and a dark webcam pixel's noise
    /// moves it about 0.05.
    static let oldShirtChromaticityDistanceLimitForTheShading: Float = 0.1

    /// Each linear channel's share of their sum, red and green (blue is the rest), or nil for black.
    static func chromaticity(red: UInt8, green: UInt8, blue: UInt8) -> SIMD2<Float>? {
        let linearRed = linearValueOfEachByte[Int(red)], linearGreen = linearValueOfEachByte[Int(green)], linearBlue = linearValueOfEachByte[Int(blue)]
        let sum = linearRed + linearGreen + linearBlue
        guard sum > 1e-4 else { return nil }
        return SIMD2(linearRed / sum, linearGreen / sum)
    }

    /// Each 8-bit sRGB value in linear light.
    static let linearValueOfEachByte: [Float] = (0..<256).map { byte in
        let srgb = Float(byte) / 255
        return srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
    }

    /// Lightness from 0 to 255, then a and b around 128: the scaling OpenCV gives an 8-bit Lab image, which the distance
    /// limit above was tuned in.
    static func lab(red: UInt8, green: UInt8, blue: UInt8) -> SIMD3<Float> {
        let linearRed = linearValueOfEachByte[Int(red)], linearGreen = linearValueOfEachByte[Int(green)], linearBlue = linearValueOfEachByte[Int(blue)]
        let tristimulusX = (0.4124564 * linearRed + 0.3575761 * linearGreen + 0.1804375 * linearBlue) / 0.950456
        let tristimulusY = 0.2126729 * linearRed + 0.7151522 * linearGreen + 0.0721750 * linearBlue
        let tristimulusZ = (0.0193339 * linearRed + 0.1191920 * linearGreen + 0.9503041 * linearBlue) / 1.088754
        func labCurve(_ value: Float) -> Float { value > 0.008856 ? cbrt(value) : 7.787 * value + 16 / 116 }
        let curvedTristimulusX = labCurve(tristimulusX), curvedTristimulusY = labCurve(tristimulusY), curvedTristimulusZ = labCurve(tristimulusZ)
        return SIMD3((116 * curvedTristimulusY - 16) * 255 / 100, 500 * (curvedTristimulusX - curvedTristimulusY) + 128, 200 * (curvedTristimulusY - curvedTristimulusZ) + 128)
    }

    /// The Lab of every color with each channel cut to its top 5 bits (32,768 colors, each at the middle of its cell), so a
    /// frame's 57,600 pixels cost a table lookup each instead of three cube roots. The cell is 8 values wide, which moves a
    /// pixel's lightness distance by under 1.5 and its chroma by about 2, small against the limit of 16.
    private static let labOfEachFiveBitColor: [SIMD3<Float>] = (0..<32_768).map { cell in
        let redCell = cell >> 10, greenCell = (cell >> 5) & 31, blueCell = cell & 31
        return lab(red: UInt8(redCell * 8 + 4), green: UInt8(greenCell * 8 + 4), blue: UInt8(blueCell * 8 + 4))
    }

    static func quickLab(red: UInt8, green: UInt8, blue: UInt8) -> SIMD3<Float> {
        let cell = Int(red >> 3) * 1024 + Int(green >> 3) * 32 + Int(blue >> 3)
        return labOfEachFiveBitColor[cell]
    }

    static func distance(from lab: SIMD3<Float>, to oldShirtLab: SIMD3<Float>) -> Float {
        let difference = lab - oldShirtLab
        return (difference.x * difference.x / 9 + difference.y * difference.y + difference.z * difference.z).squareRoot()
    }

    static func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }
}

/// The room's light, read from the pixels off the person, which the garment is lit with instead of the product photo's.
nonisolated struct ShirtRoomLight: Equatable, Sendable {
    /// A pixel whose channels differ by more than this share of the largest is colored, not a lit neutral surface.
    static let saturationLimit: Float = 0.25
    /// A pixel with a channel at or over this level is a light or a blown highlight, which says nothing about the light.
    static let clippedLevel: UInt8 = 250
    /// Fewer usable pixels than this share of the frame (a learner filling the frame, a colorful room) say nothing.
    static let leastShareOfTheFrame = 0.01

    /// The linear luminance a white surface has in the room: the 90th percentile of the unsaturated, unclipped pixels off
    /// the person, which are mostly walls, doors, and ceilings.
    let whiteLuminance: Float
    /// The light's color in linear light with a luminance of 1: the mean of the brightest fifth of those pixels.
    let illuminant: SIMD3<Float>

    /// The room's light in `frame`, or nil when too few pixels off the person can show it.
    static func measure(in frame: ShirtSmallFrame) -> ShirtRoomLight? {
        // A histogram of luminance in 512 steps finds the percentiles without sorting.
        let stepCount = 512
        var histogram = [Int](repeating: 0, count: stepCount)
        var luminanceStepOfEachPixel = [Int](repeating: -1, count: frame.width * frame.height)
        var usableCount = 0
        for index in 0..<(frame.width * frame.height) where frame.personMask[index] <= 127 {
            let red = frame.rgba[index * 4], green = frame.rgba[index * 4 + 1], blue = frame.rgba[index * 4 + 2]
            let largest = max(red, green, blue), smallest = min(red, green, blue)
            guard largest < clippedLevel, largest > 0, Float(largest - smallest) < saturationLimit * Float(largest) else { continue }
            let luminance = 0.2126 * ShirtColorMath.linearValueOfEachByte[Int(red)] + 0.7152 * ShirtColorMath.linearValueOfEachByte[Int(green)] + 0.0722 * ShirtColorMath.linearValueOfEachByte[Int(blue)]
            let step = min(stepCount - 1, Int(luminance * Float(stepCount)))
            histogram[step] += 1
            luminanceStepOfEachPixel[index] = step
            usableCount += 1
        }
        guard Double(usableCount) >= leastShareOfTheFrame * Double(frame.width * frame.height) else { return nil }
        func stepAtPercentile(_ share: Double) -> Int {
            var counted = 0
            for step in 0..<stepCount {
                counted += histogram[step]
                if Double(counted) >= share * Double(usableCount) { return step }
            }
            return stepCount - 1
        }
        let whiteStep = stepAtPercentile(0.9), brightStep = stepAtPercentile(0.8)
        var brightColorSum = SIMD3<Float>(0, 0, 0)
        for index in luminanceStepOfEachPixel.indices where luminanceStepOfEachPixel[index] >= brightStep {
            brightColorSum += SIMD3(
                ShirtColorMath.linearValueOfEachByte[Int(frame.rgba[index * 4])], ShirtColorMath.linearValueOfEachByte[Int(frame.rgba[index * 4 + 1])],
                ShirtColorMath.linearValueOfEachByte[Int(frame.rgba[index * 4 + 2])]
            )
        }
        let brightLuminance = 0.2126 * brightColorSum.x + 0.7152 * brightColorSum.y + 0.0722 * brightColorSum.z
        guard brightLuminance > 0 else { return nil }
        return ShirtRoomLight(whiteLuminance: (Float(whiteStep) + 0.5) / Float(stepCount), illuminant: brightColorSum / brightLuminance)
    }
}

/// One frame, small: the camera frame and the person mask at the same size, with the torso in the same pixels.
nonisolated struct ShirtSmallFrame: Sendable {
    let width: Int
    let height: Int
    /// Tightly packed RGBA bytes, first row at the top.
    let rgba: [UInt8]
    /// One byte per pixel, 255 where the person is.
    let personMask: [UInt8]
    let torso: BodyTorso

    func color(atColumn column: Int, row: Int) -> SIMD3<Float> {
        let index = (row * width + column) * 4
        return SIMD3(Float(rgba[index]), Float(rgba[index + 1]), Float(rgba[index + 2]))
    }

    /// The median color of the patch just below the shoulders, where the learner's current shirt is for certain: 16 percent
    /// of the shoulder width wide and 8 percent high, centered 12 percent of it below the shoulder midpoint. Nil when the
    /// patch holds under 4 pixels.
    func measureOldShirtColor() -> SIMD3<Float>? {
        let shoulderWidth = torso.shoulderWidth
        let halfWidth = 0.08 * shoulderWidth, halfHeight = 0.04 * shoulderWidth
        let centerX = torso.shoulderMidpoint.x
        let centerY = min(torso.shoulderMidpoint.y + 0.12 * shoulderWidth, Double(height) - halfHeight - 1)
        let columns = max(0, Int((centerX - halfWidth).rounded()))...min(width - 1, Int((centerX + halfWidth).rounded()))
        let rows = max(0, Int((centerY - halfHeight).rounded()))...min(height - 1, Int((centerY + halfHeight).rounded()))
        guard !columns.isEmpty, !rows.isEmpty, columns.count * rows.count >= 4 else { return nil }
        var channelValues: [[Float]] = [[], [], []]
        for row in rows {
            for column in columns {
                let pixelColor = color(atColumn: column, row: row)
                for channel in 0..<3 { channelValues[channel].append(pixelColor[channel]) }
            }
        }
        let median = channelValues.map { values in values.sorted()[values.count / 2] }
        return SIMD3(median[0], median[1], median[2])
    }

    /// Where the learner's neck meets their own shirt: the first row below the chin, on the center column, whose color is
    /// within 45 (of 255, in RGB) of the old shirt's and whose hue, its share of each linear channel, is within 0.1 of the
    /// old shirt's. The neck in the chin's shadow is as dark as a navy shirt, and only its warmer hue tells them apart.
    /// Looked for from 45 percent of a shoulder width above the shoulder line to 20 percent below it, and averaged over
    /// three columns, since the small frame is sharper than the spike's blurred one.
    func bodyNeckRow(oldShirtColor: SIMD3<Float>) -> Double? {
        let shoulderWidth = torso.shoulderWidth
        let centerColumn = Int(torso.shoulderMidpoint.x.rounded())
        let firstRow = max(0, Int((torso.shoulderMidpoint.y - 0.45 * shoulderWidth).rounded()))
        let lastRow = min(height - 1, Int((torso.shoulderMidpoint.y + 0.2 * shoulderWidth).rounded()))
        guard firstRow <= lastRow, centerColumn >= 1, centerColumn < width - 1 else { return nil }
        let oldShirtHue = ShirtColorMath.chromaticity(red: ShirtColorMath.byte(oldShirtColor.x), green: ShirtColorMath.byte(oldShirtColor.y), blue: ShirtColorMath.byte(oldShirtColor.z))
        for row in firstRow...lastRow {
            let averageColor = (color(atColumn: centerColumn - 1, row: row) + color(atColumn: centerColumn, row: row) + color(atColumn: centerColumn + 1, row: row)) / 3
            let difference = averageColor - oldShirtColor
            guard (difference * difference).sum().squareRoot() < 45 else { continue }
            let hue = ShirtColorMath.chromaticity(red: ShirtColorMath.byte(averageColor.x), green: ShirtColorMath.byte(averageColor.y), blue: ShirtColorMath.byte(averageColor.z))
            if let hue, let oldShirtHue, simd_distance(hue, oldShirtHue) >= ShirtColorMath.oldShirtChromaticityDistanceLimitForTheShading { continue }
            return Double(row)
        }
        return nil
    }
}

/// How far one old sleeve reaches on its arm, in the small frame's pixels: down the line from the shoulder joint to the elbow,
/// and out to either side of that line, away from the body and toward it. The new sleeve is drawn to cover it, so the
/// learner's own sleeve never shows past the new one.
nonisolated struct ShirtOldSleeveExtent: Equatable, Sendable {
    let reachAlongTheArm: Double
    let outward: Double
    let inward: Double
}

/// What the renderer needs from one frame.
nonisolated struct ShirtFrameAnalysis: Sendable {
    /// The fractions of the way from the shoulders to the hips at which the old shirt's half width is measured. Above half
    /// way the old sleeves hang beside the torso, so its width there is not the torso's.
    static let torsoWidthFractions = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
    /// A pixel more than this many shoulder widths from the torso's center line, on its side of the body, may be the old
    /// sleeve: the shoulder joints are half a shoulder width out, and the torso below them is a little narrower.
    /// Past this distance from the neck's middle, the old shirt above the neck's base is the tops of the shoulders, which
    /// the fill covers; nearer in it is the collar and the neck, which the neck cut decides.
    static let shoulderTopsLeastDistanceFromTheNeckInShoulderWidths = 0.32
    static let oldSleeveLeastDistanceFromTheCenterInShoulderWidths = 0.45
    /// An old sleeve's width is read from its pixels past this share of its reach down the arm.
    static let oldSleeveWidthIsReadBelowThisShareOfItsReach = 0.6

    /// RGBA bytes the size of the small frame: red is 255 where the new shirt must not draw (the neck, the face, above the
    /// shoulders), green is 255 where the learner's old shirt shows beyond the new shirt's outline and takes its base color,
    /// and blue is 255 on every pixel of the person below the neck that looks like the old shirt and has its chromaticity
    /// (`ShirtColorMath.oldShirtChromaticityDistanceLimitForTheShading`), with no clean-up, which is where the old shirt's own
    /// light can be read for the shading (its print, trim, a panel of another fabric, and the arms are left out).
    let maskPixels: [UInt8]
    /// The median luminance in linear light of the old shirt's pixels in the torso zone, which the shading is a ratio to. The
    /// median, since the mean of a dark shirt in linear light is pulled up by its few lit folds, and the shirt's typical cloth
    /// would then read as shadow.
    let oldShirtMedianLinearLuminance: Float
    /// How far below the shoulder midpoint the old shirt ends, along the body, or nil when it runs to the frame's edge or
    /// cannot be told apart from what is below it.
    let oldShirtHemDistance: Double?
    /// How far the old shirt reaches from the torso's center line, on the image left side and the image right side, at each of
    /// `torsoWidthFractions`, in the small frame's pixels, nil where none of it was found there. The renderer widens the
    /// garment's lower torso to cover it, so less of it needs the fill.
    let oldShirtHalfWidths: [[Double?]]
    /// Each old sleeve, image left first, nil when its elbow is not seen or too little of the sleeve was found.
    let oldSleeves: [ShirtOldSleeveExtent?]

    /// Classifies each pixel of `frame` against `oldShirtColor`, and finds the neck cut and the uncovered old shirt.
    ///
    /// The neck rule is the spike's: a crew neck is a half ellipse around the base of the neck, which is 10 percent of a
    /// shoulder width above the shoulder midpoint. Everything above that base, and the half ellipse below it, is neck or
    /// head, so the new shirt does not draw there unless the pixel is the old collar (which the new shirt then covers).
    /// Everything more than 30 percent of a shoulder width above the base is cut whatever its color.
    ///
    /// The uncovered old shirt is the pixels of the person, in the shirt's zone (below the neck's base, or beside the neck
    /// up to the cut, since the tops of the shoulders rise above the line through the shoulder joints; above where the
    /// garment's hem lands; within `oldShirtZoneHalfWidthInShoulderWidths` of the center), that look like it, with specks
    /// removed and gaps of its trim closed. The zone reaches 0.9 shoulder widths, over the old sleeves, when the garment is
    /// drawn in one piece, and only over the torso when its sleeves are drawn apart, each lengthened over its old sleeve.
    init(frame: ShirtSmallFrame, oldShirtColor: SIMD3<Float>, oldShirtZoneHalfWidthInShoulderWidths: Double = 0.9) {
        let torso = frame.torso
        let width = frame.width, height = frame.height
        let shoulderWidth = torso.shoulderWidth
        func vector(_ point: CGPoint) -> SIMD2<Double> { SIMD2<Double>(Double(point.x), Double(point.y)) }
        let along = (vector(torso.imageRightShoulder) - vector(torso.imageLeftShoulder)) / shoulderWidth
        var upDirection = SIMD2<Double>(along.y, -along.x)
        if upDirection.y > 0 { upDirection = -upDirection }
        let shoulderMidpoint = vector(torso.shoulderMidpoint)
        let neckBase = shoulderMidpoint + upDirection * 0.10 * shoulderWidth
        let hipMidpoint = vector(torso.hipMidpoint)
        let torsoLength = max(simd_length(hipMidpoint - shoulderMidpoint), 1)
        let torsoAxis = (hipMidpoint - shoulderMidpoint) / torsoLength
        // The old shirt's zone ends just above where the garment's hem lands (`ShirtTryOnRenderer.garmentBottomInTorsoLengths`,
        // 1.08 torso lengths), so same-colored trousers never take the shirt's color, and the fill, which the renderer grows a
        // pixel or two under the garment's edge, never draws a band of base color over the waistband below the hem.
        let lowestTorsoDistance = torsoLength * 1.08 - 2

        // Each arm with a seen elbow: its shoulder, its direction down to the elbow, its length, and its side away from the body.
        let arms: [(shoulder: SIMD2<Double>, down: SIMD2<Double>, length: Double, awayFromTheBody: SIMD2<Double>)?] = [
            (torso.imageLeftShoulder, torso.imageLeftElbow), (torso.imageRightShoulder, torso.imageRightElbow),
        ].map { shoulder, elbow in
            guard let elbow else { return nil }
            let armVector = vector(elbow) - vector(shoulder)
            guard simd_length(armVector) > 2 else { return nil }
            let down = simd_normalize(armVector)
            var away = SIMD2(-down.y, down.x)
            if simd_dot(away, vector(shoulder) - shoulderMidpoint) < 0 { away = -away }
            return (vector(shoulder), down, simd_length(armVector), away)
        }
        var oldSleevePoints: [[(alongTheArm: Double, outward: Double)]] = [[], []]

        let oldShirtLab = ShirtColorMath.lab(red: ShirtColorMath.byte(oldShirtColor.x), green: ShirtColorMath.byte(oldShirtColor.y), blue: ShirtColorMath.byte(oldShirtColor.z))
        let oldShirtChromaticity = ShirtColorMath.chromaticity(red: ShirtColorMath.byte(oldShirtColor.x), green: ShirtColorMath.byte(oldShirtColor.y), blue: ShirtColorMath.byte(oldShirtColor.z))
        var looksLikeTheOldShirt = [Bool](repeating: false, count: width * height)
        var oldShirtForTheShading = [Bool](repeating: false, count: width * height)
        var cut = [Bool](repeating: false, count: width * height)
        var uncovered = [Bool](repeating: false, count: width * height)
        var inTheOldShirtZone = [Bool](repeating: false, count: width * height)
        var oldShirtPixelCount = 0
        // A histogram of linear luminance finds the median without sorting.
        let linearLuminanceStepCount = 2048
        var linearLuminanceHistogram = [Int](repeating: 0, count: linearLuminanceStepCount)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                let pixelIndex = index * 4
                let labOfPixel = ShirtColorMath.quickLab(red: frame.rgba[pixelIndex], green: frame.rgba[pixelIndex + 1], blue: frame.rgba[pixelIndex + 2])
                let looksOld = ShirtColorMath.distance(from: labOfPixel, to: oldShirtLab) < ShirtColorMath.oldShirtDistanceLimit
                looksLikeTheOldShirt[index] = looksOld
                let offset = SIMD2(Double(column), Double(row)) - neckBase
                let across = simd_dot(offset, along), upward = simd_dot(offset, upDirection)
                let acrossShare = across / (0.21 * shoulderWidth), upwardShare = min(upward, 0) / (0.16 * shoulderWidth)
                let insideTheNeck = acrossShare * acrossShare + upwardShare * upwardShare < 1
                let aboveTheShoulders = upward > 0.04 * shoulderWidth && abs(across) < 0.30 * shoulderWidth
                cut[index] = ((insideTheNeck || aboveTheShoulders || upward > 0) && !looksOld) || upward > 0.30 * shoulderWidth
                let isPerson = frame.personMask[index] > 127
                let pixelChromaticity = looksOld && isPerson && upward < 0
                    ? ShirtColorMath.chromaticity(red: frame.rgba[pixelIndex], green: frame.rgba[pixelIndex + 1], blue: frame.rgba[pixelIndex + 2]) : nil
                oldShirtForTheShading[index] = pixelChromaticity.map { chromaticity in
                    oldShirtChromaticity.map { simd_distance(chromaticity, $0) < ShirtColorMath.oldShirtChromaticityDistanceLimitForTheShading } ?? true
                } ?? false
                let distanceFromTheShoulders = simd_dot(SIMD2(Double(column), Double(row)) - shoulderMidpoint, torsoAxis)
                // The old shirt's sleeves reach about 0.9 shoulder widths either side of the center, so something farther out that
                // happens to share its color, such as a dark chair back, is not the shirt.
                let acrossFromTheCenter = simd_dot(SIMD2(Double(column), Double(row)) - shoulderMidpoint, along)
                let besideTheNeckBelowTheCut = abs(across) > Self.shoulderTopsLeastDistanceFromTheNeckInShoulderWidths * shoulderWidth && upward < 0.30 * shoulderWidth
                inTheOldShirtZone[index] = isPerson && (upward < 0 || besideTheNeckBelowTheCut) && distanceFromTheShoulders < lowestTorsoDistance
                    && abs(acrossFromTheCenter) < oldShirtZoneHalfWidthInShoulderWidths * shoulderWidth
                // The old sleeve: the old shirt beside the torso, near the line from a shoulder down to its elbow.
                if looksOld, isPerson, upward < 0, abs(acrossFromTheCenter) > Self.oldSleeveLeastDistanceFromTheCenterInShoulderWidths * shoulderWidth {
                    let side = acrossFromTheCenter < 0 ? 0 : 1
                    if let arm = arms[side] {
                        let offset = SIMD2(Double(column), Double(row)) - arm.shoulder
                        let alongTheArm = simd_dot(offset, arm.down), outward = simd_dot(offset, arm.awayFromTheBody)
                        if alongTheArm > 0, alongTheArm < arm.length, abs(outward) < 0.45 * shoulderWidth { oldSleevePoints[side].append((alongTheArm, outward)) }
                    }
                }
                if looksOld, inTheOldShirtZone[index] {
                    uncovered[index] = true
                    let linearLuminance = 0.2126 * ShirtColorMath.linearValueOfEachByte[Int(frame.rgba[pixelIndex])]
                        + 0.7152 * ShirtColorMath.linearValueOfEachByte[Int(frame.rgba[pixelIndex + 1])]
                        + 0.0722 * ShirtColorMath.linearValueOfEachByte[Int(frame.rgba[pixelIndex + 2])]
                    linearLuminanceHistogram[min(linearLuminanceStepCount - 1, Int(linearLuminance * Float(linearLuminanceStepCount)))] += 1
                    oldShirtPixelCount += 1
                }
            }
        }
        // With no old shirt pixels to measure, the old color itself stands for them.
        let colorLinearLuminance = 0.2126 * ShirtColorMath.linearValueOfEachByte[Int(ShirtColorMath.byte(oldShirtColor.x))]
            + 0.7152 * ShirtColorMath.linearValueOfEachByte[Int(ShirtColorMath.byte(oldShirtColor.y))]
            + 0.0722 * ShirtColorMath.linearValueOfEachByte[Int(ShirtColorMath.byte(oldShirtColor.z))]
        var medianStep: Int?
        var countedPixels = 0
        for step in 0..<linearLuminanceStepCount where medianStep == nil {
            countedPixels += linearLuminanceHistogram[step]
            if 2 * countedPixels >= oldShirtPixelCount { medianStep = step }
        }
        oldShirtMedianLinearLuminance = oldShirtPixelCount > 0 ? (Float(medianStep ?? 0) + 0.5) / Float(linearLuminanceStepCount) : colorLinearLuminance

        precondition(width >= 3 && height >= 3, "The analysis needs a frame of at least 3 by 3 pixels")
        // A pixel with fewer than 3 old-shirt neighbors in its 8 is a speck, not a patch of shirt the garment missed.
        var despeckled = uncovered
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) where uncovered[row * width + column] {
                var neighborCount = 0
                for rowOffset in -1...1 {
                    for columnOffset in -1...1 where (rowOffset != 0 || columnOffset != 0) && uncovered[(row + rowOffset) * width + column + columnOffset] { neighborCount += 1 }
                }
                despeckled[row * width + column] = neighborCount >= 3
            }
        }
        // The old shirt's trim, a stripe or a seam a couple of small pixels wide, is not its color but sits inside it. Closing
        // the mask (growing it by a pixel and shrinking it back) swallows such gaps, and the zone keeps it from spreading.
        let closed = Self.eroded(Self.dilated(despeckled, width: width, height: height), width: width, height: height)
        for index in despeckled.indices { despeckled[index] = closed[index] && inTheOldShirtZone[index] }

        // The old shirt's half width on each side, at each fraction of the way down the torso, within 3 percent of it.
        var halfWidths: [[Double?]] = [Array(repeating: nil, count: Self.torsoWidthFractions.count), Array(repeating: nil, count: Self.torsoWidthFractions.count)]
        for index in despeckled.indices where despeckled[index] {
            let point = SIMD2(Double(index % width), Double(index / width))
            let fraction = simd_dot(point - shoulderMidpoint, torsoAxis) / torsoLength
            guard let bucket = Self.torsoWidthFractions.firstIndex(where: { abs($0 - fraction) < 0.03 }) else { continue }
            let across = simd_dot(point - shoulderMidpoint, along)
            let side = across < 0 ? 0 : 1
            halfWidths[side][bucket] = max(halfWidths[side][bucket] ?? 0, abs(across))
        }
        oldShirtHalfWidths = halfWidths
        // Each old sleeve's reach and width, from the 95th percentiles, so a stray pixel of the old shirt's color on the arm
        // does not stretch the new sleeve. Its width is read over its lower part, where the new sleeve's opening must cover it;
        // up by the armpit its inner side runs into the torso. Under 20 pixels is not a sleeve.
        oldSleeves = oldSleevePoints.map { points in
            guard points.count >= 20 else { return nil }
            func nearlyTheLargest(_ values: [Double]) -> Double { values.sorted()[Int(0.95 * Double(values.count - 1))] }
            let reach = nearlyTheLargest(points.map(\.alongTheArm))
            let lowerPart = points.filter { $0.alongTheArm > Self.oldSleeveWidthIsReadBelowThisShareOfItsReach * reach }
            guard !lowerPart.isEmpty else { return nil }
            return ShirtOldSleeveExtent(
                reachAlongTheArm: reach, outward: nearlyTheLargest(lowerPart.map(\.outward)), inward: nearlyTheLargest(lowerPart.map { -$0.outward })
            )
        }
        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            maskPixels[index * 4] = cut[index] ? 255 : 0
            maskPixels[index * 4 + 1] = despeckled[index] ? 255 : 0
            maskPixels[index * 4 + 2] = oldShirtForTheShading[index] ? 255 : 0
            maskPixels[index * 4 + 3] = 255
        }
        self.maskPixels = maskPixels

        // Down the body from the shoulders, a band across the torso is sampled one pixel at a time: how much of it looks like
        // the old shirt, and how bright it is. Where the shirt ends is found from those two profiles.
        var oldShirtShareOfTheBand: [Double] = []
        var lightnessOfTheBand: [Double] = []
        var distance = 0.0
        // A hem further than 2 shoulder widths down is not accepted, so the profiles stop 6 pixels past it.
        while distance <= 2.0 * shoulderWidth + 6 {
            let center = shoulderMidpoint + torsoAxis * distance
            guard center.y < Double(height - 1), center.x > 0, center.x < Double(width - 1) else { break }
            var sampleCount = 0, oldShirtCount = 0, lightnessSum = 0.0, personSampleCount = 0
            var sideOffset = -0.3 * shoulderWidth
            while sideOffset <= 0.3 * shoulderWidth {
                let point = center + along * sideOffset
                let column = Int(point.x.rounded()), row = Int(point.y.rounded())
                if column >= 0, column < width, row >= 0, row < height {
                    sampleCount += 1
                    let index = row * width + column
                    if frame.personMask[index] > 127 {
                        personSampleCount += 1
                        lightnessSum += 0.299 * Double(frame.rgba[index * 4]) + 0.587 * Double(frame.rgba[index * 4 + 1]) + 0.114 * Double(frame.rgba[index * 4 + 2])
                        if looksLikeTheOldShirt[index] { oldShirtCount += 1 }
                    }
                }
                sideOffset += 1
            }
            oldShirtShareOfTheBand.append(sampleCount > 0 ? Double(oldShirtCount) / Double(sampleCount) : 1)
            lightnessOfTheBand.append(personSampleCount > 0 ? lightnessSum / Double(personSampleCount) : .nan)
            distance += 1
        }
        oldShirtHemDistance = Self.hemDistance(oldShirtShareOfTheBand: oldShirtShareOfTheBand, lightnessOfTheBand: lightnessOfTheBand, shoulderWidth: shoulderWidth)
    }

    /// Where the old shirt ends, in pixels below the shoulder midpoint, from the band profiles (one value per pixel of
    /// distance), or nil. A shirt of the old color ends where the share of the band that looks like it falls under 35 percent
    /// for three pixels. A dark shirt over dark trousers keeps looking like itself, so when that finds nothing the hem is the
    /// largest drop in the band's lightness, at least a quarter of it from 5 pixels above to 5 below. Only a hem between 0.9
    /// and 2.0 shoulder widths below the shoulders counts, since a torso is about 1.45 long and anything else is a misread.
    static func hemDistance(oldShirtShareOfTheBand: [Double], lightnessOfTheBand: [Double], shoulderWidth: Double) -> Double? {
        let shortestHem = 0.9 * shoulderWidth, longestHem = 2.0 * shoulderWidth
        var missesInARow = 0
        guard oldShirtShareOfTheBand.count > Int(0.6 * shoulderWidth) else { return nil }
        for distance in Int(0.6 * shoulderWidth)..<oldShirtShareOfTheBand.count {
            if oldShirtShareOfTheBand[distance] < 0.35 {
                missesInARow += 1
                if missesInARow >= 3 {
                    let hem = Double(distance - 2)
                    if hem >= shortestHem && hem <= longestHem { return hem }
                    break
                }
            } else {
                missesInARow = 0
            }
        }
        var bestDrop = 0.25
        var bestHem: Double?
        let lowestStep = max(5, Int(shortestHem.rounded(.up)))
        let highestStep = min(lightnessOfTheBand.count - 6, Int(longestHem))
        guard lowestStep <= highestStep else { return nil }
        for step in lowestStep...highestStep {
            let above = lightnessOfTheBand[(step - 5)..<step], below = lightnessOfTheBand[(step + 1)...(step + 5)]
            guard !above.contains(where: \.isNaN), !below.contains(where: \.isNaN) else { continue }
            let aboveMean = above.reduce(0, +) / 5, belowMean = below.reduce(0, +) / 5
            let drop = (aboveMean - belowMean) / max(aboveMean, 8)
            if drop > bestDrop { bestDrop = drop; bestHem = Double(step) }
        }
        return bestHem
    }

    /// `mask` grown by one pixel in each of the 8 directions.
    private static func dilated(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var grown = mask
        for row in 0..<height {
            for column in 0..<width where !mask[row * width + column] {
                grown[row * width + column] = neighborhoodHas(mask, width: width, height: height, column: column, row: row, value: true)
            }
        }
        return grown
    }

    /// `mask` shrunk by one pixel from each of the 8 directions. A pixel at the frame's edge shrinks only from inside.
    private static func eroded(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var shrunk = mask
        for row in 0..<height {
            for column in 0..<width where mask[row * width + column] {
                shrunk[row * width + column] = !neighborhoodHas(mask, width: width, height: height, column: column, row: row, value: false)
            }
        }
        return shrunk
    }

    private static func neighborhoodHas(_ mask: [Bool], width: Int, height: Int, column: Int, row: Int, value: Bool) -> Bool {
        for neighborRow in max(0, row - 1)...min(height - 1, row + 1) {
            for neighborColumn in max(0, column - 1)...min(width - 1, column + 1) where mask[neighborRow * width + neighborColumn] == value { return true }
        }
        return false
    }
}
