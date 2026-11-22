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
import SwiftUI
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
    state.mediaRectArrived(sparkMedia(), at: 10, agentsMayJoinTheLine: true)
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
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [agentID])))
    // The agent's line is not a request's loop, so no loop draws.
    #expect(state.loop == .hidden)
}

@Test func anAgentStartedFromAnotherTabOrWithNoMediaInHandJoinsNothing() {
    var otherTab = stateHoldingTheMediaInHand()
    otherTab.agentStarted(id: UUID(), sourceTab: .tab(url: "https://www.youtube.com/watch?v=another"), mayJoinTheLine: true)
    #expect(otherTab.agentLine == .hidden)

    var noMedia = CursorLoopState()
    noMedia.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(noMedia.agentLine == .hidden)

    var mediaRead = CursorLoopState()
    mediaRead.pushToTalkWasReleased()
    mediaRead.mediaRectArrived(nil, at: 10, agentsMayJoinTheLine: true)
    mediaRead.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(mediaRead.agentLine == .hidden)
}

@Test func anAgentStartedAfterTheNextPressNoLongerHasTheOldRect() {
    var state = stateHoldingTheMediaInHand()
    state.pushToTalkWasPressed()
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(state.agentLine == .hidden)
}

@Test func anAgentStartedUnderAShowingLoopLapsTheSameMedia() {
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 10, agentsMayJoinTheLine: true)
    state.requestBecameALookAtTheMedia(at: 10.1)
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [agentID])))
    #expect(state.loopIsShowing)
}

@Test func severalAgentsOnOneVideoShareOneLineInTheOrderTheyJoined() {
    var state = stateHoldingTheMediaInHand()
    let firstAgentID = UUID()
    let secondAgentID = UUID()
    state.agentStarted(id: firstAgentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    // The next press clears the rect in hand, so the second agent joins the line that already shows.
    state.pushToTalkWasPressed()
    state.agentStarted(id: secondAgentID, sourceTab: .youTubeVideo(key: "sparkVideo"), mayJoinTheLine: true)
    state.agentStarted(id: secondAgentID, sourceTab: .youTubeVideo(key: "sparkVideo"), mayJoinTheLine: true)
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [firstAgentID, secondAgentID])))
}

@Test func anAgentFromAnotherTabStartsAFreshLineInsteadOfJoiningTheOldOne() {
    var state = stateHoldingTheMediaInHand()
    let firstAgentID = UUID()
    state.agentStarted(id: firstAgentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    let otherTabURL = "https://www.youtube.com/watch?v=another"
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(tabURL: otherTabURL), at: 20, agentsMayJoinTheLine: true)
    let secondAgentID = UUID()
    state.agentStarted(id: secondAgentID, sourceTab: .tab(url: otherTabURL), mayJoinTheLine: true)
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(tabURL: otherTabURL), agentIDs: [secondAgentID])))
}

// MARK: - When the line clears

@Test(arguments: CursorLoopEndReason.allCases)
func onlyAChangeOfWhatIsInFrontClearsTheAgentLine(reason: CursorLoopEndReason) {
    var state = stateHoldingTheMediaInHand()
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.end(because: reason)
    let reasonsThatChangeWhatIsInFront: [CursorLoopEndReason] = [.scrolled, .tabOrMediaChanged, .appSwitched, .aSceneStartedToShow]
    #expect(state.agentLineIsShowing == !reasonsThatChangeWhatIsInFront.contains(reason))
}

@Test func theLastAgentToLeaveFadesTheLineAndTheFadeHidesIt() {
    var state = stateHoldingTheMediaInHand()
    let firstAgentID = UUID()
    let secondAgentID = UUID()
    state.agentStarted(id: firstAgentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.agentStarted(id: secondAgentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
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
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
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
    slowSpark.advance(to: 100, agentProgress: 0, agentHasFinished: false, agentIsPaused: false)
    slowSpark.advance(to: 104, agentProgress: 0, agentHasFinished: false, agentIsPaused: false)
    #expect(abs(slowSpark.laps - 1) < 0.000001)

    var fastSpark = AgentSparkPhase()
    fastSpark.advance(to: 100, agentProgress: 1, agentHasFinished: false, agentIsPaused: false)
    fastSpark.advance(to: 101.2, agentProgress: 1, agentHasFinished: false, agentIsPaused: false)
    #expect(abs(fastSpark.laps - 1) < 0.000001)
}

@Test func theSparkSpeedsUpAsTheProgressGrowsWithoutJumping() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 0, agentHasFinished: false, agentIsPaused: false)
    spark.advance(to: 1, agentProgress: 0, agentHasFinished: false, agentIsPaused: false)
    let lapsInTheFirstSecond = spark.laps
    spark.advance(to: 2, agentProgress: 0.9, agentHasFinished: false, agentIsPaused: false)
    let lapsInTheSecondSecond = spark.laps - lapsInTheFirstSecond
    #expect(lapsInTheSecondSecond > lapsInTheFirstSecond)
    // Each step starts where the last one ended, so a change of progress never moves the spark itself.
    #expect(abs(spark.laps - (lapsInTheFirstSecond + lapsInTheSecondSecond)) < 0.000001)
}

@Test func theFirstAdvanceOnlyRecordsTheTime() {
    var spark = AgentSparkPhase(startingLaps: 0.25)
    spark.advance(to: 500, agentProgress: 0.5, agentHasFinished: false, agentIsPaused: false)
    #expect(spark.laps == 0.25)
}

@Test(arguments: [0.1, 0.5, 0.9, 3.0])
func aFinishedAgentsSparkReachesTheEndOfItsLapExactlyWhenTheControllerRemovesItWhereverItWas(startingLaps: Double) {
    var spark = AgentSparkPhase(startingLaps: startingLaps)
    spark.advance(to: 0, agentProgress: 0, agentHasFinished: true, agentIsPaused: false)
    spark.advance(to: AgentSparkTimeline.secondsAFinishingLapTakes - 0.1, agentProgress: 0, agentHasFinished: true, agentIsPaused: false)
    #expect(!spark.hasCompletedItsLastLap)
    spark.advance(to: AgentSparkTimeline.secondsAFinishingLapTakes + 0.001, agentProgress: 0, agentHasFinished: true, agentIsPaused: false)
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
    spark.advance(to: 0, agentProgress: 0.2, agentHasFinished: false, agentIsPaused: false)
    spark.advance(to: 2, agentProgress: 0.2, agentHasFinished: false, agentIsPaused: false)
    #expect(!spark.hasCompletedItsLastLap)
    let lapsAtTheFinish = spark.laps
    #expect(lapsAtTheFinish > 0.5 && lapsAtTheFinish < 1)

    spark.advance(to: 2.1, agentProgress: 1, agentHasFinished: true, agentIsPaused: false)
    #expect(spark.stopsAtLap == 1)
    #expect(!spark.hasCompletedItsLastLap)
    // The rest of the lap takes under 1.2 seconds, however far the spark was.
    spark.advance(to: 2.1 + AgentSparkTimeline.secondsAFinishingLapTakes + 0.001, agentProgress: 1, agentHasFinished: true, agentIsPaused: false)
    #expect(spark.hasCompletedItsLastLap)
    #expect(spark.laps == 1)
}

@Test func aFinishedAgentsSparkStopsAtTheLapAndNeverRunsPastIt() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: true, agentIsPaused: false)
    spark.advance(to: 60, agentProgress: 1, agentHasFinished: true, agentIsPaused: false)
    #expect(spark.laps == 1)
    #expect(spark.hasCompletedItsLastLap)
}

@Test func aSparkAtTheStartOfALapWhenTheAgentFinishesStillGetsAFullLap() {
    var spark = AgentSparkPhase(startingLaps: 3)
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: true, agentIsPaused: false)
    #expect(spark.stopsAtLap == 4)
    #expect(!spark.hasCompletedItsLastLap)
}

@Test func aSparkThatIsStillWorkingNeverCompletesItsLastLap() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: false, agentIsPaused: false)
    spark.advance(to: 600, agentProgress: 1, agentHasFinished: false, agentIsPaused: false)
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
        waitForAFinishingSparkLap: {},
        appActivationNotificationCenter: NotificationCenter()
    )
    controller.agentSparksMayDraw = { true }
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    return controller
}

// MARK: - Rejoining the line

@Test func aRunningAgentRejoinsTheLineWhenItsVideoIsInFrontAgainAfterAScrollClearedIt() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.end(because: .scrolled)
    state.agentLineFadeOutFinished()
    #expect(state.agentLine == .hidden)

    // The next press reads the same video's media again.
    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 30, agentsMayJoinTheLine: true)
    #expect(state.agentLine == .showing(AgentSparkLine(media: sparkMedia(), agentIDs: [agentID])))
}

@Test func anAgentHeldBackAtItsStartJoinsAtTheFirstReleaseThatAllowsIt() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    // A scene covers the media when the agent starts.
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: false)
    #expect(state.agentLine == .hidden)
    #expect(state.runningAgents.map(\.id) == [agentID])

    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 30, agentsMayJoinTheLine: false)
    #expect(state.agentLine == .hidden)

    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 40, agentsMayJoinTheLine: true)
    #expect(state.agentLineOnTheMedia?.line.agentIDs == [agentID])
}

@Test func aReleaseThatDrawsARequestsLoopWhileAScenePlaysBringsBackNoAgentSpark() {
    var state = stateHoldingTheMediaInHand()
    state.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.end(because: .aSceneStartedToShow)
    state.agentLineFadeOutFinished()

    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 30)
    state.mediaRectArrived(sparkMedia(), at: 30.2, agentsMayJoinTheLine: false)
    #expect(state.loopIsShowing)
    #expect(state.agentLine == .hidden)
}

@Test func aFinishedAgentNeverRejoinsTheLineItsSparkLeft() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.agentFinished(id: agentID)
    state.end(because: .scrolled)
    state.agentLineFadeOutFinished()

    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 30, agentsMayJoinTheLine: true)
    #expect(state.agentLine == .hidden)
}

@Test func anAgentDoesNotRejoinForAnotherVideoOrAfterItEnded() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.end(because: .scrolled)
    state.agentLineFadeOutFinished()

    // Another video is in front.
    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(tabURL: "https://www.youtube.com/watch?v=another"), at: 30, agentsMayJoinTheLine: true)
    #expect(state.agentLine == .hidden)

    // The agent ends, so its own video coming back changes nothing.
    state.agentEnded(id: agentID)
    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 40, agentsMayJoinTheLine: true)
    #expect(state.agentLine == .hidden)
    #expect(state.runningAgents.isEmpty)
}

@Test func aRectThatArrivesAfterTheHandOffDrawsTheLoopAndTheRunningAgentRejoinsIt() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.end(because: .scrolled)
    state.agentLineFadeOutFinished()

    state.pushToTalkWasPressed()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheMedia(at: 30)
    state.mediaRectArrived(sparkMedia(), at: 30.2, agentsMayJoinTheLine: true)
    #expect(state.loopIsShowing)
    #expect(state.agentLineOnTheMedia?.line.agentIDs == [agentID])
}

@Test func startingTheSameAgentTwiceRemembersItOnce() {
    var state = stateHoldingTheMediaInHand()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(state.runningAgents.count == 1)
}

@Test func anAgentStartedWithNoMediaInHandIsStillRememberedAndJoinsOnTheNextRelease() {
    var state = CursorLoopState()
    let agentID = UUID()
    state.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL), mayJoinTheLine: true)
    #expect(state.agentLine == .hidden)
    state.pushToTalkWasReleased()
    state.mediaRectArrived(sparkMedia(), at: 10, agentsMayJoinTheLine: true)
    #expect(state.agentLineOnTheMedia?.line.agentIDs == [agentID])
}

@Test(.timeLimit(.minutes(1))) @MainActor func aFinishedAgentWhoseSparkIsOffTheLineIsForgottenWithNoLap() async {
    let controller = await controllerWithTheMediaInHand()
    let agentID = UUID()
    controller.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    controller.end(because: .scrolled)
    controller.agentStatusesChanged([agentID: .finished])
    #expect(controller.state.runningAgents.isEmpty)
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
        waitForAFinishingSparkLap: { lapWaits.started += 1 },
        appActivationNotificationCenter: NotificationCenter()
    )
    controller.agentSparksMayDraw = { true }
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
    let appActivationNotificationCenter = NotificationCenter()
    let controller = CursorLoopController(
        readTheMediaInTheFrontTab: { _ in sparkMedia() },
        readTheFrontTabSample: { sparkSample() },
        waitBetweenFrontTabPolls: { await Task.yield() },
        waitForAFinishingSparkLap: {},
        appActivationNotificationCenter: appActivationNotificationCenter
    )
    controller.agentSparksMayDraw = { true }
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    controller.agentStarted(id: UUID(), sourceTab: .tab(url: sparkTabURL))
    // The next press clears the turn's rect, so only the agent line is left for the front app change to clear.
    controller.pushToTalkWasPressed()
    #expect(controller.state.agentLineIsShowing)
    // The test host is not Chrome, so activating it is the front app changing to something else.
    appActivationNotificationCenter.post(
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

// MARK: - The drawing

/// Renders the agent line at 2x, with a studyGuide agent whose first of two steps is done, so its progress is a half and its color is amber.
@MainActor
private struct RenderedAgentLine {
    static let lineRect = CGRect(x: 20, y: 20, width: 200, height: 120)
    static let seed: UInt64 = 7
    let pixels: NSBitmapImageRep
    let agentColor: NSColor

    init(reduceMotion: Bool, drawsItsOwnTrack: Bool = false) throws {
        let store = makeBackgroundAgentStore()
        let agentID = store.start(kind: .studyGuide)
        store.completeStep(for: agentID)
        let agent = try #require(store.agents.first)
        agentColor = NSColor(agent.displayColor.color).usingColorSpace(.sRGB) ?? .clear
        let line = AgentLoopOnScreen(lineRect: Self.lineRect, seed: Self.seed, agentIDs: [agentID], drawsItsOwnTrack: drawsItsOwnTrack, isFadingOut: false)
        let view = CursorLoopAgentSparkView(agentLoop: line, agentStore: store, trackColor: .white, reduceMotionIsOn: reduceMotion, fadesInWhenItAppears: false)
            .frame(width: 240, height: 160)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        pixels = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    /// The pixel under a point along the line, `share` of the way round it from its start.
    func color(atShare share: Double) throws -> NSColor {
        let outline = CursorLoopOutline.path(along: Self.lineRect, seed: Self.seed)
        let point = try #require(outline.trimmedPath(from: 0, to: max(share, 0.0005)).currentPoint)
        return try #require(pixels.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.usingColorSpace(.sRGB))
    }

    func isTheAgentsColor(_ color: NSColor) -> Bool {
        abs(color.redComponent - agentColor.redComponent) < 0.06
            && abs(color.greenComponent - agentColor.greenComponent) < 0.06
            && abs(color.blueComponent - agentColor.blueComponent) < 0.06
            && color.alphaComponent > 0.9
    }
}

@Test @MainActor func reduceMotionDrawsAStillArcInTheAgentsColorAsLongAsItsProgressAndNoSpark() throws {
    let render = try RenderedAgentLine(reduceMotion: true)
    // The agent is half done, so the line's first part is its color and the rest is empty.
    #expect(render.isTheAgentsColor(try render.color(atShare: 0.15)))
    #expect(render.isTheAgentsColor(try render.color(atShare: 0.4)))
    #expect(try render.color(atShare: 0.7).alphaComponent < 0.05)
    #expect(try render.color(atShare: 0.95).alphaComponent < 0.05)
}

@Test @MainActor func theSparkStartsOnTheLinesStartInTheAgentsColorWithNoTrackWhenARequestLoopDrawsTheLine() throws {
    let render = try RenderedAgentLine(reduceMotion: false)
    #expect(render.isTheAgentsColor(try render.color(atShare: 0)))
    // Nothing else is drawn on the line, since the request's loop draws it.
    #expect(try render.color(atShare: 0.5).alphaComponent < 0.05)
}

@Test @MainActor func withNoRequestLoopTheAgentsDrawAQuietTrackForTheSpark() throws {
    let render = try RenderedAgentLine(reduceMotion: false, drawsItsOwnTrack: true)
    let trackPixel = try render.color(atShare: 0.5)
    // White at 45 percent over nothing: visible, but quieter than the spark.
    #expect(trackPixel.alphaComponent > 0.3 && trackPixel.alphaComponent < 0.6)
}

@Test @MainActor func reduceMotionDrawsTheShorterArcOverTheLongerOne() throws {
    let store = makeBackgroundAgentStore()
    let halfDoneAgentID = store.start(kind: .studyGuide)
    store.completeStep(for: halfDoneAgentID)
    let finishedAgentID = store.start(kind: .threeDModel)
    store.finish(finishedAgentID, with: .readyScene)
    let halfDoneColor = try #require(store.agents.first { $0.id == halfDoneAgentID }?.displayColor.color)
    // The half done agent joined first, so drawing in the order they joined would cover its arc with the finished agent's.
    let line = AgentLoopOnScreen(
        lineRect: RenderedAgentLine.lineRect, seed: RenderedAgentLine.seed,
        agentIDs: [halfDoneAgentID, finishedAgentID], drawsItsOwnTrack: false, isFadingOut: false
    )
    let renderer = ImageRenderer(
        content: CursorLoopAgentSparkView(agentLoop: line, agentStore: store, trackColor: .white, reduceMotionIsOn: true, fadesInWhenItAppears: false)
            .frame(width: 240, height: 160)
    )
    renderer.scale = 2
    let pixels = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    let outline = CursorLoopOutline.path(along: RenderedAgentLine.lineRect, seed: RenderedAgentLine.seed)
    let point = try #require(outline.trimmedPath(from: 0, to: 0.3).currentPoint)
    let pixel = try #require(pixels.colorAt(x: Int(point.x * 2), y: Int(point.y * 2))?.usingColorSpace(.sRGB))
    let expected = try #require(NSColor(halfDoneColor).usingColorSpace(.sRGB))
    #expect(abs(pixel.redComponent - expected.redComponent) < 0.06 && abs(pixel.blueComponent - expected.blueComponent) < 0.06)
}

@Test(.timeLimit(.minutes(1))) @MainActor func theControllerHoldsAnAgentBackWhileSparksMayNotDrawAndJoinsItAtTheNextRelease() async {
    var sparksMayDraw = false
    let controller = CursorLoopController(
        readTheMediaInTheFrontTab: { _ in sparkMedia() },
        readTheFrontTabSample: { sparkSample() },
        waitBetweenFrontTabPolls: { await Task.yield() },
        waitForAFinishingSparkLap: {},
        appActivationNotificationCenter: NotificationCenter()
    )
    controller.agentSparksMayDraw = { sparksMayDraw }
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    let agentID = UUID()
    controller.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    #expect(!controller.state.agentLineIsShowing)

    // A release while sparks may not draw reads the media and still brings back nothing.
    controller.pushToTalkWasPressed()
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    #expect(!controller.state.agentLineIsShowing)

    sparksMayDraw = true
    controller.pushToTalkWasPressed()
    controller.pushToTalkWasReleased()
    await controller.waitForTheMediaReadToFinish()
    #expect(controller.state.agentLineOnTheMedia?.line.agentIDs == [agentID])
}

@Test(.timeLimit(.minutes(1))) @MainActor func theControllerMarksAFinishedAgentAtOnceSoItCannotRejoin() async {
    let controller = await controllerWithTheMediaInHand()
    let agentID = UUID()
    controller.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    controller.agentStatusesChanged([agentID: .finished])
    #expect(controller.state.runningAgents.first?.hasFinished == true)
}

@Test func sparksMayDrawOnlyWithShowClickyOnAndNoSceneOrQuizQuestionOnScreen() {
    #expect(agentSparksMayDraw(clickyCursorIsEnabled: true, aSceneIsOnScreen: false, aQuizQuestionIsOpen: false))
    #expect(!agentSparksMayDraw(clickyCursorIsEnabled: false, aSceneIsOnScreen: false, aQuizQuestionIsOpen: false))
    #expect(!agentSparksMayDraw(clickyCursorIsEnabled: true, aSceneIsOnScreen: true, aQuizQuestionIsOpen: false))
    #expect(!agentSparksMayDraw(clickyCursorIsEnabled: true, aSceneIsOnScreen: false, aQuizQuestionIsOpen: true))
}

@Test(.timeLimit(.minutes(1))) @MainActor func aLineThatIsAlreadyShowingDrawsNothingWhileSparksMayNotDrawAndDrawsAgainWhenTheyMay() async {
    let controller = await controllerWithTheMediaInHand()
    let agentID = UUID()
    controller.agentStarted(id: agentID, sourceTab: .tab(url: sparkTabURL))
    #expect(controller.agentLineToDraw()?.line.agentIDs == [agentID])

    // Show Clicky turns off, or a voice-only quiz question opens, with the line showing.
    var sparksMayDraw = false
    controller.agentSparksMayDraw = { sparksMayDraw }
    #expect(controller.agentLineToDraw() == nil)

    sparksMayDraw = true
    #expect(controller.agentLineToDraw()?.line.agentIDs == [agentID])
}

@Test @MainActor func aControllerWithNoGateWiredDrawsNoSparks() {
    let controller = CursorLoopController(readTheMediaInTheFrontTab: { _ in nil }, readTheFrontTabSample: { nil })
    #expect(controller.agentSparksMayDraw() == false)
}

// MARK: - Pausing every agent

@Test func aPausedAgentsSparkHoldsStillAndCarriesOnFromTheSamePlaceAfterTheResume() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 0.5, agentHasFinished: false, agentIsPaused: false)
    spark.advance(to: 1, agentProgress: 0.5, agentHasFinished: false, agentIsPaused: false)
    let lapsAtThePause = spark.laps
    #expect(lapsAtThePause > 0)

    spark.advance(to: 30, agentProgress: 0.5, agentHasFinished: false, agentIsPaused: true)
    #expect(spark.laps == lapsAtThePause)

    // The first frame after "go ahead" adds only the time since the last frame, not the whole pause.
    spark.advance(to: 30.1, agentProgress: 0.5, agentHasFinished: false, agentIsPaused: false)
    #expect(spark.laps > lapsAtThePause)
    #expect(spark.laps - lapsAtThePause < 0.1)
}

@Test func anAgentThatFinishesStillRunsItsLastLapWhateverItsPausedFlagSays() {
    var spark = AgentSparkPhase()
    spark.advance(to: 0, agentProgress: 1, agentHasFinished: true, agentIsPaused: true)
    spark.advance(to: AgentSparkTimeline.secondsAFinishingLapTakes + 0.001, agentProgress: 1, agentHasFinished: true, agentIsPaused: true)
    #expect(spark.hasCompletedItsLastLap)
}

@Test @MainActor func holdOnHoldsEveryRunningAgentsSparkStillAndGoAheadReleasesIt() {
    let store = makeBackgroundAgentStore()
    let agentID = store.start(kind: .task)
    #expect(store.agents.first { $0.id == agentID }?.loopSparkIsHeldStill == false)
    _ = store.pauseEveryAgent()
    #expect(store.agents.first { $0.id == agentID }?.loopSparkIsHeldStill == true)
    _ = store.resumeEveryAgent()
    #expect(store.agents.first { $0.id == agentID }?.loopSparkIsHeldStill == false)
}
