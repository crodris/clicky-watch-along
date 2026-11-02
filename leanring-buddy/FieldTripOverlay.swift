//
//  FieldTripOverlay.swift
//  leanring-buddy
//
//  Plays a bundled field-trip scene inside the transparent cursor overlay.
//  The page is self-contained. Nothing here talks to the Worker.
//

import AppKit
import WebKit

// A class, not an enum: WKNavigationDelegate has to be an NSObject.
final class FieldTripOverlay: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    static let shared = FieldTripOverlay()

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

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print("Field trip page: \(message.body)")
    }

    // A local OverlayWindow would be released when play returns.
    // Nothing else owns this window, so the static keeps the scene up.
    private var retainedOverlayWindow: OverlayWindow?
    private var specJSONText: String?
    private var didPlaySpec = false

    func play(specJSONText: String) {
        guard let mainScreen = NSScreen.main else {
            print("Field trip: NSScreen.main was nil")
            return
        }

        guard let scenePageURL = Bundle.main.url(forResource: "FieldTripScene", withExtension: "html") else {
            print("Field trip: FieldTripScene.html is not in the app bundle")
            return
        }

        self.specJSONText = specJSONText
        didPlaySpec = false

        let overlayWindow = OverlayWindow(screen: mainScreen)
        retainedOverlayWindow = overlayWindow

        // WebKit keeps page errors to itself, so shader and script failures would
        // otherwise show up as an empty overlay with nothing in the app log.
        let webViewConfiguration = WKWebViewConfiguration()
        webViewConfiguration.userContentController.add(self, name: "fieldTripLog")
        webViewConfiguration.userContentController.addUserScript(WKUserScript(
            source: Self.pageErrorForwardingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        let webView = WKWebView(
            frame: overlayWindow.contentView?.bounds ?? .zero,
            configuration: webViewConfiguration
        )
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

        overlayWindow.contentView = webView
        overlayWindow.orderFrontRegardless()
        print("Field trip: loading \(scenePageURL.path), screen \(mainScreen.frame), window visible \(overlayWindow.isVisible)")
        webView.loadFileURL(scenePageURL, allowingReadAccessTo: scenePageURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didPlaySpec, let specJSONText else {
            return
        }
        didPlaySpec = true
        print("Field trip: page loaded, webView frame \(webView.frame), device scale \(webView.window?.backingScaleFactor ?? 0)")
        // The trailing void keeps evaluateJavaScript from serializing a result.
        let playScript = "window.fieldTrip.play(\(specJSONText)); void 0"
        webView.evaluateJavaScript(playScript) { _, error in
            if let error {
                print("Field trip: play failed: \(error)")
            } else {
                print("Field trip: play started")
            }
        }
        let diagnosticScript = """
        (() => { const c = document.querySelector('canvas'); const g = c && c.getContext('webgl2');
        return JSON.stringify({ size: c ? [c.width, c.height, innerWidth, innerHeight] : null, webgl: !!g,
        lost: g ? g.isContextLost() : null, title: document.title, labels: document.querySelectorAll('body div').length }); })()
        """
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            webView.evaluateJavaScript(diagnosticScript) { result, error in
                print("Field trip: page state \(result ?? "none") \(error.map { "\($0)" } ?? "")")
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        print("Field trip: navigation started \(webView.url?.absoluteString ?? "nil")")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        print("Field trip: navigation committed")
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
}
