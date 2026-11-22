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

    private static let linearValueOfEachByte: [Float] = (0..<256).map { byte in
        let srgb = Float(byte) / 255
        return srgb <= 0.04045 ? srgb / 12.92 : pow((srgb + 0.055) / 1.055, 2.4)
    }

    /// Lightness from 0 to 255, then a and b around 128: the scaling OpenCV gives an 8-bit Lab image, which the distance
    /// limit above was tuned in.
    static func lab(red: UInt8, green: UInt8, blue: UInt8) -> SIMD3<Float> {
        let linearRed = linearValueOfEachByte[Int(red)], linearGreen = linearValueOfEachByte[Int(green)], linearBlue = linearValueOfEachByte[Int(blue)]
        let x = (0.4124564 * linearRed + 0.3575761 * linearGreen + 0.1804375 * linearBlue) / 0.950456
        let y = 0.2126729 * linearRed + 0.7151522 * linearGreen + 0.0721750 * linearBlue
        let z = (0.0193339 * linearRed + 0.1191920 * linearGreen + 0.9503041 * linearBlue) / 1.088754
        func labCurve(_ value: Float) -> Float { value > 0.008856 ? cbrt(value) : 7.787 * value + 16 / 116 }
        let fx = labCurve(x), fy = labCurve(y), fz = labCurve(z)
        return SIMD3((116 * fy - 16) * 255 / 100, 500 * (fx - fy) + 128, 200 * (fy - fz) + 128)
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
    /// within 45 (of 255, in RGB) of the old shirt's. Looked for from 45 percent of a shoulder width above the shoulder line
    /// to 20 percent below it, and averaged over three columns, since the small frame is sharper than the spike's blurred one.
    func bodyNeckRow(oldShirtColor: SIMD3<Float>) -> Double? {
        let shoulderWidth = torso.shoulderWidth
        let centerColumn = Int(torso.shoulderMidpoint.x.rounded())
        let firstRow = max(0, Int((torso.shoulderMidpoint.y - 0.45 * shoulderWidth).rounded()))
        let lastRow = min(height - 1, Int((torso.shoulderMidpoint.y + 0.2 * shoulderWidth).rounded()))
        guard firstRow <= lastRow, centerColumn >= 1, centerColumn < width - 1 else { return nil }
        for row in firstRow...lastRow {
            let averageColor = (color(atColumn: centerColumn - 1, row: row) + color(atColumn: centerColumn, row: row) + color(atColumn: centerColumn + 1, row: row)) / 3
            let difference = averageColor - oldShirtColor
            if (difference * difference).sum().squareRoot() < 45 { return Double(row) }
        }
        return nil
    }
}

/// What the renderer needs from one frame.
nonisolated struct ShirtFrameAnalysis: Sendable {
    /// RGBA bytes the size of the small frame: red is 255 where the new shirt must not draw (the neck, the face, above the
    /// shoulders), green is 255 where the learner's old shirt shows beyond the new shirt's outline and takes its base color.
    let maskPixels: [UInt8]
    /// The old shirt's average lightness and average of all channels, both from 0 to 1, over its pixels in the torso zone.
    let oldShirtMeanLuminance: Float
    let oldShirtMeanBrightness: Float
    /// How far below the shoulder midpoint the old shirt ends, along the body, or nil when it runs to the frame's edge or
    /// cannot be told apart from what is below it.
    let oldShirtHemDistance: Double?

    /// Classifies each pixel of `frame` against `oldShirtColor`, and finds the neck cut and the uncovered old shirt.
    ///
    /// The neck rule is the spike's: a crew neck is a half ellipse around the base of the neck, which is 10 percent of a
    /// shoulder width above the shoulder midpoint. Everything above that base, and the half ellipse below it, is neck or
    /// head, so the new shirt does not draw there unless the pixel is the old collar (which the new shirt then covers).
    /// Everything more than 30 percent of a shoulder width above the base is cut whatever its color.
    ///
    /// The uncovered old shirt is the pixels of the person, in the shirt's zone (below the shoulder line, above a little
    /// under the hips, within 0.9 shoulder widths of the center), that look like it, with specks removed and gaps of its trim
    /// closed.
    init(frame: ShirtSmallFrame, oldShirtColor: SIMD3<Float>) {
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
        // The old shirt's zone ends a little below the hips, so same-colored trousers never take the shirt's color.
        let lowestTorsoDistance = torsoLength * 1.10 + 0.05 * shoulderWidth

        let oldShirtLab = ShirtColorMath.lab(red: ShirtColorMath.byte(oldShirtColor.x), green: ShirtColorMath.byte(oldShirtColor.y), blue: ShirtColorMath.byte(oldShirtColor.z))
        var looksLikeTheOldShirt = [Bool](repeating: false, count: width * height)
        var cut = [Bool](repeating: false, count: width * height)
        var uncovered = [Bool](repeating: false, count: width * height)
        var inTheOldShirtZone = [Bool](repeating: false, count: width * height)
        var luminanceSum = 0.0, brightnessSum = 0.0, oldShirtPixelCount = 0
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
                let distanceFromTheShoulders = simd_dot(SIMD2(Double(column), Double(row)) - shoulderMidpoint, torsoAxis)
                // The old shirt's sleeves reach about 0.9 shoulder widths either side of the center, so something farther out that
                // happens to share its color, such as a dark chair back, is not the shirt.
                let acrossFromTheCenter = simd_dot(SIMD2(Double(column), Double(row)) - shoulderMidpoint, along)
                inTheOldShirtZone[index] = isPerson && upward < 0 && distanceFromTheShoulders < lowestTorsoDistance && abs(acrossFromTheCenter) < 0.9 * shoulderWidth
                if looksOld, inTheOldShirtZone[index] {
                    uncovered[index] = true
                    let red = Double(frame.rgba[pixelIndex]), green = Double(frame.rgba[pixelIndex + 1]), blue = Double(frame.rgba[pixelIndex + 2])
                    luminanceSum += (0.299 * red + 0.587 * green + 0.114 * blue) / 255
                    brightnessSum += (red + green + blue) / (3 * 255)
                    oldShirtPixelCount += 1
                }
            }
        }
        // With no old shirt pixels to measure, the old color itself stands for them.
        let colorLuminance: Float = (0.299 * oldShirtColor.x + 0.587 * oldShirtColor.y + 0.114 * oldShirtColor.z) / 255
        let colorBrightness: Float = (oldShirtColor.x + oldShirtColor.y + oldShirtColor.z) / (3 * 255)
        oldShirtMeanLuminance = oldShirtPixelCount > 0 ? Float(luminanceSum / Double(oldShirtPixelCount)) : colorLuminance
        oldShirtMeanBrightness = oldShirtPixelCount > 0 ? Float(brightnessSum / Double(oldShirtPixelCount)) : colorBrightness

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
        var maskPixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            maskPixels[index * 4] = cut[index] ? 255 : 0
            maskPixels[index * 4 + 1] = despeckled[index] ? 255 : 0
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
