//
//  RoomArtLoop.swift
//  leanring-buddy
//
//  Clicky's loop around the spot the room art panel measures: the wall spot for wall art, and the floor spot for furniture.
//  It is the cursor loop's own line (`CursorLoopOutline`, `CursorLoopTimeline`, `CursorLoopDrawing`) in the theme's accent,
//  drawn by the theme's own cursor glyph (`CursorLoopTracerGlyph`), which traces it and keeps lapping it while the work
//  runs, around the window `bareWallSpot` or `bareFloorSpot` scored, and it follows the room as the camera
//  turns: the window's four corners go through the tracker's current warp each frame, and the line is bent onto the mapped
//  corners. It starts when the keyframe is taken and leaves with a fade when the item shows or the measurement fails. For a
//  shirt it traces the shirt itself instead (`ShirtOutline`): the outline of the learner's own top from the moment the panel
//  knows it is a shirt until the shirt first shows, and the outline of the area being painted while the shirt is painted,
//  until the painted still shows.
//
//  This file holds the pure rules (when the loop shows and clears, the window's corners, the corner mapping, the camera to
//  panel fit, the bent outline) and the views that draw it.
//

import SwiftUI
import simd

// MARK: - When the loop shows

/// The loop as the panel draws it. `beganAt` is `ProcessInfo.systemUptime` when the measurement began, which is when the
/// keyframe is taken, so the glyph's timeline starts there.
enum RoomArtLoopState: Equatable {
    case hidden
    case drawing(beganAt: TimeInterval)
    /// The whole line stays where a press picks the ghost back up, with no glyph lapping it, since no work runs until then.
    case waitingForAClick(beganAt: TimeInterval)
    /// `tracesTheLine` says whether a glyph laps the line while it fades: a lapping loop keeps lapping, and a still line fades
    /// with no glyph appearing on it. The ghost appearing fades a lapping loop still, since its glyph leaves for the ghost's
    /// lines, and `stillDrawnShare` keeps as much of the line as was drawn then, so a loop still in its first trace does not
    /// finish itself with no glyph drawing it.
    case fadingOut(beganAt: TimeInterval, tracesTheLine: Bool, stillDrawnShare: Double = 1)

    /// The panel's phase changed. The loop starts with a measurement, a first one or a click's, with a shirt being prepared,
    /// and with a shirt being painted, and keeps its clock while the work goes on: while placed furniture waits for its
    /// painting around its ghost's footprint, and when the garment is ready before the learner stands in view. After the
    /// furniture could not be drawn, the line stays still until a press picks the ghost back up. The ghost appearing, the
    /// item or the shirt showing, a floor that was not found, or a failure fades it, and a panel that closes or is still
    /// reading the page has no loop at all.
    func after(phaseChangedTo phase: RoomArtPhase, at now: TimeInterval) -> RoomArtLoopState {
        switch phase {
        case .measuring, .moving, .arranging, .preparingTheShirt, .waitingToSeeTheLearner, .paintingTheShirt:
            if case .drawing = self { return self }
            return .drawing(beganAt: now)
        case .couldNotDraw:
            if let beganAt { return .waitingForAClick(beganAt: beganAt) }
            return .waitingForAClick(beganAt: now)
        // The ghost appearing takes over from the loop: the theme's glyph leaves the loop's line for the ghost's lines, so
        // the loop fades still, with no second glyph lapping it, keeping the share of the line already drawn.
        case .placingTheFurniture:
            switch self {
            case .drawing(let beganAt):
                let drawnShare = CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: now - beganAt).drawnShare
                return .fadingOut(beganAt: beganAt, tracesTheLine: false, stillDrawnShare: drawnShare)
            case .waitingForAClick(let beganAt): return .fadingOut(beganAt: beganAt, tracesTheLine: false)
            case .hidden, .fadingOut: return self
            }
        case .showing, .waitingForAFloorClick, .showingTheShirt, .waitingForTheLearnerToStepBack, .showingThePaintedShirt, .failed:
            switch self {
            case .drawing(let beganAt): return .fadingOut(beganAt: beganAt, tracesTheLine: true)
            case .waitingForAClick(let beganAt): return .fadingOut(beganAt: beganAt, tracesTheLine: false)
            case .hidden, .fadingOut: return self
            }
        case .closed, .readingThePage, .waitingForTheCamera:
            return .hidden
        }
    }

    /// The fade is over, so the loop leaves the screen.
    func afterTheFadeFinished() -> RoomArtLoopState {
        if case .fadingOut = self { return .hidden }
        return self
    }

    var isFadingOut: Bool {
        if case .fadingOut = self { return true }
        return false
    }

    var isHidden: Bool { self == .hidden }

    /// Whether the theme's glyph traces and laps the line. A loop waiting for a click, and the fade that follows it, show the
    /// whole line still.
    var tracesTheLine: Bool {
        switch self {
        case .waitingForAClick: return false
        case .fadingOut(_, let tracesTheLine, _): return tracesTheLine
        case .hidden, .drawing: return true
        }
    }

    /// How much of the line a still loop shows: all of it, except a fade the ghost started during the loop's first trace.
    var stillDrawnShare: Double {
        if case .fadingOut(_, _, let stillDrawnShare) = self { return stillDrawnShare }
        return 1
    }

    var beganAt: TimeInterval? {
        switch self {
        case .hidden: return nil
        case .drawing(let beganAt), .waitingForAClick(let beganAt), .fadingOut(let beganAt, _, _): return beganAt
        }
    }
}

// MARK: - Where the loop is

/// The loop's window in the keyframe, and where it is in the current frame, both in camera pixels. The processor keeps the
/// newest one, so a loop that is fading out stays where the wall last was.
nonisolated struct RoomArtLoopSnapshot: Equatable, Sendable {
    let keyframeCorners: RoomArtCorners
    let currentCorners: RoomArtCorners
    /// For a shirt, the outline of the shirt itself in camera pixels, which the line traces instead of the window
    /// (`ShirtOutline`). Nil for the wall and the floor.
    var closedOutline: [CGPoint]? = nil

    /// A loop that traces `outline`, a closed line in camera pixels, with its bounding box as the window. Nil for an outline
    /// with fewer than 3 points or no area.
    init?(tracing outline: [CGPoint]) {
        guard outline.count >= 3, let left = outline.map(\.x).min(), let right = outline.map(\.x).max(),
              let top = outline.map(\.y).min(), let bottom = outline.map(\.y).max(), right - left > 1, bottom - top > 1 else { return nil }
        let box = RoomArtCorners(rect: CGRect(x: left, y: top, width: right - left, height: bottom - top))
        self.init(keyframeCorners: box, currentCorners: box, closedOutline: outline)
    }

    init(keyframeCorners: RoomArtCorners, currentCorners: RoomArtCorners, closedOutline: [CGPoint]? = nil) {
        self.keyframeCorners = keyframeCorners
        self.currentCorners = currentCorners
        self.closedOutline = closedOutline
    }
}

nonisolated extension RoomArtCorners {
    /// The four corners of an axis-aligned rectangle, in this feature's order.
    init(rect: CGRect) {
        self.init(
            topLeft: CGPoint(x: rect.minX, y: rect.minY),
            topRight: CGPoint(x: rect.maxX, y: rect.minY),
            bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
            bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        )
    }
}

nonisolated enum RoomArtLoopGeometry {
    /// The window around `anchor` that `bareWallSpot` or `bareFloorSpot` scored, in camera pixels. A spot near an edge,
    /// which only a click picks, shifts the window inside the frame, keeping its size, so the whole line stays in the panel.
    static func keyframeCorners(around anchor: CGPoint, frameSize: CGSize, on surfaceKind: RoomArtSurfaceKind) -> RoomArtCorners {
        let (widthShare, heightShare) = switch surfaceKind {
        case .wall: (RoomArtBareWallWindow.widthShareOfTheFrame, RoomArtBareWallWindow.heightShareOfTheFrame)
        case .floor: (RoomArtBareFloorWindow.widthShareOfTheFrame, RoomArtBareFloorWindow.heightShareOfTheFrame)
        }
        let windowSize = CGSize(
            width: min(frameSize.width * widthShare, frameSize.width),
            height: min(frameSize.height * heightShare, frameSize.height)
        )
        let left = min(max(anchor.x - windowSize.width / 2, 0), frameSize.width - windowSize.width)
        let top = min(max(anchor.y - windowSize.height / 2, 0), frameSize.height - windowSize.height)
        return RoomArtCorners(rect: CGRect(origin: CGPoint(x: left, y: top), size: windowSize))
    }

    /// The axis-aligned rectangle around four corners, which a loop bent onto those corners is drawn around.
    static func boundingCorners(of corners: RoomArtCorners) -> RoomArtCorners {
        let points = corners.clockwiseFromTopLeft
        let left = points.map(\.x).min() ?? 0, right = points.map(\.x).max() ?? 0
        let top = points.map(\.y).min() ?? 0, bottom = points.map(\.y).max() ?? 0
        return RoomArtCorners(rect: CGRect(x: left, y: top, width: max(right - left, 1), height: max(bottom - top, 1)))
    }

    /// Where the keyframe's corners are after the tracker's turn of the laptop, the same warp that moves the art's corners.
    static func corners(of keyframeCorners: RoomArtCorners, after warp: EuclideanWarp) -> RoomArtCorners {
        RoomArtCorners(clockwiseFromTopLeft: keyframeCorners.clockwiseFromTopLeft.map(warp.apply))
    }
}

// MARK: - The camera in the panel

/// How the camera frame sits in the panel: scaled to fit, keeping its shape, and centered, as the video view draws it. The
/// points are in the panel's SwiftUI coordinates, y growing down, like the camera's pixels.
nonisolated struct RoomArtVideoFit: Equatable, Sendable {
    let scale: CGFloat
    let origin: CGPoint

    init(cameraSize: CGSize, viewSize: CGSize) {
        guard cameraSize.width > 0, cameraSize.height > 0 else {
            scale = 0
            origin = .zero
            return
        }
        scale = min(viewSize.width / cameraSize.width, viewSize.height / cameraSize.height)
        origin = CGPoint(x: (viewSize.width - cameraSize.width * scale) / 2, y: (viewSize.height - cameraSize.height * scale) / 2)
    }

    var isUsable: Bool { scale > 0 }

    func viewPoint(forCameraPixel cameraPixel: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + cameraPixel.x * scale, y: origin.y + cameraPixel.y * scale)
    }

    func viewCorners(of cameraCorners: RoomArtCorners) -> RoomArtCorners {
        RoomArtCorners(clockwiseFromTopLeft: cameraCorners.clockwiseFromTopLeft.map(viewPoint(forCameraPixel:)))
    }
}

// MARK: - The line

/// The cursor loop's outline, drawn around the keyframe's window in panel points and then bent so its corners land on the
/// window's current corners.
enum RoomArtLoopOutline {
    /// Each curve of the cursor loop's outline is cut into this many straight pieces before it is bent, so a curve bends
    /// smoothly with the wall's perspective.
    private static let piecesPerCurve = 12

    /// Nil when the camera has no frame yet, or the corners cannot be mapped onto each other (three on one line). A snapshot
    /// with a shirt's outline draws that outline instead of the window.
    static func path(for snapshot: RoomArtLoopSnapshot, fit: RoomArtVideoFit) -> Path? {
        guard fit.isUsable else { return nil }
        if let closedOutline = snapshot.closedOutline {
            return closedPath(through: closedOutline.map(fit.viewPoint(forCameraPixel:)))
        }
        let keyframeCornersInThePanel = fit.viewCorners(of: snapshot.keyframeCorners)
        let keyframeRect = CGRect(
            x: keyframeCornersInThePanel.topLeft.x,
            y: keyframeCornersInThePanel.topLeft.y,
            width: keyframeCornersInThePanel.bottomRight.x - keyframeCornersInThePanel.topLeft.x,
            height: keyframeCornersInThePanel.bottomRight.y - keyframeCornersInThePanel.topLeft.y
        )
        let lineRect = keyframeRect.insetBy(dx: -CursorLoopOutline.gapFromTheMediaInPoints, dy: -CursorLoopOutline.gapFromTheMediaInPoints)
        let straightOutline = CursorLoopOutline.path(along: lineRect, seed: CursorLoopOutline.seed(for: keyframeRect))
        guard let keyframeToCurrent = perspectiveTransform(
            from: keyframeCornersInThePanel.clockwiseFromTopLeft,
            to: fit.viewCorners(of: snapshot.currentCorners).clockwiseFromTopLeft
        ) else { return nil }
        return bent(straightOutline, through: keyframeToCurrent)
    }

    /// A smooth closed line through every point in order: a Catmull-Rom spline written as cubic curves, so the line passes
    /// through the outline's points and bends between them like a hand-drawn stroke. It starts at the first point, where the
    /// cursor glyph starts its trace. Nil for fewer than 3 points.
    static func closedPath(through points: [CGPoint]) -> Path? {
        guard points.count >= 3 else { return nil }
        var path = Path()
        path.move(to: points[0])
        for index in points.indices {
            let previous = points[(index + points.count - 1) % points.count]
            let start = points[index]
            let end = points[(index + 1) % points.count]
            let next = points[(index + 2) % points.count]
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + (end.x - previous.x) / 6, y: start.y + (end.y - previous.y) / 6),
                control2: CGPoint(x: end.x - (next.x - start.x) / 6, y: end.y - (next.y - start.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }

    /// `path` with every point mapped through `transform`, a perspective transform that a path cannot apply itself.
    static func bent(_ path: Path, through transform: simd_double3x3) -> Path {
        var bentPath = Path()
        var currentPoint = CGPoint.zero
        func bentPoint(_ point: CGPoint) -> CGPoint { applyingPerspective(transform, to: point) }
        path.forEach { element in
            switch element {
            case .move(let to):
                bentPath.move(to: bentPoint(to))
                currentPoint = to
            case .line(let to):
                bentPath.addLine(to: bentPoint(to))
                currentPoint = to
            case .quadCurve(let to, let control):
                for piece in 1...piecesPerCurve {
                    let share = CGFloat(piece) / CGFloat(piecesPerCurve)
                    let remaining = 1 - share
                    bentPath.addLine(to: bentPoint(CGPoint(
                        x: remaining * remaining * currentPoint.x + 2 * remaining * share * control.x + share * share * to.x,
                        y: remaining * remaining * currentPoint.y + 2 * remaining * share * control.y + share * share * to.y
                    )))
                }
                currentPoint = to
            case .curve(let to, let firstControl, let secondControl):
                for piece in 1...piecesPerCurve {
                    let share = CGFloat(piece) / CGFloat(piecesPerCurve)
                    let remaining = 1 - share
                    let startWeight = remaining * remaining * remaining
                    let firstWeight = 3 * remaining * remaining * share
                    let secondWeight = 3 * remaining * share * share
                    let endWeight = share * share * share
                    bentPath.addLine(to: bentPoint(CGPoint(
                        x: startWeight * currentPoint.x + firstWeight * firstControl.x + secondWeight * secondControl.x + endWeight * to.x,
                        y: startWeight * currentPoint.y + firstWeight * firstControl.y + secondWeight * secondControl.y + endWeight * to.y
                    )))
                }
                currentPoint = to
            case .closeSubpath:
                bentPath.closeSubpath()
            }
        }
        return bentPath
    }
}

// MARK: - Timing

/// What one moment of the loop draws: how much of the line, where the glyph is, and whether there is a glyph at all.
struct RoomArtLoopDrawingPlan: Equatable {
    let frame: CursorLoopTimeline.Frame
    let showsTheTracer: Bool

    /// The glyph traces the line from the loop's first moment and keeps lapping it, since the panel has no cursor to fly in.
    /// With Reduce Motion on, the whole line shows at once with no glyph, and the view fades it in. A still line shows
    /// `stillDrawnShare` of itself with no glyph.
    static func at(secondsSinceTheLoopBegan: TimeInterval, reduceMotionIsOn: Bool, tracesTheLine: Bool, stillDrawnShare: Double = 1) -> RoomArtLoopDrawingPlan {
        if reduceMotionIsOn {
            return RoomArtLoopDrawingPlan(frame: CursorLoopTimeline.Frame(drawnShare: 1, tracer: .lapping(lapShare: 0)), showsTheTracer: false)
        }
        if !tracesTheLine {
            return RoomArtLoopDrawingPlan(frame: CursorLoopTimeline.Frame(drawnShare: stillDrawnShare, tracer: .lapping(lapShare: 0)), showsTheTracer: false)
        }
        return RoomArtLoopDrawingPlan(
            frame: CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: secondsSinceTheLoopBegan),
            showsTheTracer: true
        )
    }
}

// MARK: - Drawing

/// One frame of the loop: the line, and the theme's cursor glyph tracing it unless Reduce Motion is on or no look was given.
/// Reads nothing but its arguments, so a test renders it at a known time.
struct RoomArtLoopCanvas: View {
    let outline: Path?
    let frame: CursorLoopTimeline.Frame
    let color: Color
    let tracerLook: CursorLoopTracerLook?
    let showsTheTracer: Bool

    var body: some View {
        let line = outline.map(CursorLoopLine.init(outline:))
        ZStack {
            Canvas { context, _ in
                guard let line else { return }
                CursorLoopDrawing.drawTheInk(of: line, upToShare: frame.drawnShare, color: color, in: &context)
            }
            if showsTheTracer, let line, let tracerLook {
                CursorLoopTracerGlyph(
                    look: tracerLook,
                    placement: CursorLoopTracerPlacement(on: line, atShare: Self.shareOfTheLine(for: frame.tracer, on: line), cursorFacing: tracerLook.theme.cursorFacing)
                )
            }
        }
        .allowsHitTesting(false)
    }

    static func shareOfTheLine(for tracerPlace: CursorLoopTimeline.TracerPlace, on line: CursorLoopLine) -> Double {
        switch tracerPlace {
        case .tracing(let share): return share
        case .lapping(let lapShare): return line.shareOfTheLine(atLapShare: lapShare)
        }
    }
}

/// The loop over the camera view, redrawn every frame from the processor's newest snapshot. With Reduce Motion on, the
/// line fades in whole with no glyph, as the cursor loop's does.
struct RoomArtLoopView: View {
    let state: RoomArtLoopState
    let color: Color
    /// The theme's cursor, which traces the line. Nil draws the line with no tracer.
    var tracerLook: CursorLoopTracerLook? = nil
    /// The line's path for this moment, in the panel's points, or nil when there is nothing to draw yet.
    let outlineProvider: () -> Path?
    /// Called once the fade-out has run, so the panel stops redrawing.
    let onFadeFinished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
            // The frame is worked out here, outside the Canvas, because SwiftUI redraws a Canvas only when a value its
            // closure captured changes, and the clock and the tracker are not such values.
            let secondsSinceTheLoopBegan = state.beganAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            let plan = RoomArtLoopDrawingPlan.at(
                secondsSinceTheLoopBegan: secondsSinceTheLoopBegan, reduceMotionIsOn: reduceMotion, tracesTheLine: state.tracesTheLine, stillDrawnShare: state.stillDrawnShare
            )
            RoomArtLoopCanvas(outline: outlineProvider(), frame: plan.frame, color: color, tracerLook: tracerLook, showsTheTracer: plan.showsTheTracer)
        }
        .opacity(state.isFadingOut || (reduceMotion && !hasAppeared) ? 0 : 1)
        .animation(.easeOut(duration: CursorLoopState.fadeOutSeconds), value: state.isFadingOut)
        .animation(.easeIn(duration: 0.3), value: hasAppeared)
        .allowsHitTesting(false)
        .onAppear { hasAppeared = true }
        // The fade runs for its own length, and then the loop is gone. A new measurement before then cancels this task.
        .task(id: state.isFadingOut) {
            guard state.isFadingOut else { return }
            try? await Task.sleep(for: .seconds(CursorLoopState.fadeOutSeconds))
            guard !Task.isCancelled else { return }
            onFadeFinished()
        }
    }
}
