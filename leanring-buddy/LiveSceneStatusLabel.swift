//
//  LiveSceneStatusLabel.swift
//  leanring-buddy
//
//  A label next to the cursor while Clicky works, so the wait has something on
//  screen. Each step has its own animated look (see LiveSceneStatusLine). Clicky
//  also says the scene build lines out loud.
//

import AppKit
import Combine
import SwiftUI

/// Shared with the overlay, which hides Clicky's blue triangle while a status line shows,
/// so the line's icon takes the triangle's place.
@MainActor
final class LiveSceneStatusLabelModel: ObservableObject {
    @Published var statusLine: LiveSceneStatusLine?
    @Published var isVisible = false
    /// False when the screen's edge pushed the panel off the cursor, so the icon is not on the
    /// triangle's spot. The overlay then keeps the triangle, since nothing else stands in for it.
    @Published var iconSitsOnTheTrianglesSpot = true
    /// When the current line appeared, so its loop starts from the beginning.
    var statusLineShownDate = Date()
}

private struct LiveSceneStatusLabelView: View {
    @ObservedObject var statusLabelModel: LiveSceneStatusLabelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 30 frames a second is smooth enough for the letters and keeps the loop light on 120 Hz displays.
    private let frameIntervalSeconds = 1.0 / 30.0

    var body: some View {
        ZStack(alignment: .leading) {
            // The label leaves the view tree when hidden, which stops the TimelineView's loop.
            if statusLabelModel.isVisible, let statusLine = statusLabelModel.statusLine {
                // With Reduce Motion on the label is still, so the timeline stops ticking.
                TimelineView(.animation(minimumInterval: frameIntervalSeconds, paused: reduceMotion)) { timeline in
                    LiveSceneStatusLabelContent(
                        statusLine: statusLine,
                        elapsedSeconds: reduceMotion
                            ? statusLine.stillMomentSeconds
                            : timeline.date.timeIntervalSince(statusLabelModel.statusLineShownDate)
                    )
                }
                .padding(.leading, 8)
                // Grows out of the icon's spot, where the triangle just faded, and shrinks back into it.
                .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: statusLabelModel.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

@MainActor
final class LiveSceneStatusLabel {
    static let shared = LiveSceneStatusLabel()

    private static let panelSize = CGSize(width: 420, height: 60)
    /// Puts the icon's center where the overlay draws Clicky's triangle: 35 points right of
    /// the mouse and 25 below it. The icon's center sits 24 points in from the panel's left
    /// edge (8 padding plus half the 32-point tile) and 30 up from its bottom (half of 60).
    private static let distanceFromCursor = CGPoint(x: 35 - 24, y: -25 - 30)
    private static let cursorFollowInterval: TimeInterval = 1.0 / 30.0

    let statusLabelModel = LiveSceneStatusLabelModel()
    private var statusLabelPanel: NSPanel?
    private var cursorFollowTimer: Timer?

    func show(_ statusLine: LiveSceneStatusLine) {
        if statusLabelModel.statusLine != statusLine || !statusLabelModel.isVisible {
            statusLabelModel.statusLineShownDate = Date()
        }
        statusLabelModel.statusLine = statusLine
        let panel = statusLabelPanel ?? makeStatusLabelPanel()
        statusLabelPanel = panel
        moveStatusLabelToTheCursor()
        panel.orderFrontRegardless()
        statusLabelModel.isVisible = true
        // Runs only while the label is up, so it costs nothing the rest of the time.
        if cursorFollowTimer == nil {
            cursorFollowTimer = Timer.scheduledTimer(withTimeInterval: Self.cursorFollowInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.moveStatusLabelToTheCursor()
                }
            }
        }
    }

    /// Swaps `expectedCurrentLine` for `newLine` only while the label is visible and shows
    /// `expectedCurrentLine`. A push-to-talk press or another owner's line therefore stops a delayed
    /// swap from bringing the label back.
    func replace(_ expectedCurrentLine: LiveSceneStatusLine, with newLine: LiveSceneStatusLine) {
        guard let lineToShow = LiveSceneStatusLine.lineShowing(
            afterReplacing: expectedCurrentLine,
            with: newLine,
            whileShowing: visibleStatusLine
        ) else { return }
        show(lineToShow)
    }

    /// Hides the label. A nil `statusLines` hides whatever shows, which a push-to-talk press uses.
    /// A set hides only when the current line is in it, so each owner hides only its own lines.
    func hide(onlyIfShowingOneOf statusLines: Set<LiveSceneStatusLine>? = nil) {
        guard LiveSceneStatusLine.lineShowing(
            afterHidingOnlyIfShowingOneOf: statusLines,
            whileShowing: visibleStatusLine
        ) == nil else { return }
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
        statusLabelModel.isVisible = false
    }

    /// The line on screen right now, or nil while the label is hidden.
    private var visibleStatusLine: LiveSceneStatusLine? {
        statusLabelModel.isVisible ? statusLabelModel.statusLine : nil
    }

    private func moveStatusLabelToTheCursor() {
        guard let statusLabelPanel, let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        let mouseLocation = NSEvent.mouseLocation
        let originOnTheTrianglesSpot = CGPoint(
            x: mouseLocation.x + Self.distanceFromCursor.x,
            y: mouseLocation.y + Self.distanceFromCursor.y
        )
        let clampedOrigin = CGPoint(
            x: min(originOnTheTrianglesSpot.x, screenFrame.maxX - Self.panelSize.width),
            y: max(originOnTheTrianglesSpot.y, screenFrame.minY)
        )
        statusLabelPanel.setFrameOrigin(clampedOrigin)
        // Published only on a change, because this runs 30 times a second and every set redraws the overlay.
        let iconSitsOnTheTrianglesSpot = clampedOrigin == originOnTheTrianglesSpot
        if statusLabelModel.iconSitsOnTheTrianglesSpot != iconSitsOnTheTrianglesSpot {
            statusLabelModel.iconSitsOnTheTrianglesSpot = iconSitsOnTheTrianglesSpot
        }
    }

    private func makeStatusLabelPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: LiveSceneStatusLabelView(statusLabelModel: statusLabelModel)
        )
        return panel
    }
}
