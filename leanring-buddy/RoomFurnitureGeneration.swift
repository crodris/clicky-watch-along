//
//  RoomFurnitureGeneration.swift
//  leanring-buddy
//
//  The app's side of the two generation services behind the furniture try-on, which work for any furniture page with a
//  photo and a size, not only the few that publish a 3D model:
//  Both services get the furniture's cutout over white and the cut title, never the raw page picture.
//  - `POST /room-furniture-composite`: OpenAI's image edit draws the product into a camera keyframe of the learner's room,
//    inside a mask of the item's real size, lit by the room. The client pastes the reply back only inside that mask.
//  - `POST /try-it-model`: fal.ai turns the cutout into a GLB. The client keeps each GLB on disk by a hash of the page's
//    picture and the title, not of the cutout, since the cutout is cropped from a fresh read of the page each request and a
//    one pixel shift would pay for the same product again.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a generation call failed, so the panel can say "this is not set up" apart from "this failed".
nonisolated enum RoomFurnitureGenerationError: Error, Equatable {
    /// The Worker answered 503: the service has no key (`FAL_KEY` for the model, `OPENAI_API_KEY` for the composite), so asking again will not help.
    case serviceIsNotSetUp(body: String)
    /// Any other status that is not 200. 401 is a missing or wrong app secret, 504 a model that took too long, 502 a
    /// failed or refused generation, and 400 a request the Worker refused.
    case workerReturned(statusCode: Int, body: String)
    /// The Worker answered 200 with something that is not what the route promises.
    case replyCouldNotBeRead(reason: String)
    /// The keyframe or the mask the caller passed could not be decoded, so the reply cannot be pasted into the keyframe.
    case inputCouldNotBeRead(reason: String)
}

// MARK: - The mask

/// The convex hull of `points` in order around it, with collinear points dropped (Andrew's monotone chain).
nonisolated func convexHull(of points: [CGPoint]) -> [CGPoint] {
    let sortedPoints = points.sorted { first, second in first.x != second.x ? first.x < second.x : first.y < second.y }
    guard sortedPoints.count >= 3 else { return sortedPoints }
    func turn(_ origin: CGPoint, _ first: CGPoint, _ second: CGPoint) -> CGFloat {
        (first.x - origin.x) * (second.y - origin.y) - (first.y - origin.y) * (second.x - origin.x)
    }
    var lowerHull: [CGPoint] = []
    for point in sortedPoints {
        while lowerHull.count >= 2, turn(lowerHull[lowerHull.count - 2], lowerHull[lowerHull.count - 1], point) <= 0 {
            lowerHull.removeLast()
        }
        lowerHull.append(point)
    }
    var upperHull: [CGPoint] = []
    for point in sortedPoints.reversed() {
        while upperHull.count >= 2, turn(upperHull[upperHull.count - 2], upperHull[upperHull.count - 1], point) <= 0 {
            upperHull.removeLast()
        }
        upperHull.append(point)
    }
    return Array(lowerHull.dropLast()) + Array(upperHull.dropLast())
}

/// The mask `/room-furniture-composite` takes: an 8-bit gray PNG the size of the keyframe, white inside the convex hull
/// of the item's projected box corners grown by `shadowMarginPixels` (room for its contact shadow), black elsewhere.
/// `projectedCorners` are keyframe pixels with y growing down. Nil when the corners do not span an area, when any number
/// is not finite, or when the frame or the margin is not a usable size.
nonisolated func furnitureCompositeMaskPNG(
    projectedCorners: [CGPoint],
    frameWidth: Int,
    frameHeight: Int,
    shadowMarginPixels: Double
) -> Data? {
    // A zero or negative frame size needs no check of its own: the bitmap context below refuses it.
    guard shadowMarginPixels.isFinite, shadowMarginPixels >= 0,
          projectedCorners.allSatisfy({ corner in corner.x.isFinite && corner.y.isFinite }) else { return nil }
    let hull = convexHull(of: projectedCorners)
    guard hull.count >= 3 else { return nil }

    guard let context = CGContext(
        data: nil,
        width: frameWidth,
        height: frameHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    // The corners have y growing down, and a bitmap context's y grows up.
    context.translateBy(x: 0, y: CGFloat(frameHeight))
    context.scaleBy(x: 1, y: -1)

    let hullPath = CGMutablePath()
    hullPath.addLines(between: hull)
    hullPath.closeSubpath()
    context.setFillColor(gray: 1, alpha: 1)
    context.addPath(hullPath)
    context.fillPath()
    // A round-joined stroke of twice the margin around the filled hull is the hull grown by the margin in every direction.
    if shadowMarginPixels > 0 {
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(CGFloat(shadowMarginPixels * 2))
        context.setLineJoin(.round)
        context.addPath(hullPath)
        context.strokePath()
    }

    guard let maskImage = context.makeImage() else { return nil }
    let pngData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, maskImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return pngData as Data
}

// MARK: - Pasting the reply into the keyframe

/// OpenAI's image edit follows a mask only as guidance: on the live check (2026-11-22) a chair's arm and a table's legs
/// came out up to about 20 pixels past it. The paste takes the reply this far past the mask, so the piece is not cut off.
nonisolated let furnitureCompositePasteSlackPixels: Double = 24
/// The paste's edge fades over about this many pixels, so no seam shows where the reply meets the filmed frame.
nonisolated let furnitureCompositePasteFeatherPixels: Double = 4
/// How wide the ring of room just outside the paste is, where the reply's tone is compared with the keyframe's.
nonisolated let furnitureCompositeToneMatchBandPixels: Double = 96

// The edit also repaints the room around the piece a little: on the live check (2026-11-22) the wall beside a chair, a
// sofa, and a table came back a few levels lighter, with a new grain, inside the pasted region only. One gain and offset
// cannot follow light that varies across the region, so the pasted region showed as a faint lighter patch next to the
// piece. The paste therefore keeps the reply only where it changed the keyframe strongly, which the piece does and the
// repainted room does not (`furniturePieceWeights`), and everywhere else it keeps the keyframe's own pixels.

/// The piece's shape is worked out on cells of this many pixels on a side, since it is smooth (closed over 20 pixels and
/// softened), and a full-size frame's worth of passes took tens of seconds in a Debug build, which the app runs in while it is
/// developed. The weights are scaled back up with a bilinear read.
nonisolated let furniturePieceCellPixels = 4
/// A cell counts as changed when the reply, after the tone fit, differs from the keyframe by more than this many levels in
/// some channel, averaged over the pixels of the cell that the paste takes. The repainted room measured up to about 8 levels, and the piece's cloth, legs, and
/// shadow measured 20 or more.
nonisolated let furniturePieceChangeThresholdLevels: Float = 14
/// The changed cells are closed before they weigh the paste: grown by `furniturePieceClosingGrowCells`, then shrunk by
/// `furniturePieceClosingShrinkCells`. The difference is the margin kept around the piece (so its anti-aliased edge and its
/// soft shadow are not cut, and the softening below leaves the piece's own edge whole), and a notch in the piece narrower
/// than twice the grow, such as a cushion seam, closes. Any gap the changed cells enclose, such as a seat that matches the
/// wall, is filled as well, so the keyframe's wall shows inside the piece's outline only where a pale part reaches the
/// outline or a part is thinner than a cell can average over the threshold.
nonisolated let furniturePieceClosingGrowCells = 5
nonisolated let furniturePieceClosingShrinkCells = 2
/// The closed shape's edge is softened with this many cells of average on each side, `furniturePieceEdgeSofteningPasses`
/// times over, which reaches about 3 cells.
nonisolated let furniturePieceEdgeSoftnessCells = 1
nonisolated let furniturePieceEdgeSofteningPasses = 3

/// A gain and an offset for one color channel, in sRGB byte values: `corrected = gain * reply + offset`.
nonisolated struct ChannelToneFit: Equatable {
    var gain: Double
    var offset: Double

    static let unchanged = ChannelToneFit(gain: 1, offset: 0)
}

/// A fit outside these bounds means the ring held something other than the same room, such as part of the piece or a
/// flat color, so the reply is pasted as it came. The live check's replies needed gains of about 0.85 to 1 and offsets
/// within about 10.
nonisolated let toneFitGainRange: ClosedRange<Double> = 0.7...1.4
nonisolated let toneFitLargestOffset: Double = 40
/// Fewer ring pixels than this give a fit that one stray patch can swing.
nonisolated let toneFitFewestSamples = 500

/// The least squares gain and offset per channel (red, green, blue) that turn the reply's pixels into the keyframe's at
/// the sampled pixels. The edit re-exposes the whole frame (on the live check, a wall came back 12 to 17 levels brighter),
/// so the pasted region would show as a lighter patch without this. Pixel arrays are RGBA bytes of the same size.
nonisolated func toneFitsMatchingTheReplyToTheKeyframe(
    keyframePixels: [UInt8],
    replyPixels: [UInt8],
    sampleIsInTheRing: [Bool]
) -> [ChannelToneFit] {
    let sampleCount = sampleIsInTheRing.reduce(0) { count, isSampled in count + (isSampled ? 1 : 0) }
    guard sampleCount >= toneFitFewestSamples else { return Array(repeating: .unchanged, count: 3) }
    return (0..<3).map { channel in
        var replySum = 0.0, keyframeSum = 0.0, replySquareSum = 0.0, productSum = 0.0
        for (pixelIndex, isSampled) in sampleIsInTheRing.enumerated() where isSampled {
            let replyValue = Double(replyPixels[pixelIndex * 4 + channel])
            let keyframeValue = Double(keyframePixels[pixelIndex * 4 + channel])
            replySum += replyValue
            keyframeSum += keyframeValue
            replySquareSum += replyValue * replyValue
            productSum += replyValue * keyframeValue
        }
        let count = Double(sampleCount)
        let replyMean = replySum / count
        let keyframeMean = keyframeSum / count
        let replyVariance = replySquareSum / count - replyMean * replyMean
        // A flat ring has no spread to fit a gain to: its gain comes out as NaN or huge, which the range below refuses.
        let gain = (productSum / count - replyMean * keyframeMean) / replyVariance
        let fit = ChannelToneFit(gain: gain, offset: keyframeMean - gain * replyMean)
        guard toneFitGainRange.contains(fit.gain), abs(fit.offset) <= toneFitLargestOffset else { return .unchanged }
        return fit
    }
}

/// An image's RGBA bytes in sRGB at `width` by `height`, scaled when its own size differs, with the first row the top.
nonisolated func rgbaBytes(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let drew = pixelBytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drew ? pixelBytes : nil
}

/// An image's gray bytes at `width` by `height`, with the first row the top.
nonisolated func grayBytes(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var pixelBytes = [UInt8](repeating: 0, count: width * height)
    let drew = pixelBytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drew ? pixelBytes : nil
}

/// The mask grown by `radiusPixels` and blurred by `blurPixels`, at the frame's size.
nonisolated func grownMaskImage(_ mask: CGImage, frameExtent: CGRect, radiusPixels: Double, blurPixels: Double, context: CIContext) -> CGImage? {
    let maskImage = CIImage(cgImage: mask).transformed(by: CGAffineTransform(
        scaleX: frameExtent.width / CGFloat(mask.width),
        y: frameExtent.height / CGFloat(mask.height)
    ))
    let grownMask = CIFilter.morphologyMaximum()
    grownMask.inputImage = maskImage.clampedToExtent()
    grownMask.radius = Float(radiusPixels)
    var outputImage = grownMask.outputImage
    if blurPixels > 0 {
        let blurredMask = CIFilter.gaussianBlur()
        blurredMask.inputImage = outputImage
        // Core Image's radius is about two standard deviations, so the edge fades over about `blurPixels` on each side.
        blurredMask.radius = Float(blurPixels / 2)
        outputImage = blurredMask.outputImage
    }
    guard let outputImage else { return nil }
    return context.createCGImage(outputImage.cropped(to: frameExtent), from: frameExtent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
}

/// One pass of a moving average along every row (or, with the strides swapped, every column) of an image. A pixel's window
/// is the `radius` pixels either side of it, cut at the image's edge, and a window part outside the image is not counted.
/// Running sums make the cost independent of the radius, and the raw buffers keep a Debug build, which the app runs in
/// while it is developed, from spending seconds on a frame's worth of bounds checks.
private nonisolated func movingAverage(
    _ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>,
    lineCount: Int, lineLength: Int, lineStride: Int, stepStride: Int, radius: Int
) {
    let runningSums = UnsafeMutablePointer<Float>.allocate(capacity: lineLength + 1)
    defer { runningSums.deallocate() }
    for line in 0..<lineCount {
        let lineStart = line * lineStride
        runningSums[0] = 0
        for step in 0..<lineLength { runningSums[step + 1] = runningSums[step] + input[lineStart + step * stepStride] }
        for step in 0..<lineLength {
            let windowStart = max(0, step - radius)
            let windowEnd = min(lineLength, step + radius + 1)
            output[lineStart + step * stepStride] = (runningSums[windowEnd] - runningSums[windowStart]) / Float(windowEnd - windowStart)
        }
    }
}

/// `values` averaged over the square window of `radius` pixels around each pixel, over `width` by `height` pixels.
nonisolated func boxAveraged(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
    var acrossRows = [Float](repeating: 0, count: values.count)
    var output = [Float](repeating: 0, count: values.count)
    // `baseAddress` is nil only for an empty array, and a frame has at least one pixel, so the unwraps below hold.
    values.withUnsafeBufferPointer { valuesPointer in
        acrossRows.withUnsafeMutableBufferPointer { acrossRowsPointer in
            movingAverage(valuesPointer.baseAddress!, into: acrossRowsPointer.baseAddress!, lineCount: height, lineLength: width, lineStride: width, stepStride: 1, radius: radius)
            output.withUnsafeMutableBufferPointer { outputPointer in
                movingAverage(UnsafePointer(acrossRowsPointer.baseAddress!), into: outputPointer.baseAddress!, lineCount: width, lineLength: height, lineStride: 1, stepStride: width, radius: radius)
            }
        }
    }
    return output
}

/// A binary image (0 or 1 per pixel) with each pixel set when any pixel (`keepsAnyHit`) or every pixel (otherwise) of the
/// square window of `radius` around it is set. Window parts outside the image are ignored.
nonisolated func binaryWindowFiltered(_ pixels: [Float], width: Int, height: Int, radius: Int, keepsAnyHit: Bool) -> [Float] {
    guard radius > 0 else { return pixels }
    // A square window is a row window and then a column window, with the result of the first made binary again.
    func filteredAlong(_ input: [Float], lineCount: Int, lineLength: Int, lineStride: Int, stepStride: Int) -> [Float] {
        var averaged = [Float](repeating: 0, count: input.count)
        // `baseAddress` is nil only for an empty array, and an image has at least one pixel.
        input.withUnsafeBufferPointer { inputPointer in
            averaged.withUnsafeMutableBufferPointer { averagedPointer in
                movingAverage(inputPointer.baseAddress!, into: averagedPointer.baseAddress!, lineCount: lineCount, lineLength: lineLength, lineStride: lineStride, stepStride: stepStride, radius: radius)
            }
        }
        // An average of 0/1 values is above 0 when any is set, and exactly 1 only when all are (sums of whole numbers are exact).
        return averaged.map { average in keepsAnyHit ? (average > 0 ? 1 : 0) : (average >= 1 ? 1 : 0) }
    }
    let acrossRows = filteredAlong(pixels, lineCount: height, lineLength: width, lineStride: width, stepStride: 1)
    return filteredAlong(acrossRows, lineCount: width, lineLength: height, lineStride: 1, stepStride: width)
}

/// `cells` (0 or 1 per cell) with every 0 that the 1s enclose set to 1. A 0 is enclosed when no path of 0 cells leads from it
/// to the image's border, going up, down, left, or right.
nonisolated func cellsWithEnclosedGapsFilled(_ cells: [Float], columns: Int, rows: Int) -> [Float] {
    var reachedFromTheBorder = [Bool](repeating: false, count: cells.count)
    var cellsToVisit: [Int] = []
    func visitIfEmpty(column: Int, row: Int) {
        let cellIndex = row * columns + column
        guard cells[cellIndex] == 0, !reachedFromTheBorder[cellIndex] else { return }
        reachedFromTheBorder[cellIndex] = true
        cellsToVisit.append(cellIndex)
    }
    for column in 0..<columns {
        visitIfEmpty(column: column, row: 0)
        visitIfEmpty(column: column, row: rows - 1)
    }
    for row in 0..<rows {
        visitIfEmpty(column: 0, row: row)
        visitIfEmpty(column: columns - 1, row: row)
    }
    while let cellIndex = cellsToVisit.popLast() {
        let column = cellIndex % columns
        let row = cellIndex / columns
        if column > 0 { visitIfEmpty(column: column - 1, row: row) }
        if column < columns - 1 { visitIfEmpty(column: column + 1, row: row) }
        if row > 0 { visitIfEmpty(column: column, row: row - 1) }
        if row < rows - 1 { visitIfEmpty(column: column, row: row + 1) }
    }
    return cells.enumerated().map { cellIndex, cell in reachedFromTheBorder[cellIndex] ? 0 : 1 }
}

/// How much of the reply each pixel keeps, 0 to 1: 1 on and around the piece, 0 on the room the edit only repainted.
/// A cell is part of the piece when the reply, after the tone fit, differs strongly from the keyframe in it
/// (`furniturePieceChangeThresholdLevels`). That shape is closed, filled where it encloses a gap, and softened as the
/// constants above describe, then read back at each pixel. Both pixel arrays are RGBA bytes of `width` by `height`.
/// Only pixels the paste takes at all (`pasteWeights`, one byte per pixel, 0 where the paste keeps the keyframe) count as
/// changed. The edit re-renders the whole frame, so a window or a person elsewhere in it can differ by more than the
/// threshold, and such a cell must not join the piece and enclose room that is inside the paste.
nonisolated func furniturePieceWeights(keyframePixels: [UInt8], correctedReplyPixels: [UInt8], pasteWeights: [UInt8], width: Int, height: Int) -> [Float] {
    let cellPixels = furniturePieceCellPixels
    let cellColumns = (width + cellPixels - 1) / cellPixels
    let cellRows = (height + cellPixels - 1) / cellPixels
    var changeSums = [Float](repeating: 0, count: cellColumns * cellRows)
    var pastedPixelCounts = [Int](repeating: 0, count: cellColumns * cellRows)
    keyframePixels.withUnsafeBufferPointer { keyframeBytes in
        correctedReplyPixels.withUnsafeBufferPointer { replyBytes in
            changeSums.withUnsafeMutableBufferPointer { sums in
                pastedPixelCounts.withUnsafeMutableBufferPointer { counts in
                    for row in 0..<height {
                        let cellRowStart = (row / cellPixels) * cellColumns
                        for column in 0..<width {
                            guard pasteWeights[row * width + column] > 0 else { continue }
                            let cellIndex = cellRowStart + column / cellPixels
                            counts[cellIndex] += 1
                            let byteIndex = (row * width + column) * 4
                            let redChange = abs(Int(replyBytes[byteIndex]) - Int(keyframeBytes[byteIndex]))
                            let greenChange = abs(Int(replyBytes[byteIndex + 1]) - Int(keyframeBytes[byteIndex + 1]))
                            let blueChange = abs(Int(replyBytes[byteIndex + 2]) - Int(keyframeBytes[byteIndex + 2]))
                            sums[cellIndex] += Float(max(redChange, greenChange, blueChange))
                        }
                    }
                }
            }
        }
    }
    // Each cell is averaged over the pixels of it that the paste takes. A cell the paste does not reach is never changed,
    // and neither is a cell it only grazes (under half of the cell), since a few pixels of the feather's faint tail would
    // then decide it.
    var changedCells = [Float](repeating: 0, count: cellColumns * cellRows)
    for cellRow in 0..<cellRows {
        let pixelRows = min(cellPixels, height - cellRow * cellPixels)
        for cellColumn in 0..<cellColumns {
            let cellIndex = cellRow * cellColumns + cellColumn
            let pixelsInTheCell = pixelRows * min(cellPixels, width - cellColumn * cellPixels)
            guard pastedPixelCounts[cellIndex] * 2 >= pixelsInTheCell else { continue }
            let averageChange = changeSums[cellIndex] / Float(pastedPixelCounts[cellIndex])
            changedCells[cellIndex] = averageChange > furniturePieceChangeThresholdLevels ? 1 : 0
        }
    }
    let grownCells = binaryWindowFiltered(changedCells, width: cellColumns, height: cellRows, radius: furniturePieceClosingGrowCells, keepsAnyHit: true)
    let closedCells = binaryWindowFiltered(grownCells, width: cellColumns, height: cellRows, radius: furniturePieceClosingShrinkCells, keepsAnyHit: false)
    let solidCells = cellsWithEnclosedGapsFilled(closedCells, columns: cellColumns, rows: cellRows)
    var softenedCells = solidCells
    for _ in 0..<furniturePieceEdgeSofteningPasses { softenedCells = boxAveraged(softenedCells, width: cellColumns, height: cellRows, radius: furniturePieceEdgeSoftnessCells) }

    // Each pixel reads the cells around it, with the cell centers at the middle of their cells.
    var pieceWeights = [Float](repeating: 0, count: width * height)
    softenedCells.withUnsafeBufferPointer { cells in
        pieceWeights.withUnsafeMutableBufferPointer { weights in
            let halfCell = Float(cellPixels) / 2
            for row in 0..<height {
                let cellRowPosition = min(Float(cellRows - 1), max(0, (Float(row) + 0.5 - halfCell) / Float(cellPixels)))
                let upperCellRow = Int(cellRowPosition)
                let lowerCellRow = min(cellRows - 1, upperCellRow + 1)
                let rowShare = cellRowPosition - Float(upperCellRow)
                for column in 0..<width {
                    let cellColumnPosition = min(Float(cellColumns - 1), max(0, (Float(column) + 0.5 - halfCell) / Float(cellPixels)))
                    let leftCellColumn = Int(cellColumnPosition)
                    let rightCellColumn = min(cellColumns - 1, leftCellColumn + 1)
                    let columnShare = cellColumnPosition - Float(leftCellColumn)
                    let upperValue = cells[upperCellRow * cellColumns + leftCellColumn] * (1 - columnShare) + cells[upperCellRow * cellColumns + rightCellColumn] * columnShare
                    let lowerValue = cells[lowerCellRow * cellColumns + leftCellColumn] * (1 - columnShare) + cells[lowerCellRow * cellColumns + rightCellColumn] * columnShare
                    weights[row * width + column] = upperValue * (1 - rowShare) + lowerValue * rowShare
                }
            }
        }
    }
    return pieceWeights
}

/// The keyframe with `generated` pasted in only where the mask, grown by `slackPixels` and feathered by
/// `featherPixels`, allows. The edit re-renders the whole frame, and pixels away from the piece come back slightly changed
/// (a window's view, the light on a wall), so everything past the grown mask stays exactly as filmed. Before the paste,
/// the reply's tone is matched to the keyframe on a ring `toneMatchBandPixels` wide just outside the paste
/// (`toneFitsMatchingTheReplyToTheKeyframe`), so the pasted region does not show as a lighter or darker patch. Inside the
/// region, only the piece keeps the reply: the room the edit repainted a few levels lighter, which one global fit cannot
/// follow, keeps the keyframe's own pixels (`furniturePieceWeights`). `keepsOnlyThePieceTheReplyChanged` false pastes
/// the whole grown region instead, for a painting that must replace everything in its mask, as the shirt's must cover
/// the learner's own top even where the new one is close to its color. A `generated` of another size, which the Worker
/// returns for a keyframe size OpenAI does not take, is scaled to the keyframe first.
nonisolated func furnitureCompositePasted(
    keyframe: CGImage,
    generated: CGImage,
    mask: CGImage,
    slackPixels: Double = furnitureCompositePasteSlackPixels,
    featherPixels: Double = furnitureCompositePasteFeatherPixels,
    toneMatchBandPixels: Double = furnitureCompositeToneMatchBandPixels,
    keepsOnlyThePieceTheReplyChanged: Bool = true,
    context: CIContext
) -> CGImage? {
    let width = keyframe.width
    let height = keyframe.height
    let frameExtent = CGRect(x: 0, y: 0, width: width, height: height)
    guard let keyframePixels = rgbaBytes(of: keyframe, width: width, height: height),
          let replyPixels = rgbaBytes(of: generated, width: width, height: height),
          let pasteMask = grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: slackPixels, blurPixels: featherPixels, context: context),
          let ringOuterMask = grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: slackPixels + featherPixels + toneMatchBandPixels, blurPixels: 0, context: context),
          let pasteWeights = grayBytes(of: pasteMask, width: width, height: height),
          let ringOuterWeights = grayBytes(of: ringOuterMask, width: width, height: height) else { return nil }

    // The ring is the room the paste does not take but the grown mask reaches: the closest room to the piece.
    let sampleIsInTheRing = zip(pasteWeights, ringOuterWeights).map { pasteWeight, ringOuterWeight in
        pasteWeight == 0 && ringOuterWeight >= 128
    }
    let toneFits = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: replyPixels, sampleIsInTheRing: sampleIsInTheRing)

    var correctedReplyPixels = replyPixels
    correctedReplyPixels.withUnsafeMutableBufferPointer { correctedBytes in
        for pixelIndex in 0..<(width * height) {
            for channel in 0..<3 {
                let byteIndex = pixelIndex * 4 + channel
                let corrected = toneFits[channel].gain * Double(correctedBytes[byteIndex]) + toneFits[channel].offset
                correctedBytes[byteIndex] = UInt8(min(255, max(0, corrected)).rounded())
            }
        }
    }
    let pieceWeights = keepsOnlyThePieceTheReplyChanged
        ? furniturePieceWeights(keyframePixels: keyframePixels, correctedReplyPixels: correctedReplyPixels, pasteWeights: pasteWeights, width: width, height: height)
        : [Float](repeating: 1, count: width * height)

    var pastedPixels = keyframePixels
    pastedPixels.withUnsafeMutableBufferPointer { pastedBytes in
        correctedReplyPixels.withUnsafeBufferPointer { correctedBytes in
            pasteWeights.withUnsafeBufferPointer { pasteWeightBytes in
                pieceWeights.withUnsafeBufferPointer { pieceWeightValues in
                    for pixelIndex in 0..<(width * height) {
                        let replyShare = Float(pasteWeightBytes[pixelIndex]) / 255 * pieceWeightValues[pixelIndex]
                        guard replyShare > 0 else { continue }
                        for channel in 0..<3 {
                            let byteIndex = pixelIndex * 4 + channel
                            let blended = Float(pastedBytes[byteIndex]) * (1 - replyShare) + Float(correctedBytes[byteIndex]) * replyShare
                            pastedBytes[byteIndex] = UInt8(blended.rounded())
                        }
                    }
                }
            }
        }
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let pixelProvider = CGDataProvider(data: Data(pastedPixels) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: pixelProvider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
}

nonisolated func decodedImage(from imageData: Data) -> CGImage? {
    guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
}

// MARK: - What the Worker takes

/// The most characters either generation route takes for an item title, counted as JavaScript counts them, in UTF-16 code
/// units. The routes answer 400 for a longer one and cut nothing.
nonisolated let roomFurnitureMostTitleUTF16Units = 300

/// `itemTitle` cut to the Worker's limit, never in the middle of a character (a character outside the Basic Multilingual
/// Plane is two UTF-16 units, so a cut between them would send half of one).
nonisolated func roomFurnitureTitleForTheWorker(_ itemTitle: String) -> String {
    var cutTitle = String.UnicodeScalarView()
    var utf16UnitCount = 0
    for unicodeScalar in itemTitle.unicodeScalars {
        utf16UnitCount += unicodeScalar.value > 0xFFFF ? 2 : 1
        if utf16UnitCount > roomFurnitureMostTitleUTF16Units { break }
        cutTitle.append(unicodeScalar)
    }
    return String(cutTitle)
}

/// The furniture's cutout as the JPEG both generation routes take: the cutout drawn over white, since a JPEG has no
/// transparency and a Worker prompt that says "the product on white" must get one. Nil when the image cannot be drawn.
nonisolated func roomFurnitureCutoutJPEG(_ cutoutImage: CGImage) -> Data? {
    guard cutoutImage.width > 0, cutoutImage.height > 0,
          let context = CGContext(
              data: nil, width: cutoutImage.width, height: cutoutImage.height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          ) else { return nil }
    let imageRectangle = CGRect(x: 0, y: 0, width: cutoutImage.width, height: cutoutImage.height)
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(imageRectangle)
    context.draw(cutoutImage, in: imageRectangle)
    guard let imageOverWhite = context.makeImage() else { return nil }
    let encodedData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(encodedData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, imageOverWhite, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return encodedData as Data
}

// MARK: - The model cache

/// Every GLB starts with the ASCII magic "glTF".
nonisolated func dataIsAGLB(_ modelData: Data) -> Bool {
    modelData.prefix(4) == Data("glTF".utf8)
}

/// The cache file's name for a model: a SHA-256 of `cacheKeyData` (the page picture's JPEG bytes) and the title, so a
/// changed picture or title pays again and the same product never does. The cutout the Worker is sent is not in the key,
/// since it is cropped to corners from a fresh `/try-it-item` call each request and differs by a pixel between requests.
/// Each part is written with its length first, so two inputs can never join to the same bytes.
nonisolated func tryItModelCacheKey(cacheKeyData: Data, itemTitle: String) -> String {
    var hasher = SHA256()
    for part in [cacheKeyData, Data(itemTitle.utf8)] {
        withUnsafeBytes(of: UInt64(part.count).bigEndian) { lengthBytes in hasher.update(bufferPointer: lengthBytes) }
        hasher.update(data: part)
    }
    return hasher.finalize().map { byte in String(format: "%02x", byte) }.joined()
}

/// `~/Library/Caches/<bundle id>/TryItModels/`. Caches, since macOS may clear it and the Worker can make the model again.
nonisolated func defaultTryItModelCacheFolder() -> URL {
    let cachesFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.crodris.clicky-watch-along"
    return cachesFolder.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent("TryItModels", isDirectory: true)
}

// MARK: - The client

/// What `/room-furniture-composite` answers: the drawn frame as JPEG, at the size OpenAI drew it.
private struct RoomFurnitureCompositeReply: Decodable {
    let imageJPEGBase64: String
    let width: Int
    let height: Int
}

@MainActor
final class RoomFurnitureGenerationClient {
    private let compositeURL: URL
    private let tryItModelURL: URL
    private let session: URLSession
    private let modelCacheFolder: URL
    private let ciContext: CIContext

    /// The Worker bounds each call at 120 seconds. A little more here lets its own 502 or 504 arrive instead of a timeout.
    static let timeoutSeconds: TimeInterval = 150

    /// Tests pass a session configuration whose protocol classes answer for the Worker, and a cache folder of their own.
    init(
        workerBaseURL: String,
        sessionConfiguration: URLSessionConfiguration = .default,
        modelCacheFolder: URL = defaultTryItModelCacheFolder(),
        ciContext: CIContext = CIContext()
    ) {
        guard let compositeURL = URL(string: "\(workerBaseURL)/room-furniture-composite"),
              let tryItModelURL = URL(string: "\(workerBaseURL)/try-it-model") else {
            preconditionFailure("Worker base URL did not form the furniture generation URLs: \(workerBaseURL)")
        }
        self.compositeURL = compositeURL
        self.tryItModelURL = tryItModelURL
        sessionConfiguration.timeoutIntervalForRequest = Self.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: sessionConfiguration)
        self.modelCacheFolder = modelCacheFolder
        self.ciContext = ciContext
    }

    private func post(_ jsonBody: [String: Any], to url: URL) async throws -> Data {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONSerialization.data(withJSONObject: jsonBody),
            to: url,
            using: session,
            sendsAppSecret: true
        )
        let responseText = String(decoding: responseData, as: UTF8.self)
        switch statusCode {
        case 200: return responseData
        case 503: throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: responseText)
        default: throw RoomFurnitureGenerationError.workerReturned(statusCode: statusCode, body: responseText)
        }
    }

    /// Draws the product into the keyframe and returns the keyframe with the drawn piece pasted in, at the keyframe's
    /// size. `productJPEG` is the furniture's cutout over white (`roomFurnitureCutoutJPEG`), `maskPNG` comes from
    /// `roomFurnitureCompositeMaskPNG`, and `itemSizeWords` reads like "31.5 inches wide and 29.5 tall"
    /// (`RoomFurniture.sizeInWords`). `orientation` says which way the piece faces and what it stands on. The Worker cuts nothing: size words over 300 characters, or an image over 4,000,000
    /// characters of base64 (about 3 MB), gets a 400, so the title is cut here (`roomFurnitureTitleForTheWorker`).
    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data,
        keyframeWidth: Int,
        keyframeHeight: Int,
        productJPEG: Data,
        maskPNG: Data,
        itemTitle: String,
        itemSizeWords: String,
        orientation: RoomFurniturePaintingOrientation?
    ) async throws -> CGImage {
        guard let keyframe = decodedImage(from: keyframeJPEG) else {
            throw RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the keyframe is not an image")
        }
        guard let mask = decodedImage(from: maskPNG) else {
            throw RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the mask is not an image")
        }
        var requestBody: [String: Any] = [
            "keyframeJPEGBase64": keyframeJPEG.base64EncodedString(),
            "keyframeWidth": keyframeWidth,
            "keyframeHeight": keyframeHeight,
            "productJPEGBase64": productJPEG.base64EncodedString(),
            "maskPNGBase64": maskPNG.base64EncodedString(),
            "itemTitle": roomFurnitureTitleForTheWorker(itemTitle),
            "itemSizeWords": itemSizeWords,
        ]
        if let orientation {
            requestBody["itemFacing"] = orientation.facing.rawValue
            requestBody["backAgainstTheWall"] = orientation.backAgainstTheWall
            requestBody["itemContinuesPastTheFrameBottom"] = orientation.itemContinuesPastTheFrameBottom
            // An absent field means the floor, so a floor piece and an older Worker's request carry none.
            if orientation.standsOn == .tableOrShelf { requestBody["standsOn"] = orientation.standsOn.rawValue }
        }
        let responseData = try await post(requestBody, to: compositeURL)

        guard let reply = try? JSONDecoder().decode(RoomFurnitureCompositeReply.self, from: responseData),
              let generatedJPEG = Data(base64Encoded: reply.imageJPEGBase64),
              let generated = decodedImage(from: generatedJPEG) else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply holds no image")
        }
        guard generated.width == reply.width, generated.height == reply.height else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(
                reason: "the image is \(generated.width)x\(generated.height), and the reply says \(reply.width)x\(reply.height)"
            )
        }
        // The paste walks every pixel of the frame, so it runs off the main actor, where the panel draws.
        let pasteContext = ciContext
        let pastedOrNil = await Task.detached(priority: .userInitiated) {
            furnitureCompositePasted(keyframe: keyframe, generated: generated, mask: mask, context: pasteContext)
        }.value
        guard let pasted = pastedOrNil else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the drawn piece could not be pasted into the keyframe")
        }
        return pasted
    }

    /// The product as a GLB, from the cache when this page picture and title were made into a model before. `productJPEG`
    /// is the furniture's cutout over white, which the Worker is sent, and `cacheKeyData` is the page picture's JPEG bytes,
    /// which the cache is keyed on (see `tryItModelCacheKey`). A cache that cannot be read or written only costs a new
    /// model, so its errors never fail the call.
    func generateAModel(productJPEG: Data, itemTitle fullItemTitle: String, cacheKeyData: Data) async throws -> Data {
        // The key and the request use the same cut title, so what is cached is what the Worker was asked for.
        let itemTitle = roomFurnitureTitleForTheWorker(fullItemTitle)
        let cacheFile = modelCacheFolder.appendingPathComponent(tryItModelCacheKey(cacheKeyData: cacheKeyData, itemTitle: itemTitle) + ".glb")
        if let cachedModel = try? Data(contentsOf: cacheFile), dataIsAGLB(cachedModel) {
            return cachedModel
        }

        let modelData = try await post([
            "productJPEGBase64": productJPEG.base64EncodedString(),
            "itemTitle": itemTitle,
        ], to: tryItModelURL)
        guard dataIsAGLB(modelData) else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply is not a GLB")
        }

        do {
            try FileManager.default.createDirectory(at: modelCacheFolder, withIntermediateDirectories: true)
            try modelData.write(to: cacheFile, options: .atomic)
        } catch {
            print("Try-it model: could not cache the model: \(error.localizedDescription)")
        }
        return modelData
    }
}
