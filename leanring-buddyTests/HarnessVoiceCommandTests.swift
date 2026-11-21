//
//  HarnessVoiceCommandTests.swift
//  leanring-buddyTests
//
//  A voice command on the brain, from the app's side: which approval ID each call carries, which lines the command
//  writes back to the harness when a hand-off or a push-to-talk press cancels it, how a hand-off ends the command, and
//  what a call queued behind the passed deadline does. The harness's own rules are tested
//  in harness/brainloop_test.go.
//

import Foundation
import os
import Testing
@testable import Clicky

/// Keeps every line a command writes, in order, as AgentHarness's stdin queue would send them.
private final class HarnessLineRecorder: Sendable {
    private let recordedLines = OSAllocatedUnfairLock<[HarnessCommand]>(initialState: [])

    var lines: [HarnessCommand] { recordedLines.withLock { lines in lines } }

    func record(_ harnessCommand: HarnessCommand) {
        recordedLines.withLock { lines in lines.append(harnessCommand) }
    }
}

@MainActor
struct HarnessVoiceCommandTests {
    private let commandID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    private func approvalCall(toolUseID: String, turnIndex: Int?) -> HarnessTaskEvent {
        .toolCall(HarnessToolCall(toolUseID: toolUseID, toolName: "answer_approval", input: ["approved": .bool(true), "always": .bool(false)], turnIndex: turnIndex))
    }

    @Test func onlyACallFromTheFirstTurnCarriesTheApprovalIDTheLearnerHadSeenAtThePress() async {
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuation.yield(approvalCall(toolUseID: "toolu_first_turn", turnIndex: 0))
        eventContinuation.yield(approvalCall(toolUseID: "toolu_second_turn", turnIndex: 1))
        eventContinuation.yield(approvalCall(toolUseID: "toolu_no_turn", turnIndex: nil))
        eventContinuation.yield(.voiceCommandFinished(spokenLine: "allowed it", gaveUp: false))
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })

        var approvalIDsTheCallsCarried: [String?] = []
        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: commandLines,
            approvalIDWaitingWhenTheCommandStarted: "approval-seen-at-the-press",
            whenNoEventArrivesInTime: {},
            runTool: { _, approvalIDTheLearnerIsAnswering in
                approvalIDsTheCallsCarried.append(approvalIDTheLearnerIsAnswering)
                return .changed(state: nil)
            }
        )

        #expect(commandEnding == .finished(spokenLine: "allowed it", gaveUp: false))
        // A later turn has read tool results, which a page or a server may have written, so its yes reaches no request.
        #expect(approvalIDsTheCallsCarried == ["approval-seen-at-the-press", nil, nil])
        #expect(recorder.lines == [
            .voiceToolResult(taskID: commandID, toolUseID: "toolu_first_turn", outcome: .changed(state: nil)),
            .voiceToolResult(taskID: commandID, toolUseID: "toolu_second_turn", outcome: .changed(state: nil)),
            .voiceToolResult(taskID: commandID, toolUseID: "toolu_no_turn", outcome: .changed(state: nil)),
        ])
    }

    @Test func aPopOutWritesOneHandedOffResultAndNoCancel() async {
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuation.yield(.toolCall(HarnessToolCall(toolUseID: "toolu_pop", toolName: "pop_out", input: [:], turnIndex: 0)))
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })

        let commandTask = Task { @MainActor in
            await runTheVoiceCommandEvents(
                commandEvents,
                lines: commandLines,
                approvalIDWaitingWhenTheCommandStarted: nil,
                whenNoEventArrivesInTime: {},
                runTool: { _, _ in
                    // What runAppVoiceTool's pop_out branch does: the mark, then respondToTranscript, whose first line
                    // cancels currentResponseTask, which is this command's task, before .handedOff is returned.
                    commandLines.handOffHasStarted()
                    withUnsafeCurrentTask { commandTaskItself in commandTaskItself?.cancel() }
                    return .handedOff
                }
            )
        }

        // The hand-off's own reply owns what Clicky says, and CompanionManager says nothing for a cancelled task.
        #expect(await commandTask.value == .finished(spokenLine: "", gaveUp: false))
        #expect(recorder.lines == [.voiceToolResult(taskID: commandID, toolUseID: "toolu_pop", outcome: .handedOff)])
    }

    @Test func aHandOffThatLeavesTheCommandRunningFinishesItWithoutWaitingForTheHarness() async {
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuation.yield(.toolCall(HarnessToolCall(toolUseID: "toolu_close", toolName: "close_scene", input: [:], turnIndex: 0)))
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })

        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: commandLines,
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.05,
            whenNoEventArrivesInTime: {
                // A harness that stalls after the result: the fallback must not answer a request close_scene took.
                eventContinuation.yield(.failed(reason: "the agent harness sent nothing for 10 seconds"))
                eventContinuation.finish()
            },
            runTool: { _, _ in
                // close_scene hands off without cancelling the command's task.
                .handedOff
            }
        )

        #expect(commandEnding == .finished(spokenLine: "", gaveUp: false))
        #expect(recorder.lines == [.voiceToolResult(taskID: commandID, toolUseID: "toolu_close", outcome: .handedOff)])
    }

    @Test func aHandOffStepSetsTheMarkBeforeItsNewPathStarts() {
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })
        commandLines.callStarted(toolUseID: "toolu_pop")
        var newPathStarted = false

        let outcome = voiceToolOutcome(of: .handOff(startTheNewPath: {
            // What respondToTranscript does first: cancel currentResponseTask, which is the command's own task.
            commandLines.commandWasCancelled()
            newPathStarted = true
        }), handOffMark: commandLines)

        #expect(outcome == .handedOff)
        #expect(newPathStarted)
        // With the mark set first, the cancel answers the call as handed off instead of cancelling the command.
        #expect(recorder.lines == [.voiceToolResult(taskID: commandID, toolUseID: "toolu_pop", outcome: .handedOff)])
    }

    @Test func aToolCallQueuedWhenTheWaitRunsOutNeverRuns() async {
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })
        var toolCallsThatRan = 0

        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: commandLines,
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.05,
            whenNoEventArrivesInTime: {
                // The harness's call reached the stream just as the wait ran out, ahead of the failure that ends it.
                eventContinuation.yield(.toolCall(HarnessToolCall(toolUseID: "toolu_rotate", toolName: "rotate_model", input: [:], turnIndex: 0)))
                commandLines.commandWasCancelled()
                eventContinuation.yield(.failed(reason: "the agent harness sent nothing for 10 seconds"))
                eventContinuation.finish()
            },
            runTool: { _, _ in
                toolCallsThatRan += 1
                return .changed(state: nil)
            }
        )

        // The router failure fallback runs, so the late call must not run as well.
        if case .failed = commandEnding {} else { Issue.record("expected the command to fail, got \(commandEnding)") }
        #expect(toolCallsThatRan == 0)
        #expect(recorder.lines == [.cancelTask(taskID: commandID)])
    }

    @Test func theWaitForTheNextEventIs35SecondsAfterAPlanningLineAnd10SecondsOtherwise() async {
        #expect(secondsToWaitForTheNextHarnessVoiceCommandEvent == 10)
        #expect(secondsToWaitForAPlanningTurn == 35)

        // After the planning line the larger wait applies: the finish comes after the normal wait, and still counts.
        // The planning wait is a minute, far past the 300 ms finish, so a busy CI runner that stalls this test
        // for seconds cannot run it out. On 2026-11-21 a 5 second wait ran out on main's CI run for 30862e4.
        let (planningEvents, planningContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        planningContinuation.yield(.planningTurnStarted)
        let sendsTheFinishLater = Task {
            try? await Task.sleep(for: .milliseconds(300))
            planningContinuation.yield(.voiceCommandFinished(spokenLine: "jumped to it", gaveUp: false))
            planningContinuation.finish()
        }
        var waitRanOutAfterThePlanningLine = false
        let endingAfterThePlanningLine = await runTheVoiceCommandEvents(
            planningEvents,
            lines: HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in }),
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.05,
            secondsToWaitAfterAPlanningLine: 60,
            whenNoEventArrivesInTime: { waitRanOutAfterThePlanningLine = true },
            runTool: { _, _ in .changed(state: nil) }
        )
        await sendsTheFinishLater.value
        #expect(endingAfterThePlanningLine == .finished(spokenLine: "jumped to it", gaveUp: false))
        #expect(!waitRanOutAfterThePlanningLine)

        // With no planning line the normal wait applies, and it runs out when no event arrives.
        let (plainEvents, plainContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        let endingWithNoPlanningLine = await runTheVoiceCommandEvents(
            plainEvents,
            lines: HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in }),
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.05,
            secondsToWaitAfterAPlanningLine: 5,
            whenNoEventArrivesInTime: {
                plainContinuation.yield(.failed(reason: "the agent harness sent nothing in time"))
                plainContinuation.finish()
            },
            runTool: { _, _ in .changed(state: nil) }
        )
        #expect(endingWithNoPlanningLine == .failed(reason: "the agent harness sent nothing in time"))

        // After the planning line a wait still runs, and it runs out when no event arrives. The backstop closes the
        // stream if no wait runs at all, so that mistake fails the test instead of hanging it.
        let (silentPlanningEvents, silentPlanningContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        silentPlanningContinuation.yield(.planningTurnStarted)
        let backstop = Task {
            // A minute, like the planning wait above, so a stalled runner cannot run it out before the 0.2 second wait.
            try? await Task.sleep(for: .seconds(60))
            silentPlanningContinuation.finish()
        }
        let endingWhenThePlanningTurnSendsNothing = await runTheVoiceCommandEvents(
            silentPlanningEvents,
            lines: HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in }),
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.05,
            secondsToWaitAfterAPlanningLine: 0.2,
            whenNoEventArrivesInTime: {
                silentPlanningContinuation.yield(.failed(reason: "the planning wait ran out"))
                silentPlanningContinuation.finish()
            },
            runTool: { _, _ in .changed(state: nil) }
        )
        backstop.cancel()
        #expect(endingWhenThePlanningTurnSendsNothing == .failed(reason: "the planning wait ran out"))
    }

    @Test func aCancelJustBeforeTheHandOffMarkSendsCancelAndOneJustAfterSendsOnlyTheHandedOffResult() {
        let cancelledBeforeTheMark = HarnessLineRecorder()
        let linesCancelledBeforeTheMark = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in cancelledBeforeTheMark.record(harnessCommand) })
        linesCancelledBeforeTheMark.callStarted(toolUseID: "toolu_pop")
        linesCancelledBeforeTheMark.commandWasCancelled()
        linesCancelledBeforeTheMark.handOffHasStarted()
        linesCancelledBeforeTheMark.sendTheResult(of: .handedOff)
        #expect(cancelledBeforeTheMark.lines == [.cancelTask(taskID: commandID, runningToolUseID: "toolu_pop")])

        let cancelledAfterTheMark = HarnessLineRecorder()
        let linesCancelledAfterTheMark = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in cancelledAfterTheMark.record(harnessCommand) })
        linesCancelledAfterTheMark.callStarted(toolUseID: "toolu_pop")
        linesCancelledAfterTheMark.handOffHasStarted()
        linesCancelledAfterTheMark.commandWasCancelled()
        linesCancelledAfterTheMark.sendTheResult(of: .handedOff)
        // A second cancel, such as a press during the hand-off's reply, sends nothing either.
        linesCancelledAfterTheMark.commandWasCancelled()
        #expect(cancelledAfterTheMark.lines == [.voiceToolResult(taskID: commandID, toolUseID: "toolu_pop", outcome: .handedOff)])

        // A hand-off that does not cancel the command, such as closing a scene with no video to resume, sends its
        // result on the normal path. A press after it sends nothing, since the command is complete.
        let cancelledAfterTheResult = HarnessLineRecorder()
        let linesCancelledAfterTheResult = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in cancelledAfterTheResult.record(harnessCommand) })
        linesCancelledAfterTheResult.callStarted(toolUseID: "toolu_close")
        linesCancelledAfterTheResult.handOffHasStarted()
        linesCancelledAfterTheResult.sendTheResult(of: .handedOff)
        linesCancelledAfterTheResult.sendTheResult(of: .handedOff)
        linesCancelledAfterTheResult.commandWasCancelled()
        #expect(cancelledAfterTheResult.lines == [.voiceToolResult(taskID: commandID, toolUseID: "toolu_close", outcome: .handedOff)])
    }

    @Test func aCancelAfterACallFinishedWritesItsResultBeforeCancelTaskAndACancelDuringTheCallWritesOnlyCancelTask() {
        // The call finished, and the press arrived before its result line went out: the harness must hear the result
        // first, so the call's action line reaches the next command's interrupted_before line.
        let cancelledAfterTheCallFinished = HarnessLineRecorder()
        let linesCancelledAfterTheCallFinished = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in cancelledAfterTheCallFinished.record(harnessCommand) })
        linesCancelledAfterTheCallFinished.callStarted(toolUseID: "toolu_rotate")
        linesCancelledAfterTheCallFinished.callFinished(with: .changed(state: nil))
        linesCancelledAfterTheCallFinished.commandWasCancelled()
        // The normal path's own line, and a second cancel, add nothing: the result went out once.
        linesCancelledAfterTheCallFinished.sendTheResult(of: .changed(state: nil))
        linesCancelledAfterTheCallFinished.commandWasCancelled()
        #expect(cancelledAfterTheCallFinished.lines == [
            .voiceToolResult(taskID: commandID, toolUseID: "toolu_rotate", outcome: .changed(state: nil)),
            .cancelTask(taskID: commandID),
        ])

        // A call still running at the press has no outcome, so only the cancel goes out, naming the call so the harness
        // can reverse it, and a call that finishes after the cancel writes nothing.
        let cancelledDuringTheCall = HarnessLineRecorder()
        let linesCancelledDuringTheCall = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in cancelledDuringTheCall.record(harnessCommand) })
        linesCancelledDuringTheCall.callStarted(toolUseID: "toolu_play")
        linesCancelledDuringTheCall.commandWasCancelled()
        linesCancelledDuringTheCall.callFinished(with: .changed(state: nil))
        linesCancelledDuringTheCall.sendTheResult(of: .changed(state: nil))
        #expect(cancelledDuringTheCall.lines == [.cancelTask(taskID: commandID, runningToolUseID: "toolu_play")])

        // The result of an earlier call that already went out is never written again for the next call's cancel.
        let cancelledBetweenCalls = HarnessLineRecorder()
        let linesCancelledBetweenCalls = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in cancelledBetweenCalls.record(harnessCommand) })
        linesCancelledBetweenCalls.callStarted(toolUseID: "toolu_rotate")
        linesCancelledBetweenCalls.callFinished(with: .changed(state: nil))
        linesCancelledBetweenCalls.sendTheResult(of: .changed(state: nil))
        linesCancelledBetweenCalls.commandWasCancelled()
        #expect(cancelledBetweenCalls.lines == [
            .voiceToolResult(taskID: commandID, toolUseID: "toolu_rotate", outcome: .changed(state: nil)),
            .cancelTask(taskID: commandID),
        ])
    }

    @Test func aHandOffMarkWinsOverAFinishedCallsResultWhenTheCommandIsCancelled() {
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })
        commandLines.callStarted(toolUseID: "toolu_pop")
        commandLines.callFinished(with: .handedOff)
        commandLines.handOffHasStarted()
        commandLines.commandWasCancelled()
        // One result, as handed off, and no cancel: the command is complete.
        #expect(recorder.lines == [.voiceToolResult(taskID: commandID, toolUseID: "toolu_pop", outcome: .handedOff)])
    }

    @Test func theWaitForAnEventStopsWhileAToolRunsAndFailsTheCommandWhenNothingComes() async {
        final class DeadlineRecord {
            var toolIsRunning = false
            var deadlinePassedWhileAToolRan = false
            var deadlinesPassed = 0
        }
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuation.yield(.toolCall(HarnessToolCall(toolUseID: "toolu_play", toolName: "play_video", input: [:], turnIndex: 0)))
        let recorder = HarnessLineRecorder()
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { harnessCommand in recorder.record(harnessCommand) })
        let deadlineRecord = DeadlineRecord()

        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: commandLines,
            approvalIDWaitingWhenTheCommandStarted: nil,
            secondsToWaitForAnEvent: 0.1,
            whenNoEventArrivesInTime: {
                deadlineRecord.deadlinesPassed += 1
                deadlineRecord.deadlinePassedWhileAToolRan = deadlineRecord.deadlinePassedWhileAToolRan || deadlineRecord.toolIsRunning
                // What CompanionManager does: tell the harness, and end the stream with the failure.
                commandLines.commandWasCancelled()
                eventContinuation.yield(.failed(reason: "the agent harness sent nothing for 10 seconds"))
                eventContinuation.finish()
            },
            runTool: { _, _ in
                // play_video checks for about 1.6 seconds, longer than the wait for an event.
                deadlineRecord.toolIsRunning = true
                try? await Task.sleep(for: .milliseconds(300))
                deadlineRecord.toolIsRunning = false
                return .changed(state: nil)
            }
        )

        #expect(commandEnding == .failed(reason: "the agent harness sent nothing for 10 seconds"))
        #expect(deadlineRecord.deadlinesPassed == 1)
        #expect(!deadlineRecord.deadlinePassedWhileAToolRan)
        #expect(recorder.lines == [
            .voiceToolResult(taskID: commandID, toolUseID: "toolu_play", outcome: .changed(state: nil)),
            .cancelTask(taskID: commandID),
        ])
    }
}
