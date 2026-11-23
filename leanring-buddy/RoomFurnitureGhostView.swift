//
//  RoomFurnitureGhostView.swift
//  leanring-buddy
//
//  Draws the furniture's ghost over the room art panel's video: a footprint that glows on the floor like a rug, a 4 point
//  line in the theme's accent with a brighter front edge, dashed posts rising from its corners, a faint outline of the
//  top at the piece's height, a soft contact shadow, and a pill with its size. The first time it appears, and after a
//  pick-up, the theme's cursor glyph draws it line by line (`RoomFurnitureGhostDrawTimeline`, `CursorLoopTracerGlyph`, the
//  loop's own tracer), and with Reduce Motion on it fades in whole. The lines come from the controller each frame, through the tracker's turn, so the ghost stays planted as the
//  camera turns. The pure rules live in `RoomFurnitureGhost.swift`.
//

import SwiftUI

struct RoomFurnitureGhostView: View {
    let draw: RoomFurnitureGhostDraw
    let color: Color
    /// The theme's cursor, which draws the lines. Nil draws them with no tracer.
    var tracerLook: CursorLoopTracerLook? = nil
    let sizePillText: String
    /// The ghost's lines for this moment in the panel's points, or nil while the room is lost.
    let linesProvider: () -> RoomFurnitureGhostLines?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            // Worked out outside the Canvas, since SwiftUI redraws a Canvas only when a captured value changes.
            let secondsSinceBegan = ProcessInfo.processInfo.systemUptime - draw.beganAt
            let frame = reduceMotion
                ? RoomFurnitureGhostDrawTimeline.Frame.whole
                : RoomFurnitureGhostDrawTimeline.frame(secondsSinceBegan: secondsSinceBegan, startsFromTheLoop: draw.tracerStartInThePanel != nil)
            let secondsSinceDrawn = secondsSinceBegan - RoomFurnitureGhostDrawTimeline.totalSeconds(startsFromTheLoop: draw.tracerStartInThePanel != nil)
            let lines = linesProvider()
            ZStack(alignment: .topLeading) {
                RoomFurnitureGhostCanvas(
                    lines: lines,
                    frame: frame,
                    color: color,
                    fillOpacity: RoomFurnitureGhostGlow.fillOpacity(secondsSinceDrawn: secondsSinceDrawn, reduceMotionIsOn: reduceMotion)
                )
                if let lines, let tracerLook,
                   let placement = RoomFurnitureGhostCanvas.tracerPlacement(for: frame.tracer, lines: lines, tracerStart: draw.tracerStartInThePanel, cursorFacing: tracerLook.theme.cursorFacing) {
                    CursorLoopTracerGlyph(look: tracerLook, placement: placement)
                }
                if let lines {
                    RoomFurnitureGhostSizePill(text: sizePillText, isShown: frame.pillIsShown, reduceMotion: reduceMotion)
                        .position(lines.pillCenter)
                }
            }
        }
        // With Reduce Motion on, the whole ghost fades in over the fade move's time, with no tracer.
        .opacity(reduceMotion && !hasAppeared ? 0 : 1)
        .animation(.easeIn(duration: DS.Move.fadeSeconds), value: hasAppeared)
        .allowsHitTesting(false)
        .onAppear { hasAppeared = true }
    }
}

/// The size pill, which pops in on the Pop move once the lines are drawn.
private struct RoomFurnitureGhostSizePill: View {
    let text: String
    let isShown: Bool
    let reduceMotion: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DS.Colors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(DS.Colors.calloutSurface.opacity(0.92)))
            .overlay(Capsule().stroke(DS.Colors.textPrimary.opacity(0.12), lineWidth: 1))
            .fixedSize()
            .scaleEffect(isShown || reduceMotion ? 1 : DS.Move.popStartScale)
            .opacity(isShown ? 1 : 0)
            .animation(DS.Move.pop.animation(reduceMotionIsOn: reduceMotion), value: isShown)
    }
}

/// One frame of the ghost's lines. Reads nothing but its arguments, so a test renders it at a known moment.
struct RoomFurnitureGhostCanvas: View {
    let lines: RoomFurnitureGhostLines?
    let frame: RoomFurnitureGhostDrawTimeline.Frame
    let color: Color
    let fillOpacity: Double

    private static let footprintLineWidth: CGFloat = 4
    private static let frontEdgeLineWidth: CGFloat = 5.5
    private static let postLineWidth: CGFloat = 3
    private static let topLineWidth: CGFloat = 2
    private static let postDash: [CGFloat] = [9, 7]

    var body: some View {
        Canvas { context, _ in
            guard let lines else { return }
            let footprintPath = Self.closedPath(through: lines.footprint)

            // The contact shadow and the glowing fill come in last, under the lines.
            if frame.fillShare > 0 {
                context.drawLayer { shadowLayer in
                    shadowLayer.addFilter(.blur(radius: 12))
                    shadowLayer.fill(footprintPath, with: .color(.black.opacity(0.4 * frame.fillShare)))
                }
                context.fill(footprintPath, with: .color(color.opacity(fillOpacity * frame.fillShare)))
            }

            // The footprint: a soft glow, a dark under-stroke so it reads on a bright floor, the accent line, and its front
            // edge brighter, so the side the piece faces is never in doubt.
            if frame.footprintShare > 0 {
                let drawnFootprint = footprintPath.trimmedPath(from: 0, to: frame.footprintShare)
                context.drawLayer { glowLayer in
                    glowLayer.addFilter(.blur(radius: 6))
                    glowLayer.stroke(drawnFootprint, with: .color(color.opacity(0.55)), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                }
                context.stroke(drawnFootprint, with: .color(.black.opacity(0.45)), style: StrokeStyle(lineWidth: Self.footprintLineWidth + 2.5, lineCap: .round, lineJoin: .round))
                context.stroke(drawnFootprint, with: .color(color), style: StrokeStyle(lineWidth: Self.footprintLineWidth, lineCap: .round, lineJoin: .round))
                // The footprint starts with its front edge, a quarter of the way around for a square, so its share of the
                // drawn line is the front edge's own share of the whole outline.
                let frontEdgeShare = Self.lengthShareOfTheFirstEdge(of: lines.footprint)
                let frontDrawnShare = min(1, frame.footprintShare / max(frontEdgeShare, 0.0001))
                var frontEdge = Path()
                frontEdge.move(to: lines.footprint[0])
                frontEdge.addLine(to: lines.footprint[1])
                context.stroke(
                    frontEdge.trimmedPath(from: 0, to: frontDrawnShare),
                    with: .color(Color.white.opacity(0.85)),
                    style: StrokeStyle(lineWidth: Self.frontEdgeLineWidth, lineCap: .round)
                )
                context.stroke(
                    frontEdge.trimmedPath(from: 0, to: frontDrawnShare),
                    with: .color(color),
                    style: StrokeStyle(lineWidth: Self.frontEdgeLineWidth - 2, lineCap: .round)
                )
            }

            // The posts rise from the floor, dashed.
            for (post, share) in zip(lines.posts, frame.postShares) where share > 0 {
                var postPath = Path()
                postPath.move(to: post.bottom)
                postPath.addLine(to: CGPoint(x: post.bottom.x + (post.top.x - post.bottom.x) * share, y: post.bottom.y + (post.top.y - post.bottom.y) * share))
                context.stroke(postPath, with: .color(color.opacity(0.88)), style: StrokeStyle(lineWidth: Self.postLineWidth, lineCap: .butt, dash: Self.postDash))
            }

            // The top: a faint outline at the piece's height.
            if frame.topShare > 0 {
                let topPath = Self.closedPath(through: lines.top).trimmedPath(from: 0, to: frame.topShare)
                context.stroke(topPath, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: Self.topLineWidth, lineCap: .round, lineJoin: .round))
            }

        }
        .allowsHitTesting(false)
    }

    private static func closedPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let firstPoint = points.first else { return path }
        path.move(to: firstPoint)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The first edge's length as a share of the closed outline's, from 0 to 1.
    static func lengthShareOfTheFirstEdge(of points: [CGPoint]) -> Double {
        guard points.count >= 2 else { return 1 }
        let edgeLengths = points.indices.map { index in
            let start = points[index], end = points[(index + 1) % points.count]
            return hypot(end.x - start.x, end.y - start.y)
        }
        let totalLength = edgeLengths.reduce(0, +)
        return totalLength > 0 ? edgeLengths[0] / totalLength : 1
    }

    /// Where the theme's cursor glyph sits on the ghost's lines for this moment of the draw, and which way it faces, or nil
    /// once the lines are drawn. It flies straight from the loop's line to the footprint's first corner, then follows each
    /// line the way the loop's tracer follows the loop (`CursorLoopTracerPlacement`).
    static func tracerPlacement(for tracer: RoomFurnitureGhostDrawTimeline.Tracer, lines: RoomFurnitureGhostLines, tracerStart: CGPoint?, cursorFacing: CursorFacing) -> CursorLoopTracerPlacement? {
        func placement(along points: [CGPoint], closed: Bool, atShare share: Double) -> CursorLoopTracerPlacement {
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            let line = closed ? CursorLoopLine(closedThrough: points) : CursorLoopLine(outline: path)
            return CursorLoopTracerPlacement(on: line, atShare: min(max(share, 0), 1), cursorFacing: cursorFacing)
        }
        switch tracer {
        case .leavingTheLoop(let share):
            return placement(along: [tracerStart ?? lines.footprint[0], lines.footprint[0]], closed: false, atShare: share)
        case .onTheFootprint(let share):
            return placement(along: lines.footprint, closed: true, atShare: share)
        case .onAPost(let index, let share):
            return placement(along: [lines.posts[index].bottom, lines.posts[index].top], closed: false, atShare: share)
        case .onTheTop(let share):
            return placement(along: lines.top, closed: true, atShare: share)
        case .gone:
            return nil
        }
    }
}
