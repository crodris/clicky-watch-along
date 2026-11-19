//
//  CursorLoopView.swift
//  leanring-buddy
//
//  Draws the loop around the video or image Clicky is looking at: a 3 point line in the cursor's color
//  over a darker 5.5 point under-stroke, drawn by a spark that leaves the cursor and keeps lapping.
//  No glow, dashes, taper, or labels on the line itself. Reduce Motion fades the whole line in with no spark.
//

import SwiftUI

/// One loop to draw on one screen, in that screen's overlay coordinates.
struct CursorLoopOnScreen: Equatable {
    /// The rectangle the line runs along, already 4 points outside the media.
    let lineRect: CGRect
    let seed: UInt64
    /// `ProcessInfo.systemUptime` when the loop began, and when its spark slows, if a build runs under it.
    let beganAt: TimeInterval
    let sparkSlowsAt: TimeInterval?
    let isFadingOut: Bool
}

struct CursorLoopView: View {
    let loop: CursorLoopOnScreen
    /// Where the spark leaves from.
    let cursorPosition: CGPoint
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Reduce Motion fades the line in whole, so it starts invisible and turns visible when it appears.
    @State private var hasAppeared = false

    private static let underStrokeColor = Color.black.opacity(0.55)
    private static let underStrokeWidthInPoints: CGFloat = 5.5
    private static let lineWidthInPoints: CGFloat = 3
    private static let sparkRadiusInPoints: CGFloat = 4.5
    private static let sparkOutlineWidthInPoints: CGFloat = 2.5

    var body: some View {
        let outline = CursorLoopOutline.path(along: loop.lineRect, seed: loop.seed)
        Group {
            if reduceMotion {
                Canvas { context, _ in drawTheLine(outline, share: 1, in: &context) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    Canvas { context, _ in drawTheLineAndTheSpark(outline, in: &context) }
                }
            }
        }
        .opacity(loop.isFadingOut || (reduceMotion && !hasAppeared) ? 0 : 1)
        .animation(.easeOut(duration: CursorLoopState.fadeOutSeconds), value: loop.isFadingOut)
        .animation(.easeIn(duration: 0.3), value: hasAppeared)
        .allowsHitTesting(false)
        .onAppear { hasAppeared = true }
    }

    private func drawTheLineAndTheSpark(_ outline: Path, in context: inout GraphicsContext) {
        let secondsSinceBegan = ProcessInfo.processInfo.systemUptime - loop.beganAt
        let frame = CursorLoopTimeline.frame(
            secondsSinceTheLoopBegan: secondsSinceBegan,
            secondsWhenTheSparkSlows: loop.sparkSlowsAt.map { sparkSlowsAt in sparkSlowsAt - loop.beganAt }
        )
        drawTheLine(outline, share: frame.drawnShare, in: &context)

        let outlineStart = outline.trimmedPath(from: 0, to: 0.0005).currentPoint ?? loop.lineRect.origin
        let sparkCenter: CGPoint
        switch frame.spark {
        case .flyingFromTheCursor(let share):
            sparkCenter = CGPoint(
                x: cursorPosition.x + (outlineStart.x - cursorPosition.x) * share,
                y: cursorPosition.y + (outlineStart.y - cursorPosition.y) * share
            )
        case .onTheLoop(let share):
            sparkCenter = outline.trimmedPath(from: 0, to: max(share, 0.0005)).currentPoint ?? outlineStart
        }
        let sparkPath = Path(ellipseIn: CGRect(
            x: sparkCenter.x - Self.sparkRadiusInPoints,
            y: sparkCenter.y - Self.sparkRadiusInPoints,
            width: Self.sparkRadiusInPoints * 2,
            height: Self.sparkRadiusInPoints * 2
        ))
        context.drawLayer { sparkLayer in
            sparkLayer.addFilter(.shadow(color: color.opacity(0.55), radius: 5))
            sparkLayer.fill(sparkPath, with: .color(.white))
            sparkLayer.stroke(sparkPath, with: .color(color), lineWidth: Self.sparkOutlineWidthInPoints)
        }
    }

    private func drawTheLine(_ outline: Path, share: Double, in context: inout GraphicsContext) {
        guard share > 0 else { return }
        let drawnPart = share >= 1 ? outline : outline.trimmedPath(from: 0, to: share)
        context.stroke(
            drawnPart,
            with: .color(Self.underStrokeColor),
            style: StrokeStyle(lineWidth: Self.underStrokeWidthInPoints, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            drawnPart,
            with: .color(color),
            style: StrokeStyle(lineWidth: Self.lineWidthInPoints, lineCap: .round, lineJoin: .round)
        )
    }
}
