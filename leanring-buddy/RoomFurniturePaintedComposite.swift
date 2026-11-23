//
//  RoomFurniturePaintedComposite.swift
//  leanring-buddy
//
//  The two looks of a piece of furniture that the generation service makes: a generated 3D model, and a photo composite
//  where the item is painted into the keyframe. `RoomFurnitureGenerating` is the seam to that service's client
//  (`RoomFurnitureGenerationClient`), so the controller and its tests never depend on the network.
//  `RoomFurniturePaintedComposite` turns a painted keyframe into the layer the frame processor draws: the region the client
//  pasted (the mask grown by `furnitureCompositePasteSlackPixels` with a `furnitureCompositePasteFeatherPixels` feather),
//  kept only when the painted item stands as tall as the measured box says it should.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the generation service does for the furniture: a model from the furniture's cutout over white, and the item painted into the
/// keyframe inside a mask. Either throws when the service is not set up (the Worker answers 503 without its key) or fails,
/// and the furniture then falls back to the next look.
protocol RoomFurnitureGenerating {
    /// GLB bytes of a model of the product in `productJPEG`, the furniture's cutout over white. `cacheKeyData` is what the
    /// model is cached by, the page picture's JPEG bytes.
    func generateAModel(productJPEG: Data, itemTitle: String, cacheKeyData: Data) async throws -> Data
    /// The keyframe with the item painted in where the mask is white, at the keyframe's size. `orientation` says which way
    /// the piece faces, which the mask alone cannot: a convex area looks the same turned 180 degrees.
    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data,
        keyframeWidth: Int,
        keyframeHeight: Int,
        productJPEG: Data,
        maskPNG: Data,
        itemTitle: String,
        itemSizeWords: String,
        orientation: RoomFurniturePaintingOrientation?
    ) async throws -> CGImage
}

extension RoomFurnitureGenerating {
    /// A painting with no orientation, which the Worker asks for turned the way the masked area's shape shows.
    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data, keyframeWidth: Int, keyframeHeight: Int, productJPEG: Data, maskPNG: Data, itemTitle: String, itemSizeWords: String
    ) async throws -> CGImage {
        try await paintTheItemIntoTheKeyframe(
            keyframeJPEG: keyframeJPEG, keyframeWidth: keyframeWidth, keyframeHeight: keyframeHeight, productJPEG: productJPEG,
            maskPNG: maskPNG, itemTitle: itemTitle, itemSizeWords: itemSizeWords, orientation: nil
        )
    }
}

/// How the painter draws the piece, which the mask alone cannot say: which way it faces, from the ghost the learner placed
/// (a convex area looks the same turned 180 degrees), and whether the frame cuts off its lower part. The Worker turns each
/// into its own words.
nonisolated struct RoomFurniturePaintingOrientation: Equatable, Sendable {
    let facing: RoomFurnitureFacing
    let backAgainstTheWall: Bool
    /// Whether the box's floor footprint reaches the frame's bottom row or lies below it (`roomFurnitureFootprintReachesTheFrameBottom`),
    /// so the piece's front feet and floor shadow are below the picture, and its back feet may be in it. Set per painting
    /// frame, since the tracker's turn moves the box, so the ghost's own orientation leaves it false.
    var itemContinuesPastTheFrameBottom = false
}

extension RoomFurnitureGenerationClient: RoomFurnitureGenerating {}

/// The generation service when none is wired in, which the controller's tests start from: every request says the service
/// is not set up, as the Worker's 503 does, and the furniture keeps the looks it has.
struct RoomFurnitureGenerationNotSetUp: RoomFurnitureGenerating {
    func generateAModel(productJPEG: Data, itemTitle: String, cacheKeyData: Data) async throws -> Data {
        throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: "")
    }

    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data, keyframeWidth: Int, keyframeHeight: Int, productJPEG: Data, maskPNG: Data, itemTitle: String, itemSizeWords: String,
        orientation: RoomFurniturePaintingOrientation?
    ) async throws -> CGImage {
        throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: "")
    }
}

nonisolated enum RoomFurniturePaintedComposite {
    /// How far the painted item's height may fall outside the range the measured box sets (its front face to its whole
    /// outline); a painting the model drew at the wrong size is worse than the look before it at the right one.
    static let mostHeightDifference = 0.15
    /// A pixel counts as painted when its luminance changed by more than this, which the service redrawing the wall inside
    /// the mask seldom reaches, so it does not stretch the item's measured height.
    static let paintedLuminanceChange = 0.2
    /// A row counts as part of the item when at least this share of the pasted region's pixels in it changed, or
    /// `fewestChangedPixelsInARow`, whichever is more. A share alone left out a chair's thin legs and the top of its back,
    /// and measured a LACK side table and a Blu Dot chair at 75 to 87 percent of their height.
    static let shareOfARowThatMustChange = 0.02
    static let fewestChangedPixelsInARow = 6
    /// A painting that changed at least this share of the pasted region's top `pixelsAlongTheRegionsTop` pixels, counted
    /// row by row from its top, reached past the region and was cut off by the paste. On the live check the service's
    /// redrawn wall changed 8 to 20 percent of them above a Blu Dot chair and none above a LACK side table, while a piece
    /// cut off there fills the region's top. Pixels and not rows, since the region often comes to a point at its top,
    /// where the first rows hold only a few pixels and one redrawn patch of wall refused a good painting of the chair.
    static let mostOfTheRegionsTopThatMayChange = 0.5
    static let pixelsAlongTheRegionsTop = 200
    /// The painted piece's floor contact, the middle of its lowest painted row, must land on the box's footprint, grown by
    /// this share of the footprint's size on each side. A piece painted floating above its footprint, or beside it, stands
    /// where the learner did not put it, even at the right height.
    static let floorContactSlackShare = 0.15

    /// The painted item as keyframe layers, or nil when the painting is not the keyframe's size, the mask does not read, the
    /// painted item is shorter than the box's front face or taller than its outline, each by more than
    /// `mostHeightDifference`, the item reached past the pasted region's top, where the paste cut it off, or its floor
    /// contact (the middle of its lowest painted row) is off the box's footprint grown by `floorContactSlackShare`
    /// (`floorContactLandsOnTheFootprint`). When the frame cuts the footprint off at its bottom row, the slack is taken from
    /// the footprint's height before the cut, so the contact may lie anywhere from the top of the visible footprint down to
    /// the bottom row, and a piece that floats above the visible footprint is refused. Also returns the painted height as a
    /// share of the box's outline and the painted rows' span (top and bottom in y-down keyframe pixels) for the log, each nil
    /// when nothing was painted.
    static func itemLayers(
        painted: CGImage,
        keyframe: CGImage,
        maskPNG: Data,
        projectedBox: [CGPoint],
        ciContext: CIContext = CIContext()
    ) -> (layers: RoomFurnitureKeyframeLayers?, paintedHeightRatio: Double?, paintedRows: ClosedRange<Int>?) {
        guard painted.width == keyframe.width, painted.height == keyframe.height, projectedBox.count == 8,
              let maskSource = CGImageSourceCreateWithData(maskPNG as CFData, nil),
              let maskImage = CGImageSourceCreateImageAtIndex(maskSource, 0, nil) else { return (nil, nil, nil) }
        let frameRectangle = CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height)
        let paintedImage = CIImage(cgImage: painted)
        // The client pasted its painting inside the mask grown by its slack, with its feather, and left the rest of the
        // keyframe as filmed, so the same grown mask is the item layer's alpha and the region where the painting is measured.
        guard let pastedRegion = grownMaskImage(
            maskImage, frameExtent: frameRectangle, radiusPixels: furnitureCompositePasteSlackPixels,
            blurPixels: furnitureCompositePasteFeatherPixels, context: ciContext
        ) else { return (nil, nil, nil) }
        let mask = CIImage(cgImage: pastedRegion)

        // The painted item must stand between two heights the measured box sets: no shorter than its front face (less
        // `mostHeightDifference`), since the piece is at least as tall as its front, and no taller than the box's whole
        // outline (plus `mostHeightDifference`). The outline alone overstates a chair, whose top is lower than the box's
        // back corners: on one frame the painted Target chair matched the exact render of the store's model and still
        // measured 79 percent of the outline.
        // A box that runs past the frame's edge, such as a long sofa placed near the camera, is measured as far as the frame
        // shows it, since the painter paints only the frame and the piece is cut off there as the box is.
        let boxInTheFrame = projectedBox.map { corner in
            CGPoint(x: min(max(corner.x, 0), Double(keyframe.width - 1)), y: min(max(corner.y, 0), Double(keyframe.height - 1)))
        }
        let boxOutlineHeight = (boxInTheFrame.map(\.y).max() ?? 0) - (boxInTheFrame.map(\.y).min() ?? 0)
        let frontFace = boxInTheFrame.prefix(4)
        let frontFaceHeight = (frontFace.map(\.y).max() ?? 0) - (frontFace.map(\.y).min() ?? 0)
        let lowestItemRow = Int((boxInTheFrame.map(\.y).max() ?? 0).rounded(.up))
        guard let (paintedRowSpan, shareChangedAlongTheRegionsTop, lowestRowMiddleColumn) = rowsThePaintingChanged(
            painted: paintedImage, keyframe: CIImage(cgImage: keyframe), mask: mask, frameRectangle: frameRectangle, lowestItemRow: lowestItemRow, ciContext: ciContext
        ) else {
            return (nil, nil, nil)
        }
        let paintedRows = Double(paintedRowSpan.count)
        let paintedHeightRatio = paintedRows / max(boxOutlineHeight, 1)
        // The client pasted nothing above the region, so a piece the service painted taller than it is cut off along the
        // region's top, where the height measured above cannot see it: the cut piece measures no taller than the region.
        guard shareChangedAlongTheRegionsTop < mostOfTheRegionsTopThatMayChange else { return (nil, paintedHeightRatio, paintedRowSpan) }
        guard paintedRows >= frontFaceHeight * (1 - mostHeightDifference),
              paintedRows <= boxOutlineHeight * (1 + mostHeightDifference) else { return (nil, paintedHeightRatio, paintedRowSpan) }
        let floorContact = CGPoint(x: lowestRowMiddleColumn, y: Double(paintedRowSpan.upperBound))
        let footprintInTheFrame = [boxInTheFrame[2], boxInTheFrame[3], boxInTheFrame[6], boxInTheFrame[7]]
        // The frame clamps a footprint below its bottom row to a line there, whose own height says nothing: the slack comes
        // from the footprint's height before the cut, and the contact may lie from the top of the part the frame shows down
        // to the bottom row, where the frame cuts the piece off.
        let footprintYs = [projectedBox[2], projectedBox[3], projectedBox[6], projectedBox[7]].map(\.y)
        let footprintHeightBeforeClamping = (footprintYs.max() ?? 0) - (footprintYs.min() ?? 0)
        guard floorContactLandsOnTheFootprint(floorContact, footprint: footprintInTheFrame, footprintHeightBeforeClamping: footprintHeightBeforeClamping) else {
            return (nil, paintedHeightRatio, paintedRowSpan)
        }

        let itemLayer = paintedImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: frameRectangle)
        guard let itemLayerImage = ciContext.createCGImage(itemLayer, from: frameRectangle, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()) else {
            return (nil, paintedHeightRatio, paintedRowSpan)
        }
        let layers = RoomFurnitureKeyframeLayers(
            itemLayer: itemLayerImage,
            // The painting holds its own shadow.
            shadowLayer: nil,
            basePointInTheKeyframe: CGPoint(x: (projectedBox[2].x + projectedBox[3].x) / 2, y: max(projectedBox[2].y, projectedBox[3].y)),
            // The painting carries the photo's own look.
            cameraNoiseStandardDeviation: 0,
            look: .paintedComposite
        )
        return (layers, paintedHeightRatio, paintedRowSpan)
    }

    /// Whether a floor contact point, in y-down keyframe pixels, lies on the footprint's bounding box grown by
    /// `floorContactSlackShare` of its size on each side. `footprint` is what the frame shows of it. When the frame cuts the
    /// footprint off at its bottom row, the cut footprint is a few rows tall or none, and 15 percent of that is a fraction of
    /// a row, so `footprintHeightBeforeClamping` gives the height the slack is taken from. The contact may then lie from the
    /// visible footprint's top, less that slack, down to the bottom row.
    static func floorContactLandsOnTheFootprint(_ floorContact: CGPoint, footprint: [CGPoint], footprintHeightBeforeClamping: Double? = nil) -> Bool {
        guard let left = footprint.map(\.x).min(), let right = footprint.map(\.x).max(),
              let top = footprint.map(\.y).min(), let bottom = footprint.map(\.y).max() else { return false }
        let footprintHeight = footprintHeightBeforeClamping ?? (bottom - top)
        let horizontalSlack = (right - left) * floorContactSlackShare, verticalSlack = max(footprintHeight, 1) * floorContactSlackShare
        return floorContact.x >= left - horizontalSlack && floorContact.x <= right + horizontalSlack
            && floorContact.y >= top - verticalSlack && floorContact.y <= bottom + verticalSlack
    }

    /// The rows from the highest to the lowest where the painting changed enough of the pasted region's pixels in that row
    /// (`shareOfARowThatMustChange`, `fewestChangedPixelsInARow`), in y-down keyframe rows, and the share of the region's
    /// top `pixelsAlongTheRegionsTop` pixels that changed, and the mean column of the changed pixels in the lowest painted
    /// row, where the piece meets the floor, or nil when no row did.
    ///
    /// Rows below the box's lowest corner (`lowestItemRow`) never count. The piece stands on the floor at that row, and below
    /// it the pasted region holds only the painted shadow and the floor the service drew again. Counting them ran the item
    /// down to the region's bottom, 40 to 50 rows below its feet, and measured a Blu Dot chair painted at 103 percent of its
    /// box as 121 percent and refused it (2026-11-22, room-floor.mp4).
    private static func rowsThePaintingChanged(
        painted: CIImage, keyframe: CIImage, mask: CIImage, frameRectangle: CGRect, lowestItemRow: Int, ciContext: CIContext
    ) -> (paintedRows: ClosedRange<Int>, shareChangedAlongTheRegionsTop: Double, lowestRowMiddleColumn: Double)? {
        let width = Int(frameRectangle.width), height = Int(frameRectangle.height)
        let difference = painted.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: keyframe])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        var differenceBytes = [UInt8](repeating: 0, count: width * height)
        var maskBytes = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        ciContext.render(difference, toBitmap: &differenceBytes, rowBytes: width, bounds: frameRectangle, format: .L8, colorSpace: gray)
        ciContext.render(mask.cropped(to: frameRectangle), toBitmap: &maskBytes, rowBytes: width, bounds: frameRectangle, format: .L8, colorSpace: gray)
        let changeThreshold = UInt8(paintedLuminanceChange * 255)
        var firstPaintedRow: Int?, lastPaintedRow: Int?
        var lastPaintedRowColumnTotal = 0, lastPaintedRowColumnCount = 0
        var regionTopPixels = 0, regionTopPixelsChanged = 0
        // Row 0 of the rendered bytes is the frame's top row, as y-down keyframe pixels count.
        for row in 0..<min(height, lowestItemRow + 1) {
            var maskPixels = 0, changedPixels = 0, changedColumnTotal = 0
            for column in 0..<width where maskBytes[row * width + column] > 127 {
                maskPixels += 1
                if differenceBytes[row * width + column] > changeThreshold {
                    changedPixels += 1
                    changedColumnTotal += column
                }
            }
            if maskPixels > 0, regionTopPixels < pixelsAlongTheRegionsTop {
                regionTopPixels += maskPixels
                regionTopPixelsChanged += changedPixels
            }
            guard maskPixels > 0, changedPixels >= max(fewestChangedPixelsInARow, Int((Double(maskPixels) * shareOfARowThatMustChange).rounded(.up))) else { continue }
            firstPaintedRow = firstPaintedRow ?? row
            lastPaintedRow = row
            lastPaintedRowColumnTotal = changedColumnTotal
            lastPaintedRowColumnCount = changedPixels
        }
        guard let firstPaintedRow, let lastPaintedRow, regionTopPixels > 0, lastPaintedRowColumnCount > 0 else { return nil }
        return (firstPaintedRow...lastPaintedRow, Double(regionTopPixelsChanged) / Double(regionTopPixels), Double(lastPaintedRowColumnTotal) / Double(lastPaintedRowColumnCount))
    }
}

/// Where the painted rows sit against the measured box, in y-down keyframe pixels, for the log: the painted item's top
/// and bottom, the box outline's, and the front face's.
nonisolated func roomFurniturePaintedRowsAgainstTheBox(_ paintedRows: ClosedRange<Int>, _ projectedBox: [CGPoint]) -> String {
    let outlineRows = projectedBox.map(\.y), frontRows = projectedBox.prefix(4).map(\.y)
    return String(
        format: "painted rows %d to %d, box outline %.0f to %.0f, front face %.0f to %.0f",
        paintedRows.lowerBound, paintedRows.upperBound,
        outlineRows.min() ?? 0, outlineRows.max() ?? 0, frontRows.min() ?? 0, frontRows.max() ?? 0
    )
}

/// The painted composite's mask (white where the service may paint, in y-down keyframe pixels): the projected outline of
/// the item's box, and its floor footprint grown by `shadowMarginPixels` for the contact shadow. The margin is only along
/// the floor and never above the box's top row. `furnitureCompositeMaskPNG` grows the whole outline, and on the live
/// check (2026-11-22, room-floor.mp4) the service filled that margin above the box: it painted a LACK side table's top 32
/// pixels above the box, 111 percent of its height. `projectedBox` is the front face's corners (top left, top right,
/// bottom right, bottom left) and then the back face's, as `FloorPlane.keyframeBoxCorners` gives them.
nonisolated func roomFurnitureCompositeMaskPNG(projectedBox: [CGPoint], frameWidth: Int, frameHeight: Int, shadowMarginPixels: Double) -> Data? {
    guard projectedBox.count == 8, shadowMarginPixels.isFinite, shadowMarginPixels >= 0,
          projectedBox.allSatisfy({ corner in corner.x.isFinite && corner.y.isFinite }) else { return nil }
    let outline = convexHull(of: projectedBox)
    let footprint = convexHull(of: [projectedBox[2], projectedBox[3], projectedBox[6], projectedBox[7]])
    guard outline.count >= 3, footprint.count >= 3,
          let context = CGContext(data: nil, width: frameWidth, height: frameHeight, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    // The corners have y growing down, and a bitmap context's y grows up.
    context.translateBy(x: 0, y: CGFloat(frameHeight))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(gray: 1, alpha: 1)
    context.addLines(between: outline)
    context.closePath()
    context.fillPath()
    // Nothing the margin adds may rise above the box's top row.
    let boxTopRow = projectedBox.map(\.y).min() ?? 0
    context.clip(to: CGRect(x: 0, y: boxTopRow, width: CGFloat(frameWidth), height: CGFloat(frameHeight) - boxTopRow))
    // A filled footprint with a round-joined stroke of twice the margin is the footprint grown by the margin.
    context.addLines(between: footprint)
    context.closePath()
    context.fillPath()
    if shadowMarginPixels > 0 {
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(CGFloat(shadowMarginPixels * 2))
        context.setLineJoin(.round)
        context.addLines(between: footprint)
        context.closePath()
        context.strokePath()
    }
    guard let maskImage = context.makeImage() else { return nil }
    let pngData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, maskImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return pngData as Data
}

/// Whether a painting request that failed may succeed when asked for again: not for a service with no key (503), a wrong
/// app secret (401), or a request the Worker refused (400), which fail the same way every time. Not after the app's own
/// request timeout (`RoomFurnitureGenerationClient.timeoutSeconds`, 150 seconds) either: a second request would take as long,
/// and with no render to show the learner would watch "Arranging it in your room…" for about 5 minutes. A 502 or a 504 from
/// the Worker arrives sooner, and a request that stopped for another network reason fails fast, so those are asked again.
nonisolated func roomFurniturePaintingIsWorthAskingForAgain(after error: Error) -> Bool {
    switch error {
    case RoomFurnitureGenerationError.serviceIsNotSetUp: return false
    case RoomFurnitureGenerationError.workerReturned(let statusCode, _): return statusCode != 400 && statusCode != 401
    case RoomFurnitureGenerationError.inputCouldNotBeRead: return false
    case let urlError as URLError: return urlError.code != .timedOut
    default: return true
    }
}

/// How long furniture with no look yet waits before its fallback shows (the model's render, and only with no request in
/// flight the could-not-draw line). It is counted twice: from the moment a painting request goes out for the placement, which
/// leaves out the time the learner spends out of the way (`aClearFrameForThePainting`), and from the placement itself, since
/// that time has no limit of its own and no request goes out at all while a learner covers the box. A painting takes 15 to
/// 20 seconds, and a second painting after a refused one about as long again.
nonisolated let roomFurnitureSecondsToWaitForALook = 45.0

/// Where furniture's model render stands for one placement: still being made (or the model search still runs), ready, or
/// not coming, since there is no model or it did not render.
nonisolated enum RoomFurnitureRenderState: Equatable, Sendable {
    case coming
    case ready
    case none
}

/// What furniture still being arranged shows while its painting has not arrived.
nonisolated enum RoomFurnitureFallbackStep: Equatable, Sendable {
    /// The loop and "Arranging it in your room…" stay.
    case keepWaiting
    case showTheRender
    /// Nothing is drawn, since the flat cutout reads as a sticker: the loop stays and Clicky says it could not draw the
    /// piece (`roomFurnitureNotDrawnLine`).
    case sayItCouldNotBeDrawn
}

/// What Clicky says, as a failure, when furniture's painting did not come and its model has no render.
nonisolated let roomFurnitureNotDrawnLine = "I couldn't draw it this time. Click the floor to try again."

/// The painting is the only first look, so the fallback waits for it until it cannot come (the service is not set up,
/// two paintings were refused, or the request failed) or a wait runs out (`roomFurnitureSecondsToWaitForALook`): the wait
/// counted from the painting request going out (`theWaitRanOut`), or from the placement (`thePlacementWaitRanOut`). The
/// fallback is the model's render when one is ready, else no piece at all and a line that says so. A painting that cannot
/// come waits for a render still being made, which takes under a second, and a wait that ran out takes whatever is ready.
///
/// A painting request still in flight is never given up on for want of a render: the request's own timeout ends it, and
/// saying "I couldn't draw it" while it is on its way sent the learner to click the floor, which cancelled the painting
/// about to arrive. Only a ready render shows when a wait ran out under a request in flight.
///
/// The placement's wait covers a placement whose request has not gone out, such as a learner covering the box who is asked
/// to step aside: a ready render shows then, and the line that the piece could not be drawn comes only once the model search
/// has ended with no render (`.none`), since a render still coming may show. The request's wait, which only a request
/// that went out starts, says it with a render still coming too.
nonisolated func roomFurnitureFallbackStep(
    paintingCannotCome: Bool, theWaitRanOut: Bool, thePlacementWaitRanOut: Bool, aPaintingRequestIsInFlight: Bool, render: RoomFurnitureRenderState
) -> RoomFurnitureFallbackStep {
    guard paintingCannotCome || theWaitRanOut || thePlacementWaitRanOut else { return .keepWaiting }
    switch render {
    case .ready: return .showTheRender
    case .none: return aPaintingRequestIsInFlight ? .keepWaiting : .sayItCouldNotBeDrawn
    case .coming: return theWaitRanOut && !aPaintingRequestIsInFlight ? .sayItCouldNotBeDrawn : .keepWaiting
    }
}
