//
//  GLBLoader.swift
//  leanring-buddy
//
//  A small glTF 2.0 binary (GLB) reader that builds a SceneKit node tree, since SceneKit cannot read GLB itself. Furniture
//  from a store page (IKEA publishes uncompressed GLB files) is drawn with it standing in the learner's room.
//
//  The bytes come from a web page, so every read is bounds checked, counts are capped, and anything the loader does not
//  understand throws a `GLBLoadError` instead of rendering something wrong. The caller then falls back to another path.
//
//  Supported: the GLB container, one embedded BIN buffer, float POSITION, NORMAL, and TEXCOORD_0, u8, u16, and u32
//  indices, strided buffer views, triangle primitives, node hierarchies (matrix or translation, rotation, scale), and
//  metallic-roughness PBR materials with embedded PNG or JPEG textures (base color, metallic-roughness, normal).
//
//  Refused: external or data URI buffers and images, any required extension (Draco, meshopt, quantization, basisu), a
//  Draco primitive, sparse or normalized accessors, non-triangle primitives, and files, counts, or images over the caps.
//

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SceneKit
import simd

/// Why a GLB could not be read. The text is for the log, never for the learner.
nonisolated struct GLBLoadError: Error, Equatable {
    let reason: String
}

nonisolated enum GLBLoader {
    /// The largest GLB the loader reads.
    static let largestFileByteCount = 40_000_000
    /// Caps on what one file may ask the loader to allocate, so a hostile file cannot exhaust memory.
    static let mostVerticesInAFile = 3_000_000
    static let mostIndicesInAFile = 9_000_000
    static let mostNodesInAFile = 100_000
    static let deepestNodeNesting = 64
    static let mostImagesDecodedFromAFile = 32
    static let largestImageSideInPixels = 4096

    /// A root node holding the whole scene of the GLB (the default scene, else scene 0, else every root node), in glTF's own
    /// units and axes (meters, y up, +z front). Throws GLBLoadError for anything it cannot read.
    static func rootNode(fromGLBData glbData: Data) throws -> SCNNode {
        let container = try GLBContainer(glbData: glbData)
        let document = try container.decodedDocument()
        let sceneBuilder = GLBSceneBuilder(document: document, binaryBuffer: container.binaryChunk)
        return try sceneBuilder.buildRootNode()
    }
}

// MARK: - Bytes

/// A window onto an array of bytes that refuses every read outside it.
private nonisolated struct ByteRegion {
    let storage: [UInt8]
    let startOffset: Int
    let byteCount: Int

    /// The part of this region at `offset` for `length` bytes, or a throw when it does not lie wholly inside the region.
    func subregion(atOffset offset: Int, length: Int, whatItHolds: String) throws -> ByteRegion {
        guard offset >= 0, length >= 0, offset <= byteCount, length <= byteCount - offset else {
            throw GLBLoadError(reason: "\(whatItHolds) reaches past the end of its data.")
        }
        return ByteRegion(storage: storage, startOffset: startOffset + offset, byteCount: length)
    }

    /// A little-endian unsigned integer of 1 to 4 bytes.
    func unsignedInteger(atOffset offset: Int, byteWidth: Int) throws -> UInt32 {
        guard byteWidth >= 1, byteWidth <= 4, offset >= 0, offset <= byteCount, byteWidth <= byteCount - offset else {
            throw GLBLoadError(reason: "A read went past the end of its data.")
        }
        var value: UInt32 = 0
        for byteIndex in 0..<byteWidth {
            value |= UInt32(storage[startOffset + offset + byteIndex]) << UInt32(8 * byteIndex)
        }
        return value
    }

    func data() -> Data {
        Data(storage[startOffset..<(startOffset + byteCount)])
    }
}

// MARK: - The container

/// The GLB container: a 12 byte header, a JSON chunk, and an optional BIN chunk.
private nonisolated struct GLBContainer {
    private static let glTFMagic: UInt32 = 0x4654_6C67
    private static let jsonChunkType: UInt32 = 0x4E4F_534A
    private static let binaryChunkType: UInt32 = 0x004E_4942
    private static let headerByteCount = 12
    private static let chunkHeaderByteCount = 8

    let jsonChunk: ByteRegion
    let binaryChunk: ByteRegion?

    init(glbData: Data) throws {
        guard glbData.count <= GLBLoader.largestFileByteCount else {
            throw GLBLoadError(reason: "The GLB is larger than \(GLBLoader.largestFileByteCount) bytes.")
        }
        let wholeFile = ByteRegion(storage: [UInt8](glbData), startOffset: 0, byteCount: glbData.count)
        guard glbData.count >= Self.headerByteCount + Self.chunkHeaderByteCount else {
            throw GLBLoadError(reason: "The file is too short to be a GLB.")
        }
        guard try wholeFile.unsignedInteger(atOffset: 0, byteWidth: 4) == Self.glTFMagic else {
            throw GLBLoadError(reason: "The file does not start with the glTF magic.")
        }
        let version = try wholeFile.unsignedInteger(atOffset: 4, byteWidth: 4)
        guard version == 2 else {
            throw GLBLoadError(reason: "The GLB is version \(version), and only version 2 is read.")
        }
        let declaredLength = try wholeFile.unsignedInteger(atOffset: 8, byteWidth: 4)
        guard Int(declaredLength) == glbData.count else {
            throw GLBLoadError(reason: "The GLB's declared length does not match its size.")
        }

        var foundJSONChunk: ByteRegion?
        var foundBinaryChunk: ByteRegion?
        var chunkOffset = Self.headerByteCount
        while chunkOffset < glbData.count {
            let chunkLength = Int(try wholeFile.unsignedInteger(atOffset: chunkOffset, byteWidth: 4))
            let chunkType = try wholeFile.unsignedInteger(atOffset: chunkOffset + 4, byteWidth: 4)
            guard chunkLength % 4 == 0 else {
                throw GLBLoadError(reason: "A GLB chunk is not padded to 4 bytes.")
            }
            let chunkBody = try wholeFile.subregion(
                atOffset: chunkOffset + Self.chunkHeaderByteCount,
                length: chunkLength,
                whatItHolds: "A GLB chunk"
            )
            if chunkType == Self.jsonChunkType {
                // The first chunk must be the JSON chunk, and there is only one.
                guard chunkOffset == Self.headerByteCount, foundJSONChunk == nil else {
                    throw GLBLoadError(reason: "The GLB's JSON chunk is not the first chunk.")
                }
                foundJSONChunk = chunkBody
            } else if chunkType == Self.binaryChunkType {
                // Only the first BIN chunk is the buffer. Chunks of other types are skipped, as the spec asks.
                if foundBinaryChunk == nil { foundBinaryChunk = chunkBody }
            }
            chunkOffset += Self.chunkHeaderByteCount + chunkLength
        }
        guard let foundJSONChunk else {
            throw GLBLoadError(reason: "The GLB has no JSON chunk.")
        }
        jsonChunk = foundJSONChunk
        binaryChunk = foundBinaryChunk
    }

    func decodedDocument() throws -> GLTFDocument {
        let document: GLTFDocument
        do {
            document = try JSONDecoder().decode(GLTFDocument.self, from: jsonChunk.data())
        } catch {
            throw GLBLoadError(reason: "The glTF JSON could not be read.")
        }
        if let requiredExtension = document.extensionsRequired?.first {
            throw GLBLoadError(reason: "The GLB requires the \(requiredExtension) extension, which is not supported.")
        }
        return document
    }
}

// MARK: - The glTF JSON

/// A JSON value the loader only needs to see exists, such as the body of an extension.
private nonisolated struct IgnoredJSONValue: Decodable {
    init(from decoder: Decoder) throws {}
}

private nonisolated struct GLTFDocument: Decodable {
    var extensionsRequired: [String]?
    var scene: Int?
    var scenes: [GLTFScene]?
    var nodes: [GLTFNode]?
    var meshes: [GLTFMesh]?
    var materials: [GLTFMaterial]?
    var textures: [GLTFTexture]?
    var images: [GLTFImage]?
    var samplers: [GLTFSampler]?
    var accessors: [GLTFAccessor]?
    var bufferViews: [GLTFBufferView]?
    var buffers: [GLTFBuffer]?
}

private nonisolated struct GLTFScene: Decodable {
    var nodes: [Int]?
}

private nonisolated struct GLTFNode: Decodable {
    var name: String?
    var children: [Int]?
    var mesh: Int?
    var matrix: [Double]?
    var translation: [Double]?
    var rotation: [Double]?
    var scale: [Double]?
}

private nonisolated struct GLTFMesh: Decodable {
    var primitives: [GLTFPrimitive]
}

private nonisolated struct GLTFPrimitive: Decodable {
    var attributes: [String: Int]
    var indices: Int?
    var material: Int?
    var mode: Int?
    var extensions: [String: IgnoredJSONValue]?
}

private nonisolated struct GLTFAccessor: Decodable {
    var bufferView: Int?
    var byteOffset: Int?
    var componentType: Int
    var normalized: Bool?
    var count: Int
    var type: String
    var sparse: IgnoredJSONValue?
}

private nonisolated struct GLTFBufferView: Decodable {
    var buffer: Int
    var byteOffset: Int?
    var byteLength: Int
    var byteStride: Int?
}

private nonisolated struct GLTFBuffer: Decodable {
    var byteLength: Int
    var uri: String?
}

private nonisolated struct GLTFTextureReference: Decodable {
    var index: Int
    var texCoord: Int?
    /// Only a normal texture has a scale.
    var scale: Double?
}

private nonisolated struct GLTFPBRMetallicRoughness: Decodable {
    var baseColorFactor: [Double]?
    var baseColorTexture: GLTFTextureReference?
    var metallicFactor: Double?
    var roughnessFactor: Double?
    var metallicRoughnessTexture: GLTFTextureReference?
}

private nonisolated struct GLTFMaterial: Decodable {
    var pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    var normalTexture: GLTFTextureReference?
    var alphaMode: String?
    var doubleSided: Bool?
}

private nonisolated struct GLTFTexture: Decodable {
    var sampler: Int?
    var source: Int?
}

private nonisolated struct GLTFImage: Decodable {
    var uri: String?
    var mimeType: String?
    var bufferView: Int?
}

private nonisolated struct GLTFSampler: Decodable {
    var wrapS: Int?
    var wrapT: Int?
}

// MARK: - Accessors

/// An accessor whose range was checked against its buffer view and the buffer, so every element read stays inside the buffer.
private nonisolated struct AccessorView {
    let bufferRegion: ByteRegion
    let firstElementOffset: Int
    let elementStride: Int
    let elementCount: Int
    let componentType: Int
    let componentCount: Int

    func floatComponent(elementIndex: Int, componentIndex: Int) throws -> Float {
        let offset = firstElementOffset + elementIndex * elementStride + componentIndex * 4
        return Float(bitPattern: try bufferRegion.unsignedInteger(atOffset: offset, byteWidth: 4))
    }

    func indexValue(elementIndex: Int) throws -> Int {
        let byteWidth = GLBComponentType.byteWidth(of: componentType) ?? 0
        let offset = firstElementOffset + elementIndex * elementStride
        return Int(try bufferRegion.unsignedInteger(atOffset: offset, byteWidth: byteWidth))
    }
}

private nonisolated enum GLBComponentType {
    static let unsignedByte = 5121
    static let unsignedShort = 5123
    static let unsignedInt = 5125
    static let float = 5126

    static func byteWidth(of componentType: Int) -> Int? {
        switch componentType {
        case 5120, 5121: return 1
        case 5122, 5123: return 2
        case 5125, 5126: return 4
        default: return nil
        }
    }

    static func componentCount(ofAccessorType accessorType: String) -> Int? {
        switch accessorType {
        case "SCALAR": return 1
        case "VEC2": return 2
        case "VEC3": return 3
        default: return nil
        }
    }
}

// MARK: - The scene

/// Turns a decoded document into SceneKit nodes. One builder serves one file, since it keeps the caches and the running
/// totals that the caps count.
private nonisolated final class GLBSceneBuilder {
    private let document: GLTFDocument
    private let binaryBuffer: ByteRegion?

    private var visitedNodeIndices: Set<Int> = []
    private var geometriesByMeshIndex: [Int: [SCNGeometry]] = [:]
    private var materialsByMaterialIndex: [Int: SCNMaterial] = [:]
    private var imagesByImageIndex: [Int: CGImage] = [:]
    private var totalVertexCount = 0
    private var totalIndexCount = 0

    init(document: GLTFDocument, binaryBuffer: ByteRegion?) {
        self.document = document
        self.binaryBuffer = binaryBuffer
    }

    // MARK: Nodes

    func buildRootNode() throws -> SCNNode {
        let nodes = document.nodes ?? []
        guard !nodes.isEmpty else {
            throw GLBLoadError(reason: "The GLB has no nodes.")
        }
        guard nodes.count <= GLBLoader.mostNodesInAFile else {
            throw GLBLoadError(reason: "The GLB has more than \(GLBLoader.mostNodesInAFile) nodes.")
        }

        let rootNode = SCNNode()
        rootNode.name = "glTF root"
        for sceneRootIndex in try sceneRootNodeIndices() {
            rootNode.addChildNode(try buildNode(nodeIndex: sceneRootIndex, depth: 0))
        }
        return rootNode
    }

    /// The default scene, else the first scene, else every node no other node lists as a child.
    private func sceneRootNodeIndices() throws -> [Int] {
        let scenes = document.scenes ?? []
        if let defaultSceneIndex = document.scene {
            guard scenes.indices.contains(defaultSceneIndex) else {
                throw GLBLoadError(reason: "The default scene does not exist.")
            }
            return scenes[defaultSceneIndex].nodes ?? []
        }
        if let firstScene = scenes.first {
            return firstScene.nodes ?? []
        }
        let nodes = document.nodes ?? []
        let indicesListedAsChildren = Set(nodes.flatMap { $0.children ?? [] })
        return nodes.indices.filter { !indicesListedAsChildren.contains($0) }
    }

    private func buildNode(nodeIndex: Int, depth: Int) throws -> SCNNode {
        guard depth <= GLBLoader.deepestNodeNesting else {
            throw GLBLoadError(reason: "The nodes are nested deeper than \(GLBLoader.deepestNodeNesting) levels.")
        }
        guard let nodes = document.nodes, nodes.indices.contains(nodeIndex) else {
            throw GLBLoadError(reason: "A node index does not exist.")
        }
        // glTF nodes form a forest, so a node reached twice is a cycle or a shared child, and both are refused.
        guard visitedNodeIndices.insert(nodeIndex).inserted else {
            throw GLBLoadError(reason: "A node is reached more than once, so the node graph is not a tree.")
        }

        let glTFNode = nodes[nodeIndex]
        let sceneKitNode = SCNNode()
        sceneKitNode.name = glTFNode.name
        sceneKitNode.simdTransform = try localTransform(of: glTFNode)

        if let meshIndex = glTFNode.mesh {
            let meshGeometries = try geometries(forMeshIndex: meshIndex)
            if meshGeometries.count == 1, let onlyGeometry = meshGeometries.first {
                sceneKitNode.geometry = onlyGeometry
            } else {
                for geometry in meshGeometries {
                    let primitiveNode = SCNNode(geometry: geometry)
                    sceneKitNode.addChildNode(primitiveNode)
                }
            }
        }
        for childIndex in glTFNode.children ?? [] {
            sceneKitNode.addChildNode(try buildNode(nodeIndex: childIndex, depth: depth + 1))
        }
        return sceneKitNode
    }

    private func localTransform(of node: GLTFNode) throws -> simd_float4x4 {
        if let matrix = node.matrix {
            let values = try finiteFloats(matrix, expectedCount: 16, whatItIs: "A node matrix")
            // glTF writes the matrix column by column.
            return simd_float4x4(columns: (
                SIMD4(values[0], values[1], values[2], values[3]),
                SIMD4(values[4], values[5], values[6], values[7]),
                SIMD4(values[8], values[9], values[10], values[11]),
                SIMD4(values[12], values[13], values[14], values[15])
            ))
        }

        var translationMatrix = matrix_identity_float4x4
        if let translation = node.translation {
            let values = try finiteFloats(translation, expectedCount: 3, whatItIs: "A node translation")
            translationMatrix.columns.3 = SIMD4(values[0], values[1], values[2], 1)
        }
        var rotationMatrix = matrix_identity_float4x4
        if let rotation = node.rotation {
            let values = try finiteFloats(rotation, expectedCount: 4, whatItIs: "A node rotation")
            // glTF writes a quaternion as x, y, z, w.
            let quaternion = simd_quatf(ix: values[0], iy: values[1], iz: values[2], r: values[3])
            guard simd_length(quaternion.vector) > 0 else {
                throw GLBLoadError(reason: "A node rotation is the zero quaternion.")
            }
            rotationMatrix = simd_float4x4(simd_normalize(quaternion))
        }
        var scaleMatrix = matrix_identity_float4x4
        if let scale = node.scale {
            let values = try finiteFloats(scale, expectedCount: 3, whatItIs: "A node scale")
            scaleMatrix = simd_float4x4(diagonal: SIMD4(values[0], values[1], values[2], 1))
        }
        return translationMatrix * rotationMatrix * scaleMatrix
    }

    private func finiteFloats(_ values: [Double], expectedCount: Int, whatItIs: String) throws -> [Float] {
        guard values.count == expectedCount, values.allSatisfy({ $0.isFinite }) else {
            throw GLBLoadError(reason: "\(whatItIs) does not hold \(expectedCount) finite numbers.")
        }
        return values.map { Float($0) }
    }

    // MARK: Meshes

    /// One geometry per primitive. A mesh that several nodes use is built once, so its caps count once.
    private func geometries(forMeshIndex meshIndex: Int) throws -> [SCNGeometry] {
        if let cachedGeometries = geometriesByMeshIndex[meshIndex] { return cachedGeometries }
        guard let meshes = document.meshes, meshes.indices.contains(meshIndex) else {
            throw GLBLoadError(reason: "A mesh index does not exist.")
        }
        let builtGeometries = try meshes[meshIndex].primitives.map { try geometry(forPrimitive: $0) }
        geometriesByMeshIndex[meshIndex] = builtGeometries
        return builtGeometries
    }

    private func geometry(forPrimitive primitive: GLTFPrimitive) throws -> SCNGeometry {
        // The Draco body is in a compressed buffer view, so the accessors below would read nothing real.
        if primitive.extensions?["KHR_draco_mesh_compression"] != nil {
            throw GLBLoadError(reason: "A primitive uses KHR_draco_mesh_compression, which is not supported.")
        }
        guard (primitive.mode ?? 4) == 4 else {
            throw GLBLoadError(reason: "A primitive is not made of triangles.")
        }
        guard let positionAccessorIndex = primitive.attributes["POSITION"] else {
            throw GLBLoadError(reason: "A primitive has no POSITION.")
        }

        let positionAccessor = try accessorView(
            accessorIndex: positionAccessorIndex,
            accessorType: "VEC3",
            allowedComponentTypes: [GLBComponentType.float]
        )
        let vertexCount = positionAccessor.elementCount
        guard totalVertexCount + vertexCount <= GLBLoader.mostVerticesInAFile else {
            throw GLBLoadError(reason: "The GLB has more than \(GLBLoader.mostVerticesInAFile) vertices.")
        }
        totalVertexCount += vertexCount

        let positions = try floatValues(of: positionAccessor)
        guard positions.allSatisfy({ $0.isFinite }) else {
            throw GLBLoadError(reason: "A position is not a finite number.")
        }

        var normals: [Float]?
        if let normalAccessorIndex = primitive.attributes["NORMAL"] {
            let normalAccessor = try accessorView(
                accessorIndex: normalAccessorIndex,
                accessorType: "VEC3",
                allowedComponentTypes: [GLBComponentType.float]
            )
            guard normalAccessor.elementCount == vertexCount else {
                throw GLBLoadError(reason: "NORMAL and POSITION hold different numbers of vertices.")
            }
            normals = try floatValues(of: normalAccessor)
        }

        var textureCoordinates: [Float]?
        if let textureCoordinateAccessorIndex = primitive.attributes["TEXCOORD_0"] {
            let textureCoordinateAccessor = try accessorView(
                accessorIndex: textureCoordinateAccessorIndex,
                accessorType: "VEC2",
                allowedComponentTypes: [GLBComponentType.float]
            )
            guard textureCoordinateAccessor.elementCount == vertexCount else {
                throw GLBLoadError(reason: "TEXCOORD_0 and POSITION hold different numbers of vertices.")
            }
            textureCoordinates = try floatValues(of: textureCoordinateAccessor)
        }

        let triangleIndices = try indices(forPrimitive: primitive, vertexCount: vertexCount)
        let vertexNormals = normals ?? Self.smoothNormals(positions: positions, triangleIndices: triangleIndices)

        var geometrySources = [
            SCNGeometrySource(
                data: Self.packedData(of: positions), semantic: .vertex, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12
            ),
            SCNGeometrySource(
                data: Self.packedData(of: vertexNormals), semantic: .normal, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12
            ),
        ]
        if let textureCoordinates {
            // glTF and SceneKit both put texture coordinate (0, 0) at the top left of the image (SceneKit's own SCNPlane has
            // v = 0 along its top edge), so the coordinates pass through unchanged. `GLBLoaderTests` pins this against SCNPlane.
            geometrySources.append(SCNGeometrySource(
                data: Self.packedData(of: textureCoordinates), semantic: .texcoord, vectorCount: vertexCount,
                usesFloatComponents: true, componentsPerVector: 2, bytesPerComponent: 4, dataOffset: 0, dataStride: 8
            ))
        }

        let geometryElement = SCNGeometryElement(
            data: Self.packedData(of: triangleIndices),
            primitiveType: .triangles,
            primitiveCount: triangleIndices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )
        let geometry = SCNGeometry(sources: geometrySources, elements: [geometryElement])
        geometry.materials = [try material(atMaterialIndex: primitive.material)]
        return geometry
    }

    private func indices(forPrimitive primitive: GLTFPrimitive, vertexCount: Int) throws -> [UInt32] {
        let triangleIndices: [UInt32]
        if let indexAccessorIndex = primitive.indices {
            let indexAccessor = try accessorView(
                accessorIndex: indexAccessorIndex,
                accessorType: "SCALAR",
                allowedComponentTypes: [GLBComponentType.unsignedByte, GLBComponentType.unsignedShort, GLBComponentType.unsignedInt]
            )
            guard totalIndexCount + indexAccessor.elementCount <= GLBLoader.mostIndicesInAFile else {
                throw GLBLoadError(reason: "The GLB has more than \(GLBLoader.mostIndicesInAFile) indices.")
            }
            totalIndexCount += indexAccessor.elementCount
            var readIndices: [UInt32] = []
            readIndices.reserveCapacity(indexAccessor.elementCount)
            for elementIndex in 0..<indexAccessor.elementCount {
                let vertexIndex = try indexAccessor.indexValue(elementIndex: elementIndex)
                guard vertexIndex < vertexCount else {
                    throw GLBLoadError(reason: "An index points past the vertices.")
                }
                readIndices.append(UInt32(vertexIndex))
            }
            triangleIndices = readIndices
        } else {
            guard totalIndexCount + vertexCount <= GLBLoader.mostIndicesInAFile else {
                throw GLBLoadError(reason: "The GLB has more than \(GLBLoader.mostIndicesInAFile) indices.")
            }
            totalIndexCount += vertexCount
            // A primitive with no indices draws its vertices in order.
            triangleIndices = (0..<vertexCount).map { UInt32($0) }
        }
        guard !triangleIndices.isEmpty, triangleIndices.count % 3 == 0 else {
            throw GLBLoadError(reason: "A primitive's index count is not a multiple of 3.")
        }
        return triangleIndices
    }

    /// Vertex normals for a primitive that has none: each triangle's area-weighted normal added to its corners.
    static func smoothNormals(positions: [Float], triangleIndices: [UInt32]) -> [Float] {
        let vertexCount = positions.count / 3
        var accumulatedNormals = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        func position(ofVertex vertexIndex: Int) -> SIMD3<Float> {
            SIMD3(positions[vertexIndex * 3], positions[vertexIndex * 3 + 1], positions[vertexIndex * 3 + 2])
        }
        for triangleStart in stride(from: 0, to: triangleIndices.count, by: 3) {
            let firstVertex = Int(triangleIndices[triangleStart])
            let secondVertex = Int(triangleIndices[triangleStart + 1])
            let thirdVertex = Int(triangleIndices[triangleStart + 2])
            // The cross product's length is twice the triangle's area, which weights big triangles more.
            let areaWeightedNormal = simd_cross(
                position(ofVertex: secondVertex) - position(ofVertex: firstVertex),
                position(ofVertex: thirdVertex) - position(ofVertex: firstVertex)
            )
            accumulatedNormals[firstVertex] += areaWeightedNormal
            accumulatedNormals[secondVertex] += areaWeightedNormal
            accumulatedNormals[thirdVertex] += areaWeightedNormal
        }
        var normals: [Float] = []
        normals.reserveCapacity(positions.count)
        for accumulatedNormal in accumulatedNormals {
            // A vertex on no real triangle gets an upward normal, since any unit vector lights it.
            let normal = simd_length_squared(accumulatedNormal) > 0 ? simd_normalize(accumulatedNormal) : SIMD3<Float>(0, 1, 0)
            normals.append(contentsOf: [normal.x, normal.y, normal.z])
        }
        return normals
    }

    private static func packedData<Element>(of values: [Element]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: Accessors

    private func accessorView(
        accessorIndex: Int,
        accessorType: String,
        allowedComponentTypes: [Int]
    ) throws -> AccessorView {
        guard let accessors = document.accessors, accessors.indices.contains(accessorIndex) else {
            throw GLBLoadError(reason: "An accessor index does not exist.")
        }
        let accessor = accessors[accessorIndex]
        guard accessor.sparse == nil else {
            throw GLBLoadError(reason: "A sparse accessor is not supported.")
        }
        guard accessor.normalized != true else {
            throw GLBLoadError(reason: "A normalized accessor is not supported.")
        }
        guard accessor.type == accessorType else {
            throw GLBLoadError(reason: "An accessor is \(accessor.type), where \(accessorType) is needed.")
        }
        guard allowedComponentTypes.contains(accessor.componentType),
              let componentByteWidth = GLBComponentType.byteWidth(of: accessor.componentType),
              let componentCount = GLBComponentType.componentCount(ofAccessorType: accessor.type) else {
            throw GLBLoadError(reason: "An accessor's component type \(accessor.componentType) is not supported there.")
        }
        // Indices are the largest accessors, so this cap only keeps the offset arithmetic far from overflow. The vertex and
        // index caps are counted where the primitive is built.
        guard accessor.count >= 1, accessor.count <= GLBLoader.mostIndicesInAFile else {
            throw GLBLoadError(reason: "An accessor's count is outside 1 to \(GLBLoader.mostIndicesInAFile).")
        }
        guard let bufferViewIndex = accessor.bufferView else {
            throw GLBLoadError(reason: "An accessor has no buffer view.")
        }

        let bufferViewRegion = try region(ofBufferViewIndex: bufferViewIndex)
        let bufferView = try bufferViewDescription(atIndex: bufferViewIndex)
        let elementByteWidth = componentByteWidth * componentCount
        let elementStride = bufferView.byteStride ?? elementByteWidth
        // A stride this large is not a vertex layout, and the cap keeps the offset arithmetic far from overflow.
        guard elementStride >= elementByteWidth, elementStride <= 1024 else {
            throw GLBLoadError(reason: "A buffer view's byte stride is not usable.")
        }
        let accessorByteOffset = accessor.byteOffset ?? 0
        guard accessorByteOffset >= 0, accessorByteOffset <= bufferViewRegion.byteCount else {
            throw GLBLoadError(reason: "An accessor starts outside its buffer view.")
        }
        let lastElementEnd = accessorByteOffset + (accessor.count - 1) * elementStride + elementByteWidth
        guard lastElementEnd <= bufferViewRegion.byteCount else {
            throw GLBLoadError(reason: "An accessor reads past the end of its buffer view.")
        }
        return AccessorView(
            bufferRegion: bufferViewRegion,
            firstElementOffset: accessorByteOffset,
            elementStride: elementStride,
            elementCount: accessor.count,
            componentType: accessor.componentType,
            componentCount: componentCount
        )
    }

    private func floatValues(of accessorView: AccessorView) throws -> [Float] {
        var values: [Float] = []
        values.reserveCapacity(accessorView.elementCount * accessorView.componentCount)
        for elementIndex in 0..<accessorView.elementCount {
            for componentIndex in 0..<accessorView.componentCount {
                values.append(try accessorView.floatComponent(elementIndex: elementIndex, componentIndex: componentIndex))
            }
        }
        return values
    }

    private func bufferViewDescription(atIndex bufferViewIndex: Int) throws -> GLTFBufferView {
        guard let bufferViews = document.bufferViews, bufferViews.indices.contains(bufferViewIndex) else {
            throw GLBLoadError(reason: "A buffer view index does not exist.")
        }
        return bufferViews[bufferViewIndex]
    }

    /// The bytes of one buffer view, which must lie inside the GLB's BIN buffer.
    private func region(ofBufferViewIndex bufferViewIndex: Int) throws -> ByteRegion {
        let bufferView = try bufferViewDescription(atIndex: bufferViewIndex)
        let bufferRegion = try glbBufferRegion(ofBufferIndex: bufferView.buffer)
        return try bufferRegion.subregion(
            atOffset: bufferView.byteOffset ?? 0,
            length: bufferView.byteLength,
            whatItHolds: "A buffer view"
        )
    }

    /// Only the GLB's own BIN chunk is a buffer. Buffers with a URI, which could name a file or a web address, are refused.
    private func glbBufferRegion(ofBufferIndex bufferIndex: Int) throws -> ByteRegion {
        guard let buffers = document.buffers, buffers.indices.contains(bufferIndex) else {
            throw GLBLoadError(reason: "A buffer index does not exist.")
        }
        let buffer = buffers[bufferIndex]
        guard buffer.uri == nil else {
            throw GLBLoadError(reason: "A buffer has a URI, and only the GLB's own binary chunk is read.")
        }
        guard bufferIndex == 0, let binaryBuffer else {
            throw GLBLoadError(reason: "A buffer is not the GLB's binary chunk.")
        }
        return try binaryBuffer.subregion(atOffset: 0, length: buffer.byteLength, whatItHolds: "The buffer")
    }

    // MARK: Materials

    /// A glTF material, or glTF's default material (white, metallic 1, roughness 1) when the primitive names none.
    private func material(atMaterialIndex materialIndex: Int?) throws -> SCNMaterial {
        let cacheKey = materialIndex ?? -1
        if let cachedMaterial = materialsByMaterialIndex[cacheKey] { return cachedMaterial }

        let glTFMaterial: GLTFMaterial
        if let materialIndex {
            guard let materials = document.materials, materials.indices.contains(materialIndex) else {
                throw GLBLoadError(reason: "A material index does not exist.")
            }
            glTFMaterial = materials[materialIndex]
        } else {
            glTFMaterial = GLTFMaterial()
        }

        let builtMaterial = try sceneKitMaterial(from: glTFMaterial)
        materialsByMaterialIndex[cacheKey] = builtMaterial
        return builtMaterial
    }

    private func sceneKitMaterial(from glTFMaterial: GLTFMaterial) throws -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.isDoubleSided = glTFMaterial.doubleSided ?? false

        let metallicRoughness = glTFMaterial.pbrMetallicRoughness ?? GLTFPBRMetallicRoughness()
        let alphaMode = glTFMaterial.alphaMode ?? "OPAQUE"
        guard ["OPAQUE", "MASK", "BLEND"].contains(alphaMode) else {
            throw GLBLoadError(reason: "A material's alpha mode \(alphaMode) is not known.")
        }
        let usesAlpha = alphaMode != "OPAQUE"

        // Base color. The factor is linear, as is SceneKit's working space, so a color without a texture is built in linear sRGB.
        let baseColorFactor = try finiteFloats(
            metallicRoughness.baseColorFactor ?? [1, 1, 1, 1], expectedCount: 4, whatItIs: "A base color factor"
        )
        if let baseColorReference = metallicRoughness.baseColorTexture {
            let baseColorTexture = try textureImage(for: baseColorReference)
            // An opaque material ignores the alpha of its texture, so the alpha is flattened away.
            material.diffuse.contents = usesAlpha ? baseColorTexture.image : Self.imageWithoutAlpha(baseColorTexture.image)
            Self.apply(baseColorTexture.sampler, to: material.diffuse)
            // With a texture the factor tints it. `multiply` applies the factor to the sampled color without touching the pixels.
            if baseColorFactor[0] != 1 || baseColorFactor[1] != 1 || baseColorFactor[2] != 1 {
                material.multiply.contents = Self.linearColor(red: baseColorFactor[0], green: baseColorFactor[1], blue: baseColorFactor[2])
            }
        } else {
            material.diffuse.contents = Self.linearColor(red: baseColorFactor[0], green: baseColorFactor[1], blue: baseColorFactor[2])
        }
        // SceneKit takes the opacity as one number, so the factor's alpha is kept as the material's transparency.
        material.transparency = usesAlpha ? CGFloat(baseColorFactor[3]) : 1

        let metallicFactor = metallicRoughness.metallicFactor ?? 1
        let roughnessFactor = metallicRoughness.roughnessFactor ?? 1
        guard metallicFactor.isFinite, roughnessFactor.isFinite else {
            throw GLBLoadError(reason: "A metallic or roughness factor is not a number.")
        }
        if let metallicRoughnessReference = metallicRoughness.metallicRoughnessTexture {
            let packedTexture = try textureImage(for: metallicRoughnessReference)
            // glTF packs roughness in green and metalness in blue, and SceneKit wants one grayscale image per property.
            material.roughness.contents = try Self.grayscaleImage(from: packedTexture.image, channelIndex: 1)
            material.metalness.contents = try Self.grayscaleImage(from: packedTexture.image, channelIndex: 2)
            Self.apply(packedTexture.sampler, to: material.roughness)
            Self.apply(packedTexture.sampler, to: material.metalness)
            // The factors scale the texture's values.
            material.roughness.intensity = CGFloat(roughnessFactor)
            material.metalness.intensity = CGFloat(metallicFactor)
        } else {
            material.roughness.contents = NSNumber(value: roughnessFactor)
            material.metalness.contents = NSNumber(value: metallicFactor)
        }

        if let normalReference = glTFMaterial.normalTexture {
            let normalTexture = try textureImage(for: normalReference)
            material.normal.contents = normalTexture.image
            Self.apply(normalTexture.sampler, to: material.normal)
            material.normal.intensity = CGFloat(normalReference.scale ?? 1)
        }
        return material
    }

    private static func linearColor(red: Float, green: Float, blue: Float) -> NSColor {
        guard let linearColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
              let cgColor = CGColor(colorSpace: linearColorSpace, components: [CGFloat(red), CGFloat(green), CGFloat(blue), 1]) else {
            return NSColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
        }
        return NSColor(cgColor: cgColor) ?? NSColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    // MARK: Textures

    private func textureImage(for reference: GLTFTextureReference) throws -> (image: CGImage, sampler: GLTFSampler?) {
        guard (reference.texCoord ?? 0) == 0 else {
            throw GLBLoadError(reason: "A texture uses a texture coordinate set other than TEXCOORD_0.")
        }
        guard let textures = document.textures, textures.indices.contains(reference.index) else {
            throw GLBLoadError(reason: "A texture index does not exist.")
        }
        let texture = textures[reference.index]
        guard let imageIndex = texture.source else {
            throw GLBLoadError(reason: "A texture has no image.")
        }
        var sampler: GLTFSampler?
        if let samplerIndex = texture.sampler {
            guard let samplers = document.samplers, samplers.indices.contains(samplerIndex) else {
                throw GLBLoadError(reason: "A sampler index does not exist.")
            }
            sampler = samplers[samplerIndex]
        }
        return (try decodedImage(atImageIndex: imageIndex), sampler)
    }

    /// An embedded PNG or JPEG, decoded once however many materials use it. Its size is read before it is decoded, since a
    /// small file can hold a very large image.
    private func decodedImage(atImageIndex imageIndex: Int) throws -> CGImage {
        if let cachedImage = imagesByImageIndex[imageIndex] { return cachedImage }
        guard imagesByImageIndex.count < GLBLoader.mostImagesDecodedFromAFile else {
            throw GLBLoadError(reason: "The GLB uses more than \(GLBLoader.mostImagesDecodedFromAFile) images.")
        }
        guard let images = document.images, images.indices.contains(imageIndex) else {
            throw GLBLoadError(reason: "An image index does not exist.")
        }
        let image = images[imageIndex]
        guard image.uri == nil else {
            throw GLBLoadError(reason: "An image has a URI, and only images inside the GLB are read.")
        }
        guard let bufferViewIndex = image.bufferView else {
            throw GLBLoadError(reason: "An image has no buffer view.")
        }
        let expectedImageTypeIdentifier: String
        switch image.mimeType {
        case "image/png": expectedImageTypeIdentifier = "public.png"
        case "image/jpeg": expectedImageTypeIdentifier = "public.jpeg"
        default: throw GLBLoadError(reason: "An image is not a PNG or a JPEG.")
        }

        let imageBytes = try region(ofBufferViewIndex: bufferViewIndex).data()
        guard let imageSource = CGImageSourceCreateWithData(imageBytes as CFData, nil),
              CGImageSourceGetCount(imageSource) >= 1,
              CGImageSourceGetType(imageSource) as String? == expectedImageTypeIdentifier else {
            throw GLBLoadError(reason: "An image's bytes are not the \(image.mimeType ?? "") it says.")
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth >= 1, pixelHeight >= 1,
              pixelWidth <= GLBLoader.largestImageSideInPixels, pixelHeight <= GLBLoader.largestImageSideInPixels else {
            throw GLBLoadError(reason: "An image is missing a size or is larger than \(GLBLoader.largestImageSideInPixels) pixels on a side.")
        }
        guard let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw GLBLoadError(reason: "An image could not be decoded.")
        }
        imagesByImageIndex[imageIndex] = decodedImage
        return decodedImage
    }

    private static func apply(_ sampler: GLTFSampler?, to property: SCNMaterialProperty) {
        // Without a sampler glTF repeats the texture, and SceneKit's own default is to clamp.
        property.wrapS = wrapMode(forGLTFWrap: sampler?.wrapS)
        property.wrapT = wrapMode(forGLTFWrap: sampler?.wrapT)
        // Mipmaps keep a far away texture from shimmering.
        property.mipFilter = .linear
    }

    private static func wrapMode(forGLTFWrap glTFWrap: Int?) -> SCNWrapMode {
        switch glTFWrap {
        case 33071: return .clamp
        case 33648: return .mirror
        default: return .repeat
        }
    }

    // MARK: Pixels

    /// The image drawn over a black opaque background, so its alpha no longer counts.
    private static func imageWithoutAlpha(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return image
        default:
            break
        }
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// One channel of an image (0 red, 1 green, 2 blue) as a grayscale image of linear values, since a metalness or roughness
    /// map holds data and not a color.
    private static func grayscaleImage(from image: CGImage, channelIndex: Int) throws -> CGImage {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        // The image's own color space keeps its values as written, where drawing into another could convert them.
        let rgbColorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var rgbaPixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drewTheImage = rgbaPixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
            guard let context = CGContext(
                data: pixelBuffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: rgbColorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drewTheImage else {
            throw GLBLoadError(reason: "A metallic-roughness image could not be read.")
        }

        var channelValues = [UInt8](repeating: 0, count: width * height)
        for pixelIndex in 0..<(width * height) {
            channelValues[pixelIndex] = rgbaPixels[pixelIndex * 4 + channelIndex]
        }
        let grayColorSpace = CGColorSpace(name: CGColorSpace.linearGray) ?? CGColorSpaceCreateDeviceGray()
        guard let dataProvider = CGDataProvider(data: Data(channelValues) as CFData),
              let grayscaleImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                space: grayColorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: dataProvider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            throw GLBLoadError(reason: "A metallic-roughness channel could not be made.")
        }
        return grayscaleImage
    }
}
