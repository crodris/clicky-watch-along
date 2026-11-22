//
//  CursorLoopView.swift
//  leanring-buddy
//
//  Draws the loop around the video or image Clicky is looking at: a 3 point line in the cursor's color over a darker
//  5.5 point under-stroke. Clicky's own cursor draws it: the line is ink left behind the cursor as it moves, so this view
//  draws only the share of the line the cursor has covered, and the overlay moves the real cursor (`BlueCursorView`).
//  The finished line carries a slow shimmer while it shows, since the loop is Clicky's thinking light. Reduce Motion fades
//  the whole line in with no cursor travel and no shimmer.
//
//  It also holds what every loop shares (`CursorLoopLine`, `CursorLoopDrawing`, and the tracer: `CursorLoopTracerPlacement`
//  and `CursorLoopTracerGlyph`), so a loop drawn where there is no overlay cursor, such as the room art panel's, draws the
//  theme's cursor glyph as its tracer.
//

import AppKit
import SwiftUI

/// One loop to draw on one screen, in that screen's overlay coordinates.
struct CursorLoopOnScreen: Equatable {
    /// The rectangle the line runs along, already 4 points outside the media.
    let lineRect: CGRect
    let seed: UInt64
    /// `ProcessInfo.systemUptime` when the loop began, which also names the loop, and when its shimmer slows, if a build
    /// runs under it.
    let beganAt: TimeInterval
    let shimmerSlowsAt: TimeInterval?
    let isFadingOut: Bool

    var outline: Path { CursorLoopOutline.path(along: lineRect, seed: seed) }
}

/// How much of a loop's line shows, which the cursor that draws it decides.
enum CursorLoopInk: Equatable {
    /// The cursor is on its way to the line's start, so nothing is drawn yet.
    case waitingForTheCursor
    /// The cursor reached the line's start at `beganAt` (`ProcessInfo.systemUptime`) and traces it. The share drawn is
    /// `CursorLoopTimeline.tracedShare`, the same rule that moves the cursor, so the ink ends under it.
    case tracing(beganAt: TimeInterval)
    /// The whole line, since `since`, when its shimmer starts. The cursor finished, or something landed its draw at once.
    case whole(since: TimeInterval)
}

/// How a loop that appears gets drawn.
enum CursorLoopDrawWay: Equatable {
    /// The buddy flies to the line's start, traces it, and flies back.
    case theCursorTracesIt
    /// The whole line fades in where it is, with no cursor travel.
    case itFadesInWhole
}

/// Reduce Motion fades the line in with no cursor travel. So does a buddy that is busy pointing, scrubbing, held by an
/// instant replay, or typing the first-launch welcome, since the loop never takes the cursor from those.
func cursorLoopDrawWay(reduceMotionIsOn: Bool, theBuddyIsFree: Bool) -> CursorLoopDrawWay {
    reduceMotionIsOn || !theBuddyIsFree ? .itFadesInWhole : .theCursorTracesIt
}

/// One screen's buddy drawing one loop: which loop, how much of its line shows, and whether the buddy is still away on it,
/// from its flight to the line's start until it is back at the mouse or a pointing or a scrub took it. The overlay moves the
/// cursor, and each step here is pure, so tests walk a draw through its steps and its land-at-once paths.
struct BuddyLoopDraw: Equatable {
    let loopBeganAt: TimeInterval
    private(set) var ink: CursorLoopInk
    private(set) var holdsTheBuddy: Bool

    /// A loop the cursor traces starts with nothing drawn and the buddy on its way. One that fades in whole shows whole from
    /// the loop's first moment, and the buddy stays where it is.
    init(loopBeganAt: TimeInterval, way: CursorLoopDrawWay) {
        self.loopBeganAt = loopBeganAt
        switch way {
        case .theCursorTracesIt:
            ink = .waitingForTheCursor
            holdsTheBuddy = true
        case .itFadesInWhole:
            ink = .whole(since: loopBeganAt)
            holdsTheBuddy = false
        }
    }

    /// The buddy landed on the line's start, so the ink starts behind it.
    mutating func theCursorReachedTheStart(at now: TimeInterval) {
        guard ink == .waitingForTheCursor else { return }
        ink = .tracing(beganAt: now)
    }

    /// The trace ran its course, so the whole line shows and its shimmer starts.
    mutating func theTraceFinished(at now: TimeInterval) {
        guard case .tracing = ink else { return }
        ink = .whole(since: now)
    }

    /// A push-to-talk press, a pointing, a scrub, or the loop ending lands the draw: the whole line shows at once. A line
    /// already whole keeps its shimmer's clock.
    mutating func landAtOnce(at now: TimeInterval) {
        ink.landAtOnce(at: now)
    }

    /// The buddy is back at the mouse, or another job took it.
    mutating func theBuddyLeft() {
        holdsTheBuddy = false
    }

    /// The ink to draw for `loop`. A loop the buddy has not picked up yet, which is the one frame before the overlay hears of
    /// it, draws what its way would start with, so a line that fades in starts invisible and one the cursor traces starts
    /// empty. A loop that is fading out shows whole.
    static func ink(for loop: CursorLoopOnScreen, draw: BuddyLoopDraw?, wayForANewLoop: CursorLoopDrawWay) -> CursorLoopInk {
        let drawOfThisLoop = draw.flatMap { $0.loopBeganAt == loop.beganAt ? $0 : nil }
        var ink = drawOfThisLoop?.ink ?? BuddyLoopDraw(loopBeganAt: loop.beganAt, way: wayForANewLoop).ink
        if loop.isFadingOut {
            ink.landAtOnce(at: loop.beganAt)
        }
        return ink
    }
}

struct CursorLoopView: View {
    let loop: CursorLoopOnScreen
    let ink: CursorLoopInk
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A line that first shows whole fades in, so it starts invisible and turns visible when it appears.
    @State private var hasAppeared = false

    var body: some View {
        let line = CursorLoopLine(outline: loop.outline)
        Group {
            if reduceMotion {
                Canvas { context, _ in CursorLoopDrawing.drawTheInk(of: line, upToShare: 1, color: color, in: &context) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    // The moment is worked out here, outside the Canvas, because SwiftUI redraws a Canvas only when a value
                    // its closure captured changes, and the clock is not one.
                    let now = ProcessInfo.processInfo.systemUptime
                    let inkedShare = Self.inkedShare(of: ink, at: now)
                    let shimmerLapShare = Self.shimmerLapShare(of: ink, shimmerSlowsAt: loop.shimmerSlowsAt, at: now)
                    Canvas { context, _ in
                        CursorLoopDrawing.drawTheInk(of: line, upToShare: inkedShare, color: color, in: &context)
                        if let shimmerLapShare {
                            CursorLoopDrawing.drawTheShimmer(on: line, atLapShare: shimmerLapShare, in: &context)
                        }
                    }
                }
            }
        }
        .opacity(loop.isFadingOut || (inkIsWhole && !hasAppeared) ? 0 : 1)
        .animation(.easeOut(duration: CursorLoopState.fadeOutSeconds), value: loop.isFadingOut)
        .animation(.easeIn(duration: 0.3), value: hasAppeared)
        .allowsHitTesting(false)
        .onAppear { hasAppeared = true }
    }

    private var inkIsWhole: Bool {
        if reduceMotion { return true }
        if case .whole = ink { return true }
        return false
    }

    static func inkedShare(of ink: CursorLoopInk, at now: TimeInterval) -> Double {
        switch ink {
        case .waitingForTheCursor: return 0
        case .tracing(let beganAt): return CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: now - beganAt)
        case .whole: return 1
        }
    }

    /// The shimmer laps the finished line from the moment it is whole, and slows when a build runs under the loop. Nil until
    /// the line is whole.
    static func shimmerLapShare(of ink: CursorLoopInk, shimmerSlowsAt: TimeInterval?, at now: TimeInterval) -> Double? {
        guard case .whole(let since) = ink else { return nil }
        return CursorLoopTimeline.lapShare(
            secondsSinceTheLapsBegan: now - since,
            secondsWhenTheLapsSlow: shimmerSlowsAt.map { $0 - since }
        )
    }
}

// MARK: - The line as lengths

/// A loop's line cut into short straight pieces with the length up to each point, so the tracer's place and heading at any
/// share of the line cost a search instead of a path trim, and the ink ends exactly under the tracer. Every share is a share
/// of the line's length, so a glyph moved by share goes at an even speed along any closed path and turns with it: the
/// rounded rectangle of `CursorLoopOutline` is one caller, and a shirt's contour or a furniture footprint, given as a closed
/// path or as its corners in order (`init(closedThrough:)`), are others.
///
/// A loop line ends with a short overshoot past its start (`CursorLoopOutline`). A lap goes around the closed part only,
/// which ends where the overshoot passes nearest the start, and the first lap starts where the overshoot ended, so a glyph
/// that keeps lapping never jumps back to the start.
struct CursorLoopLine {
    static let piecesPerCurve = 12

    let points: [CGPoint]
    /// The length of the line from its start to each point.
    private let lengthToEachPoint: [CGFloat]
    /// The length of the closed part a lap goes around.
    let lapLength: CGFloat
    /// Where along the closed part the first lap starts.
    let firstLapStartLength: CGFloat

    var totalLength: CGFloat { lengthToEachPoint.last ?? 0 }

    init(outline: Path) {
        var flattenedPoints: [CGPoint] = []
        var subpathStart = CGPoint.zero
        var currentPoint = CGPoint.zero
        outline.forEach { element in
            switch element {
            case .move(let to):
                // The loops are drawn as one subpath, so a later move is joined to the line rather than skipped over.
                flattenedPoints.append(to)
                subpathStart = to
                currentPoint = to
            case .line(let to):
                flattenedPoints.append(to)
                currentPoint = to
            case .quadCurve(let to, let control):
                for piece in 1...Self.piecesPerCurve {
                    let share = CGFloat(piece) / CGFloat(Self.piecesPerCurve)
                    let remaining = 1 - share
                    flattenedPoints.append(CGPoint(
                        x: remaining * remaining * currentPoint.x + 2 * remaining * share * control.x + share * share * to.x,
                        y: remaining * remaining * currentPoint.y + 2 * remaining * share * control.y + share * share * to.y
                    ))
                }
                currentPoint = to
            case .curve(let to, let firstControl, let secondControl):
                for piece in 1...Self.piecesPerCurve {
                    let share = CGFloat(piece) / CGFloat(Self.piecesPerCurve)
                    let remaining = 1 - share
                    let startWeight = remaining * remaining * remaining
                    let firstWeight = 3 * remaining * remaining * share
                    let secondWeight = 3 * remaining * share * share
                    let endWeight = share * share * share
                    flattenedPoints.append(CGPoint(
                        x: startWeight * currentPoint.x + firstWeight * firstControl.x + secondWeight * secondControl.x + endWeight * to.x,
                        y: startWeight * currentPoint.y + firstWeight * firstControl.y + secondWeight * secondControl.y + endWeight * to.y
                    ))
                }
                currentPoint = to
            case .closeSubpath:
                flattenedPoints.append(subpathStart)
                currentPoint = subpathStart
            }
        }
        points = flattenedPoints

        var lengths: [CGFloat] = []
        lengths.reserveCapacity(flattenedPoints.count)
        var runningLength: CGFloat = 0
        for index in flattenedPoints.indices {
            if index > 0 {
                runningLength += hypot(flattenedPoints[index].x - flattenedPoints[index - 1].x, flattenedPoints[index].y - flattenedPoints[index - 1].y)
            }
            lengths.append(runningLength)
        }
        lengthToEachPoint = lengths

        // The closed part ends where the second half of the line passes nearest its start, and the first lap starts at the
        // point of the closed part nearest the line's end.
        guard let startPoint = flattenedPoints.first, let endPoint = flattenedPoints.last, runningLength > 0 else {
            lapLength = 0
            firstLapStartLength = 0
            return
        }
        let closingLength = Self.nearestLength(to: startPoint, points: flattenedPoints, lengths: lengths, fromLength: runningLength / 2, toLength: runningLength)
        lapLength = closingLength > 0 ? closingLength : runningLength
        let firstLapStart = Self.nearestLength(to: endPoint, points: flattenedPoints, lengths: lengths, fromLength: 0, toLength: lapLength)
        firstLapStartLength = firstLapStart >= lapLength ? 0 : firstLapStart
    }

    /// A closed line through `points` in order, back to the first one. Fewer than two points make an empty line.
    init(closedThrough points: [CGPoint]) {
        var closedPath = Path()
        if let firstPoint = points.first, points.count > 1 {
            closedPath.move(to: firstPoint)
            for point in points.dropFirst() { closedPath.addLine(to: point) }
            closedPath.closeSubpath()
        }
        self.init(outline: closedPath)
    }

    /// The point `length` along the line, clamped to its ends.
    func point(atLength length: CGFloat) -> CGPoint {
        guard let firstPoint = points.first else { return .zero }
        guard totalLength > 0 else { return firstPoint }
        let clampedLength = min(max(length, 0), totalLength)
        let segmentEndIndex = indexOfTheSegmentEnd(containingLength: clampedLength)
        let segmentStart = points[segmentEndIndex - 1]
        let segmentEnd = points[segmentEndIndex]
        let segmentLength = lengthToEachPoint[segmentEndIndex] - lengthToEachPoint[segmentEndIndex - 1]
        let shareOfTheSegment = segmentLength > 0 ? (clampedLength - lengthToEachPoint[segmentEndIndex - 1]) / segmentLength : 0
        return CGPoint(
            x: segmentStart.x + (segmentEnd.x - segmentStart.x) * shareOfTheSegment,
            y: segmentStart.y + (segmentEnd.y - segmentStart.y) * shareOfTheSegment
        )
    }

    func point(atShare share: Double) -> CGPoint {
        point(atLength: totalLength * CGFloat(share))
    }

    /// The direction the line runs at `share`, in the cursor's rotation convention: 0 is straight up, and it turns clockwise,
    /// so 90 runs right. It is read across 2 points on each side, so a corner piece never flips it.
    func headingDegrees(atShare share: Double) -> Double {
        let length = totalLength * CGFloat(share)
        let lookDistance: CGFloat = 2
        let behind = point(atLength: max(0, min(length - lookDistance, totalLength - 2 * lookDistance)))
        let ahead = point(atLength: min(totalLength, max(length + lookDistance, 2 * lookDistance)))
        return atan2(Double(ahead.y - behind.y), Double(ahead.x - behind.x)) * 180 / .pi + 90
    }

    /// The share of the whole line a lap is at, so `point(atShare:)` and `headingDegrees(atShare:)` place a lapping glyph.
    func shareOfTheLine(atLapShare lapShare: Double) -> Double {
        guard totalLength > 0, lapLength > 0 else { return 0 }
        let lapLengthFromTheStart = (firstLapStartLength + lapLength * CGFloat(lapShare)).truncatingRemainder(dividingBy: lapLength)
        return Double(lapLengthFromTheStart / totalLength)
    }

    /// The line from its start to `share`, ending at exactly the tracer's point.
    func inkPath(upToShare share: Double) -> Path {
        path(fromLength: 0, toLength: totalLength * CGFloat(min(max(share, 0), 1)))
    }

    /// The part of the line between two lengths, `fromLength` before `toLength`.
    func path(fromLength: CGFloat, toLength: CGFloat) -> Path {
        var path = Path()
        guard points.count > 1, toLength > fromLength else { return path }
        path.move(to: point(atLength: fromLength))
        for index in points.indices where lengthToEachPoint[index] > fromLength && lengthToEachPoint[index] < toLength {
            path.addLine(to: points[index])
        }
        path.addLine(to: point(atLength: toLength))
        return path
    }

    /// The index of the point that ends the piece holding `length`, from 1 on.
    private func indexOfTheSegmentEnd(containingLength length: CGFloat) -> Int {
        var lowIndex = 1
        var highIndex = lengthToEachPoint.count - 1
        while lowIndex < highIndex {
            let middleIndex = (lowIndex + highIndex) / 2
            if lengthToEachPoint[middleIndex] < length {
                lowIndex = middleIndex + 1
            } else {
                highIndex = middleIndex
            }
        }
        return lowIndex
    }

    /// The length along the line, between two lengths, of the point nearest `target`, read on every piece and not only its ends.
    private static func nearestLength(to target: CGPoint, points: [CGPoint], lengths: [CGFloat], fromLength: CGFloat, toLength: CGFloat) -> CGFloat {
        var nearestDistance = CGFloat.infinity
        var nearestLength = fromLength
        for index in points.indices.dropFirst() where lengths[index] >= fromLength && lengths[index - 1] <= toLength {
            let segmentStart = points[index - 1]
            let segmentEnd = points[index]
            let segmentVector = CGPoint(x: segmentEnd.x - segmentStart.x, y: segmentEnd.y - segmentStart.y)
            let segmentLengthSquared = segmentVector.x * segmentVector.x + segmentVector.y * segmentVector.y
            var shareOfTheSegment: CGFloat = 0
            if segmentLengthSquared > 0 {
                shareOfTheSegment = ((target.x - segmentStart.x) * segmentVector.x + (target.y - segmentStart.y) * segmentVector.y) / segmentLengthSquared
            }
            let segmentLength = lengths[index] - lengths[index - 1]
            let lowestShare = segmentLength > 0 ? max(0, (fromLength - lengths[index - 1]) / segmentLength) : 0
            let highestShare = segmentLength > 0 ? min(1, (toLength - lengths[index - 1]) / segmentLength) : 1
            shareOfTheSegment = min(max(shareOfTheSegment, lowestShare), highestShare)
            let nearestPoint = CGPoint(x: segmentStart.x + segmentVector.x * shareOfTheSegment, y: segmentStart.y + segmentVector.y * shareOfTheSegment)
            let distance = hypot(nearestPoint.x - target.x, nearestPoint.y - target.y)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestLength = lengths[index - 1] + segmentLength * shareOfTheSegment
            }
        }
        return nearestLength
    }
}

// MARK: - The tracer

/// The theme's cursor and its picture, which a tracer draws where no overlay cursor is.
struct CursorLoopTracerLook {
    let theme: ClickyTheme
    let picture: NSImage?
}

/// Where the cursor glyph sits while it traces a line, and which way it turns. The ink comes out of the triangle's tip, which
/// keeps its pointer angle. A cursor that turns toward movement, such as a school's volleyball, faces along the line with the
/// ink at its center, so the line trails out from under it, and one that stays upright, such as a star or a picture, does too
/// without turning.
struct CursorLoopTracerPlacement: Equatable {
    /// The triangle's resting angle, which the overlay uses too.
    static let pointerAngleDegrees: Double = -35
    /// The triangle's tip sits this far from its center: the top vertex of `Triangle` in a 16 point frame.
    static let triangleTipDistanceFromItsCenter: CGFloat = CustomCursorView.triangleSideLength / sqrt(3)

    /// The point on the line the ink has reached.
    let inkPoint: CGPoint
    let glyphCenter: CGPoint
    /// The glyph's turn, in the cursor's rotation convention.
    let rotationDegrees: Double
    /// The way the line runs here, which a turned glyph's streaks trail behind.
    let headingDegrees: Double

    init(inkPoint: CGPoint, headingDegrees: Double, cursorFacing: CursorFacing) {
        self.inkPoint = inkPoint
        self.headingDegrees = headingDegrees
        switch cursorFacing {
        case .pointerAngle:
            let pointerAngleRadians = Self.pointerAngleDegrees * .pi / 180
            let tipDistance = Double(Self.triangleTipDistanceFromItsCenter)
            // The tip is the top vertex turned by the pointer angle, so the center sits that far back from the ink.
            glyphCenter = CGPoint(
                x: inkPoint.x - CGFloat(tipDistance * sin(pointerAngleRadians)),
                y: inkPoint.y + CGFloat(tipDistance * cos(pointerAngleRadians))
            )
            rotationDegrees = Self.pointerAngleDegrees
        case .followsMouseMovement:
            glyphCenter = inkPoint
            rotationDegrees = headingDegrees
        case .upright:
            glyphCenter = inkPoint
            rotationDegrees = 0
        }
    }

    /// The tracer `share` of the way along `line`.
    init(on line: CursorLoopLine, atShare share: Double, cursorFacing: CursorFacing) {
        self.init(inkPoint: line.point(atShare: share), headingDegrees: line.headingDegrees(atShare: share), cursorFacing: cursorFacing)
    }
}

/// The theme's cursor glyph drawn as a loop's tracer, with the overlay cursor's glow and contact shadow, at the size the
/// overlay draws it. Callers put it over their own line, at `placement`.
struct CursorLoopTracerGlyph: View {
    let look: CursorLoopTracerLook
    let placement: CursorLoopTracerPlacement

    var body: some View {
        CursorBodyLanguageView(
            glyph: CustomCursorView(
                customTheme: look.theme,
                picture: look.picture,
                streakOpacity: 0,
                voiceState: .idle,
                audioPowerLevel: 0
            )
            .rotationEffect(.degrees(placement.rotationDegrees)),
            glowColor: look.theme.cursorColor,
            flightSpeedShare: 0,
            flightDirectionDegrees: 0,
            playingEmote: nil,
            landedAt: nil
        )
        .position(placement.glyphCenter)
        .allowsHitTesting(false)
    }
}

// MARK: - Drawing

/// How a loop's line is drawn, shared by the cursor loop, the room art panel's loop, and the agents' sparks, so they look
/// the same: a 3 point line in the color over a darker 5.5 point under-stroke.
enum CursorLoopDrawing {
    private static let underStrokeColor = Color.black.opacity(0.55)
    private static let underStrokeWidthInPoints: CGFloat = 5.5
    private static let lineWidthInPoints: CGFloat = 3
    /// The shimmer is a soft white band over the line, brightest at its head, a sixth of the lap long.
    static let shimmerShareOfTheLap: CGFloat = 1.0 / 6
    static let shimmerPeakOpacity: Double = 0.5
    private static let shimmerPieces = 10

    /// The line from its start to `share`, which is where a tracer is.
    static func drawTheInk(of line: CursorLoopLine, upToShare share: Double, color: Color, in context: inout GraphicsContext) {
        guard share > 0 else { return }
        stroke(line.inkPath(upToShare: share), color: color, in: &context)
    }

    /// A quiet band of light lapping the finished line, so it reads as working while Clicky thinks, with no spark on it.
    static func drawTheShimmer(on line: CursorLoopLine, atLapShare lapShare: Double, in context: inout GraphicsContext) {
        guard line.lapLength > 0 else { return }
        let headLength = CGFloat(line.shareOfTheLine(atLapShare: lapShare)) * line.totalLength
        let bandLength = line.lapLength * shimmerShareOfTheLap
        let pieceLength = bandLength / CGFloat(shimmerPieces)
        for piece in 0..<shimmerPieces {
            // Each piece is brighter toward the head, so the band fades out behind it.
            let pieceEnd = headLength - CGFloat(piece) * pieceLength
            let pieceStart = pieceEnd - pieceLength
            let opacity = shimmerPeakOpacity * pow(1 - Double(piece) / Double(shimmerPieces), 1.5)
            for (start, end) in piecesInsideTheLap(from: pieceStart, to: pieceEnd, lapLength: line.lapLength) {
                context.stroke(
                    line.path(fromLength: start, toLength: end),
                    with: .color(.white.opacity(opacity)),
                    style: StrokeStyle(lineWidth: lineWidthInPoints, lineCap: .butt, lineJoin: .round)
                )
            }
        }
    }

    /// A piece of the band that runs back past the lap's start continues from the lap's end.
    private static func piecesInsideTheLap(from start: CGFloat, to end: CGFloat, lapLength: CGFloat) -> [(CGFloat, CGFloat)] {
        if start >= 0 { return [(start, end)] }
        if end <= 0 { return [(start + lapLength, end + lapLength)] }
        return [(start + lapLength, lapLength), (0, end)]
    }

    static func drawTheLine(_ outline: Path, share: Double, color: Color, in context: inout GraphicsContext) {
        guard share > 0 else { return }
        stroke(share >= 1 ? outline : outline.trimmedPath(from: 0, to: share), color: color, in: &context)
    }

    private static func stroke(_ drawnPart: Path, color: Color, in context: inout GraphicsContext) {
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

extension CursorLoopInk {
    /// The whole line from `now`, unless it already shows whole.
    mutating func landAtOnce(at now: TimeInterval) {
        if case .whole = self { return }
        self = .whole(since: now)
    }
}
