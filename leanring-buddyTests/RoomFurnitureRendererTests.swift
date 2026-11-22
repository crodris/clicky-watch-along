//
//  RoomFurnitureRendererTests.swift
//  leanring-buddyTests
//
//  Renders a plain box model on a made-up room and reads the layers' pixels: the render is clear around the item and
//  opaque on it, lands where the pinhole puts the box, and its shadow darkens the floor in front of it and fades out.
//  These need a Metal device, which every Mac this runs on has.
//

import AppKit
import CoreGraphics
import Foundation
import Metal
import SceneKit
import Testing
import simd
@testable import Clicky

private let aMetalDeviceExists = MTLCreateSystemDefaultDevice() != nil

/// RGBA8 pixels of an image, premultiplied, rows from the top.
struct RoomFurnitureTestPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var pixelBytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixelBytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = pixelBytes
    }

    func alpha(atColumn column: Int, row: Int) -> UInt8 { bytes[(row * width + column) * 4 + 3] }

    /// The box around every pixel whose alpha is over half, or nil.
    func boxAroundOpaquePixels() -> CGRect? {
        var left = width, right = -1, top = height, bottom = -1
        for row in 0..<height {
            for column in 0..<width where alpha(atColumn: column, row: row) > 127 {
                left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
            }
        }
        guard right >= left else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }
}

/// A wall over a darker floor, 1280 by 720, so the light and the noise have something to measure.
func roomFurnitureTestKeyframe(width: Int = 1280, height: Int = 720) -> CGImage? {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    // Core Graphics' y grows up, so the floor is the bottom 40 percent.
    context?.setFillColor(CGColor(srgbRed: 0.86, green: 0.85, blue: 0.82, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context?.setFillColor(CGColor(srgbRed: 0.3, green: 0.24, blue: 0.2, alpha: 1))
    context?.fill(CGRect(x: 0, y: 0, width: width, height: Int(Double(height) * 0.4)))
    return context?.makeImage()
}

/// A plain white box model, y up, in meters, centered on its own origin, as a GLB's root node would hold it.
func roomFurnitureTestBoxModel(width: Double, height: Double, depth: Double) -> SCNNode {
    let box = SCNBox(width: width, height: height, length: depth, chamferRadius: 0)
    let whiteMaterial = SCNMaterial()
    whiteMaterial.lightingModel = .physicallyBased
    whiteMaterial.diffuse.contents = NSColor(white: 0.95, alpha: 1)
    whiteMaterial.roughness.contents = 0.8
    whiteMaterial.metalness.contents = 0.0
    box.materials = [whiteMaterial]
    let rootNode = SCNNode()
    rootNode.addChildNode(SCNNode(geometry: box))
    return rootNode
}

struct RoomFurnitureRendererTests {
    private let floor: FloorPlane = {
        let up = simd_normalize(SIMD3<Double>(0, -0.96, -0.28))
        let right = SIMD3<Double>(1, 0, 0)
        return FloorPlane(center: SIMD3(0.3, 0.8, 2.8), right: right, up: up, forward: simd_cross(up, right),
                          focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 2.6, floorTiltDegrees: 16, planeInlierShare: 1)
    }()

    private func renderTheBox(width: Double, height: Double, depth: Double) throws -> (RoomFurnitureKeyframeLayers, [CGPoint]) {
        let placement = try #require(RoomFurniturePlacement(floor: floor, widthMeters: width, heightMeters: height, depthMeters: depth))
        let request = RoomFurnitureRenderRequest(
            modelRootNode: roomFurnitureTestBoxModel(width: width, height: height, depth: depth),
            placement: placement,
            focalLengthPixels: floor.focalLengthPixels,
            principalPoint: floor.principalPoint,
            keyframeImage: try #require(roomFurnitureTestKeyframe()),
            look: .storeModel
        )
        let rendered = try #require(RoomFurnitureRenderer().render(request))
        let projectedBox = try #require(floor.keyframeBoxCorners(widthMeters: width, heightMeters: height, depthMeters: depth))
        return (rendered.layers, projectedBox)
    }

    @Test(.enabled(if: aMetalDeviceExists))
    func theRenderIsClearAroundTheItemAndOpaqueOnIt() throws {
        let (layers, projectedBox) = try renderTheBox(width: 0.9, height: 0.5, depth: 0.4)
        let pixels = RoomFurnitureTestPixels(layers.itemLayer)
        #expect(pixels.width == 1280 && pixels.height == 720)
        for (column, row) in [(0, 0), (1279, 0), (0, 719), (1279, 719)] {
            #expect(pixels.alpha(atColumn: column, row: row) == 0)
        }
        let frontFaceMiddle = CGPoint(
            x: projectedBox.prefix(4).map(\.x).reduce(0, +) / 4,
            y: projectedBox.prefix(4).map(\.y).reduce(0, +) / 4
        )
        #expect(pixels.alpha(atColumn: Int(frontFaceMiddle.x), row: Int(frontFaceMiddle.y)) == 255)
    }

    /// The render of an asymmetric box covers exactly the outline the pinhole projects, so SceneKit's camera is the
    /// keyframe camera to within a pixel or so of antialiasing and the camera blur.
    @Test(.enabled(if: aMetalDeviceExists))
    func theRenderLandsWhereThePinholeProjectsTheBox() throws {
        let (layers, projectedBox) = try renderTheBox(width: 1.3, height: 0.45, depth: 0.35)
        let renderedBox = try #require(RoomFurnitureTestPixels(layers.itemLayer).boxAroundOpaquePixels())
        let projectedLeft = projectedBox.map(\.x).min() ?? 0, projectedRight = projectedBox.map(\.x).max() ?? 0
        let projectedTop = projectedBox.map(\.y).min() ?? 0, projectedBottom = projectedBox.map(\.y).max() ?? 0
        #expect(abs(renderedBox.minX - projectedLeft) < 1.5)
        #expect(abs(renderedBox.maxX - projectedRight) < 1.5)
        #expect(abs(renderedBox.minY - projectedTop) < 1.5)
        #expect(abs(renderedBox.maxY - projectedBottom) < 1.5)
    }

    @Test(.enabled(if: aMetalDeviceExists))
    func theShadowDarkensTheFloorInFrontAndFadesOutward() throws {
        let (layers, projectedBox) = try renderTheBox(width: 0.9, height: 0.5, depth: 0.4)
        let shadowPixels = RoomFurnitureTestPixels(try #require(layers.shadowLayer))
        let frontBottomMiddle = CGPoint(x: (projectedBox[2].x + projectedBox[3].x) / 2, y: (projectedBox[2].y + projectedBox[3].y) / 2)
        let justInFront = Int(shadowPixels.alpha(atColumn: Int(frontBottomMiddle.x), row: Int(frontBottomMiddle.y) + 3))
        let fartherOut = Int(shadowPixels.alpha(atColumn: Int(frontBottomMiddle.x), row: Int(frontBottomMiddle.y) + 40))
        #expect(justInFront > 40)
        #expect(fartherOut < justInFront)
        #expect(shadowPixels.alpha(atColumn: 5, row: 5) == 0)
        #expect(abs(layers.basePointInTheKeyframe.y - max(projectedBox[2].y, projectedBox[3].y)) < 1e-6)
        #expect(abs(layers.basePointInTheKeyframe.x - frontBottomMiddle.x) < 1e-6)
    }
}

/// The painted composite's layer: kept when the painted item stands at the measured box's height, refused when it does not.
struct RoomFurniturePaintedCompositeTests {
    /// A box whose projected outline spans rows 300 to 500, between columns 500 and 700.
    private let projectedBox = [
        CGPoint(x: 500, y: 300), CGPoint(x: 700, y: 300), CGPoint(x: 700, y: 500), CGPoint(x: 500, y: 500),
        CGPoint(x: 520, y: 310), CGPoint(x: 680, y: 310), CGPoint(x: 680, y: 480), CGPoint(x: 520, y: 480),
    ]

    /// The keyframe with a white item painted from `topRow` to row 500, the base the box stands on.
    private func painting(topRow: Int, over keyframe: CGImage) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: keyframe.width, height: keyframe.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(keyframe, in: CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        // Core Graphics' y grows up from the bottom.
        context.fill(CGRect(x: 520, y: keyframe.height - 500, width: 160, height: 500 - topRow))
        return try #require(context.makeImage())
    }

    private func layers(paintedFromRow topRow: Int) throws -> (layers: RoomFurnitureKeyframeLayers?, paintedHeightRatio: Double?, paintedRows: ClosedRange<Int>?) {
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: projectedBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        return RoomFurniturePaintedComposite.itemLayers(painted: try painting(topRow: topRow, over: keyframe), keyframe: keyframe, maskPNG: maskPNG, projectedBox: projectedBox)
    }

    @Test func aPaintingAtTheMeasuredHeightIsKeptAsTheItemLayer() throws {
        let result = try layers(paintedFromRow: 310)
        let paintedHeightRatio = try #require(result.paintedHeightRatio)
        #expect(abs(paintedHeightRatio - 0.955) < 0.03)
        let itemLayer = try #require(result.layers?.itemLayer)
        let pixels = RoomFurnitureTestPixels(itemLayer)
        // Opaque on the painted item, clear far outside the pasted region.
        #expect(pixels.alpha(atColumn: 600, row: 400) == 255)
        #expect(pixels.alpha(atColumn: 100, row: 100) == 0)
        #expect(result.layers?.look == .paintedComposite)
    }

    @Test func aTableOnThinLegsIsMeasuredToTheFootOfItsLegs() throws {
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let context = try #require(CGContext(data: nil, width: keyframe.width, height: keyframe.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(keyframe, in: CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        // A top from row 300 to 330 and two legs 8 pixels wide down to row 500, in Core Graphics' y-up coordinates.
        context.fill(CGRect(x: 510, y: keyframe.height - 330, width: 180, height: 30))
        context.fill(CGRect(x: 512, y: keyframe.height - 500, width: 8, height: 170))
        context.fill(CGRect(x: 680, y: keyframe.height - 500, width: 8, height: 170))
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: projectedBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        let result = RoomFurniturePaintedComposite.itemLayers(painted: try #require(context.makeImage()), keyframe: keyframe, maskPNG: maskPNG, projectedBox: projectedBox)
        #expect(abs((result.paintedHeightRatio ?? 0) - 1) < 0.03)
        #expect(result.layers != nil)
    }

    /// A chair's box: its front face spans rows 400 to 500 and its back face rows 300 to 460, so its outline is twice as
    /// tall as its front, as a deep chair's is.
    private let chairBox = [
        CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 400), CGPoint(x: 700, y: 500), CGPoint(x: 500, y: 500),
        CGPoint(x: 520, y: 300), CGPoint(x: 680, y: 300), CGPoint(x: 680, y: 460), CGPoint(x: 520, y: 460),
    ]

    private func chairLayers(paintedFromRow topRow: Int) throws -> RoomFurnitureKeyframeLayers? {
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: chairBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        return RoomFurniturePaintedComposite.itemLayers(painted: try painting(topRow: topRow, over: keyframe), keyframe: keyframe, maskPNG: maskPNG, projectedBox: chairBox).layers
    }

    @Test func aChairShorterThanItsBoxsOutlineButTallerThanItsFrontIsKept() throws {
        // 140 rows: 70 percent of the outline, which an outline-only check refused, and well over the 100 row front.
        #expect(try chairLayers(paintedFromRow: 360) != nil)
    }

    @Test func aPaintingShorterThanTheBoxsFrontIsRefused() throws {
        // 80 rows, under 85 percent of the 100 row front.
        #expect(try chairLayers(paintedFromRow: 420) == nil)
    }

    /// The test painting with one more filled band, `color` from `topRow` to `bottomRow` between columns 460 and 740.
    private func painting(topRow: Int, over keyframe: CGImage, andBandFromRow bandTopRow: Int, toRow bandBottomRow: Int, color: CGColor) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: keyframe.width, height: keyframe.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try painting(topRow: topRow, over: keyframe), in: CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height))
        context.setFillColor(color)
        context.fill(CGRect(x: 460, y: keyframe.height - bandBottomRow, width: 280, height: bandBottomRow - bandTopRow))
        return try #require(context.makeImage())
    }

    @Test func theShadowAndFloorPaintedBelowTheBoxDoNotCountAsTheItem() throws {
        // The live check's paintings darkened the floor for 40 to 50 rows under the piece's feet, inside the pasted region.
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: projectedBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        let painted = try painting(topRow: 310, over: keyframe, andBandFromRow: 500, toRow: 548, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        let result = RoomFurniturePaintedComposite.itemLayers(painted: painted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: projectedBox)
        #expect(result.paintedRows == 310...500)
        #expect(result.layers != nil)
    }

    @Test func theMaskGrowsOnlyAlongTheFloorAndNeverAboveTheBox() throws {
        // A low, wide table seen from above: its top is row 370, and its floor footprint's back edge is row 380, so the
        // footprint grown by 24 rows would reach row 356, above the box.
        let lowTableBox = [
            CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 400), CGPoint(x: 700, y: 420), CGPoint(x: 500, y: 420),
            CGPoint(x: 530, y: 370), CGPoint(x: 670, y: 370), CGPoint(x: 670, y: 380), CGPoint(x: 530, y: 380),
        ]
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: lowTableBox, frameWidth: 1280, frameHeight: 720, shadowMarginPixels: 24))
        let maskSource = try #require(CGImageSourceCreateWithData(maskPNG as CFData, nil))
        let mask = RoomFurnitureTestPixels(try #require(CGImageSourceCreateImageAtIndex(maskSource, 0, nil)))
        func isWhite(_ column: Int, _ row: Int) -> Bool { mask.bytes[(row * mask.width + column) * 4] > 127 }
        // Inside the box, and the shadow margin below and beside the floor footprint.
        #expect(isWhite(600, 410))
        #expect(isWhite(600, 440))
        #expect(isWhite(480, 418))
        #expect(!isWhite(600, 450))
        // Beside the box above the floor, 22 pixels left of its front top corner and 30 from its footprint.
        #expect(!isWhite(478, 400))
        // Nothing above the box's top row, where the whole outline's margin would reach.
        #expect(!isWhite(600, 362))
        #expect(!isWhite(600, 350))
    }

    @Test func aWallRedrawnOverPartOfThePastedRegionsTopIsKept() throws {
        // The live check's Blu Dot painting changed about 20 percent of the region's top rows above the chair. Here a dark
        // patch covers 50 of the region's 200 or so columns at its top, and the item stands at its measured height.
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: projectedBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        let context = try #require(CGContext(data: nil, width: keyframe.width, height: keyframe.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(try painting(topRow: 310, over: keyframe), in: CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 560, y: keyframe.height - 292, width: 50, height: 22))
        let result = RoomFurniturePaintedComposite.itemLayers(painted: try #require(context.makeImage()), keyframe: keyframe, maskPNG: maskPNG, projectedBox: projectedBox)
        #expect(result.layers != nil)
    }

    @Test func aPaintingCutOffAlongThePastedRegionsTopIsRefused() throws {
        // A painted item from row 220 is 1.4 times the box's 200 rows. The client pasted nothing above the region, which
        // starts 24 rows above the box, so the measured height is only 1.125 times, and the cut along the top refuses it.
        let result = try layers(paintedFromRow: 220)
        #expect(result.paintedRows?.lowerBound ?? 0 > 260)
        #expect((result.paintedHeightRatio ?? 0) < 1 + RoomFurniturePaintedComposite.mostHeightDifference)
        #expect(result.layers == nil)
    }

    @Test func aPaintingTallerThanASmallBoxIsRefused() throws {
        // A box 100 rows tall, from 400 to 500: an item painted from row 380 is 1.2 times it, inside the pasted region.
        let smallBox = [
            CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 400), CGPoint(x: 700, y: 500), CGPoint(x: 500, y: 500),
            CGPoint(x: 520, y: 405), CGPoint(x: 680, y: 405), CGPoint(x: 680, y: 490), CGPoint(x: 520, y: 490),
        ]
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: smallBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        let result = RoomFurniturePaintedComposite.itemLayers(painted: try painting(topRow: 380, over: keyframe), keyframe: keyframe, maskPNG: maskPNG, projectedBox: smallBox)
        #expect((result.paintedHeightRatio ?? 0) > 1 + RoomFurniturePaintedComposite.mostHeightDifference)
        #expect(result.layers == nil)
    }
}
