//
//  RoomArtLoop.swift
//  leanring-buddy
//
//  Clicky's loop around the wall spot while the room art panel measures the wall. It is the cursor loop's own line and
//  spark (`CursorLoopOutline`, `CursorLoopTimeline`, `CursorLoopDrawing`) in the theme's accent, drawn around the window
//  `bareWallSpot` scored, and it follows the wall as the camera turns: the window's four corners go through the tracker's
//  current warp each frame, and the line is bent onto the mapped corners. It starts when the keyframe is taken and leaves
//  with a fade when the art shows or the measurement fails.
//
//  This file holds the pure rules (when the loop shows and clears, the window's corners, the corner mapping, the camera to
//  panel fit, the bent outline) and the views that draw it.
//

import SwiftUI
import simd

// MARK: - When the loop shows

/// The loop as the panel draws it. `beganAt` is `ProcessInfo.systemUptime` when the measurement began, which is when the
/// keyframe is taken, so the spark's timeline starts there.
enum RoomArtLoopState: Equatable {
    case hidden
    case drawing(beganAt: TimeInterval)
    case fadingOut(beganAt: TimeInterval)

    /// The panel's phase changed. The loop starts with a measurement, a first one or a click's, and keeps its clock while
    /// the measurement goes on, such as when the page is read before the wall is. The art showing, or a failure, fades it,
    /// and a panel that closes or starts its camera has no loop at all.
    func after(phaseChangedTo phase: RoomArtPhase, at now: TimeInterval) -> RoomArtLoopState {
        switch phase {
        case .measuring, .moving:
            if case .drawing = self { return self }
            return .drawing(beganAt: now)
        case .showing, .failed:
            if case .drawing(let beganAt) = self { return .fadingOut(beganAt: beganAt) }
            return self
        case .closed, .startingCamera:
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

    var beganAt: TimeInterval? {
        switch self {
        case .hidden: return nil
        case .drawing(let beganAt), .fadingOut(let beganAt): return beganAt
        }
    }
}

// MARK: - Where the loop is

/// The loop's window in the keyframe, and where it is in the current frame, both in camera pixels. The processor keeps the
/// newest one, so a loop that is fading out stays where the wall last was.
nonisolated struct RoomArtLoopSnapshot: Equatable, Sendable {
    let keyframeCorners: RoomArtCorners
    let currentCorners: RoomArtCorners
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
    /// The window around `anchor` that `bareWallSpot` scored, in camera pixels. A spot near an edge, which only a click
    /// picks, shifts the window inside the frame, keeping its size, so the whole line stays in the panel.
    static func keyframeCorners(around anchor: CGPoint, frameSize: CGSize) -> RoomArtCorners {
        let windowSize = CGSize(
            width: min(frameSize.width * RoomArtBareWallWindow.widthShareOfTheFrame, frameSize.width),
            height: min(frameSize.height * RoomArtBareWallWindow.heightShareOfTheFrame, frameSize.height)
        )
        let left = min(max(anchor.x - windowSize.width / 2, 0), frameSize.width - windowSize.width)
        let top = min(max(anchor.y - windowSize.height / 2, 0), frameSize.height - windowSize.height)
        return RoomArtCorners(rect: CGRect(origin: CGPoint(x: left, y: top), size: windowSize))
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

    /// Nil when the camera has no frame yet, or the corners cannot be mapped onto each other (three on one line).
    static func path(for snapshot: RoomArtLoopSnapshot, fit: RoomArtVideoFit) -> Path? {
        guard fit.isUsable else { return nil }
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

/// What one moment of the loop draws: how much of the line, where the spark is, and whether there is a spark at all.
struct RoomArtLoopDrawingPlan: Equatable {
    let frame: CursorLoopTimeline.Frame
    let showsTheSpark: Bool

    /// The cursor loop's own timeline, so the two loops move alike. With Reduce Motion on, the whole line shows at once with
    /// no spark, and the view fades it in.
    static func at(secondsSinceTheLoopBegan: TimeInterval, reduceMotionIsOn: Bool) -> RoomArtLoopDrawingPlan {
        if reduceMotionIsOn {
            return RoomArtLoopDrawingPlan(frame: CursorLoopTimeline.Frame(drawnShare: 1, spark: .onTheLoop(share: 0)), showsTheSpark: false)
        }
        return RoomArtLoopDrawingPlan(
            frame: CursorLoopTimeline.frame(secondsSinceTheLoopBegan: secondsSinceTheLoopBegan, secondsWhenTheSparkSlows: nil),
            showsTheSpark: true
        )
    }
}

// MARK: - Drawing

/// One frame of the loop: the line, and the spark unless Reduce Motion is on. Reads nothing but its arguments, so a test
/// renders it at a known time.
struct RoomArtLoopCanvas: View {
    let outline: Path?
    let frame: CursorLoopTimeline.Frame
    let color: Color
    let showsTheSpark: Bool

    var body: some View {
        Canvas { context, _ in
            guard let outline else { return }
            if showsTheSpark {
                // There is no cursor in the panel, so the spark starts on the line instead of flying in.
                CursorLoopDrawing.drawTheLineAndTheSpark(outline, frame: frame, color: color, cursorPosition: nil, in: &context)
            } else {
                CursorLoopDrawing.drawTheLine(outline, share: frame.drawnShare, color: color, in: &context)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The loop over the camera view, redrawn every frame from the processor's newest snapshot. With Reduce Motion on, the
/// line fades in whole with no spark, as the cursor loop's does.
struct RoomArtLoopView: View {
    let state: RoomArtLoopState
    let color: Color
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
            let plan = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: secondsSinceTheLoopBegan, reduceMotionIsOn: reduceMotion)
            RoomArtLoopCanvas(outline: outlineProvider(), frame: plan.frame, color: color, showsTheSpark: plan.showsTheSpark)
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
