//
//  FieldTripOverlay.swift
//  leanring-buddy
//
//  One transparent window and one page, reused for every field trip. The
//  window is created on the screen under the mouse, and later plays move it
//  there again. The page reports tourFinished when the camera tour ends.
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

    private var fieldTripOverlayWindow: OverlayWindow?
    private var fieldTripWebView: WKWebView?
    private var pageHasFinishedLoading = false
    private var queuedPlay: (specJSONData: Data, hidesQuizLabel: Bool)?

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
        guard fieldTripWebView != nil else {
            return
        }
        if pageHasFinishedLoading {
            queuedPlay = nil
            sendSpecToPage(specJSONData, hidesQuizLabel: hidesQuizLabel)
        } else {
            queuedPlay = (specJSONData, hidesQuizLabel)
        }
    }

    /// A window that catches the mouse blocks every click on the screen, so
    /// this stays off until the scene is finished and clear() turns it off.
    func letLearnerDragTheModel() {
        fieldTripOverlayWindow?.ignoresMouseEvents = false
    }

    func reveal() {
        evaluateOnThePage("window.fieldTrip.reveal()")
    }

    func clear() {
        queuedPlay = nil
        fieldTripOverlayWindow?.ignoresMouseEvents = true
        evaluateOnThePage("window.fieldTrip.clear()")
        fieldTripOverlayWindow?.orderOut(nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageHasFinishedLoading = true
        guard let queuedPlay else {
            return
        }
        self.queuedPlay = nil
        sendSpecToPage(queuedPlay.specJSONData, hidesQuizLabel: queuedPlay.hidesQuizLabel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        print("Field trip: web content process terminated")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Field trip: page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("Field trip: page failed to load: \(error.localizedDescription)")
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
        guard let scenePageURL = Bundle.main.url(forResource: "FieldTripScene", withExtension: "html") else {
            print("Field trip: FieldTripScene.html is not in the app bundle")
            return
        }

        let fieldTripOverlayWindow = OverlayWindow(screen: screen)
        let webViewFrame = fieldTripOverlayWindow.contentView?.bounds
            ?? CGRect(origin: .zero, size: screen.frame.size)
        let fieldTripWebView = makeFieldTripWebView(frame: webViewFrame)
        fieldTripOverlayWindow.contentView = fieldTripWebView
        self.fieldTripOverlayWindow = fieldTripOverlayWindow
        self.fieldTripWebView = fieldTripWebView
        fieldTripOverlayWindow.orderFrontRegardless()
        fieldTripWebView.loadFileURL(
            scenePageURL,
            allowingReadAccessTo: scenePageURL.deletingLastPathComponent()
        )
    }

    private func makeFieldTripWebView(frame: CGRect) -> WKWebView {
        let webViewConfiguration = WKWebViewConfiguration()
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
