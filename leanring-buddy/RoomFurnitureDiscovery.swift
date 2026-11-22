//
//  RoomFurnitureDiscovery.swift
//  leanring-buddy
//
//  How "try it in my room" finds a store's own 3D model of a piece of furniture, and a fuller read of the product page.
//
//  A store page often carries a real 3D model (a GLB or USDZ file for its AR and 3D viewers), which stands in the room better
//  than a flat cutout of the product photo. This file holds the page script that finds the candidate files (it runs in
//  Chrome's front tab), the boundary that parses the script's reply, the ranking of the candidates, the sniff that tells a
//  GLB or USDZ file from anything else, and the download. It also holds the two page scripts that read the product's size
//  more completely than `document.body.innerText`: one opens the collapsed sections that hide a measurement, the other reads
//  the page's text, its JSON-LD, and its framework data.
//
//  Every page script here runs inside an AppleScript string literal (`appleScriptToRunJavaScript`), so none contains a double
//  quote or a backslash, and a Promise is never awaited, so a network read in a page is a synchronous XMLHttpRequest.
//  Everything a page names, and every downloaded byte, is untrusted data.
//

import Foundation

// MARK: - The page script that finds model files

/// A page script that returns a JSON string `[{ url, source, type }]` of the files in the page that may be a 3D model of the
/// product, at most 30, each URL under 2048 characters. It looks in:
/// - the page's HTML, for https URLs ending in .glb, .gltf, or .usdz, with or without a query (source `html`);
/// - the resource names the page already fetched, which catches a model a store's 3D viewer loaded (source `resource`);
/// - `model-viewer` elements' `src` and `ios-src` (sources `model-viewer` and `model-viewer-ios`);
/// - `a[rel=ar]` links (source `ar-link`);
/// - JSON-LD objects of type 3DModel with a `contentUrl` or an `encoding` list, anywhere in the graph (source `json-ld`);
/// - on a page with a `/products/<handle>` path (a Shopify store's, and the read is harmless on any other site), the `model3d` media of `/products/<handle>.js` from the page's own
///   origin, read with a synchronous request (source `shopify`);
/// - the page's data, for a URL right after a key that says usdz, glb, or gltf, or a key such as `modelUrl` or `3dAsset`, since
///   some stores name a model file with no extension (source `product-data-hint`, whose `type` is only what the key says).
/// Each part is in its own try block, so a broken part never throws away the rest.
nonisolated let roomFurnitureModelDiscoveryScript = [
    "(function () {",
    "var found = []; var seen = {};",
    "var QUOTE = String.fromCharCode(34); var BACKSLASH = String.fromCharCode(92); var NEWLINE = String.fromCharCode(10);",
    // A character class of what ends a URL in markup or JSON: white space, quotes, angle brackets, and parentheses.
    "var STOP = ' ' + String.fromCharCode(9, 10, 13, 34, 39) + '<>()';",
    "function addCandidate(rawUrl, source, claimedType) {",
    "try {",
    "if (!rawUrl || found.length >= 30) { return; }",
    // A fragment never reaches a server, and a store's AR link adds one, so the same file would count twice.
    "var parsedUrl = new URL(String(rawUrl), document.baseURI); parsedUrl.hash = ''; var absoluteUrl = parsedUrl.href;",
    "if (absoluteUrl.length > 2048 || !/^https:/i.test(absoluteUrl) || seen[absoluteUrl]) { return; }",
    "seen[absoluteUrl] = true;",
    "found.push({ url: absoluteUrl, source: source, type: claimedType ? String(claimedType).slice(0, 80) : '' });",
    "} catch (error) {}",
    "}",
    // JSON in a page writes a slash as backslash-slash and an ampersand as backslash-u0026, and HTML writes it as &amp;.
    "function cleaned(text) {",
    "return String(text).split(BACKSLASH + '/').join('/').split(BACKSLASH + 'u0026').join('&').split('&amp;').join('&').split(BACKSLASH).join(' ');",
    "}",
    "function scanTextForModelUrls(text, source) {",
    "var pattern = new RegExp('https://[^' + STOP + ']+?[.](glb|gltf|usdz)(?![A-Za-z0-9_])([?][^' + STOP + ']*)?', 'ig');",
    "var match; var guard = 0;",
    "while ((match = pattern.exec(text)) !== null && guard++ < 200) { addCandidate(match[0], source, ''); }",
    "}",
    "function scanTextForHintedUrls(text) {",
    "var pattern = new RegExp('((?:usdz|glb|gltf)|(?:3d|model)[A-Za-z0-9_-]*?(?:url|src|file|path|link|href|asset))[A-Za-z0-9_-]*[^A-Za-z0-9]{1,8}(https://[^' + STOP + ']+)', 'ig');",
    "var match; var guard = 0; var added = 0;",
    "while ((match = pattern.exec(text)) !== null && guard++ < 400 && added < 8) {",
    "if (/[.](png|jpe?g|webp|gif|svg|avif|css|js|json|html?|woff2?|mp4|webm|ico|txt|xml)([?#]|$)/i.test(match[2])) { continue; }",
    "var before = found.length;",
    "addCandidate(match[2], 'product-data-hint', /^usdz$/i.test(match[1]) ? 'usdz' : (/^glb$/i.test(match[1]) ? 'glb' : ''));",
    "if (found.length > before) { added++; }",
    "}",
    "}",
    "try { scanTextForModelUrls(cleaned(document.documentElement.outerHTML), 'html'); } catch (error) {}",
    "try { var resourceNames = performance.getEntriesByType('resource').map(function (entry) { return entry.name; }); scanTextForModelUrls(cleaned(resourceNames.join(' ')), 'resource'); } catch (error) {}",
    "try {",
    "var viewers = document.querySelectorAll('model-viewer');",
    "for (var viewerIndex = 0; viewerIndex < viewers.length; viewerIndex++) {",
    "addCandidate(viewers[viewerIndex].getAttribute('src'), 'model-viewer', '');",
    "addCandidate(viewers[viewerIndex].getAttribute('ios-src'), 'model-viewer-ios', '');",
    "}",
    "} catch (error) {}",
    "try {",
    "var arLinks = document.querySelectorAll('a[rel~=ar]');",
    "for (var linkIndex = 0; linkIndex < arLinks.length; linkIndex++) { addCandidate(arLinks[linkIndex].getAttribute('href'), 'ar-link', arLinks[linkIndex].getAttribute('type')); }",
    "} catch (error) {}",
    "function collectModelLocations(model) {",
    "addCandidate(model.contentUrl, 'json-ld', model.encodingFormat);",
    "var encodings = model.encoding ? [].concat(model.encoding) : [];",
    "for (var encodingIndex = 0; encodingIndex < encodings.length; encodingIndex++) {",
    "var encoding = encodings[encodingIndex];",
    "if (encoding && typeof encoding === 'object') { addCandidate(encoding.contentUrl || encoding.url, 'json-ld', encoding.encodingFormat); }",
    "}",
    "}",
    "function visitStructuredData(node, depth) {",
    "if (!node || typeof node !== 'object' || depth > 12) { return; }",
    "if (Array.isArray(node)) { for (var itemIndex = 0; itemIndex < node.length; itemIndex++) { visitStructuredData(node[itemIndex], depth + 1); } return; }",
    "var typeText = [].concat(node['@type'] || []).join(' ');",
    "if (typeText.indexOf('3DModel') >= 0) { collectModelLocations(node); }",
    "for (var key in node) { visitStructuredData(node[key], depth + 1); }",
    "}",
    "try {",
    "var scripts = document.querySelectorAll('script');",
    "for (var scriptIndex = 0; scriptIndex < scripts.length; scriptIndex++) {",
    "if (scripts[scriptIndex].type !== 'application/ld+json') { continue; }",
    "try { visitStructuredData(JSON.parse(scripts[scriptIndex].textContent), 0); } catch (error) {}",
    "}",
    "} catch (error) {}",
    "try {",
    "var handleMatch = location.pathname.match(/[/]products[/]([^/?#]+)/);",
    "if (handleMatch) {",
    "var request = new XMLHttpRequest();",
    "request.open('GET', location.origin + '/products/' + handleMatch[1] + '.js', false);",
    "request.send();",
    "if (request.status === 200) {",
    "var media = JSON.parse(request.responseText).media || [];",
    "for (var mediaIndex = 0; mediaIndex < media.length; mediaIndex++) {",
    "var sources = media[mediaIndex].sources || [];",
    "for (var sourceIndex = 0; sourceIndex < sources.length; sourceIndex++) {",
    "var modelSource = sources[sourceIndex];",
    "var format = String(modelSource.format || '') + ' ' + String(modelSource.mime_type || '');",
    "if (media[mediaIndex].media_type === 'model' || /glb|gltf|usdz/i.test(format)) { addCandidate(modelSource.url, 'shopify', format); }",
    "}",
    "}",
    "}",
    "}",
    "} catch (error) {}",
    "try { scanTextForHintedUrls(cleaned(document.documentElement.outerHTML)); } catch (error) {}",
    "return JSON.stringify(found);",
    "})()",
].joined(separator: " ")

// MARK: - Candidates

/// The kind of model file a URL or a store says a candidate is. Only the downloaded bytes say what it really is.
nonisolated enum RoomFurnitureClaimedModelType: Equatable, Sendable {
    case usdz
    case glb
    /// A `.gltf` file points at other files for its buffers and textures, so it cannot stand alone.
    case gltf
    case unknown
}

/// One file the page names that may be a 3D model of the product.
nonisolated struct RoomFurnitureModelCandidate: Equatable, Sendable {
    let url: URL
    /// Which part of the discovery script found it (`html`, `resource`, `model-viewer`, `json-ld`, `shopify`, ...), for the log.
    let source: String
    let claimedType: RoomFurnitureClaimedModelType
    /// True when the URL's path says Draco, the mesh compression SceneKit cannot decode.
    let looksLikeDraco: Bool

    /// The candidates in a discovery script's reply, in the order the script found them. Only https URLs on a public host are
    /// kept (`PageImageAnimation.mayDownload`), so a page cannot send a request to this Mac or its network, and each URL is
    /// kept once. Anything that is not the script's JSON, such as a failed script, gives an empty list.
    static func parse(discoveryScriptResult: String?) -> [RoomFurnitureModelCandidate] {
        guard let discoveryScriptResult,
              let replyEntries = try? JSONDecoder().decode([ReplyEntry].self, from: Data(discoveryScriptResult.utf8)) else {
            return []
        }
        var seenURLs = Set<URL>()
        var candidates: [RoomFurnitureModelCandidate] = []
        for replyEntry in replyEntries {
            guard let candidateURL = URL(string: replyEntry.url),
                  PageImageAnimation.mayDownload(candidateURL),
                  seenURLs.insert(candidateURL).inserted else { continue }
            candidates.append(RoomFurnitureModelCandidate(
                url: candidateURL,
                source: replyEntry.source ?? "unknown",
                claimedType: claimedType(ofURL: candidateURL, storeClaim: replyEntry.type ?? ""),
                looksLikeDraco: candidateURL.path.lowercased().contains("draco")
            ))
        }
        return candidates
    }

    private struct ReplyEntry: Decodable {
        let url: String
        let source: String?
        let type: String?
    }

    /// The URL's own extension wins over what a store claims, since a store's type text can be a MIME type or a loose word.
    /// A store that serves the file from an id with no extension often names it in the query (`?dl=sofa.usdz`), which counts too.
    nonisolated private static func claimedType(ofURL candidateURL: URL, storeClaim: String) -> RoomFurnitureClaimedModelType {
        let lowercaseQuery = candidateURL.query?.lowercased() ?? ""
        switch candidateURL.pathExtension.lowercased() {
        case "usdz": return .usdz
        case "glb": return .glb
        case "gltf": return .gltf
        default: break
        }
        if lowercaseQuery.hasSuffix(".usdz") { return .usdz }
        if lowercaseQuery.hasSuffix(".glb") { return .glb }
        let lowercaseClaim = storeClaim.lowercased()
        if lowercaseClaim.contains("usdz") { return .usdz }
        if lowercaseClaim.contains("glb") || lowercaseClaim.contains("gltf-binary") { return .glb }
        if lowercaseClaim.contains("gltf") { return .gltf }
        return .unknown
    }
}

/// The candidates worth downloading, in the order to try them, and how many were left out, for the log.
nonisolated struct RoomFurnitureCandidateRanking: Equatable, Sendable {
    let candidatesToTry: [RoomFurnitureModelCandidate]
    let droppedBecauseOfDracoCount: Int
    let droppedBecauseOfGltfCount: Int
}

/// USDZ first, since Apple's own loader reads it and a store's AR file is a finished model. Then GLB, then a file whose type
/// nobody names (the download's bytes decide). A GLB that looks Draco compressed is dropped, since SceneKit has no Draco
/// decoder, and so is a `.gltf` file, since it needs the external buffers and textures it names and a lone download is empty.
/// The order inside each group is the order the page script found them.
nonisolated func rankedModelCandidates(_ candidates: [RoomFurnitureModelCandidate]) -> RoomFurnitureCandidateRanking {
    var usdzCandidates: [RoomFurnitureModelCandidate] = []
    var glbCandidates: [RoomFurnitureModelCandidate] = []
    var unknownCandidates: [RoomFurnitureModelCandidate] = []
    var droppedBecauseOfDracoCount = 0
    var droppedBecauseOfGltfCount = 0
    for candidate in candidates {
        switch candidate.claimedType {
        case .usdz:
            usdzCandidates.append(candidate)
        case .gltf:
            droppedBecauseOfGltfCount += 1
        case .glb, .unknown:
            if candidate.looksLikeDraco {
                droppedBecauseOfDracoCount += 1
            } else if candidate.claimedType == .glb {
                glbCandidates.append(candidate)
            } else {
                unknownCandidates.append(candidate)
            }
        }
    }
    return RoomFurnitureCandidateRanking(
        candidatesToTry: usdzCandidates + glbCandidates + unknownCandidates,
        droppedBecauseOfDracoCount: droppedBecauseOfDracoCount,
        droppedBecauseOfGltfCount: droppedBecauseOfGltfCount
    )
}

// MARK: - What a downloaded file is

/// The file formats the room can stand. A download counts only when its first bytes say it is one of these, whatever its
/// URL or the store said, since a URL with no extension, or one with the wrong extension, can be anything.
nonisolated enum RoomFurnitureModelFileKind: Equatable, Sendable {
    case glb
    case usdz

    /// `glb` for the ASCII magic `glTF`. `usdz` for a ZIP whose local file headers name an entry ending in `.usdc` or `.usda`,
    /// since a USDZ is an uncompressed ZIP of USD layers and a plain ZIP can be anything. Nil for everything else.
    static func sniff(_ data: Data) -> RoomFurnitureModelFileKind? {
        let glbMagic: [UInt8] = [0x67, 0x6C, 0x54, 0x46]
        if data.starts(with: glbMagic) { return .glb }
        return zipHoldsAUSDLayer(data) ? .usdz : nil
    }

    /// Walks the ZIP's local file headers (signature, 30 fixed bytes, the name, an extra field, then the entry's data), which
    /// a USDZ stores uncompressed. Stops at the first thing that is not a header, and gives up on an entry whose size a data
    /// descriptor would give, since it cannot be skipped.
    nonisolated private static func zipHoldsAUSDLayer(_ data: Data) -> Bool {
        let localFileHeaderSignature: UInt32 = 0x0403_4B50
        let fixedHeaderByteCount = 30
        let mostEntriesToRead = 64
        return data.withUnsafeBytes { (allBytes: UnsafeRawBufferPointer) -> Bool in
            func littleEndianValue(at offset: Int, byteCount: Int) -> Int {
                var value = 0
                for byteIndex in 0..<byteCount { value |= Int(allBytes[offset + byteIndex]) << (8 * byteIndex) }
                return value
            }
            var headerOffset = 0
            for _ in 0..<mostEntriesToRead {
                guard headerOffset + fixedHeaderByteCount <= allBytes.count,
                      littleEndianValue(at: headerOffset, byteCount: 4) == Int(localFileHeaderSignature) else { return false }
                let flags = littleEndianValue(at: headerOffset + 6, byteCount: 2)
                let storedByteCount = littleEndianValue(at: headerOffset + 18, byteCount: 4)
                let nameByteCount = littleEndianValue(at: headerOffset + 26, byteCount: 2)
                let extraByteCount = littleEndianValue(at: headerOffset + 28, byteCount: 2)
                let nameStart = headerOffset + fixedHeaderByteCount
                guard nameStart + nameByteCount <= allBytes.count else { return false }
                let entryName = String(
                    decoding: UnsafeRawBufferPointer(rebasing: allBytes[nameStart..<(nameStart + nameByteCount)]),
                    as: UTF8.self
                ).lowercased()
                if entryName.hasSuffix(".usdc") || entryName.hasSuffix(".usda") { return true }
                let hasDataDescriptor = flags & 0x08 != 0
                if hasDataDescriptor { return false }
                headerOffset = nameStart + nameByteCount + extraByteCount + storedByteCount
            }
            return false
        }
    }
}

/// True when a GLB's JSON chunk lists `KHR_draco_mesh_compression` in `extensionsRequired` or `extensionsUsed`, which SceneKit
/// cannot load. False for anything that is not a GLB with a readable JSON chunk.
nonisolated func glbRequiresDraco(_ data: Data) -> Bool {
    // A GLB is a 12 byte header (magic, version, length), then chunks of a 4 byte length, a 4 byte type, and the data.
    // The first chunk is the glTF JSON, type 0x4E4F534A, which reads as the ASCII letters JSON.
    let glbHeaderByteCount = 12
    let jsonChunkTypeBytes: [UInt8] = [0x4A, 0x53, 0x4F, 0x4E]
    guard RoomFurnitureModelFileKind.sniff(data) == .glb, data.count >= glbHeaderByteCount + 8 else { return false }
    let bytes = [UInt8](data.prefix(glbHeaderByteCount + 8))
    guard Array(bytes[16..<20]) == jsonChunkTypeBytes else { return false }
    let jsonByteCount = Int(bytes[12]) | Int(bytes[13]) << 8 | Int(bytes[14]) << 16 | Int(bytes[15]) << 24
    let jsonStart = data.startIndex + glbHeaderByteCount + 8
    guard jsonByteCount > 0, jsonByteCount <= data.count - (glbHeaderByteCount + 8) else { return false }
    let jsonData = data[jsonStart..<(jsonStart + jsonByteCount)]
    guard let glTFJSON = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return false }
    let dracoExtensionName = "KHR_draco_mesh_compression"
    return ["extensionsRequired", "extensionsUsed"].contains { extensionListKey in
        (glTFJSON[extensionListKey] as? [String])?.contains(dracoExtensionName) ?? false
    }
}

// MARK: - The download

/// A model file from the store's own page, checked to be a GLB or USDZ that SceneKit can load.
nonisolated struct RoomFurnitureStoreModelFile: Equatable, Sendable {
    let data: Data
    let kind: RoomFurnitureModelFileKind
    let url: URL
    /// Which part of the discovery script found it.
    let source: String
}

nonisolated enum RoomFurnitureDiscovery {
    /// A store's model is a few megabytes. This leaves room for a detailed one and refuses anything stranger.
    static let largestModelByteCount = 40_000_000
    static let mostDownloadsPerRequest = 4
    static let downloadTimeoutSeconds: TimeInterval = 15

    /// Tries the ranked candidates one at a time, at most `mostDownloadsPerRequest` downloads, and returns the first file whose
    /// bytes are a GLB without Draco compression or a USDZ. Every download is the shared safe one (https only including
    /// redirects, no cookies, no local or private host). The log names each candidate by host and outcome and never its URL
    /// query, since a store's URL may carry a token. Nil when nothing usable downloaded or the task was cancelled.
    @concurrent static func downloadTheFirstUsableModel(
        from candidates: [RoomFurnitureModelCandidate],
        session: URLSession = PageImageAnimation.downloadSession
    ) async -> RoomFurnitureStoreModelFile? {
        let ranking = rankedModelCandidates(candidates)
        if ranking.droppedBecauseOfDracoCount > 0 || ranking.droppedBecauseOfGltfCount > 0 {
            print("Room furniture: left out \(ranking.droppedBecauseOfDracoCount) Draco files and \(ranking.droppedBecauseOfGltfCount) .gltf files")
        }
        for candidate in ranking.candidatesToTry.prefix(mostDownloadsPerRequest) {
            if Task.isCancelled { return nil }
            let host = candidate.url.host ?? "unknown host"
            guard let downloadedData = await PageImageAnimation.downloadedImageData(
                atImageURL: candidate.url,
                timeoutSeconds: downloadTimeoutSeconds,
                session: session,
                largestByteCount: largestModelByteCount
            ) else {
                print("Room furniture: \(host) (\(candidate.source)) did not download")
                continue
            }
            guard let fileKind = RoomFurnitureModelFileKind.sniff(downloadedData) else {
                print("Room furniture: \(host) (\(candidate.source)) is not a GLB or USDZ file")
                continue
            }
            if fileKind == .glb, glbRequiresDraco(downloadedData) {
                print("Room furniture: \(host) (\(candidate.source)) is a Draco compressed GLB, which SceneKit cannot load")
                continue
            }
            print("Room furniture: \(host) (\(candidate.source)) is a usable \(fileKind) file of \(downloadedData.count) bytes")
            return RoomFurnitureStoreModelFile(data: downloadedData, kind: fileKind, url: candidate.url, source: candidate.source)
        }
        return nil
    }
}

// MARK: - Reading the page's size text

/// A page script that opens the collapsed sections that hide a product's measurements, and returns how many it opened.
/// It opens every `<details>` element, and clicks each button, summary, or role=button element whose whole visible text is
/// Measurements, Dimensions, Product details, or Specifications (any case, at most 40 characters, so it never clicks a large
/// container). A bare "Size" is left alone, since on a clothing page it opens the size picker. It skips a control that is already expanded, since a click would close it, a submit
/// button of a form, and a control inside a link, so it never leaves the page or sends a form.
nonisolated let roomArtExpandTheSizeSectionsScript = [
    "(function () {",
    "var opened = 0;",
    "var sectionNames = ['measurements', 'dimensions', 'product details', 'specifications'];",
    "try {",
    "var detailsElements = document.querySelectorAll('details');",
    "for (var detailsIndex = 0; detailsIndex < detailsElements.length; detailsIndex++) {",
    "if (!detailsElements[detailsIndex].open) { detailsElements[detailsIndex].open = true; opened++; }",
    "}",
    "} catch (error) {}",
    "try {",
    "var controls = document.querySelectorAll('button, summary, [role=button]');",
    "for (var controlIndex = 0; controlIndex < controls.length && controlIndex < 400; controlIndex++) {",
    "var control = controls[controlIndex];",
    "var visibleText = String(control.innerText || control.textContent || '').trim().toLowerCase();",
    "if (visibleText.length > 40 || sectionNames.indexOf(visibleText) < 0) { continue; }",
    "if (control.getAttribute('aria-expanded') === 'true') { continue; }",
    "if (control.form && control.type === 'submit') { continue; }",
    "if (control.closest('a[href]')) { continue; }",
    "if (control.tagName === 'SUMMARY') { if (control.parentElement && control.parentElement.open) { continue; } }",
    "control.click(); opened++;",
    "}",
    "} catch (error) {}",
    "return opened;",
    "})()",
].joined(separator: " ")

/// A page script that returns the page's text for `POST /try-it-item`, cut to `longestCharacters` in all: the page's visible
/// text first, then its JSON-LD, then Next.js and Nuxt data, each of those only when it holds a word that looks like a
/// dimension (height, width, depth, dimension, cm, inch). A size a store keeps out of the visible text, or hides in a
/// collapsed section, is often in that data. Run `roomArtExpandTheSizeSectionsScript` and wait a moment first.
nonisolated func roomArtPageTextScript(longestCharacters: Int) -> String {
    [
        "(function () {",
        "var NEWLINE = String.fromCharCode(10);",
        "var dimensionWords = /height|width|depth|dimension|cm|inch/i;",
        "var parts = [document.body ? document.body.innerText : ''];",
        "function addWhenItLooksLikeADimension(text) { if (text && dimensionWords.test(text)) { parts.push(text); } }",
        "try {",
        "var scripts = document.querySelectorAll('script');",
        "for (var scriptIndex = 0; scriptIndex < scripts.length; scriptIndex++) {",
        "if (scripts[scriptIndex].type === 'application/ld+json') { addWhenItLooksLikeADimension(scripts[scriptIndex].textContent); }",
        "}",
        "} catch (error) {}",
        "try {",
        "var hydrationIds = ['__NEXT_DATA__', '__NUXT_DATA__'];",
        "for (var idIndex = 0; idIndex < hydrationIds.length; idIndex++) {",
        "var hydrationElement = document.getElementById(hydrationIds[idIndex]);",
        "if (hydrationElement) { addWhenItLooksLikeADimension(hydrationElement.textContent); }",
        "}",
        "} catch (error) {}",
        "try { if (window.__NUXT__) { addWhenItLooksLikeADimension(JSON.stringify(window.__NUXT__)); } } catch (error) {}",
        "return parts.join(NEWLINE).slice(0, \(max(0, longestCharacters)));",
        "})()",
    ].joined(separator: " ")
}
