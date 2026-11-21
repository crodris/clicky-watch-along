//
//  CursorFollowMotion.swift
//  leanring-buddy
//
//  What every drawn cursor shares: the 24 point box its shapes are drawn in, the motion streaks behind it, and how a
//  cursor that turns toward movement follows the mouse. A school theme's volleyball is shapes in its theme file, drawn
//  by `CustomCursorView` like any other theme's cursor.
//

import SwiftUI

/// Maps the design's 24 point box onto a drawing rect. Every theme's shapes cursor (`SVGPathShape`, `CustomCursorView`)
/// draws in this box.
enum CursorDrawingBox {
    static let sideLength: CGFloat = 24

    static func point(_ boxX: CGFloat, _ boxY: CGFloat, in rect: CGRect) -> CGPoint {
        let scale = min(rect.width, rect.height) / sideLength
        return CGPoint(x: rect.minX + boxX * scale, y: rect.minY + boxY * scale)
    }
}

/// Up to three motion lines below the cursor: the long middle line, then the two short side lines. The overlay turns the
/// cursor to face its direction of travel with "up" as forward, so lines below it trail behind it. They reach past the
/// frame on purpose. The volleyball always draws three. A custom cursor draws `lineCount` of them (1 is the middle line,
/// 2 is the two side lines).
struct CursorFlightStreaks: Shape {
    var lineCount = 3

    func path(in rect: CGRect) -> Path {
        let middleLine = (x: 12.0, startY: 23.5, endY: 34.0)
        let leftLine = (x: 7.5, startY: 22.0, endY: 29.0)
        let rightLine = (x: 16.5, startY: 22.0, endY: 29.0)
        let linesToDraw: [(x: Double, startY: Double, endY: Double)]
        switch lineCount {
        case ...0: linesToDraw = []
        case 1: linesToDraw = [middleLine]
        case 2: linesToDraw = [leftLine, rightLine]
        default: linesToDraw = [middleLine, leftLine, rightLine]
        }
        var path = Path()
        for line in linesToDraw {
            path.move(to: CursorDrawingBox.point(line.x, line.startY, in: rect))
            path.addLine(to: CursorDrawingBox.point(line.x, line.endY, in: rect))
        }
        return path
    }
}

/// How a cursor that turns toward movement, such as a school theme's volleyball, shows the mouse's motion while it follows the mouse: the direction it faces and how
/// strong its streaks are. The overlay advances it once per 16 ms tracking tick with the distance the mouse moved.
struct CursorFollowMotion: Equatable {
    /// The mouse's recent movement per tick, smoothed so one jittery tick does not swing the ball around.
    var smoothedMovementPerTick: CGVector
    /// The same convention as the triangle's rotation: 0 faces up, and the streaks trail below.
    var facingDegrees: Double
    /// 0 hides the streaks and 1 shows them fully.
    var streakStrength: Double

    static let atRest = CursorFollowMotion(smoothedMovementPerTick: .zero, facingDegrees: -35, streakStrength: 0)

    /// Below this smoothed speed, in points per tick (about 180 points a second), the mouse is drifting, so no streaks show
    /// and the ball keeps facing the way it last moved.
    private static let slowestSpeedThatShowsStreaks: CGFloat = 3
    /// How far above that speed the streaks reach full strength.
    private static let speedRangeToFullStreaks: CGFloat = 12
    /// The share of the old movement each tick keeps. Higher fades the streaks more slowly after the mouse stops.
    private static let movementKeptPerTick: CGFloat = 0.8

    func advanced(byMouseMovement mouseMovement: CGVector) -> CursorFollowMotion {
        let keptShare = Self.movementKeptPerTick
        var smoothedMovement = CGVector(
            dx: smoothedMovementPerTick.dx * keptShare + mouseMovement.dx * (1 - keptShare),
            dy: smoothedMovementPerTick.dy * keptShare + mouseMovement.dy * (1 - keptShare)
        )
        var speed = hypot(smoothedMovement.dx, smoothedMovement.dy)
        // Snap a dying movement to zero, so a still mouse settles on one value and stops redrawing the overlay.
        if speed < 0.05 {
            smoothedMovement = .zero
            speed = 0
        }

        var nextFacingDegrees = facingDegrees
        if speed >= Self.slowestSpeedThatShowsStreaks {
            // atan2 gives 0 for rightward movement, and the ball's 0 faces up, hence the 90 degree turn.
            let movementDegrees = atan2(smoothedMovement.dy, smoothedMovement.dx) * 180 / .pi + 90
            // Take the turn of at most 180 degrees from the current facing, so moving straight left, where atan2
            // jumps between +180 and -180, never spins the ball a full turn under the overlay's spring animation.
            var turnDegrees = (movementDegrees - facingDegrees).truncatingRemainder(dividingBy: 360)
            if turnDegrees > 180 { turnDegrees -= 360 }
            if turnDegrees < -180 { turnDegrees += 360 }
            nextFacingDegrees = facingDegrees + turnDegrees
        }
        let nextStreakStrength = Double(min(max((speed - Self.slowestSpeedThatShowsStreaks) / Self.speedRangeToFullStreaks, 0), 1))

        return CursorFollowMotion(
            smoothedMovementPerTick: smoothedMovement,
            facingDegrees: nextFacingDegrees,
            streakStrength: nextStreakStrength
        )
    }
}
