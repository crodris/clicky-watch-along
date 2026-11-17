//
//  VolleyballCursorView.swift
//  leanring-buddy
//
//  The volleyball a school theme draws in place of the blue cursor triangle.
//  The drawing follows a 24 point box, the one the design mocks used, and the
//  view draws at that size, larger than the 16 point triangle, since a 16 point
//  ball was hard to follow while it flew.
//

import SwiftUI

struct VolleyballCursorView: View {
    let volleyballColors: VolleyballCursorColors
    /// The team color the streaks behind a flying ball use, the same color as the glow.
    let flightStreakColor: Color
    /// 0 at rest and 1 at the middle of a flight, so the streaks fade in after takeoff and out before landing.
    let flightStreakOpacity: Double

    // Line widths in points. The seams are thinner than the outline, since full-width seams turn an orange ball brown.
    private let outlineLineWidth: CGFloat = 1.6
    private let seamLineWidth: CGFloat = 1.1
    private let lightRingLineWidth: CGFloat = 0.9
    private let flightStreakLineWidth: CGFloat = 2.0

    var body: some View {
        ZStack {
            VolleyballFlightStreaks()
                .stroke(flightStreakColor, style: StrokeStyle(lineWidth: flightStreakLineWidth, lineCap: .round))
                .opacity(min(max(flightStreakOpacity, 0), 1))
            // A light ring outside the outline keeps the ball's edge visible on a dark video frame.
            VolleyballOutline(radiusInBoxUnits: 11.3)
                .stroke(Color.white.opacity(0.6), lineWidth: lightRingLineWidth)
            VolleyballOutline(radiusInBoxUnits: 10)
                .fill(Color(hex: volleyballColors.fillHex))
            VolleyballSeams()
                .stroke(Color(hex: volleyballColors.seamHex), style: StrokeStyle(lineWidth: seamLineWidth, lineCap: .round))
            VolleyballOutline(radiusInBoxUnits: 10)
                .stroke(Color(hex: volleyballColors.outlineHex), lineWidth: outlineLineWidth)
        }
        .frame(width: VolleyballBox.sideLength, height: VolleyballBox.sideLength)
    }
}

/// Maps the design's 24 point box onto a drawing rect.
private enum VolleyballBox {
    static let sideLength: CGFloat = 24

    static func point(_ boxX: CGFloat, _ boxY: CGFloat, in rect: CGRect) -> CGPoint {
        let scale = min(rect.width, rect.height) / sideLength
        return CGPoint(x: rect.minX + boxX * scale, y: rect.minY + boxY * scale)
    }
}

/// A circle around the box's center, sized in box units: 10 is the ball's edge.
private struct VolleyballOutline: Shape {
    let radiusInBoxUnits: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = VolleyballBox.point(12, 12, in: rect)
        let radius = radiusInBoxUnits * min(rect.width, rect.height) / VolleyballBox.sideLength
        return Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }
}

/// The ball's seams. The design drew them as SVG arcs (the Lucide volleyball icon), and SwiftUI has no
/// SVG arc, so each arc is the single cubic curve that matches it, worked out from the arc's endpoints and radius.
private struct VolleyballSeams: Shape {
    func path(in rect: CGRect) -> Path {
        // Each seam is start, first control point, second control point, end, in box units.
        let seamCurvesInBoxUnits: [[(CGFloat, CGFloat)]] = [
            [(11.10, 7.10), (15.10, 7.07), (18.97, 8.49), (22.00, 11.10)],
            [(12.00, 12.00), (9.92, 14.80), (6.77, 16.61), (3.30, 17.00)],
            [(16.80, 13.60), (14.81, 17.11), (11.61, 19.78), (7.80, 21.10)],
            [(20.70, 17.00), (18.60, 14.22), (15.46, 12.41), (12.00, 12.00)],
            [(12.00, 12.00), (10.70, 8.79), (10.70, 5.21), (12.00, 2.00)],
            [(6.30, 3.80), (5.52, 7.74), (6.19, 11.82), (8.20, 15.30)],
        ]

        var path = Path()
        for seamCurve in seamCurvesInBoxUnits {
            let curvePoints = seamCurve.map { VolleyballBox.point($0.0, $0.1, in: rect) }
            path.move(to: curvePoints[0])
            path.addCurve(to: curvePoints[3], control1: curvePoints[1], control2: curvePoints[2])
        }
        return path
    }
}

/// Three motion lines below the ball. The overlay turns the cursor to face its direction of travel
/// with "up" as forward, so lines below the ball trail behind it. They reach past the frame on purpose.
private struct VolleyballFlightStreaks: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: VolleyballBox.point(12, 23.5, in: rect))
        path.addLine(to: VolleyballBox.point(12, 34, in: rect))
        path.move(to: VolleyballBox.point(7.5, 22, in: rect))
        path.addLine(to: VolleyballBox.point(7.5, 29, in: rect))
        path.move(to: VolleyballBox.point(16.5, 22, in: rect))
        path.addLine(to: VolleyballBox.point(16.5, 29, in: rect))
        return path
    }
}

/// How the volleyball shows the mouse's motion while it follows the mouse: the direction it faces and how
/// strong its streaks are. The overlay advances it once per 16 ms tracking tick with the distance the mouse moved.
struct VolleyballFollowMotion: Equatable {
    /// The mouse's recent movement per tick, smoothed so one jittery tick does not swing the ball around.
    var smoothedMovementPerTick: CGVector
    /// The same convention as the triangle's rotation: 0 faces up, and the streaks trail below.
    var facingDegrees: Double
    /// 0 hides the streaks and 1 shows them fully.
    var streakStrength: Double

    static let atRest = VolleyballFollowMotion(smoothedMovementPerTick: .zero, facingDegrees: -35, streakStrength: 0)

    /// Below this smoothed speed, in points per tick (about 180 points a second), the mouse is drifting, so no streaks show
    /// and the ball keeps facing the way it last moved.
    private static let slowestSpeedThatShowsStreaks: CGFloat = 3
    /// How far above that speed the streaks reach full strength.
    private static let speedRangeToFullStreaks: CGFloat = 12
    /// The share of the old movement each tick keeps. Higher fades the streaks more slowly after the mouse stops.
    private static let movementKeptPerTick: CGFloat = 0.8

    func advanced(byMouseMovement mouseMovement: CGVector) -> VolleyballFollowMotion {
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

        return VolleyballFollowMotion(
            smoothedMovementPerTick: smoothedMovement,
            facingDegrees: nextFacingDegrees,
            streakStrength: nextStreakStrength
        )
    }
}
