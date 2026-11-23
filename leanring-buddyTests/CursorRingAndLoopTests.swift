//
//  CursorRingAndLoopTests.swift
//  leanring-buddyTests
//
//  The ring around the cursor and the loop around the media Clicky is looking at: when a request draws a loop and
//  when it clears, the loop's outline, the lap's pace and the shimmer's slowdown, and the ring's ticks and dots.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Clicky

private func exampleGeometry(left: Double = 94, devicePixelRatio: Double = 2) -> ChromePageGeometry {
    ChromePageGeometry(
        screenX: 0, screenY: 0, outerWidth: 1400, outerHeight: 900, innerWidth: 1400, innerHeight: 800,
        devicePixelRatio: devicePixelRatio, left: left, top: 120, width: 600, height: 338, imageSourceURL: nil
    )
}

private let exampleTabURL = "https://www.youtube.com/watch?v=example"

private func exampleSample(tabID: Int = 42, tabURL: String = exampleTabURL, left: Double = 94, devicePixelRatio: Double = 2) -> FrontTabSample {
    FrontTabSample(windowID: 7, tabID: tabID, tabURL: tabURL, pageGeometry: exampleGeometry(left: left, devicePixelRatio: devicePixelRatio))
}

private let exampleMedia = MediaOnTheFrontTab(
    screenRect: ScreenRectInChromeCoordinates(rectX: 100, rectY: 120, rectWidth: 600, rectHeight: 338),
    sample: exampleSample()
)

/// A turn that reached the hand-off with the rect already back, which draws the loop at `now`.
private func stateShowingALoop(since now: TimeInterval = 10) -> CursorLoopState {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(exampleMedia, at: now - 1, agentsMayJoinTheLine: true)
    state.requestBecameALookAtTheMedia(at: now)
    return state
}

// MARK: - When a request draws a loop

@Test func aRequestThatBecomesALookDrawsTheLoopWhenTheRectIsAlreadyInHand() {
    let state = stateShowingALoop(since: 10)
    #expect(state.loop == .showing(.media(exampleMedia), since: 10, shimmerSlowsAt: nil))
    #expect(state.turn == .notWaitingForALoop)
}

@Test func aRectThatArrivesWithinTheHandOffWindowStillDrawsTheLoop() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 10)
    #expect(!state.loopIsShowing)
    // A quarter second after the hand-off is inside the 300 ms window.
    state.mediaRectArrived(exampleMedia, at: 10.25, agentsMayJoinTheLine: true)
    #expect(state.loop == .showing(.media(exampleMedia), since: 10.25, shimmerSlowsAt: nil))
}

@Test func aRectThatArrivesAfterTheHandOffWindowDrawsNothing() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 10)
    state.mediaRectArrived(exampleMedia, at: 10.31, agentsMayJoinTheLine: true)
    #expect(state.loop == .hidden)
    #expect(state.turn == .notWaitingForALoop)
}

@Test func onlyTheFirstHandOffOfATurnStartsTheHandOffWindow() {
    // A later hand-off must not move the window, or a rect that missed the first one would still draw.
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 10)
    state.requestBecameALookAtTheMedia(at: 11)
    state.mediaRectArrived(exampleMedia, at: 11.2, agentsMayJoinTheLine: true)
    #expect(state.loop == .hidden)
}

@Test func aTurnThatNeverHandsOffNeverDrawsALoop() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(exampleMedia, at: 10, agentsMayJoinTheLine: true)
    #expect(state.loop == .hidden)
    // The rect stays unused until the turn ends. A later hand-off from a different turn must not reuse it.
    state.pushToTalkWasPressed()
    state.requestBecameALookAtTheMedia(at: 20)
    #expect(state.loop == .hidden)
}

@Test func onlyTheRoutersLookAtTheMediaToolsHandOff() {
    let toolsThatHandOff = AppVoiceTool.allCases.filter(\.handsOffToALookAtTheMedia)
    // animate_picture pops the picture out like pop_out, so it looks at the media too, and show_art_in_my_room reads the
    // picture it hangs on the learner's wall.
    #expect(Set(toolsThatHandOff) == [.answerWithScreen, .buildNewScene, .popOut, .animatePicture, .showArtInMyRoom])
}

@Test func aMissingMediaRectDrawsNothing() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(nil, at: 10, agentsMayJoinTheLine: true)
    state.requestBecameALookAtTheMedia(at: 10.1)
    #expect(state.loop == .hidden)
}

@Test func aHandOffWithNoReleasedTurnDrawsNothing() {
    var state = CursorLoopState()
    state.requestBecameALookAtTheMedia(at: 10)
    state.mediaRectArrived(exampleMedia, at: 10.1, agentsMayJoinTheLine: true)
    #expect(state.loop == .hidden)
}

// MARK: - When a loop clears

@Test(arguments: CursorLoopEndReason.allCases)
func eachEndEventFadesAShowingLoop(reason: CursorLoopEndReason) {
    var state = stateShowingALoop(since: 10)
    state.end(because: reason)
    #expect(state.loop == .fadingOut(.media(exampleMedia), since: 10, shimmerSlowsAt: nil))
    #expect(!state.loopIsShowing)
    state.fadeOutFinished()
    #expect(state.loop == .hidden)
}

@Test(arguments: CursorLoopEndReason.allCases)
func eachEndEventStopsARectInHandFromDrawingLater(reason: CursorLoopEndReason) {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(exampleMedia, at: 10, agentsMayJoinTheLine: true)
    state.end(because: reason)
    state.requestBecameALookAtTheMedia(at: 10.5)
    #expect(state.loop == .hidden)
}

@Test func theVoiceStateEndsALoopOnlyWhenClickyStopsThinkingOrSpeaksAnAnswer() {
    #expect(cursorLoopEndReason(forVoiceState: .processing, aStatusLabelIsShowing: false) == nil)
    #expect(cursorLoopEndReason(forVoiceState: .listening, aStatusLabelIsShowing: false) == .newPushToTalk)
    #expect(cursorLoopEndReason(forVoiceState: .idle, aStatusLabelIsShowing: false) == .thinkingStopped)
    #expect(cursorLoopEndReason(forVoiceState: .responding, aStatusLabelIsShowing: false) == .speechStarted)
    // "Sure, let me build that for you" is spoken under the loop, which stays through the build.
    #expect(cursorLoopEndReason(forVoiceState: .responding, aStatusLabelIsShowing: true) == nil)
}

/// A controller that reads `media` from the front tab instead of Chrome, with a turn waiting for a loop.
/// The poll sees the media's own sample unless a test passes `readTheFrontTabSample`, and a test that counts the poll's
/// waits passes `waitBetweenFrontTabPolls`. By default the poll waits until it is cancelled (`suspendUntilThePollIsCancelled`),
/// and an idle holds as soon as the controller's task runs, so no wait reads the clock of a busy machine. It hears app
/// switches on a center of its own by default, so an app that activates on the machine running the tests never ends a loop a
/// test is checking.
@MainActor
private func controllerWithATurnWaitingForALoop(
    reading media: MediaOnTheFrontTab?,
    readTheFrontTabSample: @escaping () -> FrontTabSample? = { exampleSample() },
    waitBetweenFrontTabPolls: @escaping () async -> Void = suspendUntilThePollIsCancelled,
    appActivationNotificationCenter: NotificationCenter = NotificationCenter()
) async -> CursorLoopController {
    let controller = CursorLoopController(
        readTheMediaInTheFrontTab: { _ in media },
        readTheFrontTabSample: readTheFrontTabSample,
        waitBetweenFrontTabPolls: waitBetweenFrontTabPolls,
        waitForAnIdleToHold: {},
        appActivationNotificationCenter: appActivationNotificationCenter
    )
    controller.pushToTalkWasReleased()
    // The rect read runs as a task, so wait for it instead of guessing how long it takes.
    await controller.waitForTheMediaReadToFinish()
    return controller
}

@Test(.timeLimit(.minutes(1))) @MainActor func anIdleThatLastsThroughTheRouterCallDoesNotEndATurnWaitingForItsHandOff() async {
    // After a push-to-talk request the dictation session's idle lands after the request set processing, and the router
    // call that follows takes about a second before it hands off, so a turn still waiting for that hand-off must survive.
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia)
    controller.voiceStateChanged(to: .processing, aStatusLabelIsShowing: false)
    controller.voiceStateChanged(to: .idle, aStatusLabelIsShowing: false)
    await controller.waitForTheIdleHoldToFinish()
    controller.requestBecameALookAtTheMedia()
    #expect(controller.isShowingTheLoop)
}

@Test(.timeLimit(.minutes(1))) @MainActor func anIdleThatLastsOnlyAMomentDoesNotEndALoopThatIsShowing() async {
    // A plain keyword path request draws its loop at once, and the dictation session's idle lands just after.
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia)
    controller.requestBecameALookAtTheMedia()
    controller.voiceStateChanged(to: .idle, aStatusLabelIsShowing: false)
    controller.voiceStateChanged(to: .processing, aStatusLabelIsShowing: false)
    await controller.waitForTheIdleHoldToFinish()
    #expect(controller.isShowingTheLoop)
}

@Test(.timeLimit(.minutes(1))) @MainActor func anIdleThatHoldsEndsALoopThatIsShowing() async {
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia)
    controller.requestBecameALookAtTheMedia()
    #expect(controller.isShowingTheLoop)
    controller.voiceStateChanged(to: .idle, aStatusLabelIsShowing: false)
    await controller.waitForTheIdleHoldToFinish()
    #expect(!controller.isShowingTheLoop)
}

@Test(.timeLimit(.minutes(1))) @MainActor func aLoopDrawnAfterATabSwitchClearsAtOnceInsteadOfAfterASecond() async {
    // The learner switched tabs between the release and the hand-off, so the rect the loop would frame is stale.
    // The poll's waits are counted instead of timed, since a busy CI runner can hold the main actor past a whole poll
    // interval, and the first sample must end the loop before the poll's first wait.
    // The first sample shows the other tab and every later one fails, so a poll that wrongly waits or keeps the loop still
    // ends on its second sample, and the test fails instead of spinning on a wait that never suspends.
    final class PollCounts { var samplesRead = 0; var waitsTaken = 0 }
    let pollCounts = PollCounts()
    let controller = await controllerWithATurnWaitingForALoop(
        reading: exampleMedia,
        readTheFrontTabSample: {
            pollCounts.samplesRead += 1
            return pollCounts.samplesRead == 1 ? exampleSample(tabID: 99) : nil
        },
        waitBetweenFrontTabPolls: { pollCounts.waitsTaken += 1 }
    )
    controller.requestBecameALookAtTheMedia()
    await controller.waitForThePollToEndTheLoop()
    #expect(!controller.isShowingTheLoop)
    #expect(pollCounts.samplesRead == 1)
    #expect(pollCounts.waitsTaken == 0)
}

@Test(.timeLimit(.minutes(1))) @MainActor func theFrontAppChangingEndsALoopThatIsShowing() async {
    let appActivationNotificationCenter = NotificationCenter()
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia, appActivationNotificationCenter: appActivationNotificationCenter)
    controller.requestBecameALookAtTheMedia()
    #expect(controller.isShowingTheLoop)
    appActivationNotificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    #expect(!controller.isShowingTheLoop)
}

@Test(.timeLimit(.minutes(1))) @MainActor func anAppActivatingOnTheMachineDoesNotEndTheLoopOfAControllerWithItsOwnCenter() async {
    // The system posts this on the real workspace center whenever any app comes to the front, which a busy machine does
    // all the time, so a test controller must not hear it.
    let controller = await controllerWithATurnWaitingForALoop(reading: exampleMedia)
    controller.requestBecameALookAtTheMedia()
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
    #expect(controller.isShowingTheLoop)
}

@Test func aRequestDrawsALoopOnlyWhenNoSceneOrQuizQuestionOwnsTheScreen() {
    #expect(requestMayDrawALoop(aSceneIsOnScreen: false, aQuizQuestionIsOpen: false))
    #expect(!requestMayDrawALoop(aSceneIsOnScreen: true, aQuizQuestionIsOpen: false))
    #expect(!requestMayDrawALoop(aSceneIsOnScreen: false, aQuizQuestionIsOpen: true))
    #expect(!requestMayDrawALoop(aSceneIsOnScreen: true, aQuizQuestionIsOpen: true))
}

// MARK: - The shimmer under a build

@Test func theShimmerSlowsThreeSecondsIntoTheLoopWhenABuildStarts() {
    var buildStartedEarly = stateShowingALoop(since: 10)
    buildStartedEarly.aStatusLabelStartedShowing(at: 10.5)
    #expect(buildStartedEarly.loop == .showing(.media(exampleMedia), since: 10, shimmerSlowsAt: 13))

    var buildStartedLate = stateShowingALoop(since: 10)
    buildStartedLate.aStatusLabelStartedShowing(at: 15)
    #expect(buildStartedLate.loop == .showing(.media(exampleMedia), since: 10, shimmerSlowsAt: 15))
}

@Test func aLapTakes2Point2SecondsAnd4SecondsOnceItSlows() {
    #expect(CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 0, secondsWhenTheLapsSlow: nil) == 0)
    #expect(abs(CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 1.1, secondsWhenTheLapsSlow: nil) - 0.5) < 1e-9)
    #expect(abs(CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 2.2 + 0.55, secondsWhenTheLapsSlow: nil) - 0.25) < 1e-9)

    // Slowing at 3 seconds changes the pace from then on and never moves the lap at that moment.
    let justBeforeTheSlowdown = CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 3, secondsWhenTheLapsSlow: 3)
    let justAfterTheSlowdown = CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 3.0001, secondsWhenTheLapsSlow: 3)
    #expect(abs(justBeforeTheSlowdown - justAfterTheSlowdown) < 0.001)
    let aSlowLapLater = CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 3 + 4, secondsWhenTheLapsSlow: 3)
    #expect(abs(justBeforeTheSlowdown - aSlowLapLater) < 1e-9)
    // A slowdown that came before the laps began runs them slow from their start.
    #expect(abs(CursorLoopTimeline.lapShare(secondsSinceTheLapsBegan: 1, secondsWhenTheLapsSlow: -2) - 0.25) < 1e-9)
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
    // A tall portrait image, narrower than the offsets where a loop's line starts and its overshoot ends.
    CGRect(x: 40, y: 60, width: 40, height: 400),
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
    let startOffset = CursorLoopOutline.startOffsetFromTheLeftEdge(forLineWidth: lineRect.width)
    let overshootEndOffset = CursorLoopOutline.overshootEndOffsetFromTheLeftEdge(forLineWidth: lineRect.width)
    // A Path keeps single precision points, so these compare to within a thousandth of a point.
    #expect(abs(start.x - (lineRect.minX + startOffset)) < 0.001)
    #expect(abs((end.x - start.x) - (overshootEndOffset - startOffset)) < 0.001)
    // On a narrow media the overshoot still ends inside the line instead of sticking out of its right edge.
    #expect(end.x < lineRect.maxX)
    // The overshoot drifts about 2.8 points toward the media, never as far as the media's edge.
    #expect(end.y > lineRect.minY + 1)
    #expect(end.y < lineRect.minY + CursorLoopOutline.gapFromTheMediaInPoints)
}

@Test func theWobbleDependsOnlyOnTheRect() {
    let mediaRect = exampleMediaRects[0]
    let lineRect = mediaRect.insetBy(dx: -4, dy: -4)
    let seed = CursorLoopOutline.seed(for: mediaRect)
    #expect(CursorLoopOutline.path(along: lineRect, seed: seed) == CursorLoopOutline.path(along: lineRect, seed: seed))
    #expect(CursorLoopOutline.seed(for: mediaRect) == seed)
    #expect(seed != CursorLoopOutline.seed(for: exampleMediaRects[1]))
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
    #expect(exampleMedia.isTheSameMediaInTheSameTab(as: exampleSample(left: 95.5)))
    #expect(!exampleMedia.isTheSameMediaInTheSameTab(as: exampleSample(left: 97)))
    #expect(!exampleMedia.isTheSameMediaInTheSameTab(as: exampleSample(tabID: 43)))
    #expect(!exampleMedia.isTheSameMediaInTheSameTab(as: exampleSample(tabURL: "https://www.youtube.com/watch?v=another")))
    // A different page zoom moves everything, whatever the numbers add up to.
    #expect(!exampleMedia.isTheSameMediaInTheSameTab(as: exampleSample(devicePixelRatio: 3)))
}

// MARK: - The ring

@Test func theCueShowsTheRingOnlyWhileListeningOrThinkingWithNoLoop() {
    #expect(cursorCue(voiceState: .idle, loopIsShowing: false) == .idle)
    #expect(cursorCue(voiceState: .listening, loopIsShowing: false) == .listening)
    #expect(cursorCue(voiceState: .processing, loopIsShowing: false) == .thinkingWithDots)
    #expect(cursorCue(voiceState: .responding, loopIsShowing: false) == .speaking)
    // The loop's shimmer is the thinking light, so the dots stay away while it shows.
    #expect(cursorCue(voiceState: .processing, loopIsShowing: true) == .thinkingWithLoop)
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

@Test func underAStatusLineTheDotsNeverReachTheCalloutsBodyAndWithoutOneTheyOrbitAt24Points() {
    let dotRadius = CursorRingGeometry.dotDiameterInPoints / 2
    let calloutBodyRise = tetherCalloutTipRiseAboveTheCursor + TetherCalloutShape.tailHeight
    let orbitUnderAStatusLine = CursorRingGeometry.dotOrbitRadius(aStatusLineShows: true)
    // A whole orbit, sampled every 10 ms: the top edge of every dot stays under the Callout's body (y grows down).
    for sampleIndex in 0...120 {
        let placements = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: Double(sampleIndex) * 0.01, orbitRadius: orbitUnderAStatusLine)
        #expect(placements.allSatisfy { -($0.offset.y - dotRadius) < calloutBodyRise })
    }
    // The pulled-in orbit still clears the 16 point triangle at the center.
    #expect(orbitUnderAStatusLine - dotRadius > 8)
    #expect(CursorRingGeometry.dotOrbitRadius(aStatusLineShows: false) == 24)
}
