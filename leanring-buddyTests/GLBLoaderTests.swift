//
//  GLBLoaderTests.swift
//  leanring-buddyTests
//
//  The GLB loader on small GLB files built here, one behavior each, and on a real file when ROOM_FURNITURE_GLB names one.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import SceneKit
import Testing
import simd
@testable import Clicky

// MARK: - Building GLB files

/// A GLB under construction: the glTF JSON as a dictionary a test can change, and the BIN chunk.
private struct SyntheticGLB {
    var json: [String: Any] = ["asset": ["version": "2.0"]]
    var binary = Data()

    @discardableResult
    mutating func appendEntry(_ entry: [String: Any], to key: String) -> Int {
        var entries = json[key] as? [[String: Any]] ?? []
        entries.append(entry)
        json[key] = entries
        return entries.count - 1
    }

    mutating func changeEntry(of key: String, at index: Int, _ change: (inout [String: Any]) -> Void) {
        var entries = json[key] as? [[String: Any]] ?? []
        change(&entries[index])
        json[key] = entries
    }

    mutating func addBufferView(_ bytes: Data, byteStride: Int? = nil) -> Int {
        while binary.count % 4 != 0 { binary.append(0) }
        var bufferView: [String: Any] = ["buffer": 0, "byteOffset": binary.count, "byteLength": bytes.count]
        if let byteStride { bufferView["byteStride"] = byteStride }
        binary.append(bytes)
        return appendEntry(bufferView, to: "bufferViews")
    }

    mutating func addAccessor(
        bufferView: Int, componentType: Int, count: Int, type: String, byteOffset: Int = 0
    ) -> Int {
        var accessor: [String: Any] = [
            "bufferView": bufferView, "componentType": componentType, "count": count, "type": type,
        ]
        if byteOffset != 0 { accessor["byteOffset"] = byteOffset }
        return appendEntry(accessor, to: "accessors")
    }

    /// The finished GLB. The header fields can be broken on purpose.
    func data(magic: UInt32 = 0x4654_6C67, version: UInt32 = 2, declaredLengthChange: Int = 0) -> Data {
        var completeJSON = json
        if completeJSON["buffers"] == nil, !binary.isEmpty {
            completeJSON["buffers"] = [["byteLength": binary.count]]
        }
        var jsonBytes = (try? JSONSerialization.data(withJSONObject: completeJSON)) ?? Data()
        while jsonBytes.count % 4 != 0 { jsonBytes.append(0x20) }
        var binaryBytes = binary
        while binaryBytes.count % 4 != 0 { binaryBytes.append(0) }

        var file = Data()
        file.appendLittleEndian(magic)
        file.appendLittleEndian(version)
        let totalLength = 12 + 8 + jsonBytes.count + (binaryBytes.isEmpty ? 0 : 8 + binaryBytes.count)
        file.appendLittleEndian(UInt32(totalLength + declaredLengthChange))
        file.appendLittleEndian(UInt32(jsonBytes.count))
        file.appendLittleEndian(0x4E4F_534A)
        file.append(jsonBytes)
        if !binaryBytes.isEmpty {
            file.appendLittleEndian(UInt32(binaryBytes.count))
            file.appendLittleEndian(0x004E_4942)
            file.append(binaryBytes)
        }
        return file
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}

private func littleEndianBytes<Element>(of values: [Element]) -> Data {
    values.withUnsafeBufferPointer { Data(buffer: $0) }
}

enum GLBIndexWidth: CaseIterable {
    case unsignedByte, unsignedShort, unsignedInt

    var componentType: Int {
        switch self {
        case .unsignedByte: return 5121
        case .unsignedShort: return 5123
        case .unsignedInt: return 5125
        }
    }

    func bytes(of indices: [Int]) -> Data {
        switch self {
        case .unsignedByte: return littleEndianBytes(of: indices.map { UInt8($0) })
        case .unsignedShort: return littleEndianBytes(of: indices.map { UInt16($0) })
        case .unsignedInt: return littleEndianBytes(of: indices.map { UInt32($0) })
        }
    }
}

/// A square facing +z, corners in the order bottom left, bottom right, top right, top left, with texture coordinates in
/// glTF's convention (v grows downward, so the bottom left corner has v = 1).
private let quadPositions: [Float] = [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0]
private let quadTextureCoordinates: [Float] = [0, 1, 1, 1, 1, 0, 0, 0]
private let quadIndices = [0, 1, 2, 0, 2, 3]

/// A GLB with one node holding a quad. Pass images to embed them (texture i is image i), and change `json` afterwards to
/// build the broken variants.
private func quadGLB(
    indexWidth: GLBIndexWidth = .unsignedShort,
    includeNormals: Bool = true,
    includeTextureCoordinates: Bool = true,
    material: [String: Any]? = nil,
    imageFiles: [(bytes: Data, mimeType: String)] = [],
    samplers: [[String: Any]] = []
) -> SyntheticGLB {
    var glb = SyntheticGLB()
    var attributes: [String: Any] = [:]

    let positionView = glb.addBufferView(littleEndianBytes(of: quadPositions))
    attributes["POSITION"] = glb.addAccessor(bufferView: positionView, componentType: 5126, count: 4, type: "VEC3")
    if includeNormals {
        let normalView = glb.addBufferView(littleEndianBytes(of: [Float]([0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])))
        attributes["NORMAL"] = glb.addAccessor(bufferView: normalView, componentType: 5126, count: 4, type: "VEC3")
    }
    if includeTextureCoordinates {
        let textureCoordinateView = glb.addBufferView(littleEndianBytes(of: quadTextureCoordinates))
        attributes["TEXCOORD_0"] = glb.addAccessor(bufferView: textureCoordinateView, componentType: 5126, count: 4, type: "VEC2")
    }
    let indexView = glb.addBufferView(indexWidth.bytes(of: quadIndices))
    let indexAccessor = glb.addAccessor(bufferView: indexView, componentType: indexWidth.componentType, count: 6, type: "SCALAR")

    var primitive: [String: Any] = ["attributes": attributes, "indices": indexAccessor]
    if let material {
        primitive["material"] = glb.appendEntry(material, to: "materials")
    }
    for imageFile in imageFiles {
        let imageView = glb.addBufferView(imageFile.bytes)
        let imageIndex = glb.appendEntry(["bufferView": imageView, "mimeType": imageFile.mimeType], to: "images")
        var texture: [String: Any] = ["source": imageIndex]
        if !samplers.isEmpty { texture["sampler"] = 0 }
        glb.appendEntry(texture, to: "textures")
    }
    for sampler in samplers {
        glb.appendEntry(sampler, to: "samplers")
    }
    glb.appendEntry(["primitives": [primitive]], to: "meshes")
    glb.appendEntry(["mesh": 0, "name": "quad"], to: "nodes")
    glb.appendEntry(["nodes": [0]], to: "scenes")
    glb.json["scene"] = 0
    return glb
}

/// A PNG of the given RGBA pixels (straight alpha, row by row from the top), with or without an alpha channel.
private func pngData(width: Int, height: Int, rgbaPixels: [UInt8], hasAlpha: Bool = true) -> Data {
    var pixels = rgbaPixels
    let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
    let image = pixels.withUnsafeMutableBytes { pixelBuffer -> CGImage? in
        let context = CGContext(
            data: pixelBuffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: alphaInfo.rawValue
        )
        return context?.makeImage()
    }
    let output = NSMutableData()
    if let image, let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
    return output as Data
}

/// Red, green, blue, and white pixels, left to right then top to bottom, so a flipped image is easy to see.
private let colorQuadPNG = pngData(
    width: 2, height: 2,
    rgbaPixels: [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
)

// MARK: - Reading the result

private func floatValues(of source: SCNGeometrySource) -> [Float] {
    var values: [Float] = []
    source.data.withUnsafeBytes { rawBytes in
        for vectorIndex in 0..<source.vectorCount {
            for componentIndex in 0..<source.componentsPerVector {
                let offset = source.dataOffset + vectorIndex * source.dataStride + componentIndex * source.bytesPerComponent
                values.append(rawBytes.loadUnaligned(fromByteOffset: offset, as: Float.self))
            }
        }
    }
    return values
}

private func indexValues(of element: SCNGeometryElement) -> [UInt32] {
    var values: [UInt32] = []
    element.data.withUnsafeBytes { rawBytes in
        for indexPosition in 0..<(element.primitiveCount * 3) {
            values.append(rawBytes.loadUnaligned(fromByteOffset: indexPosition * element.bytesPerIndex, as: UInt32.self))
        }
    }
    return values
}

private func quadNode(in rootNode: SCNNode) throws -> SCNNode {
    try #require(rootNode.childNodes.first)
}

private func isACGImage(_ contents: Any?) -> Bool {
    guard let contents else { return false }
    return CFGetTypeID(contents as CFTypeRef) == CGImage.typeID
}

/// The material contents as a CGImage, or nil when they are anything else.
private func cgImage(from contents: Any?) -> CGImage? {
    guard isACGImage(contents) else { return nil }
    // Reason: Swift cannot check a cast to a Core Foundation type, so the type ID check above is the check.
    return (contents as! CGImage)
}

/// The 8-bit values of a CGImage's pixels as RGBA, drawn into a known layout.
private func rgbaPixels(of image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    pixels.withUnsafeMutableBytes { pixelBuffer in
        let context = CGContext(
            data: pixelBuffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return pixels
}

/// The stored values of a one channel, 8-bit image, read from its bytes since drawing it would convert them.
private func grayValues(of image: CGImage) -> [UInt8] {
    guard image.bitsPerPixel == 8, let pixelBytes = image.dataProvider?.data as Data? else { return [] }
    return (0..<image.height).flatMap { row in
        (0..<image.width).map { column in pixelBytes[row * image.bytesPerRow + column] }
    }
}

private func expectRefusal(
    of glbData: Data, mentioning expectedText: String, sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try GLBLoader.rootNode(fromGLBData: glbData)
        Issue.record("The loader accepted a file it should refuse (\(expectedText)).", sourceLocation: sourceLocation)
    } catch let error as GLBLoadError {
        #expect(error.reason.contains(expectedText), "The refusal said \"\(error.reason)\".", sourceLocation: sourceLocation)
    } catch {
        Issue.record("The loader threw \(error), not a GLBLoadError.", sourceLocation: sourceLocation)
    }
}

// MARK: - Geometry

struct GLBLoaderGeometryTests {
    @Test func aTexturedQuadKeepsItsVerticesTrianglesAndImage() throws {
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/png")]
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        let vertexSource = try #require(geometry.sources(for: .vertex).first)
        let textureCoordinateSource = try #require(geometry.sources(for: .texcoord).first)
        #expect(vertexSource.vectorCount == 4)
        #expect(floatValues(of: vertexSource) == quadPositions)
        #expect(textureCoordinateSource.vectorCount == 4)
        #expect(geometry.elements.count == 1)
        #expect(geometry.elements[0].primitiveCount == 2)
        #expect(indexValues(of: geometry.elements[0]) == quadIndices.map { UInt32($0) })

        let material = try #require(geometry.materials.first)
        #expect(material.lightingModel == .physicallyBased)
        #expect(isACGImage(material.diffuse.contents))
    }

    @Test func textureCoordinatesPassThroughUnchanged() throws {
        let glb = quadGLB()
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        let textureCoordinateSource = try #require(geometry.sources(for: .texcoord).first)
        #expect(floatValues(of: textureCoordinateSource) == quadTextureCoordinates)
    }

    @Test(arguments: GLBIndexWidth.allCases)
    func indicesOfEveryWidthReadTheSameTriangles(indexWidth: GLBIndexWidth) throws {
        let glb = quadGLB(indexWidth: indexWidth)
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        #expect(indexValues(of: geometry.elements[0]) == quadIndices.map { UInt32($0) })
    }

    @Test func aPrimitiveWithNoIndicesDrawsItsVerticesInOrder() throws {
        var glb = quadGLB()
        glb.changeEntry(of: "meshes", at: 0) { mesh in
            var primitive = (mesh["primitives"] as? [[String: Any]] ?? [])[0]
            primitive["indices"] = nil
            // Three vertices make one triangle, so the quad's fourth vertex is dropped from the draw.
            mesh["primitives"] = [primitive]
        }
        glb.changeEntry(of: "accessors", at: 0) { $0["count"] = 3 }
        glb.changeEntry(of: "accessors", at: 1) { $0["count"] = 3 }
        glb.changeEntry(of: "accessors", at: 2) { $0["count"] = 3 }
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        #expect(indexValues(of: geometry.elements[0]) == [0, 1, 2])
    }

    @Test func aStridedInterleavedBufferViewReadsPositionsAndTextureCoordinates() throws {
        var glb = SyntheticGLB()
        // Eight bytes of padding first, so the buffer view does not start at the buffer's start.
        _ = glb.addBufferView(Data(count: 8))
        var interleavedFloats: [Float] = []
        for vertexIndex in 0..<4 {
            interleavedFloats += Array(quadPositions[(vertexIndex * 3)..<(vertexIndex * 3 + 3)])
            interleavedFloats += Array(quadTextureCoordinates[(vertexIndex * 2)..<(vertexIndex * 2 + 2)])
        }
        let interleavedView = glb.addBufferView(littleEndianBytes(of: interleavedFloats), byteStride: 20)
        let positionAccessor = glb.addAccessor(bufferView: interleavedView, componentType: 5126, count: 4, type: "VEC3")
        let textureCoordinateAccessor = glb.addAccessor(
            bufferView: interleavedView, componentType: 5126, count: 4, type: "VEC2", byteOffset: 12
        )
        let indexView = glb.addBufferView(littleEndianBytes(of: quadIndices.map { UInt16($0) }))
        let indexAccessor = glb.addAccessor(bufferView: indexView, componentType: 5123, count: 6, type: "SCALAR")
        glb.appendEntry(
            ["primitives": [["attributes": ["POSITION": positionAccessor, "TEXCOORD_0": textureCoordinateAccessor], "indices": indexAccessor]]],
            to: "meshes"
        )
        glb.appendEntry(["mesh": 0], to: "nodes")

        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        let vertexSource = try #require(geometry.sources(for: .vertex).first)
        let textureCoordinateSource = try #require(geometry.sources(for: .texcoord).first)
        #expect(floatValues(of: vertexSource) == quadPositions)
        #expect(floatValues(of: textureCoordinateSource) == quadTextureCoordinates)
    }

    @Test func missingNormalsAreComputedFromTheTriangles() throws {
        let glb = quadGLB(includeNormals: false)
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        let normalSource = try #require(geometry.sources(for: .normal).first)
        #expect(floatValues(of: normalSource) == [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1])
    }

    @Test func aMissingTextureCoordinateSetIsFine() throws {
        let glb = quadGLB(includeTextureCoordinates: false)
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let geometry = try #require(try quadNode(in: rootNode).geometry)
        #expect(geometry.sources(for: .texcoord).isEmpty)
    }
}

// MARK: - Nodes and scenes

struct GLBLoaderNodeTests {
    /// A GLB with only nodes, so a test sets up the hierarchy it needs.
    private func nodesOnlyGLB(nodes: [[String: Any]], scenes: [[String: Any]]? = nil, scene: Int? = nil) -> SyntheticGLB {
        var glb = quadGLB()
        glb.json["nodes"] = nodes
        if let scenes { glb.json["scenes"] = scenes } else { glb.json["scenes"] = nil }
        glb.json["scene"] = scene
        return glb
    }

    @Test func translationRotationAndScaleApplyInThatOrder() throws {
        let glb = nodesOnlyGLB(nodes: [[
            "translation": [1, 2, 3], "rotation": [0, 0, 0.70710678, 0.70710678], "scale": [2, 2, 2],
        ]], scene: nil)
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        // The point (1, 0, 0) is scaled to (2, 0, 0), turned a quarter turn about z to (0, 2, 0), and moved by (1, 2, 3).
        let transformedPoint = try quadNode(in: rootNode).simdTransform * SIMD4<Float>(1, 0, 0, 1)
        #expect(abs(transformedPoint.x - 1) < 1e-5)
        #expect(abs(transformedPoint.y - 4) < 1e-5)
        #expect(abs(transformedPoint.z - 3) < 1e-5)
    }

    @Test func aMatrixIsReadColumnByColumnAndChildrenInheritTheirParentsTransform() throws {
        // The child's matrix turns a quarter turn about z and moves by (2, 5, 0). Written column by column, the first column is
        // the turned x axis (0, 1, 0), the second the turned y axis (-1, 0, 0), and the last the move.
        let glb = nodesOnlyGLB(nodes: [
            ["translation": [10, 0, 0], "children": [1]],
            ["matrix": [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 2, 5, 0, 1]],
        ])
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let childNode = try #require(try quadNode(in: rootNode).childNodes.first)
        // (1, 2, 3) turns to (-2, 1, 3) and moves by (2, 5, 0).
        let childPoint = childNode.simdTransform * SIMD4<Float>(1, 2, 3, 1)
        #expect(childPoint == SIMD4<Float>(0, 6, 3, 1))
        #expect(childNode.simdWorldPosition == SIMD3<Float>(12, 5, 0))
    }

    @Test func theDefaultSceneDecidesWhichNodesLoad() throws {
        let glb = nodesOnlyGLB(
            nodes: [["name": "firstScenesNode"], ["name": "secondScenesNode"]],
            scenes: [["nodes": [0]], ["nodes": [1]]],
            scene: 1
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        #expect(rootNode.childNodes.map(\.name) == ["secondScenesNode"])
    }

    @Test func withNoDefaultSceneTheFirstSceneLoads() throws {
        let glb = nodesOnlyGLB(
            nodes: [["name": "firstScenesNode"], ["name": "secondScenesNode"]],
            scenes: [["nodes": [0]], ["nodes": [1]]]
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        #expect(rootNode.childNodes.map(\.name) == ["firstScenesNode"])
    }

    @Test func withNoScenesEveryRootNodeLoads() throws {
        let glb = nodesOnlyGLB(nodes: [
            ["name": "parent", "children": [1]], ["name": "child"], ["name": "otherRoot"],
        ])
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        #expect(rootNode.childNodes.map(\.name) == ["parent", "otherRoot"])
        #expect(rootNode.childNodes.first?.childNodes.map(\.name) == ["child"])
    }
}

// MARK: - Materials

struct GLBLoaderMaterialTests {
    @Test func aPrimitiveWithNoMaterialGetsGLTFsDefaultMaterial() throws {
        let rootNode = try GLBLoader.rootNode(fromGLBData: quadGLB().data())

        let material = try #require(try quadNode(in: rootNode).geometry?.materials.first)
        #expect(material.lightingModel == .physicallyBased)
        #expect((material.metalness.contents as? NSNumber)?.doubleValue == 1)
        #expect((material.roughness.contents as? NSNumber)?.doubleValue == 1)
        #expect(material.isDoubleSided == false)
        #expect(material.transparency == 1)
    }

    @Test func factorsAndDoubleSidingCarryOver() throws {
        let glb = quadGLB(material: [
            "pbrMetallicRoughness": ["baseColorFactor": [0.5, 0.25, 0.75, 1], "metallicFactor": 0.2, "roughnessFactor": 0.6],
            "doubleSided": true,
        ])
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let material = try #require(try quadNode(in: rootNode).geometry?.materials.first)
        let diffuseColor = try #require(material.diffuse.contents as? NSColor)
        let linearColorSpace = try #require(CGColorSpace(name: CGColorSpace.linearSRGB))
        let linearNSColorSpace = try #require(NSColorSpace(cgColorSpace: linearColorSpace))
        let linearSRGB = try #require(diffuseColor.usingColorSpace(linearNSColorSpace))
        #expect(abs(linearSRGB.redComponent - 0.5) < 0.001)
        #expect(abs(linearSRGB.greenComponent - 0.25) < 0.001)
        #expect(abs(linearSRGB.blueComponent - 0.75) < 0.001)
        #expect((material.metalness.contents as? NSNumber)?.doubleValue == 0.2)
        #expect((material.roughness.contents as? NSNumber)?.doubleValue == 0.6)
        #expect(material.isDoubleSided)
    }

    @Test func aBlendMaterialKeepsItsAlphaAndAnOpaqueOneIgnoresIt() throws {
        let blendGLB = quadGLB(material: [
            "pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 0.4]], "alphaMode": "BLEND",
        ])
        let opaqueGLB = quadGLB(material: ["pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 0.4]]])

        let blendMaterial = try #require(try quadNode(in: GLBLoader.rootNode(fromGLBData: blendGLB.data())).geometry?.materials.first)
        let opaqueMaterial = try #require(try quadNode(in: GLBLoader.rootNode(fromGLBData: opaqueGLB.data())).geometry?.materials.first)

        #expect(abs(blendMaterial.transparency - 0.4) < 0.001)
        #expect(opaqueMaterial.transparency == 1)
    }

    @Test func anOpaqueMaterialDropsTheAlphaOfItsBaseColorTexture() throws {
        let translucentPNG = pngData(width: 1, height: 1, rgbaPixels: [200, 100, 50, 128])
        let material: [String: Any] = ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]]
        let opaqueGLB = quadGLB(material: material, imageFiles: [(translucentPNG, "image/png")])
        var blendMaterialJSON = material
        blendMaterialJSON["alphaMode"] = "BLEND"
        let blendGLB = quadGLB(material: blendMaterialJSON, imageFiles: [(translucentPNG, "image/png")])

        let opaqueContents = try quadNode(in: GLBLoader.rootNode(fromGLBData: opaqueGLB.data())).geometry?.materials.first?.diffuse.contents
        let blendContents = try quadNode(in: GLBLoader.rootNode(fromGLBData: blendGLB.data())).geometry?.materials.first?.diffuse.contents

        let opaqueImage = try #require(cgImage(from: opaqueContents))
        let blendImage = try #require(cgImage(from: blendContents))
        #expect([.none, .noneSkipFirst, .noneSkipLast].contains(opaqueImage.alphaInfo))
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(blendImage.alphaInfo))
    }

    @Test func aBaseColorFactorTintsItsTextureThroughMultiply() throws {
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "baseColorFactor": [0.5, 1, 1, 1]]],
            imageFiles: [(colorQuadPNG, "image/png")]
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let material = try #require(try quadNode(in: rootNode).geometry?.materials.first)
        #expect(isACGImage(material.diffuse.contents))
        #expect(material.multiply.contents is NSColor)
    }

    @Test func theMetallicRoughnessTextureSplitsIntoRoughnessFromGreenAndMetalnessFromBlue() throws {
        // Two pixels: (green 200, blue 50) and (green 100, blue 150).
        let packedPNG = pngData(width: 2, height: 1, rgbaPixels: [0, 200, 50, 255, 0, 100, 150, 255])
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": [
                "metallicRoughnessTexture": ["index": 0], "metallicFactor": 0.5, "roughnessFactor": 0.75,
            ]],
            imageFiles: [(packedPNG, "image/png")]
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let material = try #require(try quadNode(in: rootNode).geometry?.materials.first)
        let roughnessImage = try #require(cgImage(from: material.roughness.contents))
        let metalnessImage = try #require(cgImage(from: material.metalness.contents))
        #expect(roughnessImage.width == 2 && roughnessImage.height == 1)
        #expect(grayValues(of: roughnessImage) == [200, 100])
        #expect(grayValues(of: metalnessImage) == [50, 150])
        #expect(material.roughness.intensity == 0.75)
        #expect(material.metalness.intensity == 0.5)
    }

    @Test func aNormalTextureKeepsItsScale() throws {
        let glb = quadGLB(
            material: ["normalTexture": ["index": 0, "scale": 0.5]],
            imageFiles: [(colorQuadPNG, "image/png")]
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())

        let material = try #require(try quadNode(in: rootNode).geometry?.materials.first)
        #expect(isACGImage(material.normal.contents))
        #expect(material.normal.intensity == 0.5)
    }

    @Test func aSamplersWrapModesCarryOverAndTheDefaultIsRepeat() throws {
        let samplerGLB = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/png")],
            samplers: [["wrapS": 33071, "wrapT": 33648]]
        )
        let defaultGLB = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/png")]
        )

        let samplerMaterial = try #require(try quadNode(in: GLBLoader.rootNode(fromGLBData: samplerGLB.data())).geometry?.materials.first)
        let defaultMaterial = try #require(try quadNode(in: GLBLoader.rootNode(fromGLBData: defaultGLB.data())).geometry?.materials.first)

        #expect(samplerMaterial.diffuse.wrapS == .clamp)
        #expect(samplerMaterial.diffuse.wrapT == .mirror)
        #expect(defaultMaterial.diffuse.wrapS == .repeat)
        #expect(defaultMaterial.diffuse.wrapT == .repeat)
    }
}

// MARK: - Orientation

/// Which way a loaded quad's texture runs. SceneKit's own plane is the windowless reference, since SceneKit draws an image
/// upright on a plane, and a render into a Metal texture confirms the whole path.
struct GLBLoaderOrientationTests {
    @Test func aQuadsTextureCoordinatesRunTheSameWayAsSceneKitsOwnPlane() throws {
        let plane = SCNPlane(width: 2, height: 2)
        let planePositions = floatValues(of: try #require(plane.sources(for: .vertex).first))
        let planeTextureCoordinates = floatValues(of: try #require(plane.sources(for: .texcoord).first))
        // The plane's corners are matched by which side of its center they are on, since its units differ from the quad's.
        func planeTextureCoordinate(atX x: Float, y: Float) throws -> [Float] {
            let vertexIndex = try #require((0..<4).first { (planePositions[$0 * 3] < 0) == (x < 0) && (planePositions[$0 * 3 + 1] < 0) == (y < 0) })
            return Array(planeTextureCoordinates[(vertexIndex * 2)..<(vertexIndex * 2 + 2)])
        }

        let rootNode = try GLBLoader.rootNode(fromGLBData: quadGLB().data())
        let geometry = try #require(try quadNode(in: rootNode).geometry)
        let loadedPositions = floatValues(of: try #require(geometry.sources(for: .vertex).first))
        let loadedTextureCoordinates = floatValues(of: try #require(geometry.sources(for: .texcoord).first))

        for vertexIndex in 0..<4 {
            let loadedCorner = Array(loadedTextureCoordinates[(vertexIndex * 2)..<(vertexIndex * 2 + 2)])
            let planeCorner = try planeTextureCoordinate(
                atX: loadedPositions[vertexIndex * 3], y: loadedPositions[vertexIndex * 3 + 1]
            )
            #expect(loadedCorner == planeCorner, "corner \(vertexIndex) is \(loadedCorner), and SceneKit's plane has \(planeCorner)")
        }
    }

    // MARK: Drawing

    private static let imageSideInPixels = 64

    /// Draws `rootNode` straight on, filling the view, into a Metal texture and returns RGB at the four quadrant centers, or
    /// nil when this process cannot draw at all.
    private func quadrantColors(of rootNode: SCNNode) -> (topLeft: [UInt8], topRight: [UInt8], bottomLeft: [UInt8], bottomRight: [UInt8])? {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else { return nil }
        let side = Self.imageSideInPixels
        let scene = SCNScene()
        scene.rootNode.addChildNode(rootNode)
        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = 1
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 5)
        scene.rootNode.addChildNode(cameraNode)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .managed
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: side, height: side, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let colorTexture = device.makeTexture(descriptor: colorDescriptor),
              let depthTexture = device.makeTexture(descriptor: depthDescriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = colorTexture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.depthAttachment.texture = depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.clearDepth = 1
        passDescriptor.stencilAttachment.texture = depthTexture
        passDescriptor.stencilAttachment.loadAction = .clear
        renderer.render(
            atTime: 0, viewport: CGRect(x: 0, y: 0, width: side, height: side),
            commandBuffer: commandBuffer, passDescriptor: passDescriptor
        )
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blitEncoder.synchronize(resource: colorTexture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bgraPixels = [UInt8](repeating: 0, count: side * side * 4)
        colorTexture.getBytes(&bgraPixels, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        func redGreenBlue(atColumn column: Int, row: Int) -> [UInt8] {
            let offset = (row * side + column) * 4
            return [bgraPixels[offset + 2], bgraPixels[offset + 1], bgraPixels[offset]]
        }
        return (
            redGreenBlue(atColumn: side / 4, row: side / 4), redGreenBlue(atColumn: 3 * side / 4, row: side / 4),
            redGreenBlue(atColumn: side / 4, row: 3 * side / 4), redGreenBlue(atColumn: 3 * side / 4, row: 3 * side / 4)
        )
    }

    @Test func aTexturedQuadDrawsRightSideUp() throws {
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/png")]
        )
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())
        // Constant lighting shows the texture's own colors, with no light to set up. The texture coordinates and the image
        // are the loader's own.
        try #require(rootNode.childNodes.first?.geometry?.materials.first).lightingModel = .constant

        guard let colors = quadrantColors(of: rootNode) else {
            Issue.record("This process could not draw with Metal.")
            return
        }
        // The image is red and green on its top row, and blue and white on its bottom row.
        // Allowing a few levels for the renderer's own rounding.
        func isClose(_ drawn: [UInt8], to expected: [Int]) -> Bool {
            zip(drawn, expected).allSatisfy { abs(Int($0) - $1) <= 12 }
        }
        #expect(isClose(colors.topLeft, to: [255, 0, 0]), "top left was \(colors.topLeft)")
        #expect(isClose(colors.topRight, to: [0, 255, 0]), "top right was \(colors.topRight)")
        #expect(isClose(colors.bottomLeft, to: [0, 0, 255]), "bottom left was \(colors.bottomLeft)")
        #expect(isClose(colors.bottomRight, to: [255, 255, 255]), "bottom right was \(colors.bottomRight)")
    }
}

// MARK: - Refusals

struct GLBLoaderRefusalTests {
    @Test func aFileWithoutTheGLTFMagicIsRefused() {
        expectRefusal(of: quadGLB().data(magic: 0x1234_5678), mentioning: "magic")
    }

    @Test func versionOneIsRefused() {
        expectRefusal(of: quadGLB().data(version: 1), mentioning: "version 1")
    }

    @Test func aDeclaredLengthThatDoesNotMatchTheFileIsRefused() {
        expectRefusal(of: quadGLB().data(declaredLengthChange: 8), mentioning: "length")
    }

    @Test func aTruncatedFileIsRefused() {
        let wholeFile = quadGLB().data()
        expectRefusal(of: wholeFile.prefix(wholeFile.count - 10), mentioning: "length")
    }

    @Test func aFileTooShortForAHeaderIsRefused() {
        expectRefusal(of: Data([0x67, 0x6C, 0x54, 0x46]), mentioning: "too short")
    }

    @Test func aFileOverTheSizeCapIsRefused() {
        expectRefusal(of: Data(count: GLBLoader.largestFileByteCount + 1), mentioning: "larger than")
    }

    @Test func aBufferWithAnExternalURIIsRefused() {
        var glb = quadGLB()
        glb.json["buffers"] = [["byteLength": glb.binary.count, "uri": "scene.bin"]]
        expectRefusal(of: glb.data(), mentioning: "URI")
    }

    @Test func aBufferWithADataURIIsRefused() {
        var glb = quadGLB()
        glb.json["buffers"] = [["byteLength": 4, "uri": "data:application/octet-stream;base64,AAAAAA=="]]
        expectRefusal(of: glb.data(), mentioning: "URI")
    }

    @Test func aRequiredDracoExtensionIsRefused() {
        var glb = quadGLB()
        glb.json["extensionsRequired"] = ["KHR_draco_mesh_compression"]
        glb.json["extensionsUsed"] = ["KHR_draco_mesh_compression"]
        expectRefusal(of: glb.data(), mentioning: "KHR_draco_mesh_compression")
    }

    @Test func anyOtherRequiredExtensionIsRefused() {
        var glb = quadGLB()
        glb.json["extensionsRequired"] = ["KHR_mesh_quantization"]
        expectRefusal(of: glb.data(), mentioning: "KHR_mesh_quantization")
    }

    @Test func aPrimitiveThatCarriesDracoIsRefusedEvenWhenTheExtensionIsOnlyUsed() {
        var glb = quadGLB()
        glb.json["extensionsUsed"] = ["KHR_draco_mesh_compression"]
        glb.changeEntry(of: "meshes", at: 0) { mesh in
            var primitive = (mesh["primitives"] as? [[String: Any]] ?? [])[0]
            primitive["extensions"] = ["KHR_draco_mesh_compression": ["bufferView": 0, "attributes": ["POSITION": 0]]]
            mesh["primitives"] = [primitive]
        }
        expectRefusal(of: glb.data(), mentioning: "KHR_draco_mesh_compression")
    }

    @Test func aPrimitiveThatIsNotTrianglesIsRefused() {
        var glb = quadGLB()
        glb.changeEntry(of: "meshes", at: 0) { mesh in
            var primitive = (mesh["primitives"] as? [[String: Any]] ?? [])[0]
            primitive["mode"] = 1
            mesh["primitives"] = [primitive]
        }
        expectRefusal(of: glb.data(), mentioning: "triangles")
    }

    @Test func aSparseAccessorIsRefused() {
        var glb = quadGLB()
        glb.changeEntry(of: "accessors", at: 0) { $0["sparse"] = ["count": 1] }
        expectRefusal(of: glb.data(), mentioning: "sparse")
    }

    @Test func aNormalizedAccessorIsRefused() {
        var glb = quadGLB()
        glb.changeEntry(of: "accessors", at: 0) { $0["normalized"] = true }
        expectRefusal(of: glb.data(), mentioning: "normalized")
    }

    @Test func positionsThatAreNotFloatsAreRefused() {
        var glb = quadGLB()
        glb.changeEntry(of: "accessors", at: 0) { $0["componentType"] = 5123 }
        expectRefusal(of: glb.data(), mentioning: "component type")
    }

    @Test func anAccessorThatReadsPastItsBufferViewIsRefused() {
        var glb = quadGLB()
        glb.changeEntry(of: "accessors", at: 0) { $0["count"] = 5 }
        expectRefusal(of: glb.data(), mentioning: "past the end of its buffer view")
    }

    @Test func aBufferViewThatReachesPastTheBufferIsRefused() {
        var glb = quadGLB()
        glb.changeEntry(of: "bufferViews", at: 0) { $0["byteLength"] = 100_000 }
        expectRefusal(of: glb.data(), mentioning: "past the end")
    }

    @Test func anIndexPastTheVertexCountIsRefused() {
        var glb = quadGLB()
        // Replaces the index buffer view's bytes in place, with the same length and an index of 7.
        let indexView = (glb.json["bufferViews"] as? [[String: Any]] ?? []).count - 1
        let indexOffset = (glb.json["bufferViews"] as? [[String: Any]] ?? [])[indexView]["byteOffset"] as? Int ?? 0
        glb.binary.replaceSubrange(indexOffset..<(indexOffset + 12), with: littleEndianBytes(of: [UInt16](arrayLiteral: 0, 1, 7, 0, 2, 3)))
        expectRefusal(of: glb.data(), mentioning: "past the vertices")
    }

    @Test func moreVerticesThanTheCapAreRefused() {
        var glb = SyntheticGLB()
        let vertexCount = GLBLoader.mostVerticesInAFile + 1
        let positionView = glb.addBufferView(Data(count: vertexCount * 12))
        let positionAccessor = glb.addAccessor(bufferView: positionView, componentType: 5126, count: vertexCount, type: "VEC3")
        glb.appendEntry(["primitives": [["attributes": ["POSITION": positionAccessor]]]], to: "meshes")
        glb.appendEntry(["mesh": 0], to: "nodes")
        expectRefusal(of: glb.data(), mentioning: "vertices")
    }

    @Test func anImageOver4096PixelsOnASideIsRefused() {
        let wideImage = pngData(width: 4097, height: 1, rgbaPixels: [UInt8](repeating: 255, count: 4097 * 4))
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(wideImage, "image/png")]
        )
        expectRefusal(of: glb.data(), mentioning: "4096")
    }

    @Test func anImageThatIsNotAPNGOrJPEGIsRefused() {
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/webp")]
        )
        expectRefusal(of: glb.data(), mentioning: "PNG or a JPEG")
    }

    @Test func anImageWhoseBytesAreNotTheTypeItClaimsIsRefused() {
        let glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/jpeg")]
        )
        expectRefusal(of: glb.data(), mentioning: "bytes")
    }

    @Test func anImageWithAURIIsRefused() {
        var glb = quadGLB(
            material: ["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]]],
            imageFiles: [(colorQuadPNG, "image/png")]
        )
        glb.changeEntry(of: "images", at: 0) { $0["uri"] = "https://example.com/texture.png" }
        expectRefusal(of: glb.data(), mentioning: "URI")
    }

    @Test func aNodeCycleIsRefused() {
        var glb = quadGLB()
        glb.json["nodes"] = [["children": [1]], ["children": [0]]]
        glb.json["scenes"] = [["nodes": [0]]]
        expectRefusal(of: glb.data(), mentioning: "not a tree")
    }

    @Test func nodesNestedDeeperThanTheLimitAreRefused() {
        var glb = quadGLB()
        let chainLength = GLBLoader.deepestNodeNesting + 6
        glb.json["nodes"] = (0..<chainLength).map { nodeIndex in
            nodeIndex + 1 < chainLength ? ["children": [nodeIndex + 1]] : [:]
        }
        glb.json["scenes"] = [["nodes": [0]]]
        expectRefusal(of: glb.data(), mentioning: "nested deeper")
    }
}

// MARK: - A real file

struct GLBLoaderRealFileTests {
    private static let realFilePath = ProcessInfo.processInfo.environment["ROOM_FURNITURE_GLB"]

    @Test(.enabled(if: realFilePath != nil))
    func aRealFileLoadsAndReportsItsSize() throws {
        let path = try #require(Self.realFilePath)
        let glbData = try Data(contentsOf: URL(fileURLWithPath: path))

        let rootNode = try GLBLoader.rootNode(fromGLBData: glbData)

        var nodeCount = 0
        var triangleCount = 0
        var lowestCorner = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var highestCorner = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        rootNode.enumerateHierarchy { node, _ in
            nodeCount += 1
            guard let geometry = node.geometry else { return }
            triangleCount += geometry.elements.reduce(0) { $0 + $1.primitiveCount }
            let (minimum, maximum) = geometry.boundingBox
            for cornerIndex in 0..<8 {
                let corner = SIMD3<Float>(
                    cornerIndex & 1 == 0 ? Float(minimum.x) : Float(maximum.x),
                    cornerIndex & 2 == 0 ? Float(minimum.y) : Float(maximum.y),
                    cornerIndex & 4 == 0 ? Float(minimum.z) : Float(maximum.z)
                )
                let worldCorner = node.simdWorldTransform * SIMD4<Float>(corner, 1)
                lowestCorner = simd_min(lowestCorner, SIMD3(worldCorner.x, worldCorner.y, worldCorner.z))
                highestCorner = simd_max(highestCorner, SIMD3(worldCorner.x, worldCorner.y, worldCorner.z))
            }
        }
        print("GLB \(path): \(nodeCount) nodes, \(triangleCount) triangles, box \(lowestCorner) to \(highestCorner) meters")
        #expect(triangleCount > 0)
        #expect(highestCorner.x > lowestCorner.x)
    }

    private static let dracoFilePath = ProcessInfo.processInfo.environment["ROOM_FURNITURE_DRACO_GLB"]

    @Test(.enabled(if: dracoFilePath != nil))
    func aRealDracoFileIsRefused() throws {
        let path = try #require(Self.dracoFilePath)
        let glbData = try Data(contentsOf: URL(fileURLWithPath: path))

        expectRefusal(of: glbData, mentioning: "KHR_draco_mesh_compression")
    }
}

/// A store's file can point many materials at one large texture, or embed several large ones, so what the loader decodes
/// and derives from images is cached and counted against a budget.
struct GLBLoaderImageBudgetTests {
    /// A 4096 by 4096 PNG of one color, which compresses to a few kilobytes but decodes to 16.7 million pixels.
    private static let largePNG: Data = {
        let side = 4096
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let output = NSMutableData()
        if let image = context?.makeImage(), let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return output as Data
    }()

    /// A quad whose mesh repeats its primitive `primitiveCount` times, each with its own material built by `material`.
    /// With `sharingOneMaterial`, every primitive uses the first material instead.
    private func quadWithPrimitives(_ primitiveCount: Int, imageCount: Int, sharingOneMaterial: Bool = false, material: (Int) -> [String: Any]) -> SyntheticGLB {
        var glb = quadGLB(material: material(0), imageFiles: Array(repeating: (bytes: Self.largePNG, mimeType: "image/png"), count: imageCount))
        var addedMaterialIndices: [Int] = []
        for primitiveIndex in 1..<max(primitiveCount, 1) {
            addedMaterialIndices.append(sharingOneMaterial ? 0 : glb.appendEntry(material(primitiveIndex), to: "materials"))
        }
        glb.changeEntry(of: "meshes", at: 0) { mesh in
            var primitives = mesh["primitives"] as? [[String: Any]] ?? []
            let firstPrimitive = primitives[0]
            for materialIndex in addedMaterialIndices {
                var primitive = firstPrimitive
                primitive["material"] = materialIndex
                primitives.append(primitive)
            }
            mesh["primitives"] = primitives
        }
        return glb
    }

    @Test func manyMaterialsSharingOneLargePackedTextureDeriveItsChannelsOnce() throws {
        // Ten materials each splitting the same packed texture would derive 20 channel images, 334 million pixels, past the
        // budget, so this loads only because each channel is derived once and shared.
        let glb = quadWithPrimitives(10, imageCount: 1) { _ in
            ["pbrMetallicRoughness": ["metallicRoughnessTexture": ["index": 0]]]
        }
        let rootNode = try GLBLoader.rootNode(fromGLBData: glb.data())
        var materials: [SCNMaterial] = []
        rootNode.enumerateHierarchy { node, _ in materials += node.geometry?.materials ?? [] }
        #expect(materials.count == 10)
        let roughnessImages = materials.compactMap { $0.roughness.contents as AnyObject? }
        #expect(roughnessImages.count == 10)
        #expect(roughnessImages.allSatisfy { $0 === roughnessImages[0] })
    }

    @Test func imagesPastThePixelBudgetAreRefused() throws {
        // Four different 4096 by 4096 base colors decode to 67 million pixels, past the 64 million budget.
        let glb = quadWithPrimitives(4, imageCount: 4) { primitiveIndex in
            ["pbrMetallicRoughness": ["baseColorTexture": ["index": primitiveIndex]], "alphaMode": "BLEND"]
        }
        #expect(throws: GLBLoadError.self) { try GLBLoader.rootNode(fromGLBData: glb.data()) }
    }

    @Test func aFileWithTooManyMaterialsIsRefused() throws {
        var glb = quadGLB(material: [:])
        for _ in 0..<GLBLoader.mostMaterialsInAFile { glb.appendEntry([:], to: "materials") }
        #expect(throws: GLBLoadError.self) { try GLBLoader.rootNode(fromGLBData: glb.data()) }
    }

    @Test func aFileWithTooManyPrimitivesIsRefused() throws {
        // One shared material, so only the primitive cap can refuse it.
        let glb = quadWithPrimitives(GLBLoader.mostPrimitivesInAFile + 1, imageCount: 0, sharingOneMaterial: true) { _ in [:] }
        #expect(throws: GLBLoadError.self) { try GLBLoader.rootNode(fromGLBData: glb.data()) }
    }

    @Test func aFileAtTheMaterialAndPrimitiveCapsLoads() throws {
        let glb = quadWithPrimitives(GLBLoader.mostMaterialsInAFile, imageCount: 0) { _ in [:] }
        _ = try GLBLoader.rootNode(fromGLBData: glb.data())
    }
}
