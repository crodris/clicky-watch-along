//
//  HarnessVoiceCommand.swift
//  leanring-buddy
//
//  The app's side of a voice command on the brain, with the brainRunsInTheHarness flag on: the lines the command
//  writes to the harness, and the loop over the harness's events for it. The harness runs the model's turns
//  (harness/brainloop.go), and the app runs each tool call through runVoiceTool exactly as the old path does.
//

import Foundation
import os

/// The lines one voice command writes back to the harness: one tool_result per call, or one cancel_task.
///
/// A hand-off cancels the command's own task before its outcome exists: respondToTranscript cancels
/// currentResponseTask first, inside runAppVoiceTool, before `.handedOff` is returned. A plain cancel handler would then
/// tell the harness to cancel a command whose hand-off already started. So each branch of runAppVoiceTool that returns
/// `.handedOff` calls `handOffHasStarted()` right before its side effect, and the cancel handler, seeing the mark,
/// sends the handedOff result for the current call instead of cancel_task. The harness then marks the command complete.
///
/// The cancel handler of `withTaskCancellationHandler` runs wherever the cancel happens, off the main actor, so this
/// state sits behind a lock. Each call has one line to send, and the cancel handler and the normal path both claim it
/// under the lock before they write, so exactly one of them sends it.
nonisolated final class HarnessVoiceCommandLines: Sendable {
    private struct CommandLineState: Sendable {
        /// The call that runs now, whose result is the next line.
        var currentToolUseID: String?
        /// A branch of runAppVoiceTool is about to hand the request to a slow path for the current call.
        var handOffHasStarted = false
        /// The current call's line went out, from the normal path or the cancel handler.
        var currentCallLineWasSent = false
        /// The command's task was cancelled, so no later result goes out.
        var commandWasCancelled = false
    }

    let taskID: UUID
    private let lineState = OSAllocatedUnfairLock(initialState: CommandLineState())
    /// Writes one line through the harness's one stdin queue.
    private let sendLine: @Sendable (HarnessCommand) -> Void

    init(taskID: UUID, sendLine: @escaping @Sendable (HarnessCommand) -> Void) {
        self.taskID = taskID
        self.sendLine = sendLine
    }

    /// A tool call from the harness is about to run.
    func callStarted(toolUseID: String) {
        lineState.withLock { state in
            state.currentToolUseID = toolUseID
            state.handOffHasStarted = false
            state.currentCallLineWasSent = false
        }
    }

    /// Set by each branch of runAppVoiceTool that returns `.handedOff`, right before the side effect that may cancel
    /// the command's task.
    func handOffHasStarted() {
        lineState.withLock { state in state.handOffHasStarted = true }
    }

    /// The normal path's answer to the current call, once it has run. It sends nothing when the cancel handler already
    /// answered the call or told the harness to cancel. Returns whether the line went out.
    @discardableResult
    func sendTheResult(of outcome: VoiceToolOutcome) -> Bool {
        lineState.withLock { state in
            guard let toolUseID = state.currentToolUseID, !state.currentCallLineWasSent, !state.commandWasCancelled else { return false }
            state.currentCallLineWasSent = true
            sendLine(.voiceToolResult(taskID: taskID, toolUseID: toolUseID, outcome: outcome))
            return true
        }
    }

    /// The command's task was cancelled: by a push-to-talk press, by a new command, by the app's 10 second wait, or by
    /// a hand-off starting its own reply. A hand-off's cancel answers the call as handed off, so the harness ends the
    /// command as complete. Any other cancel tells the harness to cancel it.
    func commandWasCancelled() {
        lineState.withLock { state in
            guard !state.commandWasCancelled else { return }
            state.commandWasCancelled = true
            guard state.handOffHasStarted else {
                sendLine(.cancelTask(taskID: taskID))
                return
            }
            // A hand-off whose result already went out completed the command, so there is nothing to cancel.
            guard let toolUseID = state.currentToolUseID, !state.currentCallLineWasSent else { return }
            state.currentCallLineWasSent = true
            sendLine(.voiceToolResult(taskID: taskID, toolUseID: toolUseID, outcome: .handedOff))
        }
    }
}

/// How a voice command on the brain ended, which CompanionManager acts on.
nonisolated enum HarnessVoiceCommandEnding: Equatable, Sendable {
    /// Say the line, which may be empty, or the gave-up line, then go idle.
    case finished(spokenLine: String, gaveUp: Bool)
    /// The Worker, Anthropic, or the harness failed, or the harness sent nothing in time, so the router failure
    /// fallback runs.
    case failed(reason: String)
    /// A press, a new command, or a hand-off cancelled the command's task, which owns nothing more.
    case cancelled
}

/// How long the app waits for the harness's next event of a command before it fails the command, so a hung harness
/// falls back too. It is above the harness's own 8 second turn timeout, which ends a hung turn with task_failed first.
nonisolated let secondsToWaitForTheNextHarnessVoiceCommandEvent: Double = 10

/// Runs one voice command's events: each tool call through `runTool`, with the approval ID the learner had seen at the
/// press only for a call from the model's first turn, and its outcome back to the harness. It returns how the command
/// ended. The wait for each event has a deadline, which stops while a tool runs, since a tool such as play_video's check
/// takes its own time. When it passes, `whenNoEventArrivesInTime` must end the stream with a failure.
@MainActor
func runTheVoiceCommandEvents(
    _ commandEvents: AsyncStream<HarnessTaskEvent>,
    lines: HarnessVoiceCommandLines,
    approvalIDWaitingWhenTheCommandStarted: String?,
    secondsToWaitForAnEvent: Double = secondsToWaitForTheNextHarnessVoiceCommandEvent,
    whenNoEventArrivesInTime: @escaping @MainActor () -> Void,
    runTool: (_ toolCall: VoiceToolCall, _ approvalIDTheLearnerIsAnswering: String?) async -> VoiceToolOutcome
) async -> HarnessVoiceCommandEnding {
    var eventDeadline: Task<Void, Never>?
    func startTheEventDeadline() {
        eventDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(secondsToWaitForAnEvent))
            guard !Task.isCancelled else { return }
            whenNoEventArrivesInTime()
        }
    }
    defer { eventDeadline?.cancel() }

    return await withTaskCancellationHandler {
        startTheEventDeadline()
        for await commandEvent in commandEvents {
            eventDeadline?.cancel()
            switch commandEvent {
            case .toolCall(let harnessToolCall):
                // A push-to-talk press cancels the command, so no call of it runs after the press.
                guard !Task.isCancelled else { return .cancelled }
                let toolCall = VoiceToolCall(id: harnessToolCall.toolUseID, name: harnessToolCall.toolName, input: harnessToolCall.input)
                lines.callStarted(toolUseID: toolCall.id)
                // Only the model's first reply to the learner's words may answer a request. A later turn has read tool
                // results, which can hold text a page or a server wrote. A call with no turn counts as a later one.
                let outcome = await runTool(toolCall, harnessToolCall.turnIndex == 0 ? approvalIDWaitingWhenTheCommandStarted : nil)
                lines.sendTheResult(of: outcome)
                startTheEventDeadline()
            case .voiceCommandFinished(let spokenLine, let gaveUp):
                return .finished(spokenLine: spokenLine, gaveUp: gaveUp)
            case .failed(let reason):
                return .failed(reason: reason)
            case .finished:
                return .failed(reason: "the harness ended the voice command as a task")
            }
        }
        // The stream ends with no last event when the command's task is cancelled.
        return Task.isCancelled ? .cancelled : .failed(reason: "the harness ended the voice command with no result")
    } onCancel: {
        lines.commandWasCancelled()
    }
}
