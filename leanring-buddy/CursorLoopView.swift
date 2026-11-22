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

    var body: some View {
        let outline = CursorLoopOutline.path(along: loop.lineRect, seed: loop.seed)
        Group {
            if reduceMotion {
                Canvas { context, _ in CursorLoopDrawing.drawTheLine(outline, share: 1, color: color, in: &context) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    // The frame is worked out here, outside the Canvas, because SwiftUI redraws a Canvas only when
                    // a value its closure captured changes, and the clock is not one.
                    let frame = CursorLoopTimeline.frame(
                        secondsSinceTheLoopBegan: ProcessInfo.processInfo.systemUptime - loop.beganAt,
                        secondsWhenTheSparkSlows: loop.sparkSlowsAt.map { sparkSlowsAt in sparkSlowsAt - loop.beganAt }
                    )
                    Canvas { context, _ in
                        CursorLoopDrawing.drawTheLineAndTheSpark(outline, frame: frame, color: color, cursorPosition: cursorPosition, in: &context)
                    }
                }
            }
        }
        .opacity(loop.isFadingOut || (reduceMotion && !hasAppeared) ? 0 : 1)
        .animation(.easeOut(duration: CursorLoopState.fadeOutSeconds), value: loop.isFadingOut)
        .animation(.easeIn(duration: 0.3), value: hasAppeared)
        .allowsHitTesting(false)
        .onAppear { hasAppeared = true }
    }
}

/// How a loop's line and spark are drawn, shared by the cursor loop and the room art panel's loop, so the two look the
/// same: a 3 point line in the color over a darker 5.5 point under-stroke, and a white spark with a colored outline.
enum CursorLoopDrawing {
    private static let underStrokeColor = Color.black.opacity(0.55)
    private static let underStrokeWidthInPoints: CGFloat = 5.5
    private static let lineWidthInPoints: CGFloat = 3
    private static let sparkRadiusInPoints: CGFloat = 4.5
    private static let sparkOutlineWidthInPoints: CGFloat = 2.5

    /// `cursorPosition` is where the spark leaves from while it flies to the line's start. With none, the spark waits at the
    /// line's start for that first part.
    static func drawTheLineAndTheSpark(
        _ outline: Path,
        frame: CursorLoopTimeline.Frame,
        color: Color,
        cursorPosition: CGPoint?,
        in context: inout GraphicsContext
    ) {
        drawTheLine(outline, share: frame.drawnShare, color: color, in: &context)

        let outlineStart = outline.trimmedPath(from: 0, to: 0.0005).currentPoint ?? outline.boundingRect.origin
        let sparkCenter: CGPoint
        switch frame.spark {
        case .flyingFromTheCursor(let share):
            let flightStart = cursorPosition ?? outlineStart
            sparkCenter = CGPoint(
                x: flightStart.x + (outlineStart.x - flightStart.x) * share,
                y: flightStart.y + (outlineStart.y - flightStart.y) * share
            )
        case .onTheLoop(let share):
            sparkCenter = outline.trimmedPath(from: 0, to: max(share, 0.0005)).currentPoint ?? outlineStart
        }
        drawTheSpark(at: sparkCenter, color: color, in: &context)
    }

    /// The white spark with its colored outline and glow, which the furniture's ghost draws its lines with too.
    static func drawTheSpark(at sparkCenter: CGPoint, color: Color, in context: inout GraphicsContext) {
        let sparkPath = Path(ellipseIn: CGRect(
            x: sparkCenter.x - sparkRadiusInPoints,
            y: sparkCenter.y - sparkRadiusInPoints,
            width: sparkRadiusInPoints * 2,
            height: sparkRadiusInPoints * 2
        ))
        context.drawLayer { sparkLayer in
            sparkLayer.addFilter(.shadow(color: color.opacity(0.55), radius: 5))
            sparkLayer.fill(sparkPath, with: .color(.white))
            sparkLayer.stroke(sparkPath, with: .color(color), lineWidth: sparkOutlineWidthInPoints)
        }
    }

    static func drawTheLine(_ outline: Path, share: Double, color: Color, in context: inout GraphicsContext) {
        guard share > 0 else { return }
        let drawnPart = share >= 1 ? outline : outline.trimmedPath(from: 0, to: share)
        context.stroke(
            drawnPart,
            with: .color(underStrokeColor),
            style: StrokeStyle(lineWidth: underStrokeWidthInPoints, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            drawnPart,
            with: .color(color),
            style: StrokeStyle(lineWidth: lineWidthInPoints, lineCap: .round, lineJoin: .round)
        )
    }
}
