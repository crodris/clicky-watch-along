//
//  CursorLoopAgentSparkTests.swift
//  leanring-buddyTests
//
//  The sparks background agents lap around the loop: which agents work on the video in front, how an agent joins the
//  line and leaves it, what clears it, and the spark's pace and last lap.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

private let sparkTabURL = "https://www.youtube.com/watch?v=sparkVideo"

private func sparkSample(tabID: Int = 42, tabURL: String = sparkTabURL) -> FrontTabSample {
    FrontTabSample(
        windowID: 7, tabID: tabID, tabURL: tabURL,
        pageGeometry: ChromePageGeometry(
            screenX: 0, screenY: 0, outerWidth: 1400, outerHeight: 900, innerWidth: 1400, innerHeight: 800,
            devicePixelRatio: 2, left: 94, top: 120, width: 600, height: 338, imageSourceURL: nil
        )
    )
}

private func sparkMedia(tabURL: String = sparkTabURL) -> MediaOnTheFrontTab {
    MediaOnTheFrontTab(
        screenRect: ScreenRectInChromeCoordinates(rectX: 100, rectY: 120, rectWidth: 600, rectHeight: 338),
        sample: sparkSample(tabURL: tabURL)
    )
}

/// A turn whose release read the media and that handed off to nothing, as a voice command that only started an agent does.
private func stateHoldingTheMediaInHand() -> CursorLoopState {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 10)
    return state
}

// MARK: - Which agents work on the video in front

@Test func anAgentWorksOnTheVideoInFrontOnlyWhenItStartedFromTheTabStillInFront() {
    #expect(agentWorksOnTheVideoInFront(sourceTab: .tab(url: sparkTabURL), frontTabURL: sparkTabURL))
    #expect(!agentWorksOnTheVideoInFront(sourceTab: .tab(url: sparkTabURL), frontTabURL: "https://www.youtube.com/watch?v=another"))
    #expect(!agentWorksOnTheVideoInFront(sourceTab: .unknown, frontTabURL: sparkTabURL))
}

@Test func aGuideAgentWorksOnItsVideoWhateverElseTheFrontTabsURLHolds() {
    #expect(agentWorksOnTheVideoInFront(sourceTab: .youTubeVideo(key: "sparkVideo"), frontTabURL: sparkTabURL))
    #expect(agentWorksOnTheVideoInFront(sourceTab: .youTubeVideo(key: "sparkVideo"), frontTabURL: "https://www.youtube.com/watch?v=sparkVideo&t=95s&list=PL1"))
    #expect(!agentWorksOnTheVideoInFront(sourceTab: .youTubeVideo(key: "sparkVideo"), frontTabURL: "https://www.youtube.com/watch?v=another"))
}

@Test func eachAgentPhaseHasTheStatusTheLoopActsOn() {
    func agent(in phase: BackgroundAgentPhase) -> BackgroundAgent {
        BackgroundAgent(
            id: UUID(), kind: .task, subject: nil, studyGuideVideoKey: nil, startedAt: Date(), currentStepStartedAt: Date(),
            endedAt: nil, phase: phase
        )
    }
    #expect(agent(in: .running(completedStepCount: 0)).loopSparkStatus == .working)
    #expect(agent(in: .finished(.readyScene)).loopSparkStatus == .finished)
    #expect(agent(in: .failed(reason: "no")).loopSparkStatus == .endedWithoutFinishing)
    #expect(agent(in: .cancelled).loopSparkStatus == .endedWithoutFinishing)
}

// MARK: - How an agent joins the line

@Test func anAgentStartedFromTheVideoInFrontJoinsTheLineAroundTheMediaTheReleaseRead() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [agentID])))
    // The agent's line is not a request's loop, so no loop draws.
    #expect(state.loop == .hidden)
}

@Test func anAgentStartedFromAnotherTabOrWithNoMediaInHandJoinsNothing() {
    var otherTab = stateHoldingTheMediaInHand()
    otherTab.agentStarted(id: UUID(), sourceTab: .tab(url: "https://www.youtube.com/watch?v=another"))
    #expect(otherTab.agentLine == .hidden)

    var noMedia = CursorLoopState()
    noMedia.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    #expect(noMedia.agentLine == .hidden)

    var mediaRead = CursorLoopState()
    mediaRead.pushToTalkWasReleased()
    mediaRead.mediaRectArrived(nil, at: 10)
    mediaRead.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    #expect(mediaRead.agentLine == .hidden)
}

@Test func anAgentStartedAfterTheNextPressNoLongerHasTheOldRect() {
    var state = stateHoldingTheMediaInHand()
    state.pushToTalkWasPressed()
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    #expect(state.agentLine == .hidden)
}

@Test func anAgentStartedUnderAShowingLoopLapsTheSameMedia() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 10)
    state.requestBecameALookAtTheMedia(at: 10.1)
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [agentID])))
    #expect(state.loopIsShowing)
}

@Test func severalAgentsOnOneVideoShareOneLineInTheOrderTheyJoined() {
    var state = stateHoldingTheMediaInHand()
    let firstAgentID = UUID()
    let secondAgentID = UUID()
    state.agentStarted(id: firstAgentID, sourceTab: .tab(url: sparkTabURL))
    // The next press clears the rect in hand, so the second agent joins the line that already shows.
    state.pushToTalkWasPressed()
    state.agentStarted(id: secondAgentID, sourceTab: .youTubeVideo(key: "sparkVideo"))
    state.agentStarted(id: secondAgentID, sourceTab: .youTubeVideo(key: "sparkVideo"))
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [firstAgentID, secondAgentID])))
}

@Test func anAgentFromAnotherTabStartsAFreshLineInsteadOfJoiningTheOldOne() {
    var state = stateHoldingTheMediaInHand()
    let firstAgentID = UUID()
    state.agentStarted(id: firstAgentID, sourceTab: .tab(url: sparkTabURL))
    let otherTabURL = "https://www.youtube.com/watch?v=another"
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(tabURL: otherTabURL), at: 20)
    let secondAgentID = UUID()
    state.agentStarted(id: secondAgentID, sourceTab: .tab(url: otherTabURL))
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(tabURL: otherTabURL), agentIDs: [secondAgentID])))
}

// MARK: - When the line clears

@Test(arguments: CursorLoopEndReason.allCases)
func onlyAChangeOfWhatIsInFrontClearsTheAgentLine(reason: CursorLoopEndReason) {
    var state = stateHoldingTheMediaInHand()
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    state.end(because: reason)
    let reasonsThatChangeWhatIsInFront: [CursorLoopEndReason] = [.scrolled, .tabOrMediaChanged, .appSwitched, .aSceneStartedToShow]
    #expect(state.agentLineIsShowing == !reasonsThatChangeWhatIsInFront.contains(reason))
}

@Test func theLastAgentToLeaveFadesTheLineAndTheFadeHidesIt() {
    var state = stateHoldingTheMediaInHand()
    let firstAgentID = UUID()
    let secondAgentID = UUID()
    state.agentStarted(id: firstAgentID, sourceTab: .tab(url: sparkTabURL))
    state.agentStarted(id: secondAgentID, sourceTab: .tab(url: sparkTabURL))
    state.agentLeavesTheLine(id: UUID())
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [firstAgentID, secondAgentID])))
    state.agentLeavesTheLine(id: firstAgentID)
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [secondAgentID])))
    state.agentLeavesTheLine(id: secondAgentID)
    #expect(state.agentLine == .fadingOut(AgentSparkLine(media: sparkMedia(), agentIDs: [])))
    state.agentLineFadeOutFinished()
    #expect(state.agentLine == .hidden)
}

@Test func theFrontTabPollStopsWatchingAnAgentLineOnceItFades() {
    var state = stateHoldingTheMediaInHand()
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    #expect(state.mediaThePollWatches == sparkMedia())
    state.end(because: .scrolled)
    #expect(state.mediaThePollWatches == nil)
}

// MARK: - The spark's pace

@Test func theSparkLapsInFourSecondsAtNoProgressAndInOnePointTwoAtFullProgress() {
    #expect(abs(AgentSparkTimeline.secondsPerLap(atProgress: 0) - 4.0) < 0.000001)
    #expect(abs(AgentSparkTimeline.secondsPerLap(atProgress: 1) - 1.2) < 0.000001)
    #expect(abs(AgentSparkTimeline.secondsPerLap(atProgress: 0.5) - 2.6) < 0.000001)
}

@Test func aProgressOutsideZeroToOneCountsAsTheNearestEnd() {
    #expect(AgentSparkTimeline.secondsPerLap(atProgress: -3) == AgentSparkTimeline.secondsPerLap(atProgress: 0))
    #expect(AgentSparkTimeline.secondsPerLap(atProgress: 7) == AgentSparkTimeline.secondsPerLap(atProgress: 1))
    #expect(AgentSparkTimeline.secondsPerLap(atProgress: .nan) == AgentSparkTimeline.secondsPerLap(atProgress: 0))
}

@Test func theSparkTakesOneLapInTheTimeItsProgressGives() {
    var slowSpark = AgentSparkPhase()
    slowSpark.advance(to: 100, agentProgress: 0, agentHasFinished: false)
    slowSpark.advance(to: 104, agentProgress: 0, agentHasFinished: false)
    #expect(abs(slowSpark.laps - 1) < 0.000001)

    var fastSpark = AgentSparkPhase()
    fastSpark.advance(to: 100, agentProgress: 1, agentHasFinished: false)
    fastSpark.advance(to: 101.2, agentProgress: 1, agentHasFinished: false)
    #expect(abs(fastSpark.laps - 1) < 0.000001)
}

@Test func theSparkSpeedsUpAsTheProgressGrowsWithoutJumping() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 0, agentHasFinished: false)
    spark.advance(to: 1, agentProgress: 0, agentHasFinished: false)
    let lapsInTheFirstSecond = spark.laps
    spark.advance(to: 2, agentProgress: 0.9, agentHasFinished: false)
    let lapsInTheSecondSecond = spark.laps - lapsInTheFirstSecond
    #expect(lapsInTheSecondSecond > lapsInTheFirstSecond)
    // Each step starts where the last one ended, so a change of progress never moves the spark itself.
    #expect(abs(spark.laps - (lapsInTheFirstSecond + lapsInTheSecondSecond)) < 0.000001)
}

@Test func theFirstAdvanceOnlyRecordsTheTime() {
    var spark = AgentSparkPhase(startingLaps: 0.25)
    spark.advance(to: 500, agentProgress: 0.5, agentHasFinished: false)
    #expect(spark.laps == 0.25)
}

@Test func aFinishedAgentsLapRunsAtTheFastestPaceWhateverProgressItIsGiven() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 0, agentHasFinished: true)
    spark.advance(to: AgentSparkTimeline.secondsAFinishingLapTakesAtMost + 0.001, agentProgress: 0, agentHasFinished: true)
    #expect(spark.hasCompletedItsLastLap)
}

@Test func theAgentsThatJoinedTogetherStartInDifferentPlacesAroundTheLine() {
    let startingPlaces = (0..<4).map { AgentSparkTimeline.startingLaps(forAgentNumber: $0) }
    #expect(startingPlaces == [0, 0.25, 0.5, 0.75])
    #expect(Set(startingPlaces).count == 4)
}

// MARK: - The last lap

@Test func aFinishedAgentsSparkCompletesTheLapItIsOnAtTheFastestPaceThenStops() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 0.2, agentHasFinished: false)
    spark.advance(to: 2, agentProgress: 0.2, agentHasFinished: false)
    #expect(!spark.hasCompletedItsLastLap)
    let lapsAtTheFinish = spark.laps
    #expect(lapsAtTheFinish > 0.5 && lapsAtTheFinish < 1)

    spark.advance(to: 2.1, agentProgress: 1, agentHasFinished: true)
    #expect(spark.stopsAtLap == 1)
    #expect(!spark.hasCompletedItsLastLap)
    // The rest of the lap takes under 1.2 seconds, however far the spark was.
    spark.advance(to: 2.1 + AgentSparkTimeline.secondsAFinishingLapTakesAtMost + 0.001, agentProgress: 1, agentHasFinished: true)
    #expect(spark.hasCompletedItsLastLap)
    #expect(spark.laps == 1)
}

@Test func aFinishedAgentsSparkStopsAtTheLapAndNeverRunsPastIt() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: true)
    spark.advance(to: 60, agentProgress: 1, agentHasFinished: true)
    #expect(spark.laps == 1)
    #expect(spark.hasCompletedItsLastLap)
}

@Test func aSparkAtTheStartOfALapWhenTheAgentFinishesStillGetsAFullLap() {
    var spark = AgentSparkPhase(startingLaps: 3)
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: true)
    #expect(spark.stopsAtLap == 4)
    #expect(!spark.hasCompletedItsLastLap)
}

@Test func aSparkThatIsStillWorkingNeverCompletesItsLastLap() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: false)
    spark.advance(to: 600, agentProgress: 1, agentHasFinished: false)
    #expect(!spark.hasCompletedItsLastLap)
    #expect(spark.stopsAtLap == nil)
}

// MARK: - The controller

/// A controller that reads the media from a fixed front tab, with a finishing lap that ends at once.
@MainActor
private func controllerWithTheMediaInHand(
    readTheFrontTabSample: @escaping () -> FrontTabSample? = { sparkSample() }
) async -> CursorLoopController {
    let controller = CursorLoopController(
        readTheMediaInTheFrontTab: { _ in sparkMedia() },
        readTheFrontTabSample: readTheFrontTabSample,
        waitBetweenFrontTabPolls: { await Task.yield() },
        waitForAFinishingSparkLap: {}
    )
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    return controller
}

@Test(.timeLimit(.minutes(1))) @MainActor func aFinishedAgentsSparkLeavesTheLineAfterItsLastLapAndTheLineFades() async {
    let controller = await controllerWithTheMediaInHand()
    let agentID = UUID()
    controller.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    #expect(controller.state.agentLineIsShowing)

    controller.agentStatusesChanged([agentID: .working])
    #expect(controller.state.agentLineIsShowing)

    controller.agentStatusesChanged([agentID: .finished])
    await controller.waitForTheFinishingLapsToEnd()
    #expect(!controller.state.agentLineIsShowing)
    #expect(controller.state.agentLineOnTheMedia?.isFadingOut == true)
}

@Test(.timeLimit(.minutes(1))) @MainActor func anAgentThatFailedOrLeftTheStoreLeavesTheLineAtOnce() async {
    let controller = await controllerWithTheMediaInHand()
    let failedAgentID = UUID()
    let removedAgentID = UUID()
    controller.agentStarted(id: failedAgentID, sourceTab: .tab(url: sparkTabURL))
    controller.agentStarted(id: removedAgentID, sourceTab: .tab(url: sparkTabURL))

    controller.agentStatusesChanged([failedAgentID: .endedWithoutFinishing, removedAgentID: .working])
    #expect(controller.state.agentLineOnTheMedia?.line.agentIDs == [removedAgentID])

    // An agent the store no longer lists was cancelled and pruned.
    controller.agentStatusesChanged([:])
    #expect(!controller.state.agentLineIsShowing)
}

@Test(.timeLimit(.minutes(1))) @MainActor func theFrontTabPollClearsTheAgentLineWhenTheTabChanges() async {
    let controller = await controllerWithTheMediaInHand(readTheFrontTabSample: { sparkSample(tabID: 99) })
    controller.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    await controller.waitForThePollToEndTheLoop()
    #expect(!controller.state.agentLineIsShowing)
}

@Test(.timeLimit(.minutes(1))) @MainActor func theAgentLineSurvivesAPushToTalkPressAndTheAnswerSpeaking() async {
    let controller = await controllerWithTheMediaInHand()
    controller.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    controller.pushToTalkWasPressed()
    controller.voiceStateChanged(to: .responding, aStatusLabelIsShowing: false)
    #expect(controller.state.agentLineIsShowing)
}

@Test(.timeLimit(.minutes(1))) @MainActor func aFinishedAgentStartsItsLastLapOnceHoweverOftenTheStoreChanges() async {
    final class LapWaits { var started = 0 }
    let lapWaits = LapWaits()
    let controller = CursorLoopController(
        readTheMediaInTheFrontTab: { _ in sparkMedia() },
        readTheFrontTabSample: { sparkSample() },
        waitBetweenFrontTabPolls: { await Task.yield() },
        waitForAFinishingSparkLap: { lapWaits.started += 1 }
    )
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    let agentID = UUID()
    controller.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    // The agent store publishes on every change, so a finished agent is reported again until its spark has gone.
    controller.agentStatusesChanged([agentID: .finished])
    controller.agentStatusesChanged([agentID: .finished])
    controller.agentStatusesChanged([agentID: .finished])
    await controller.waitForTheFinishingLapsToEnd()
    #expect(lapWaits.started == 1)
}

@Test(.timeLimit(.minutes(1))) @MainActor func theFrontAppChangingClearsTheAgentLine() async throws {
    // This controller listens to a center of its own, so the post reaches no other test's controller.
    let workspaceNotificationCenter = NotificationCenter()
    let controller = CursorLoopController(
        readTheMediaInTheFrontTab: { _ in sparkMedia() },
        readTheFrontTabSample: { sparkSample() },
        waitBetweenFrontTabPolls: { await Task.yield() },
        waitForAFinishingSparkLap: {},
        workspaceNotificationCenter: workspaceNotificationCenter
    )
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    controller.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    // The next press clears the turn's rect, so only the agent line is left for the front app change to clear.
    controller.pushToTalkWasPressed()
    #expect(controller.state.agentLineIsShowing)
    // The test host is not Chrome, so activating it is the front app changing to something else.
    workspaceNotificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current]
    )
    for _ in 0..<500 where controller.state.agentLineIsShowing {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!controller.state.agentLineIsShowing)
}

@Test(.timeLimit(.minutes(1))) @MainActor func aScrollClearsTheAgentLineEvenWhenNoLoopOrTurnIsWaiting() async {
    let controller = await controllerWithTheMediaInHand()
    controller.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    controller.pushToTalkWasPressed()
    controller.end(because: .scrolled)
    #expect(!controller.state.agentLineIsShowing)
}
