//
//  ShirtLookCheckTests.swift
//  leanring-buddyTests
//
//  Measures whether a drawn shirt looks worn in the room instead of pasted on: real product photos drawn on a real photo of
//  a person, with the real Vision requests, each composite saved as a PNG with its numbers in a JSON file. It runs only when
//  SHIRT_TRYON_PHOTOS_DIR names a folder with standing.jpg (a person standing in a camera frame, a personal photo that is
//  never committed) and uE*.jpg flat lay product photos, and SHIRT_TRYON_OUTPUT_DIR names where the files go:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos SHIRT_TRYON_OUTPUT_DIR=/path/out tools/swift-check.sh --filter ShirtLookCheck
//
//  Each check is one way a pasted-on shirt gives itself away:
//  - clipping: the garment's highlights blow out to white, which the camera's own shirt never did;
//  - exposure: the garment is lit like the product photo instead of like the room;
//  - white balance: a neutral part of the garment is not the color of a neutral surface in the room;
//  - shading: the folds and light across the learner's body do not carry onto the garment;
//  - halo outside: the garment draws past the person onto the room;
//  - halo inside: the garment's edge is a light rim, from the product photo's background or from a soft mask;
//  - old shirt: the learner's own shirt still shows inside the new one;
//  - sleeves: a drawn sleeve does not follow the upper arm.
//  Two measures were tried and dropped as not measuring the garment: a sleeve's pixels on the person (the person mask clips
//  its top at the shoulder's outline) and the old shirt's unchanged pixels (a navy stripe over a navy shirt barely changes).
//  The room and the albedo are measured here at full size, apart from the renderer's own small copy, so a check does not
//  only repeat the renderer's arithmetic.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import Vision
@testable import Clicky

private let lookCheckEnvironment = ProcessInfo.processInfo.environment

/// The numbers one composite is judged by, written next to its PNG.
struct ShirtLookMetrics: Codable {
    var shirtName = ""
    /// Share of the garment's pixels with a channel at 250 or above, and the share of the same pixels in the original frame.
    var clippedShareOfTheGarment = 0.0
    var clippedShareOfTheOriginal = 0.0
    /// The garment's median linear luminance, its median albedo (the product photo over its own white), the room's white
    /// (the 90th percentile of unsaturated, unclipped pixels off the person), and the first over the product of the other two.
    var garmentMedianLuminance = 0.0
    var albedoMedianLuminance = 0.0
    var roomWhiteLuminance = 0.0
    var exposureRatio = 0.0
    /// The median CIE76 distance in a and b from the garment's neutral pixels to the room's neutral at their lightness, nil
    /// when the garment has too few neutral pixels to judge.
    var whiteBalanceDeltaE: Double?
    var neutralGarmentPixelCount = 0
    /// The correlation of the garment's low-pass log shading with the original torso's.
    var shadingCorrelation = 0.0
    /// The mean change, in 8-bit levels, in the 6 pixel band just outside the person matte.
    var haloOutsideMeanChange = 0.0
    /// The brightest ratio, over 16 sectors around the garment, of the 4 pixel band inside its edge to the band behind it,
    /// each band's light being the sum of the composite's luminance over the sum of the drawn cloth's own (`warpedGarmentColor`),
    /// so a print or a stripe that happens to run along the edge is not a rim, and extra light or the room's color at the edge
    /// is.
    var haloInsideWorstRimRatio = 0.0
    /// Where that sector points from the garment's center, in degrees, 0 to the image right and 90 down.
    var haloInsideWorstSectorDegrees = 0.0
    /// The share of the old shirt's pixels in the torso that the composite left showing: nothing was drawn over them (the
    /// drawn coverage is under one half) and they are as they were. A navy stripe drawn over a navy shirt changes a pixel
    /// little but covers it.
    var oldShirtStillShowingShare = 0.0
    /// Each drawn sleeve's angle away from its shoulder-to-elbow line, in degrees, measured where the sleeve shows.
    var sleeveAxisErrorsDegrees: [Double] = []
}

/// The limits each composite must meet.
enum ShirtLookLimits {
    static let clippingAllowanceOverTheOriginal = 0.01
    static let exposureRatioRange = 0.7...1.15
    static let whiteBalanceDeltaE = 8.0
    static let shadingCorrelation = 0.6
    static let haloOutsideMeanChange = 2.0
    static let haloInsideRimRatio = 1.10
    static let oldShirtStillShowingShare = 0.01
    static let sleeveAxisErrorDegrees = 12.0
}

// MARK: - Pixels

private let linearOfEachByte: [Double] = (0..<256).map { byte in
    let encoded = Double(byte) / 255
    return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
}

private func linearLuminance(red: Double, green: Double, blue: Double) -> Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

/// CIE Lab (L from 0 to 100) of a linear sRGB color, white D65.
private func cieLab(linearRed: Double, linearGreen: Double, linearBlue: Double) -> SIMD3<Double> {
    let x = (0.4124564 * linearRed + 0.3575761 * linearGreen + 0.1804375 * linearBlue) / 0.95047
    let y = 0.2126729 * linearRed + 0.7151522 * linearGreen + 0.0721750 * linearBlue
    let z = (0.0193339 * linearRed + 0.1191920 * linearGreen + 0.9503041 * linearBlue) / 1.08883
    func curve(_ value: Double) -> Double { value > 0.008856 ? cbrt(value) : 7.787 * value + 16 / 116 }
    let fx = curve(x), fy = curve(y), fz = curve(z)
    return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
}

/// An image read back as RGBA bytes, top row first.
private struct LookPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    /// `colorSpace` nil reads the values Core Image holds, as a mask needs.
    init(_ image: CIImage, extent: CGRect, context: CIContext, colorSpace: CGColorSpace?) {
        let renderedWidth = Int(extent.width), renderedHeight = Int(extent.height)
        width = renderedWidth
        height = renderedHeight
        var rendered = [UInt8](repeating: 0, count: renderedWidth * renderedHeight * 4)
        rendered.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: renderedWidth * 4, bounds: extent, format: .RGBA8, colorSpace: colorSpace)
        }
        bytes = rendered
    }

    func channel(_ index: Int, at pixel: Int) -> UInt8 { bytes[pixel * 4 + index] }
    func linear(at pixel: Int) -> SIMD3<Double> {
        SIMD3(linearOfEachByte[Int(bytes[pixel * 4])], linearOfEachByte[Int(bytes[pixel * 4 + 1])], linearOfEachByte[Int(bytes[pixel * 4 + 2])])
    }
    func luminance(at pixel: Int) -> Double {
        let color = linear(at: pixel)
        return linearLuminance(red: color.x, green: color.y, blue: color.z)
    }
}

/// `mask` grown (`grow` true) or shrunk by `radius` pixels with a square, as two passes along the rows and the columns.
private func squareMorphology(_ mask: [Bool], width: Int, height: Int, radius: Int, grow: Bool) -> [Bool] {
    var alongTheRows = [Bool](repeating: !grow, count: mask.count)
    for row in 0..<height {
        for column in 0..<width {
            var result = !grow
            for offset in -radius...radius {
                let neighbor = column + offset
                // Outside the frame counts as not the mask, so shrinking pulls in from the frame's edge too.
                let value = neighbor >= 0 && neighbor < width ? mask[row * width + neighbor] : false
                if grow ? value : !value { result = grow; break }
            }
            alongTheRows[row * width + column] = result
        }
    }
    var result = [Bool](repeating: !grow, count: mask.count)
    for row in 0..<height {
        for column in 0..<width {
            var value = !grow
            for offset in -radius...radius {
                let neighbor = row + offset
                let neighborValue = neighbor >= 0 && neighbor < height ? alongTheRows[neighbor * width + column] : false
                if grow ? neighborValue : !neighborValue { value = grow; break }
            }
            result[row * width + column] = value
        }
    }
    return result
}

/// The mean of `values` over the pixels in `included` within a square of `radius` around each pixel, through summed area
/// tables. Pixels with nothing included around them get nan.
private func includedBoxMean(_ values: [Double], included: [Bool], width: Int, height: Int, radius: Int) -> [Double] {
    var valueSums = [Double](repeating: 0, count: (width + 1) * (height + 1))
    var countSums = [Double](repeating: 0, count: (width + 1) * (height + 1))
    for row in 0..<height {
        var rowValue = 0.0, rowCount = 0.0
        for column in 0..<width {
            let pixel = row * width + column
            if included[pixel] { rowValue += values[pixel]; rowCount += 1 }
            valueSums[(row + 1) * (width + 1) + column + 1] = valueSums[row * (width + 1) + column + 1] + rowValue
            countSums[(row + 1) * (width + 1) + column + 1] = countSums[row * (width + 1) + column + 1] + rowCount
        }
    }
    var means = [Double](repeating: .nan, count: width * height)
    for row in 0..<height {
        for column in 0..<width {
            let top = max(0, row - radius), bottom = min(height, row + radius + 1), left = max(0, column - radius), right = min(width, column + radius + 1)
            func boxSum(_ sums: [Double]) -> Double {
                sums[bottom * (width + 1) + right] - sums[top * (width + 1) + right] - sums[bottom * (width + 1) + left] + sums[top * (width + 1) + left]
            }
            let count = boxSum(countSums)
            if count > 0 { means[row * width + column] = boxSum(valueSums) / count }
        }
    }
    return means
}

private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

private func percentile(_ values: [Double], _ share: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(share * Double(sorted.count)))]
}

private func isInside(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
    var inside = false
    var previous = polygon[polygon.count - 1]
    for current in polygon {
        if (current.y > point.y) != (previous.y > point.y),
           point.x < (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x {
            inside.toggle()
        }
        previous = current
    }
    return inside
}

// MARK: - The room and the product photo, measured here

/// The room's white and its illuminant, from the frame at full size: pixels off the person, unsaturated (their channels
/// within 25 percent of each other), and not clipped. White is their 90th percentile of linear luminance, and the
/// illuminant is the mean color of the brightest fifth of them with a luminance of 1.
private func roomWhiteAndIlluminant(original: LookPixels, personAt: (Int) -> Bool) -> (white: Double, illuminant: SIMD3<Double>) {
    var luminances: [Double] = []
    var candidates: [Int] = []
    for pixel in 0..<(original.width * original.height) where !personAt(pixel) {
        let red = original.channel(0, at: pixel), green = original.channel(1, at: pixel), blue = original.channel(2, at: pixel)
        let largest = max(red, green, blue), smallest = min(red, green, blue)
        guard largest < 250, largest > 0, Double(largest - smallest) / Double(largest) < 0.25 else { continue }
        luminances.append(original.luminance(at: pixel))
        candidates.append(pixel)
    }
    let white = percentile(luminances, 0.9)
    let brightThreshold = percentile(luminances, 0.8)
    var colorSum = SIMD3<Double>(0, 0, 0)
    for (index, pixel) in candidates.enumerated() where luminances[index] >= brightThreshold { colorSum += original.linear(at: pixel) }
    let illuminantLuminance = linearLuminance(red: colorSum.x, green: colorSum.y, blue: colorSum.z)
    return (white, illuminantLuminance > 0 ? colorSum / illuminantLuminance : SIMD3(1, 1, 1))
}

/// The product photo's white, linear: the median of its outer 20 pixel border, raised to the garment's 98th percentile of
/// luminance when the garment is brighter than its background (a white shirt on a light gray sweep).
private func productPhotoWhite(productPhoto: CGImage, garment: ShirtGarment, context: CIContext) -> SIMD3<Double> {
    let photo = LookPixels(CIImage(cgImage: productPhoto), extent: CGRect(x: 0, y: 0, width: productPhoto.width, height: productPhoto.height), context: context, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    var borderChannels: [[Double]] = [[], [], []]
    for row in 0..<photo.height {
        for column in 0..<photo.width where row < 20 || row >= photo.height - 20 || column < 20 || column >= photo.width - 20 {
            let linear = photo.linear(at: row * photo.width + column)
            borderChannels[0].append(linear.x); borderChannels[1].append(linear.y); borderChannels[2].append(linear.z)
        }
    }
    let border = SIMD3(median(borderChannels[0]), median(borderChannels[1]), median(borderChannels[2]))
    let cutout = LookPixels(garment.cutout, extent: garment.cutout.extent, context: context, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    var garmentLuminances: [Double] = []
    for pixel in 0..<(cutout.width * cutout.height) where cutout.channel(3, at: pixel) == 255 { garmentLuminances.append(cutout.luminance(at: pixel)) }
    let borderLuminance = linearLuminance(red: border.x, green: border.y, blue: border.z)
    return border * max(1, percentile(garmentLuminances, 0.98) / borderLuminance)
}

// MARK: - The measurements

private struct LookInputs {
    let original: LookPixels
    let composite: LookPixels
    let person: LookPixels
    let garmentAlpha: LookPixels
    let totalAlpha: LookPixels
    let warpedGarment: LookPixels
    let sleeves: [(axis: CGVector, shoulder: CGPoint, elbow: CGPoint)]
    let landedTorsoCorners: [CGPoint]
    let oldShirtColor: SIMD3<Float>
    let photoWhite: SIMD3<Double>
}

private func measure(_ inputs: LookInputs, shirtName: String) -> ShirtLookMetrics {
    let width = inputs.original.width, height = inputs.original.height, pixelCount = width * height
    var metrics = ShirtLookMetrics()
    metrics.shirtName = shirtName
    let isPerson = (0..<pixelCount).map { inputs.person.channel(0, at: $0) >= 128 }
    let isGarment = (0..<pixelCount).map { inputs.garmentAlpha.channel(0, at: $0) >= 128 }
    let isGarmentCore = (0..<pixelCount).map { inputs.garmentAlpha.channel(0, at: $0) >= 230 }

    // Clipping.
    var garmentCount = 0, garmentClipped = 0, originalClipped = 0
    for pixel in 0..<pixelCount where isGarment[pixel] {
        garmentCount += 1
        if max(inputs.composite.channel(0, at: pixel), inputs.composite.channel(1, at: pixel), inputs.composite.channel(2, at: pixel)) >= 250 { garmentClipped += 1 }
        if max(inputs.original.channel(0, at: pixel), inputs.original.channel(1, at: pixel), inputs.original.channel(2, at: pixel)) >= 250 { originalClipped += 1 }
    }
    metrics.clippedShareOfTheGarment = Double(garmentClipped) / Double(max(garmentCount, 1))
    metrics.clippedShareOfTheOriginal = Double(originalClipped) / Double(max(garmentCount, 1))

    // Exposure.
    let room = roomWhiteAndIlluminant(original: inputs.original, personAt: { isPerson[$0] })
    metrics.roomWhiteLuminance = room.white
    var garmentLuminances: [Double] = [], albedoLuminances: [Double] = []
    var albedoOfEachPixel = [SIMD3<Double>](repeating: .zero, count: pixelCount)
    for pixel in 0..<pixelCount where isGarmentCore[pixel] {
        let albedo = inputs.warpedGarment.linear(at: pixel) / inputs.photoWhite
        albedoOfEachPixel[pixel] = albedo
        albedoLuminances.append(linearLuminance(red: albedo.x, green: albedo.y, blue: albedo.z))
        garmentLuminances.append(inputs.composite.luminance(at: pixel))
    }
    metrics.garmentMedianLuminance = median(garmentLuminances)
    metrics.albedoMedianLuminance = median(albedoLuminances)
    metrics.exposureRatio = metrics.garmentMedianLuminance / (metrics.albedoMedianLuminance * room.white)

    // White balance: the garment's neutral pixels against the room's illuminant at the same luminance.
    var neutralDistances: [Double] = []
    for pixel in 0..<pixelCount where isGarmentCore[pixel] {
        let albedo = simd_min(albedoOfEachPixel[pixel], SIMD3(1, 1, 1))
        let albedoLab = cieLab(linearRed: albedo.x, linearGreen: albedo.y, linearBlue: albedo.z)
        guard albedoLab.x > 40, (albedoLab.y * albedoLab.y + albedoLab.z * albedoLab.z).squareRoot() < 6 else { continue }
        let drawn = inputs.composite.linear(at: pixel)
        let drawnLab = cieLab(linearRed: drawn.x, linearGreen: drawn.y, linearBlue: drawn.z)
        let expected = room.illuminant * linearLuminance(red: drawn.x, green: drawn.y, blue: drawn.z)
        let expectedLab = cieLab(linearRed: expected.x, linearGreen: expected.y, linearBlue: expected.z)
        neutralDistances.append(((drawnLab.y - expectedLab.y) * (drawnLab.y - expectedLab.y) + (drawnLab.z - expectedLab.z) * (drawnLab.z - expectedLab.z)).squareRoot())
    }
    metrics.neutralGarmentPixelCount = neutralDistances.count
    metrics.whiteBalanceDeltaE = neutralDistances.count >= 500 ? median(neutralDistances) : nil

    // Which pixels of the original are the old shirt, by the renderer's own color rule.
    let oldShirtLab = ShirtColorMath.lab(red: ShirtColorMath.byte(inputs.oldShirtColor.x), green: ShirtColorMath.byte(inputs.oldShirtColor.y), blue: ShirtColorMath.byte(inputs.oldShirtColor.z))
    let originalIsOldShirt = (0..<pixelCount).map { pixel -> Bool in
        guard isPerson[pixel] else { return false }
        let pixelLab = ShirtColorMath.quickLab(red: inputs.original.channel(0, at: pixel), green: inputs.original.channel(1, at: pixel), blue: inputs.original.channel(2, at: pixel))
        return ShirtColorMath.distance(from: pixelLab, to: oldShirtLab) < ShirtColorMath.oldShirtDistanceLimit
    }

    // Shading: where the garment covers the old shirt, the low-pass log of what the garment was lit with against the low-pass
    // log of the old shirt's own luminance.
    let shadingPixels = (0..<pixelCount).map { isGarmentCore[$0] && originalIsOldShirt[$0] }
    var drawnShadingLog = [Double](repeating: 0, count: pixelCount), originalLog = [Double](repeating: 0, count: pixelCount)
    for pixel in 0..<pixelCount where shadingPixels[pixel] {
        let warped = inputs.warpedGarment.luminance(at: pixel)
        drawnShadingLog[pixel] = log(max(inputs.composite.luminance(at: pixel), 1e-4) / max(warped, 1e-4))
        originalLog[pixel] = log(max(inputs.original.luminance(at: pixel), 1e-4))
    }
    let lowPassDrawn = includedBoxMean(drawnShadingLog, included: shadingPixels, width: width, height: height, radius: 8)
    let lowPassOriginal = includedBoxMean(originalLog, included: shadingPixels, width: width, height: height, radius: 8)
    var pairs: [(Double, Double)] = []
    for pixel in stride(from: 0, to: pixelCount, by: 3) where shadingPixels[pixel] && !lowPassDrawn[pixel].isNaN && !lowPassOriginal[pixel].isNaN {
        pairs.append((lowPassDrawn[pixel], lowPassOriginal[pixel]))
    }
    let meanDrawn = pairs.map(\.0).reduce(0, +) / Double(max(pairs.count, 1)), meanOriginal = pairs.map(\.1).reduce(0, +) / Double(max(pairs.count, 1))
    var covariance = 0.0, drawnVariance = 0.0, originalVariance = 0.0
    for (drawn, original) in pairs {
        covariance += (drawn - meanDrawn) * (original - meanOriginal)
        drawnVariance += (drawn - meanDrawn) * (drawn - meanDrawn)
        originalVariance += (original - meanOriginal) * (original - meanOriginal)
    }
    metrics.shadingCorrelation = covariance / max((drawnVariance * originalVariance).squareRoot(), 1e-12)

    // Halo outside: the change just outside the person matte.
    let personGrown = squareMorphology(isPerson, width: width, height: height, radius: 6, grow: true)
    var outsideChangeSum = 0.0, outsideCount = 0
    for pixel in 0..<pixelCount where personGrown[pixel] && !isPerson[pixel] {
        var change = 0.0
        for channel in 0..<3 { change += abs(Double(inputs.composite.channel(channel, at: pixel)) - Double(inputs.original.channel(channel, at: pixel))) }
        outsideChangeSum += change / 3
        outsideCount += 1
    }
    metrics.haloOutsideMeanChange = outsideChangeSum / Double(max(outsideCount, 1))

    // Halo inside: the rim against the band just behind it, in sectors around the garment's center.
    let shrunkBy4 = squareMorphology(isGarment, width: width, height: height, radius: 4, grow: false)
    let shrunkBy6 = squareMorphology(isGarment, width: width, height: height, radius: 6, grow: false)
    let shrunkBy16 = squareMorphology(isGarment, width: width, height: height, radius: 16, grow: false)
    var centerSum = SIMD2<Double>(0, 0)
    for pixel in 0..<pixelCount where isGarment[pixel] { centerSum += SIMD2(Double(pixel % width), Double(pixel / width)) }
    let center = centerSum / Double(max(garmentCount, 1))
    let sectorCount = 16
    var rimSums = [Double](repeating: 0, count: sectorCount), rimClothSums = [Double](repeating: 0, count: sectorCount), rimCounts = [Int](repeating: 0, count: sectorCount)
    var interiorSums = [Double](repeating: 0, count: sectorCount), interiorClothSums = [Double](repeating: 0, count: sectorCount), interiorCounts = [Int](repeating: 0, count: sectorCount)
    for pixel in 0..<pixelCount where isGarment[pixel] {
        let isRim = !shrunkBy4[pixel], isInterior = shrunkBy6[pixel] && !shrunkBy16[pixel]
        guard isRim || isInterior else { continue }
        let angle = atan2(Double(pixel / width) - center.y, Double(pixel % width) - center.x)
        let sector = min(sectorCount - 1, Int((angle + .pi) / (2 * .pi) * Double(sectorCount)))
        let drawn = inputs.composite.luminance(at: pixel), cloth = inputs.warpedGarment.luminance(at: pixel)
        if isRim { rimSums[sector] += drawn; rimClothSums[sector] += cloth; rimCounts[sector] += 1 }
        if isInterior { interiorSums[sector] += drawn; interiorClothSums[sector] += cloth; interiorCounts[sector] += 1 }
    }
    var worstRimRatio = 0.0
    for sector in 0..<sectorCount where rimCounts[sector] >= 200 && interiorCounts[sector] >= 200 {
        let rimLight = rimSums[sector] / max(rimClothSums[sector], 1e-6)
        let interiorLight = interiorSums[sector] / max(interiorClothSums[sector], 1e-6)
        let ratio = rimLight / max(interiorLight, 1e-6)
        if ratio > worstRimRatio {
            worstRimRatio = ratio
            metrics.haloInsideWorstSectorDegrees = (Double(sector) + 0.5) / Double(sectorCount) * 360 - 180
        }
    }
    metrics.haloInsideWorstRimRatio = worstRimRatio

    // The old shirt left showing inside the torso.
    var torsoOldShirtCount = 0, stillShowingCount = 0
    for pixel in 0..<pixelCount where originalIsOldShirt[pixel] {
        guard isInside(CGPoint(x: Double(pixel % width) + 0.5, y: Double(pixel / width) + 0.5), polygon: inputs.landedTorsoCorners) else { continue }
        torsoOldShirtCount += 1
        var change = 0.0
        for channel in 0..<3 { change += abs(Double(inputs.composite.channel(channel, at: pixel)) - Double(inputs.original.channel(channel, at: pixel))) }
        if change / 3 < 6 && inputs.totalAlpha.channel(0, at: pixel) < 128 { stillShowingCount += 1 }
    }
    metrics.oldShirtStillShowingShare = Double(stillShowingCount) / Double(max(torsoOldShirtCount, 1))

    // Each sleeve's drawn axis, from the middle of its seam to the middle of its opening, against its upper arm.
    for sleeve in inputs.sleeves {
        let drawnAxis = simd_normalize(SIMD2(Double(sleeve.axis.dx), Double(sleeve.axis.dy)))
        let armAxis = simd_normalize(SIMD2(sleeve.elbow.x - sleeve.shoulder.x, sleeve.elbow.y - sleeve.shoulder.y))
        metrics.sleeveAxisErrorsDegrees.append(acos(max(-1, min(1, simd_dot(drawnAxis, armAxis)))) * 180 / .pi)
    }
    return metrics
}

// MARK: - The check

private func loadImage(at url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

private func savePNG(_ image: CGImage, to url: URL) throws {
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
}

struct ShirtLookCheckTests {
    @Test(.enabled(if: lookCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil && lookCheckEnvironment["SHIRT_TRYON_OUTPUT_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR and SHIRT_TRYON_OUTPUT_DIR"))
    func eachFlatLayLooksWornInTheRoom() throws {
        let photosFolder = URL(fileURLWithPath: try #require(lookCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let outputFolder = URL(fileURLWithPath: try #require(lookCheckEnvironment["SHIRT_TRYON_OUTPUT_DIR"]))
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let context = CIContext()
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))

        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        let frame = CIImage(cgImage: standingPhoto)
        let frameExtent = frame.extent
        var frameBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, standingPhoto.width, standingPhoto.height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &frameBuffer)
        let cameraFrame = try #require(frameBuffer)
        context.render(frame, to: cameraFrame, bounds: frameExtent, colorSpace: sRGB)
        let torso = try #require(ShirtPoseTracker.detectTorso(in: cameraFrame))
        let segmentation = VNGeneratePersonSegmentationRequest()
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try VNImageRequestHandler(cvPixelBuffer: cameraFrame, orientation: .up).perform([segmentation])
        let personMask = CIImage(cvPixelBuffer: try #require(segmentation.results?.first?.pixelBuffer), options: [.colorSpace: NSNull()])
        let personMaskExtent = personMask.extent
        let personMaskAtFrameSize = personMask
            .transformed(by: CGAffineTransform(scaleX: frameExtent.width / personMaskExtent.width, y: frameExtent.height / personMaskExtent.height))
            .cropped(to: frameExtent)

        let original = LookPixels(frame, extent: frameExtent, context: context, colorSpace: sRGB)
        let person = LookPixels(personMaskAtFrameSize, extent: frameExtent, context: context, colorSpace: nil)
        let fullSizeFrame = ShirtSmallFrame(width: original.width, height: original.height, rgba: original.bytes, personMask: (0..<(original.width * original.height)).map { person.channel(0, at: $0) }, torso: torso)
        let oldShirtColor = try #require(fullSizeFrame.measureOldShirtColor())

        let flatLayNames = try FileManager.default.contentsOfDirectory(atPath: photosFolder.path).filter { $0.hasPrefix("uE") && $0.hasSuffix(".jpg") }.sorted()
        #expect(!flatLayNames.isEmpty)
        var everyShirtsMetrics: [ShirtLookMetrics] = []
        for flatLayName in flatLayNames {
            let shirtName = flatLayName.replacingOccurrences(of: ".jpg", with: "")
            let productPhoto = try loadImage(at: photosFolder.appendingPathComponent(flatLayName))
            let garment = try #require(ShirtGarment.make(productPhoto: productPhoto, itemCorners: RoomArtCorners(
                topLeft: .zero, topRight: CGPoint(x: productPhoto.width, y: 0),
                bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height)
            )), "no garment found in \(flatLayName)")
            // A few frames first, as the panel draws them, so the renderer's smoothed numbers settle.
            let renderer = ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false)
            for _ in 0..<8 { _ = renderer.composition(frame: frame, personMask: personMask, torso: torso, garment: garment) }
            let composition = try #require(renderer.composition(frame: frame, personMask: personMask, torso: torso, garment: garment))

            let composite = LookPixels(composition.image, extent: frameExtent, context: context, colorSpace: sRGB)
            let sleeves = sleeveLayers(of: composition, torso: torso)
            let inputs = LookInputs(
                original: original, composite: composite, person: person,
                garmentAlpha: LookPixels(composition.garmentAlpha, extent: frameExtent, context: context, colorSpace: nil),
                totalAlpha: LookPixels(composition.totalAlpha, extent: frameExtent, context: context, colorSpace: nil),
                warpedGarment: LookPixels(composition.warpedGarmentColor, extent: frameExtent, context: context, colorSpace: sRGB),
                sleeves: sleeves, landedTorsoCorners: composition.landedTorsoCorners, oldShirtColor: oldShirtColor,
                photoWhite: productPhotoWhite(productPhoto: productPhoto, garment: garment, context: context)
            )
            let metrics = measure(inputs, shirtName: shirtName)
            everyShirtsMetrics.append(metrics)

            let rendered = try #require(context.createCGImage(composition.image, from: frameExtent, format: .RGBA8, colorSpace: sRGB))
            try savePNG(rendered, to: outputFolder.appendingPathComponent("look-\(shirtName).png"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(metrics).write(to: outputFolder.appendingPathComponent("look-\(shirtName).json"))
            print("Shirt look check: \(shirtName) \(String(data: try JSONEncoder().encode(metrics), encoding: .utf8) ?? "")")

            #expect(metrics.clippedShareOfTheGarment <= metrics.clippedShareOfTheOriginal + ShirtLookLimits.clippingAllowanceOverTheOriginal, "\(shirtName): clipping")
            #expect(ShirtLookLimits.exposureRatioRange.contains(metrics.exposureRatio), "\(shirtName): exposure ratio \(metrics.exposureRatio)")
            if let whiteBalanceDeltaE = metrics.whiteBalanceDeltaE {
                #expect(whiteBalanceDeltaE <= ShirtLookLimits.whiteBalanceDeltaE, "\(shirtName): white balance")
            }
            #expect(metrics.shadingCorrelation >= ShirtLookLimits.shadingCorrelation, "\(shirtName): shading")
            #expect(metrics.haloOutsideMeanChange < ShirtLookLimits.haloOutsideMeanChange, "\(shirtName): halo outside")
            #expect(metrics.haloInsideWorstRimRatio <= ShirtLookLimits.haloInsideRimRatio, "\(shirtName): halo inside")
            #expect(metrics.oldShirtStillShowingShare < ShirtLookLimits.oldShirtStillShowingShare, "\(shirtName): old shirt")
            #expect(metrics.sleeveAxisErrorsDegrees.count == 2, "\(shirtName): both sleeves drawn along the arms")
            for sleeveAxisError in metrics.sleeveAxisErrorsDegrees {
                #expect(sleeveAxisError <= ShirtLookLimits.sleeveAxisErrorDegrees, "\(shirtName): sleeve axis")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(everyShirtsMetrics).write(to: outputFolder.appendingPathComponent("look-metrics.json"))
    }
}

/// Each sleeve drawn on its own, with the shoulder and elbow it should follow.
private func sleeveLayers(of composition: ShirtTryOnComposition, torso: BodyTorso) -> [(axis: CGVector, shoulder: CGPoint, elbow: CGPoint)] {
    composition.sleeves.compactMap { sleeve in
        let isImageLeft = sleeve.side == .imageLeft
        guard let elbow = isImageLeft ? torso.imageLeftElbow : torso.imageRightElbow else { return nil }
        return (sleeve.axis, isImageLeft ? torso.imageLeftShoulder : torso.imageRightShoulder, elbow)
    }
}
