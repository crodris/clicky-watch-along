//
//  RoomFurnitureModelLoadingTests.swift
//  leanring-buddyTests
//
//  Loading a model file for the room: a USDZ reads through SceneKit with its consistency checked, and a model past the node
//  or vertex caps is refused before it renders.
//

import Foundation
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
}
