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
    /// The painted item's height may differ from the measured box's projected height by at most this share; a painting the
    /// model drew at the wrong size is worse than the flat cutout at the right one.
    static let mostHeightDifference = 0.15
    /// A pixel counts as painted when its luminance changed by more than this, which a shadow on a dark floor seldom does,
    /// so the painted shadow does not stretch the item's height.
    static let paintedLuminanceChange = 0.08

    /// The painted item as keyframe layers, or nil when the painting is not the keyframe's size, the mask does not read, or
    /// the painted item is off the projected height by more than `mostHeightDifference`. Also returns the measured height
    /// ratio for the log, nil when nothing was painted.
    static func itemLayers(
        painted: CGImage,
        keyframe: CGImage,
        maskPNG: Data,
        projectedBox: [CGPoint],
        ciContext: CIContext = CIContext()
    ) -> (layers: RoomFurnitureKeyframeLayers?, paintedHeightRatio: Double?) {
        guard painted.width == keyframe.width, painted.height == keyframe.height, projectedBox.count == 8,
              let maskSource = CGImageSourceCreateWithData(maskPNG as CFData, nil),
              let maskImage = CGImageSourceCreateImageAtIndex(maskSource, 0, nil) else { return (nil, nil) }
        let frameRectangle = CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height)
        let paintedImage = CIImage(cgImage: painted)
        // The client pasted its painting inside the mask grown by its slack, with its feather, and left the rest of the
        // keyframe as filmed, so the same grown mask is the item layer's alpha and the region where the painting is measured.
        guard let pastedRegion = grownMaskImage(
            maskImage, frameExtent: frameRectangle, radiusPixels: furnitureCompositePasteSlackPixels,
            blurPixels: furnitureCompositePasteFeatherPixels, context: ciContext
        ) else { return (nil, nil) }
        let mask = CIImage(cgImage: pastedRegion)

        let paintedHeightRatio = paintedHeight(painted: paintedImage, keyframe: CIImage(cgImage: keyframe), mask: mask, frameRectangle: frameRectangle, ciContext: ciContext)
            .map { paintedRows in
                let projectedHeight = (projectedBox.map(\.y).max() ?? 0) - (projectedBox.map(\.y).min() ?? 0)
                return paintedRows / max(projectedHeight, 1)
            }
        guard let paintedHeightRatio, abs(paintedHeightRatio - 1) <= mostHeightDifference else { return (nil, paintedHeightRatio) }

        let itemLayer = paintedImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: frameRectangle)
        guard let itemLayerImage = ciContext.createCGImage(itemLayer, from: frameRectangle, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()) else {
            return (nil, paintedHeightRatio)
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
        return (layers, paintedHeightRatio)
    }

    /// The number of rows between the highest and the lowest row where the painting changed at least 3 percent of the mask's
    /// pixels in that row, or nil when no row did.
    private static func paintedHeight(painted: CIImage, keyframe: CIImage, mask: CIImage, frameRectangle: CGRect, ciContext: CIContext) -> Double? {
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
        // Core Image renders the bottom row first, so row 0 of the bytes is the frame's bottom; only the span matters.
        for row in 0..<height {
            var maskPixels = 0, changedPixels = 0
            for column in 0..<width where maskBytes[row * width + column] > 127 {
                maskPixels += 1
                if differenceBytes[row * width + column] > changeThreshold { changedPixels += 1 }
            }
            guard maskPixels > 0, Double(changedPixels) >= Double(maskPixels) * 0.03 else { continue }
            firstPaintedRow = firstPaintedRow ?? row
            lastPaintedRow = row
        }
        guard let firstPaintedRow, let lastPaintedRow else { return nil }
        return Double(lastPaintedRow - firstPaintedRow + 1)
    }
}
