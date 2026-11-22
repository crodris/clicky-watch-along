//
//  RoomFurnitureModelLoadingTests.swift
//  leanring-buddyTests
//
//  Loading a model file for the room: a model past the node or vertex caps is refused before it renders. Only a GLB loads,
//  through `GLBLoader`, whose own tests cover the file format.
//

import Foundation
import SceneKit
import Testing
@testable import Clicky

struct RoomFurnitureModelLoadingTests {
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
