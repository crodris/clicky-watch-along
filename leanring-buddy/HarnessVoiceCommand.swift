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
/// tell the harness to cancel a command whose hand-off already started. So every hand-off goes through
/// `voiceToolOutcome(of:handOffMark:)`, which calls `handOffHasStarted()` right before the new path starts, and the
/// cancel handler, seeing the mark, sends the handedOff result for the current call instead of cancel_task. The harness
/// then marks the command complete.
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

    /// Set by `voiceToolOutcome(of:handOffMark:)` for a hand-off, right before the new path starts, since starting it
    /// may cancel the command's task.
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

/// What one of the app's voice tools does: an outcome it already has, or a hand-off to a slow path that owns the reply
/// from then on. runAppVoiceTool's switch returns one, and only `voiceToolOutcome(of:handOffMark:)` starts a hand-off's
/// new path, so no branch can hand off without the harness command's mark.
enum AppVoiceToolStep {
    /// The tool ran, or refused, and this is its outcome. It is never `.handedOff`, which only `.handOff` produces.
    case outcome(VoiceToolOutcome)
    /// Start this path, such as respondToTranscript, which takes over what Clicky says next.
    case handOff(startTheNewPath: () -> Void)
}

/// The outcome of one app voice tool's step. A hand-off sets the harness command's mark before its new path starts,
/// since the new path may cancel the command's own task, whose cancel handler reads the mark. The old path and the debug
/// server pass no mark.
func voiceToolOutcome(of appVoiceToolStep: AppVoiceToolStep, handOffMark: HarnessVoiceCommandLines?) -> VoiceToolOutcome {
    switch appVoiceToolStep {
    case .outcome(let outcome):
        assert(outcome != .handedOff, "A hand-off must be an AppVoiceToolStep.handOff, so the harness command's mark is set")
        return outcome
    case .handOff(let startTheNewPath):
        handOffMark?.handOffHasStarted()
        startTheNewPath()
        return .handedOff
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
/// takes its own time. When it passes, `whenNoEventArrivesInTime` must end the stream with a failure, and no call still
/// queued behind the deadline runs, since the router failure fallback runs instead.
///
/// A hand-off ends the command at once as finished with no spoken line, since the harness's next step after a
/// `.handedOff` result is always to finish silently. Waiting for its voice_command_finished would let a harness that
/// exits or stalls fail the command, and the fallback would then answer a request the hand-off already took.
@MainActor
func runTheVoiceCommandEvents(
    _ commandEvents: AsyncStream<HarnessTaskEvent>,
    lines: HarnessVoiceCommandLines,
    approvalIDWaitingWhenTheCommandStarted: String?,
    secondsToWaitForAnEvent: Double = secondsToWaitForTheNextHarnessVoiceCommandEvent,
    whenNoEventArrivesInTime: @escaping @MainActor () -> Void,
    runTool: (_ toolCall: VoiceToolCall, _ approvalIDTheLearnerIsAnswering: String?) async -> VoiceToolOutcome
) async -> HarnessVoiceCommandEnding {
    let eventDeadlineRecord = HarnessVoiceCommandDeadlineRecord()
    var eventDeadline: Task<Void, Never>?
    func startTheEventDeadline() {
        eventDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(secondsToWaitForAnEvent))
            guard !Task.isCancelled else { return }
            // An event can already sit in the stream when this runs, since the loop resumes only after it.
            eventDeadlineRecord.deadlineHasPassed = true
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
                // The deadline already told the harness to cancel and failed the command, so the fallback owns it.
                guard !eventDeadlineRecord.deadlineHasPassed else { return .failed(reason: "a tool call arrived after the wait for it ran out") }
                let toolCall = VoiceToolCall(id: harnessToolCall.toolUseID, name: harnessToolCall.toolName, input: harnessToolCall.input)
                lines.callStarted(toolUseID: toolCall.id)
                // Only the model's first reply to the learner's words may answer a request. A later turn has read tool
                // results, which can hold text a page or a server wrote. A call with no turn counts as a later one.
                let outcome = await runTool(toolCall, harnessToolCall.turnIndex == 0 ? approvalIDWaitingWhenTheCommandStarted : nil)
                lines.sendTheResult(of: outcome)
                if outcome == .handedOff {
                    return .finished(spokenLine: "", gaveUp: false)
                }
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

/// Whether a command's wait for its next event ran out. The deadline task and the event loop both run on the main actor,
/// and the loop reads it before it runs any call.
@MainActor
private final class HarnessVoiceCommandDeadlineRecord {
    var deadlineHasPassed = false
}
