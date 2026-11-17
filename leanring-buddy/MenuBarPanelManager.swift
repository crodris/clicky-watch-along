//
//  MenuBarPanelManager.swift
//  leanring-buddy
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let clickyDismissPanel = Notification.Name("clickyDismissPanel")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var isShowingVolleyballIcon = false
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var themeIconSubscription: AnyCancellable?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = 320
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()
        themeIconSubscription = companionManager.themeSettings.$theme.sink { [weak self] theme in
            self?.showVolleyballIcon(theme.usesVolleyballMenuBarIcon)
        }

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makeClickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Draws the clicky triangle as a menu bar icon. Uses the same shape
    /// and rotation as the in-app cursor so the menu bar icon matches.
    private func makeClickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let triangleSize = iconSize * 0.7
        let cx = iconSize * 0.50
        let cy = iconSize * 0.50
        let height = triangleSize * sqrt(3.0) / 2.0

        let top = CGPoint(x: cx, y: cy + height / 1.5)
        let bottomLeft = CGPoint(x: cx - triangleSize / 2, y: cy - height / 3)
        let bottomRight = CGPoint(x: cx + triangleSize / 2, y: cy - height / 3)

        let angle = 35.0 * .pi / 180.0
        func rotate(_ point: CGPoint) -> CGPoint {
            let dx = point.x - cx, dy = point.y - cy
            let cosA = CGFloat(cos(angle)), sinA = CGFloat(sin(angle))
            return CGPoint(x: cx + cosA * dx - sinA * dy, y: cy + sinA * dx + cosA * dy)
        }

        let path = NSBezierPath()
        path.move(to: rotate(top))
        path.line(to: rotate(bottomLeft))
        path.line(to: rotate(bottomRight))
        path.close()

        NSColor.black.setFill()
        path.fill()

        image.unlockFocus()
        return image
    }

    /// Swaps the menu bar icon between the clicky triangle and a volleyball.
    /// A team theme turns the volleyball on. Does nothing when the icon
    /// already matches, so repeated theme updates never reset the button image.
    private func showVolleyballIcon(_ shouldShowVolleyball: Bool) {
        guard shouldShowVolleyball != isShowingVolleyballIcon else { return }
        guard let button = statusItem?.button else { return }

        let iconImage = shouldShowVolleyball ? makeVolleyballMenuBarIcon() : makeClickyMenuBarIcon()
        iconImage.isTemplate = true
        button.image = iconImage
        isShowingVolleyballIcon = shouldShowVolleyball
    }

    /// Draws a volleyball as an 18 point template icon: a circle outline and
    /// three long curved seams that cross to form a small triangle at the
    /// center. The image is black on clear, so macOS tints it for light and
    /// dark menu bars like the triangle icon.
    private func makeVolleyballMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        let center = CGPoint(x: iconSize / 2, y: iconSize / 2)
        // Inset by just over half the outline width so the stroke stays inside the image.
        let ballRadius = iconSize / 2 - 1.1
        let outlineLineWidth: CGFloat = 1.3
        let seamLineWidth: CGFloat = 1.1

        // How far around the ball each seam travels (radians), and how close to the
        // center its curve pulls. A long sweep with the pull near the center gives
        // the swirl of a real volleyball. Shorter sweeps read as a play button.
        let seamSweepRadians: CGFloat = 2.4
        let seamCurveControlRadiusShare: CGFloat = 0.05
        // Turns the whole seam pattern so no seam sits exactly at the top.
        let seamPatternRotationRadians: CGFloat = 0.4

        func pointOnBall(angleRadians: CGFloat, radiusShare: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + cos(angleRadians) * radiusShare * ballRadius,
                y: center.y + sin(angleRadians) * radiusShare * ballRadius
            )
        }

        NSColor.black.setStroke()

        let outlinePath = NSBezierPath(ovalIn: NSRect(
            x: center.x - ballRadius,
            y: center.y - ballRadius,
            width: ballRadius * 2,
            height: ballRadius * 2
        ))
        outlinePath.lineWidth = outlineLineWidth
        outlinePath.stroke()

        for seamIndex in 0..<3 {
            let seamStartAngle = CGFloat(seamIndex) * 2.0 * .pi / 3.0 + .pi / 2 + seamPatternRotationRadians
            let seamStart = pointOnBall(angleRadians: seamStartAngle, radiusShare: 1.0)
            let seamEnd = pointOnBall(angleRadians: seamStartAngle - seamSweepRadians, radiusShare: 1.0)
            let seamCurveControl = pointOnBall(
                angleRadians: seamStartAngle - seamSweepRadians / 2,
                radiusShare: seamCurveControlRadiusShare
            )

            // NSBezierPath has no quadratic curve, so raise the single control
            // point to the two cubic control points that draw the same curve.
            let seamPath = NSBezierPath()
            seamPath.move(to: seamStart)
            seamPath.curve(
                to: seamEnd,
                controlPoint1: CGPoint(
                    x: seamStart.x + 2.0 / 3.0 * (seamCurveControl.x - seamStart.x),
                    y: seamStart.y + 2.0 / 3.0 * (seamCurveControl.y - seamStart.y)
                ),
                controlPoint2: CGPoint(
                    x: seamEnd.x + 2.0 / 3.0 * (seamCurveControl.x - seamEnd.x),
                    y: seamEnd.y + 2.0 / 3.0 * (seamCurveControl.y - seamEnd.y)
                )
            )
            seamPath.lineWidth = seamLineWidth
            seamPath.lineCapStyle = .round
            seamPath.stroke()
        }

        image.unlockFocus()
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager)
            .frame(width: panelWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        menuBarPanel.level = .floating
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss during onboarding.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
