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
    /// When the current line appeared, so its loop starts from the beginning.
    var statusLineShownDate = Date()
}

private struct LiveSceneStatusLabelView: View {
    @ObservedObject var statusLabelModel: LiveSceneStatusLabelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .leading) {
            // The label leaves the view tree when hidden, which stops the TimelineView's loop.
            if statusLabelModel.isVisible, let statusLine = statusLabelModel.statusLine {
                TimelineView(.animation) { timeline in
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

    func hide() {
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
        statusLabelModel.isVisible = false
    }

    private func moveStatusLabelToTheCursor() {
        guard let statusLabelPanel, let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        let mouseLocation = NSEvent.mouseLocation
        statusLabelPanel.setFrameOrigin(CGPoint(
            x: min(mouseLocation.x + Self.distanceFromCursor.x, screenFrame.maxX - Self.panelSize.width),
            y: max(mouseLocation.y + Self.distanceFromCursor.y, screenFrame.minY)
        ))
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
