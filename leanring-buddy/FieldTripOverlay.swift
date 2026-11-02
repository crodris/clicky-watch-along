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
final class FieldTripOverlay: NSObject, WKNavigationDelegate {
    static let shared = FieldTripOverlay()

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

        let webView = WKWebView(frame: overlayWindow.contentView?.bounds ?? .zero)
        webView.autoresizingMask = [.width, .height]
        // drawsBackground is a private WKWebView switch. It has to be off or
        // WebKit paints an opaque layer over the desktop.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        // The page script defines window.fieldTrip. Play waits until that has run.
        webView.navigationDelegate = self

        overlayWindow.contentView = webView
        overlayWindow.orderFrontRegardless()
        webView.loadFileURL(scenePageURL, allowingReadAccessTo: scenePageURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didPlaySpec, let specJSONText else {
            return
        }
        didPlaySpec = true
        let playScript = "window.fieldTrip.play(\(specJSONText))"
        webView.evaluateJavaScript(playScript) { _, error in
            if let error {
                print("Field trip: play failed: \(error.localizedDescription)")
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("Field trip: page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        print("Field trip: page failed to load: \(error.localizedDescription)")
    }
}
