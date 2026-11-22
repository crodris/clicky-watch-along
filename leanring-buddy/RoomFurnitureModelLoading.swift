//
//  RoomFurnitureModelLoading.swift
//  leanring-buddy
//
//  Turns a model file into a SceneKit node tree the renderer can stand in the room: a USDZ through SceneKit's own reader,
//  and an uncompressed GLB through `GLBLoader`. It also finds the store's own model in Chrome's front tab
//  (`RoomFurnitureDiscovery`) and loads it, which is the first of the furniture's looks.
//

import Foundation
import ImageIO
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
    /// A loaded model may hold at most this many nodes and vertices, the caps `GLBLoader` holds a GLB to, so a store's USDZ
    /// that SceneKit read cannot make the render allocate without bound.
    static let mostNodesInAModel = GLBLoader.mostNodesInAFile
    static let mostVerticesInAModel = GLBLoader.mostVerticesInAFile

    /// The model in `fileData` as a node tree in its own units and axes. SceneKit reads a USDZ only from a file whose name
    /// ends in .usdz, so the bytes go to a temporary file first, which is removed after the read. Throws for a file that
    /// does not read or holds no geometry.
    static func rootNode(fromFileData fileData: Data, kind: RoomFurnitureModelFileKind) throws -> SCNNode {
        let rootNode: SCNNode
        switch kind {
        case .glb:
            rootNode = try GLBLoader.rootNode(fromGLBData: fileData)
        case .usdz:
            // SceneKit decodes a USDZ's textures at whatever size their headers declare, so the ZIP's entries are checked
            // against the image caps `GLBLoader` holds a GLB to before SceneKit sees the file.
            try checkTheUSDZsEntries(in: fileData)
            let temporaryFolder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-room-furniture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryFolder) }
            let modelFile = temporaryFolder.appendingPathComponent("model.usdz")
            try fileData.write(to: modelFile)
            // SceneKit's own USD parser reads the store's file, so it checks the file's consistency as it reads, and the
            // counts are capped below. The page's GLB is preferred over its USDZ for the same reason.
            let scene = try SCNScene(url: modelFile, options: [.checkConsistency: true])
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
        try checkTheCounts(of: rootNode)
        guard RoomFurnitureRenderer.boundingBox(of: rootNode) != nil else {
            throw RoomFurnitureModelLoadError(reason: "the model has no geometry")
        }
        return rootNode
    }

    /// The most entries a USDZ may hold, which is far more than a product's model and its textures need.
    static let mostEntriesInAUSDZ = 4096

    /// Refuses a USDZ whose ZIP could make SceneKit allocate without bound, before SceneKit reads it. It walks the local file
    /// headers the way `RoomFurnitureModelFileKind.sniff` does, and refuses an entry that is compressed (a USDZ stores every
    /// entry as is, so a compressed one is not a USDZ), an entry with a data descriptor (its size is not in its header, so it
    /// cannot be walked past), an entry whose data runs past the file, an image that is larger than `largestImageSide` on a
    /// side, and images that number more than `mostImages` or hold more than `mostPixels` in all. An image's size is read from
    /// its header with `CGImageSource` and never decoded here.
    static func checkTheUSDZsEntries(
        in fileData: Data,
        largestImageSide: Int = GLBLoader.largestImageSideInPixels,
        mostImages: Int = GLBLoader.mostImagesDecodedFromAFile,
        mostPixels: Int = GLBLoader.mostPixelsDecodedAndDerived
    ) throws {
        let localFileHeaderSignature = 0x0403_4B50
        let fixedHeaderByteCount = 30
        // Slices of `Data` keep their parent's indices, so offsets here count from the first byte of the file.
        let fileBytes = Data(fileData)
        var headerOffset = 0
        var entryCount = 0
        var imageCount = 0
        var totalPixelCount = 0
        func littleEndianValue(at offset: Int, byteCount: Int) -> Int {
            (0..<byteCount).reduce(0) { value, byteIndex in value | Int(fileBytes[offset + byteIndex]) << (8 * byteIndex) }
        }
        while headerOffset + 4 <= fileBytes.count, littleEndianValue(at: headerOffset, byteCount: 4) == localFileHeaderSignature {
            entryCount += 1
            guard entryCount <= mostEntriesInAUSDZ else {
                throw RoomFurnitureModelLoadError(reason: "the USDZ has more than \(mostEntriesInAUSDZ) entries")
            }
            guard headerOffset + fixedHeaderByteCount <= fileBytes.count else {
                throw RoomFurnitureModelLoadError(reason: "the USDZ ends inside an entry's header")
            }
            let flags = littleEndianValue(at: headerOffset + 6, byteCount: 2)
            let compressionMethod = littleEndianValue(at: headerOffset + 8, byteCount: 2)
            let storedByteCount = littleEndianValue(at: headerOffset + 18, byteCount: 4)
            let nameByteCount = littleEndianValue(at: headerOffset + 26, byteCount: 2)
            let extraByteCount = littleEndianValue(at: headerOffset + 28, byteCount: 2)
            guard compressionMethod == 0 else {
                throw RoomFurnitureModelLoadError(reason: "the USDZ has a compressed entry, and a USDZ stores its entries uncompressed")
            }
            guard flags & 0x08 == 0 else {
                throw RoomFurnitureModelLoadError(reason: "the USDZ has an entry with a data descriptor, so its size cannot be read")
            }
            let entryDataStart = headerOffset + fixedHeaderByteCount + nameByteCount + extraByteCount
            guard entryDataStart + storedByteCount <= fileBytes.count else {
                throw RoomFurnitureModelLoadError(reason: "the USDZ has an entry whose data runs past the end of the file")
            }
            let entryData = fileBytes.subdata(in: entryDataStart..<(entryDataStart + storedByteCount))
            if let imageSource = CGImageSourceCreateWithData(entryData as CFData, nil), CGImageSourceGetCount(imageSource) >= 1 {
                guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                      let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int,
                      let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int,
                      pixelWidth >= 1, pixelHeight >= 1, pixelWidth <= largestImageSide, pixelHeight <= largestImageSide else {
                    throw RoomFurnitureModelLoadError(reason: "the USDZ has an image with no size or one larger than \(largestImageSide) pixels on a side")
                }
                imageCount += 1
                totalPixelCount += pixelWidth * pixelHeight
                guard imageCount <= mostImages else {
                    throw RoomFurnitureModelLoadError(reason: "the USDZ has more than \(mostImages) images")
                }
                guard totalPixelCount <= mostPixels else {
                    throw RoomFurnitureModelLoadError(reason: "the USDZ's images hold more than \(mostPixels) pixels")
                }
            }
            headerOffset = entryDataStart + storedByteCount
        }
        guard entryCount > 0 else {
            throw RoomFurnitureModelLoadError(reason: "the USDZ has no readable entries")
        }
    }

    /// Refuses a model with more nodes or vertices than the caps, before anything renders it.
    static func checkTheCounts(of rootNode: SCNNode, mostNodesInAModel: Int = mostNodesInAModel, mostVerticesInAModel: Int = mostVerticesInAModel) throws {
        var nodeCount = 0, vertexCount = 0
        rootNode.enumerateHierarchy { node, stop in
            nodeCount += 1
            vertexCount += node.geometry?.sources(for: .vertex).first?.vectorCount ?? 0
            if nodeCount > mostNodesInAModel || vertexCount > mostVerticesInAModel { stop.pointee = true }
        }
        guard nodeCount <= mostNodesInAModel else {
            throw RoomFurnitureModelLoadError(reason: "the model has more than \(mostNodesInAModel) nodes")
        }
        guard vertexCount <= mostVerticesInAModel else {
            throw RoomFurnitureModelLoadError(reason: "the model has more than \(mostVerticesInAModel) vertices")
        }
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
        let candidatesThePageNamed = RoomFurnitureModelCandidate.parse(discoveryScriptResult: scriptResult)
        // A filter on which files the page may offer (its own domain, or a file its own script says it loaded), not a boundary:
        // the download follows a redirect to any public https host.
        let candidates = URL(string: pageURL).map { candidatesThePageMayOffer(candidatesThePageNamed, pageURL: $0) } ?? []
        let ranking = rankedModelCandidates(candidates)
        print("Room furniture: the page names \(candidatesThePageNamed.count) model files, \(candidatesThePageNamed.count - candidates.count) on other hosts, \(ranking.candidatesToTry.count) worth trying, \(ranking.droppedBecauseOfDracoCount) Draco only")
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
