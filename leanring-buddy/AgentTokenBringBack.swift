//
//  AgentTokenBringBack.swift
//  leanring-buddy
//
//  Bring back: when an agent ends, a spark runs from its disc in the menu bar along the screen's top edge, then drops down
//  to the cursor, and the ending chip shows there as it lands. The run along the edge stays off the page, and when the
//  cursor loop knows where the video is, the drop comes down beside it and turns in to the cursor only at its end. A 1 point
//  tether line in the agent's color traces the route behind the spark and fades 250 ms after the landing. With Reduce Motion
//  on, nothing travels: a still ring fades in at the cursor, and the chip follows it.
//
//  This file is the pure route and the plans the carrier plays (`TetherCarrier`), plus the two small views the carrier
//  draws. `AgentTokenDockController.bringBack` reads the screens and runs the move. Every point is in global AppKit screen
//  coordinates, where y grows upward.
//

import CoreGraphics
import SwiftUI

// MARK: - Route

/// The spark's route: a quadratic arc from the disc up to the top edge and along it to an elbow past the cursor, then a
/// cubic drop straight down beside the cursor that turns in to it at the end. The two arcs share the move's time by `shareOfTheMoveAlongTheEdge`.
struct AgentTokenBringBackPath: Equatable {
    let start: CGPoint
    let edgeControl: CGPoint
    let elbow: CGPoint
    let dropControl: CGPoint
    let end: CGPoint

    /// How much of the half second goes to the run along the edge, which is the shorter run: 220 of the design's 540 ms.
    static let shareOfTheMoveAlongTheEdge = 0.4
    /// How far past the cursor's x the spark runs along the edge before it drops.
    static let elbowDistanceFromTheCursor: CGFloat = 100
    /// How far the spark keeps from the screen's side edges.
    static let sideMargin: CGFloat = 20
    /// How far below the screen's top edge the run along the edge keeps, so the spark stays on the bar.
    static let runBelowTheTopEdge: CGFloat = 3
    /// How far the elbow sits under the run's own height, which gives the first arc a small downward finish.
    static let elbowDropBelowTheRun: CGFloat = 8

    /// The Bring back move's time, 0.6 seconds.
    static var flightSeconds: TimeInterval { DS.Move.bringBack.curve.seconds() }

    /// The point after `flightProgress` of the move, from 0 (the disc) to 1 (the cursor), eased by the move's own curve.
    func point(atFlightProgress flightProgress: Double) -> CGPoint {
        let easedProgress = DS.Move.bringBack.curve.progress(atSeconds: flightProgress * Self.flightSeconds)
        let alongTheEdge = Self.shareOfTheMoveAlongTheEdge
        if easedProgress <= alongTheEdge {
            return Self.quadraticPoint(from: start, control: edgeControl, to: elbow, at: easedProgress / alongTheEdge)
        }
        // The drop is a cubic whose two control points both sit at `dropControl`, beside the cursor at its height, so the spark
        // comes straight down first and turns in late. A quadratic cut diagonally across a video under the elbow.
        return Self.cubicPoint(from: elbow, control: dropControl, to: end, at: (easedProgress - alongTheEdge) / (1 - alongTheEdge))
    }

    private static func cubicPoint(from startPoint: CGPoint, control: CGPoint, to endPoint: CGPoint, at share: Double) -> CGPoint {
        let remainingShare = 1 - share
        let controlWeight = 3 * remainingShare * share
        return CGPoint(
            x: remainingShare * remainingShare * remainingShare * startPoint.x + controlWeight * control.x + share * share * share * endPoint.x,
            y: remainingShare * remainingShare * remainingShare * startPoint.y + controlWeight * control.y + share * share * share * endPoint.y
        )
    }

    private static func quadraticPoint(from startPoint: CGPoint, control: CGPoint, to endPoint: CGPoint, at share: Double) -> CGPoint {
        let remainingShare = 1 - share
        return CGPoint(
            x: remainingShare * remainingShare * startPoint.x + 2 * remainingShare * share * control.x + share * share * endPoint.x,
            y: remainingShare * remainingShare * startPoint.y + 2 * remainingShare * share * control.y + share * share * endPoint.y
        )
    }
}

/// The route from a disc to the cursor, along the top edge of the display the two share.
///
/// - `discCenter`: the center of the disc's panel, in the menu bar.
/// - `cursorPoint`: where the ending chip's tail will point, which is the blue cursor glyph.
/// - `screenFrame`: the display's frame, whose top edge the spark runs along.
/// - `mediaRect`: the video or image the cursor loop is around, which the drop keeps clear of, or nil when none is known.
func agentTokenBringBackPath(from discCenter: CGPoint, to cursorPoint: CGPoint, onScreenWithFrame screenFrame: CGRect, keepingClearOf mediaRect: CGRect? = nil) -> AgentTokenBringBackPath {
    let runY = screenFrame.maxY - AgentTokenBringBackPath.runBelowTheTopEdge
    // The elbow goes to the side of the cursor with room for it, the right one when both fit, and stays off the screen's edges.
    let distance = AgentTokenBringBackPath.elbowDistanceFromTheCursor
    let lowestElbowX = screenFrame.minX + AgentTokenBringBackPath.sideMargin
    let highestElbowX = screenFrame.maxX - AgentTokenBringBackPath.sideMargin
    let roomOnTheRight = highestElbowX - cursorPoint.x
    let wantedElbowX = roomOnTheRight >= distance ? cursorPoint.x + distance : cursorPoint.x - distance
    let elbowX = agentTokenBringBackElbowX(
        wantedElbowX: min(max(wantedElbowX, lowestElbowX), highestElbowX),
        cursorPoint: cursorPoint,
        elbowXRange: lowestElbowX...highestElbowX,
        mediaRect: mediaRect
    )
    let elbow = CGPoint(x: elbowX, y: runY - AgentTokenBringBackPath.elbowDropBelowTheRun)
    return AgentTokenBringBackPath(
        start: discCenter,
        edgeControl: CGPoint(x: (discCenter.x + elbowX) / 2, y: runY),
        elbow: elbow,
        dropControl: CGPoint(x: elbowX, y: cursorPoint.y),
        end: cursorPoint
    )
}

/// Where the drop comes down. A drop above the media whose column runs through it would cross the video, so the elbow
/// moves just past the media's nearer side, with the side margin, when that side is on the screen. The drop then runs beside
/// the video and turns in to the cursor only at its end. A media that fills the screen's width leaves the elbow where it was.
func agentTokenBringBackElbowX(wantedElbowX: CGFloat, cursorPoint: CGPoint, elbowXRange: ClosedRange<CGFloat>, mediaRect: CGRect?) -> CGFloat {
    let margin = AgentTokenBringBackPath.sideMargin
    guard let mediaRect, mediaRect.maxY > cursorPoint.y,
          wantedElbowX > mediaRect.minX - margin, wantedElbowX < mediaRect.maxX + margin else { return wantedElbowX }
    let sidesBesideTheMedia = [mediaRect.minX - margin, mediaRect.maxX + margin].filter { elbowXRange.contains($0) }
    return sidesBesideTheMedia.min { abs($0 - cursorPoint.x) < abs($1 - cursorPoint.x) } ?? wantedElbowX
}

// MARK: - Plans

extension CarrierFlightPlan {
    /// Bring back: a spark of `sparkSize` runs the route at the move's pace, and the tether traces the route behind it. The
    /// spark rests on the cursor point at the end, where the carrier lets go of it.
    static func bringBack(along path: AgentTokenBringBackPath, sparkSize: CGSize) -> CarrierFlightPlan {
        let seconds = AgentTokenBringBackPath.flightSeconds
        let poses = sampleTimes(over: seconds).map { elapsedSeconds in
            CarrierPose(pivot: path.point(atFlightProgress: elapsedSeconds / seconds), scale: 1, opacity: 1)
        }
        return CarrierFlightPlan(
            restingFrame: CGRect(x: path.end.x - sparkSize.width / 2, y: path.end.y - sparkSize.height / 2, width: sparkSize.width, height: sparkSize.height),
            pivotAtRest: path.end,
            poses: poses,
            seconds: seconds,
            tetherOrigin: path.start,
            tetherFollowsThePath: true
        )
    }

    /// How long the still ring stays after it has faded in, before the chip takes its place.
    static let secondsTheStillRingHolds: TimeInterval = 0.3

    /// Bring back with Reduce Motion on: no travel and no tether. A ring of `ringSize` fades in at the cursor over the move's
    /// Reduce Motion fade (`DS.Move.bringBack.reduceMotionForm`), holds still, and the chip shows as it ends.
    static func bringBackWithReduceMotion(at cursorPoint: CGPoint, ringSize: CGSize) -> CarrierFlightPlan {
        let fadeSeconds = DS.Move.bringBack.reduceMotionForm.fadeSeconds
        let seconds = fadeSeconds + secondsTheStillRingHolds
        let poses = sampleTimes(over: seconds).map { elapsedSeconds in
            CarrierPose(pivot: cursorPoint, scale: 1, opacity: CGFloat(min(1, elapsedSeconds / fadeSeconds)))
        }
        return CarrierFlightPlan(
            restingFrame: CGRect(x: cursorPoint.x - ringSize.width / 2, y: cursorPoint.y - ringSize.height / 2, width: ringSize.width, height: ringSize.height),
            pivotAtRest: cursorPoint,
            poses: poses,
            seconds: seconds,
            tetherOrigin: nil
        )
    }
}

// MARK: - Views the carrier draws

/// The spark: a white dot with a ring in the agent's color, which reads on any page.
struct AgentBringBackSparkView: View {
    let color: Color
    static let diameter: CGFloat = 10

    var body: some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(color, lineWidth: 2))
            .frame(width: Self.diameter, height: Self.diameter)
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }
}

/// The still ring Reduce Motion leaves at the cursor instead of a flight.
struct AgentBringBackRingView: View {
    let color: Color
    static let diameter: CGFloat = 20

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2)
            .frame(width: Self.diameter, height: Self.diameter)
            .shadow(color: .black.opacity(0.35), radius: 1.5, x: 0, y: 1)
    }
}

// MARK: - What a push-to-talk press ends

/// What a push-to-talk press ends on screen, in the order the press handler ends them (`CompanionManager.handleShortcutTransition`).
/// The order matters twice, so a test pins it.
enum PushToTalkPressStep: CaseIterable {
    /// The recap's gather ends and its discs show in their places at once. It comes first: landing the gather's flights before
    /// the gather knows it was cancelled would unfold the recap Card over the request the press starts.
    case endTheRecapGather
    /// A serve, a Bring back spark, and a pause's moves land at once. A landing spark shows the chip it carries.
    case landTheFlights
    /// A scrub on its way to the moment lands at once: the video seeks now, and the cursor goes back to the mouse.
    case landTheScrub
    case hideTheStatusLabel
    /// The chip shrinks into the cursor. It comes after the landing, so the chip a Bring back spark carries shows first and
    /// then shrinks like any chip already up.
    case recallTheChip
    case endTheCursorLoop
}
