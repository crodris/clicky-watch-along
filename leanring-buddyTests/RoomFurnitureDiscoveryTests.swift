//
//  RoomFurnitureDiscoveryTests.swift
//  leanring-buddyTests
//
//  How room art finds a store's own 3D model of a piece of furniture: the page scripts are safe to paste into an AppleScript
//  string, the script's reply is parsed at the boundary (https and public hosts only, each URL once), the candidates are ranked
//  (GLB, then unknown, with Draco and .gltf files left out, and a USDZ never a candidate), the downloaded bytes are checked
//  to be a GLB, and the download takes the first usable file against a stubbed host (a failed or oversized or wrong or Draco file is skipped,
//  and at most 4 files are tried).
//

import Foundation
import os
import JavaScriptCore
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

/// One stored (uncompressed) ZIP entry, local file header and data, standing in for a download that is a ZIP and not a GLB.
private func zipEntry(name: String, content: [UInt8]) -> Data {
    var entry: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
    entry += littleEndianBytes(20, byteCount: 2)  // version needed
    entry += littleEndianBytes(0, byteCount: 2)  // flags
    entry += littleEndianBytes(0, byteCount: 2)  // method: stored
    entry += littleEndianBytes(0, byteCount: 4)  // time and date
    entry += littleEndianBytes(0, byteCount: 4)  // crc, which nothing checks
    entry += littleEndianBytes(content.count, byteCount: 4)  // stored size
    entry += littleEndianBytes(content.count, byteCount: 4)  // full size
    entry += littleEndianBytes(name.utf8.count, byteCount: 2)
    entry += littleEndianBytes(0, byteCount: 2)  // extra field size
    entry += Array(name.utf8) + content
    return Data(entry)
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

    /// Runs the page text script in JavaScriptCore against a stand-in page with `bodyText`, JSON-LD blocks, and Next.js or
    /// Nuxt data, and returns what it would send.
    private func pageText(
        longestCharacters: Int = 30_000,
        bodyText: String,
        jsonLDBlocks: [String] = [],
        nextDataJSON: String? = nil,
        nuxtJSON: String? = nil
    ) throws -> String {
        let context = try #require(JSContext())
        context.setObject(bodyText, forKeyedSubscript: "BODY_TEXT" as NSString)
        context.setObject(jsonLDBlocks.map { ["type": "application/ld+json", "textContent": $0] }, forKeyedSubscript: "SCRIPTS" as NSString)
        context.setObject(nextDataJSON.map { ["__NEXT_DATA__": ["textContent": $0]] } ?? [:], forKeyedSubscript: "ELEMENTS" as NSString)
        context.setObject(nuxtJSON ?? "", forKeyedSubscript: "NUXT_JSON" as NSString)
        context.evaluateScript("""
        var window = this;
        if (NUXT_JSON) { window.__NUXT__ = JSON.parse(NUXT_JSON); }
        var document = {
            body: { innerText: BODY_TEXT },
            querySelectorAll: function () { return SCRIPTS; },
            getElementById: function (id) { return ELEMENTS[id] || null; }
        };
        """)
        return try #require(context.evaluateScript(roomArtPageTextScript(longestCharacters: longestCharacters))?.toString())
    }

    @Test func pageTextKeepsTheSizesFromJSONLDAsLines() throws {
        let productJSONLD = #"{"@type":"Product","name":"LACK","height":"17 3/4 \"","additionalProperty":[{"@type":"PropertyValue","name":"Width","value":"21 5/8 \""}],"offers":{"price":"14.99"}}"#
        let text = try pageText(bodyText: "LACK side table", jsonLDBlocks: [productJSONLD])
        #expect(text.hasPrefix("LACK side table"))
        #expect(text.contains(#"height: 17 3/4 ""#))
        #expect(text.contains(#"Width: 21 5/8 ""#))
        #expect(!text.contains("14.99"))
    }

    @Test func pageTextNeverSendsWholeHydrationObjects() throws {
        // A size-like key whose value is not a measurement, such as a size chart's contact, is left out too.
        let nextData = #"{"props":{"user":{"email":"shopper@example.com","sessionToken":"tok_4f9a8b7c6d5e"},"sizeChartContact":"fit-team@example.com","product":{"dimensions":{"height":{"value":45,"unitCode":"CMT"},"depth":"55 cm"}}}}"#
        let nuxt = #"{"state":{"cart":{"id":"cart_123456"},"item":{"seatWidth":"20 in"}}}"#
        let text = try pageText(bodyText: "A table", nextDataJSON: nextData, nuxtJSON: nuxt)
        #expect(text.contains("height: 45 CMT"))
        #expect(text.contains("depth: 55 cm"))
        #expect(text.contains("seatWidth: 20 in"))
        #expect(!text.contains("shopper@example.com"))
        #expect(!text.contains("tok_4f9a8b7c6d5e"))
        #expect(!text.contains("cart_123456"))
        #expect(!text.contains("fit-team@example.com"))
    }

    @Test func pageTextCutsTheVisibleTextSoTheSizesStillFit() throws {
        let longBody = String(repeating: "word ", count: 10_000)
        let text = try pageText(longestCharacters: 1000, bodyText: longBody, jsonLDBlocks: [#"{"height":"45 cm"}"#])
        #expect(text.count <= 1000)
        #expect(text.hasSuffix("height: 45 cm"))
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
        [{"url":"https://models.example.com/b.glb","source":"ar-link","type":""},
         {"url":"https://models.example.com/a.glb","source":"html","type":""},
         {"url":"https://models.example.com/b.glb","source":"resource","type":""}]
        """
        let candidates = RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply)
        #expect(candidates.map(\.url.lastPathComponent) == ["b.glb", "a.glb"])
        #expect(candidates.first?.source == "ar-link")
    }

    @Test(arguments: [nil, "", "none", "not json", #"{"url":"https://models.example.com/a.glb"}"#, #"[{"source":"html"}]"#])
    func parseGivesNothingForAReplyThatIsNotTheScriptsList(reply: String?) {
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).isEmpty)
    }

    @Test func parseReadsTheTypeFromTheURLBeforeTheStoresClaim() {
        let reply = """
        [{"url":"https://models.example.com/a.glb","source":"json-ld","type":"model/vnd.usdz+zip"},
         {"url":"https://models.example.com/b.gltf","source":"html","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.claimedType) == [.glb, .gltf])
    }

    @Test func parseReadsAnExtensionlessURLsTypeFromItsQueryOrTheStoresClaim() {
        let reply = """
        [{"url":"https://cdn.example.com/WKbnY0s?dl=sven-sofa.glb","source":"html","type":""},
         {"url":"https://cdn.example.com/abc123","source":"shopify","type":"glb model/gltf-binary"},
         {"url":"https://cdn.example.com/def456","source":"product-data-hint","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.claimedType) == [.glb, .glb, .unknown])
    }

    @Test func aPageThatOffersOnlyAUSDZYieldsNoCandidateToTry() {
        // USDZ is not read, so a file the URL's extension, its query, or the store's claim says is a USDZ never becomes a
        // candidate, and a store such as Article that offers only one falls back to the generated model or the composite.
        let reply = """
        [{"url":"https://models.example.com/sofa.usdz","source":"ar-link","type":""},
         {"url":"https://cdn.example.com/WKbnY0s?dl=sven-sofa.usdz","source":"html","type":""},
         {"url":"https://cdn.example.com/abc123","source":"shopify","type":"usdz model/vnd.usdz+zip"}]
        """
        let candidates = RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply)
        #expect(candidates.isEmpty)
        #expect(rankedModelCandidates(candidates).candidatesToTry.isEmpty)
    }

    @Test func parseFlagsAPathThatSaysDraco() {
        let reply = """
        [{"url":"https://web-api.example.com/assets/glb_draco/chair.glb","source":"html","type":""},
         {"url":"https://web-api.example.com/assets/glb/chair.glb","source":"html","type":""}]
        """
        #expect(RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply).map(\.looksLikeDraco) == [true, false])
    }

    // MARK: Ranking

    @Test func rankingPutsGLBFirstThenUnknownInTheScriptsOrder() {
        let ranking = rankedModelCandidates([
            candidate("https://m.example.com/unknown-1", claimedType: .unknown),
            candidate("https://m.example.com/glb-1.glb", claimedType: .glb),
            candidate("https://m.example.com/unknown-2", claimedType: .unknown),
            candidate("https://m.example.com/glb-2.glb", claimedType: .glb),
        ])
        #expect(ranking.candidatesToTry.map(\.url.lastPathComponent) == ["glb-1.glb", "glb-2.glb", "unknown-1", "unknown-2"])
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

    // MARK: Checking the bytes

    @Test func aGLBIsReadFromItsMagic() {
        #expect(dataIsAGLB(tinyGLBData(jsonText: plainGLBJSON)))
    }

    @Test func aGLBIsFoundInASliceOfLargerData() {
        // `Data` slices keep their parent's indices, so the check must not assume the first byte is at index 0.
        let paddedGLB = Data([9, 9, 9]) + tinyGLBData(jsonText: plainGLBJSON)
        #expect(dataIsAGLB(paddedGLB.dropFirst(3)))
    }

    @Test(arguments: ["", "<html>not found</html>", "glT", "PK"])
    func bytesThatAreNotAGLBAreRefused(text: String) {
        #expect(!dataIsAGLB(Data(text.utf8)))
    }

    @Test func aZipIsNotAGLB() {
        #expect(!dataIsAGLB(zipEntry(name: "model.usdc", content: [4, 5, 6, 7])))
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
        #expect(!glbRequiresDraco(zipEntry(name: "model.usdc", content: [4, 5, 6, 7])))
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
        let failing = stubbedCandidate(answeringWith: .status(404), fileNameSuffix: ".glb", claimedType: .glb)
        let working = stubbedCandidate(answeringWith: .file(tinyGLBData(jsonText: plainGLBJSON)), fileNameSuffix: ".glb", claimedType: .glb)
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [failing, working], session: stubbedSession())
        #expect(modelFile?.url == working.url)
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

    // MARK: Which hosts a page may offer

    @Test func aPageMayOfferFilesOnItsOwnDomainOrFilesItLoaded() throws {
        let pageURL = try #require(URL(string: "https://www.ikea.com/us/en/p/lack-side-table-white-30449908/"))
        let onTheSameDomain = candidate("https://web-api.ikea.com/dimma/model.glb", claimedType: .glb)
        let elsewhere = candidate("https://attacker.example/model.glb", claimedType: .glb)
        var loadedByThePage = candidate("https://cdn.shopify.com/model.glb", claimedType: .glb)
        loadedByThePage.wasLoadedByThePage = true
        let offered = candidatesThePageMayOffer([onTheSameDomain, elsewhere, loadedByThePage], pageURL: pageURL)
        #expect(offered.map(\.url) == [onTheSameDomain.url, loadedByThePage.url])
    }

    @Test func aURLTheScriptFoundAmongTheLoadedResourcesCountsAsLoadedByThePage() {
        let reply = #"[{"url":"https://cdn.example.net/m.glb","source":"html","type":""},{"url":"https://cdn.example.net/m.glb","source":"resource","type":""},{"url":"https://cdn.example.net/n.glb","source":"html","type":""}]"#
        let candidates = RoomFurnitureModelCandidate.parse(discoveryScriptResult: reply)
        #expect(candidates.map(\.wasLoadedByThePage) == [true, false])
    }

    @Test func aRegistrableDomainKeepsTheLabelSomeoneRegistered() {
        #expect(registrableDomain(ofHost: "digitalcontent.target.com") == "target.com")
        #expect(registrableDomain(ofHost: "www.johnlewis.co.uk") == "johnlewis.co.uk")
        #expect(registrableDomain(ofHost: "evil.co.uk") == "evil.co.uk")
        #expect(registrableDomain(ofHost: "store-one.myshopify.com") != registrableDomain(ofHost: "store-two.myshopify.com"))
    }

    @Test func downloadRefusesAHostOnThisMacsNetwork() async {
        let onThisMac = RoomFurnitureModelCandidate(
            url: URL(string: "https://127.0.0.1/chair.glb")!, source: "html", claimedType: .glb, looksLikeDraco: false
        )
        let modelFile = await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [onThisMac], session: stubbedSession())
        #expect(modelFile == nil)
    }

    @Test func downloadStopsAtOnceWhenTheTaskIsCancelled() async {
        let working = stubbedCandidate(answeringWith: .file(tinyGLBData(jsonText: plainGLBJSON)), fileNameSuffix: ".glb", claimedType: .glb)
        let session = stubbedSession()
        let cancelledDownload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await RoomFurnitureDiscovery.downloadTheFirstUsableModel(from: [working], session: session)
        }
        #expect(await cancelledDownload.value == nil)
        #expect(requestCount(for: [working]) == 0)
    }
}
