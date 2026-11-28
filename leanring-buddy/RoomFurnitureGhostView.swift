//
//  RoomFurnitureGhostView.swift
//  leanring-buddy
//
//  Draws the furniture's ghost over the room art panel's video: a footprint that glows on the floor like a rug, a 4 point
//  line in the theme's accent with a brighter front edge, dashed posts rising from its corners, a faint outline of the
//  top at the piece's height, a soft contact shadow, and a pill with its size. The first time it appears, and after a
//  pick-up, the theme's cursor glyph draws it line by line (`RoomFurnitureGhostDrawTimeline`, `CursorLoopTracerGlyph`, the
//  loop's own tracer), and with Reduce Motion on it fades in whole. The lines come from the controller each frame, through
//  the tracker's turn, so the ghost stays planted as the camera turns. The pure rules live in `RoomFurnitureGhost.swift`.
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
                : RoomFurnitureGhostDrawTimeline.frame(secondsSinceBegan: secondsSinceBegan)
            let secondsSinceDrawn = secondsSinceBegan - RoomFurnitureGhostDrawTimeline.totalSeconds
            let lines = linesProvider()
            ZStack(alignment: .topLeading) {
                RoomFurnitureGhostCanvas(
                    lines: lines,
                    frame: frame,
                    color: color,
                    fillOpacity: RoomFurnitureGhostGlow.fillOpacity(secondsSinceDrawn: secondsSinceDrawn, reduceMotionIsOn: reduceMotion)
                )
                if let lines, let tracerLook,
                   let placement = RoomFurnitureGhostCanvas.tracerPlacement(for: frame.tracer, lines: lines, cursorFacing: tracerLook.theme.cursorFacing) {
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
            .font(DS.TypeScale.title.font)
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
            let footprintPath = Self.path(through: lines.footprintEdges)

            // The contact shadow and the glowing fill come in last, under the lines. They take the footprint's visible part,
            // since the path of its edges has gaps wherever the camera or the panel cuts an edge away.
            if frame.fillShare > 0 {
                let footprintFillPath = Self.closedPath(through: lines.footprintFill)
                context.drawLayer { shadowLayer in
                    shadowLayer.addFilter(.blur(radius: 12))
                    shadowLayer.fill(footprintFillPath, with: .color(.black.opacity(0.4 * frame.fillShare)))
                }
                context.fill(footprintFillPath, with: .color(color.opacity(fillOpacity * frame.fillShare)))
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
                // The front edge is the footprint's first edge when any of it shows.
                if let frontSegment = lines.footprintEdges.first ?? nil {
                    let frontEdgeShare = Self.lengthShareOfTheFirstEdge(of: lines.footprintEdges)
                    let frontDrawnShare = min(1, frame.footprintShare / max(frontEdgeShare, 0.0001))
                    var frontEdge = Path()
                    frontEdge.move(to: frontSegment.start)
                    frontEdge.addLine(to: frontSegment.end)
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
            }

            // The posts rise from the floor, dashed.
            for (post, share) in zip(lines.posts, frame.postShares) where share > 0 {
                guard let post else { continue }
                var postPath = Path()
                postPath.move(to: post.start)
                postPath.addLine(to: CGPoint(x: post.start.x + (post.end.x - post.start.x) * share, y: post.start.y + (post.end.y - post.start.y) * share))
                context.stroke(postPath, with: .color(color.opacity(0.88)), style: StrokeStyle(lineWidth: Self.postLineWidth, lineCap: .butt, dash: Self.postDash))
            }

            // The top: a faint outline at the piece's height.
            if frame.topShare > 0 {
                let topPath = Self.path(through: lines.topEdges).trimmedPath(from: 0, to: frame.topShare)
                context.stroke(topPath, with: .color(color.opacity(0.45)), style: StrokeStyle(lineWidth: Self.topLineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }

    /// The closed outline through these corners.
    private static func closedPath(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let firstPoint = points.first else { return path }
        path.move(to: firstPoint)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The outline made of these edges in order. An edge that starts where the one before ended continues its line, and an
    /// edge that starts elsewhere, after one that was cut away, starts a new piece. An outline whose edges all show and meet
    /// is closed, so its corners join.
    static func path(through edges: [RoomFurnitureGhostSegment?]) -> Path {
        var path = Path()
        var currentPoint: CGPoint?
        for case let edge? in edges {
            if currentPoint != edge.start { path.move(to: edge.start) }
            path.addLine(to: edge.end)
            currentPoint = edge.end
        }
        if let firstEdge = edges.first ?? nil, currentPoint == firstEdge.start, edges.allSatisfy({ $0 != nil }) {
            path.closeSubpath()
        }
        return path
    }

    /// The first edge's length as a share of all the edges', from 0 to 1, and 0 when it is cut away.
    static func lengthShareOfTheFirstEdge(of edges: [RoomFurnitureGhostSegment?]) -> Double {
        let totalLength = edges.compactMap { $0?.length }.reduce(0, +)
        guard totalLength > 0, let firstEdge = edges.first ?? nil else { return 0 }
        return firstEdge.length / totalLength
    }

    /// Where the theme's cursor glyph sits on the ghost's lines for this moment of the draw, and which way it faces, or nil
    /// once the lines are drawn. It starts on the footprint's first corner and follows each
    /// line the way the loop's tracer follows the loop (`CursorLoopTracerPlacement`).
    static func tracerPlacement(for tracer: RoomFurnitureGhostDrawTimeline.Tracer, lines: RoomFurnitureGhostLines, cursorFacing: CursorFacing) -> CursorLoopTracerPlacement? {
        // A line with a cut away edge jumps from one piece to the next, as the loop's line joins a later move.
        func placement(along edges: [RoomFurnitureGhostSegment?], atShare share: Double) -> CursorLoopTracerPlacement? {
            guard edges.contains(where: { $0 != nil }) else { return nil }
            return CursorLoopTracerPlacement(on: CursorLoopLine(outline: path(through: edges)), atShare: min(max(share, 0), 1), cursorFacing: cursorFacing)
        }
        switch tracer {
        case .onTheFootprint(let share):
            return placement(along: lines.footprintEdges, atShare: share)
        case .onAPost(let index, let share):
            return placement(along: [lines.posts[index]], atShare: share)
        case .onTheTop(let share):
            return placement(along: lines.topEdges, atShare: share)
        case .gone:
            return nil
        }
    }
}
