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
    /// Which side of the icon the letters sit on. They move left of it near a screen's right edge,
    /// so the icon can stay on the triangle's spot.
    @Published var textSide: StatusLabelTextSide = .rightOfIcon
    /// The icon and letters' measured width, which decides whether the letters fit right of the icon.
    /// Not published, since the cursor-follow timer reads it 30 times a second.
    var contentWidth: CGFloat = 0
    /// When the current line appeared, so its loop starts from the beginning.
    var statusLineShownDate = Date()
}

enum StatusLabelTextSide: Equatable {
    case rightOfIcon
    case leftOfIcon
}

/// Where the label panel goes for one mouse position, and whether its icon covers the triangle's spot.
struct StatusLabelPlacement: Equatable {
    let panelOrigin: CGPoint
    let textSide: StatusLabelTextSide
    let iconSitsOnTheTrianglesSpot: Bool

    static let panelSize = CGSize(width: 420, height: 60)
    /// The content sits 8 points in from the panel's edge, and the icon's center 24 points in
    /// (8 padding plus half the 32-point tile) and 30 up from the panel's bottom (half of 60).
    static let contentInset: CGFloat = 8
    static let iconCenterInset: CGFloat = 24
    /// Clicky's triangle sits 35 points right of the mouse and 25 below it.
    static let trianglesSpotFromTheMouse = CGPoint(x: 35, y: -25)

    /// The letters go right of the icon when they fit on the screen, left of it when only that fits,
    /// and otherwise the panel is pushed inside the screen as before and the triangle stays.
    static func placement(mouseLocation: CGPoint, contentWidth: CGFloat, screenFrame: CGRect) -> StatusLabelPlacement {
        let trianglesSpot = CGPoint(x: mouseLocation.x + trianglesSpotFromTheMouse.x, y: mouseLocation.y + trianglesSpotFromTheMouse.y)
        let originY = max(trianglesSpot.y - panelSize.height / 2, screenFrame.minY)
        let iconStaysOnTheSpotVertically = originY == trianglesSpot.y - panelSize.height / 2

        let rightLayoutOriginX = trianglesSpot.x - iconCenterInset
        let contentRightEdgeInTheRightLayout = rightLayoutOriginX + contentInset + contentWidth
        if contentRightEdgeInTheRightLayout <= screenFrame.maxX {
            return StatusLabelPlacement(panelOrigin: CGPoint(x: rightLayoutOriginX, y: originY), textSide: .rightOfIcon, iconSitsOnTheTrianglesSpot: iconStaysOnTheSpotVertically)
        }
        let leftLayoutOriginX = trianglesSpot.x + iconCenterInset - panelSize.width
        let contentLeftEdgeInTheLeftLayout = leftLayoutOriginX + panelSize.width - contentInset - contentWidth
        if contentLeftEdgeInTheLeftLayout >= screenFrame.minX {
            return StatusLabelPlacement(panelOrigin: CGPoint(x: leftLayoutOriginX, y: originY), textSide: .leftOfIcon, iconSitsOnTheTrianglesSpot: iconStaysOnTheSpotVertically)
        }
        let pushedOriginX = min(rightLayoutOriginX, screenFrame.maxX - contentInset - contentWidth)
        return StatusLabelPlacement(panelOrigin: CGPoint(x: pushedOriginX, y: originY), textSide: .rightOfIcon, iconSitsOnTheTrianglesSpot: false)
    }
}

private struct LiveSceneStatusLabelView: View {
    @ObservedObject var statusLabelModel: LiveSceneStatusLabelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 30 frames a second is smooth enough for the letters and keeps the loop light on 120 Hz displays.
    private let frameIntervalSeconds = 1.0 / 30.0

    var body: some View {
        let textSide = statusLabelModel.textSide
        let contentAlignment: Alignment = textSide == .rightOfIcon ? .leading : .trailing
        let iconEdgeAnchor: UnitPoint = textSide == .rightOfIcon ? .leading : .trailing
        ZStack(alignment: contentAlignment) {
            // The label leaves the view tree when hidden, which stops the TimelineView's loop.
            if statusLabelModel.isVisible, let statusLine = statusLabelModel.statusLine {
                // With Reduce Motion on the label is still, so the timeline stops ticking.
                TimelineView(.animation(minimumInterval: frameIntervalSeconds, paused: reduceMotion)) { timeline in
                    LiveSceneStatusLabelContent(
                        statusLine: statusLine,
                        elapsedSeconds: reduceMotion
                            ? statusLine.stillMomentSeconds
                            : timeline.date.timeIntervalSince(statusLabelModel.statusLineShownDate),
                        textSide: textSide
                    )
                }
                .onGeometryChange(for: CGFloat.self) { contentGeometry in
                    contentGeometry.size.width
                } action: { measuredContentWidth in
                    statusLabelModel.contentWidth = measuredContentWidth
                }
                .padding(textSide == .rightOfIcon ? .leading : .trailing, StatusLabelPlacement.contentInset)
                // Grows out of the icon's spot, where the triangle just faded, and shrinks back into it.
                .transition(.scale(scale: 0.4, anchor: iconEdgeAnchor).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: statusLabelModel.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: contentAlignment)
    }
}

@MainActor
final class LiveSceneStatusLabel {
    static let shared = LiveSceneStatusLabel()

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
        let placement = StatusLabelPlacement.placement(
            mouseLocation: NSEvent.mouseLocation,
            contentWidth: statusLabelModel.contentWidth,
            screenFrame: screenFrame
        )
        statusLabelPanel.setFrameOrigin(placement.panelOrigin)
        // Published only on a change, because this runs 30 times a second and every set redraws the overlay.
        if statusLabelModel.iconSitsOnTheTrianglesSpot != placement.iconSitsOnTheTrianglesSpot {
            statusLabelModel.iconSitsOnTheTrianglesSpot = placement.iconSitsOnTheTrianglesSpot
        }
        if statusLabelModel.textSide != placement.textSide {
            statusLabelModel.textSide = placement.textSide
        }
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
