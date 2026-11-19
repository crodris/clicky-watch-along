//
//  CursorLoopState.swift
//  leanring-buddy
//
//  The pure part of the loop Clicky draws around the video or image it is looking at: what decides
//  whether a request draws a loop and when it clears, the outline of the loop, and the timing of the
//  spark that draws it. Nothing here reads Chrome, the clock, or the screen, so tests drive it with
//  made-up times and rects. `CursorLoopController` does the reading, and `CursorLoopView` the drawing.
//

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - The media the loop goes around

/// The largest video or image in Chrome's front tab as Clicky read it, and which tab it was in.
/// The loop clears when a later read of the front tab differs from this one.
struct MediaOnTheFrontTab: Equatable {
    let screenRect: ScreenRectInChromeCoordinates
    let windowID: Int
    let tabID: Int
    let tabURL: String

    /// Page layout can move an element by a point or two without anything the learner would call a change,
    /// such as a scrollbar appearing, so a rect within this many points on every side counts as the same.
    static let rectToleranceInPoints = 2.0

    func isTheSameMediaInTheSameTab(as laterRead: MediaOnTheFrontTab) -> Bool {
        windowID == laterRead.windowID
            && tabID == laterRead.tabID
            && tabURL == laterRead.tabURL
            && abs(screenRect.rectX - laterRead.screenRect.rectX) <= Self.rectToleranceInPoints
            && abs(screenRect.rectY - laterRead.screenRect.rectY) <= Self.rectToleranceInPoints
            && abs(screenRect.rectWidth - laterRead.screenRect.rectWidth) <= Self.rectToleranceInPoints
            && abs(screenRect.rectHeight - laterRead.screenRect.rectHeight) <= Self.rectToleranceInPoints
    }
}

/// A loop around a whole screen frames nothing, so media that covers nearly all of a screen gets none.
/// A video letterboxed in full screen is smaller than that, and its loop sits just inside the screen edge.
func mediaFillsTheWholeScreen(_ mediaRect: ScreenRectInChromeCoordinates, screenFrameInChromeCoordinates screenFrame: CGRect) -> Bool {
    let shareOfTheScreenTheMediaMustCoverToCountAsTheWholeScreen: CGFloat = 0.95
    let mediaFrame = CGRect(x: mediaRect.rectX, y: mediaRect.rectY, width: mediaRect.rectWidth, height: mediaRect.rectHeight)
    let overlap = mediaFrame.intersection(screenFrame)
    guard !overlap.isNull, screenFrame.width > 0, screenFrame.height > 0 else { return false }
    return (overlap.width * overlap.height) / (screenFrame.width * screenFrame.height) >= shareOfTheScreenTheMediaMustCoverToCountAsTheWholeScreen
}

// MARK: - When a request draws a loop and when it clears

/// Why a loop ends early. Cancel and failure both show up as Clicky going back to idle, so one reason covers them.
enum CursorLoopEndReason: CaseIterable, Equatable {
    /// Clicky went back to idle: the learner cancelled, the request failed, or the answer is about to be pointed at.
    case thinkingStopped
    case newPushToTalk
    case scrolled
    /// The front tab's window, tab, URL, or media rect differs from the one the loop was drawn around.
    case tabOrMediaChanged
    /// The front app is no longer Chrome.
    case appSwitched
    /// Clicky's answer started to play, so the bubble takes over from the loop.
    case speechStarted
    /// A scene or pop-out began to show, so it rises from the line Clicky drew.
    case aSceneStartedToShow
}

/// Whether Clicky's voice state ends a loop that is showing. Going idle covers a cancel and a failure, and an
/// answer's speech ends the loop too, since the response bubble takes over. A status line speaking, such as
/// "Sure, let me build that for you", does not, because the loop stays up through the build.
func cursorLoopEndReason(forVoiceState voiceState: CompanionVoiceState, aStatusLabelIsShowing: Bool) -> CursorLoopEndReason? {
    switch voiceState {
    case .idle: return .thinkingStopped
    case .listening: return .newPushToTalk
    case .processing: return nil
    case .responding: return aStatusLabelIsShowing ? nil : .speechStarted
    }
}

/// What one push-to-talk turn has done about a loop. Clicky reads the front tab's media rect when the
/// shortcut is released, beside the router call. The loop draws only when the request then becomes a look at
/// that media and the rect is in hand within 300 ms of that hand-off. A turn that only runs tools never
/// hands off, so it never draws one.
struct CursorLoopState: Equatable {
    /// How long after the hand-off the rect may still arrive and draw the loop.
    static let secondsTheRectMayArriveAfterTheHandOff: TimeInterval = 0.3
    /// How long after a loop starts to fade it is gone, which the view's fade-out matches.
    static let fadeOutSeconds: TimeInterval = 0.35

    enum Turn: Equatable {
        case notWaitingForALoop
        /// The shortcut was released and the rect read is running. `handedOffAt` is set when the request became a
        /// look at the media before the rect came back.
        case readingTheRect(handedOffAt: TimeInterval?)
        case rectIsInHand(MediaOnTheFrontTab)
    }

    enum Loop: Equatable {
        case hidden
        /// `sparkSlowsAt` is set once a scene build runs under the loop.
        case showing(MediaOnTheFrontTab, since: TimeInterval, sparkSlowsAt: TimeInterval?)
        /// Keeps the timing the loop had, so its spark carries on while the line fades.
        case fadingOut(MediaOnTheFrontTab, since: TimeInterval, sparkSlowsAt: TimeInterval?)
    }

    private(set) var turn = Turn.notWaitingForALoop
    private(set) var loop = Loop.hidden

    var loopIsShowing: Bool {
        if case .showing = loop { return true }
        return false
    }

    /// The loop to draw, whether it is showing or fading out.
    var loopOnTheMedia: (media: MediaOnTheFrontTab, since: TimeInterval, sparkSlowsAt: TimeInterval?, isFadingOut: Bool)? {
        switch loop {
        case .hidden:
            return nil
        case .showing(let media, let since, let sparkSlowsAt):
            return (media, since, sparkSlowsAt, false)
        case .fadingOut(let media, let since, let sparkSlowsAt):
            return (media, since, sparkSlowsAt, true)
        }
    }

    /// The media of a loop that is showing, which the poll compares each front tab read to.
    var mediaTheLoopIsAround: MediaOnTheFrontTab? {
        if case .showing(let media, _, _) = loop { return media }
        return nil
    }

    /// A press starts a new request, so a loop from the last one is out of date, and so is any rect read for it.
    mutating func pushToTalkWasPressed() {
        end(because: .newPushToTalk)
    }

    /// The rect read starts here. It stays unused unless the request becomes a look at the media.
    mutating func pushToTalkWasReleased() {
        turn = .readingTheRect(handedOffAt: nil)
    }

    /// The read finished. Nil means Chrome has no media in front worth framing, or the read failed.
    mutating func mediaRectArrived(_ media: MediaOnTheFrontTab?, at now: TimeInterval) {
        guard case .readingTheRect(let handedOffAt) = turn else { return }
        guard let media else {
            turn = .notWaitingForALoop
            return
        }
        guard let handedOffAt else {
            turn = .rectIsInHand(media)
            return
        }
        // The request already became a look at the media, so this is the last chance to draw the loop for it.
        turn = .notWaitingForALoop
        if now - handedOffAt <= Self.secondsTheRectMayArriveAfterTheHandOff {
            loop = .showing(media, since: now, sparkSlowsAt: nil)
        }
    }

    /// The voice command router handed off to `answer_with_screen`, `build_new_scene`, or `pop_out`, or the keyword
    /// path started a scene or a pop-out. Only the first hand-off of a turn counts.
    mutating func requestBecameALookAtTheMedia(at now: TimeInterval) {
        switch turn {
        case .notWaitingForALoop:
            return
        case .readingTheRect(let handedOffAt):
            guard handedOffAt == nil else { return }
            turn = .readingTheRect(handedOffAt: now)
        case .rectIsInHand(let media):
            turn = .notWaitingForALoop
            loop = .showing(media, since: now, sparkSlowsAt: nil)
        }
    }

    /// A status line such as "Building your 3D scene" started under a loop. After the first 3 seconds of the loop
    /// the spark slows, since a build takes a while and a fast spark would look like a hang.
    mutating func aStatusLabelStartedShowing(at now: TimeInterval) {
        guard case .showing(let media, let since, let sparkSlowsAt) = loop, sparkSlowsAt == nil else { return }
        loop = .showing(media, since: since, sparkSlowsAt: max(now, since + CursorLoopTimeline.secondsBeforeTheSparkSlowsDuringABuild))
    }

    /// Any of these ends the turn too, so a rect read for it can no longer draw a loop.
    mutating func end(because reason: CursorLoopEndReason) {
        turn = .notWaitingForALoop
        if case .showing(let media, let since, let sparkSlowsAt) = loop {
            loop = .fadingOut(media, since: since, sparkSlowsAt: sparkSlowsAt)
        }
    }

    /// The fade is over, so the loop leaves the screen.
    mutating func fadeOutFinished() {
        if case .fadingOut = loop {
            loop = .hidden
        }
    }
}

// MARK: - The loop's outline

/// One closed, even line around the media rect, 4 points outside it, with rounded corners, about a point of
/// wobble that depends only on the rect, and a short overshoot where it closes. It starts on the top edge and
/// runs clockwise, so the overshoot ends a little past the start, drifting inside the line.
enum CursorLoopOutline {
    static let gapFromTheMediaInPoints: CGFloat = 4
    static let cornerRadiusInPoints: CGFloat = 13
    static let wobbleInPoints: CGFloat = 1
    /// Where along the top edge the line starts and where its overshoot ends, from the outline's left edge.
    static let startOffsetFromTheLeftEdgeInPoints: CGFloat = 30
    static let overshootEndOffsetFromTheLeftEdgeInPoints: CGFloat = 58
    /// How far inside the top edge the overshoot ends. It stays under the 4 point gap, so it never reaches the media.
    static let overshootDriftInsideInPoints: CGFloat = 2.8
    /// A loop never runs closer than this to a screen edge, so a letterboxed full screen video keeps its whole line.
    static let marginFromTheScreenEdgeInPoints: CGFloat = 3

    /// The rectangle the line runs along: the media outset by the gap, then pulled inside the screen if that
    /// pushed it past an edge.
    static func rectTheLineRunsAlong(around mediaRect: CGRect, insideScreenBounds screenBounds: CGRect) -> CGRect {
        let outsetRect = mediaRect.insetBy(dx: -gapFromTheMediaInPoints, dy: -gapFromTheMediaInPoints)
        let allowedBounds = screenBounds.insetBy(dx: marginFromTheScreenEdgeInPoints, dy: marginFromTheScreenEdgeInPoints)
        let clampedRect = outsetRect.intersection(allowedBounds)
        return clampedRect.isNull ? outsetRect : clampedRect
    }

    /// The same wobble for the same rect, so a loop never shimmers when it is rebuilt.
    static func seed(for mediaRect: CGRect) -> UInt64 {
        var mixedBits: UInt64 = 0x9E37_79B9_7F4A_7C15
        for value in [mediaRect.minX, mediaRect.minY, mediaRect.width, mediaRect.height] {
            mixedBits ^= UInt64(bitPattern: Int64(value.rounded()))
            mixedBits = mixedBits &* 0xBF58_476D_1CE4_E5B9
            mixedBits ^= mixedBits >> 31
        }
        return mixedBits
    }

    /// The line's path in the same coordinates as `lineRect`, which is the rectangle the line runs along.
    static func path(along lineRect: CGRect, seed: UInt64) -> Path {
        var wobbleGenerator = SeededWobble(state: seed)
        func wobble() -> CGFloat { wobbleGenerator.nextOffset(withinPoints: wobbleInPoints) }

        let cornerRadius = min(cornerRadiusInPoints, lineRect.width / 4, lineRect.height / 4)
        let left = lineRect.minX
        let right = lineRect.maxX
        let top = lineRect.minY
        let bottom = lineRect.maxY
        let startX = left + startOffsetFromTheLeftEdgeInPoints

        /// Two control points a third and two thirds of the way along a straight edge, each pushed off it by the wobble.
        func edgeControlPoints(from start: CGPoint, to end: CGPoint) -> (CGPoint, CGPoint) {
            (
                CGPoint(x: start.x + (end.x - start.x) / 3 + wobble() / 2, y: start.y + (end.y - start.y) / 3 + wobble()),
                CGPoint(x: start.x + (end.x - start.x) * 2 / 3 + wobble() / 2, y: start.y + (end.y - start.y) * 2 / 3 + wobble())
            )
        }

        var path = Path()
        let start = CGPoint(x: startX, y: top + wobble())
        path.move(to: start)

        // Top edge, left to right.
        let topEdgeEnd = CGPoint(x: right - cornerRadius, y: top + wobble())
        let topControls = edgeControlPoints(from: start, to: topEdgeEnd)
        path.addCurve(to: topEdgeEnd, control1: topControls.0, control2: topControls.1)

        // Top right corner, then the right edge down.
        let rightEdgeStart = CGPoint(x: right + wobble(), y: top + cornerRadius)
        path.addQuadCurve(to: rightEdgeStart, control: CGPoint(x: right + wobble(), y: top + wobble()))
        let rightEdgeEnd = CGPoint(x: right + wobble(), y: bottom - cornerRadius)
        let rightControls = edgeControlPoints(from: rightEdgeStart, to: rightEdgeEnd)
        path.addCurve(to: rightEdgeEnd, control1: rightControls.0, control2: rightControls.1)

        // Bottom right corner, then the bottom edge back left.
        let bottomEdgeStart = CGPoint(x: right - cornerRadius, y: bottom + wobble())
        path.addQuadCurve(to: bottomEdgeStart, control: CGPoint(x: right + wobble(), y: bottom + wobble()))
        let bottomEdgeEnd = CGPoint(x: left + cornerRadius, y: bottom + wobble())
        let bottomControls = edgeControlPoints(from: bottomEdgeStart, to: bottomEdgeEnd)
        path.addCurve(to: bottomEdgeEnd, control1: bottomControls.0, control2: bottomControls.1)

        // Bottom left corner, then the left edge back up.
        let leftEdgeStart = CGPoint(x: left + wobble(), y: bottom - cornerRadius)
        path.addQuadCurve(to: leftEdgeStart, control: CGPoint(x: left + wobble(), y: bottom + wobble()))
        let leftEdgeEnd = CGPoint(x: left + wobble(), y: top + cornerRadius)
        let leftControls = edgeControlPoints(from: leftEdgeStart, to: leftEdgeEnd)
        path.addCurve(to: leftEdgeEnd, control1: leftControls.0, control2: leftControls.1)

        // Top left corner, past the start, and a short overshoot that drifts inside the line.
        let closingPoint = CGPoint(x: left + cornerRadius + 1, y: top + wobble())
        path.addQuadCurve(to: closingPoint, control: CGPoint(x: left + wobble(), y: top + wobble()))
        path.addLine(to: CGPoint(x: left + overshootEndOffsetFromTheLeftEdgeInPoints, y: top + overshootDriftInsideInPoints + wobble()))
        return path
    }

    /// A small deterministic generator, so the wobble depends on the seed alone. SplitMix64.
    private struct SeededWobble {
        var state: UInt64

        /// A value from -`range` to `range`.
        mutating func nextOffset(withinPoints range: CGFloat) -> CGFloat {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var mixedBits = state
            mixedBits = (mixedBits ^ (mixedBits >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixedBits = (mixedBits ^ (mixedBits >> 27)) &* 0x94D0_49BB_1331_11EB
            mixedBits ^= mixedBits >> 31
            let shareFromZeroToOne = CGFloat(mixedBits >> 11) / CGFloat(1 << 53)
            return (shareFromZeroToOne * 2 - 1) * range
        }
    }
}

// MARK: - The spark's timing

/// What the loop shows at one moment: how much of the line is drawn, and where the spark is. A pure function of
/// the time since the loop began, so a frame never depends on the one before it.
enum CursorLoopTimeline {
    static let sparkFlightFromTheCursorSeconds: TimeInterval = 0.3
    static let drawSeconds: TimeInterval = 1.0
    static let secondsPerLap: TimeInterval = 2.2
    /// While a scene builds under the loop, after its first 3 seconds, a lap takes this long.
    static let secondsPerLapDuringABuild: TimeInterval = 4.0
    static let secondsBeforeTheSparkSlowsDuringABuild: TimeInterval = 3.0

    enum SparkPlace: Equatable {
        /// On its way from the cursor to the line's start. `share` runs from 0 at the cursor to 1 at the start.
        case flyingFromTheCursor(share: Double)
        /// On the line. `share` runs from 0 at the start to 1 at the end of the overshoot.
        case onTheLoop(share: Double)
    }

    struct Frame: Equatable {
        /// How much of the line is drawn, from 0 to 1. The spark draws it, so it is also the spark's share while drawing.
        let drawnShare: Double
        let spark: SparkPlace
    }

    /// `secondsWhenTheSparkSlows` counts from the loop's first moment, like the time does. Nil keeps a lap at 2.2 seconds.
    static func frame(secondsSinceTheLoopBegan secondsSinceBegan: TimeInterval, secondsWhenTheSparkSlows: TimeInterval?) -> Frame {
        let secondsBeforeDrawing = sparkFlightFromTheCursorSeconds
        let secondsBeforeLapping = secondsBeforeDrawing + drawSeconds
        if secondsSinceBegan < secondsBeforeDrawing {
            return Frame(drawnShare: 0, spark: .flyingFromTheCursor(share: max(0, secondsSinceBegan) / secondsBeforeDrawing))
        }
        if secondsSinceBegan < secondsBeforeLapping {
            let drawnShare = (secondsSinceBegan - secondsBeforeDrawing) / drawSeconds
            return Frame(drawnShare: drawnShare, spark: .onTheLoop(share: drawnShare))
        }
        // The spark keeps going from the end of the line, so it never jumps back at the end of the draw.
        let slowedFromSeconds = max(secondsWhenTheSparkSlows ?? .infinity, secondsBeforeLapping)
        let secondsAtTheNormalPace = min(secondsSinceBegan, slowedFromSeconds) - secondsBeforeLapping
        let secondsAtTheSlowPace = max(0, secondsSinceBegan - slowedFromSeconds)
        let lapsDone = 1 + secondsAtTheNormalPace / secondsPerLap + secondsAtTheSlowPace / secondsPerLapDuringABuild
        return Frame(drawnShare: 1, spark: .onTheLoop(share: lapsDone.truncatingRemainder(dividingBy: 1)))
    }
}
