//
//  CursorRingAndLoopTests.swift
//  leanring-buddyTests
//
//  The ring around the cursor and the loop around the media Clicky is looking at: when a request draws a loop and
//  when it clears, the loop's outline, the spark's timing, and the ring's ticks and dots.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Clicky

private let exampleMedia = MediaOnTheFrontTab(
    screenRect: ScreenRectInChromeCoordinates(rectX: 100, rectY: 120, rectWidth: 600, rectHeight: 338),
    windowID: 7,
    tabID: 42,
    tabURL: "https://www.youtube.com/watch?v=example"
)

/// A turn that reached the hand-off with the rect already back, which draws the loop at `now`.
private func stateShowingALoop(since now: TimeInterval = 10) -> CursorLoopState {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(exampleMedia, at: now - 1)
    state.requestBecameALookAtTheMedia(at: now)
    return state
}

// MARK: - When a request draws a loop

@Test func aRequestThatBecomesALookDrawsTheLoopWhenTheRectIsAlreadyInHand() {
    let state = stateShowingALoop(since: 10)
    #expect(state.loop == .showing(exampleMedia, since: 10, sparkSlowsAt: nil))
    #expect(state.turn == .notWaitingForALoop)
}

@Test func aRectThatArrivesWithinTheHandOffWindowStillDrawsTheLoop() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 10)
    #expect(!state.loopIsShowing)
    // A quarter second after the hand-off is inside the 300 ms window.
    state.mediaRectArrived(exampleMedia, at: 10.25)
    #expect(state.loop == .showing(exampleMedia, since: 10.25, sparkSlowsAt: nil))
}

@Test func aRectThatArrivesAfterTheHandOffWindowDrawsNothing() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 10)
    state.mediaRectArrived(exampleMedia, at: 10.31)
    #expect(state.loop == .hidden)
    #expect(state.turn == .notWaitingForALoop)
}

@Test func onlyTheFirstHandOffOfATurnStartsTheHandOffWindow() {
    // A later hand-off must not move the window, or a rect that missed the first one would still draw.
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 10)
    state.requestBecameALookAtTheMedia(at: 11)
    state.mediaRectArrived(exampleMedia, at: 11.2)
    #expect(state.loop == .hidden)
}

@Test func aTurnThatNeverHandsOffNeverDrawsALoop() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(exampleMedia, at: 10)
    #expect(state.loop == .hidden)
    // The rect stays unused until the turn ends. A later hand-off from a different turn must not reuse it.
    state.pushToTalkWasPressed()
    state.requestBecameALookAtTheMedia(at: 20)
    #expect(state.loop == .hidden)
}

@Test func onlyTheRoutersLookAtTheMediaToolsHandOff() {
    let toolsThatHandOff = AppVoiceTool.allCases.filter(\.handsOffToALookAtTheMedia)
    #expect(Set(toolsThatHandOff) == [.answerWithScreen, .buildNewScene, .popOut])
}

@Test func aMissingMediaRectDrawsNothing() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(nil, at: 10)
    state.requestBecameALookAtTheMedia(at: 10.1)
    #expect(state.loop == .hidden)
}

@Test func aHandOffWithNoReleasedTurnDrawsNothing() {
    var state = CursorLoopState()
    state.requestBecameALookAtTheMedia(at: 10)
    state.mediaRectArrived(exampleMedia, at: 10.1)
    #expect(state.loop == .hidden)
}

// MARK: - When a loop clears

@Test(arguments: CursorLoopEndReason.allCases)
func eachEndEventFadesAShowingLoop(reason: CursorLoopEndReason) {
    var state = stateShowingALoop(since: 10)
    state.end(because: reason)
    #expect(state.loop == .fadingOut(exampleMedia, since: 10, sparkSlowsAt: nil))
    #expect(!state.loopIsShowing)
    state.fadeOutFinished()
    #expect(state.loop == .hidden)
}

@Test(arguments: CursorLoopEndReason.allCases)
func eachEndEventStopsARectInHandFromDrawingLater(reason: CursorLoopEndReason) {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(exampleMedia, at: 10)
    state.end(because: reason)
    state.requestBecameALookAtTheMedia(at: 10.5)
    #expect(state.loop == .hidden)
}

@Test func theVoiceStateEndsALoopOnlyWhenClickyStopsThinkingOrSpeaksAnAnswer() {
    #expect(cursorLoopEndReason(forVoiceState: .processing, aStatusLabelIsShowing: false) == nil)
    #expect(cursorLoopEndReason(forVoiceState: .idle, aStatusLabelIsShowing: false) == .thinkingStopped)
    #expect(cursorLoopEndReason(forVoiceState: .responding, aStatusLabelIsShowing: false) == .speechStarted)
    // "Sure, let me build that for you" is spoken under the loop, which stays through the build.
    #expect(cursorLoopEndReason(forVoiceState: .responding, aStatusLabelIsShowing: true) == nil)
}

/// A controller that reads `media` from the front tab instead of Chrome, with a turn waiting for a loop.
@MainActor
private func controllerWithATurnWaitingForALoop(reading media: MediaOnTheFrontTab?) async -> CursorLoopController {
    let controller = CursorLoopController(readTheMediaInTheFrontTab: { media })
    controller.pushToTalkWasReleased()
    // The rect read runs as a task, so it has arrived once the task has had a turn.
    try? await Task.sleep(for: .milliseconds(50))
    return controller
}

@Test func anIdleThatLastsOnlyAMomentDoesNotEndATurnWaitingForALoop() async {
    // The dictation session finishes and sets idle right after a request is submitted, before the request
    // sets processing, so a loop that is about to draw must survive that blip.
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia)
    controller.voiceStateChanged(to: .idle, aStatusLabelIsShowing: false)
    controller.voiceStateChanged(to: .processing, aStatusLabelIsShowing: false)
    try? await Task.sleep(for: .seconds(CursorLoopController.secondsAnIdleMustHoldToEndTheLoop + 0.2))
    controller.requestBecameALookAtTheMedia()
    #expect(controller.isShowingTheLoop)
}

@Test func anIdleThatHoldsEndsALoopThatIsShowing() async {
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia)
    controller.requestBecameALookAtTheMedia()
    #expect(controller.isShowingTheLoop)
    controller.voiceStateChanged(to: .idle, aStatusLabelIsShowing: false)
    try? await Task.sleep(for: .seconds(CursorLoopController.secondsAnIdleMustHoldToEndTheLoop + 0.2))
    #expect(!controller.isShowingTheLoop)
}

// MARK: - The spark under a build

@Test func theSparkSlowsThreeSecondsIntoTheLoopWhenABuildStarts() {
    var buildStartedEarly = stateShowingALoop(since: 10)
    buildStartedEarly.aStatusLabelStartedShowing(at: 10.5)
    #expect(buildStartedEarly.loop == .showing(exampleMedia, since: 10, sparkSlowsAt: 13))

    var buildStartedLate = stateShowingALoop(since: 10)
    buildStartedLate.aStatusLabelStartedShowing(at: 15)
    #expect(buildStartedLate.loop == .showing(exampleMedia, since: 10, sparkSlowsAt: 15))
}

@Test func theSparkLapsEvery2Point2SecondsAndEvery4SecondsDuringABuild() {
    let secondsBeforeLapping = CursorLoopTimeline.sparkFlightFromTheCursorSeconds + CursorLoopTimeline.drawSeconds
    func shareOnTheLoop(_ frame: CursorLoopTimeline.Frame) -> Double {
        guard case .onTheLoop(let share) = frame.spark else { return -1 }
        return share
    }
    let atTheEndOfTheDraw = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: secondsBeforeLapping, secondsWhenTheSparkSlows: nil)
    let aLapLater = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: secondsBeforeLapping + 2.2, secondsWhenTheSparkSlows: nil)
    #expect(atTheEndOfTheDraw.drawnShare == 1)
    #expect(abs(shareOnTheLoop(atTheEndOfTheDraw) - shareOnTheLoop(aLapLater)) < 0.0001)

    // Slowing at 3 seconds changes the pace from then on and never moves the spark at that moment.
    let justBeforeTheSlowdown = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: 3, secondsWhenTheSparkSlows: 3)
    let justAfterTheSlowdown = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: 3.0001, secondsWhenTheSparkSlows: 3)
    #expect(abs(shareOnTheLoop(justBeforeTheSlowdown) - shareOnTheLoop(justAfterTheSlowdown)) < 0.001)
    let aSlowLapLater = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: 3 + 4, secondsWhenTheSparkSlows: 3)
    #expect(abs(shareOnTheLoop(justBeforeTheSlowdown) - shareOnTheLoop(aSlowLapLater)) < 0.0001)
}

@Test func theSparkLeavesTheCursorThenDrawsTheWholeLoop() {
    let flying = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: 0.15, secondsWhenTheSparkSlows: nil)
    #expect(flying.drawnShare == 0)
    #expect(flying.spark == .flyingFromTheCursor(share: 0.5))
    let drawing = CursorLoopTimeline.frame(secondsSinceTheLoopBegan: 0.3 + 0.5, secondsWhenTheSparkSlows: nil)
    #expect(drawing.drawnShare == 0.5)
    #expect(drawing.spark == .onTheLoop(share: 0.5))
}

// MARK: - The outline

/// Points on the path, evenly along its length.
private func pointsAlong(_ path: Path, sampleCount: Int = 400) -> [CGPoint] {
    (0...sampleCount).compactMap { sampleIndex in
        path.trimmedPath(from: 0, to: max(Double(sampleIndex) / Double(sampleCount), 0.000001)).currentPoint
    }
}

private let exampleMediaRects = [
    CGRect(x: 94, y: 120, width: 600, height: 338),
    CGRect(x: 40, y: 60, width: 160, height: 90),
    CGRect(x: 300, y: 200, width: 1280, height: 720),
]

@Test(arguments: exampleMediaRects)
func theLoopRunsFourPointsOutsideTheMediaAndNeverEntersIt(mediaRect: CGRect) {
    let lineRect = CursorLoopOutline.rectTheLineRunsAlong(around: mediaRect, insideScreenBounds: CGRect(x: 0, y: 0, width: 4000, height: 3000))
    #expect(lineRect == mediaRect.insetBy(dx: -4, dy: -4))
    let samples = pointsAlong(CursorLoopOutline.path(along: lineRect, seed: CursorLoopOutline.seed(for: mediaRect)))
    #expect(samples.allSatisfy { !mediaRect.contains($0) })
    // The wobble is about a point, so every side of the loop sits within 1.5 points of the 4 point gap.
    let wobbleAllowance: CGFloat = 1.5
    #expect(abs((samples.map(\.x).min() ?? 0) - lineRect.minX) <= wobbleAllowance)
    #expect(abs((samples.map(\.x).max() ?? 0) - lineRect.maxX) <= wobbleAllowance)
    #expect(abs((samples.map(\.y).min() ?? 0) - lineRect.minY) <= wobbleAllowance)
    #expect(abs((samples.map(\.y).max() ?? 0) - lineRect.maxY) <= wobbleAllowance)
}

/// The path's first and last points, read from its own elements, since a trimmed path is only accurate to a sample.
private func startAndEnd(of path: Path) -> (start: CGPoint, end: CGPoint) {
    var start = CGPoint.zero
    var end = CGPoint.zero
    path.forEach { pathElement in
        switch pathElement {
        case .move(let point):
            start = point
            end = point
        case .line(let point), .quadCurve(let point, _), .curve(let point, _, _):
            end = point
        case .closeSubpath:
            break
        }
    }
    return (start, end)
}

@Test(arguments: exampleMediaRects)
func theLoopClosesWithAnOvershootThatPassesItsStartAndStaysInsideTheLine(mediaRect: CGRect) {
    let lineRect = CursorLoopOutline.rectTheLineRunsAlong(around: mediaRect, insideScreenBounds: CGRect(x: 0, y: 0, width: 4000, height: 3000))
    let (start, end) = startAndEnd(of: CursorLoopOutline.path(along: lineRect, seed: CursorLoopOutline.seed(for: mediaRect)))
    // It starts on the top edge, runs clockwise, and ends on the top edge again, past where it started.
    #expect(abs(start.y - lineRect.minY) <= 1.5)
    #expect(start.x == lineRect.minX + CursorLoopOutline.startOffsetFromTheLeftEdgeInPoints)
    #expect(end.x - start.x == CursorLoopOutline.overshootEndOffsetFromTheLeftEdgeInPoints - CursorLoopOutline.startOffsetFromTheLeftEdgeInPoints)
    // The overshoot drifts about 2.8 points toward the media, never as far as the media's edge.
    #expect(end.y > lineRect.minY + 1)
    #expect(end.y < lineRect.minY + CursorLoopOutline.gapFromTheMediaInPoints)
}

@Test func theWobbleDependsOnlyOnTheRect() {
    let mediaRect = exampleMediaRects[0]
    let lineRect = mediaRect.insetBy(dx: -4, dy: -4)
    let seed = CursorLoopOutline.seed(for: mediaRect)
    #expect(CursorLoopOutline.path(along: lineRect, seed: seed) == CursorLoopOutline.path(along: lineRect, seed: seed))
    #expect(CursorLoopOutline.seed(for: mediaRect) == CursorLoopOutline.seed(for: mediaRect))
    #expect(CursorLoopOutline.seed(for: mediaRect) != CursorLoopOutline.seed(for: exampleMediaRects[1]))
}

@Test func aPageNumberThatIsNotFiniteCannotCrashTheSeed() {
    // Int64(.nan) and Int64(.infinity) trap, and the rect's numbers come from the page.
    let badRects = [
        CGRect(x: CGFloat.nan, y: 0, width: 600, height: 338),
        CGRect(x: 0, y: CGFloat.infinity, width: 600, height: 338),
        CGRect(x: 0, y: 0, width: 1e300, height: 338),
    ]
    for badRect in badRects {
        #expect(CursorLoopOutline.seed(for: badRect) == CursorLoopOutline.seed(for: badRect))
    }
}

@Test func aLoopNearAScreenEdgeIsPulledInsideIt() {
    let screenBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    // A 16:9 video letterboxed in full screen touches both side edges.
    let letterboxedVideo = CGRect(x: 0, y: 78, width: 1920, height: 924)
    let lineRect = CursorLoopOutline.rectTheLineRunsAlong(around: letterboxedVideo, insideScreenBounds: screenBounds)
    #expect(lineRect.minX == CursorLoopOutline.marginFromTheScreenEdgeInPoints)
    #expect(lineRect.maxX == 1920 - CursorLoopOutline.marginFromTheScreenEdgeInPoints)
    let expectedTopEdge: CGFloat = 74
    #expect(lineRect.minY == expectedTopEdge)
}

@Test func mediaThatFillsTheWholeScreenGetsNoLoop() {
    let screenFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let wholeScreen = ScreenRectInChromeCoordinates(rectX: 0, rectY: 0, rectWidth: 1920, rectHeight: 1080)
    let letterboxedVideo = ScreenRectInChromeCoordinates(rectX: 0, rectY: 78, rectWidth: 1920, rectHeight: 924)
    let playerInAWindow = ScreenRectInChromeCoordinates(rectX: 94, rectY: 120, rectWidth: 600, rectHeight: 338)
    #expect(mediaFillsTheWholeScreen(wholeScreen, screenFrameInChromeCoordinates: screenFrame))
    #expect(!mediaFillsTheWholeScreen(letterboxedVideo, screenFrameInChromeCoordinates: screenFrame))
    #expect(!mediaFillsTheWholeScreen(playerInAWindow, screenFrameInChromeCoordinates: screenFrame))
}

@Test func theFrontTabPollIgnoresAPointOrTwoOfLayoutShiftAndNothingMore() {
    func media(rectX: Double = 100, tabID: Int = 42, tabURL: String = "https://www.youtube.com/watch?v=example") -> MediaOnTheFrontTab {
        MediaOnTheFrontTab(
            screenRect: ScreenRectInChromeCoordinates(rectX: rectX, rectY: 120, rectWidth: 600, rectHeight: 338),
            windowID: 7,
            tabID: tabID,
            tabURL: tabURL
        )
    }
    #expect(media().isTheSameMediaInTheSameTab(as: media(rectX: 101.5)))
    #expect(!media().isTheSameMediaInTheSameTab(as: media(rectX: 103)))
    #expect(!media().isTheSameMediaInTheSameTab(as: media(tabID: 43)))
    #expect(!media().isTheSameMediaInTheSameTab(as: media(tabURL: "https://www.youtube.com/watch?v=another")))
}

// MARK: - The ring

@Test func theCueShowsTheRingOnlyWhileListeningOrThinkingWithNoLoopAndNoStatusLabel() {
    #expect(cursorCue(voiceState: .idle, loopIsShowing: false, aStatusLabelIsShowing: false) == .idle)
    #expect(cursorCue(voiceState: .listening, loopIsShowing: false, aStatusLabelIsShowing: false) == .listening)
    #expect(cursorCue(voiceState: .processing, loopIsShowing: false, aStatusLabelIsShowing: false) == .thinkingWithDots)
    #expect(cursorCue(voiceState: .responding, loopIsShowing: false, aStatusLabelIsShowing: false) == .speaking)
    // The loop's spark is the thinking light, so the dots stay away while it shows.
    #expect(cursorCue(voiceState: .processing, loopIsShowing: true, aStatusLabelIsShowing: false) == .thinkingWithLoop)
    #expect(cursorCue(voiceState: .processing, loopIsShowing: true, aStatusLabelIsShowing: true) == .thinkingWithLoop)
    // The ring hides under a status label such as "Popping it out".
    #expect(cursorCue(voiceState: .processing, loopIsShowing: false, aStatusLabelIsShowing: true) == .idle)
    #expect(cursorCue(voiceState: .listening, loopIsShowing: false, aStatusLabelIsShowing: true) == .idle)
}

@Test func theTicksFollowTheVoiceBetween5And16Points() {
    let silentTicks = CursorRingGeometry.tickLengths(audioPowerLevel: 0, shimmerPhase: 0)
    #expect(silentTicks.count == 24)
    #expect(silentTicks.allSatisfy { $0 == 5 })

    let ordinarySpeechTicks = CursorRingGeometry.tickLengths(audioPowerLevel: 0.15, shimmerPhase: 1)
    let loudTicks = CursorRingGeometry.tickLengths(audioPowerLevel: 1, shimmerPhase: 1)
    #expect(zip(ordinarySpeechTicks, loudTicks).allSatisfy { $0 <= $1 })
    #expect(ordinarySpeechTicks.contains { $0 > 5 })
    #expect((loudTicks + ordinarySpeechTicks).allSatisfy { (5...16).contains($0) })
    #expect(abs((loudTicks.max() ?? 0) - 16) < 0.5)
}

@Test func theThreeDotsOrbitTheCursorOnceEvery1Point2Seconds() {
    let atTheStart = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: 0)
    let afterOneOrbit = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: 1.2)
    let aQuarterOrbitIn = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: 0.3)
    #expect(atTheStart.count == 3)
    for (before, after) in zip(atTheStart, afterOneOrbit) {
        #expect(hypot(before.offset.x - after.offset.x, before.offset.y - after.offset.y) < 0.001)
    }
    #expect(atTheStart.allSatisfy { abs(hypot($0.offset.x, $0.offset.y) - 24) < 0.001 })
    // The leading dot starts at the top and turns clockwise, so a quarter orbit later it is at the right.
    #expect(abs(atTheStart[0].offset.x) < 0.001 && atTheStart[0].offset.y < 0)
    #expect(abs(aQuarterOrbitIn[0].offset.y) < 0.001 && aQuarterOrbitIn[0].offset.x > 0)
}
