//
//  VoiceCommandSpeculationTests.swift
//  leanring-buddyTests
//
//  A voice command started on the partial transcript at push-to-talk release: where a transcript goes, when a partial
//  may start a command, when the final transcript keeps it, what a new press or the final transcript does to a command
//  waiting for it, and that the events the harness sends while it waits run once it is kept, with no deadline passing.
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
        approvalIsWaiting: false
    )

    private func speculativeCommand(ofPress pressCount: Int, lines: HarnessVoiceCommandLines) -> SpeculativeVoiceCommand {
        let (commandEvents, _) = AsyncStream<HarnessTaskEvent>.makeStream()
        return SpeculativeVoiceCommand(
            pressCount: pressCount,
            partialTranscript: "turn it left",
            pageRead: VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: Date()),
            inputs: VoiceCommandInputs(tools: [], pageState: nil, frontVideoState: nil, harnessSceneState: .object([:]), approvalIDWaitingWhenTheCommandStarted: nil),
            command: StartedHarnessVoiceCommand(commandID: commandID, lines: lines, events: commandEvents, sentAt: Date())
        )
    }

    @Test func theFinalTranscriptsCapitalsAndPunctuationStillMatchThePartialsWords() {
        #expect(transcriptWordsForComparison("Turn it left.") == transcriptWordsForComparison("turn it   left"))
        #expect(transcriptWordsForComparison("What's that part?") == ["whats", "that", "part"])
        #expect(transcriptWordsForComparison("turn it") != transcriptWordsForComparison("turn it left"))
        #expect(transcriptWordsForComparison("  ,. ").isEmpty)
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

    @Test func aPartialStartsACommandOnlyWhenTheBrainWouldTakeItAndNoApprovalCanBeAnswered() {
        func step(_ partial: String, route: TranscriptRoute = .voiceCommandRouter, harness: Bool = true, approvalID: String? = nil, isOn: Bool = true) -> SpeculativeStartStep {
            speculativeStartStep(partialTranscript: partial, partialRoute: route, voiceCommandsRunInTheHarness: harness, approvalIDSeenAtPress: approvalID, speculationIsOn: isOn)
        }
        #expect(step("turn it left") == .start)
        // The harness settles an approval from the transcript's own words, so a partial "yes" must never reach it.
        #expect(step("yes", approvalID: "approval-1") == .doNotStart(reason: "an approval request may be answered"))
        #expect(step("turn it left", route: .keywordBranch(.startExperiment)) == .doNotStart(reason: "the partial transcript does not go to the router"))
        #expect(step("stop the", route: .videoQuizCommand(.stop)) == .doNotStart(reason: "the partial transcript does not go to the router"))
        #expect(step("the heart", route: .keywordPath) == .doNotStart(reason: "the partial transcript does not go to the router"))
        #expect(step("") == .doNotStart(reason: "no words were heard yet"))
        #expect(step("turn it left", harness: false) == .doNotStart(reason: "voice commands run on the Worker router"))
        #expect(step("turn it left", isOn: false) == .doNotStart(reason: "speculation is turned off"))
    }

    @Test func theFinalTranscriptKeepsTheCommandOnlyWhenEverythingItWasStartedFromStillHolds() {
        func step(final: String = "Turn it left.", route: TranscriptRoute = .voiceCommandRouter, harness: Bool = true, sameRead: Bool = true, sameInputs: Bool = true) -> SpeculationStep {
            speculationStep(
                partialTranscript: "turn it left",
                finalTranscript: final,
                finalRoute: route,
                voiceCommandsRunInTheHarness: harness,
                finalUsesTheSameScreenRead: sameRead,
                commandInputsAreUnchanged: sameInputs
            )
        }
        #expect(step() == .confirm)
        // The microphone's tail caught one more word.
        #expect(step(final: "turn it left twice") == .discard(reason: "the final transcript has other words"))
        // The last word turned the request into one a keyword branch owns.
        #expect(step(final: "let me try it", route: .keywordBranch(.startExperiment)) == .discard(reason: "the final transcript does not go to the router"))
        #expect(step(route: .keywordPath) == .discard(reason: "the final transcript does not go to the router"))
        #expect(step(harness: false) == .discard(reason: "voice commands moved to the Worker router"))
        #expect(step(sameRead: false) == .discard(reason: "the page the command read is gone"))
        // A quiz question opened, or the Theme Studio closed, while the final transcript was on its way.
        #expect(step(sameInputs: false) == .discard(reason: "what the command offers changed"))
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

    @Test func eventsThatWaitedForTheFinalTranscriptRunOnceItIsKeptWithNoDeadlinePassing() async {
        // The harness sent the early line, and then the call and the finish once the command was confirmed, while the app
        // had not started reading the stream. The deadline starts with the loop, so a wait longer than it before the loop
        // never fails the command.
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuation.yield(.spokenLineIfEveryCallChanges("turned it left"))
        eventContinuation.yield(.toolCall(HarnessToolCall(toolUseID: "toolu_rotate", toolName: "rotate_model", input: [:], turnIndex: 0)))
        eventContinuation.yield(.voiceCommandFinished(spokenLine: "turned it left", gaveUp: false))
        try? await Task.sleep(for: .milliseconds(150))

        var deadlinePassed = false
        var ranCalls: [String] = []
        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in }),
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.05,
            whenNoEventArrivesInTime: { deadlinePassed = true },
            runTool: { toolCall, _ in
                ranCalls.append(toolCall.name)
                return .changed(state: nil)
            }
        )
        #expect(commandEnding == .finished(spokenLine: "turned it left", gaveUp: false))
        #expect(ranCalls == ["rotate_model"])
        #expect(!deadlinePassed)
    }

    @Test func theLinesToTheHarnessSayWhetherACommandWaitsAndConfirmIt() {
        let waitingLine = HarnessCommand.voiceCommand(taskID: commandID, transcript: "turn it left", sceneState: .object([:]), tools: [], approvalIDSeenAtPress: nil, waitsForTheFinalTranscript: true)
        #expect(waitingLine.json["waitsForTheFinalTranscript"] == .bool(true))
        // A normal command's line is the one the harness has always read.
        let normalLine = HarnessCommand.voiceCommand(taskID: commandID, transcript: "turn it left", sceneState: .object([:]), tools: [], approvalIDSeenAtPress: nil)
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
