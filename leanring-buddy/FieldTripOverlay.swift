//
//  FieldTripOverlay.swift
//  leanring-buddy
//
//  One transparent window and one page, reused for every field trip. The
//  window is created on the screen under the mouse, and later plays move it
//  there again. A template spec plays in FieldTripScene.html. A live scene
//  loads generated HTML in that same window. The page reports tourFinished
//  when the camera tour ends.
//

import AppKit
import WebKit

/// The overlay window never becomes key, so AppKit would otherwise drop the
/// click that starts a drag.
private final class FieldTripWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Generated pages import three.js from clicky-asset://three/..., because that
/// page is not allowed to reach a CDN. The two files ship in the app bundle.
private final class FieldTripThreeAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    private let stoppedTaskLock = NSLock()
    private let stoppedTasks = NSHashTable<AnyObject>.weakObjects()

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            fail(urlSchemeTask, message: "Three.js request had no URL")
            return
        }
        let fileName = requestURL.lastPathComponent
        guard fileName == "three.module.js" || fileName == "three.core.js" else {
            fail(urlSchemeTask, message: "Refusing to serve \(fileName)")
            return
        }
        guard let scriptData = bundledScript(named: fileName) else {
            print("Field trip: \(fileName) is not in the app bundle")
            fail(urlSchemeTask, message: "\(fileName) is not in the app bundle")
            return
        }
        guard let scriptResponse = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/javascript",
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

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        stoppedTaskLock.lock()
        stoppedTasks.add(urlSchemeTask as AnyObject)
        stoppedTaskLock.unlock()
    }

    private func bundledScript(named fileName: String) -> Data? {
        let resourceName = (fileName as NSString).deletingPathExtension
        let fileURL = Bundle.main.url(
            forResource: resourceName,
            withExtension: "js",
            subdirectory: "LiveSceneAssets"
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: "js")
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
            domain: "FieldTripScene",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}

// A class, not an enum: WKNavigationDelegate has to be an NSObject.
final class FieldTripOverlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = FieldTripOverlay()

    var onTourFinished: (() -> Void)?

    private static let pageErrorForwardingScript = """
    (() => {
      const send = (text) => window.webkit.messageHandlers.fieldTripLog.postMessage(String(text));
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
      }
    ]
    """

    private enum QueuedFieldTripPage {
        case template(specJSONData: Data, hidesQuizLabel: Bool)
        case live(html: String, hidesQuizLabel: Bool)
    }

    private enum LoadedFieldTripPage {
        case none
        case template
        case live
    }

    private let threeAssetSchemeHandler = FieldTripThreeAssetSchemeHandler()
    private var fieldTripOverlayWindow: OverlayWindow?
    private var fieldTripWebView: WKWebView?
    private var networkBlockRuleList: WKContentRuleList?
    private var networkBlockRuleListHasFinishedCompiling = false
    private var pageHasFinishedLoading = false
    private var loadedPageKind: LoadedFieldTripPage = .none
    private var queuedPageLoad: QueuedFieldTripPage?
    /// A new load cancels the previous one. Only the navigation that started last may play.
    private var navigationWeAreWaitingFor: WKNavigation?

    private override init() {
        super.init()
        compileHttpAndHttpsBlock()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "fieldTripLog" {
            print("Field trip page: \(message.body)")
            return
        }
        guard message.name == "fieldTripEvent" else {
            return
        }
        // The page posts this string when the camera tour ends.
        guard let eventName = message.body as? String, eventName == "tourFinished" else {
            return
        }
        onTourFinished?()
    }

    func play(specJSONData: Data, hidesQuizLabel: Bool) {
        placeOverlayOnTheScreenUnderTheMouse()
        fieldTripOverlayWindow?.ignoresMouseEvents = true
        queuedPageLoad = .template(specJSONData: specJSONData, hidesQuizLabel: hidesQuizLabel)
        startQueuedPageLoad()
    }

    /// False means the page was refused and the caller should use a template.
    /// Generated code must never run without both network blocks in place.
    func playLiveScene(html: String, hidesQuizLabel: Bool) -> Bool {
        let networkBlockFailedToCompile = networkBlockRuleListHasFinishedCompiling && networkBlockRuleList == nil
        guard !networkBlockFailedToCompile,
              let htmlWithPolicy = Self.htmlWithContentSecurityPolicy(html) else {
            print("Field trip: refused a live page because its network block is missing")
            return false
        }
        placeOverlayOnTheScreenUnderTheMouse()
        fieldTripOverlayWindow?.ignoresMouseEvents = true
        queuedPageLoad = .live(html: htmlWithPolicy, hidesQuizLabel: hidesQuizLabel)
        startQueuedPageLoad()
        return true
    }

    /// The rule list only stops http and https, so this policy is what stops
    /// WebSockets. It has to come first, because it only covers what follows it.
    private static func htmlWithContentSecurityPolicy(_ html: String) -> String? {
        guard let headTagRange = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let htmlBeforeHead = html[..<headTagRange.lowerBound].lowercased()
        let tagsThatCouldRunFirst = ["<script", "<link", "<base", "<meta", "<iframe"]
        if tagsThatCouldRunFirst.contains(where: { htmlBeforeHead.contains($0) }) {
            return nil
        }
        let policy = "default-src 'none'; script-src 'unsafe-inline' clicky-asset:; style-src 'unsafe-inline'; img-src data: blob:; connect-src clicky-asset:; base-uri 'none'; form-action 'none'"
        var htmlWithPolicy = html
        htmlWithPolicy.insert(
            contentsOf: "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">",
            at: headTagRange.upperBound
        )
        return htmlWithPolicy
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let navigationScheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let schemesThisPageMayOpen = ["about", "file", "clicky-asset"]
        decisionHandler(schemesThisPageMayOpen.contains(navigationScheme) ? .allow : .cancel)
    }

    /// A window that catches the mouse blocks every click on the screen, so
    /// this stays off until the scene is finished and clear() turns it off.
    func letLearnerDragTheModel() {
        fieldTripOverlayWindow?.ignoresMouseEvents = false
    }

    /// The overlay never becomes key, so AppKit does not deliver a pinch to it.
    /// CompanionManager passes in what the push-to-talk event tap sees instead.
    func zoomModelForPinch(magnification: Double) {
        guard let fieldTripOverlayWindow,
              !fieldTripOverlayWindow.ignoresMouseEvents,
              fieldTripOverlayWindow.frame.contains(NSEvent.mouseLocation) else { return }
        evaluateOnThePage(
            "window.fieldTrip.zoomBy(magnification)",
            arguments: ["magnification": magnification]
        )
    }

    func reveal() {
        evaluateOnThePage("window.fieldTrip.reveal()")
    }

    func clear() {
        queuedPageLoad = nil
        fieldTripOverlayWindow?.ignoresMouseEvents = true
        evaluateOnThePage("window.fieldTrip.clear()")
        fieldTripOverlayWindow?.orderOut(nil)
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
        print("Field trip: web content process terminated")
        pageHasFinishedLoading = false
        loadedPageKind = .none
        fieldTripOverlayWindow?.ignoresMouseEvents = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        notePageLoadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        notePageLoadFailed(error)
    }

    private func compileHttpAndHttpsBlock() {
        guard let ruleListStore = WKContentRuleListStore.default() else {
            print("Field trip: content rule list store is unavailable")
            networkBlockRuleListHasFinishedCompiling = true
            return
        }
        ruleListStore.compileContentRuleList(
            forIdentifier: "FieldTripBlocksHttpAndHttps",
            encodedContentRuleList: Self.httpAndHttpsBlockRuleListJSON
        ) { [weak self] ruleList, error in
            DispatchQueue.main.async {
                self?.finishCompilingTheHttpBlock(ruleList: ruleList, error: error)
            }
        }
    }

    private func finishCompilingTheHttpBlock(ruleList: WKContentRuleList?, error: Error?) {
        if let error {
            print("Field trip: http block failed to compile: \(error.localizedDescription)")
        }
        networkBlockRuleList = ruleList
        networkBlockRuleListHasFinishedCompiling = true
        startQueuedPageLoad()
    }

    private func screenUnderTheMouseCursor() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screenContainingTheMouse = NSScreen.screens.first(where: { screen in
            screen.frame.contains(mouseLocation)
        }) {
            return screenContainingTheMouse
        }
        return NSScreen.screens.first
    }

    private func placeOverlayOnTheScreenUnderTheMouse() {
        guard let screen = screenUnderTheMouseCursor() else {
            print("Field trip: no screen is available")
            return
        }
        if let fieldTripOverlayWindow {
            fieldTripOverlayWindow.setFrame(screen.frame, display: true)
            fieldTripOverlayWindow.orderFrontRegardless()
            return
        }
        let fieldTripOverlayWindow = OverlayWindow(screen: screen)
        self.fieldTripOverlayWindow = fieldTripOverlayWindow
        fieldTripOverlayWindow.orderFrontRegardless()
    }

    private func startQueuedPageLoad() {
        guard networkBlockRuleListHasFinishedCompiling else { return }
        guard fieldTripOverlayWindow != nil else { return }
        guard let queuedPageLoad else { return }
        ensureFieldTripWebView()
        guard fieldTripWebView != nil else { return }

        switch queuedPageLoad {
        case .template(let specJSONData, let hidesQuizLabel):
            if loadedPageKind == .template && pageHasFinishedLoading {
                self.queuedPageLoad = nil
                sendSpecToPage(specJSONData, hidesQuizLabel: hidesQuizLabel)
                return
            }
            // The template document is already on its way. didFinish plays the latest spec.
            if loadedPageKind == .template && !pageHasFinishedLoading {
                return
            }
            guard let scenePageURL = Bundle.main.url(forResource: "FieldTripScene", withExtension: "html") else {
                print("Field trip: FieldTripScene.html is not in the app bundle")
                return
            }
            // A live page replaced window.fieldTrip.play, so the template file has to load again.
            beginReplacingTheDocument()
            loadedPageKind = .template
            fieldTripWebView?.loadFileURL(
                scenePageURL,
                allowingReadAccessTo: scenePageURL.deletingLastPathComponent()
            )
        case .live(let html, _):
            beginReplacingTheDocument()
            loadedPageKind = .live
            fieldTripWebView?.loadHTMLString(html, baseURL: nil)
        }
    }

    private func beginReplacingTheDocument() {
        navigationWeAreWaitingFor = nil
        pageHasFinishedLoading = false
    }

    private func deliverQueuedPageLoad() {
        guard let queuedPageLoad else { return }
        switch queuedPageLoad {
        case .template(let specJSONData, let hidesQuizLabel):
            guard loadedPageKind == .template else { return }
            self.queuedPageLoad = nil
            sendSpecToPage(specJSONData, hidesQuizLabel: hidesQuizLabel)
        case .live(_, let hidesQuizLabel):
            guard loadedPageKind == .live else { return }
            self.queuedPageLoad = nil
            if !hidesQuizLabel {
                evaluateOnThePage("window.fieldTrip.reveal()")
            }
        }
    }

    private func ensureFieldTripWebView() {
        guard fieldTripWebView == nil, let fieldTripOverlayWindow else { return }
        let webViewFrame = fieldTripOverlayWindow.contentView?.bounds
            ?? CGRect(origin: .zero, size: fieldTripOverlayWindow.frame.size)
        let fieldTripWebView = makeFieldTripWebView(frame: webViewFrame)
        fieldTripOverlayWindow.contentView = fieldTripWebView
        self.fieldTripWebView = fieldTripWebView
    }

    private func makeFieldTripWebView(frame: CGRect) -> WKWebView {
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.setURLSchemeHandler(threeAssetSchemeHandler, forURLScheme: "clicky-asset")
        if let networkBlockRuleList {
            webViewConfiguration.userContentController.add(networkBlockRuleList)
        }
        webViewConfiguration.userContentController.add(self, name: "fieldTripLog")
        webViewConfiguration.userContentController.add(self, name: "fieldTripEvent")
        webViewConfiguration.userContentController.addUserScript(WKUserScript(
            source: Self.pageErrorForwardingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let webView = FieldTripWebView(frame: frame, configuration: webViewConfiguration)
        webView.autoresizingMask = [.width, .height]
        #if DEBUG
        webView.isInspectable = true
        #endif
        // drawsBackground is a private WKWebView switch. It has to be off or
        // WebKit paints an opaque layer over the desktop.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // The page script defines window.fieldTrip. Play waits until that has run.
        webView.navigationDelegate = self
        return webView
    }

    private func sendSpecToPage(_ specJSONData: Data, hidesQuizLabel: Bool) {
        do {
            let specJSONValue = try JSONSerialization.jsonObject(with: specJSONData)
            // JSONSerialization returns Any. callAsyncJavaScript takes a dictionary,
            // and a scene spec is a JSON object.
            guard let specDictionary = specJSONValue as? [String: Any] else {
                print("Field trip: spec JSON was not an object")
                return
            }
            evaluateOnThePage(
                "window.fieldTrip.play(spec, hidesQuizLabel)",
                arguments: ["spec": specDictionary, "hidesQuizLabel": hidesQuizLabel]
            )
        } catch {
            print("Field trip: spec JSON could not be parsed: \(error.localizedDescription)")
        }
    }

    private func notePageLoadFailed(_ error: Error) {
        guard !navigationWasCancelled(error) else { return }
        print("Field trip: page failed to load: \(error.localizedDescription)")
        // A failed load must not look like a template page that is still loading,
        // or the next play would wait for a didFinish that never comes.
        pageHasFinishedLoading = false
        loadedPageKind = .none
    }

    private func navigationWasCancelled(_ error: Error) -> Bool {
        let urlError = error as? URLError
        return urlError?.code == .cancelled
    }

    // arguments uses WebKit's dictionary type. Callers pass JSON values.
    private func evaluateOnThePage(_ functionBody: String, arguments: [String: Any] = [:]) {
        guard let fieldTripWebView, pageHasFinishedLoading else {
            return
        }
        fieldTripWebView.callAsyncJavaScript(
            functionBody,
            arguments: arguments,
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result {
                print("Field trip: page call failed: \(error.localizedDescription)")
            }
        }
    }
}
