//
//  ShadowMarginMousePassThrough.swift
//  leanring-buddy
//
//  The one mechanism that lets a Card's window pass the mouse through its transparent shadow margin. The agent list, the
//  Theme Studio card, the "Add theme?" card, the quiz summary Card, and the instant replay control all draw their Card in a
//  window larger than the Card (`AgentListWindowMargins`). The window server routes a click to any pixel with some alpha, and
//  the margin's shadow pixels are faint but not clear, so without this a click meant for the page under the shadow lands on
//  the window and does nothing.
//

import AppKit

/// Makes `panel` ignore the mouse while the pointer is in its shadow margin
/// (`AgentListWindowMargins.windowPassesTheMouseThrough`), and take it everywhere else.
///
/// A window that ignores the mouse reports nothing, and a global monitor misses moves over the panel, so the panel takes the
/// mouse whenever the pointer is away, and its entry view reports the pointer coming back. While the pointer is within
/// `pointerNearDistance` of the window, a 60 Hz timer reads it, and the timer stops once the pointer leaves. A panel that
/// stays up for minutes with the pointer elsewhere costs no timer.
///
/// The decision is made at once on `start`, and again at once each time the window resizes or moves, since a window that
/// appears or grows under a still pointer would otherwise take clicks in its margin until the next tick.
@MainActor
final class ShadowMarginMousePassThrough {
    /// How far outside the window's frame the pointer still counts as near it, so a pointer on the frame's edge does.
    static let pointerNearDistance: CGFloat = 8

    /// Where the pointer is on screen. A test sets it, since the real pointer is wherever the learner left it.
    var mouseLocationOnScreen: () -> CGPoint

    /// Readable by a test, which checks that it runs only while the pointer is near the window and that it stops.
    private(set) var clickThroughTimer: Timer?
    /// The view that reports the pointer entering the window. Readable by a test.
    private(set) var pointerEntryView: PointerEntryNSView?

    private weak var panel: NSPanel?
    private var windowObservers: [NSObjectProtocol] = []

    init(panel: NSPanel, mouseLocationOnScreen: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        self.panel = panel
        self.mouseLocationOnScreen = mouseLocationOnScreen
    }

    /// Starts watching and decides at once. The panel's content view must be set.
    func start() {
        guard let panel, pointerEntryView == nil else { return }
        if let contentView = panel.contentView {
            let entryView = PointerEntryNSView(frame: contentView.bounds)
            entryView.autoresizingMask = [.width, .height]
            entryView.pointerEntered = { [weak self] in self?.update() }
            contentView.addSubview(entryView)
            // Watching before the window first shows, not from AppKit's first pass over it.
            entryView.updateTrackingAreas()
            pointerEntryView = entryView
        }
        for notificationName in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            let observer = NotificationCenter.default.addObserver(forName: notificationName, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            windowObservers.append(observer)
        }
        update()
    }

    /// Stops watching, for a panel that is closing. The timer and the observers go, and the panel keeps whatever mouse state
    /// it had, which a closing panel sets itself.
    func stop() {
        stopReadingTheMouse()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        pointerEntryView?.removeFromSuperview()
        pointerEntryView = nil
    }

    /// Reads the pointer now and sets whether the window takes the mouse. Also starts the timer while the pointer is near the
    /// window, and stops it once the pointer is away. A window that ignores the mouse reports nothing, so away from the
    /// window it takes the mouse, which lets its tracking area report the pointer's return.
    func update() {
        guard let panel else { return }
        let mouseLocation = mouseLocationOnScreen()
        let pointerIsNear = panel.frame.insetBy(dx: -Self.pointerNearDistance, dy: -Self.pointerNearDistance).contains(mouseLocation)
        let passesTheMouseThrough = pointerIsNear
            && AgentListWindowMargins.windowPassesTheMouseThrough(at: mouseLocation, windowFrame: panel.frame)
        if panel.ignoresMouseEvents != passesTheMouseThrough {
            panel.ignoresMouseEvents = passesTheMouseThrough
            // The tracking areas missed the moves made while the window ignored the mouse, so they start over, and a hover the
            // margin cut off does not stay behind.
            if !passesTheMouseThrough { pointerEntryView?.updateTrackingAreas() }
            if let contentView = panel.contentView {
                refreshTheRowHovers(in: contentView, windowPassesTheMouseThrough: passesTheMouseThrough)
            }
        }
        if pointerIsNear {
            startReadingTheMouse()
        } else {
            stopReadingTheMouse()
        }
    }

    private func startReadingTheMouse() {
        guard clickThroughTimer == nil else { return }
        // The run loop keeps the timer, so a timer that outlives this object ends itself.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.update() }
        }
        // The common modes keep it running while a menu or a drag tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        clickThroughTimer = timer
    }

    private func stopReadingTheMouse() {
        clickThroughTimer?.invalidate()
        clickThroughTimer = nil
    }
}

/// A transparent view over a panel's content that reports the pointer entering the window. It takes no mouse events itself.
final class PointerEntryNSView: NSView {
    var pointerEntered: () -> Void = {}
    private var entryTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let entryTrackingArea { removeTrackingArea(entryTrackingArea) }
        // Always active, since the panel is never key. During a drag too, so a drag that ends over the shadow margin, such as
        // one that turns the pop-out's model, still reports the entry.
        let trackingArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        entryTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pointerEntered()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
