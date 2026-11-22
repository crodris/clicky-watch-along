//
//  RoomFurnitureModelLoadingTests.swift
//  leanring-buddyTests
//
//  Loading a model file for the room: a USDZ reads through SceneKit with its consistency checked, and a model past the node
//  or vertex caps is refused before it renders. A USDZ's ZIP entries are checked before SceneKit reads it, since a tiny
//  texture can declare a huge image.
//

import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import Testing
@testable import Clicky

struct RoomFurnitureModelLoadingTests {
    /// A USDZ SceneKit wrote, holding one box, as a store's AR file would hold its product.
    private func boxUSDZData() throws -> Data {
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 0.5, height: 0.4, length: 0.3, chamferRadius: 0)))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("room-furniture-usdz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fileURL = folder.appendingPathComponent("box.usdz")
        try #require(scene.write(to: fileURL, options: nil, delegate: nil, progressHandler: nil))
        return try Data(contentsOf: fileURL)
    }

    @Test func aUSDZLoadsWithItsConsistencyChecked() throws {
        let rootNode = try RoomFurnitureModelLoading.rootNode(fromFileData: try boxUSDZData(), kind: .usdz)
        #expect(RoomFurnitureRenderer.boundingBox(of: rootNode) != nil)
    }

    @Test func aModelPastTheNodeCapIsRefused() throws {
        let rootNode = SCNNode()
        for _ in 0..<5 { rootNode.addChildNode(SCNNode()) }
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheCounts(of: rootNode, mostNodesInAModel: 5, mostVerticesInAModel: 1000)
        }
        try RoomFurnitureModelLoading.checkTheCounts(of: rootNode, mostNodesInAModel: 6, mostVerticesInAModel: 1000)
    }

    @Test func aModelPastTheVertexCapIsRefused() throws {
        // An SCNBox has 24 vertices, four for each face.
        let rootNode = SCNNode()
        rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)))
        rootNode.addChildNode(SCNNode(geometry: SCNBox(width: 1, height: 1, length: 1, chamferRadius: 0)))
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheCounts(of: rootNode, mostNodesInAModel: 100, mostVerticesInAModel: 47)
        }
        try RoomFurnitureModelLoading.checkTheCounts(of: rootNode, mostNodesInAModel: 100, mostVerticesInAModel: 48)
    }

    // MARK: A USDZ's ZIP entries

    /// Little endian bytes of `value`, the byte order of ZIP headers.
    private func littleEndianBytes(_ value: Int, byteCount: Int) -> [UInt8] {
        (0..<byteCount).map { byteIndex in UInt8((value >> (8 * byteIndex)) & 0xFF) }
    }

    /// One ZIP entry, local file header and data. `compressionMethod` 0 is stored, which is how a USDZ holds every file.
    private func zipEntry(name: String, content: [UInt8], compressionMethod: Int = 0, flags: Int = 0) -> Data {
        var entry: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
        entry += littleEndianBytes(20, byteCount: 2)
        entry += littleEndianBytes(flags, byteCount: 2)
        entry += littleEndianBytes(compressionMethod, byteCount: 2)
        entry += littleEndianBytes(0, byteCount: 4)
        entry += littleEndianBytes(0, byteCount: 4)
        entry += littleEndianBytes(content.count, byteCount: 4)
        entry += littleEndianBytes(content.count, byteCount: 4)
        entry += littleEndianBytes(name.utf8.count, byteCount: 2)
        entry += littleEndianBytes(0, byteCount: 2)
        entry += Array(name.utf8) + content
        return Data(entry)
    }

    /// The CRC-32 a PNG chunk ends with, computed bit by bit since a test needs no speed.
    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var checksum: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            checksum ^= UInt32(byte)
            for _ in 0..<8 { checksum = checksum & 1 == 1 ? (checksum >> 1) ^ 0xEDB8_8320 : checksum >> 1 }
        }
        return ~checksum
    }

    /// A one pixel PNG whose header declares `declaredSide` by `declaredSide`, with the header's checksum written again so
    /// ImageIO still reads it. Nothing decodes it, since the check reads only the declared size.
    private func pngBytes(declaredSide: Int) throws -> [UInt8] {
        let context = try #require(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let image = try #require(context.makeImage())
        let encodedData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encodedData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        var pngBytes = [UInt8](encodedData as Data)
        // The first chunk is the 13 byte IHDR: 8 signature bytes, 4 length bytes, the 4 type bytes, then width and height
        // (4 bytes each, big endian) at offsets 16 and 20, and its checksum at 29.
        func bigEndianBytes(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * (3 - $0))) & 0xFF) } }
        pngBytes.replaceSubrange(16..<20, with: bigEndianBytes(declaredSide))
        pngBytes.replaceSubrange(20..<24, with: bigEndianBytes(declaredSide))
        pngBytes.replaceSubrange(29..<33, with: bigEndianBytes(Int(crc32(Array(pngBytes[12..<29])))))
        return pngBytes
    }

    private func usdzInMiniature(textureSide: Int?, compressionMethodOfTheTexture: Int = 0, textureFlags: Int = 0) throws -> Data {
        var archive = zipEntry(name: "model.usdc", content: [1, 2, 3, 4])
        if let textureSide {
            archive += zipEntry(
                name: "0/texture.png", content: try pngBytes(declaredSide: textureSide),
                compressionMethod: compressionMethodOfTheTexture, flags: textureFlags
            )
        }
        return archive
    }

    @Test func aStoredUSDZWithASmallPNGPassesTheEntryCheck() throws {
        try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: try usdzInMiniature(textureSide: 1))
    }

    @Test func aUSDZWhoseTextureDeclaresFiveThousandPixelsASideIsRefusedBeforeSceneKit() throws {
        let archive = try usdzInMiniature(textureSide: 5000)
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive)
        }
        // The load itself refuses it, with SceneKit never reading the file.
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.rootNode(fromFileData: archive, kind: .usdz)
        }
    }

    /// The forged 5000 pixel header above may be refused before its size is read, so this pins the side limit itself with
    /// a real 3 by 3 PNG, held to a limit of 2 and then of 3.
    @Test func aUSDZImageWiderThanTheSideLimitIsRefusedForItsSize() throws {
        let archive = zipEntry(name: "model.usdc", content: [1, 2, 3, 4])
            + zipEntry(name: "0/texture.png", content: try realPNGBytes(side: 3))
        #expect(throws: RoomFurnitureModelLoadError(reason: "the USDZ has an image with no size or one larger than 2 pixels on a side")) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive, largestImageSide: 2)
        }
        try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive, largestImageSide: 3)
    }

    /// A real PNG of `side` by `side` pixels, so ImageIO reads its size from a header that matches its data.
    private func realPNGBytes(side: Int) throws -> [UInt8] {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try #require(context.makeImage())
        let encodedData = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(encodedData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return [UInt8](encodedData as Data)
    }

    @Test func aUSDZWithACompressedEntryIsRefused() throws {
        let archive = try usdzInMiniature(textureSide: 1, compressionMethodOfTheTexture: 8)
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive)
        }
    }

    @Test func aUSDZWithADataDescriptorIsRefused() throws {
        let archive = try usdzInMiniature(textureSide: 1, textureFlags: 0x08)
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive)
        }
    }

    @Test func aUSDZWhoseEntryRunsPastTheEndOfTheFileIsRefused() throws {
        let archive = try usdzInMiniature(textureSide: 1)
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive.dropLast(5))
        }
    }

    @Test func aUSDZWithMoreImagesOrMorePixelsThanTheCapsIsRefused() throws {
        let archive = try usdzInMiniature(textureSide: 1) + zipEntry(name: "1/texture.png", content: try pngBytes(declaredSide: 1))
        // Two one pixel images: the second passes an image cap of 1 and a pixel cap of 1.
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive, mostImages: 1)
        }
        #expect(throws: RoomFurnitureModelLoadError.self) {
            try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive, mostPixels: 1)
        }
        try RoomFurnitureModelLoading.checkTheUSDZsEntries(in: archive, mostImages: 2, mostPixels: 2)
    }
}
