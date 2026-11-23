//
//  CursorLoopState.swift
//  leanring-buddy
//
//  The pure part of the loop Clicky draws around the video or image it is looking at: what decides
//  whether a request draws a loop and when it clears, the line that background agents lap their sparks around,
//  the outline of the loop, and the timing of Clicky's cursor as it draws it. Nothing here reads Chrome, the clock, or
//  the screen, so tests drive it with made-up times and rects.
//  `CursorLoopController` does the reading, and `CursorLoopView` the drawing.
//

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - The media the loop goes around

/// What the poll reads from Chrome's front tab once a second: which tab it is, and where the window and the largest
/// media sit in it. It needs two Apple Events, with no accessibility read, since the main actor also moves the cursor and draws the line.
struct FrontTabSample: Equatable {
    let windowID: Int
    let tabID: Int
    let tabURL: String
    let pageGeometry: ChromePageGeometry
}

/// The largest video or image in Chrome's front tab as Clicky read it, and the tab sample it was read with.
/// The loop clears when a later sample of the front tab differs from this one.
struct MediaOnTheFrontTab: Equatable {
    let screenRect: ScreenRectInChromeCoordinates
    let sample: FrontTabSample

    func isTheSameMediaInTheSameTab(as laterSample: FrontTabSample) -> Bool {
        sample.windowID == laterSample.windowID
            && sample.tabID == laterSample.tabID
            && sample.tabURL == laterSample.tabURL
            && sample.pageGeometry.isCloseTo(laterSample.pageGeometry)
    }
}

/// What a request's loop goes around: the largest media in Chrome's front tab, which the poll watches, or a region the learner
/// circled with the mouse while holding push-to-talk, which may be in any app, so no tab is watched and no agent's spark joins it.
enum CursorLoopTarget: Equatable {
    case media(MediaOnTheFrontTab)
    case circledRegion(CircledRegion)

    var screenRect: ScreenRectInChromeCoordinates {
        switch self {
        case .media(let media): return media.screenRect
        case .circledRegion(let circledRegion): return circledRegion.boundingRect
        }
    }

    /// The Chrome media, or nil for a circled region.
    var media: MediaOnTheFrontTab? {
        if case .media(let media) = self { return media }
        return nil
    }
}

/// A request that became a look at the media draws a loop only when nothing else owns the screen: a scene on screen
/// covers the media, and a quiz question waiting on its answer belongs to the question.
func requestMayDrawALoop(aSceneIsOnScreen: Bool, aQuizQuestionIsOpen: Bool) -> Bool {
    !aSceneIsOnScreen && !aQuizQuestionIsOpen
}

/// An agent's spark draws, and joins the line, only when a request's loop could draw, and with Show Clicky on, since with it
/// off the overlay fades a second after the answer. An open room art panel covers the screen with its own loop, so it holds
/// the sparks back as a scene does.
func agentSparksMayDraw(clickyCursorIsEnabled: Bool, aSceneIsOnScreen: Bool, aQuizQuestionIsOpen: Bool, theRoomArtPanelIsOpen: Bool) -> Bool {
    clickyCursorIsEnabled
        && !theRoomArtPanelIsOpen
        && requestMayDrawALoop(aSceneIsOnScreen: aSceneIsOnScreen, aQuizQuestionIsOpen: aQuizQuestionIsOpen)
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
    /// Clicky's answer started to play, so the speech Callout takes over from the loop.
    case speechStarted
    /// A scene or pop-out began to show, so it rises from the line Clicky drew.
    case aSceneStartedToShow

    /// Whether this also clears the sparks agents lap around the media. An agent keeps working while the learner talks
    /// and while Clicky answers, so only a change of what is in front ends its sparks: a scroll, a tab or media change,
    /// another front app, or a scene covering the media.
    var endsTheAgentSparks: Bool {
        switch self {
        case .scrolled, .tabOrMediaChanged, .appSwitched, .aSceneStartedToShow: return true
        case .thinkingStopped, .newPushToTalk, .speechStarted: return false
        }
    }

    /// Whether this ends a loop around a region the learner circled. The region may be in any app, so another front app or
    /// tab leaves its loop: macOS's own prompts, such as the one a screen capture brings up, take the front for a moment.
    var endsALoopAroundACircledRegion: Bool {
        switch self {
        case .appSwitched, .tabOrMediaChanged: return false
        case .thinkingStopped, .newPushToTalk, .scrolled, .speechStarted, .aSceneStartedToShow: return true
        }
    }
}

/// The line background agents lap their sparks around: the media they work on, and the agents in the order they joined.
struct AgentSparkLine: Equatable {
    let media: MediaOnTheFrontTab
    var agentIDs: [UUID]
}

/// Whether Clicky's voice state ends a loop that is showing. Going idle covers a cancel and a failure, and an
/// answer's speech ends the loop too, since the speech Callout takes over. A status line speaking, such as
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
        /// `shimmerSlowsAt` is set once a scene build runs under the loop.
        case showing(CursorLoopTarget, since: TimeInterval, shimmerSlowsAt: TimeInterval?)
        /// Keeps the timing the loop had, so its shimmer carries on while the line fades.
        case fadingOut(CursorLoopTarget, since: TimeInterval, shimmerSlowsAt: TimeInterval?)
    }

    enum AgentLine: Equatable {
        case hidden
        case showing(AgentSparkLine)
        /// Keeps its sparks while the line fades.
        case fadingOut(AgentSparkLine)
    }

    private(set) var turn = Turn.notWaitingForALoop
    private(set) var loop = Loop.hidden
    private(set) var agentLine = AgentLine.hidden

    struct RunningAgent: Equatable {
        let id: UUID
        let sourceTab: AgentSourceTab
        /// A finished agent only runs its spark's last lap, so it never rejoins a line that cleared meanwhile.
        var hasFinished = false
    }
    /// The agents that started from a tab and have not ended, in the order they started, whether or not their spark is on the
    /// line. A scroll or a tab switch clears the line while they work, and they rejoin it when the video is in front again.
    private(set) var runningAgents: [RunningAgent] = []

    var loopIsShowing: Bool {
        if case .showing = loop { return true }
        return false
    }

    /// The loop to draw, whether it is showing or fading out.
    var loopOnTheMedia: (target: CursorLoopTarget, since: TimeInterval, shimmerSlowsAt: TimeInterval?, isFadingOut: Bool)? {
        switch loop {
        case .hidden:
            return nil
        case .showing(let target, let since, let shimmerSlowsAt):
            return (target, since, shimmerSlowsAt, false)
        case .fadingOut(let target, let since, let shimmerSlowsAt):
            return (target, since, shimmerSlowsAt, true)
        }
    }

    /// The Chrome media of a loop that is showing, which the poll compares each front tab read to. A circled region has none.
    var mediaTheLoopIsAround: MediaOnTheFrontTab? {
        if case .showing(let target, _, _) = loop { return target.media }
        return nil
    }

    /// A request's loop around the media draws the whole line the agents' sparks ride, so their own track shows only when
    /// none does. A loop around a region the learner circled is somewhere else, so the track stays.
    var agentLineDrawsItsOwnTrack: Bool { mediaTheLoopIsAround == nil }

    var agentLineIsShowing: Bool {
        if case .showing = agentLine { return true }
        return false
    }

    /// Whether the agent's spark is on the line that shows. A line that is fading out holds no agent.
    func agentLineHolds(agentID: UUID) -> Bool {
        if case .showing(let line) = agentLine { return line.agentIDs.contains(agentID) }
        return false
    }

    /// The agent line to draw, whether it is showing or fading out.
    var agentLineOnTheMedia: (line: AgentSparkLine, isFadingOut: Bool)? {
        switch agentLine {
        case .hidden: return nil
        case .showing(let line): return (line, false)
        case .fadingOut(let line): return (line, true)
        }
    }

    /// The media the poll watches: a loop's, or else the agent line's. Either one clears when the front tab differs from it.
    var mediaThePollWatches: MediaOnTheFrontTab? {
        if let mediaTheLoopIsAround { return mediaTheLoopIsAround }
        if case .showing(let line) = agentLine { return line.media }
        return nil
    }

    /// An agent started. Its spark joins the line when its work is on the video in front, and it is remembered so that it
    /// can rejoin when a later turn has that video's media in hand again. The line goes around the media it already has,
    /// or a loop's, or else the rect the push-to-talk release read for this turn, which a turn that handed off to nothing
    /// keeps. With no request loop around the media, that rect in hand is what gives an agent a line of its own, and dropping it would
    /// limit sparks to a loop a request already drew. `mayJoinTheLine` is false while a scene covers the media, a quiz question
    /// is open, or Show Clicky is off, and the agent is then only remembered.
    mutating func agentStarted(id agentID: UUID, sourceTab: AgentSourceTab, mayJoinTheLine: Bool) {
        guard !runningAgents.contains(where: { $0.id == agentID }) else { return }
        let runningAgent = RunningAgent(id: agentID, sourceTab: sourceTab)
        runningAgents.append(runningAgent)
        if mayJoinTheLine { joinTheLineIfTheAgentWorksOnTheVideoInFront(runningAgent) }
    }

    /// The agent finished. Its spark is still on the line for its last lap, if the line shows, and it never rejoins.
    mutating func agentFinished(id agentID: UUID) {
        guard let index = runningAgents.firstIndex(where: { $0.id == agentID }) else { return }
        runningAgents[index].hasFinished = true
    }

    /// Every running agent whose spark is off the line and whose video is in front again joins it.
    private mutating func runningAgentsRejoinTheLine() {
        for runningAgent in runningAgents where !runningAgent.hasFinished {
            joinTheLineIfTheAgentWorksOnTheVideoInFront(runningAgent)
        }
    }

    private mutating func joinTheLineIfTheAgentWorksOnTheVideoInFront(_ runningAgent: RunningAgent) {
        var candidateMedia: [MediaOnTheFrontTab] = []
        if case .showing(let line) = agentLine { candidateMedia.append(line.media) }
        if let mediaTheLoopIsAround { candidateMedia.append(mediaTheLoopIsAround) }
        if case .rectIsInHand(let mediaInHand) = turn { candidateMedia.append(mediaInHand) }
        guard let media = candidateMedia.first(where: { agentWorksOnTheVideoInFront(sourceTab: runningAgent.sourceTab, frontTabURL: $0.sample.tabURL) }) else {
            return
        }
        if case .showing(var line) = agentLine, line.media.sample.tabURL == media.sample.tabURL {
            if !line.agentIDs.contains(runningAgent.id) { line.agentIDs.append(runningAgent.id) }
            agentLine = .showing(line)
        } else {
            agentLine = .showing(AgentSparkLine(media: media, agentIDs: [runningAgent.id]))
        }
    }

    /// The agent finished and its spark is done, or it ended without finishing. It leaves the line and is forgotten.
    mutating func agentEnded(id agentID: UUID) {
        runningAgents.removeAll { $0.id == agentID }
        agentLeavesTheLine(id: agentID)
    }

    /// The agent's spark is done, or the agent ended without finishing. The line fades with its last agent.
    mutating func agentLeavesTheLine(id agentID: UUID) {
        guard case .showing(var line) = agentLine, line.agentIDs.contains(agentID) else { return }
        line.agentIDs.removeAll { $0 == agentID }
        agentLine = line.agentIDs.isEmpty ? .fadingOut(line) : .showing(line)
    }

    /// The fade is over, so the agent line leaves the screen.
    mutating func agentLineFadeOutFinished() {
        if case .fadingOut = agentLine {
            agentLine = .hidden
        }
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
    /// `agentsMayJoinTheLine` is false while a scene covers the media, a quiz question is open, or Show Clicky is off, so a release
    /// then brings back no agent's spark.
    mutating func mediaRectArrived(_ media: MediaOnTheFrontTab?, at now: TimeInterval, agentsMayJoinTheLine: Bool) {
        guard case .readingTheRect(let handedOffAt) = turn else { return }
        guard let media else {
            turn = .notWaitingForALoop
            return
        }
        guard let handedOffAt else {
            turn = .rectIsInHand(media)
            if agentsMayJoinTheLine { runningAgentsRejoinTheLine() }
            return
        }
        // The request already became a look at the media, so this is the last chance to draw the loop for it.
        turn = .notWaitingForALoop
        if now - handedOffAt <= Self.secondsTheRectMayArriveAfterTheHandOff {
            loop = .showing(.media(media), since: now, shimmerSlowsAt: nil)
            if agentsMayJoinTheLine { runningAgentsRejoinTheLine() }
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
            loop = .showing(.media(media), since: now, shimmerSlowsAt: nil)
        }
    }

    /// The request became a look at a region the learner circled while holding push-to-talk. The region was in hand at the
    /// release, so its loop shows at once, and the turn ends, so the front tab's media read for this release draws nothing.
    mutating func requestBecameALookAtTheCircledRegion(_ circledRegion: CircledRegion, at now: TimeInterval) {
        turn = .notWaitingForALoop
        loop = .showing(.circledRegion(circledRegion), since: now, shimmerSlowsAt: nil)
    }

    /// A status line such as "Building your 3D scene" started under a loop. After the first 3 seconds of the loop
    /// the line's shimmer slows, since a build takes a while and a fast shimmer would look like a hang.
    mutating func aStatusLabelStartedShowing(at now: TimeInterval) {
        guard case .showing(let target, let since, let shimmerSlowsAt) = loop, shimmerSlowsAt == nil else { return }
        loop = .showing(target, since: since, shimmerSlowsAt: max(now, since + CursorLoopTimeline.secondsBeforeTheShimmerSlowsDuringABuild))
    }

    /// Any of these ends the turn too, so a rect read for it can no longer draw a loop.
    mutating func end(because reason: CursorLoopEndReason) {
        turn = .notWaitingForALoop
        if case .showing(let target, let since, let shimmerSlowsAt) = loop,
           target.media != nil || reason.endsALoopAroundACircledRegion {
            loop = .fadingOut(target, since: since, shimmerSlowsAt: shimmerSlowsAt)
        }
        if reason.endsTheAgentSparks, case .showing(let line) = agentLine {
            agentLine = .fadingOut(line)
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
    /// On a narrow media, such as a tall portrait image, those offsets would run past the top edge, so they shrink
    /// to these shares of the outline's width, which keeps the start left of the first corner and the overshoot inside the line.
    private static let startOffsetShareOfTheWidth: CGFloat = 0.2
    private static let overshootEndOffsetShareOfTheWidth: CGFloat = 0.4

    static func startOffsetFromTheLeftEdge(forLineWidth lineWidth: CGFloat) -> CGFloat {
        min(startOffsetFromTheLeftEdgeInPoints, lineWidth * startOffsetShareOfTheWidth)
    }

    static func overshootEndOffsetFromTheLeftEdge(forLineWidth lineWidth: CGFloat) -> CGFloat {
        min(overshootEndOffsetFromTheLeftEdgeInPoints, lineWidth * overshootEndOffsetShareOfTheWidth)
    }
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

    /// The same wobble for the same rect, so a loop never shimmers when it is rebuilt. The rect's numbers come from
    /// the page, so they are hashed as bit patterns, which never trap on a NaN or an infinity the way an integer
    /// conversion does.
    static func seed(for mediaRect: CGRect) -> UInt64 {
        var mixedBits: UInt64 = 0x9E37_79B9_7F4A_7C15
        for value in [mediaRect.minX, mediaRect.minY, mediaRect.width, mediaRect.height] {
            mixedBits ^= Double(value.rounded()).bitPattern
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
        let startX = left + startOffsetFromTheLeftEdge(forLineWidth: lineRect.width)

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
        path.addLine(to: CGPoint(x: left + overshootEndOffsetFromTheLeftEdge(forLineWidth: lineRect.width), y: top + overshootDriftInsideInPoints + wobble()))
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

// MARK: - The cursor's timing

/// When Clicky's cursor draws a loop, as pure functions of time, so a frame never depends on the one before it.
/// The cursor traces the whole line once in `traceSeconds`, easing in and out like a hand, and the ink is the line behind
/// it. In the overlay the real cursor flies to the line's start first, on the Point move, and back to the mouse after, and
/// the finished line then carries a slow shimmer while Clicky thinks, since the loop is the thinking light. The room art
/// panel has no cursor to fly in, so its glyph starts on the line and keeps lapping it while the measurement runs.
/// Both laps go at `secondsPerLap`, and the overlay's shimmer slows during a build.
enum CursorLoopTimeline {
    static let traceSeconds: TimeInterval = 1.0
    static let secondsPerLap: TimeInterval = 2.2
    /// While a scene builds under the loop, after its first 3 seconds, a lap takes this long.
    static let secondsPerLapDuringABuild: TimeInterval = 4.0
    static let secondsBeforeTheShimmerSlowsDuringABuild: TimeInterval = 3.0

    /// The share of the line traced `seconds` after the cursor reached the line's start: 0 before, 1 from `traceSeconds`
    /// on, and smoothstep between, so the cursor sets off and arrives gently.
    static func tracedShare(secondsSinceTheTraceBegan seconds: TimeInterval) -> Double {
        let linearShare = min(max(seconds / traceSeconds, 0), 1)
        return linearShare * linearShare * (3 - 2 * linearShare)
    }

    static func traceIsDone(secondsSinceTheTraceBegan seconds: TimeInterval) -> Bool {
        seconds >= traceSeconds
    }

    /// How fast the cursor traces at this moment, from 0 at the ends of the trace to 1 at its middle: the slope of the
    /// smoothstep over its peak. Its streaks show by it, and it stretches along the line by it, as in a Point flight.
    static func traceSpeedShare(secondsSinceTheTraceBegan seconds: TimeInterval) -> Double {
        let linearShare = min(max(seconds / traceSeconds, 0), 1)
        return 4 * linearShare * (1 - linearShare)
    }

    /// The flight to the line's start leaves the cursor turned along the flight's arc, so at the start of the trace it turns
    /// to its tracing angle over `secondsToTurnTowardTheLine`, the shortest way round, instead of snapping.
    static let secondsToTurnTowardTheLine: TimeInterval = 0.15

    static func turnTowardTheLine(fromDegrees: Double, toDegrees: Double, secondsSinceTheTraceBegan seconds: TimeInterval) -> Double {
        let turnedShare = min(max(seconds / secondsToTurnTowardTheLine, 0), 1)
        var difference = (toDegrees - fromDegrees).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return fromDegrees + difference * turnedShare
    }

    /// Where a lap is, from 0 to 1, `seconds` after the laps began. `secondsWhenTheLapsSlow` counts from the same moment, and a
    /// negative one slows them from the start. Nil keeps a lap at `secondsPerLap`.
    static func lapShare(secondsSinceTheLapsBegan seconds: TimeInterval, secondsWhenTheLapsSlow: TimeInterval?) -> Double {
        let secondsSinceBegan = max(0, seconds)
        let slowedFromSeconds = max(0, secondsWhenTheLapsSlow ?? .infinity)
        let secondsAtTheNormalPace = min(secondsSinceBegan, slowedFromSeconds)
        let secondsAtTheSlowPace = max(0, secondsSinceBegan - slowedFromSeconds)
        let lapsDone = secondsAtTheNormalPace / secondsPerLap + secondsAtTheSlowPace / secondsPerLapDuringABuild
        return lapsDone.truncatingRemainder(dividingBy: 1)
    }

    /// Where the glyph is on a loop it keeps lapping.
    enum TracerPlace: Equatable {
        /// Drawing the line. `share` runs from 0 at the start to 1 at the end of the overshoot.
        case tracing(share: Double)
        /// Lapping the finished line. `lapShare` runs from 0 to 1 around the closed part of it (`CursorLoopLine.shareOfTheLine(atLapShare:)`).
        case lapping(lapShare: Double)
    }

    struct Frame: Equatable {
        /// How much of the line is drawn, from 0 to 1.
        let drawnShare: Double
        let tracer: TracerPlace
    }

    /// The room art panel's loop: the glyph traces the line from the loop's first moment, then laps it.
    static func lappingFrame(secondsSinceTheLoopBegan seconds: TimeInterval) -> Frame {
        guard traceIsDone(secondsSinceTheTraceBegan: seconds) else {
            let share = tracedShare(secondsSinceTheTraceBegan: seconds)
            return Frame(drawnShare: share, tracer: .tracing(share: share))
        }
        return Frame(
            drawnShare: 1,
            tracer: .lapping(lapShare: lapShare(secondsSinceTheLapsBegan: seconds - traceSeconds, secondsWhenTheLapsSlow: nil))
        )
    }
}
