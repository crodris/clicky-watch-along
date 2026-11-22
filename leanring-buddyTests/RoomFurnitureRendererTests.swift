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
