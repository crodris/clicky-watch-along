//
//  LiveSceneOverlay.swift
//  leanring-buddy
//
//  One transparent window and one page, reused for every live scene. The
//  window is created on the screen under the mouse, and later plays move it
//  there again. Each scene is generated HTML loaded in that window. The page
//  reports tourFinished when the camera tour ends.
//

import AppKit
import WebKit

/// The overlay window never becomes key, so AppKit would otherwise drop the
/// click that starts a drag.
private final class LiveSceneWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Generated pages import three.js from clicky-asset://three/..., because that
/// page is not allowed to reach a CDN. The files ship in the app bundle. The landmark
/// page also loads Google 3D Tiles from clicky-asset://tiles/..., which this handler
/// fetches from the Worker, so the page itself still never reaches the network.
private final class LiveSceneAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The generated page is served from here so its policy is a response header.
    /// Text in the page cannot displace a header the way it could a meta tag.
    static let livePageURLString = "clicky-asset://live/page.html"
    private static let livePageContentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline' clicky-asset:; style-src 'unsafe-inline'; img-src data: blob:; connect-src clicky-asset:; base-uri 'none'; form-action 'none'; webrtc 'block'"
    /// Only the bundled landmark page gets this. Its Draco decoder runs WebAssembly in a
    /// blob worker, and its tile textures are read back from blob URLs.
    private static let mapTilesPageContentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline' 'wasm-unsafe-eval' clicky-asset: blob:; worker-src blob:; style-src 'unsafe-inline'; img-src data: blob:; connect-src clicky-asset: blob: data:; base-uri 'none'; form-action 'none'; webrtc 'block'"

    /// The bundled files a page may load, with the content type each is served as.
    private static let bundledAssetContentTypes = [
        "three.module.js": "text/javascript",
        "three.core.js": "text/javascript",
        "three-tiles.js": "text/javascript",
        "draco_wasm_wrapper.js": "text/javascript",
        "draco_decoder.wasm": "application/wasm",
    ]

    var livePageHTMLData: Data?
    var livePageRendersMapTiles = false
    /// The Worker's address, which adds the Maps key to every 3D Tiles request.
    var mapTilesWorkerBaseURL: String?
    private let stoppedTaskLock = NSLock()
    private let stoppedTasks = NSHashTable<AnyObject>.weakObjects()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, message: "Three.js request had no URL")
            return
        }
        if requestURL.absoluteString == Self.livePageURLString {
            serveLivePage(for: urlSchemeTask, requestURL: requestURL)
            return
        }
        if requestURL.host == "tiles" {
            serveMapTile(for: urlSchemeTask, requestURL: requestURL)
            return
        }
        let fileName = requestURL.lastPathComponent
        guard let contentType = Self.bundledAssetContentTypes[fileName] else {
            fail(urlSchemeTask, message: "Refusing to serve \(fileName)")
            return
        }
        guard let scriptData = bundledAsset(named: fileName) else {
            print("Live scene: \(fileName) is not in the app bundle")
            fail(urlSchemeTask, message: "\(fileName) is not in the app bundle")
            return
        }
        guard let scriptResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                // The page origin is not this scheme, so the module import is cross-origin.
                "Access-Control-Allow-Origin": "*",
            ]
        ) else {
            fail(urlSchemeTask, message: "Could not build a response for \(fileName)")
            return
        }
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didReceive(scriptResponse)
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didReceive(scriptData)
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didFinish()
    }

    private func serveLivePage(for urlSchemeTask: WKURLSchemeTask, requestURL: URL) {
        guard let livePageHTMLData, let pageResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Security-Policy": livePageRendersMapTiles
                    ? Self.mapTilesPageContentSecurityPolicy
                    : Self.livePageContentSecurityPolicy,
            ]
        ) else {
            fail(urlSchemeTask, message: "No live page to serve")
            return
        }
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didReceive(pageResponse)
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didReceive(livePageHTMLData)
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stoppedTaskLock.lock()
        stoppedTasks.add(urlSchemeTask as AnyObject)
        stoppedTaskLock.unlock()
    }

    /// Only 3D Tiles paths go through, to the Worker, which adds the Maps key.
    private func serveMapTile(for urlSchemeTask: WKURLSchemeTask, requestURL: URL) {
        guard livePageRendersMapTiles,
              let mapTilesWorkerBaseURL,
              let requestComponents = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              requestComponents.path.hasPrefix("/v1/3dtiles/"),
              let workerTileURL = URL(string: mapTilesWorkerBaseURL + requestComponents.percentEncodedPath
                  + (requestComponents.percentEncodedQuery.map { "?" + $0 } ?? "")) else {
            fail(urlSchemeTask, message: "Refusing to serve \(requestURL.path)")
            return
        }
        URLSession.shared.dataTask(with: workerTileURL) { [weak self] tileData, response, error in
            DispatchQueue.main.async {
                guard let self, !self.taskWasStopped(urlSchemeTask) else { return }
                guard error == nil, let tileData, let workerResponse = response as? HTTPURLResponse,
                      let tileResponse = HTTPURLResponse(
                          url: requestURL,
                          statusCode: workerResponse.statusCode,
                          httpVersion: "HTTP/1.1",
                          headerFields: [
                              "Content-Type": workerResponse.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                              // The page is served from clicky-asset://live, so a tile from clicky-asset://tiles is cross-origin.
                              "Access-Control-Allow-Origin": "*",
                          ]
                      ) else {
                    self.fail(urlSchemeTask, message: "The Worker did not return \(requestURL.path)")
                    return
                }
                urlSchemeTask.didReceive(tileResponse)
                guard !self.taskWasStopped(urlSchemeTask) else { return }
                urlSchemeTask.didReceive(tileData)
                guard !self.taskWasStopped(urlSchemeTask) else { return }
                urlSchemeTask.didFinish()
            }
        }.resume()
    }

    private func bundledAsset(named fileName: String) -> Data? {
        let resourceName = (fileName as NSString).deletingPathExtension
        let fileExtension = (fileName as NSString).pathExtension
        let fileURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: fileExtension,
            subdirectory: "LiveSceneAssets"
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: fileExtension)
        guard let fileURL else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    private func taskWasStopped(_ urlSchemeTask: WKURLSchemeTask) -> Bool {
        stoppedTaskLock.lock()
        let taskWasStopped = stoppedTasks.contains(urlSchemeTask as AnyObject)
        stoppedTaskLock.unlock()
        return taskWasStopped
    }

    private func fail(_ urlSchemeTask: WKURLSchemeTask, message: String) {
        guard !taskWasStopped(urlSchemeTask) else { return }
        urlSchemeTask.didFailWithError(NSError(
            domain: "LiveScene",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

// A class, not an enum: WKNavigationDelegate has to be an NSObject.
final class LiveSceneOverlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = LiveSceneOverlay()

    var onTourFinished: (() -> Void)?
    /// An uncaught error or rejection in the page. A page that throws mid-tour never posts tourFinished.
    var onPageError: ((String) -> Void)?

    private static let pageErrorForwardingScript = """
    (() => {
      delete window.RTCPeerConnection;
      delete window.webkitRTCPeerConnection;
      const send = (text) => window.webkit.messageHandlers.liveSceneLog.postMessage(String(text));
      for (const level of ["error", "warn"]) {
        const original = console[level].bind(console);
        console[level] = (...values) => { send(level + ": " + values.join(" ")); original(...values); };
      }
      window.addEventListener("error", (event) => send("page error: " + event.message + " at line " + event.lineno));
      window.addEventListener("unhandledrejection", (event) => send("rejection: " + event.reason));
    })();
    """

    /// Generated HTML must not be able to reach the network. clicky-asset is not http,
    /// so the bundled three.js still loads.
    private static let httpAndHttpsBlockRuleListJSON = """
    [
      {
        "trigger": {
          "url-filter": "https?://.*"
        },
        "action": {
          "type": "block"
        }
      },
      {
        "trigger": {
          "url-filter": "wss?://.*"
        },
        "action": {
          "type": "block"
        }
      }
    ]
    """

    private struct QueuedLiveScenePage {
        let html: String
        let hidesQuizLabel: Bool
        let rendersMapTiles: Bool
    }

    /// Set once at start, so the landmark page's tile requests can reach the Worker.
    var mapTilesWorkerBaseURL: String? {
        get { threeAssetSchemeHandler.mapTilesWorkerBaseURL }
        set { threeAssetSchemeHandler.mapTilesWorkerBaseURL = newValue }
    }

    private let threeAssetSchemeHandler = LiveSceneAssetSchemeHandler()
    private var liveSceneOverlayWindow: OverlayWindow?
    private var liveSceneWebView: WKWebView?
    private var networkBlockRuleList: WKContentRuleList?
    private var liveSceneShowsEveryLabel = false
    private var networkBlockRuleListHasFinishedCompiling = false
    private var pageHasFinishedLoading = false
    private var queuedPageLoad: QueuedLiveScenePage?
    /// A new load cancels the previous one. Only the navigation that started last may play.
    private var navigationWeAreWaitingFor: WKNavigation?

    private override init() {
        super.init()
        compileHttpAndHttpsBlock()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "liveSceneLog" {
            print("Live scene page: \(message.body)")
            // Only uncaught errors count. console.error and console.warn are logged and ignored.
            if let logText = message.body as? String,
               logText.hasPrefix("page error:") || logText.hasPrefix("rejection:") {
                onPageError?(logText)
            }
            return
        }
        guard message.name == "liveSceneEvent" else {
            return
        }
        // The page posts this string when the camera tour ends.
        guard let eventName = message.body as? String, eventName == "tourFinished" else {
            return
        }
        onTourFinished?()
    }

    /// False means the page was refused. Generated code must never run without the network block in place.
    /// rendersMapTiles is only for the bundled landmark page, never for generated HTML.
    /// `overlayScreen` must be the screen the page's coordinates were computed for.
    func playLiveScene(html: String, hidesQuizLabel: Bool, rendersMapTiles: Bool = false, overlayScreen: NSScreen) -> Bool {
        guard networkBlockRuleList != nil else {
            print("Live scene: refused a live page because its network block is missing")
            return false
        }
        discardThePreviousWebView()
        placeOverlay(on: overlayScreen)
        liveSceneOverlayWindow?.ignoresMouseEvents = true
        queuedPageLoad = QueuedLiveScenePage(html: html, hidesQuizLabel: hidesQuizLabel, rendersMapTiles: rendersMapTiles)
        startQueuedPageLoad()
        return true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let navigationScheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let schemesThisPageMayOpen = ["about", "clicky-asset"]
        decisionHandler(schemesThisPageMayOpen.contains(navigationScheme) ? .allow : .cancel)
    }

    /// A window that catches the mouse blocks every click on the screen, so
    /// this stays off until the scene is finished and clear() turns it off.
    func letLearnerDragTheModel() {
        liveSceneOverlayWindow?.ignoresMouseEvents = false
        if liveSceneShowsEveryLabel {
            reveal()
        }
    }

    /// The overlay never becomes key, so AppKit does not deliver a pinch to it.
    /// CompanionManager passes in what the push-to-talk event tap sees instead.
    func zoomModelForPinch(magnification: Double) {
        guard let liveSceneOverlayWindow,
              !liveSceneOverlayWindow.ignoresMouseEvents,
              liveSceneOverlayWindow.frame.contains(NSEvent.mouseLocation) else { return }
        evaluateOnThePage(
            "window.liveScene.zoomBy(magnification)",
            arguments: ["magnification": magnification]
        )
    }

    func reveal() {
        evaluateOnThePage("window.liveScene.reveal()")
    }

    /// A generated page imports three.js, so window.liveScene can appear after
    /// the load event. Revealing then would fail and leave a "?" on the model.
    private func revealOnceTheGeneratedPageIsReady() {
        evaluateOnThePage("""
        for (let attempt = 0; attempt < 100; attempt += 1) {
          if (window.liveScene?.reveal) { window.liveScene.reveal(); return; }
          await new Promise((resolve) => setTimeout(resolve, 100));
        }
        """)
    }

    /// A generated page may leave out focusPart, so the call is optional.
    func highlightPart(labelText: String) {
        evaluateOnThePage("window.liveScene.focusPart?.(labelText)", arguments: ["labelText": labelText])
    }

    func partLabels() async -> [String] {
        guard let liveSceneWebView, pageHasFinishedLoading else { return [] }
        let pageResult = try? await liveSceneWebView.callAsyncJavaScript(
            "return [...document.querySelectorAll('.scene-label')].map((label) => label.textContent.trim())",
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        // The page returns a list of strings, and WebKit types it as Any.
        return (pageResult as? [String]) ?? []
    }

    func clear() {
        queuedPageLoad = nil
        liveSceneOverlayWindow?.ignoresMouseEvents = true
        liveSceneOverlayWindow?.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationWeAreWaitingFor = navigation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let navigationWeAreWaitingFor, navigation === navigationWeAreWaitingFor else {
            return
        }
        self.navigationWeAreWaitingFor = nil
        pageHasFinishedLoading = true
        deliverQueuedPageLoad()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("Live scene: web content process terminated")
        pageHasFinishedLoading = false
        liveSceneOverlayWindow?.ignoresMouseEvents = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        notePageLoadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        notePageLoadFailed(error)
    }

    private func compileHttpAndHttpsBlock() {
        guard let ruleListStore = WKContentRuleListStore.default() else {
            print("Live scene: content rule list store is unavailable")
            networkBlockRuleListHasFinishedCompiling = true
            return
        }
        ruleListStore.compileContentRuleList(
            forIdentifier: "LiveSceneBlocksHttpAndHttps",
            encodedContentRuleList: Self.httpAndHttpsBlockRuleListJSON
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                self?.finishCompilingTheHttpBlock(ruleList: ruleList, error: error)
            }
        }
    }

    private func finishCompilingTheHttpBlock(ruleList: WKContentRuleList?, error: Error?) {
        if let error {
            print("Live scene: http block failed to compile: \(error.localizedDescription)")
        }
        networkBlockRuleList = ruleList
        networkBlockRuleListHasFinishedCompiling = true
        startQueuedPageLoad()
    }

    private func placeOverlay(on screen: NSScreen) {
        if let liveSceneOverlayWindow {
            liveSceneOverlayWindow.setFrame(screen.frame, display: true)
            liveSceneOverlayWindow.orderFrontRegardless()
            return
        }
        let liveSceneOverlayWindow = OverlayWindow(screen: screen)
        self.liveSceneOverlayWindow = liveSceneOverlayWindow
        liveSceneOverlayWindow.orderFrontRegardless()
    }

    private func startQueuedPageLoad() {
        guard networkBlockRuleListHasFinishedCompiling else { return }
        guard liveSceneOverlayWindow != nil else { return }
        guard let queuedPageLoad else { return }
        ensureLiveSceneWebView()
        guard liveSceneWebView != nil else { return }

        beginReplacingTheDocument()
        guard let livePageURL = URL(string: LiveSceneAssetSchemeHandler.livePageURLString) else { return }
        threeAssetSchemeHandler.livePageHTMLData = Data(queuedPageLoad.html.utf8)
        threeAssetSchemeHandler.livePageRendersMapTiles = queuedPageLoad.rendersMapTiles
        liveSceneWebView?.load(URLRequest(url: livePageURL))
    }

    private func beginReplacingTheDocument() {
        navigationWeAreWaitingFor = nil
        pageHasFinishedLoading = false
    }

    private func deliverQueuedPageLoad() {
        guard let queuedPageLoad else { return }
        self.queuedPageLoad = nil
        liveSceneShowsEveryLabel = !queuedPageLoad.hidesQuizLabel
        if !queuedPageLoad.hidesQuizLabel {
            revealOnceTheGeneratedPageIsReady()
        }
    }

    /// A reused web view shows the previous page for a few frames when the window
    /// comes back, before the new page paints. A fresh web view has nothing to show.
    private func discardThePreviousWebView() {
        guard let previousWebView = liveSceneWebView else { return }
        previousWebView.stopLoading()
        previousWebView.navigationDelegate = nil
        previousWebView.configuration.userContentController.removeAllScriptMessageHandlers()
        liveSceneWebView = nil
        pageHasFinishedLoading = false
    }

    private func ensureLiveSceneWebView() {
        guard liveSceneWebView == nil, let liveSceneOverlayWindow else { return }
        let webViewFrame = liveSceneOverlayWindow.contentView?.bounds
            ?? CGRect(origin: .zero, size: liveSceneOverlayWindow.frame.size)
        let liveSceneWebView = makeLiveSceneWebView(frame: webViewFrame)
        liveSceneOverlayWindow.contentView = liveSceneWebView
        self.liveSceneWebView = liveSceneWebView
    }

    private func makeLiveSceneWebView(frame: CGRect) -> WKWebView {
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.setURLSchemeHandler(threeAssetSchemeHandler, forURLScheme: "clicky-asset")
        if let networkBlockRuleList {
            webViewConfiguration.userContentController.add(networkBlockRuleList)
        }
        webViewConfiguration.userContentController.add(self, name: "liveSceneLog")
        webViewConfiguration.userContentController.add(self, name: "liveSceneEvent")
        webViewConfiguration.userContentController.addUserScript(WKUserScript(
            source: Self.pageErrorForwardingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))

        let webView = LiveSceneWebView(frame: frame, configuration: webViewConfiguration)
        webView.autoresizingMask = [.width, .height]
        #if DEBUG
        webView.isInspectable = true
        #endif
        // drawsBackground is a private WKWebView switch. It has to be off or
        // WebKit paints an opaque layer over the desktop.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // The page script defines window.liveScene. Play waits until that has run.
        webView.navigationDelegate = self
        return webView
    }

    private func notePageLoadFailed(_ error: Error) {
        guard !navigationWasCancelled(error) else { return }
        print("Live scene: page failed to load: \(error.localizedDescription)")
        pageHasFinishedLoading = false
    }

    private func navigationWasCancelled(_ error: Error) -> Bool {
        let urlError = error as? URLError
        return urlError?.code == .cancelled
    }

    // arguments uses WebKit's dictionary type. Callers pass JSON values.
    private func evaluateOnThePage(_ functionBody: String, arguments: [String: Any] = [:]) {
        guard let liveSceneWebView, pageHasFinishedLoading else {
            return
        }
        liveSceneWebView.callAsyncJavaScript(
            functionBody,
            arguments: arguments,
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                print("Live scene: page call failed: \(error.localizedDescription)")
            }
        }
    }
}

/// The scene overlay and the status label both follow the mouse, so they share this screen lookup.
func screenUnderTheMouseCursor() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    if let screenContainingTheMouse = NSScreen.screens.first(where: { screen in
        screen.frame.contains(mouseLocation)
    }) {
        return screenContainingTheMouse
    }
    return NSScreen.screens.first
}
