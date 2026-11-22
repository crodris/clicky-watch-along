//
//  CursorScrubTests.swift
//  leanring-buddyTests
//
//  Scrub by voice: the line a voice seek slides the cursor along, and the wait that holds the seek until the cursor
//  arrives, a press lands it, or the wait times out.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

/// A clock the test fires by hand, so a timeout happens exactly when the test says.
@MainActor
private final class HandFiredClock {
    private var waitingSleeps: [CheckedContinuation<Void, Never>] = []

    func sleep(_ seconds: Double) async {
        await withCheckedContinuation { continuation in waitingSleeps.append(continuation) }
    }

    /// Fires once a sleep has started, since the timeout's task may not have run yet.
    func fireOnceASleepWaits() async {
        while waitingSleeps.isEmpty { await Task.yield() }
        fire()
    }

    func fire() {
        let sleepsToEnd = waitingSleeps
        waitingSleeps = []
        sleepsToEnd.forEach { continuation in continuation.resume() }
    }
}

@MainActor
struct CursorScrubTests {
    private let youTubeLine = VideoScrubLine(
        startPoint: CGPoint(x: 100, y: 300),
        endPoint: CGPoint(x: 900, y: 300),
        durationSeconds: 400,
        currentSeconds: 100,
        followsTheProgressBar: true
    )
    private let mainDisplay = CGRect(x: 0, y: 0, width: 1440, height: 900)

    // MARK: - The line

    @Test func aTimeMapsToItsShareOfTheLine() {
        #expect(youTubeLine.point(atSeconds: 0) == CGPoint(x: 100, y: 300))
        #expect(youTubeLine.point(atSeconds: 200) == CGPoint(x: 500, y: 300))
        #expect(youTubeLine.point(atSeconds: 400) == CGPoint(x: 900, y: 300))
    }

    @Test func aTimeOutsideTheVideoStaysAtTheLinesEnds() {
        #expect(youTubeLine.point(atSeconds: 9_000) == CGPoint(x: 900, y: 300))
        #expect(youTubeLine.point(atSeconds: -30) == CGPoint(x: 100, y: 300))
        #expect(youTubeLine.point(atSeconds: .nan) == CGPoint(x: 100, y: 300))
    }

    private func scriptReply(width: Double = 800, durationSeconds: Double = 400, followsTheProgressBar: Bool = true) -> String {
        """
        {"screenX":0,"screenY":25,"outerWidth":1440,"outerHeight":875,"innerWidth":1440,"innerHeight":790,"devicePixelRatio":2,\
        "left":120,"top":600,"width":\(width),"height":0,"imageSourceURL":null,\
        "currentSeconds":61.5,"durationSeconds":\(durationSeconds),"followsTheProgressBar":\(followsTheProgressBar)}
        """
    }

    /// Places the page box 110 points below the main display's top, as Chrome's toolbar would.
    private func placeBelowTheToolbar(_ pageGeometry: ChromePageGeometry) -> ScreenRectInChromeCoordinates? {
        ScreenRectInChromeCoordinates(rectX: pageGeometry.left, rectY: 110 + pageGeometry.top, rectWidth: pageGeometry.width, rectHeight: pageGeometry.height)
    }

    @Test func theScriptReplyBecomesALineInAppKitPoints() throws {
        let scrubLine = try #require(videoScrubLine(fromScriptReply: scriptReply(), mainDisplayHeight: 900, screenRect: placeBelowTheToolbar))
        // 900 - (110 + 600) is 190 points up from the bottom of the main display.
        #expect(scrubLine.startPoint == CGPoint(x: 120, y: 190))
        #expect(scrubLine.endPoint == CGPoint(x: 920, y: 190))
        #expect(scrubLine.currentSeconds == 61.5)
        #expect(scrubLine.durationSeconds == 400)
        #expect(scrubLine.followsTheProgressBar)
    }

    @Test func aPageWithNoLineToSlideAlongGivesNone() {
        #expect(videoScrubLine(fromScriptReply: "no-video", mainDisplayHeight: 900, screenRect: placeBelowTheToolbar) == nil)
        #expect(videoScrubLine(fromScriptReply: "off-screen", mainDisplayHeight: 900, screenRect: placeBelowTheToolbar) == nil)
        // A live stream or a video still loading has no length to map a time onto.
        #expect(videoScrubLine(fromScriptReply: scriptReply(durationSeconds: 0), mainDisplayHeight: 900, screenRect: placeBelowTheToolbar) == nil)
        #expect(videoScrubLine(fromScriptReply: scriptReply(width: 30), mainDisplayHeight: 900, screenRect: placeBelowTheToolbar) == nil)
        #expect(videoScrubLine(fromScriptReply: scriptReply(), mainDisplayHeight: 900) { _ in nil } == nil)
    }

    private let conditionsThatScrub = CursorScrubConditions(chromeIsTheFrontApp: true, cursorIsPointing: false, sceneIsOnScreen: false, commandWasCancelled: false)

    @Test func theLineIsReadWhenNothingStandsInTheWay() {
        #expect(scrubLineToPlay(conditionsThatScrub) { youTubeLine } == youTubeLine)
    }

    @Test(arguments: [
        \CursorScrubConditions.chromeIsTheFrontApp,
        \CursorScrubConditions.cursorIsPointing,
        \CursorScrubConditions.sceneIsOnScreen,
        \CursorScrubConditions.commandWasCancelled,
    ])
    func eachConditionThatStandsInTheWaySeeksAtOnceWithoutReadingTheLine(condition: WritableKeyPath<CursorScrubConditions, Bool>) {
        var conditions = conditionsThatScrub
        conditions[keyPath: condition].toggle()
        var readCount = 0
        #expect(scrubLineToPlay(conditions) { readCount += 1; return youTubeLine } == nil)
        #expect(readCount == 0)
    }

    @Test func theSeekMovesOnlyThePageTheScrubWasFor() throws {
        let volcanoTab = ChromeVideoTab(windowId: 1, tabId: 7, url: "https://www.youtube.com/watch?v=p1eE93vybrc", title: "Volcano")
        let sameTabWithANewTitle = ChromeVideoTab(windowId: 1, tabId: 7, url: "https://www.youtube.com/watch?v=p1eE93vybrc", title: "(1) Volcano")
        let nextVideoAutoplayedInTheSameTab = ChromeVideoTab(windowId: 1, tabId: 7, url: "https://www.youtube.com/watch?v=next", title: "Next")
        let tabToSeek = try tabToSeekAfterTheScrub(checkedTab: volcanoTab, tabInFrontNow: sameTabWithANewTitle)
        #expect(tabToSeek.title == "Volcano")
        #expect(throws: VideoQuizFailure.self) {
            try tabToSeekAfterTheScrub(checkedTab: volcanoTab, tabInFrontNow: nextVideoAutoplayedInTheSameTab)
        }
    }

    @Test func reduceMotionFadesInAtTheMomentWithNoTravel() {
        #expect(cursorScrubMotion(reduceMotionIsOn: false) == .flyThenSlide)
        #expect(cursorScrubMotion(reduceMotionIsOn: true) == .fadeAtTheMoment)
    }

    /// The script runs only in Chrome, so this pins the order of its checks in the source: every reply that gives no line
    /// returns before the script wakes YouTube's controls for 6 seconds.
    @Test func thePageScriptWakesTheControlsOnlyAfterEveryCheckThatGivesNoLine() throws {
        let wakePosition = try #require(videoScrubLineJavaScript.range(of: "wakeTheControls();")).lowerBound
        for markerOfNoLine in ["'no-video'", "'off-screen'", "'no-length'"] {
            let markerPosition = try #require(videoScrubLineJavaScript.range(of: markerOfNoLine)).lowerBound
            #expect(markerPosition < wakePosition, "\(markerOfNoLine) returns after the wake")
        }
    }

    @Test func thePageScriptHoldsNoCharacterThatBreaksItsAppleScriptString() {
        #expect(!videoScrubLineJavaScript.contains("\""))
        #expect(!videoScrubLineJavaScript.contains("\\"))
    }

    // MARK: - The wait before the seek

    /// Starts a scrub to `targetSeconds` and returns its task once the overlay can see the request.
    private func startAScrub(
        on scrubController: CursorScrubController,
        toSeconds targetSeconds: Double = 300,
        scrubLine: VideoScrubLine? = nil
    ) async -> Task<CursorScrubOutcome, Never> {
        let lineToScrub = scrubLine ?? youTubeLine
        let displayFrames = [mainDisplay]
        let scrubTask = Task { await scrubController.scrubBeforeTheSeek(along: lineToScrub, toSeconds: targetSeconds, displayFrames: displayFrames, timeoutSeconds: 3) }
        while scrubController.request == nil { await Task.yield() }
        return scrubTask
    }

    @Test func withNoLineTheSeekRunsAtOnceAndNothingFlies() async {
        let scrubController = CursorScrubController(sleep: { _ in })
        let outcome = await scrubController.scrubBeforeTheSeek(along: nil, toSeconds: 300, displayFrames: [mainDisplay], timeoutSeconds: 3)
        #expect(outcome == .noScrubLine)
        #expect(scrubController.request == nil)
    }

    @Test func aLineAcrossTwoDisplaysFliesNowhere() async {
        let scrubController = CursorScrubController(sleep: { _ in })
        let secondDisplay = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        // The current time sits on the main display and the moment on the second one.
        let lineAcrossTwoDisplays = VideoScrubLine(startPoint: CGPoint(x: 1000, y: 300), endPoint: CGPoint(x: 2400, y: 300), durationSeconds: 400, currentSeconds: 20, followsTheProgressBar: true)
        let outcome = await scrubController.scrubBeforeTheSeek(along: lineAcrossTwoDisplays, toSeconds: 390, displayFrames: [mainDisplay, secondDisplay], timeoutSeconds: 3)
        #expect(outcome == .noScrubLine)
        #expect(scrubController.request == nil)
    }

    @Test func aMomentOnNoDisplayFliesNowhere() async {
        let scrubController = CursorScrubController(sleep: { _ in })
        let lineOnAGoneDisplay = VideoScrubLine(startPoint: CGPoint(x: 2000, y: 300), endPoint: CGPoint(x: 2800, y: 300), durationSeconds: 400, currentSeconds: 0, followsTheProgressBar: true)
        let outcome = await scrubController.scrubBeforeTheSeek(along: lineOnAGoneDisplay, toSeconds: 300, displayFrames: [mainDisplay], timeoutSeconds: 3)
        #expect(outcome == .noScrubLine)
        #expect(scrubController.request == nil)
    }

    @Test func theRequestStartsAtTheCurrentTimeAndEndsAtTheMoment() async throws {
        let clock = HandFiredClock()
        let scrubController = CursorScrubController(sleep: clock.sleep)
        let scrubTask = await startAScrub(on: scrubController, toSeconds: 300)
        let scrubRequest = try #require(scrubController.request)
        #expect(scrubRequest.startPoint == CGPoint(x: 300, y: 300))
        #expect(scrubRequest.momentPoint == CGPoint(x: 700, y: 300))
        #expect(scrubRequest.displayFrame == mainDisplay)
        scrubController.cursorReachedTheMoment(scrubID: scrubRequest.scrubID)
        #expect(await scrubTask.value == .reachedTheMoment)
    }

    @Test func theSeekWaitsForTheCursorAndTheCursorStaysForItsFlightBack() async throws {
        let clock = HandFiredClock()
        let scrubController = CursorScrubController(sleep: clock.sleep)
        let scrubTask = await startAScrub(on: scrubController)
        let scrubRequest = try #require(scrubController.request)
        // An arrival from an older scrub is not this one's.
        scrubController.cursorReachedTheMoment(scrubID: UUID())
        scrubController.cursorReachedTheMoment(scrubID: scrubRequest.scrubID)
        #expect(await scrubTask.value == .reachedTheMoment)
        // A timeout after the arrival leaves the cursor to hold at the moment and fly back.
        await clock.fireOnceASleepWaits()
        await Task.yield()
        #expect(scrubController.request == scrubRequest)
        scrubController.overlayFinished(scrubID: scrubRequest.scrubID)
        #expect(scrubController.request == nil)
    }

    @Test func aPressLandsTheScrubAtOnce() async {
        let scrubController = CursorScrubController(sleep: HandFiredClock().sleep)
        let scrubTask = await startAScrub(on: scrubController)
        scrubController.landAtOnce()
        #expect(await scrubTask.value == .landedAtOnce)
        #expect(scrubController.request == nil)
    }

    @Test func aCancelledVoiceCommandLandsTheScrubAtOnce() async {
        let scrubController = CursorScrubController(sleep: HandFiredClock().sleep)
        let scrubTask = await startAScrub(on: scrubController)
        scrubTask.cancel()
        #expect(await scrubTask.value == .landedAtOnce)
        #expect(scrubController.request == nil)
    }

    @Test func anOverlayThatNeverArrivesTimesOutSoTheSeekStillRuns() async {
        let clock = HandFiredClock()
        let scrubController = CursorScrubController(sleep: clock.sleep)
        let scrubTask = await startAScrub(on: scrubController)
        await clock.fireOnceASleepWaits()
        #expect(await scrubTask.value == .timedOut)
        #expect(scrubController.request == nil)
    }

    @Test func aNewerScrubReplacesOneStillOnItsWay() async throws {
        let scrubController = CursorScrubController(sleep: HandFiredClock().sleep)
        let firstScrubTask = await startAScrub(on: scrubController, toSeconds: 300)
        let firstRequest = try #require(scrubController.request)
        let secondScrubTask = Task { await scrubController.scrubBeforeTheSeek(along: youTubeLine, toSeconds: 20, displayFrames: [mainDisplay], timeoutSeconds: 3) }
        #expect(await firstScrubTask.value == .replaced)
        while scrubController.request == firstRequest { await Task.yield() }
        let secondRequest = try #require(scrubController.request)
        // The first scrub's overlay giving up must not take the second one away.
        scrubController.overlayFinished(scrubID: firstRequest.scrubID)
        #expect(scrubController.request == secondRequest)
        scrubController.cursorReachedTheMoment(scrubID: secondRequest.scrubID)
        #expect(await secondScrubTask.value == .reachedTheMoment)
    }

    @Test func aPointingThatTakesOverBeforeTheArrivalLetsTheSeekRun() async throws {
        let scrubController = CursorScrubController(sleep: HandFiredClock().sleep)
        let scrubTask = await startAScrub(on: scrubController)
        let scrubRequest = try #require(scrubController.request)
        scrubController.overlayFinished(scrubID: scrubRequest.scrubID)
        #expect(await scrubTask.value == .replaced)
        #expect(scrubController.request == nil)
    }
}
