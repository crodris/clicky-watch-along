//
//  ChromeWebArea.swift
//  leanring-buddy
//
//  Where the page viewport of Chrome's focused window sits on screen, read from Chrome's
//  accessibility tree. The page geometry alone cannot say: Chrome's side panels, vertical tabs,
//  and docked DevTools all take window space on either side of the viewport, and the page
//  cannot see which side.
//

import ApplicationServices
import AppKit
import Foundation

enum ChromeWebArea {
    private static let webAreaRole = "AXWebArea"
    private static let maximumTreeDepth = 30
    private static let maximumVisitedElementCount = 4000
    /// A busy Chrome would otherwise hold each accessibility call for the 6-second default, and these calls
    /// run on the main actor, which also serves the push-to-talk shortcut. A timeout applies only to the
    /// element it is set on, so every element gets it before its first call.
    private static let secondsToWaitForEachAccessibilityCall: Float = 0.5

    /// The screen frames of every web area in Chrome's focused window, in global points with the origin
    /// at the top left of the main display, which is the space Chrome's `screenX` uses.
    /// A docked DevTools has a web area of its own, so there can be more than one. Empty on any failure,
    /// such as Chrome not running or Accessibility not being allowed, and never throws.
    static func webAreaFramesOfChromesFocusedWindow() -> [CGRect] {
        guard let chromeProcessIdentifier = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.google.Chrome").first?.processIdentifier else {
            return []
        }
        let chromeApplicationElement = AXUIElementCreateApplication(chromeProcessIdentifier)
        AXUIElementSetMessagingTimeout(chromeApplicationElement, secondsToWaitForEachAccessibilityCall)
        // Chrome builds its accessibility tree only after a client asks for it, so without this flag the
        // window has no web area in it. Chrome then keeps the tree on for the rest of its session, which
        // costs its renderers some CPU and memory. Setting it again on a later call changes nothing more.
        AXUIElementSetAttributeValue(chromeApplicationElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        // There is one try and no wait. On the first call of a Chrome session the tree may not be built yet,
        // and the caller then places the rect from the page geometry instead.
        guard let focusedWindowElement = elementAttribute(kAXFocusedWindowAttribute, of: chromeApplicationElement)
            ?? elementAttribute(kAXMainWindowAttribute, of: chromeApplicationElement) else {
            return []
        }
        return webAreaFramesInTree(of: focusedWindowElement)
    }

    /// Walks the tree breadth first and collects each web area. It does not look inside a web area,
    /// because an iframe in the page is a web area nested in the page's own.
    private static func webAreaFramesInTree(of windowElement: AXUIElement) -> [CGRect] {
        var elementsToVisit: [(element: AXUIElement, depth: Int)] = [(element: windowElement, depth: 0)]
        var nextIndexToVisit = 0
        var webAreaFrames: [CGRect] = []
        while nextIndexToVisit < elementsToVisit.count, nextIndexToVisit < maximumVisitedElementCount {
            let (element, depth) = elementsToVisit[nextIndexToVisit]
            nextIndexToVisit += 1
            if (attributeValue(kAXRoleAttribute, of: element) as? String) == webAreaRole {
                if let webAreaFrame = frame(of: element) {
                    webAreaFrames.append(webAreaFrame)
                }
                continue
            }
            guard depth < maximumTreeDepth,
                  let childElements = attributeValue(kAXChildrenAttribute, of: element) as? [AXUIElement] else {
                continue
            }
            elementsToVisit.append(contentsOf: childElements.map { childElement in (element: childElement, depth: depth + 1) })
        }
        return webAreaFrames
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = attributeValue(kAXPositionAttribute, of: element),
              let sizeValue = attributeValue(kAXSizeAttribute, of: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }
        var position = CGPoint.zero
        var size = CGSize.zero
        // The type ID checks above prove both values are AXValues, and Swift cannot check CF types itself.
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    /// Nil when the attribute is missing or the call fails, such as when Accessibility is not allowed.
    private static func attributeValue(_ attributeName: String, of element: AXUIElement) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, secondsToWaitForEachAccessibilityCall)
        var copiedValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attributeName as CFString, &copiedValue)
        return result == .success ? copiedValue : nil
    }

    private static func elementAttribute(_ attributeName: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = attributeValue(attributeName, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        // The type ID check above proves the value is an AXUIElement, and Swift cannot check CF types itself.
        return (value as! AXUIElement)
    }
}

/// The element's place on screen from the web area frame that matches the page's shape.
/// A CSS pixel is `pageZoom` points, and the web area's width over the viewport's CSS width gives it,
/// so unlike the window-frame math this holds with any panel on either side of the page.
/// A docked DevTools is a web area of a different shape, so only the web area whose width to height
/// ratio is within 3 percent of the viewport's counts. Nil when none does.
func screenRectInChromeCoordinates(from pageGeometry: ChromePageGeometry, matchingWebAreaFrames webAreaFrames: [CGRect]) -> ScreenRectInChromeCoordinates? {
    guard pageGeometry.innerWidth > 0, pageGeometry.innerHeight > 0 else { return nil }
    let viewportAspectRatio = pageGeometry.innerWidth / pageGeometry.innerHeight
    // Starting at the limit means only a web area under 3 percent away can become the match.
    var smallestAspectRatioDifferenceShare = 0.03
    var matchingWebAreaFrame: CGRect?
    for webAreaFrame in webAreaFrames {
        guard webAreaFrame.width > 0, webAreaFrame.height > 0 else { continue }
        let webAreaAspectRatio = Double(webAreaFrame.width / webAreaFrame.height)
        let aspectRatioDifferenceShare = abs(webAreaAspectRatio - viewportAspectRatio) / viewportAspectRatio
        if aspectRatioDifferenceShare < smallestAspectRatioDifferenceShare {
            smallestAspectRatioDifferenceShare = aspectRatioDifferenceShare
            matchingWebAreaFrame = webAreaFrame
        }
    }
    guard let matchingWebAreaFrame else { return nil }

    let pageZoom = Double(matchingWebAreaFrame.width) / pageGeometry.innerWidth
    return ScreenRectInChromeCoordinates(
        rectX: Double(matchingWebAreaFrame.minX) + pageGeometry.left * pageZoom,
        rectY: Double(matchingWebAreaFrame.minY) + pageGeometry.top * pageZoom,
        rectWidth: pageGeometry.width * pageZoom,
        rectHeight: pageGeometry.height * pageZoom
    )
}
