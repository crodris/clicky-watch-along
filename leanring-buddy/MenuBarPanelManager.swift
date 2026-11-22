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
    /// Sent by the settings dial's More slice to open the panel the menu bar icon opens.
    static let clickyShowPanel = Notification.Name("clickyShowPanel")
    /// Sent by the Debug tool server's `debug_click_menu_bar_icon`: clicks the status item's button, as a click on the icon does.
    static let clickyClickMenuBarIcon = Notification.Name("clickyClickMenuBarIcon")
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    /// A global monitor never sees a click the window server delivers to this app's own window, so a click on the
    /// shadow around the card needs this local one to count as outside.
    private var clickOnShadowMarginMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var showPanelObserver: NSObjectProtocol?
    private var clickMenuBarIconObserver: NSObjectProtocol?
    private var savedThemesSubscription: AnyCancellable?
    /// Keeps the status item's icon in step with the voice state, the shown theme, and the approval desk.
    private var statusIconController: MenuBarStatusIconController?

    private let companionManager: CompanionManager
    private let panelWidth: CGFloat = CompanionPanelView.contentWidth
    /// The window is wider and taller than the card by the shadow margin, so the card's shadow is not clipped.
    private let shadowMargin = CompanionPanelView.shadowMargin
    private var windowWidth: CGFloat { panelWidth + shadowMargin.leading + shadowMargin.trailing }
    private let panelHeight: CGFloat = 380

    init(companionManager: CompanionManager) {
        self.companionManager = companionManager
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }
        clickMenuBarIconObserver = NotificationCenter.default.addObserver(
            forName: .clickyClickMenuBarIcon,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem?.button?.performClick(nil) }
        }
        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .clickyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The observer runs on the main queue, where this class lives.
            MainActor.assumeIsolated { self?.showPanel() }
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = clickOnShadowMarginMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = showPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = clickMenuBarIconObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        // A fixed width, so the icon's states never move the status items beside it.
        statusItem = NSStatusBar.system.statusItem(withLength: MenuBarIconArt.size.width)

        guard let button = statusItem?.button else { return }

        button.action = #selector(statusItemClicked)
        button.target = self
        let companionManager = companionManager
        statusIconController = MenuBarStatusIconController(
            button: button,
            changes: Publishers.Merge3(
                companionManager.$voiceState.map { _ in () },
                companionManager.themeSettings.objectWillChange.map { _ in () },
                companionManager.backgroundAgentStore.$agentIDsWaitingForApproval.map { _ in () }
            ).eraseToAnyPublisher(),
            voiceState: { companionManager.voiceState },
            shownCursor: { companionManager.themeSettings.shownTheme.cursor },
            approvalIsWaiting: { !companionManager.backgroundAgentStore.agentIDsWaitingForApproval.isEmpty }
        )
        logTheStatusItemPlace()
    }

    /// Logs where the icon is and whether macOS shows it, since a status item can sit behind the notch when the menu bar is
    /// full, and a check that cannot find it has to know that from the log (`verify-clicky.sh menu-icon`).
    private func logTheStatusItemPlace() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let buttonWindow = self?.statusItem?.button?.window else {
                print("Menu bar icon: no window, so macOS is not showing it")
                return
            }
            let isVisible = buttonWindow.occlusionState.contains(.visible)
            print("Menu bar icon: frame \(buttonWindow.frame), on screen \(buttonWindow.screen?.localizedName ?? "none"), visible \(isVisible)")
        }
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
            .frame(width: windowWidth)

        let hostingView = NSHostingView(rootView: companionPanelView)
        hostingView.frame = NSRect(x: 0, y: 0, width: windowWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: panelHeight),
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

        // The panel's frame is fitted to its content only when it opens, so a saved theme row deleted while it is open would
        // leave the card floating with empty space below it. The list publishes before it changes, so the refit waits one
        // main queue turn for SwiftUI to lay out the new rows.
        savedThemesSubscription = companionManager.themeSettings.$savedCustomThemesWithSavedDates
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.panel?.isVisible == true else { return }
                    self.panel?.contentView?.layoutSubtreeIfNeeded()
                    self.positionPanelBelowStatusItem()
                }
            }
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the window's height from the hosting view's fitting size so it snugly wraps the
        // SwiftUI content (the card plus its shadow margin) instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: windowWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the card beneath the status item icon. The margins on both sides are equal,
        // so centering the window centers the card.
        let panelOriginX = statusItemFrame.midX - (windowWidth / 2)
        // The card's top edge, not the window's, sits the gap below the menu bar, so the window starts
        // the top margin higher.
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar + shadowMargin.top

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: windowWidth, height: actualPanelHeight),
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

        clickOnShadowMarginMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            let cardFrame = Self.cardFrame(inWindowFrame: panel.frame, shadowMargin: self.shadowMargin)
            if !cardFrame.contains(NSEvent.mouseLocation) {
                self.hidePanel()
            }
            return event
        }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }

            // A click on the card keeps the panel open. The transparent shadow margin around the card does not count.
            let clickLocation = NSEvent.mouseLocation
            let cardFrame = Self.cardFrame(inWindowFrame: panel.frame, shadowMargin: self.shadowMargin)
            if cardFrame.contains(clickLocation) {
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
        if let monitor = clickOnShadowMarginMonitor {
            NSEvent.removeMonitor(monitor)
            clickOnShadowMarginMonitor = nil
        }
    }

    /// The card's frame inside the panel window, which is larger than the card by the shadow margin.
    static func cardFrame(inWindowFrame windowFrame: NSRect, shadowMargin: EdgeInsets) -> NSRect {
        NSRect(
            x: windowFrame.minX + shadowMargin.leading,
            y: windowFrame.minY + shadowMargin.bottom,
            width: windowFrame.width - shadowMargin.leading - shadowMargin.trailing,
            height: windowFrame.height - shadowMargin.top - shadowMargin.bottom
        )
    }
}
