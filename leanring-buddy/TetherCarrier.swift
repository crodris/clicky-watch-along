//
//  TetherCarrier.swift
//  leanring-buddy
//
//  The carrier: SwiftUI cannot animate across windows, so every Tether move that crosses them (Send, and a Card's Glide out
//  of its origin and its Glide close back into it) plays on one shared click-through panel per display, at `.screenSaver + 2`,
//  above the cursor overlay windows. The carrier draws the moving view and a 1 point tether line in the origin's color,
//  from the origin to the moving view, which fades out 250 ms after the landing.
//
//  A move is a `CarrierFlightPlan`: plain data sampled ahead of time from the move's curve (`DS.Move`), built by the pure
//  functions here and tested on its own. The carrier turns it into Core Animation keyframes, so the render server plays the
//  move and a main thread that stalls right after it starts (an Apple Event to Chrome, say) cannot freeze it.
//
//  With Reduce Motion on, no move travels, so a caller does not use the carrier then: it applies the move's
//  `reduceMotionForm` to its own window, as the serve fades its disc in at the slot.
//

import AppKit
import SwiftUI

// MARK: - Plan

/// One moment of a carried view's move, in global AppKit coordinates (y grows upward): where the view's pivot is, how
/// large the view is drawn, and how opaque.
struct CarrierPose: Equatable {
    let pivot: CGPoint
    let scale: CGFloat
    let opacity: CGFloat
}

/// A move for the carrier to play, sampled ahead of time at even steps.
struct CarrierFlightPlan: Equatable {
    /// The carried view's frame at scale 1: where it rests at the end of a Send or a Glide, and at the start of a Return
    /// to source.
    let restingFrame: CGRect
    /// The point of the view the poses place, where it sits when the view is in `restingFrame`. The view scales about it,
    /// and the tether line ends on it.
    let pivotAtRest: CGPoint
    /// The poses from the start to the end, evenly spaced over `seconds`.
    let poses: [CarrierPose]
    let seconds: TimeInterval
    /// Where the tether line starts, which is the origin of the move. Nil draws no line.
    let tetherOrigin: CGPoint?
    /// True when the tether follows the path the pivot took, drawn from the origin up to the pivot, instead of running
    /// straight from the origin to the pivot. A Bring back needs it, since a straight line from a disc to the cursor
    /// would cross the video the spark goes around.
    var tetherFollowsThePath = false

    /// Steps per second when a move's curve is sampled. At a 60 or 120 Hz display a step is one or two frames, so the
    /// straight lines between keyframes read as the curve.
    static let samplesPerSecond = 120.0

    /// Send: the token leaves the cursor glyph and arcs into its slot along `path`, the serve's arc, at full size. The
    /// carried view is centered on the slot when it rests, and the tether runs from the cursor glyph to its center.
    static func send(along path: AgentTokenServePath, carriedSize: CGSize) -> CarrierFlightPlan {
        let seconds = AgentTokenServePath.flightSeconds
        let poses = sampleTimes(over: seconds).map { elapsedSeconds in
            CarrierPose(pivot: path.point(atFlightProgress: elapsedSeconds / seconds), scale: 1, opacity: 1)
        }
        return CarrierFlightPlan(
            restingFrame: CGRect(x: path.end.x - carriedSize.width / 2, y: path.end.y - carriedSize.height / 2, width: carriedSize.width, height: carriedSize.height),
            pivotAtRest: path.end,
            poses: poses,
            seconds: seconds,
            tetherOrigin: path.start
        )
    }

    /// Glide from origin: a Card opens out of `origin`, such as an agent's disc, into `cardFrame`, on the Glide spring.
    /// It grows out of the point of its frame nearest the origin, so a Card under a disc grows from its top edge, and the
    /// tether line runs from the origin to that point.
    static func glideFromOrigin(_ origin: CGPoint, into cardFrame: CGRect) -> CarrierFlightPlan {
        glide(origin: origin, cardFrame: cardFrame, curve: DS.Move.glide.curve, isOpening: true)
    }

    /// The Glide close, a Card's return to its source: the Card in `cardFrame` closes back into `origin`, on the Glide spring
    /// at `DS.Move.glideCloseTimeFactor`, and fades out as it arrives. It ends hidden, so the caller hides the real Card as it
    /// starts. This is not `DS.Move.returnToSource`, the pop-out's 0.8 s flatten into its video, which the page plays itself.
    static func glideClose(from cardFrame: CGRect, into origin: CGPoint) -> CarrierFlightPlan {
        glide(origin: origin, cardFrame: cardFrame, curve: DS.Move.glide.curve.timeScaled(by: DS.Move.glideCloseTimeFactor), isOpening: false)
    }

    private static func glide(origin: CGPoint, cardFrame: CGRect, curve: MoveCurve, isOpening: Bool) -> CarrierFlightPlan {
        let pivotAtRest = CGPoint(
            x: min(max(origin.x, cardFrame.minX), cardFrame.maxX),
            y: min(max(origin.y, cardFrame.minY), cardFrame.maxY)
        )
        let seconds = curve.seconds()
        let poses = sampleTimes(over: seconds).map { elapsedSeconds -> CarrierPose in
            let springProgress = curve.progress(atSeconds: elapsedSeconds)
            // A close plays the open's shape backward: from the Card at rest to the origin.
            let openShare = CGFloat(isOpening ? springProgress : 1 - springProgress)
            return CarrierPose(
                pivot: CGPoint(x: origin.x + (pivotAtRest.x - origin.x) * openShare, y: origin.y + (pivotAtRest.y - origin.y) * openShare),
                scale: DS.Move.glideStartScale + (1 - DS.Move.glideStartScale) * openShare,
                opacity: min(1, max(0, openShare * 3))
            )
        }
        return CarrierFlightPlan(restingFrame: cardFrame, pivotAtRest: pivotAtRest, poses: poses, seconds: seconds, tetherOrigin: origin)
    }

    /// The times of the samples: from 0 to `seconds` inclusive, at `samplesPerSecond`, so the last pose is the move's end.
    static func sampleTimes(over seconds: TimeInterval) -> [TimeInterval] {
        let stepCount = max(1, Int((seconds * samplesPerSecond).rounded()))
        return (0...stepCount).map { stepIndex in seconds * Double(stepIndex) / Double(stepCount) }
    }
}

/// The translation that, after scaling a layer by `pose.scale` about its anchor, puts the plan's pivot at `pose.pivot`.
/// A layer maps its point `q` (from its bottom-left corner) to `position + transform(q - anchor)`, and its position is its
/// frame's origin plus the anchor, so the pivot lands on `pose.pivot` and the layer scales about the pivot.
/// - `anchorInLayer`: the layer's anchor point in its own points, (0, 0) for the layer of a plain `NSView`.
func carrierLayerTranslation(for pose: CarrierPose, restingFrame: CGRect, pivotAtRest: CGPoint, anchorInLayer: CGPoint) -> CGVector {
    let pivotInLayer = CGPoint(x: pivotAtRest.x - restingFrame.minX, y: pivotAtRest.y - restingFrame.minY)
    return CGVector(
        dx: pose.pivot.x - restingFrame.minX - pose.scale * pivotInLayer.x - (1 - pose.scale) * anchorInLayer.x,
        dy: pose.pivot.y - restingFrame.minY - pose.scale * pivotInLayer.y - (1 - pose.scale) * anchorInLayer.y
    )
}

/// How much of a path's length a pivot has covered at each pose: the running total of the distances between neighboring
/// poses, so the first is 0 and the last is the whole path. The trail tether reveals its line by these shares.
func carrierTrailLengthsCovered(by pivots: [CGPoint]) -> [CGFloat] {
    var lengthCoveredSoFar: CGFloat = 0
    return pivots.enumerated().map { index, pivot in
        if index > 0 { lengthCoveredSoFar += hypot(pivot.x - pivots[index - 1].x, pivot.y - pivots[index - 1].y) }
        return lengthCoveredSoFar
    }
}

/// The tether line at each pose: its length and its angle from the origin to the pose's pivot. The angles are unwrapped,
/// so a line that turns past straight left keeps turning the short way instead of spinning a full circle between two
/// keyframes.
func carrierTetherLines(from origin: CGPoint, to ends: [CGPoint]) -> [(length: CGFloat, angle: CGFloat)] {
    var lines: [(length: CGFloat, angle: CGFloat)] = []
    for end in ends {
        var angle = atan2(end.y - origin.y, end.x - origin.x)
        if let previousAngle = lines.last?.angle {
            while angle - previousAngle > .pi { angle -= 2 * .pi }
            while angle - previousAngle < -.pi { angle += 2 * .pi }
        }
        // A line with no length has no direction, and Core Animation draws a zero width as nothing, which is right.
        lines.append((length: hypot(end.x - origin.x, end.y - origin.y), angle: angle))
    }
    return lines
}

// MARK: - Carrier

/// A carrier panel. It ignores the mouse, so a click during a move reaches the window under it.
private final class TetherCarrierPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The shared carrier: one panel per display, each covering its display, shown only while a move plays there. Several
/// moves can play at once, each in its own view. A move stays on one display, since a panel's window draws only on the
/// display it is on, so a caller picks the display its origin and destination share.
@MainActor
final class TetherCarrier {
    static let shared = TetherCarrier()

    private var panelsByDisplayID: [CGDirectDisplayID: TetherCarrierPanel] = [:]
    private var flightsPlayingByDisplayID: [CGDirectDisplayID: [CarrierFlight]] = [:]

    private init() {}

    /// Plays `plan` with `content` drawn in the plan's resting frame, on the display `displayID`.
    ///
    /// - `tetherColor`: the origin's color, such as the cursor's accent for a Send.
    /// - `onLanded`: called once, when the move ends or `landAtOnce` ends it early. Show the real surface here: the
    ///   carried view stays over it for `CarrierFlight.secondsTheCarriedViewStaysAfterLanding`, so nothing blinks.
    /// - `onGone`: called once with the flight, when the carried view has left the screen after the landing.
    @discardableResult
    func play<Content: View>(
        _ plan: CarrierFlightPlan,
        carrying content: Content,
        onDisplay displayID: CGDirectDisplayID,
        tetherColor: NSColor,
        onLanded: @escaping () -> Void,
        onGone: @escaping (CarrierFlight) -> Void = { _ in }
    ) -> CarrierFlight {
        let flight = CarrierFlight(plan: plan, onLanded: onLanded, onGone: onGone, onFinished: { [weak self] finishedFlight in
            self?.forget(finishedFlight, onDisplay: displayID)
        })
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            // The display went away between the plan and the move, so the thing lands where it is going at once.
            flight.landOnTheNextTurn()
            return flight
        }
        let panel = panel(for: displayID, screen: screen)
        flightsPlayingByDisplayID[displayID, default: []].append(flight)
        flight.start(in: panel, panelOrigin: panel.frame.origin, carrying: content, tetherColor: tetherColor)
        return flight
    }

    private func panel(for displayID: CGDirectDisplayID, screen: NSScreen) -> TetherCarrierPanel {
        let panel = panelsByDisplayID[displayID] ?? makePanel()
        panelsByDisplayID[displayID] = panel
        // The display may have moved or changed size since the last move. A panel with a move playing keeps its frame, so
        // that move stays where it is.
        if flightsPlayingByDisplayID[displayID, default: []].isEmpty, panel.frame != screen.frame {
            panel.setFrame(screen.frame, display: false)
        }
        return panel
    }

    private func makePanel() -> TetherCarrierPanel {
        let panel = TetherCarrierPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Two above the cursor overlay windows (one above `.screenSaver`), so a token draws over the blue cursor it leaves.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        let contentView = NSView()
        contentView.wantsLayer = true
        panel.contentView = contentView
        return panel
    }

    private func forget(_ finishedFlight: CarrierFlight, onDisplay displayID: CGDirectDisplayID) {
        flightsPlayingByDisplayID[displayID]?.removeAll { $0 === finishedFlight }
        if flightsPlayingByDisplayID[displayID, default: []].isEmpty {
            panelsByDisplayID[displayID]?.orderOut(nil)
        }
    }
}

/// One move on the carrier. Hold it to end the move early with `landAtOnce`.
@MainActor
final class CarrierFlight {
    /// How long the carried view stays over the real surface after the landing, so the real one has drawn underneath
    /// before the carried one goes, and the learner never sees a gap. Only the main thread removes it, never the render
    /// server, so a stalled landing cannot leave a frame with nothing on screen.
    static let secondsTheCarriedViewStaysAfterLanding: TimeInterval = 0.05

    /// How long past its own time a move may take before it lands anyway, such as a move on a display that went to sleep,
    /// whose animation never reports that it finished.
    private static let secondsBeforeAStuckMoveLands: TimeInterval = 1

    private let plan: CarrierFlightPlan
    private let onLanded: () -> Void
    private let onGone: (CarrierFlight) -> Void
    private let onFinished: (CarrierFlight) -> Void
    /// Holds the tether's view and the carried view, in that order, so the line draws under the carried view.
    private var flightView: NSView?
    private var carriedView: NSView?
    private var tetherLayer: CALayer?
    private var hasLanded = false

    fileprivate init(plan: CarrierFlightPlan, onLanded: @escaping () -> Void, onGone: @escaping (CarrierFlight) -> Void, onFinished: @escaping (CarrierFlight) -> Void) {
        self.plan = plan
        self.onLanded = onLanded
        self.onGone = onGone
        self.onFinished = onFinished
    }

    fileprivate func start<Content: View>(in panel: NSPanel, panelOrigin: CGPoint, carrying content: Content, tetherColor: NSColor) {
        guard let contentView = panel.contentView else { return landOnTheNextTurn() }
        func local(_ globalPoint: CGPoint) -> CGPoint { CGPoint(x: globalPoint.x - panelOrigin.x, y: globalPoint.y - panelOrigin.y) }

        let flightView = NSView(frame: contentView.bounds)
        flightView.wantsLayer = true
        flightView.autoresizingMask = [.width, .height]

        let tetherHostView = NSView(frame: flightView.bounds)
        tetherHostView.wantsLayer = true
        tetherHostView.autoresizingMask = [.width, .height]
        flightView.addSubview(tetherHostView)

        let restingFrameInPanel = CGRect(origin: local(plan.restingFrame.origin), size: plan.restingFrame.size)
        let carriedView = NSView(frame: restingFrameInPanel)
        carriedView.wantsLayer = true
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = carriedView.bounds
        hostingView.autoresizingMask = [.width, .height]
        carriedView.addSubview(hostingView)
        flightView.addSubview(carriedView)
        contentView.addSubview(flightView)
        // Lay the views out now, so the carried view's layer exists with its final anchor before the keyframes are built.
        flightView.layoutSubtreeIfNeeded()
        self.flightView = flightView
        self.carriedView = carriedView

        guard let carriedLayer = carriedView.layer else { return landOnTheNextTurn() }
        let anchorInLayer = CGPoint(x: carriedLayer.anchorPoint.x * carriedLayer.bounds.width, y: carriedLayer.anchorPoint.y * carriedLayer.bounds.height)
        let transforms = plan.poses.map { pose -> NSValue in
            let translation = carrierLayerTranslation(for: pose, restingFrame: plan.restingFrame, pivotAtRest: plan.pivotAtRest, anchorInLayer: anchorInLayer)
            return NSValue(caTransform3D: CATransform3DConcat(
                CATransform3DMakeScale(pose.scale, pose.scale, 1),
                CATransform3DMakeTranslation(translation.dx, translation.dy, 0)
            ))
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.land() }
        }
        carriedLayer.add(Self.keyframes("transform", transforms, seconds: plan.seconds), forKey: "carry.transform")
        carriedLayer.add(Self.keyframes("opacity", plan.poses.map { NSNumber(value: Double($0.opacity)) }, seconds: plan.seconds), forKey: "carry.opacity")
        CATransaction.commit()

        // The tether is added outside that transaction, since its fade outlasts the move and would hold back the landing.
        if let tetherOrigin = plan.tetherOrigin, let tetherHostLayer = tetherHostView.layer {
            let tetherLayer: CALayer
            if plan.tetherFollowsThePath {
                tetherLayer = Self.trailTetherLayer(pivotsInPanel: plan.poses.map { local($0.pivot) }, color: tetherColor, seconds: plan.seconds)
            } else {
                tetherLayer = Self.tetherLayer(
                    from: local(tetherOrigin),
                    lines: carrierTetherLines(from: tetherOrigin, to: plan.poses.map(\.pivot)),
                    color: tetherColor,
                    seconds: plan.seconds
                )
            }
            tetherHostLayer.addSublayer(tetherLayer)
            self.tetherLayer = tetherLayer
        }

        panel.orderFrontRegardless()
        // Commit the layer tree now. Without this, a main thread that blocks later in this turn of the run loop holds the
        // commit back while the animations' clock runs, and the learner sees the move only for whatever is left of it:
        // a 400 ms stall left 100 ms of a half second serve in the phase-zero prototype.
        CATransaction.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + plan.seconds + Self.secondsBeforeAStuckMoveLands) { [weak self] in
            self?.land()
        }
    }

    /// Ends the move where it is, as a push-to-talk press does: the carried view jumps to its end, the tether goes, and
    /// `onLanded` runs at once.
    /// - `hidingTheCarriedView`: the carried view goes from the screen at once instead of resting at its end for the landing's
    ///   0.05 seconds, for a surface closed during its move, whose real surface will not show.
    func landAtOnce(hidingTheCarriedView: Bool = false) {
        tetherLayer?.removeAllAnimations()
        land(hidingTheCarriedView: hidingTheCarriedView)
    }

    /// Whether the tether line is still on the screen. False once it has ended with `endTheTetherNow`, or for a move with none.
    var tetherIsShowing: Bool { tetherLayer != nil }

    /// Takes the tether off the screen now, instead of letting it fade. The dock calls it when a disc is about to slide out
    /// from under the landed token, since the line would then end where the disc used to be.
    func endTheTetherNow() {
        tetherLayer?.removeAllAnimations()
        tetherLayer?.removeFromSuperlayer()
        tetherLayer = nil
    }

    /// Lands a move that cannot play, after `play` has returned, so the caller holds the flight before `onLanded` runs and
    /// never keeps a flight that already landed.
    fileprivate func landOnTheNextTurn() {
        DispatchQueue.main.async { [self] in landAtOnce() }
    }

    private func land(hidingTheCarriedView: Bool = false) {
        guard !hasLanded else { return }
        hasLanded = true
        carriedView?.layer?.removeAllAnimations()
        // Without its animations the carried view rests in its frame at full size, which is the end of a Send or a Glide.
        if carriedViewHidesOnLanding(endOpacity: plan.poses.last?.opacity, closedDuringTheMove: hidingTheCarriedView) {
            carriedView?.isHidden = true
        }
        onLanded()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsTheCarriedViewStaysAfterLanding) { [self] in
            // Dropping the view stops any animation of its own, such as a token's ring.
            carriedView?.removeFromSuperview()
            carriedView = nil
            onGone(self)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + DS.Move.tetherFadeSeconds + 0.1) { [self] in
            flightView?.removeFromSuperview()
            flightView = nil
            onFinished(self)
        }
    }

    // MARK: Layers

    /// A keyframe animation the render server plays, which holds its last value until the flight removes it.
    private static func keyframes(_ keyPath: String, _ values: [Any], seconds: TimeInterval) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = seconds
        animation.calculationMode = .linear
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// The tether of a move whose line follows the path: the pivot's whole path drawn as one line, revealed up to the pivot on
    /// the same clock as the carried view, so the line's end is attached on every frame. It fades like the straight tether.
    /// Each keyframe of the reveal is the share of the path's length the pivot has covered at that pose.
    private static func trailTetherLayer(pivotsInPanel: [CGPoint], color: NSColor, seconds: TimeInterval) -> CALayer {
        let lengthCoveredAtEachPose = carrierTrailLengthsCovered(by: pivotsInPanel)
        let wholeLength = lengthCoveredAtEachPose.last ?? 0
        let trailPath = CGMutablePath()
        if let firstPivot = pivotsInPanel.first {
            trailPath.move(to: firstPivot)
            for pivot in pivotsInPanel.dropFirst() { trailPath.addLine(to: pivot) }
        }
        let trailLayer = CAShapeLayer()
        trailLayer.path = trailPath
        trailLayer.fillColor = nil
        trailLayer.strokeColor = color.cgColor
        trailLayer.lineWidth = DS.Move.tetherLineWidth
        trailLayer.lineJoin = .round
        trailLayer.allowsEdgeAntialiasing = true
        trailLayer.strokeEnd = 1
        trailLayer.opacity = 0
        let revealedShares = lengthCoveredAtEachPose.map { wholeLength > 0 ? NSNumber(value: Double($0 / wholeLength)) : NSNumber(value: 1) }
        trailLayer.add(keyframes("strokeEnd", revealedShares, seconds: seconds), forKey: "tether.reveal")

        let secondsUntilFadedOut = seconds + DS.Move.tetherFadeSeconds
        let fade = keyframes("opacity", [1, 1, 0], seconds: secondsUntilFadedOut)
        fade.keyTimes = [0, NSNumber(value: seconds / secondsUntilFadedOut), 1]
        trailLayer.add(fade, forKey: "tether.fade")
        return trailLayer
    }

    /// The tether: a solid line from the origin whose length and angle follow the carried view's pivot on the same clock,
    /// so it is attached on every frame. It stays for the move, then fades over `DS.Move.tetherFadeSeconds`. Its model
    /// opacity is 0, so it is gone once its animations are.
    private static func tetherLayer(from originInPanel: CGPoint, lines: [(length: CGFloat, angle: CGFloat)], color: NSColor, seconds: TimeInterval) -> CALayer {
        let lineLayer = CALayer()
        lineLayer.backgroundColor = color.cgColor
        // The line turns to every angle, and without smoothing a diagonal 1 point line draws as stairs.
        lineLayer.allowsEdgeAntialiasing = true
        lineLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        lineLayer.position = originInPanel
        lineLayer.bounds = CGRect(x: 0, y: 0, width: lines.last?.length ?? 0, height: DS.Move.tetherLineWidth)
        lineLayer.transform = CATransform3DMakeRotation(lines.last?.angle ?? 0, 0, 0, 1)
        lineLayer.opacity = 0
        lineLayer.add(keyframes("transform.rotation.z", lines.map { NSNumber(value: Double($0.angle)) }, seconds: seconds), forKey: "tether.angle")
        lineLayer.add(keyframes("bounds.size.width", lines.map { NSNumber(value: Double($0.length)) }, seconds: seconds), forKey: "tether.length")

        let secondsUntilFadedOut = seconds + DS.Move.tetherFadeSeconds
        let fade = keyframes("opacity", [1, 1, 0], seconds: secondsUntilFadedOut)
        fade.keyTimes = [0, NSNumber(value: seconds / secondsUntilFadedOut), 1]
        lineLayer.add(fade, forKey: "tether.fade")
        return lineLayer
    }
}

/// Whether the carried view hides when its move lands. A Glide close ends hidden (an end opacity of 0), and so does a move
/// whose surface closed during it, since a carried view resting at full size would show the whole surface for 0.05 seconds.
nonisolated func carriedViewHidesOnLanding(endOpacity: CGFloat?, closedDuringTheMove: Bool) -> Bool {
    closedDuringTheMove || endOpacity == 0
}
