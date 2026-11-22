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

/// What the generation service does for the furniture: a model from the product photo, and the item painted into the
/// keyframe inside a mask. Either throws when the service is not set up (the Worker answers 503 without its key) or fails,
/// and the furniture then falls back to the next look.
protocol RoomFurnitureGenerating {
    /// GLB bytes of a model of the product in the photo.
    func generateAModel(productJPEG: Data, itemTitle: String) async throws -> Data
    /// The keyframe with the item painted in where the mask is white, at the keyframe's size.
    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data,
        keyframeWidth: Int,
        keyframeHeight: Int,
        productJPEG: Data,
        maskPNG: Data,
        itemTitle: String,
        itemSizeWords: String
    ) async throws -> CGImage
}

extension RoomFurnitureGenerationClient: RoomFurnitureGenerating {}

/// The generation service when none is wired in, which the controller's tests start from: every request says the service
/// is not set up, as the Worker's 503 does, and the furniture keeps the looks it has.
struct RoomFurnitureGenerationNotSetUp: RoomFurnitureGenerating {
    func generateAModel(productJPEG: Data, itemTitle: String) async throws -> Data {
        throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: "")
    }

    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data, keyframeWidth: Int, keyframeHeight: Int, productJPEG: Data, maskPNG: Data, itemTitle: String, itemSizeWords: String
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
    /// A painting that changed at least this share of the pasted region's top `rowsAlongTheRegionsTop` rows reached past
    /// the region and was cut off by the paste. On the live check the service's redrawn wall changed about 20 percent of
    /// them above a Blu Dot chair and none above a LACK side table, while a piece cut off there fills the region's top.
    static let mostOfTheRegionsTopThatMayChange = 0.5
    static let rowsAlongTheRegionsTop = 4

    /// The painted item as keyframe layers, or nil when the painting is not the keyframe's size, the mask does not read, the
    /// painted item is shorter than the box's front face or taller than its outline, each by more than
    /// `mostHeightDifference`, or the item reached past the pasted region's top, where the paste cut it off. Also returns the painted height as a share of the box's outline and the painted rows' span
    /// (top and bottom in y-down keyframe pixels) for the log, each nil when nothing was painted.
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
        let boxOutlineHeight = (projectedBox.map(\.y).max() ?? 0) - (projectedBox.map(\.y).min() ?? 0)
        let frontFace = projectedBox.prefix(4)
        let frontFaceHeight = (frontFace.map(\.y).max() ?? 0) - (frontFace.map(\.y).min() ?? 0)
        let lowestItemRow = Int((projectedBox.map(\.y).max() ?? 0).rounded(.up))
        guard let (paintedRowSpan, shareChangedAlongTheRegionsTop) = rowsThePaintingChanged(
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

    /// The rows from the highest to the lowest where the painting changed enough of the pasted region's pixels in that row
    /// (`shareOfARowThatMustChange`, `fewestChangedPixelsInARow`), in y-down keyframe rows, and the share of the region's
    /// pixels that changed in its top `rowsAlongTheRegionsTop` rows, or nil when no row did.
    ///
    /// Rows below the box's lowest corner (`lowestItemRow`) never count. The piece stands on the floor at that row, and below
    /// it the pasted region holds only the painted shadow and the floor the service drew again. Counting them ran the item
    /// down to the region's bottom, 40 to 50 rows below its feet, and measured a Blu Dot chair painted at 103 percent of its
    /// box as 121 percent and refused it (2026-11-22, room-floor.mp4).
    private static func rowsThePaintingChanged(
        painted: CIImage, keyframe: CIImage, mask: CIImage, frameRectangle: CGRect, lowestItemRow: Int, ciContext: CIContext
    ) -> (paintedRows: ClosedRange<Int>, shareChangedAlongTheRegionsTop: Double)? {
        let width = Int(frameRectangle.width), height = Int(frameRectangle.height)
        let difference = painted.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: keyframe])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        var differenceBytes = [UInt8](repeating: 0, count: width * height)
        var maskBytes = [UInt8](repeating: 0, count: width * height)
        let gray = CGColorSpaceCreateDeviceGray()
        ciContext.render(difference, toBitmap: &differenceBytes, rowBytes: width, bounds: frameRectangle, format: .L8, colorSpace: gray)
        ciContext.render(mask.cropped(to: frameRectangle), toBitmap: &maskBytes, rowBytes: width, bounds: frameRectangle, format: .L8, colorSpace: gray)
        let changeThreshold = UInt8(paintedLuminanceChange * 255)
        var firstPaintedRow: Int?, lastPaintedRow: Int?, firstRowOfTheRegion: Int?
        var regionTopPixels = 0, regionTopPixelsChanged = 0
        // Row 0 of the rendered bytes is the frame's top row, as y-down keyframe pixels count.
        for row in 0..<min(height, lowestItemRow + 1) {
            var maskPixels = 0, changedPixels = 0
            for column in 0..<width where maskBytes[row * width + column] > 127 {
                maskPixels += 1
                if differenceBytes[row * width + column] > changeThreshold { changedPixels += 1 }
            }
            if maskPixels > 0 { firstRowOfTheRegion = firstRowOfTheRegion ?? row }
            if let firstRowOfTheRegion, row - firstRowOfTheRegion < rowsAlongTheRegionsTop {
                regionTopPixels += maskPixels
                regionTopPixelsChanged += changedPixels
            }
            guard maskPixels > 0, changedPixels >= max(fewestChangedPixelsInARow, Int((Double(maskPixels) * shareOfARowThatMustChange).rounded(.up))) else { continue }
            firstPaintedRow = firstPaintedRow ?? row
            lastPaintedRow = row
        }
        guard let firstPaintedRow, let lastPaintedRow, regionTopPixels > 0 else { return nil }
        return (firstPaintedRow...lastPaintedRow, Double(regionTopPixelsChanged) / Double(regionTopPixels))
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
/// app secret (401), or a request the Worker refused (400), which fail the same way every time.
nonisolated func roomFurniturePaintingIsWorthAskingForAgain(after error: Error) -> Bool {
    switch error {
    case RoomFurnitureGenerationError.serviceIsNotSetUp: return false
    case RoomFurnitureGenerationError.workerReturned(let statusCode, _): return statusCode != 400 && statusCode != 401
    case RoomFurnitureGenerationError.inputCouldNotBeRead: return false
    default: return true
    }
}
