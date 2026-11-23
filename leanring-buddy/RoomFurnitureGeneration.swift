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
    /// The Worker answered 402: OpenAI is out of credit, so no painting can come until someone adds credit.
    case serviceIsOutOfCredit(body: String)
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

/// The connected pieces (4-connected) of the closed cells the fit keeps, and those it stands on.
nonisolated struct FurniturePieceCells {
    /// 1 for a cell of a kept piece, 0 otherwise.
    let kept: [Float]
    /// Whether a cell's piece is one the painted item can stand on: a kept piece whose strong change is not all darkening.
    let standsTheItem: [Bool]
}

/// A piece whose strongly changed pixels are under this share recolored or brightened only got darker, as a contact shadow
/// does, so the item does not stand on it.
nonisolated let furniturePieceLeastRecoloredShareToStandOn = 0.1

/// The box's outline in the fit's pixels: the convex outline of its projected corners, and of those corners and the same
/// corners raised to the top of the search.
nonisolated struct FurnitureBoxOutlines {
    let box: [CGPoint]
    let raisedToTheTop: [CGPoint]
}

/// The closed cells with only the connected pieces (4-connected) that hold some of `strongCells` and stand in the box: a
/// cell's center, `cellPixels` to a cell, lies inside the box's outline, or half or more of the piece's cells lie inside
/// the outline raised to the top (`FurnitureBoxOutlines`). So a lamp whose stem is close to the wall's color keeps its base
/// and its shade, even a shade wholly above the box. A piece beside the box, such as a learner, a window the edit
/// re-rendered, or a door's edge that reaches over the box from the side, is cleared however strongly it changed.
/// `strongPixelCounts` and `recoloredStrongPixelCounts` give each cell's strongly changed pixels and those of them that
/// brightened or changed color. A kept piece under `furniturePieceLeastRecoloredShareToStandOn` recolored only got darker,
/// as a contact shadow does, so the item does not stand on it (`FurniturePieceCells.standsTheItem`), unless no kept piece
/// brightened or changed color, as for a black piece in a light room, when the item stands on every kept piece.
nonisolated func cellsOfThePiecesReachingTheBox(
    _ cells: [Float], strongCells: [Bool], strongPixelCounts: [Int], recoloredStrongPixelCounts: [Int],
    columns: Int, rows: Int, cellPixels: Int, boxOutlines: FurnitureBoxOutlines
) -> FurniturePieceCells {
    var pieceOfCell = [Int](repeating: -1, count: cells.count)
    var pieceIsKept: [Bool] = [], pieceStandsTheItem: [Bool] = []
    for startIndex in cells.indices where cells[startIndex] > 0 && pieceOfCell[startIndex] < 0 {
        let piece = pieceIsKept.count
        var holdsStrongChange = false, reachesTheBox = false
        var strongPixels = 0, recoloredStrongPixels = 0, cellCount = 0, cellsAboveTheBox = 0
        pieceOfCell[startIndex] = piece
        var cellsToVisit = [startIndex]
        while let cellIndex = cellsToVisit.popLast() {
            let column = cellIndex % columns, row = cellIndex / columns
            if strongCells[cellIndex] { holdsStrongChange = true }
            strongPixels += strongPixelCounts[cellIndex]
            recoloredStrongPixels += recoloredStrongPixelCounts[cellIndex]
            let cellCenter = CGPoint(x: Double(column * cellPixels) + Double(cellPixels) / 2, y: Double(row * cellPixels) + Double(cellPixels) / 2)
            cellCount += 1
            if convexPolygon(boxOutlines.raisedToTheTop, contains: cellCenter) { cellsAboveTheBox += 1 }
            if !reachesTheBox { reachesTheBox = convexPolygon(boxOutlines.box, contains: cellCenter) }
            for (neighborColumn, neighborRow) in [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
            where neighborColumn >= 0 && neighborColumn < columns && neighborRow >= 0 && neighborRow < rows {
                let neighborIndex = neighborRow * columns + neighborColumn
                guard cells[neighborIndex] > 0, pieceOfCell[neighborIndex] < 0 else { continue }
                pieceOfCell[neighborIndex] = piece
                cellsToVisit.append(neighborIndex)
            }
        }
        let isKept = holdsStrongChange && (reachesTheBox || cellsAboveTheBox * 2 >= cellCount)
        pieceIsKept.append(isKept)
        pieceStandsTheItem.append(isKept && Double(recoloredStrongPixels) >= max(1, Double(strongPixels) * furniturePieceLeastRecoloredShareToStandOn))
    }
    // A black or charcoal piece on a light room only got darker everywhere, as its shadow did, so when no kept piece
    // brightened or changed color the item stands on every kept piece.
    let theItemStandsOnSomePiece = pieceStandsTheItem.contains(true)
    return FurniturePieceCells(
        kept: pieceOfCell.map { piece in piece >= 0 && pieceIsKept[piece] ? 1 : 0 },
        standsTheItem: pieceOfCell.map { piece in piece >= 0 && (theItemStandsOnSomePiece ? pieceStandsTheItem[piece] : pieceIsKept[piece]) }
    )
}

/// A cell changed by more than this many levels on average is strong change, which only the piece itself reaches.
nonisolated let furniturePieceStrongChangeLevels: Float = 42

/// How `furniturePieceWeights` tells the piece from the room: the change a cell must pass, and how its cells are closed.
nonisolated struct FurniturePieceShape: Equatable {
    let changeThresholdLevels: Float
    let closingGrowCells: Int
    let closingShrinkCells: Int
    /// How many cells the kept pieces grow by after they are told from the room, so their own soft edge is kept whole.
    var marginCells = 0

    /// The paste's own piece, with the margin `furniturePieceClosingGrowCells` and `furniturePieceClosingShrinkCells` leave.
    static let paste = FurniturePieceShape(
        changeThresholdLevels: furniturePieceChangeThresholdLevels, closingGrowCells: furniturePieceClosingGrowCells,
        closingShrinkCells: furniturePieceClosingShrinkCells
    )
    /// The fit's piece, which is moved, so any room it holds lands in the wrong place. The plush astronaut's painter relit the
    /// room around it by 14 to 20 levels (the door frame beside it and the carpet to its left), which joined the piece at the
    /// paste's 14 and was shrunk with it, while its contact shadow changed the carpet by 21 to 55 levels and the plush itself
    /// by over 63. The cells are closed with no margin, since a margin held a shrunk copy of the door's bottom edge.
    static let fit = FurniturePieceShape(changeThresholdLevels: 21, closingGrowCells: 2, closingShrinkCells: 2)
    /// The piece past the paste's grown mask (`furniturePiecePastTheGrownMask`): the fit's threshold and closing, so the
    /// room the painter relit by 14 to 20 levels and a stray change beside the box stay out, and then the paste's margin
    /// around what is kept, so the piece's anti-aliased edge and its soft shadow are not cut.
    static let pastTheGrownMask = FurniturePieceShape(
        changeThresholdLevels: 21, closingGrowCells: 2, closingShrinkCells: 2,
        marginCells: furniturePieceClosingGrowCells - furniturePieceClosingShrinkCells
    )
}

/// How much of the reply each pixel keeps, 0 to 1: 1 on and around the piece, 0 on the room the edit only repainted.
/// A cell is part of the piece when the reply, after the tone fit, differs strongly from the keyframe in it
/// (`furniturePieceChangeThresholdLevels`). That shape is closed, filled where it encloses a gap, and softened as the
/// constants above describe, then read back at each pixel. Both pixel arrays are RGBA bytes of `width` by `height`.
/// Only pixels the paste takes at all (`pasteWeights`, one byte per pixel, 0 where the paste keeps the keyframe) count as
/// changed. The edit re-renders the whole frame, so a window or a person elsewhere in it can differ by more than the
/// threshold, and such a cell must not join the piece and enclose room that is inside the paste.
/// `shape` says how the piece is told from the room (`FurniturePieceShape`), the paste's by default.
nonisolated func furniturePieceWeights(
    keyframePixels: [UInt8], correctedReplyPixels: [UInt8], pasteWeights: [UInt8], width: Int, height: Int, shape: FurniturePieceShape = .paste
) -> [Float] {
    furniturePiece(
        keyframePixels: keyframePixels, correctedReplyPixels: correctedReplyPixels, pasteWeights: pasteWeights, width: width, height: height,
        shape: shape, boxOutlines: nil
    ).weights
}

/// A pixel brightened by more than this many levels in some channel was not only darkened.
nonisolated let furniturePieceBrighteningLevels = 14
/// A pixel whose share of red or green in its color moved by more than this changed color, which a shadow does not.
nonisolated let furniturePieceColorShareChange = 0.03

/// The piece's weights (`furniturePieceWeights`) and, with `boxOutlines` (see `cellsOfThePiecesReachingTheBox`), which
/// pixels lie in a piece the item can stand on, by cell. Without `boxOutlines` every changed piece is kept and none is marked.
/// Whether a pixel only got darker is read on `uncorrectedReplyPixels`, the reply before its tone fit, when given: a gain
/// and an offset per channel, fitted on a ring of room, can shift a dark pixel's color, as they turned a test's shadow of
/// (65, 59, 50) into (91, 61, 47).
nonisolated func furniturePiece(
    keyframePixels: [UInt8], correctedReplyPixels: [UInt8], uncorrectedReplyPixels: [UInt8]? = nil, pasteWeights: [UInt8], width: Int, height: Int,
    shape: FurniturePieceShape, boxOutlines: FurnitureBoxOutlines?
) -> (weights: [Float], pixelStandsTheItem: (Int) -> Bool) {
    let cellPixels = furniturePieceCellPixels
    let cellColumns = (width + cellPixels - 1) / cellPixels
    let cellRows = (height + cellPixels - 1) / cellPixels
    var changeSums = [Float](repeating: 0, count: cellColumns * cellRows)
    var pastedPixelCounts = [Int](repeating: 0, count: cellColumns * cellRows)
    // Only the fit, which passes the box, asks which pieces only got darker.
    let countsTheDarkening = boxOutlines != nil
    var strongPixelCounts = [Int](repeating: 0, count: countsTheDarkening ? cellColumns * cellRows : 0)
    var recoloredStrongPixelCounts = strongPixelCounts
    let strongPixelLevels = Int(furniturePieceStrongChangeLevels)
    let replyPixelsForTheDarkening = uncorrectedReplyPixels ?? correctedReplyPixels
    keyframePixels.withUnsafeBufferPointer { keyframeBytes in
        correctedReplyPixels.withUnsafeBufferPointer { replyBytes in
            replyPixelsForTheDarkening.withUnsafeBufferPointer { replyBytesForTheDarkening in
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
                                let largestChange = max(redChange, greenChange, blueChange)
                                sums[cellIndex] += Float(largestChange)
                                guard countsTheDarkening, largestChange > strongPixelLevels else { continue }
                                strongPixelCounts[cellIndex] += 1
                                if pixelWasRecoloredOrBrightened(keyframe: keyframeBytes, reply: replyBytesForTheDarkening, byteIndex: byteIndex) {
                                    recoloredStrongPixelCounts[cellIndex] += 1
                                }
                            }
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
    var strongCells = [Bool](repeating: false, count: cellColumns * cellRows)
    for cellRow in 0..<cellRows {
        let pixelRows = min(cellPixels, height - cellRow * cellPixels)
        for cellColumn in 0..<cellColumns {
            let cellIndex = cellRow * cellColumns + cellColumn
            let pixelsInTheCell = pixelRows * min(cellPixels, width - cellColumn * cellPixels)
            guard pastedPixelCounts[cellIndex] * 2 >= pixelsInTheCell else { continue }
            let averageChange = changeSums[cellIndex] / Float(pastedPixelCounts[cellIndex])
            changedCells[cellIndex] = averageChange > shape.changeThresholdLevels ? 1 : 0
            strongCells[cellIndex] = averageChange > furniturePieceStrongChangeLevels
        }
    }
    let grownCells = binaryWindowFiltered(changedCells, width: cellColumns, height: cellRows, radius: shape.closingGrowCells, keepsAnyHit: true)
    let closedCells = binaryWindowFiltered(grownCells, width: cellColumns, height: cellRows, radius: shape.closingShrinkCells, keepsAnyHit: false)
    let reachingCells = boxOutlines.map { boxOutlines in
        cellsOfThePiecesReachingTheBox(
            closedCells, strongCells: strongCells, strongPixelCounts: strongPixelCounts, recoloredStrongPixelCounts: recoloredStrongPixelCounts,
            columns: cellColumns, rows: cellRows, cellPixels: cellPixels, boxOutlines: boxOutlines
        )
    }
    let keptCells = reachingCells?.kept ?? closedCells
    let pieceCells = shape.marginCells > 0
        ? binaryWindowFiltered(keptCells, width: cellColumns, height: cellRows, radius: shape.marginCells, keepsAnyHit: true)
        : keptCells
    let solidCells = cellsWithEnclosedGapsFilled(pieceCells, columns: cellColumns, rows: cellRows)
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
    let standingCells = reachingCells?.standsTheItem ?? []
    return (pieceWeights, { pixelIndex in
        guard !standingCells.isEmpty else { return false }
        return standingCells[(pixelIndex / width / cellPixels) * cellColumns + (pixelIndex % width) / cellPixels]
    })
}

/// Whether the reply's pixel at `byteIndex` (RGBA bytes) brightened by more than `furniturePieceBrighteningLevels` in some
/// channel, or changed color by more than `furniturePieceColorShareChange`. A shadow does neither: it darkens the floor and
/// keeps its color. A pixel too dark to read its color by (under 30 levels in all) counts only by brightening.
private nonisolated func pixelWasRecoloredOrBrightened(keyframe: UnsafeBufferPointer<UInt8>, reply: UnsafeBufferPointer<UInt8>, byteIndex: Int) -> Bool {
    let keyframeRed = Int(keyframe[byteIndex]), keyframeGreen = Int(keyframe[byteIndex + 1]), keyframeBlue = Int(keyframe[byteIndex + 2])
    let replyRed = Int(reply[byteIndex]), replyGreen = Int(reply[byteIndex + 1]), replyBlue = Int(reply[byteIndex + 2])
    let brightening = max(replyRed - keyframeRed, replyGreen - keyframeGreen, replyBlue - keyframeBlue)
    if brightening > furniturePieceBrighteningLevels { return true }
    let keyframeSum = keyframeRed + keyframeGreen + keyframeBlue, replySum = replyRed + replyGreen + replyBlue
    guard keyframeSum >= 30, replySum >= 30 else { return false }
    let redShareChange = abs(Double(replyRed) / Double(replySum) - Double(keyframeRed) / Double(keyframeSum))
    let greenShareChange = abs(Double(replyGreen) / Double(replySum) - Double(keyframeGreen) / Double(keyframeSum))
    return max(redShareChange, greenShareChange) > furniturePieceColorShareChange
}

// MARK: - Fitting a painting drawn too big

// OpenAI's image edit takes the mask and the size words only as guidance, and it draws a small item too big: on 2026-11-23
// it drew an 11 inch plush astronaut 373 rows tall in a box 234 rows tall, 1.6 times its size, so the paste cut its head off
// along the region's top and every painting was refused. Its shape, light, and shadow were right, so the client shrinks
// the painted piece back into the box about the row it stands on instead of throwing it away.

/// The fit shrinks a piece at most to this share. A piece drawn over twice the box's height is more likely something other
/// than the product, so it is pasted as it came and the judge refuses it.
nonisolated let furniturePaintingLeastFitScale = 0.5
/// A piece whose top is within this many rows of the search's top may run past it, so its top is not known and it is not
/// fitted.
nonisolated let furniturePaintingFitTopMarginRows = 8

/// How to shrink a painted piece back into its box: by `scale`, about `anchor`, in y-down keyframe pixels. The anchor is the
/// piece's own floor row (`paintedLowestRow`) below the footprint's middle, so the piece keeps the row the painter stood it
/// on. `paintedTopRow` is where the painter put the piece's top.
nonisolated struct FurniturePaintingFit: Equatable {
    let scale: Double
    let anchor: CGPoint
    let paintedTopRow: Int
    let paintedLowestRow: Int
    /// The rectangle the piece was looked for in, in y-down keyframe pixels, which the fit reads the piece from.
    let searchRectangle: CGRect
    /// The reply in the search rectangle with its tone matched to the keyframe on a ring around the rectangle, as RGBA
    /// bytes, row by row from the rectangle's top.
    let correctedReplyInTheSearch: [UInt8]
    /// How much of the reply each pixel of the search rectangle is the piece, 0 to 1 (`furniturePiece` with the fit's
    /// shape and the box's outline).
    let pieceWeightsInTheSearch: [Float]
}

/// The fit for a painting whose piece rises above its box's top by more than the paste takes
/// (`furnitureCompositePasteSlackPixels`) or is taller than the judge allows (`RoomFurniturePaintedComposite.mostHeightDifference`),
/// or nil when it needs none or cannot be measured.
/// The piece is read from a search rectangle, the box's columns widened by half its width on each side and the rows a
/// piece of `furniturePaintingLeastFitScale` could reach, with the reply's tone matched to the keyframe on a ring of
/// `toneMatchBandPixels` around the rectangle (the oversized piece reaches into the paste's own ring).
/// The piece is every part that changed strongly and reaches into the box's outline, or lies mostly straight above it
/// (`furniturePiece` with `FurniturePieceShape.fit`). So a learner or a window beside the box is no part of it.
/// A lamp's shade and base both are.
/// Its painted rows are the rows where enough of the piece's pixels changed in luminance by more than the judge's
/// `paintedLuminanceChange`. Enough is what the judge needs in that row (`RoomFurniturePaintedComposite.changedPixelsARowNeeds`),
/// counted on `pasteRegion`, the paste's grown mask (one byte per frame pixel, over 127 inside), as the judge counts it.
/// The item stands on its lowest painted row of a part that did not only get darker, at most the box's lowest row.
/// A contact shadow painted under a floating piece is therefore no floor.
/// When the middle of that row is off the footprint as the judge measures it (`floorContactLandsOnTheFootprint`), the piece
/// floats or stands beside its box. It is not fitted, so the judge refuses it as before.
/// The fit shrinks the piece about that row only until its top meets the box's top: a piece standing on the front of its
/// footprint comes to the box's outline height, and one standing further back to less, as the box allows there.
/// Only a box wholly inside the frame is fitted, since a piece the frame cuts off has no top or floor point to measure.
nonisolated func furniturePaintingFit(
    keyframePixels: [UInt8], replyPixels: [UInt8], width: Int, height: Int, projectedBox: [CGPoint], pasteRegion: [UInt8]?,
    toneMatchBandPixels: Double = furnitureCompositeToneMatchBandPixels
) -> FurniturePaintingFit? {
    guard projectedBox.count == 8,
          projectedBox.allSatisfy({ $0.x >= 0 && $0.y >= 0 && $0.x <= Double(width - 1) && $0.y <= Double(height - 1) }) else { return nil }
    let boxLeft = projectedBox.map(\.x).min() ?? 0, boxRight = projectedBox.map(\.x).max() ?? 0
    let boxTop = projectedBox.map(\.y).min() ?? 0, boxBottom = projectedBox.map(\.y).max() ?? 0
    let outlineHeight = boxBottom - boxTop
    guard outlineHeight >= 1, boxRight > boxLeft else { return nil }
    // The judge counts painted rows down to the box's lowest corner rounded up, and no lower.
    let lowestItemRow = min(height - 1, Int(boxBottom.rounded(.up)))
    let searchColumns = furniturePieceSearchColumns(projectedBox: projectedBox, width: width)
    let searchLeft = searchColumns.lowerBound, searchRight = searchColumns.upperBound
    let searchTop = max(0, Int(boxBottom - outlineHeight / furniturePaintingLeastFitScale - furnitureCompositePasteSlackPixels))
    let searchBottom = min(height - 1, lowestItemRow + Int(furnitureCompositePasteSlackPixels * 2))
    let searchWidth = searchRight - searchLeft + 1, searchHeight = searchBottom - searchTop + 1

    // The tone is matched on a ring around the search rectangle, read from a crop of the rectangle grown by the ring.
    let band = Int(toneMatchBandPixels)
    let ringLeft = max(0, searchLeft - band), ringRight = min(width - 1, searchRight + band)
    let ringTop = max(0, searchTop - band), ringBottom = min(height - 1, searchBottom + band)
    let ringWidth = ringRight - ringLeft + 1, ringHeight = ringBottom - ringTop + 1
    func crop(_ pixels: [UInt8], left: Int, top: Int, cropWidth: Int, cropHeight: Int) -> [UInt8] {
        rgbaCrop(pixels, frameWidth: width, left: left, top: top, cropWidth: cropWidth, cropHeight: cropHeight)
    }
    var sampleIsInTheRing = [Bool](repeating: false, count: ringWidth * ringHeight)
    for row in 0..<ringHeight {
        let frameRow = ringTop + row
        for column in 0..<ringWidth {
            let frameColumn = ringLeft + column
            sampleIsInTheRing[row * ringWidth + column] = !(frameRow >= searchTop && frameRow <= searchBottom && frameColumn >= searchLeft && frameColumn <= searchRight)
        }
    }
    let toneFits = toneFitsMatchingTheReplyToTheKeyframe(
        keyframePixels: crop(keyframePixels, left: ringLeft, top: ringTop, cropWidth: ringWidth, cropHeight: ringHeight),
        replyPixels: crop(replyPixels, left: ringLeft, top: ringTop, cropWidth: ringWidth, cropHeight: ringHeight),
        sampleIsInTheRing: sampleIsInTheRing
    )
    let keyframeInTheSearch = crop(keyframePixels, left: searchLeft, top: searchTop, cropWidth: searchWidth, cropHeight: searchHeight)
    let uncorrectedReplyInTheSearch = crop(replyPixels, left: searchLeft, top: searchTop, cropWidth: searchWidth, cropHeight: searchHeight)
    let replyInTheSearch = toneCorrectedPixels(uncorrectedReplyInTheSearch, by: toneFits)

    // Each frame row needs as many changed pixels as the judge needs in it, from the pasted region's pixels in that row.
    let changedPixelsEachRowNeeds = (searchTop...searchBottom).map { frameRow in
        let regionPixelsInTheRow = pasteRegion.map { pasteRegion in
            (0..<width).reduce(0) { count, column in count + (pasteRegion[frameRow * width + column] > 127 ? 1 : 0) }
        } ?? 0
        return RoomFurniturePaintedComposite.changedPixelsARowNeeds(regionPixelsInTheRow: regionPixelsInTheRow)
    }
    let luminanceChangeThreshold = RoomFurniturePaintedComposite.paintedLuminanceChange * 255
    /// The row's changed pixels, only those `counts` takes when it is given (by their index in the search rectangle), and
    /// their mean frame column, or nil when too few changed for the row to count as painted. `frameRow` is a keyframe row.
    func paintedRow(_ frameRow: Int, counting counts: ((Int) -> Bool)?) -> Double? {
        let row = frameRow - searchTop
        var changedPixels = 0, columnSum = 0
        for column in 0..<searchWidth {
            if let counts, !counts(row * searchWidth + column) { continue }
            let byteIndex = (row * searchWidth + column) * 4
            let redChange = abs(Double(replyInTheSearch[byteIndex]) - Double(keyframeInTheSearch[byteIndex]))
            let greenChange = abs(Double(replyInTheSearch[byteIndex + 1]) - Double(keyframeInTheSearch[byteIndex + 1]))
            let blueChange = abs(Double(replyInTheSearch[byteIndex + 2]) - Double(keyframeInTheSearch[byteIndex + 2]))
            // The judge reads the same luminance of the difference (Rec. 709 weights).
            if 0.2126 * redChange + 0.7152 * greenChange + 0.0722 * blueChange > luminanceChangeThreshold {
                changedPixels += 1
                columnSum += column
            }
        }
        guard changedPixels >= changedPixelsEachRowNeeds[row] else { return nil }
        return Double(searchLeft) + Double(columnSum) / Double(changedPixels)
    }
    let mostHeightTheJudgeKeeps = outlineHeight * (1 + RoomFurniturePaintedComposite.mostHeightDifference)
    let highestRowThePasteKeeps = boxTop - furnitureCompositePasteSlackPixels

    // Every painted row of the whole search, the piece's or not, is a bound on the piece's: a painting whose highest such
    // row is kept by both the paste and the judge needs no fit, and the piece's weights, the costly part, are never made.
    guard let highestChangedRow = (searchTop...lowestItemRow).first(where: { paintedRow($0, counting: nil) != nil }) else { return nil }
    guard Double(highestChangedRow) < highestRowThePasteKeeps || Double(lowestItemRow - highestChangedRow) > mostHeightTheJudgeKeeps else { return nil }

    // The box's outline, and the same raised to the search's top, so a part straight above the box counts.
    func inTheSearch(_ outline: [CGPoint]) -> [CGPoint] { outline.map { CGPoint(x: $0.x - Double(searchLeft), y: $0.y - Double(searchTop)) } }
    let raisedBox = projectedBox.map { CGPoint(x: $0.x, y: Double(searchTop)) }
    let boxOutlines = FurnitureBoxOutlines(box: inTheSearch(convexHull(of: projectedBox)), raisedToTheTop: inTheSearch(convexHull(of: projectedBox + raisedBox)))
    let piece = furniturePiece(
        keyframePixels: keyframeInTheSearch, correctedReplyPixels: replyInTheSearch, uncorrectedReplyPixels: uncorrectedReplyInTheSearch,
        pasteWeights: [UInt8](repeating: 255, count: searchWidth * searchHeight), width: searchWidth, height: searchHeight,
        shape: .fit, boxOutlines: boxOutlines
    )
    let pieceWeights = piece.weights
    let isThePiece: (Int) -> Bool = { pieceWeights[$0] >= 0.5 }
    let isWhereThePieceStands: (Int) -> Bool = { pieceWeights[$0] >= 0.5 && piece.pixelStandsTheItem($0) }
    // The piece's lowest painted row on a part it stands on is where it stands, as the judge finds its floor contact.
    guard let paintedLowestRow = stride(from: lowestItemRow, through: searchTop, by: -1).first(where: { paintedRow($0, counting: isWhereThePieceStands) != nil }),
          let contactColumn = paintedRow(paintedLowestRow, counting: isWhereThePieceStands) else { return nil }
    let footprint = [projectedBox[2], projectedBox[3], projectedBox[6], projectedBox[7]]
    guard RoomFurniturePaintedComposite.floorContactLandsOnTheFootprint(CGPoint(x: contactColumn, y: Double(paintedLowestRow)), footprint: footprint) else { return nil }
    // A piece that runs to the search's top, or the frame's, has a top the search did not reach.
    guard let paintedTopRow = (searchTop...paintedLowestRow).first(where: { paintedRow($0, counting: isThePiece) != nil }),
          paintedTopRow > searchTop + furniturePaintingFitTopMarginRows else { return nil }
    let paintedHeight = Double(paintedLowestRow - paintedTopRow)
    guard Double(paintedTopRow) < highestRowThePasteKeeps || paintedHeight > mostHeightTheJudgeKeeps else { return nil }
    // The shrunk piece's top lands on the box's top row.
    let scale = (Double(paintedLowestRow) - boxTop) / paintedHeight
    guard scale >= furniturePaintingLeastFitScale, scale < 1 else { return nil }
    let anchor = CGPoint(x: footprint.map(\.x).reduce(0, +) / 4, y: Double(paintedLowestRow))
    return FurniturePaintingFit(
        scale: scale, anchor: anchor, paintedTopRow: paintedTopRow, paintedLowestRow: paintedLowestRow,
        searchRectangle: CGRect(x: searchLeft, y: searchTop, width: searchWidth, height: searchHeight),
        correctedReplyInTheSearch: replyInTheSearch, pieceWeightsInTheSearch: pieceWeights
    )
}

/// The keyframe with the painted piece shrunk by `fit` and laid over it. The piece is the fit's own (its weights, its
/// shadow included, and its tone-matched reply), and each output pixel in the search rectangle reads the reply and that
/// weight back through the shrink with a bilinear read, so the room the oversized piece covered shows as filmed.
nonisolated func furniturePiecePastedAfterTheFit(keyframePixels: [UInt8], width: Int, height: Int, fit: FurniturePaintingFit) -> [UInt8] {
    let search = fit.searchRectangle
    let searchLeft = Int(search.minX), searchTop = Int(search.minY), searchRight = Int(search.maxX) - 1, searchBottom = Int(search.maxY) - 1
    let searchWidth = searchRight - searchLeft + 1
    var pastedPixels = keyframePixels
    func readBilinear(_ sampleColumn: Double, _ sampleRow: Double, _ value: (Int, Int) -> Float) -> Float {
        let left = Int(sampleColumn.rounded(.down)), top = Int(sampleRow.rounded(.down))
        let columnShare = Float(sampleColumn - Double(left)), rowShare = Float(sampleRow - Double(top))
        let right = min(searchRight, left + 1), bottom = min(searchBottom, top + 1)
        let upper = value(left, top) * (1 - columnShare) + value(right, top) * columnShare
        let lower = value(left, bottom) * (1 - columnShare) + value(right, bottom) * columnShare
        return upper * (1 - rowShare) + lower * rowShare
    }
    for row in searchTop...searchBottom {
        for column in searchLeft...searchRight {
            // The output pixel reads the reply where the shrink took it from.
            let sourceX = fit.anchor.x + (Double(column) - fit.anchor.x) / fit.scale
            let sourceY = fit.anchor.y + (Double(row) - fit.anchor.y) / fit.scale
            guard sourceX >= Double(searchLeft), sourceX <= Double(searchRight), sourceY >= Double(searchTop), sourceY <= Double(searchBottom) else { continue }
            let weight = readBilinear(sourceX, sourceY) { sourceColumn, sourceRow in
                fit.pieceWeightsInTheSearch[(sourceRow - searchTop) * searchWidth + sourceColumn - searchLeft]
            }
            guard weight > 0 else { continue }
            for channel in 0..<3 {
                let value = readBilinear(sourceX, sourceY) { sourceColumn, sourceRow in
                    Float(fit.correctedReplyInTheSearch[((sourceRow - searchTop) * searchWidth + sourceColumn - searchLeft) * 4 + channel])
                }
                let byteIndex = (row * width + column) * 4 + channel
                pastedPixels[byteIndex] = UInt8((Float(keyframePixels[byteIndex]) * (1 - weight) + value * weight).rounded())
            }
        }
    }
    return pastedPixels
}

/// The RGBA bytes of the `cropWidth` by `cropHeight` rectangle at `left`, `top` of a frame `frameWidth` pixels wide.
nonisolated func rgbaCrop(_ pixels: [UInt8], frameWidth: Int, left: Int, top: Int, cropWidth: Int, cropHeight: Int) -> [UInt8] {
    var cropped = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
    for row in 0..<cropHeight {
        let frameStart = ((top + row) * frameWidth + left) * 4, cropStart = row * cropWidth * 4
        cropped[cropStart..<(cropStart + cropWidth * 4)] = pixels[frameStart..<(frameStart + cropWidth * 4)]
    }
    return cropped
}

/// The columns the painted piece is looked for in: the box's columns widened by half its width on each side, inside the
/// frame. `furniturePaintingFit` and `furniturePiecePastTheGrownMask` share them.
nonisolated func furniturePieceSearchColumns(projectedBox: [CGPoint], width: Int) -> ClosedRange<Int> {
    let boxLeft = projectedBox.map(\.x).min() ?? 0, boxRight = projectedBox.map(\.x).max() ?? 0
    let boxWidth = boxRight - boxLeft
    let searchLeft = min(width - 1, max(0, Int(boxLeft - boxWidth / 2))), searchRight = max(searchLeft, min(width - 1, Int(boxRight + boxWidth / 2)))
    return searchLeft...searchRight
}

/// How much of the reply each frame pixel is the painted piece, 0 to 1, for the part of the piece the paste's grown mask
/// may not reach. The painter follows the mask only as guidance: on 2026-11-23 it drew a seated plush astronaut's feet 20
/// to 40 pixels past the mask, since a box whose depth the page does not state is shallower than a seated plush's legs,
/// and the paste cut the soles off along a straight line 24 pixels out.
/// The piece is read in the fit's columns (`furniturePieceSearchColumns`) from `furnitureCompositePasteSlackPixels` above the
/// box's top, where the grown mask already reaches, down to twice that below its lowest corner. A piece drawn taller than
/// its box is the fit's work, so nothing above that is read. Only the parts that changed strongly and reach into the box's
/// outline count (`furniturePiece` with `FurniturePieceShape.pastTheGrownMask`), so a learner, a window, a door's edge, or
/// relit carpet beside the box keeps the keyframe. Both pixel arrays are RGBA bytes of the frame, the reply's after its tone fit.
nonisolated func furniturePiecePastTheGrownMask(
    keyframePixels: [UInt8], correctedReplyPixels: [UInt8], width: Int, height: Int, projectedBox: [CGPoint]
) -> [Float] {
    var frameWeights = [Float](repeating: 0, count: width * height)
    guard projectedBox.count == 8 else { return frameWeights }
    let boxTop = projectedBox.map(\.y).min() ?? 0, boxBottom = projectedBox.map(\.y).max() ?? 0
    let columns = furniturePieceSearchColumns(projectedBox: projectedBox, width: width)
    let searchTop = min(height - 1, max(0, Int(boxTop - furnitureCompositePasteSlackPixels)))
    let searchBottom = min(height - 1, Int(boxBottom.rounded(.up) + furnitureCompositePasteSlackPixels * 2))
    guard searchBottom > searchTop, columns.count > 1 else { return frameWeights }
    let searchLeft = columns.lowerBound, searchWidth = columns.count, searchHeight = searchBottom - searchTop + 1

    func inTheSearch(_ outline: [CGPoint]) -> [CGPoint] { outline.map { CGPoint(x: $0.x - Double(searchLeft), y: $0.y - Double(searchTop)) } }
    let raisedBox = projectedBox.map { CGPoint(x: $0.x, y: Double(searchTop)) }
    let piece = furniturePiece(
        keyframePixels: rgbaCrop(keyframePixels, frameWidth: width, left: searchLeft, top: searchTop, cropWidth: searchWidth, cropHeight: searchHeight),
        correctedReplyPixels: rgbaCrop(correctedReplyPixels, frameWidth: width, left: searchLeft, top: searchTop, cropWidth: searchWidth, cropHeight: searchHeight),
        pasteWeights: [UInt8](repeating: 255, count: searchWidth * searchHeight), width: searchWidth, height: searchHeight,
        shape: .pastTheGrownMask,
        boxOutlines: FurnitureBoxOutlines(box: inTheSearch(convexHull(of: projectedBox)), raisedToTheTop: inTheSearch(convexHull(of: projectedBox + raisedBox)))
    )
    for row in 0..<searchHeight {
        let frameStart = (searchTop + row) * width + searchLeft, searchStart = row * searchWidth
        frameWeights[frameStart..<(frameStart + searchWidth)] = piece.weights[searchStart..<(searchStart + searchWidth)]
    }
    return frameWeights
}

/// The keyframe with the painted piece pasted in, and the region the paste took the painting from: an 8-bit gray image of
/// the keyframe's size, 255 where the paste may keep the painting, 0 where it keeps the keyframe, and between them along
/// its feathered edge. It is the item layer's alpha (`RoomFurniturePaintedComposite.itemLayers`).
nonisolated struct RoomFurniturePaintedKeyframe: @unchecked Sendable {
    // @unchecked because CGImage is immutable, so sharing one across tasks is safe.
    let image: CGImage
    let pastedRegion: CGImage
}

/// The paste of `furnitureCompositePastedWithItsRegion` without its region, for a caller that draws the whole image.
nonisolated func furnitureCompositePasted(
    keyframe: CGImage,
    generated: CGImage,
    mask: CGImage,
    slackPixels: Double = furnitureCompositePasteSlackPixels,
    featherPixels: Double = furnitureCompositePasteFeatherPixels,
    toneMatchBandPixels: Double = furnitureCompositeToneMatchBandPixels,
    keepsOnlyThePieceTheReplyChanged: Bool = true,
    projectedBox: [CGPoint]? = nil,
    context: CIContext
) -> CGImage? {
    furnitureCompositePastedWithItsRegion(
        keyframe: keyframe, generated: generated, mask: mask, slackPixels: slackPixels, featherPixels: featherPixels,
        toneMatchBandPixels: toneMatchBandPixels, keepsOnlyThePieceTheReplyChanged: keepsOnlyThePieceTheReplyChanged,
        projectedBox: projectedBox, context: context
    )?.image
}

/// The keyframe with `generated` pasted in only where the mask, grown by `slackPixels` and feathered by
/// `featherPixels`, allows, and the region that was. The edit re-renders the whole frame, and pixels away from the piece
/// come back slightly changed (a window's view, the light on a wall), so everything past the grown mask stays exactly as
/// filmed, except the piece itself where the painter drew it past the grown mask (`furniturePiecePastTheGrownMask`, with
/// `projectedBox` only). Before the paste,
/// the reply's tone is matched to the keyframe on a ring `toneMatchBandPixels` wide just outside the paste
/// (`toneFitsMatchingTheReplyToTheKeyframe`), so the pasted region does not show as a lighter or darker patch. Inside the
/// region, only the piece keeps the reply: the room the edit repainted a few levels lighter, which one global fit cannot
/// follow, keeps the keyframe's own pixels (`furniturePieceWeights`). `keepsOnlyThePieceTheReplyChanged` false pastes
/// the whole grown region instead, for a painting that must replace everything in its mask, as the shirt's must cover
/// the learner's own top even where the new one is close to its color. A `generated` of another size, which the Worker
/// returns for a keyframe size OpenAI does not take, is scaled to the keyframe first. With `projectedBox`, a piece drawn
/// taller than that box allows is shrunk back into it about the row it stands on instead (`furniturePaintingFit`), and
/// its region stays the grown mask.
nonisolated func furnitureCompositePastedWithItsRegion(
    keyframe: CGImage,
    generated: CGImage,
    mask: CGImage,
    slackPixels: Double = furnitureCompositePasteSlackPixels,
    featherPixels: Double = furnitureCompositePasteFeatherPixels,
    toneMatchBandPixels: Double = furnitureCompositeToneMatchBandPixels,
    keepsOnlyThePieceTheReplyChanged: Bool = true,
    projectedBox: [CGPoint]? = nil,
    context: CIContext
) -> RoomFurniturePaintedKeyframe? {
    let width = keyframe.width
    let height = keyframe.height
    let frameExtent = CGRect(x: 0, y: 0, width: width, height: height)
    guard let keyframePixels = rgbaBytes(of: keyframe, width: width, height: height),
          let replyPixels = rgbaBytes(of: generated, width: width, height: height),
          let pasteMask = grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: slackPixels, blurPixels: featherPixels, context: context),
          let ringOuterMask = grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: slackPixels + featherPixels + toneMatchBandPixels, blurPixels: 0, context: context),
          let pasteWeights = grayBytes(of: pasteMask, width: width, height: height),
          let ringOuterWeights = grayBytes(of: ringOuterMask, width: width, height: height) else { return nil }

    if let projectedBox, keepsOnlyThePieceTheReplyChanged,
       let fit = furniturePaintingFit(
           keyframePixels: keyframePixels, replyPixels: replyPixels, width: width, height: height, projectedBox: projectedBox,
           pasteRegion: pasteWeights, toneMatchBandPixels: toneMatchBandPixels
       ) {
        print(String(
            format: "Room furniture: the painting's piece runs from row %d to %d, past what its box keeps, so it is shrunk to %.0f%% about row %d",
            fit.paintedTopRow, fit.paintedLowestRow, fit.scale * 100, fit.paintedLowestRow
        ))
        guard let fitted = rgbaImage(furniturePiecePastedAfterTheFit(keyframePixels: keyframePixels, width: width, height: height, fit: fit), width: width, height: height) else { return nil }
        return RoomFurniturePaintedKeyframe(image: fitted, pastedRegion: pasteMask)
    }

    // The ring is the room the paste does not take but the grown mask reaches: the closest room to the piece.
    let sampleIsInTheRing = zip(pasteWeights, ringOuterWeights).map { pasteWeight, ringOuterWeight in
        pasteWeight == 0 && ringOuterWeight >= 128
    }
    let toneFits = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: replyPixels, sampleIsInTheRing: sampleIsInTheRing)

    let correctedReplyPixels = toneCorrectedPixels(replyPixels, by: toneFits)
    let pieceWeights = keepsOnlyThePieceTheReplyChanged
        ? furniturePieceWeights(keyframePixels: keyframePixels, correctedReplyPixels: correctedReplyPixels, pasteWeights: pasteWeights, width: width, height: height)
        : [Float](repeating: 1, count: width * height)
    // The piece where the painter drew it past the grown mask, which the paste and the region take too. Only a piece paste
    // with its box has one.
    let pieceWeightsPastTheGrownMask: [Float]? = keepsOnlyThePieceTheReplyChanged ? projectedBox.map { projectedBox in
        furniturePiecePastTheGrownMask(
            keyframePixels: keyframePixels, correctedReplyPixels: correctedReplyPixels, width: width, height: height, projectedBox: projectedBox
        )
    } : nil

    var pastedPixels = keyframePixels
    pastedPixels.withUnsafeMutableBufferPointer { pastedBytes in
        correctedReplyPixels.withUnsafeBufferPointer { correctedBytes in
            pasteWeights.withUnsafeBufferPointer { pasteWeightBytes in
                pieceWeights.withUnsafeBufferPointer { pieceWeightValues in
                    for pixelIndex in 0..<(width * height) {
                        let replyShareInTheGrownMask = Float(pasteWeightBytes[pixelIndex]) / 255 * pieceWeightValues[pixelIndex]
                        let replyShare = max(replyShareInTheGrownMask, pieceWeightsPastTheGrownMask?[pixelIndex] ?? 0)
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

    guard let pastedImage = rgbaImage(pastedPixels, width: width, height: height) else { return nil }
    guard let pieceWeightsPastTheGrownMask else { return RoomFurniturePaintedKeyframe(image: pastedImage, pastedRegion: pasteMask) }
    let regionBytes = zip(pasteWeights, pieceWeightsPastTheGrownMask).map { pasteWeight, pieceWeight in
        max(pasteWeight, UInt8((min(1, max(0, pieceWeight)) * 255).rounded()))
    }
    guard let region = grayImage(bytes: regionBytes, width: width, height: height) else { return nil }
    return RoomFurniturePaintedKeyframe(image: pastedImage, pastedRegion: region)
}

/// RGBA bytes with each color channel's tone fit applied, clamped to bytes.
nonisolated func toneCorrectedPixels(_ pixels: [UInt8], by toneFits: [ChannelToneFit]) -> [UInt8] {
    var correctedPixels = pixels
    correctedPixels.withUnsafeMutableBufferPointer { correctedBytes in
        for pixelIndex in 0..<(correctedBytes.count / 4) {
            for channel in 0..<3 {
                let byteIndex = pixelIndex * 4 + channel
                let corrected = toneFits[channel].gain * Double(correctedBytes[byteIndex]) + toneFits[channel].offset
                correctedBytes[byteIndex] = UInt8(min(255, max(0, corrected)).rounded())
            }
        }
    }
    return correctedPixels
}

/// An sRGB image of RGBA bytes, with the first row the top.
nonisolated func rgbaImage(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let pixelProvider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
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
        case 402: throw RoomFurnitureGenerationError.serviceIsOutOfCredit(body: responseText)
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
        orientation: RoomFurniturePaintingOrientation?,
        projectedBox: [CGPoint]? = nil
    ) async throws -> RoomFurniturePaintedKeyframe {
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
            furnitureCompositePastedWithItsRegion(keyframe: keyframe, generated: generated, mask: mask, projectedBox: projectedBox, context: pasteContext)
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
