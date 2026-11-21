//
//  AgentTokenServe.swift
//  leanring-buddy
//
//  The serve: when a tool starts a background agent, that agent's own token leaves the blue cursor and arcs into its slot
//  beside the notch, so the learner sees the cursor hand the work off. This file is the plain data and pure functions:
//  whether the token flies, fades in, or just appears, the arc it flies along, and which display it flies to. The AppKit
//  side (`AgentTokenDockController`, which plays the flight on `TetherCarrier`) reads the screens and runs the flight. Every point here is in
//  global AppKit screen coordinates, where y grows upward.
//

import CoreGraphics
import Foundation

// MARK: - Plan

/// What happens as a new agent's token arrives beside the notch.
enum AgentTokenServePlan: Equatable {
    /// The token flies from the cursor along the path, and the router's spoken confirmation waits for it to land.
    case fly(AgentTokenServePath)
    /// Reduce Motion is on: the token fades in at its slot, and the confirmation plays at once.
    case fadeInAtTheSlot
    /// No serve: the confirmation plays at once. The agent has no slot of its own (it went to the "+N" disc), or no disc
    /// can show on the cursor's display.
    case none
}

/// Decides how a new agent's token arrives.
///
/// - `cursorPoint`: where the blue cursor glyph is.
/// - `slotPoint`: the center of the slot the token will fill, or nil when the agent got no slot.
/// - `slotDisplayCanShowDiscs`: false when the cursor's display has no free space, a hidden menu bar, or a full-screen
///   space, which hides every app window in the strip beside the notch.
func agentTokenServePlan(
    cursorPoint: CGPoint,
    slotPoint: CGPoint?,
    slotDisplayCanShowDiscs: Bool,
    reduceMotionIsOn: Bool
) -> AgentTokenServePlan {
    guard slotDisplayCanShowDiscs, let slotPoint else { return .none }
    if reduceMotionIsOn { return .fadeInAtTheSlot }
    return .fly(agentTokenServePath(from: cursorPoint, to: slotPoint))
}

/// How long the still ring a Reduce Motion serve leaves around the new disc stays before it fades. The move's Reduce Motion
/// form is a fade in at the target that leaves a still ring there (`DS.Move.send.reduceMotionForm`).
let agentTokenServeStillRingSeconds: TimeInterval = 1

/// How wide the still ring is: as wide as the disc's panel allows, and a point less than the panel is tall, so a menu bar
/// only a little taller than the 22 point disc, such as a 24 point bar on a display with no notch, never cuts it off.
func agentTokenStillRingDiameter(panelHeight: CGFloat) -> CGFloat {
    min(AgentTokenMetrics.panelWidth - 2, panelHeight - 1)
}

/// Whether the tether of a flight that has left must end at once. It must when a disc had to wait under that very flight, since
/// that disc slides now and the fading line would end where the disc used to be. Another flight's tether stays.
func agentTokenTetherMustEnd<Flight: AnyObject>(flightWhoseDiscWaited: Flight?, goneFlight: Flight) -> Bool {
    flightWhoseDiscWaited === goneFlight
}

// MARK: - Arc

/// A quadratic bezier arc from the cursor to a slot, shaped like the one the cursor flies when it points at something.
struct AgentTokenServePath: Equatable {
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint

    /// The Send move's half second, which is shorter than the cursor's own flights, since the token only crosses to the
    /// menu bar.
    static var flightSeconds: TimeInterval { DS.Move.send.curve.seconds() }

    /// The point on the arc after `flightProgress` of the flight, from 0 (the cursor) to 1 (the slot). The token eases in
    /// and out with `agentTokenServeEasedProgress`.
    func point(atFlightProgress flightProgress: Double) -> CGPoint {
        let eased = agentTokenServeEasedProgress(flightProgress)
        let oneMinusEased = 1 - eased
        return CGPoint(
            x: oneMinusEased * oneMinusEased * start.x + 2 * oneMinusEased * eased * control.x + eased * eased * end.x,
            y: oneMinusEased * oneMinusEased * start.y + 2 * oneMinusEased * eased * control.y + eased * eased * end.y
        )
    }
}

/// The arc bows away from the straight line, sideways to it, by a fifth of the distance at the control point, at most 80
/// points, so it reads as an arc whichever way the token travels. It bows toward the top of the screen, or to the right
/// when the flight is straight up. It never rises above the higher end, so a cursor near the menu bar does not send the
/// token off the top of the display: a bezier stays inside its control points, and the control point is held at that height.
func agentTokenServePath(from cursorPoint: CGPoint, to slotPoint: CGPoint) -> AgentTokenServePath {
    let straightLineX = slotPoint.x - cursorPoint.x
    let straightLineY = slotPoint.y - cursorPoint.y
    let distance = hypot(straightLineX, straightLineY)
    guard distance > 0 else { return AgentTokenServePath(start: cursorPoint, control: cursorPoint, end: slotPoint) }

    // The two directions sideways to the line point opposite ways. Take the one with the larger y, which is toward the top
    // of the screen, and the right-hand one when the line is vertical and neither is higher.
    let sidewaysX = straightLineX > 0 ? -straightLineY : straightLineY
    let sidewaysY = straightLineX > 0 ? straightLineX : -straightLineX
    let bowDistance = min(distance * 0.2, 80)
    let midpoint = CGPoint(x: (cursorPoint.x + slotPoint.x) / 2, y: (cursorPoint.y + slotPoint.y) / 2)

    let highestEndY = max(cursorPoint.y, slotPoint.y)
    let controlPoint = CGPoint(
        x: midpoint.x + sidewaysX / distance * bowDistance,
        y: min(midpoint.y + sidewaysY / distance * bowDistance, highestEndY)
    )
    return AgentTokenServePath(start: cursorPoint, control: controlPoint, end: slotPoint)
}

/// Smoothstep, `3t² - 2t³`, the same easing the cursor's flight uses: it leaves slowly, moves fastest in the middle, and
/// settles into the slot. Progress outside 0 to 1 is clamped.
func agentTokenServeEasedProgress(_ linearProgress: Double) -> Double {
    DS.Move.send.curve.progress(atSeconds: linearProgress * AgentTokenServePath.flightSeconds)
}

// MARK: - A disc under a flight stays put

/// Whether a disc has to stay where it is for now. A disc that a token is flying to, or that a landed token still covers on
/// the carrier for a moment, does not slide to close a gap until the carried token has left. That token stays at the old
/// slot, so a slide before then shows the token there and in the disc that slides away.
func agentTokenDiscMustWaitForItsFlight<DiscID: Equatable>(_ discID: DiscID, flightLandsOn: DiscID?, lingeringFlightSitsOn: DiscID?) -> Bool {
    discID == flightLandsOn || discID == lingeringFlightSitsOn
}

// MARK: - Where it starts and which display

/// How far the blue cursor glyph sits from the mouse: 35 points right and 25 points below, as `BlueCursorView` places it
/// while it follows the mouse (`+ 35` and `+ 25` in `OverlayWindow.swift`).
private let blueCursorGlyphOffsetFromTheMouse = CGSize(width: 35, height: 25)

/// Where the token starts: the blue cursor glyph, in global AppKit coordinates, from the mouse's.
func agentTokenServeStartPoint(mouseLocation: CGPoint) -> CGPoint {
    // The offset is measured downward, and AppKit's y grows upward.
    CGPoint(
        x: mouseLocation.x + blueCursorGlyphOffsetFromTheMouse.width,
        y: mouseLocation.y - blueCursorGlyphOffsetFromTheMouse.height
    )
}

/// The display the token flies to: the one the mouse is on, which is where the learner is looking. Nil when the mouse is
/// on none of them, which means no serve.
func agentTokenServeDisplayID(containing mouseLocation: CGPoint, displayFrames: [CGDirectDisplayID: CGRect]) -> CGDirectDisplayID? {
    displayFrames.first { _, displayFrame in
        agentTokenServeDisplayFrame(displayFrame, holdsTheMouseAt: mouseLocation)
    }?.key
}

/// Whether a mouse at `mouseLocation` is on the display with `displayFrame`.
///
/// AppKit's y grows upward, so the rows a mouse can reach on a display run from just above its `minY` up to its `maxY`: the
/// top row has y equal to `maxY`, and a bottom row never has y equal to `minY`. That is the reverse of `CGRect.contains`, which
/// would send a mouse in the top row to no display, or, with a display stacked above, to the display above. The left edge
/// belongs to a display and the right edge to the display beside it. The frames of two displays never share a row or a column
/// by this rule, so exactly one display holds a mouse, whatever order the displays are visited in.
func agentTokenServeDisplayFrame(_ displayFrame: CGRect, holdsTheMouseAt mouseLocation: CGPoint) -> Bool {
    displayFrame.minX <= mouseLocation.x && mouseLocation.x < displayFrame.maxX
        && displayFrame.minY < mouseLocation.y && mouseLocation.y <= displayFrame.maxY
}
