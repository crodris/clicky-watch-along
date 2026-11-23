//
//  VoiceCommandSpeculationTests.swift
//  leanring-buddyTests
//
//  A voice command started on the partial transcript at push-to-talk release: where a transcript goes, when a partial
//  may start a command, when the final transcript keeps it, what a new press or the final transcript does to a command
//  waiting for it.
//  The harness's half, which holds the command's calls until it is confirmed, is tested in harness/brainspeculation_test.go.
//

import Foundation
import os
import Testing
@testable import Clicky

/// Keeps every line a command writes, as AgentHarness's stdin queue would send them.
private final class SpeculationLineRecorder: Sendable {
    private let recordedLines = OSAllocatedUnfairLock<[HarnessCommand]>(initialState: [])

    var lines: [HarnessCommand] { recordedLines.withLock { lines in lines } }

    func record(_ harnessCommand: HarnessCommand) {
        recordedLines.withLock { lines in lines.append(harnessCommand) }
    }
}

@MainActor
struct VoiceCommandSpeculationTests {
    private let commandID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    /// Nothing on screen, no video, and no request waiting: a transcript with nothing to command goes down the keyword path.
    private let quietScreen = TranscriptRouteContext(
        themeStudioIsOpen: false,
        phaseIsWaitingForAQuizAnswer: false,
        liveSceneIsUpWithNoQuizQuestion: false,
        sceneIsBuilding: false,
        sceneIsOnScreen: false,
        brainTakesEveryRequest: false,
        backgroundSceneIsReady: false,
        taskAnswerIsReady: false,
        approvalIsWaiting: false,
        backgroundAgentIsRunning: false,
        backgroundAgentsArePaused: false
    )

    private func screenRead(ofPress pressCount: Int) -> ReleaseScreenReadInHand {
        ReleaseScreenReadInHand(
            pressCount: pressCount,
            frontVideoState: nil,
            pageRead: VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: Date())
        )
    }

    private func speculativeCommand(ofPress pressCount: Int, lines: HarnessVoiceCommandLines) -> SpeculativeVoiceCommand {
        let (commandEvents, _) = AsyncStream<HarnessTaskEvent>.makeStream()
        return SpeculativeVoiceCommand(
            partialTranscript: "turn it left",
            screenRead: screenRead(ofPress: pressCount),
            inputs: VoiceCommandInputs(tools: [], pageState: nil, frontVideoState: nil, harnessSceneState: .object([:]), approvalWhenTheCommandStarted: nil),
            command: StartedHarnessVoiceCommand(commandID: commandID, lines: lines, events: commandEvents, sentAt: Date())
        )
    }

    @Test func theFinalTranscriptsCapitalsAndPunctuationStillMatchThePartialsWords() {
        #expect(transcriptWordsForComparison("Turn it left.") == transcriptWordsForComparison("turn it   left"))
        #expect(transcriptWordsForComparison("What's that part?") == ["what's", "that", "part"])
        #expect(transcriptWordsForComparison("turn it") != transcriptWordsForComparison("turn it left"))
        #expect(transcriptWordsForComparison("  ,. ").isEmpty)
    }

    @Test func numbersWhosePunctuationDiffersAreOtherWordsSoTheCommandIsDiscarded() {
        func step(partial: String, final: String) -> SpeculationStep {
            speculationStep(
                partialTranscript: partial,
                finalTranscript: final,
                finalRoute: .voiceCommandRouter,
                finalUsesTheSameScreenRead: true,
                commandInputsAreUnchanged: true,
                heldCommandIsStillRunning: true
            )
        }
        // The partial caught the digits before Apple Speech wrote the final's punctuation, so the command built from the
        // partial would seek, turn, or set the speed to the wrong value.
        #expect(step(partial: "seek to 130", final: "Seek to 1:30") == .discard(reason: "the final transcript has other words"))
        #expect(step(partial: "turn it 45 degrees", final: "Turn it -45 degrees") == .discard(reason: "the final transcript has other words"))
        #expect(step(partial: "play it at 15 speed", final: "Play it at 1.5 speed") == .discard(reason: "the final transcript has other words"))
        // A closing period or comma, and capitals, are still the same words.
        #expect(step(partial: "turn it left", final: "Turn it left.") == .confirm)
        #expect(step(partial: "seek to 1:30", final: "Seek to 1:30.") == .confirm)
        #expect(transcriptWordsForComparison("Go back, -10 seconds.") == ["go", "back", "-10", "seconds"])
    }

    @Test func eachRouteIsDecidedInTheOrderTheAppHasAlwaysUsed() {
        var videoReads = 0
        let videoIsInFront = { videoReads += 1; return true }
        #expect(transcriptRoute(for: "stop the quiz", in: quietScreen, videoIsInFront: videoIsInFront) == .videoQuizCommand(.stop))
        #expect(transcriptRoute(for: "animate this", in: quietScreen, videoIsInFront: videoIsInFront) == .keywordBranch(.animatePicture))
        // A phrase match or a keyword branch never reads the video, since a fresh read is a round trip to Chrome.
        #expect(videoReads == 0)
        #expect(transcriptRoute(for: "turn it left", in: quietScreen, videoIsInFront: videoIsInFront) == .voiceCommandRouter)
        #expect(transcriptRoute(for: "turn it left", in: quietScreen, videoIsInFront: { false }) == .keywordPath)

        var sceneUp = quietScreen
        sceneUp.sceneIsOnScreen = true
        sceneUp.liveSceneIsUpWithNoQuizQuestion = true
        #expect(transcriptRoute(for: "put it back", in: sceneUp, videoIsInFront: { false }) == .putTheSceneBack)
        #expect(transcriptRoute(for: "turn it left", in: sceneUp, videoIsInFront: { false }) == .voiceCommandRouter)

        // A quiz answer goes to the judge, and a scene still building keeps the keyword path, video or not.
        var quizAnswer = sceneUp
        quizAnswer.phaseIsWaitingForAQuizAnswer = true
        quizAnswer.liveSceneIsUpWithNoQuizQuestion = false
        #expect(transcriptRoute(for: "the heart", in: quizAnswer, videoIsInFront: { true }) == .keywordPath)
        var sceneBuilding = quietScreen
        sceneBuilding.sceneIsBuilding = true
        #expect(transcriptRoute(for: "turn it left", in: sceneBuilding, videoIsInFront: { true }) == .keywordPath)

        // The Theme Studio's own phrase opens the studio with no model call.
        if case .keywordBranch(.designATheme) = transcriptRoute(for: "change my theme", in: quietScreen, videoIsInFront: { true }) {} else {
            Issue.record("change my theme did not open the Theme Studio")
        }
    }

    @Test func roomArtIsAKeywordBranchWithTheBrainFlagOffAndTheRoutersWithItOn() {
        let transcript = "show me how this would look in my room"
        #expect(transcriptRoute(for: transcript, in: quietScreen, videoIsInFront: { false }) == .keywordBranch(.showArtInMyRoom))
        var brainTakesEveryRequest = quietScreen
        brainTakesEveryRequest.brainTakesEveryRequest = true
        #expect(transcriptRoute(for: transcript, in: brainTakesEveryRequest, videoIsInFront: { false }) == .voiceCommandRouter)
        // With the flag off the partial waits for the final transcript, since the room art panel is not the router's.
        #expect(
            speculativeStartStep(
                partialTranscript: transcript,
                partialRoute: .keywordBranch(.showArtInMyRoom),
                approvalAtPress: nil,
                speculationIsOn: true
            ) == .waitForOtherWords(reason: "the partial transcript does not go to the router")
        )
    }

    @Test func aPartialStartsACommandOnlyWhenTheBrainWouldTakeItAndNoApprovalIsWaiting() {
        func step(_ partial: String, route: TranscriptRoute = .voiceCommandRouter, approvalAtPress: ApprovalAtPress? = nil, isOn: Bool = true) -> SpeculativeStartStep {
            speculativeStartStep(partialTranscript: partial, partialRoute: route, approvalAtPress: approvalAtPress, speculationIsOn: isOn)
        }
        #expect(step("turn it left") == .start)
        // The harness settles an approval from the transcript's own words, so a partial "yes" must never reach one.
        let approvalIsWaitingReason = "an approval request is waiting, and a partial yes or no could answer it"
        #expect(step("yes", approvalAtPress: ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: true)) == .doNotStart(reason: approvalIsWaitingReason))
        // A no counts for a request whose card was not read, so a request that only waited at the press blocks the start too.
        #expect(step("no", approvalAtPress: ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: false)) == .doNotStart(reason: approvalIsWaitingReason))
        #expect(step("turn it left", approvalAtPress: ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: false)) == .doNotStart(reason: approvalIsWaitingReason))
        // Words that start nothing yet may be followed by newer ones that do, so the press waits for them.
        #expect(step("turn it left", route: .keywordBranch(.startExperiment)) == .waitForOtherWords(reason: "the partial transcript does not go to the router"))
        #expect(step("stop the", route: .videoQuizCommand(.stop)) == .waitForOtherWords(reason: "the partial transcript does not go to the router"))
        #expect(step("the heart", route: .keywordPath) == .waitForOtherWords(reason: "the partial transcript does not go to the router"))
        #expect(step("") == .waitForOtherWords(reason: "no words were heard yet"))
        #expect(step("turn it left", isOn: false) == .doNotStart(reason: "speculation is turned off"))
    }

    @Test func commandInputsDifferWhenOnlyTheApprovalAtThePressDiffers() {
        func inputs(approvalAtPress: ApprovalAtPress?) -> VoiceCommandInputs {
            VoiceCommandInputs(tools: [], pageState: nil, frontVideoState: nil, harnessSceneState: .object([:]), approvalWhenTheCommandStarted: approvalAtPress)
        }
        let unreadRequest = ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: false)
        let readRequest = ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: true)
        // The final transcript's inputs are compared with the ones the command started from, so a request that came or went,
        // or a card read in between, discards the command instead of sending the harness an answer it was never told about.
        #expect(inputs(approvalAtPress: nil) == inputs(approvalAtPress: nil))
        #expect(inputs(approvalAtPress: readRequest) == inputs(approvalAtPress: readRequest))
        #expect(inputs(approvalAtPress: nil) != inputs(approvalAtPress: unreadRequest))
        #expect(inputs(approvalAtPress: unreadRequest) != inputs(approvalAtPress: readRequest))
        #expect(inputs(approvalAtPress: unreadRequest) != inputs(approvalAtPress: ApprovalAtPress(approvalID: "approval-2", wholeSummaryWasSeen: false)))
    }

    /// "Hold on" and "go ahead" are router tools (`pause_agents`, `resume_agents`), not keyword branches, so the route follows
    /// the agents' state and is the same for the partial and the final transcript.
    @Test func holdOnAndGoAheadGoToTheRouterOnlyWhileAnAgentRunsOrIsPausedForPartialAndFinalAlike() {
        var anAgentRuns = quietScreen
        anAgentRuns.backgroundAgentIsRunning = true
        var theAgentsArePaused = quietScreen
        theAgentsArePaused.backgroundAgentsArePaused = true
        for transcript in ["hold on", "Hold on.", "go ahead", "Go ahead."] {
            // Nothing runs, so there is nothing to hold, and the words answer no command.
            #expect(transcriptRoute(for: transcript, in: quietScreen, videoIsInFront: { false }) == .keywordPath)
            #expect(transcriptRoute(for: transcript, in: anAgentRuns, videoIsInFront: { false }) == .voiceCommandRouter)
            #expect(transcriptRoute(for: transcript, in: theAgentsArePaused, videoIsInFront: { false }) == .voiceCommandRouter)
        }
        // The first word of either phrase, which Apple Speech often shows alone at the release, goes the same way.
        #expect(transcriptRoute(for: "hold", in: anAgentRuns, videoIsInFront: { false }) == .voiceCommandRouter)
        #expect(transcriptRoute(for: "go", in: theAgentsArePaused, videoIsInFront: { false }) == .voiceCommandRouter)
        // A quiz answer still goes to the judge, and a scene still building keeps the keyword path, agents or not.
        var quizAnswerWhileAgentsRun = anAgentRuns
        quizAnswerWhileAgentsRun.phaseIsWaitingForAQuizAnswer = true
        #expect(transcriptRoute(for: "hold on", in: quizAnswerWhileAgentsRun, videoIsInFront: { false }) == .keywordPath)
        var sceneBuildingWhileAgentsRun = anAgentRuns
        sceneBuildingWhileAgentsRun.sceneIsBuilding = true
        #expect(transcriptRoute(for: "hold on", in: sceneBuildingWhileAgentsRun, videoIsInFront: { false }) == .keywordPath)
        // A keyword branch keeps its place ahead of the router while agents run, so "let me try it" builds with no model call.
        #expect(transcriptRoute(for: "let me try it", in: anAgentRuns, videoIsInFront: { false }) == .keywordBranch(.startExperiment))
    }

    @Test func aPartialHoldOnOrGoAheadStartsACommandUnlessAnApprovalWaitsAtThePress() {
        func step(_ partial: String, approvalAtPress: ApprovalAtPress?) -> SpeculativeStartStep {
            speculativeStartStep(partialTranscript: partial, partialRoute: .voiceCommandRouter, approvalAtPress: approvalAtPress, speculationIsOn: true)
        }
        #expect(step("hold on", approvalAtPress: nil) == .start)
        #expect(step("go ahead", approvalAtPress: nil) == .start)
        // "Go ahead" is also a yes to a waiting request, which the harness settles from the transcript's own words, so a
        // request at the press, read or not, keeps both phrases from starting a command on a partial transcript.
        let approvalIsWaitingReason = "an approval request is waiting, and a partial yes or no could answer it"
        for wholeSummaryWasSeen in [true, false] {
            let request = ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: wholeSummaryWasSeen)
            #expect(step("go ahead", approvalAtPress: request) == .doNotStart(reason: approvalIsWaitingReason))
            #expect(step("hold on", approvalAtPress: request) == .doNotStart(reason: approvalIsWaitingReason))
        }
    }

    /// A command started on the partial transcript is kept only while the tools and scene state it was sent with still
    /// hold. A pause, a resume, or an agent that started or finished while the learner spoke changes both, so the held
    /// command is discarded and the final transcript builds its own. The harness never pauses a voice command, so a pause
    /// never holds, cancels, or reorders a held command (`TestAPauseNeverHoldsACommandStartedOnThePartialTranscript`).
    @Test func aHeldCommandIsDiscardedWhenTheAgentsPauseStateChangesBeforeTheFinalTranscript() {
        func inputs(agentIsRunning: Bool, agentsArePaused: Bool, agentsRunning: Int, approvalIsWaiting: Bool = false) -> VoiceCommandInputs {
            let context = AppVoiceTool.Context(
                sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false,
                videoQuizIsRunning: false, quizQuestionIsOpen: false, approvalIsWaiting: approvalIsWaiting,
                backgroundAgentIsRunning: agentIsRunning, backgroundAgentsArePaused: agentsArePaused
            )
            // The same function voiceCommandSceneState adds the field with, so the field's key and text come from production.
            let sceneStateFields = sceneStateFieldsAddingBackgroundAgents(to: [:], runningAgentCount: agentsRunning, agentsArePaused: agentsArePaused)
            return VoiceCommandInputs(
                tools: voiceToolsOfferedToTheModel(pageTools: [], appTools: AppVoiceTool.available(in: context)),
                pageState: nil,
                frontVideoState: nil,
                harnessSceneState: .object(sceneStateFields),
                approvalWhenTheCommandStarted: nil
            )
        }
        func finalStep(startedFrom startedInputs: VoiceCommandInputs, keptUntil finalInputs: VoiceCommandInputs, finalRoute: TranscriptRoute = .voiceCommandRouter) -> SpeculationStep {
            speculationStep(
                partialTranscript: "hold on",
                finalTranscript: "Hold on.",
                finalRoute: finalRoute,
                finalUsesTheSameScreenRead: true,
                commandInputsAreUnchanged: startedInputs == finalInputs,
                heldCommandIsStillRunning: true
            )
        }
        let running = inputs(agentIsRunning: true, agentsArePaused: false, agentsRunning: 2)
        let paused = inputs(agentIsRunning: true, agentsArePaused: true, agentsRunning: 2)

        // The tools differ ("hold on" offers pause_agents, "go ahead" resume_agents), and so does the scene state.
        #expect(running.offeredToolNames.contains("pause_agents") && !running.offeredToolNames.contains("resume_agents"))
        #expect(paused.offeredToolNames.contains("resume_agents") && !paused.offeredToolNames.contains("pause_agents"))
        #expect(running.harnessSceneState != paused.harnessSceneState)
        #expect(finalStep(startedFrom: running, keptUntil: running) == .confirm)
        #expect(finalStep(startedFrom: running, keptUntil: paused) == .discard(reason: "what the command offers changed"))
        #expect(finalStep(startedFrom: paused, keptUntil: running) == .discard(reason: "what the command offers changed"))

        // Another agent started while the learner spoke: the tools match but the count in the scene state does not.
        let anotherAgentStarted = inputs(agentIsRunning: true, agentsArePaused: false, agentsRunning: 3)
        #expect(running.tools == anotherAgentStarted.tools)
        #expect(finalStep(startedFrom: running, keptUntil: anotherAgentStarted) == .discard(reason: "what the command offers changed"))

        // The last agent finished while the learner spoke, so the final "hold on" has nothing to hold: with nothing on screen
        // it no longer goes to the router, and the held command is discarded for that reason first.
        let nothingRunsAnymore = inputs(agentIsRunning: false, agentsArePaused: false, agentsRunning: 0)
        #expect(finalStep(startedFrom: running, keptUntil: nothingRunsAnymore, finalRoute: .keywordPath) == .discard(reason: "the final transcript does not go to the router"))
        #expect(finalStep(startedFrom: running, keptUntil: nothingRunsAnymore) == .discard(reason: "what the command offers changed"))

        // A request that came to wait while the agents were paused withholds resume_agents, since "go ahead" answers it.
        let pausedWithARequestWaiting = inputs(agentIsRunning: true, agentsArePaused: true, agentsRunning: 2, approvalIsWaiting: true)
        #expect(!pausedWithARequestWaiting.offeredToolNames.contains("resume_agents"))
        #expect(finalStep(startedFrom: paused, keptUntil: pausedWithARequestWaiting) == .discard(reason: "what the command offers changed"))
    }

    @Test func theFinalTranscriptKeepsTheCommandOnlyWhenEverythingItWasStartedFromStillHolds() {
        func step(final: String = "Turn it left.", route: TranscriptRoute = .voiceCommandRouter, sameRead: Bool = true, sameInputs: Bool = true, stillRunning: Bool = true) -> SpeculationStep {
            speculationStep(
                partialTranscript: "turn it left",
                finalTranscript: final,
                finalRoute: route,
                finalUsesTheSameScreenRead: sameRead,
                commandInputsAreUnchanged: sameInputs,
                heldCommandIsStillRunning: stillRunning
            )
        }
        #expect(step() == .confirm)
        // The microphone's tail caught one more word.
        #expect(step(final: "turn it left twice") == .discard(reason: "the final transcript has other words"))
        // The last word turned the request into one a keyword branch owns.
        #expect(step(final: "let me try it", route: .keywordBranch(.startExperiment)) == .discard(reason: "the final transcript does not go to the router"))
        #expect(step(route: .keywordPath) == .discard(reason: "the final transcript does not go to the router"))
        #expect(step(sameRead: false) == .discard(reason: "the page the command read is gone"))
        // A quiz question opened, or the Theme Studio closed, while the final transcript was on its way.
        #expect(step(sameInputs: false) == .discard(reason: "what the command offers changed"))
        // The held command's first turn failed, or its harness exited, while it waited, so a confirm would only reach the
        // failure's fallback, and the final transcript starts a fresh command instead.
        #expect(step(stillRunning: false) == .discard(reason: "the held command already ended in the harness"))
    }

    @Test func aHeldCommandWhoseTurnFailedOrWhoseHarnessExitedCountsAsEnded() throws {
        // The final transcript reads `isTracking` to tell a held command that still runs from one that already ended.
        let taskRouter = HarnessTaskRouter()
        _ = taskRouter.register(taskID: commandID)
        #expect(taskRouter.isTracking(taskID: commandID))
        taskRouter.route(try HarnessMessage(line: #"{"type":"task_failed","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","reason":"turn 1 got no reply from Claude within 8s"}"#))
        #expect(!taskRouter.isTracking(taskID: commandID))

        _ = taskRouter.register(taskID: commandID)
        taskRouter.failEveryTask(reason: "the agent harness exited")
        #expect(!taskRouter.isTracking(taskID: commandID))
    }

    @Test func aNewPressDiscardsTheCommandWaitingForItsFinalTranscriptAndTheCancelNamesNoCall() {
        let recorder = SpeculationLineRecorder()
        let lines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })
        var speculation = VoiceCommandSpeculationState.awaitingTheFinalTranscript(speculativeCommand(ofPress: 3, lines: lines))

        let commandToDiscard = speculation.end()
        #expect(commandToDiscard?.pressCount == 3)
        if case .none = speculation {} else { Issue.record("a press left the speculation in place") }
        // The harness held every call, so none was running and the cancel names none.
        commandToDiscard?.command.lines.commandWasCancelled()
        #expect(recorder.lines == [.cancelTask(taskID: commandID, runningToolUseID: nil)])
    }

    @Test func theFinalTranscriptTakesOnlyItsOwnPresssCommand() {
        let lines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in })
        var speculation = VoiceCommandSpeculationState.awaitingTheFinalTranscript(speculativeCommand(ofPress: 3, lines: lines))
        #expect(speculation.takeForTheFinalTranscript(ofPress: 2) == nil)
        if case .awaitingTheFinalTranscript = speculation {} else { Issue.record("another press's transcript ended this press's command") }
        #expect(speculation.takeForTheFinalTranscript(ofPress: 3)?.pressCount == 3)
        if case .none = speculation {} else { Issue.record("the final transcript left the command waiting") }
    }

    @Test func aFinalTranscriptThatArrivesBeforeTheScreenReadCancelsTheStart() async {
        let startOnceTheScreenIsRead = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        var speculation = VoiceCommandSpeculationState.waitingForTheScreenRead(pressCount: 5, start: startOnceTheScreenIsRead)
        #expect(speculation.takeForTheFinalTranscript(ofPress: 5) == nil)
        #expect(startOnceTheScreenIsRead.isCancelled)
        if case .none = speculation {} else { Issue.record("the start still waits after its final transcript arrived") }
    }

    @Test func newerPartialWordsStartTheCommandAgainOnlyWhenTheyAreOtherWords() {
        // Apple Speech's partial words lag the audio: at the release the partial was "Zoo", and "Zoom in" came later.
        let lines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in })
        let waitingCommand = VoiceCommandSpeculationState.awaitingTheFinalTranscript(speculativeCommand(ofPress: 3, lines: lines))
        #expect(waitingCommand.screenReadToStartFrom(whenThePartialWordsBecome: "turn it left twice")?.pressCount == 3)
        // The same words with other capitals and punctuation, and an empty partial, change nothing.
        #expect(waitingCommand.screenReadToStartFrom(whenThePartialWordsBecome: "Turn it left.") == nil)
        #expect(waitingCommand.screenReadToStartFrom(whenThePartialWordsBecome: "") == nil)

        // A press whose first partial had no words, or words the router does not take, starts on the first that do.
        let waitingForWords = VoiceCommandSpeculationState.waitingForWords(screenRead(ofPress: 4))
        #expect(waitingForWords.screenReadToStartFrom(whenThePartialWordsBecome: "zoom")?.pressCount == 4)
        #expect(waitingForWords.screenReadToStartFrom(whenThePartialWordsBecome: " ") == nil)

        // Before the release's screen read is in, and after the final transcript took the command, partial words start nothing.
        let startOnceTheScreenIsRead = Task<Void, Never> {}
        #expect(VoiceCommandSpeculationState.waitingForTheScreenRead(pressCount: 5, start: startOnceTheScreenIsRead).screenReadToStartFrom(whenThePartialWordsBecome: "zoom in") == nil)
        #expect(VoiceCommandSpeculationState.none.screenReadToStartFrom(whenThePartialWordsBecome: "zoom in") == nil)
    }

    @Test func anEmptyFinalTranscriptDiscardsTheWaitingCommandAtOnceWithACancelThatNamesNoCall() async {
        let recorder = SpeculationLineRecorder()
        let lines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })
        var speculation = VoiceCommandSpeculationState.awaitingTheFinalTranscript(speculativeCommand(ofPress: 3, lines: lines))

        // Another press's empty session leaves this press's command waiting.
        #expect(speculation.endForAnEmptyFinalTranscript(ofPress: 2) == nil)
        if case .awaitingTheFinalTranscript = speculation {} else { Issue.record("another press's empty session ended this command") }

        // The press's own session came back empty, so no final transcript will decide its command: it comes back to be
        // discarded now, and the cancel names no call, since the harness held every call.
        let commandToDiscard = speculation.endForAnEmptyFinalTranscript(ofPress: 3)
        #expect(commandToDiscard?.pressCount == 3)
        if case .none = speculation {} else { Issue.record("an empty final transcript left the command waiting") }
        commandToDiscard?.command.lines.commandWasCancelled()
        #expect(recorder.lines == [.cancelTask(taskID: commandID, runningToolUseID: nil)])

        // A press that was still waiting for words, or for its screen read, ends there too.
        var waitingForWords = VoiceCommandSpeculationState.waitingForWords(screenRead(ofPress: 4))
        #expect(waitingForWords.endForAnEmptyFinalTranscript(ofPress: 4) == nil)
        if case .none = waitingForWords {} else { Issue.record("an empty final transcript left the press waiting for words") }
        let startOnceTheScreenIsRead = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        var waitingForTheScreenRead = VoiceCommandSpeculationState.waitingForTheScreenRead(pressCount: 5, start: startOnceTheScreenIsRead)
        #expect(waitingForTheScreenRead.endForAnEmptyFinalTranscript(ofPress: 5) == nil)
        #expect(startOnceTheScreenIsRead.isCancelled)
    }

    @Test func theFinalTranscriptEndsAPressThatWaitsForWords() {
        var speculation = VoiceCommandSpeculationState.waitingForWords(screenRead(ofPress: 6))
        #expect(speculation.takeForTheFinalTranscript(ofPress: 7) == nil)
        if case .waitingForWords = speculation {} else { Issue.record("another press's transcript ended this press's wait") }
        #expect(speculation.takeForTheFinalTranscript(ofPress: 6) == nil)
        if case .none = speculation {} else { Issue.record("the final transcript left the press waiting for words") }
    }

    @Test func theLinesToTheHarnessSayWhetherACommandWaitsAndConfirmIt() {
        let waitingLine = HarnessCommand.voiceCommand(taskID: commandID, transcript: "turn it left", sceneState: .object([:]), tools: [], approvalAtPress: nil, waitsForTheFinalTranscript: true)
        #expect(waitingLine.json["waitsForTheFinalTranscript"] == .bool(true))
        // A normal command's line is the one the harness has always read.
        let normalLine = HarnessCommand.voiceCommand(taskID: commandID, transcript: "turn it left", sceneState: .object([:]), tools: [], approvalAtPress: nil)
        #expect(normalLine.json["waitsForTheFinalTranscript"] == nil)
        #expect(HarnessCommand.confirmVoiceCommand(taskID: commandID).json == .object([
            "type": .string("confirm_voice_command"),
            "taskID": .string(commandID.uuidString),
        ]))
    }

    @Test func theTimingLineSaysWhetherTheCommandStartedOnThePartialTranscript() {
        let released = Date(timeIntervalSinceReferenceDate: 1000)
        var timing = VoiceCommandTiming(
            pushToTalkReleasedAt: released,
            transcriptReadyAt: released.addingTimeInterval(0.7),
            commandSentAt: released.addingTimeInterval(0.35)
        )
        timing.speculation = .kept
        // A kept command went out before its transcript arrived.
        #expect(timing.logLine.contains("transcript_to_request_ms=-350 "))
        #expect(timing.logLine.hasSuffix(" speculation=kept"))
        timing.speculation = .discarded
        #expect(timing.logLine.hasSuffix(" speculation=discarded"))
        timing.speculation = nil
        #expect(timing.logLine.hasSuffix(" speculation=none"))
    }

    @Test func aRehearsalStepCanHearAPartialTranscriptFirst() {
        #expect(rehearsalStepPrefix("%turn it left") == (.hearsAPartialTranscriptFirst, "turn it left"))
        #expect(rehearsalPartialAndFinalTranscripts("turn it left") == ("turn it left", "turn it left"))
        #expect(rehearsalPartialAndFinalTranscripts("turn it >> turn it right") == ("turn it", "turn it right"))
    }

    @Test func aDebugLaunchCanCallTheWorkerOnAnotherPort() {
        #expect(debugWorkerPort(launchArguments: ["Clicky"]) == 8787)
        #expect(debugWorkerPort(launchArguments: ["Clicky", "--worker-port", "8796"]) == 8796)
        // A value that is not a usable port keeps the default, so a typo never points the app at nothing.
        #expect(debugWorkerPort(launchArguments: ["Clicky", "--worker-port", "eighty"]) == 8787)
        #expect(debugWorkerPort(launchArguments: ["Clicky", "--worker-port", "80"]) == 8787)
        #expect(debugWorkerPort(launchArguments: ["Clicky", "--worker-port"]) == 8787)
    }

    @Test func aDebugLaunchArgumentTurnsSpeculationOff() {
        #expect(VoiceCommandSpeculation.isOn(launchArguments: ["Clicky"]))
        #expect(!VoiceCommandSpeculation.isOn(launchArguments: ["Clicky", "--no-voice-command-speculation"]))
    }
}
