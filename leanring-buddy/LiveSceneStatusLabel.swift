//
//  LiveSceneStatusLabel.swift
//  leanring-buddy
//
//  A Callout above the cursor while Clicky works, so the wait has something on screen. Each step has its own hue and
//  animated icon (see LiveSceneStatusLine), and its tail points at the cursor's triangle, which stays visible.
//  Clicky also says the scene build lines out loud. It pops in from the tail's tip, leaves with a fade-rise, and shrinks
//  into the cursor when the learner interrupts (a Recall).
//

import AppKit
import Combine
import SwiftUI

/// What the label shows, read by the overlay to hide the ring while a line shows.
@MainActor
final class LiveSceneStatusLabelModel: ObservableObject {
    @Published var statusLine: LiveSceneStatusLine?
    @Published var isVisible = false
    /// How the label leaves, which the view reads as the label goes. Set one turn before `isVisible` goes false, since a
    /// view's removal transition is the one it had in its last drawing.
    @Published var exit: TetherCalloutExit = .fadeRise
    /// The Callout's measured width, which decides whether it fits right of the cursor. Not published, since the
    /// cursor-follow timer reads it 30 times a second.
    var contentWidth: CGFloat = 0
    /// When the current line appeared, so its loop starts from the beginning.
    var statusLineShownDate = Date()
}

/// Where the label panel goes for one mouse position.
enum StatusLabelPlacement {
    /// Wide enough for the longest line, "Picking spots to quiz you on", with the margin for its halo and shadow.
    static let panelSize = CGSize(width: 420, height: tetherSingleLineCalloutHeight + 2 * tetherCalloutPanelMargin)
    /// Clicky's triangle sits 35 points right of the mouse and 25 below it.
    static let trianglesSpotFromTheMouse = CGPoint(x: 35, y: -25)

    /// The panel's bottom-left corner, so the tail's tip lands just above the triangle.
    static func panelOrigin(mouseLocation: CGPoint, contentWidth: CGFloat, screenFrame: CGRect) -> CGPoint {
        let tipPoint = CGPoint(
            x: mouseLocation.x + trianglesSpotFromTheMouse.x,
            y: mouseLocation.y + trianglesSpotFromTheMouse.y + tetherCalloutTipRiseAboveTheCursor
        )
        return tetherCalloutPanelOrigin(tipPoint: tipPoint, calloutWidth: contentWidth, panelHeight: panelSize.height, screenFrame: screenFrame)
    }
}

private struct LiveSceneStatusLabelView: View {
    @ObservedObject var statusLabelModel: LiveSceneStatusLabelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 30 frames a second is smooth enough for the icon and keeps the loop light on 120 Hz displays.
    private let frameIntervalSeconds = 1.0 / 30.0

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The label leaves the view tree when hidden, which stops the TimelineView's loop.
            if statusLabelModel.isVisible, let statusLine = statusLabelModel.statusLine {
                // With Reduce Motion on the label is still, so the timeline stops ticking.
                TimelineView(.animation(minimumInterval: frameIntervalSeconds, paused: reduceMotion)) { timeline in
                    LiveSceneStatusLabelContent(
                        statusLine: statusLine,
                        elapsedSeconds: reduceMotion
                            ? statusLine.stillMomentSeconds
                            : timeline.date.timeIntervalSince(statusLabelModel.statusLineShownDate),
                        lettersAreStill: reduceMotion
                    )
                }
                .onGeometryChange(for: CGFloat.self) { contentGeometry in
                    contentGeometry.size.width
                } action: { measuredContentWidth in
                    statusLabelModel.contentWidth = measuredContentWidth
                }
                .transition(.tetherCallout(exit: statusLabelModel.exit, reduceMotionIsOn: reduceMotion))
            }
        }
        .padding(tetherCalloutPanelMargin)
        .animation(
            tetherCalloutAnimation(isAppearing: statusLabelModel.isVisible, exit: statusLabelModel.exit, reduceMotionIsOn: reduceMotion),
            value: statusLabelModel.isVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

@MainActor
final class LiveSceneStatusLabel {
    static let shared = LiveSceneStatusLabel()

    private static let cursorFollowInterval: TimeInterval = 1.0 / 30.0

    let statusLabelModel = LiveSceneStatusLabelModel()
    private var statusLabelPanel: NSPanel?
    private var cursorFollowTimer: Timer?
    /// Counts each hide and each show, so a hide that waits one turn for its exit style never hides a line shown since.
    private var latestHideOrShowCount = 0

    func show(_ statusLine: LiveSceneStatusLine) {
        if statusLabelModel.statusLine != statusLine || !statusLabelModel.isVisible {
            statusLabelModel.statusLineShownDate = Date()
        }
        latestHideOrShowCount += 1
        statusLabelModel.statusLine = statusLine
        statusLabelModel.exit = .fadeRise
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

    /// Hides the label. A nil `statusLines` hides whatever shows, which a push-to-talk press uses, so the label shrinks into
    /// the cursor (a Recall). A set hides only when the current line is in it, so each owner hides only its own lines, and
    /// the label leaves with a fade-rise.
    func hide(onlyIfShowingOneOf statusLines: Set<LiveSceneStatusLine>? = nil) {
        guard LiveSceneStatusLine.lineShowing(
            afterHidingOnlyIfShowingOneOf: statusLines,
            whileShowing: visibleStatusLine
        ) == nil else { return }
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
        // The exit is set first and the label hides one turn later, so the view's removal uses it.
        statusLabelModel.exit = statusLines == nil ? .recall : .fadeRise
        latestHideOrShowCount += 1
        let thisHideCount = latestHideOrShowCount
        DispatchQueue.main.async { [weak self] in
            guard let self, self.latestHideOrShowCount == thisHideCount else { return }
            self.statusLabelModel.isVisible = false
        }
    }

    /// The line on screen right now, or nil while the label is hidden.
    private var visibleStatusLine: LiveSceneStatusLine? {
        statusLabelModel.isVisible ? statusLabelModel.statusLine : nil
    }

    private func moveStatusLabelToTheCursor() {
        guard let statusLabelPanel, let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        statusLabelPanel.setFrameOrigin(StatusLabelPlacement.panelOrigin(
            mouseLocation: NSEvent.mouseLocation,
            contentWidth: statusLabelModel.contentWidth,
            screenFrame: screenFrame
        ))
    }

    private func makeStatusLabelPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: StatusLabelPlacement.panelSize),
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
