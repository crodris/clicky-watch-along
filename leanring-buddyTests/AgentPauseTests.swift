//
//  AgentPauseTests.swift
//  leanring-buddyTests
//
//  Pausing every agent by voice: the store's pause, which holds each agent's progress and its next step, the discs that
//  fold into one paused disc and go back to their places, and the two voice tools.
//

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct AgentPauseTests {
    // MARK: - The store

    @Test func aPauseHoldsEachRunningAgentsProgressAndAResumePicksItUpFromThere() throws {
        let store = makeBackgroundAgentStore()
        // A task's one step runs 45 seconds, so 4 seconds in and 64 seconds in read differently.
        let agentID = store.start(kind: .task)
        let startedAt = try #require(store.agents.first).currentStepStartedAt
        let pausedAt = startedAt.addingTimeInterval(4)
        #expect(store.pauseEveryAgent(at: pausedAt))
        #expect(store.agentsArePaused)

        let pausedAgent = try #require(store.agents.first { $0.id == agentID })
        // A minute later the progress is still where the pause left it, and it heads nowhere.
        #expect(pausedAgent.progress(at: pausedAt.addingTimeInterval(60)) == pausedAgent.progress(at: pausedAt))
        #expect(pausedAgent.progressHeading(at: pausedAt.addingTimeInterval(60)) == nil)

        let resumedAt = pausedAt.addingTimeInterval(60)
        #expect(store.resumeEveryAgent(at: resumedAt))
        let resumedAgent = try #require(store.agents.first { $0.id == agentID })
        #expect(resumedAgent.pausedAt == nil)
        #expect(resumedAgent.progress(at: resumedAt) == pausedAgent.progress(at: pausedAt))
        #expect(resumedAgent.progressHeading(at: resumedAt) != nil)
    }

    @Test func pausingTwiceOrResumingWhatRunsChangesNothing() {
        let store = makeBackgroundAgentStore()
        store.start(kind: .task)
        #expect(!store.resumeEveryAgent())
        #expect(store.pauseEveryAgent())
        #expect(!store.pauseEveryAgent())
        #expect(store.resumeEveryAgent())
        #expect(!store.agentsArePaused)
    }

    @Test func anAgentStartedDuringAPauseStartsPausedAndAStepFinishedInFlightStartsTheNextOnePaused() throws {
        let store = makeBackgroundAgentStore()
        store.start(kind: .task)
        store.pauseEveryAgent()
        let newAgentID = store.start(kind: .studyGuide)
        let newAgent = try #require(store.agents.first { $0.id == newAgentID })
        #expect(newAgent.pausedAt == newAgent.startedAt)

        store.completeStep(for: newAgentID)
        let afterTheStep = try #require(store.agents.first { $0.id == newAgentID })
        #expect(afterTheStep.pausedAt == afterTheStep.currentStepStartedAt)
        #expect(afterTheStep.progress(at: Date().addingTimeInterval(30)) == afterTheStep.progress(at: afterTheStep.currentStepStartedAt))
    }

    @Test func cancellingEveryPausedAgentEndsThePause() {
        let store = makeBackgroundAgentStore()
        let firstAgentID = store.start(kind: .task)
        let secondAgentID = store.start(kind: .threeDModel)
        store.pauseEveryAgent()
        store.cancel(firstAgentID)
        #expect(store.agentsArePaused)
        store.cancel(secondAgentID)
        #expect(!store.agentsArePaused)
    }

    @Test func theWaitReturnsAtOnceWhileAgentsRunAndOnlyAfterTheResumeWhilePaused() async {
        let store = makeBackgroundAgentStore()
        store.start(kind: .task)
        await store.waitWhileAgentsArePaused()

        store.pauseEveryAgent()
        var waitEnded = false
        let waitingTask = Task { @MainActor in
            await store.waitWhileAgentsArePaused()
            waitEnded = true
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!waitEnded)
        store.resumeEveryAgent()
        await waitingTask.value
        #expect(waitEnded)
    }

    @Test func aCancelledAgentStopsWaitingThroughThePause() async {
        let store = makeBackgroundAgentStore()
        store.start(kind: .task)
        store.pauseEveryAgent()
        let waitingTask = Task { @MainActor in
            await store.waitWhileAgentsArePaused()
            return Task.isCancelled
        }
        try? await Task.sleep(for: .milliseconds(50))
        waitingTask.cancel()
        #expect(await waitingTask.value)
        #expect(store.agentsArePaused)
    }

    // MARK: - The discs

    @Test func everyDiscFoldsIntoOnePausedDiscAndTheLayoutComesBackOnResume() {
        let firstAgentID = UUID()
        let secondAgentID = UUID()
        let layout = AgentTokenLayout(shownAgentIDs: [firstAgentID, secondAgentID], overflowCount: 2)
        #expect(agentTokenSlotsLeftToRight(layout: layout, agentsArePaused: false) == [.agent(firstAgentID), .agent(secondAgentID), .overflow])
        #expect(agentTokenSlotsLeftToRight(layout: layout, agentsArePaused: true) == [.paused])
        // A display with no room for discs shows no paused disc either.
        #expect(agentTokenSlotsLeftToRight(layout: AgentTokenLayout(shownAgentIDs: [], overflowCount: 0), agentsArePaused: true).isEmpty)
    }

    @Test func aPauseGathersAndAResumeSendsBackWithACrossfadeUnderReduceMotion() {
        #expect(agentTokenPauseMove(agentsWerePaused: false, agentsArePaused: true, reduceMotionIsOn: false) == .gatherIntoThePausedDisc)
        #expect(agentTokenPauseMove(agentsWerePaused: false, agentsArePaused: true, reduceMotionIsOn: true) == .crossfadeToThePausedDisc)
        #expect(agentTokenPauseMove(agentsWerePaused: true, agentsArePaused: false, reduceMotionIsOn: false) == .sendBackToTheirPlaces)
        #expect(agentTokenPauseMove(agentsWerePaused: true, agentsArePaused: false, reduceMotionIsOn: true) == .crossfadeBackToTheirPlaces)
        #expect(agentTokenPauseMove(agentsWerePaused: true, agentsArePaused: true, reduceMotionIsOn: false) == nil)
        #expect(agentTokenPauseMove(agentsWerePaused: false, agentsArePaused: false, reduceMotionIsOn: true) == nil)
    }

    @Test func aGatheredDiscShrinksToTheRecallScaleAboutThePausedDiscsCenter() {
        let pausedDiscPanelFrame = CGRect(x: 100, y: 900, width: 28, height: 37)
        let endFrame = AgentTokenGather.endFrame(intoPausedDiscPanelFrame: pausedDiscPanelFrame)
        #expect(abs(endFrame.midX - pausedDiscPanelFrame.midX) < 0.001)
        #expect(abs(endFrame.midY - pausedDiscPanelFrame.midY) < 0.001)
        #expect(abs(endFrame.width - 28 * DS.Move.recallEndScale) < 0.001)
        #expect(AgentTokenGather.slideSeconds == 0.18)
    }

    @Test func thePausedDiscsPeekSaysHowManyAndHowToGoOn() {
        #expect(agentTokenPausedPeekContent(pausedAgentCount: 1, anApprovalWaits: false).title == "1 agent paused")
        #expect(agentTokenPausedPeekContent(pausedAgentCount: 3, anApprovalWaits: false).title == "3 agents paused")
        #expect(agentTokenPausedPeekContent(pausedAgentCount: 3, anApprovalWaits: false).caption == "Say go ahead to let them go on")
        // "Go ahead" answers a waiting request, so the card never tells the learner to say it before they answer.
        #expect(agentTokenPausedPeekContent(pausedAgentCount: 3, anApprovalWaits: true).caption == "Answer the request first, then say go ahead")
    }

    @Test func thePausedDiscCountsOnlyTheRunningAgentsItHolds() {
        let store = makeBackgroundAgentStore()
        store.start(kind: .task)
        let finishedAgentID = store.start(kind: .threeDModel)
        store.finish(finishedAgentID, with: .readyScene)
        store.pauseEveryAgent()
        #expect(pausedAgentCount(of: store.agents) == 1)
    }

    private func renderedPixels(of view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.padding(20).background(Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    @Test func thePausedDiscDrawsItsBarsAndKeepsItsCountBadgeInsideThePanel() throws {
        let pixels = try renderedPixels(of: AgentPausedDiscView(pausedAgentCount: 3).frame(width: AgentTokenMetrics.panelWidth, height: 37))
        let discCenterX = 20 + AgentTokenMetrics.panelWidth / 2
        let discCenterY: CGFloat = 20 + 37 / 2
        // The left bar sits 2.5 points left of the center, light on the dark face.
        let barPixel = try #require(pixels.colorAt(x: Int((discCenterX - 2.5) * 2), y: Int(discCenterY * 2)))
        #expect(barPixel.brightnessComponent > 0.55)
        // The gap between the bars is the dark face.
        let gapPixel = try #require(pixels.colorAt(x: Int(discCenterX * 2), y: Int(discCenterY * 2)))
        #expect(gapPixel.brightnessComponent < 0.25)
        // The badge's light fill sits at the disc's lower right, still inside the 28 point panel.
        let badgeCenterX = discCenterX + AgentTokenMetrics.discDiameter / 2 - 5.5 + 3
        let badgeCenterY = discCenterY + AgentTokenMetrics.discDiameter / 2 - 5.5 + 3
        #expect(badgeCenterX + 5.5 <= 20 + AgentTokenMetrics.panelWidth)
        let badgePixel = try #require(pixels.colorAt(x: Int((badgeCenterX - 3) * 2), y: Int((badgeCenterY - 3) * 2)))
        #expect(badgePixel.brightnessComponent > 0.55)
    }

    // MARK: - The voice tools

    private func voiceContext(agentIsRunning: Bool, agentsArePaused: Bool) -> AppVoiceTool.Context {
        AppVoiceTool.Context(
            sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false,
            videoQuizIsRunning: false, quizQuestionIsOpen: false,
            backgroundAgentIsRunning: agentIsRunning, backgroundAgentsArePaused: agentsArePaused
        )
    }

    @Test func holdOnIsOfferedWhileAnAgentRunsAndGoAheadOnlyWhileTheyArePaused() {
        let nothingRuns = AppVoiceTool.available(in: voiceContext(agentIsRunning: false, agentsArePaused: false))
        #expect(!nothingRuns.contains(.pauseAgents) && !nothingRuns.contains(.resumeAgents))

        let anAgentRuns = AppVoiceTool.available(in: voiceContext(agentIsRunning: true, agentsArePaused: false))
        #expect(anAgentRuns.contains(.pauseAgents) && !anAgentRuns.contains(.resumeAgents))

        let paused = AppVoiceTool.available(in: voiceContext(agentIsRunning: true, agentsArePaused: true))
        #expect(!paused.contains(.pauseAgents) && paused.contains(.resumeAgents))

        // "Go ahead" is a yes to a request the learner can answer by voice, so a resume waits until it is answered.
        var pausedWithARequestWaiting = voiceContext(agentIsRunning: true, agentsArePaused: true)
        pausedWithARequestWaiting.approvalIsWaiting = true
        let offeredWhileARequestWaits = AppVoiceTool.available(in: pausedWithARequestWaiting)
        #expect(!offeredWhileARequestWaits.contains(.resumeAgents) && offeredWhileARequestWaits.contains(.answerApproval))
    }

    @Test func theRouterTakesEveryCommandWhileAnAgentRunsOrIsPaused() {
        #expect(!voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, backgroundAgentIsRunning: true, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, backgroundAgentsArePaused: true, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
        // A quiz answer still goes to the judge first.
        #expect(!voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, backgroundAgentsArePaused: true, phaseIsWaitingForAQuizAnswer: true, sceneIsBuilding: false))
    }

    @Test func thePanelSaysTheAgentsArePausedAndTheirTimeStandsStill() throws {
        let store = makeBackgroundAgentStore()
        let agentID = store.start(kind: .task)
        let startedAt = try #require(store.agents.first).startedAt
        #expect(panelAgentsSummary(agents: store.agents, agentsArePaused: false, at: startedAt)?.mainText == "1 working")
        store.pauseEveryAgent(at: startedAt.addingTimeInterval(10))
        #expect(panelAgentsSummary(agents: store.agents, agentsArePaused: true, at: startedAt)?.mainText == "1 paused · say go ahead")
        let pausedAgent = try #require(store.agents.first { $0.id == agentID })
        #expect(pausedAgent.elapsedSeconds(at: startedAt.addingTimeInterval(70)) == 10)
    }

    @Test func anExperimentStartedDuringAPauseSaysItWaitsForGoAhead() {
        #expect(experimentStartedSpokenLine(agentsArePaused: false) == "Sure, I'll build that while you watch.")
        #expect(experimentStartedSpokenLine(agentsArePaused: true) == "Sure, I'll build that once you say go ahead.")
    }

    @Test func theChipsAndTheSceneStateSayWhatHappenedToTheAgents() {
        #expect(VoiceToolCall(id: "1", name: "pause_agents", input: [:]).chipPhrase == "Holding every agent")
        #expect(VoiceToolCall(id: "2", name: "resume_agents", input: [:]).chipPhrase == "Back to work")
        #expect(backgroundAgentsStateText(runningAgentCount: 0, agentsArePaused: false) == nil)
        #expect(backgroundAgentsStateText(runningAgentCount: 2, agentsArePaused: false) == "2 running")
        #expect(backgroundAgentsStateText(runningAgentCount: 1, agentsArePaused: true) == "1 paused, and a new agent waits for go ahead too")
    }
}
