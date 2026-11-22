//
//  RoomFurnitureModelLoading.swift
//  leanring-buddy
//
//  Turns a model file into a SceneKit node tree the renderer can stand in the room: a USDZ through SceneKit's own reader,
//  and an uncompressed GLB through `GLBLoader`. It also finds the store's own model in Chrome's front tab
//  (`RoomFurnitureDiscovery`) and loads it, which is the first of the furniture's looks.
//

import Foundation
import SceneKit

/// A model ready to render, and which look it is.
nonisolated struct RoomFurnitureLoadedModel: @unchecked Sendable {
    // @unchecked: the node tree is built once here and only read afterward, by the renderer's queue.
    let rootNode: SCNNode
    let look: RoomFurnitureLook
    /// Where the file came from, for the log: a host, or "generated".
    let originForTheLog: String
}

nonisolated struct RoomFurnitureModelLoadError: Error, Equatable {
    let reason: String
}

nonisolated enum RoomFurnitureModelLoading {
    /// The model in `fileData` as a node tree in its own units and axes. SceneKit reads a USDZ only from a file whose name
    /// ends in .usdz, so the bytes go to a temporary file first, which is removed after the read. Throws for a file that
    /// does not read or holds no geometry.
    static func rootNode(fromFileData fileData: Data, kind: RoomFurnitureModelFileKind) throws -> SCNNode {
        let rootNode: SCNNode
        switch kind {
        case .glb:
            rootNode = try GLBLoader.rootNode(fromGLBData: fileData)
        case .usdz:
            let temporaryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-room-furniture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryFolder) }
            let modelFile = temporaryFolder.appendingPathComponent("model.usdz")
            try fileData.write(to: modelFile)
            let scene = try SCNScene(url: modelFile, options: [.checkConsistency: false])
            rootNode = SCNNode()
            // The scene's root itself stays behind, so its children move to a node the renderer owns.
            for childNode in scene.rootNode.childNodes {
                childNode.removeFromParentNode()
                rootNode.addChildNode(childNode)
            }
        }
        // A file with cameras or lights of its own would light or frame the render its way, so they are removed.
        rootNode.enumerateHierarchy { node, _ in
            node.camera = nil
            node.light = nil
        }
        guard RoomFurnitureRenderer.boundingBox(of: rootNode) != nil else {
            throw RoomFurnitureModelLoadError(reason: "the model has no geometry")
        }
        return rootNode
    }

    /// The store's own model of the item in Chrome's front tab, downloaded and loaded, or nil when the page offers none this
    /// app can read (no model, only a Draco GLB, a download that failed, or a file that does not load). `pageURL` is the page
    /// the panel read, so a tab that changed since then is not searched.
    @MainActor
    static func findTheStoreModel(onThePageAt pageURL: String) async -> RoomFurnitureLoadedModel? {
        guard let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow(), frontTab.url == pageURL else {
            print("Room furniture: the front tab is no longer the page that was read, so no store model is searched")
            return nil
        }
        // The script may fetch a Shopify store's product data synchronously, so it gets longer than the default 2 seconds.
        let scriptResult = try? ChromeVideoTab.runJavaScript(roomFurnitureModelDiscoveryScript, in: frontTab, timeoutSeconds: 8)
        let candidates = RoomFurnitureModelCandidate.parse(discoveryScriptResult: scriptResult)
        let ranking = rankedModelCandidates(candidates)
        print("Room furniture: the page names \(candidates.count) model files, \(ranking.candidatesToTry.count) worth trying, \(ranking.droppedBecauseOfDracoCount) Draco only")
        guard !ranking.candidatesToTry.isEmpty,
              let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: candidates) else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> RoomFurnitureLoadedModel? in
            do {
                let rootNode = try rootNode(fromFileData: modelFile.data, kind: modelFile.kind)
                return RoomFurnitureLoadedModel(rootNode: rootNode, look: .storeModel, originForTheLog: modelFile.url.host ?? "the store")
            } catch {
                print("Room furniture: the store's \(modelFile.kind) from \(modelFile.url.host ?? "the store") did not load: \(error)")
                return nil
            }
        }.value
    }
}
