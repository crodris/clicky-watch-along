//
//  RoomFurnitureDiscoveryTests.swift
//  leanring-buddyTests
//
//  How room art finds a store's own 3D model of a piece of furniture: the page scripts are safe to paste into an AppleScript
//  string, the script's reply is parsed at the boundary (https and public hosts only, each URL once), the candidates are ranked
//  (USDZ, then GLB, then unknown, with Draco and .gltf files left out), the downloaded bytes are sniffed as GLB or USDZ, and
//  the download takes the first usable file against a stubbed host (a failed or oversized or wrong or Draco file is skipped,
//  and at most 4 files are tried).
//

import Foundation
import os
import Testing
@testable import Clicky

// MARK: - Fixtures

/// Answers requests to `https://models.stub/<path>` with the reply a test set for that path, and counts the requests.
private final class StubbedModelURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case file(Data)
        /// A reply whose headers say the file is `declaredByteCount` bytes long, whatever the body is.
        case fileDeclaring(byteCount: Int, Data)
        case status(Int)
    }

    static let replies = OSAllocatedUnfairLock<[String: Reply]>(initialState: [:])
    static let requestedPaths = OSAllocatedUnfairLock<[String]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "models.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requestedPaths.withLock { requestedPaths in requestedPaths.append(url.path) }
        guard let reply = Self.replies.withLock({ replies in replies[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch reply {
        case .file(let fileData):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(fileData.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fileData)
            client?.urlProtocolDidFinishLoading(self)
        case .fileDeclaring(let declaredByteCount, let fileData):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": String(declaredByteCount)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: fileData)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let statusCode):
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Little endian bytes of `value`, the byte order of ZIP and GLB headers.
private func littleEndianBytes(_ value: Int, byteCount: Int) -> [UInt8] {
    (0..<byteCount).map { byteIndex in UInt8((value >> (8 * byteIndex)) & 0xFF) }
}

/// One stored (uncompressed) ZIP entry, local file header and data, which is how a USDZ holds each file.
private func zipEntry(name: String, content: [UInt8]) -> Data {
    var entry: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    entry += littleEndianBytes(20, byteCount: 2)  // version needed
    entry += littleEndianBytes(0, byteCount: 2)  // flags
    entry += littleEndianBytes(0, byteCount: 2)  // method: stored
    entry += littleEndianBytes(0, byteCount: 4)  // time and date
    entry += littleEndianBytes(0, byteCount: 4)  // crc, which the sniff never checks
    entry += littleEndianBytes(content.count, byteCount: 4)  // stored size
    entry += littleEndianBytes(content.count, byteCount: 4)  // full size
    entry += littleEndianBytes(name.utf8.count, byteCount: 2)
    entry += littleEndianBytes(0, byteCount: 2)  // extra field size
    entry += Array(name.utf8) + content
    return Data(entry)
}

/// A USDZ in miniature: a ZIP whose first entry is a texture and whose second is the USD layer.
private func tinyUSDZData(layerName: String = "model.usdc") -> Data {
    zipEntry(name: "0/texture.jpg", content: [1, 2, 3]) + zipEntry(name: layerName, content: [4, 5, 6, 7])
}

/// A GLB in miniature: the 12 byte header and one JSON chunk holding `jsonText`.
private func tinyGLBData(jsonText: String) -> Data {
    var jsonBytes = Array(jsonText.utf8)
    while jsonBytes.count % 4 != 0 { jsonBytes.append(0x20) }
    var glb: [UInt8] = Array("glTF".utf8)
    glb += littleEndianBytes(2, byteCount: 4)
    glb += littleEndianBytes(12 + 8 + jsonBytes.count, byteCount: 4)
    glb += littleEndianBytes(jsonBytes.count, byteCount: 4)
    glb += [0x4A, 0x53, 0x4F, 0x4E]
    glb += jsonBytes
    return Data(glb)
}

private let plainGLBJSON = #"{"asset":{"version":"2.0"},"extensionsUsed":["KHR_materials_unlit"]}"#
private let dracoGLBJSON = #"{"asset":{"version":"2.0"},"extensionsUsed":["KHR_draco_mesh_compression"],"extensionsRequired":["KHR_draco_mesh_compression"]}"#

private func candidate(
    _ urlText: String,
    claimedType: RoomFurnitureClaimedModelType,
    looksLikeDraco: Bool = false,
    source: String = "html"
) -> RoomFurnitureModelCandidate {
    RoomFurnitureModelCandidate(url: URL(string: urlText)!, source: source, claimedType: claimedType, looksLikeDraco: looksLikeDraco)
}

// MARK: - Tests

struct RoomFurnitureDiscoveryTests {
    // MARK: Page scripts

    @Test(arguments: [
        roomFurnitureModelDiscoveryScript,
        roomArtExpandTheSizeSectionsScript,
        roomArtPageTextScript(longestCharacters: 30_000),
    ])
    func pageScriptHasNoDoubleQuoteAndNoBackslash(script: String) {
        // The script sits inside an AppleScript string literal, where either character would end or twist the string.
        #expect(!script.contains("\""))
        #expect(!script.contains("\\"))
    }

    @Test func pageTextScriptCutsToTheRequestedLength() {
        #expect(roomArtPageTextScript(longestCharacters: 1234).contains(".slice(0, 1234)"))
    }

    // MARK: Parsing the discovery reply

    @Test func parseKeepsOnlyHTTPSURLsOnPublicHosts() {
        let reply = """
        [{"url":"https://models.example.com/a.glb","source":"html","type":""},
         {"url":"http://models.example.com/b.glb","source":"html","type":""},
         {"url":"https://localhost/c.glb","source":"html","type":""},
         {"url":"https://127.0.0.1/d.glb","source":"html","type":""},
         {"url":"https://192.168.1.20/e.glb","source":"html","type":""},
         {"url":"https://printer.local/f.glb","source":"html","type":""},
         {"url":"javascript:alert(1)","source":"html","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.url.absoluteString) == ["https://models.example.com/a.glb"])
    }

    @Test func parseKeepsEachURLOnceInTheOrderTheScriptFoundIt() {
        let reply = """
        [{"url":"https://models.example.com/b.usdz","source":"ar-link","type":""},
         {"url":"https://models.example.com/a.glb","source":"html","type":""},
         {"url":"https://models.example.com/b.usdz","source":"resource","type":""}]
        """
        let candidates = RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply)
        #expect(candidates.map(\.url.lastPathComponent) == ["b.usdz", "a.glb"])
        #expect(candidates.first?.source == "ar-link")
    }

    @Test(arguments: [nil, "", "none", "not json", #"{"url":"https://models.example.com/a.glb"}"#, #"[{"source":"html"}]"#])
    func parseGivesNothingForAReplyThatIsNotTheScriptsList(reply: String?) {
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).isEmpty)
    }

    @Test func parseReadsTheTypeFromTheURLBeforeTheStoresClaim() {
        let reply = """
        [{"url":"https://models.example.com/a.glb","source":"json-ld","type":"model/vnd.usdz+zip"},
         {"url":"https://models.example.com/b.usdz","source":"html","type":""},
         {"url":"https://models.example.com/c.gltf","source":"html","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.claimedType) == [.glb, .usdz, .gltf])
    }

    @Test func parseReadsAnExtensionlessURLsTypeFromItsQueryOrTheStoresClaim() {
        let reply = """
        [{"url":"https://cdn.example.com/WKbnY0s?dl=sven-sofa.usdz","source":"html","type":""},
         {"url":"https://cdn.example.com/abc123","source":"shopify","type":"glb model/gltf-binary"},
         {"url":"https://cdn.example.com/def456","source":"product-data-hint","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.claimedType) == [.usdz, .glb, .unknown])
    }

    @Test func parseFlagsAPathThatSaysDraco() {
        let reply = """
        [{"url":"https://web-api.example.com/assets/glb_draco/chair.glb","source":"html","type":""},
         {"url":"https://web-api.example.com/assets/glb/chair.glb","source":"html","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.looksLikeDraco) == [true, false])
    }

    // MARK: Ranking

    @Test func rankingPutsUSDZFirstThenGLBThenUnknownInTheScriptsOrder() {
        let ranking = rankedModelCandidates([
            candidate("https://m.example.com/unknown-1", claimedType: .unknown),
            candidate("https://m.example.com/glb-1.glb", claimedType: .glb),
            candidate("https://m.example.com/usdz-1.usdz", claimedType: .usdz),
            candidate("https://m.example.com/glb-2.glb", claimedType: .glb),
            candidate("https://m.example.com/usdz-2.usdz", claimedType: .usdz),
        ])
        #expect(ranking.candidatesToTry.map(\.url.lastPathComponent) == ["usdz-1.usdz", "usdz-2.usdz", "glb-1.glb", "glb-2.glb", "unknown-1"])
    }

    @Test func rankingLeavesOutDracoFilesAndGltfFilesAndCountsThem() {
        let ranking = rankedModelCandidates([
            candidate("https://m.example.com/draco.glb", claimedType: .glb, looksLikeDraco: true),
            candidate("https://m.example.com/unknown-draco", claimedType: .unknown, looksLikeDraco: true),
            candidate("https://m.example.com/scene.gltf", claimedType: .gltf),
            candidate("https://m.example.com/plain.glb", claimedType: .glb),
        ])
        #expect(ranking.candidatesToTry.map(\.url.lastPathComponent) == ["plain.glb"])
        #expect(ranking.droppedBecauseOfDracoCount == 2)
        #expect(ranking.droppedBecauseOfGltfCount == 1)
    }

    // MARK: Sniffing

    @Test func sniffReadsGLBFromItsMagic() {
        #expect(RoomFurnitureModelFileKind.sniff(tinyGLBData(jsonText: plainGLBJSON)) == .glb)
    }

    @Test func sniffReadsUSDZFromAZipWithAUSDLayer() {
        #expect(RoomFurnitureModelFileKind.sniff(tinyUSDZData()) == .usdz)
        #expect(RoomFurnitureModelFileKind.sniff(tinyUSDZData(layerName: "Scene.USDA")) == .usdz)
    }

    @Test func sniffRefusesAZipWithNoUSDLayer() {
        let plainZip = zipEntry(name: "readme.txt", content: [1]) + zipEntry(name: "photo.jpg", content: [2, 3])
        #expect(RoomFurnitureModelFileKind.sniff(plainZip) == nil)
    }

    @Test func sniffFindsTheUSDLayerInASliceOfLargerData() {
        // `Data` slices keep their parent's indices, so the sniff must not assume the first byte is at index 0.
        let paddedZip = Data([9, 9, 9]) + tinyUSDZData()
        #expect(RoomFurnitureModelFileKind.sniff(paddedZip.dropFirst(3)) == .usdz)
    }

    @Test(arguments: ["", "<html>not found</html>", "glT", "PK"])
    func sniffRefusesBytesThatAreNeitherModelFormat(text: String) {
        #expect(RoomFurnitureModelFileKind.sniff(Data(text.utf8)) == nil)
    }

    @Test func sniffDoesNotTrustATruncatedZipHeader() {
        #expect(RoomFurnitureModelFileKind.sniff(tinyUSDZData().prefix(20)) == nil)
    }

    // MARK: Draco

    @Test func glbRequiresDracoWhenItsJSONNamesTheExtension() {
        #expect(glbRequiresDraco(tinyGLBData(jsonText: dracoGLBJSON)))
        #expect(glbRequiresDraco(tinyGLBData(jsonText: #"{"extensionsUsed":["KHR_draco_mesh_compression"]}"#)))
    }

    @Test func glbWithoutTheDracoExtensionDoesNotRequireIt() {
        #expect(!glbRequiresDraco(tinyGLBData(jsonText: plainGLBJSON)))
    }

    @Test func glbRequiresDracoIsFalseForBytesThatAreNotAReadableGLB() {
        #expect(!glbRequiresDraco(tinyUSDZData()))
        #expect(!glbRequiresDraco(Data("glTF".utf8)))
        #expect(!glbRequiresDraco(tinyGLBData(jsonText: "not json")))
    }
}

// MARK: - Downloading

struct RoomFurnitureDownloadTests {
    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedModelURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// A candidate on the stub host with its own path, so tests running side by side never share a reply.
    private func stubbedCandidate(
        answeringWith reply: StubbedModelURLProtocol.Reply,
        fileNameSuffix: String = "",
        claimedType: RoomFurnitureClaimedModelType
    ) -> RoomFurnitureModelCandidate {
        let path = "/\(UUID().uuidString)\(fileNameSuffix)"
        StubbedModelURLProtocol.replies.withLock { replies in replies[path] = reply }
        return candidate("https://models.stub\(path)", claimedType: claimedType)
    }

    private func requestCount(for candidates: [RoomFurnitureModelCandidate]) -> Int {
        let paths = Set(candidates.map(\.url.path))
        return StubbedModelURLProtocol.requestedPaths.withLock { requestedPaths in requestedPaths.filter { paths.contains($0) }.count }
    }

    @Test func downloadSkipsAFailedCandidateAndReturnsTheNextUsableOne() async {
        let failing = stubbedCandidate(answeringWith: .status(404), fileNameSuffix: ".usdz", claimedType: .usdz)
        let working = stubbedCandidate(answeringWith: .file(tinyUSDZData()), fileNameSuffix: ".usdz", claimedType: .usdz)
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [failing, working], session: stubbedSession())
        #expect(modelFile?.url == working.url)
        #expect(modelFile?.kind == .usdz)
        #expect(modelFile?.source == "html")
    }

    @Test func downloadRefusesAFileOverTheSizeCap() async {
        let tooBig = stubbedCandidate(
            answeringWith: .fileDeclaring(byteCount: RoomFurnitureDiscovery.largestModelByteCount + 1, tinyGLBData(jsonText: plainGLBJSON)),
            fileNameSuffix: ".glb",
            claimedType: .glb
        )
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [tooBig], session: stubbedSession())
        #expect(modelFile == nil)
    }

    @Test func downloadAcceptsAnExtensionlessFileOnlyWhenItsBytesAreAModel() async {
        let htmlErrorPage = stubbedCandidate(answeringWith: .file(Data("<html>sign in</html>".utf8)), claimedType: .unknown)
        let plainZip = stubbedCandidate(answeringWith: .file(zipEntry(name: "a.txt", content: [1])), claimedType: .unknown)
        let realGLB = stubbedCandidate(answeringWith: .file(tinyGLBData(jsonText: plainGLBJSON)), claimedType: .unknown)
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(
            from: [htmlErrorPage, plainZip, realGLB],
            session: stubbedSession()
        )
        #expect(modelFile?.url == realGLB.url)
        #expect(modelFile?.kind == .glb)
    }

    @Test func downloadRefusesAGLBNamedFileWhoseBytesAreNotAModel() async {
        let mislabeled = stubbedCandidate(answeringWith: .file(Data("<html>moved</html>".utf8)), fileNameSuffix: ".glb", claimedType: .glb)
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [mislabeled], session: stubbedSession())
        #expect(modelFile == nil)
    }

    @Test func downloadSkipsADracoGLBThatThePathDidNotGiveAway() async {
        let hiddenDraco = stubbedCandidate(
            answeringWith: .file(tinyGLBData(jsonText: dracoGLBJSON)), fileNameSuffix: ".glb", claimedType: .glb
        )
        let plain = stubbedCandidate(
            answeringWith: .file(tinyGLBData(jsonText: plainGLBJSON)), fileNameSuffix: ".glb", claimedType: .glb
        )
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [hiddenDraco, plain], session: stubbedSession())
        #expect(modelFile?.url == plain.url)
    }

    @Test func downloadNeverRequestsADracoOrGltfCandidate() async {
        let draco = stubbedCandidate(answeringWith: .file(tinyGLBData(jsonText: dracoGLBJSON)), claimedType: .glb)
        let dracoByPath = RoomFurnitureModelCandidate(url: draco.url, source: "html", claimedType: .glb, looksLikeDraco: true)
        let gltf = stubbedCandidate(answeringWith: .file(Data("{}".utf8)), fileNameSuffix: ".gltf", claimedType: .gltf)
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [dracoByPath, gltf], session: stubbedSession())
        #expect(modelFile == nil)
        #expect(requestCount(for: [draco, gltf]) == 0)
    }

    @Test func downloadTriesAtMostFourCandidates() async {
        let failing = (0..<6).map { _ in stubbedCandidate(answeringWith: .status(500), fileNameSuffix: ".glb", claimedType: .glb) }
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: failing, session: stubbedSession())
        #expect(modelFile == nil)
        #expect(requestCount(for: failing) == RoomFurnitureDiscovery.mostDownloadsPerRequest)
    }

    @Test func downloadTriesUSDZBeforeGLB() async {
        let glb = stubbedCandidate(answeringWith: .file(tinyGLBData(jsonText: plainGLBJSON)), fileNameSuffix: ".glb", claimedType: .glb)
        let usdz = stubbedCandidate(answeringWith: .file(tinyUSDZData()), fileNameSuffix: ".usdz", claimedType: .usdz)
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [glb, usdz], session: stubbedSession())
        #expect(modelFile?.url == usdz.url)
        #expect(requestCount(for: [glb]) == 0)
    }

    @Test func downloadRefusesAHostOnThisMacsNetwork() async {
        let onThisMac = RoomFurnitureModelCandidate(
            url: URL(string: "https://127.0.0.1/chair.glb")!, source: "html", claimedType: .glb, looksLikeDraco: false
        )
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [onThisMac], session: stubbedSession())
        #expect(modelFile == nil)
    }

    @Test func downloadStopsAtOnceWhenTheTaskIsCancelled() async {
        let working = stubbedCandidate(answeringWith: .file(tinyUSDZData()), fileNameSuffix: ".usdz", claimedType: .usdz)
        let session = stubbedSession()
        let cancelledDownload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [working], session: session)
        }
        #expect(await cancelledDownload.value == nil)
        #expect(requestCount(for: [working]) == 0)
    }
}
