//
//  AgentHarness.swift
//  leanring-buddy
//
//  The task agent's loop runs in a Go helper process, harness/ in the repo, bundled at Contents/Helpers/
//  clicky-agent-harness. The voice command brain (harness/brain.go) runs there too. The app and the harness talk in JSON lines on the harness's stdin and stdout. The harness runs Claude through
//  the Worker's /v1/messages passthrough. It asks the app for the task agent's tools that touch the Mac or Notion, and
//  for a voice command's scene, video, and agent tools. harness/protocol.go is the other half of the messages in this
//  file.
//

import Combine
import Foundation
import os

// MARK: - Messages from the harness

/// One tool call of a task agent's turn, or of a voice command's. The name stays text, so a name this app does not know
/// still reaches the task loop, which answers it with an error instead of leaving the agent waiting.
nonisolated struct HarnessToolCall: Equatable, Sendable {
    let toolUseID: String
    let toolName: String
    let input: [String: JSONValue]
}

/// What the app hears from the harness for one task or voice command. The stream of events ends after finished,
/// failed, or voiceCommandFinished.
nonisolated enum HarnessTaskEvent: Equatable, Sendable {
    case toolCall(HarnessToolCall)
    case finished(spokenSummary: String)
    case failed(reason: String)
    /// A voice command ended. spokenLine may be empty, and gaveUp says its last turn still needed the model.
    case voiceCommandFinished(spokenLine: String, gaveUp: Bool)
    /// The line a voice command will speak if every call of the turn that follows changes the screen, and the turn's tool
    /// names in order. It comes before the turn's first call, so its audio can be fetched while the calls run. Only a voice
    /// command gets it.
    case spokenLineIfEveryCallChanges(spokenLine: String, toolNames: [String])
    /// The brain's last turn runs on the larger model, which takes longer, so the command's wait for its next event is
    /// longer too (`secondsToWaitForAPlanningTurn`). Only a voice command gets it.
    case planningTurnStarted
}

/// What a tool may do, which decides whether the harness asks before running it. harness/approval.go is the other half.
/// A capability this app does not know still parses, so the desk can answer no at once and the task does not wait.
nonisolated enum HarnessCapability: Equatable, Sendable {
    /// Puts something where others see it or changes a thing: a message, a page, a link with data in it, the clipboard.
    case sends
    case deletes
    case spends
    /// Reads what the learner never offered: the screen, the clipboard.
    case readsPrivate
    case unknown(String)

    init(wireName: String) {
        switch wireName {
        case "sends": self = .sends
        case "deletes": self = .deletes
        case "spends": self = .spends
        case "reads_private": self = .readsPrivate
        default: self = .unknown(wireName)
        }
    }
}

/// "once" covers one call. "always" covers that tool at that capability for the rest of the task that asked.
nonisolated enum HarnessApprovalScope: String, Equatable, Sendable {
    case once
    case always
}

/// The harness waits for an answer to this before it runs one tool call.
nonisolated struct HarnessApprovalRequest: Equatable, Sendable {
    let taskID: UUID
    let approvalID: String
    let capability: HarnessCapability
    /// In plain words, from the harness, from the call's own input.
    let summary: String
}

/// One line the harness wrote, checked at the boundary. A line that is not one of these is dropped and logged.
nonisolated enum HarnessMessage: Equatable, Sendable {
    case ready
    case approvalRequest(HarnessApprovalRequest)
    case toolCall(taskID: UUID, HarnessToolCall)
    case taskFinished(taskID: UUID, spokenSummary: String)
    case taskFailed(taskID: UUID, reason: String)
    case voiceCommandFinished(taskID: UUID, spokenLine: String, gaveUp: Bool)
    /// voice_line_if_every_call_changes: the line the command's next turn speaks if every one of its calls changes the
    /// screen, sent before the turn's first tool_call (spokenLineIfEveryCallChanges in harness/brain.go).
    case voiceLineIfEveryCallChanges(taskID: UUID, spokenLine: String, toolNames: [String])
    /// The harness's gate took this answer to an approval request. It is the one outcome the desk shows, whether the
    /// learner clicked or said it, and the first answer wins.
    case approvalSettled(approvalID: String, approved: Bool, scope: HarnessApprovalScope)
    /// `taskID` is set only on the few lines about one voice command that the app acts on, such as the planning line.
    case log(taskID: UUID? = nil, message: String)

    enum ParseError: Error, Equatable {
        case notAJSONObject
        case unknownType(String)
        case missingField(messageType: String, fieldName: String)
    }

    init(line: String) throws {
        guard let messageJSON = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
              messageJSON.objectValue != nil else {
            throw ParseError.notAJSONObject
        }
        let messageType = messageJSON["type"]?.stringValue ?? ""

        func requiredText(_ fieldName: String) throws -> String {
            guard let text = messageJSON[fieldName]?.stringValue else {
                throw ParseError.missingField(messageType: messageType, fieldName: fieldName)
            }
            return text
        }
        func requiredTaskID() throws -> UUID {
            guard let taskID = UUID(uuidString: try requiredText("taskID")) else {
                throw ParseError.missingField(messageType: messageType, fieldName: "taskID")
            }
            return taskID
        }

        switch messageType {
        case "ready":
            self = .ready
        case "approval_request":
            self = .approvalRequest(HarnessApprovalRequest(
                taskID: try requiredTaskID(),
                approvalID: try requiredText("approvalID"),
                capability: HarnessCapability(wireName: try requiredText("capability")),
                summary: try requiredText("summary")
            ))
        case "tool_call":
            guard let input = messageJSON["input"]?.objectValue else {
                throw ParseError.missingField(messageType: messageType, fieldName: "input")
            }
            self = .toolCall(
                taskID: try requiredTaskID(),
                HarnessToolCall(
                    toolUseID: try requiredText("toolUseID"),
                    toolName: try requiredText("name"),
                    input: input
                )
            )
        case "task_finished":
            self = .taskFinished(taskID: try requiredTaskID(), spokenSummary: try requiredText("spokenSummary"))
        case "task_failed":
            self = .taskFailed(taskID: try requiredTaskID(), reason: try requiredText("reason"))
        case "voice_command_finished":
            guard let gaveUp = messageJSON["gaveUp"]?.boolValue else {
                throw ParseError.missingField(messageType: messageType, fieldName: "gaveUp")
            }
            self = .voiceCommandFinished(taskID: try requiredTaskID(), spokenLine: try requiredText("spokenLine"), gaveUp: gaveUp)
        case "voice_line_if_every_call_changes":
            guard let toolNameValues = messageJSON["toolNames"]?.arrayValue else {
                throw ParseError.missingField(messageType: messageType, fieldName: "toolNames")
            }
            let toolNames = toolNameValues.compactMap(\.stringValue)
            guard toolNames.count == toolNameValues.count else {
                throw ParseError.missingField(messageType: messageType, fieldName: "toolNames")
            }
            self = .voiceLineIfEveryCallChanges(taskID: try requiredTaskID(), spokenLine: try requiredText("spokenLine"), toolNames: toolNames)
        case "approval_settled":
            guard let approved = messageJSON["approved"]?.boolValue else {
                throw ParseError.missingField(messageType: messageType, fieldName: "approved")
            }
            self = .approvalSettled(
                approvalID: try requiredText("approvalID"),
                approved: approved,
                scope: HarnessApprovalScope(rawValue: messageJSON["scope"]?.stringValue ?? "") ?? .once
            )
        case "log":
            self = .log(taskID: messageJSON["taskID"]?.stringValue.flatMap { taskIDText in UUID(uuidString: taskIDText) }, message: try requiredText("message"))
        default:
            throw ParseError.unknownType(messageType)
        }
    }
}

// MARK: - Messages to the harness

nonisolated enum HarnessCommand: Equatable, Sendable {
    /// `skill` names a skill file the harness reads from its skills folders, or is nil for a task with no skill.
    /// `startsPaused` is true for a task started while the learner has paused every agent, so its first turn waits for
    /// `resumeTask`.
    case startTask(taskID: UUID, goal: String, frontTabTitle: String?, frontTabURL: String?, skill: String?, startsPaused: Bool = false)
    /// `content` is a string or an array of content blocks, such as the image block look_at_video returns.
    /// `sourceURL` is the video link a read_video_captions result is about. The harness lets a task cite only that link
    /// from it and never reads a link out of `content`, which a video's own text can write, so it is set for that tool
    /// alone and left out of the line otherwise.
    case toolResult(taskID: UUID, toolUseID: String, content: JSONValue, isError: Bool, sourceURL: String? = nil)
    /// `runningToolUseID` is set only for a voice command: the call the app had started and not answered when the press came,
    /// which may already have changed the screen. The harness reverses a cut-off page call on "undo that" only when this
    /// names it, since a call the press caught before it started never ran.
    case cancelTask(taskID: UUID, runningToolUseID: String? = nil)
    /// Holds a task's next model turn and next tool call while the learner has paused every agent. A turn or a call
    /// already in flight finishes, and a pending approval stays pending.
    case pauseTask(taskID: UUID)
    /// Lets a paused task go on.
    case resumeTask(taskID: UUID)
    /// The answer to one approval_request, named by the harness's approvalID.
    case approvalResult(approvalID: String, approved: Bool, scope: HarnessApprovalScope)
    /// Starts a voice command on the brain. `sceneState` is `voiceCommandSceneState`'s object, and `tools` the list after
    /// `voiceToolsOfferedToTheModel`. The line carries no recent actions, since the brain keeps every earlier command in
    /// its own session, and its scene state has no `approvalWaiting`, since the harness names the waiting request's kind of
    /// action itself. `approvalAtPress` is the request the card showed at the press and whether a card had shown its whole
    /// summary for a second then, the facts about approvals only the app knows. It goes out as `approvalIDWaitingAtPress`
    /// and `approvalIDSeenAtPress`, the second null unless the summary was seen. `waitsForTheFinalTranscript` is true for
    /// a command started on the partial transcript, which the harness holds before its first call until
    /// `confirmVoiceCommand` arrives. Such a command never has an approval waiting at the press, seen or not, since the
    /// harness would settle a partial "yes" or "no" as the answer.
    case voiceCommand(taskID: UUID, transcript: String, sceneState: JSONValue, tools: [VoiceToolDescriptor], approvalAtPress: ApprovalAtPress?, waitsForTheFinalTranscript: Bool = false)
    /// The final transcript has the words a command waiting for it started on, so the command goes on.
    case confirmVoiceCommand(taskID: UUID)
    /// A voice command's tool_result, which carries what the tool did, so the brain knows whether to speak, ask the
    /// model again, or stop for a hand-off.
    case voiceToolResult(taskID: UUID, toolUseID: String, outcome: VoiceToolOutcome)

    var json: JSONValue {
        switch self {
        case .startTask(let taskID, let goal, let frontTabTitle, let frontTabURL, let skill, let startsPaused):
            var startFields: [String: JSONValue] = [
                "type": .string("start_task"),
                "taskID": .string(taskID.uuidString),
                "goal": .string(goal),
                "frontTabTitle": frontTabTitle.map(JSONValue.string) ?? .null,
                "frontTabURL": frontTabURL.map(JSONValue.string) ?? .null,
                "skill": skill.map(JSONValue.string) ?? .null,
            ]
            if startsPaused {
                startFields["startsPaused"] = .bool(true)
            }
            return .object(startFields)
        case .toolResult(let taskID, let toolUseID, let content, let isError, let sourceURL):
            var toolResultFields: [String: JSONValue] = [
                "type": .string("tool_result"),
                "taskID": .string(taskID.uuidString),
                "toolUseID": .string(toolUseID),
                "content": content,
                "isError": .bool(isError),
            ]
            if let sourceURL {
                toolResultFields["sourceURL"] = .string(sourceURL)
            }
            return .object(toolResultFields)
        case .cancelTask(let taskID, let runningToolUseID):
            var cancelFields: [String: JSONValue] = ["type": .string("cancel_task"), "taskID": .string(taskID.uuidString)]
            if let runningToolUseID {
                cancelFields["runningToolUseID"] = .string(runningToolUseID)
            }
            return .object(cancelFields)
        case .pauseTask(let taskID):
            return .object(["type": .string("pause_task"), "taskID": .string(taskID.uuidString)])
        case .resumeTask(let taskID):
            return .object(["type": .string("resume_task"), "taskID": .string(taskID.uuidString)])
        case .approvalResult(let approvalID, let approved, let scope):
            return .object([
                "type": .string("approval_result"),
                "approvalID": .string(approvalID),
                "approved": .bool(approved),
                "scope": .string(scope.rawValue),
            ])
        case .voiceCommand(let taskID, let transcript, let sceneState, let tools, let approvalAtPress, let waitsForTheFinalTranscript):
            var voiceCommandFields: [String: JSONValue] = [
                "type": .string("voice_command"),
                "taskID": .string(taskID.uuidString),
                "transcript": .string(transcript),
                "sceneState": sceneState,
                "tools": .array(tools.map(\.workerRequestJSON)),
                "approvalIDWaitingAtPress": approvalAtPress.map { JSONValue.string($0.approvalID) } ?? .null,
                "approvalIDSeenAtPress": approvalAtPress.flatMap { $0.wholeSummaryWasSeen ? JSONValue.string($0.approvalID) : nil } ?? .null,
            ]
            if waitsForTheFinalTranscript {
                voiceCommandFields["waitsForTheFinalTranscript"] = .bool(true)
            }
            return .object(voiceCommandFields)
        case .confirmVoiceCommand(let taskID):
            return .object(["type": .string("confirm_voice_command"), "taskID": .string(taskID.uuidString)])
        case .voiceToolResult(let taskID, let toolUseID, let outcome):
            return .object([
                "type": .string("tool_result"),
                "taskID": .string(taskID.uuidString),
                "toolUseID": .string(toolUseID),
                "content": .string(outcome.toolResultText),
                "isError": .bool(outcome.isFailure),
                "outcome": .string(outcome.harnessWireName),
            ])
        }
    }

    /// One line, since JSON text escapes every newline inside a string.
    var line: Data {
        Data((json.compactJSONText + "\n").utf8)
    }
}

extension VoiceToolOutcome {
    /// The name harness/protocol.go's voiceToolOutcome reads.
    nonisolated var harnessWireName: String {
        switch self {
        case .changed: return "changed"
        case .lookedUp: return "lookedUp"
        case .failed: return "failed"
        case .handedOff: return "handedOff"
        }
    }
}

// MARK: - Routing a task's messages

/// Hands each harness message to the task it belongs to. The harness is one process for every task, and each task
/// reads its own stream of events.
@MainActor
final class HarnessTaskRouter {
    private var eventContinuationsByTaskID: [UUID: AsyncStream<HarnessTaskEvent>.Continuation] = [:]
    /// Called once for each task the router stops tracking, whether it finished, failed, was cancelled, or lost its harness.
    var onTaskEnded: ((UUID) -> Void)?

    var hasATaskRunning: Bool { !eventContinuationsByTaskID.isEmpty }

    func isTracking(taskID: UUID) -> Bool { eventContinuationsByTaskID[taskID] != nil }

    /// The task's events, which end after finished or failed, or when the task is ended or the harness stops.
    func register(taskID: UUID) -> AsyncStream<HarnessTaskEvent> {
        let (eventStream, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuationsByTaskID[taskID] = eventContinuation
        return eventStream
    }

    func route(_ message: HarnessMessage) {
        switch message {
        case .ready:
            print("Agent harness: ready")
        case .approvalRequest, .approvalSettled:
            // AgentHarness hands these to its approval desk before they reach the router.
            break
        case .log(let taskID, let logText):
            print(logText)
            if let taskID, logText.hasPrefix(harnessPlanningLogLinePrefix) {
                eventContinuationsByTaskID[taskID]?.yield(.planningTurnStarted)
            }
        case .toolCall(let taskID, let toolCall):
            eventContinuationsByTaskID[taskID]?.yield(.toolCall(toolCall))
        case .taskFinished(let taskID, let spokenSummary):
            end(taskID: taskID, lastEvent: .finished(spokenSummary: spokenSummary))
        case .taskFailed(let taskID, let reason):
            end(taskID: taskID, lastEvent: .failed(reason: reason))
        case .voiceCommandFinished(let taskID, let spokenLine, let gaveUp):
            end(taskID: taskID, lastEvent: .voiceCommandFinished(spokenLine: spokenLine, gaveUp: gaveUp))
        case .voiceLineIfEveryCallChanges(let taskID, let spokenLine, let toolNames):
            eventContinuationsByTaskID[taskID]?.yield(.spokenLineIfEveryCallChanges(spokenLine: spokenLine, toolNames: toolNames))
        }
    }

    /// Ends a task's stream, after one last event when there is one. A task the router does not know is ignored,
    /// since a cancelled task may still have a message on its way.
    func end(taskID: UUID, lastEvent: HarnessTaskEvent? = nil) {
        guard let eventContinuation = eventContinuationsByTaskID.removeValue(forKey: taskID) else { return }
        onTaskEnded?(taskID)
        if let lastEvent {
            eventContinuation.yield(lastEvent)
        }
        eventContinuation.finish()
    }

    func failEveryTask(reason: String) {
        for taskID in Array(eventContinuationsByTaskID.keys) {
            end(taskID: taskID, lastEvent: .failed(reason: reason))
        }
    }
}

// MARK: - Approvals

/// A screen that shows the approval card. Each surface keeps its own seen ranges and its own 1 second clock, so a click
/// counts only on the surface whose card was read, and a voice answer's press-time check accepts any surface. The agent
/// list shows the card, and so does the menu bar panel's banner slot, which takes the keyboard.
nonisolated enum ApprovalCardSurface: Hashable, Sendable {
    case agentList
    case menuPanel
}

/// Whether a Yes or an Always on the oldest approval request counts yet. A No counts at once, so this never holds it
/// back. The desk decides it from this one function, and the card draws its buttons, its ring, and its status line from
/// the same value, so the look never differs from what a click does.
nonisolated enum ApprovalAnswerReadiness: Equatable, Sendable {
    /// The card has not yet shown the whole summary from top to bottom.
    case summaryNotYetSeen
    /// The whole summary has been shown, and `HarnessApprovalDesk.secondsTheCardShowsBeforeAnAnswerCounts` has not passed.
    case readyInAMoment
    case ready

    /// Allow once and For this task dim until a yes counts, so a click that the desk would ignore is never offered.
    /// Don't allow never dims.
    var allowButtonsAreDimmed: Bool { self != .ready }
}

/// `wholeSummaryShownSince` is when one surface's card first showed the whole summary, nil until it has.
func approvalAnswerReadiness(wholeSummaryShownSince: Date?, at date: Date) -> ApprovalAnswerReadiness {
    guard let wholeSummaryShownSince else { return .summaryNotYetSeen }
    let secondsShown = date.timeIntervalSince(wholeSummaryShownSince)
    return secondsShown >= HarnessApprovalDesk.secondsTheCardShowsBeforeAnAnswerCounts ? .ready : .readyInAMoment
}

/// How far the card's ring has filled, from 0 when the whole summary first showed to 1 when a Yes counts.
func approvalReadyClockProgress(wholeSummaryShownSince: Date?, at date: Date) -> Double {
    guard let wholeSummaryShownSince else { return 0 }
    let secondsShown = date.timeIntervalSince(wholeSummaryShownSince)
    return min(1, max(0, secondsShown / HarnessApprovalDesk.secondsTheCardShowsBeforeAnAnswerCounts))
}

/// The request a voice answer from one push-to-talk press may reach: the oldest one, the request the card shows, and
/// whether a card had shown its whole summary for a second at the press. A no counts either way, and a yes only when
/// `wholeSummaryWasSeen`.
nonisolated struct ApprovalAtPress: Equatable, Sendable {
    let approvalID: String
    let wholeSummaryWasSeen: Bool
}

/// How an answered request's card ends. The card shows it for `HarnessApprovalDesk.defaultSecondsAnEndedCardStays`.
nonisolated enum ApprovalCardEnding: Equatable, Sendable {
    /// The harness's gate took a yes, a click's or a voice answer's.
    case allowed(HarnessApprovalScope)
    /// The harness's gate took a no.
    case declined
    /// Nobody answered in time, so the desk declined it.
    case timedOut
    /// The answer went to the harness, which never said it took it.
    case noReply
}

/// What the approval card shows, which only the desk decides, so the card never shows an answer the harness did not take.
nonisolated enum ApprovalCardPhase: Equatable, Sendable {
    case waiting(ApprovalAnswerReadiness)
    /// The answer went to the harness, and its `approval_settled` has not come back.
    case sending
    case ended(ApprovalCardEnding)
}

/// The one card a surface shows: the oldest waiting request, or for a moment the request that just ended.
nonisolated struct ShownApprovalCard: Equatable, Sendable {
    let request: HarnessApprovalRequest
    let phase: ApprovalCardPhase
}

/// Holds each approval_request until the learner answers it, its task ends, or `timeoutSeconds` pass, which declines it.
/// An answer the harness does not settle within `answerSettleGraceSeconds` drops the card, since a harness that hung
/// after it took the answer would otherwise leave the card with no buttons for as long as its task lives.
/// Requests wait in arrival order, and the learner answers the oldest first (by the buttons in the agent list, or by
/// voice with `answer_approval`). The desk keeps the queue, each surface's clock, and the card each surface shows, and
/// sends the answers. `onRequestArrived` and `onWaitingRequestsChanged` let CompanionManager show the request, and a
/// Debug build's `debug_answer_approval` tool answers through `answer(approvalID:approved:scope:)` like the buttons do.
@MainActor
final class HarnessApprovalDesk: ObservableObject {
    /// How long a request waits for an answer before it is declined, so a learner who walked away does not leave the
    /// agent waiting for good. harness/approval.go waits as long as the task lives.
    nonisolated static let defaultTimeoutSeconds: Double = 120

    /// How long an answered request waits for the harness's `approval_settled` before its card is dropped. The harness
    /// settles an answer within milliseconds, so this only runs out when the harness hung.
    nonisolated static let defaultAnswerSettleGraceSeconds: Double = 15

    /// A Yes or an Always, by voice or by click, counts only once a card has shown the oldest request's whole summary,
    /// scrolled through from top to bottom, and this long has passed since it did. Scrolling away afterward does not stop
    /// the clock. The list opens next to the mouse, so a click the learner meant for the page could otherwise be taken
    /// as Yes, and a summary on screen for an instant is one nobody read. A No counts at once: a wrong no costs the agent
    /// a retry, while a wrong yes can send data out.
    nonisolated static let secondsTheCardShowsBeforeAnAnswerCounts: Double = 1

    /// How long a card shows how its request ended, when no other request waits behind it.
    nonisolated static let defaultSecondsAnEndedCardStays: Double = 2

    /// Oldest first.
    @Published private(set) var waitingRequests: [HarnessApprovalRequest] = []
    /// The requests whose answer went to the harness and whose `approval_settled` has not come back. The card shows them as
    /// sending, since the gate takes the first answer, and a voice answer may have won over this click.
    @Published private(set) var answeringApprovalIDs: Set<String> = []
    /// When each surface's card first had shown the oldest request's whole summary, from top to bottom. A surface is
    /// missing until its card has: it is closed, or a new request just became the oldest. Published so each card draws
    /// its buttons from the same value `answerByClick` checks for it (`approvalAnswerReadiness`).
    @Published private(set) var wholeSummaryShownSinceBySurface: [ApprovalCardSurface: Date] = [:]
    /// The request that ended last and how, which a card shows for `secondsAnEndedCardStays` when no request waits.
    @Published private(set) var lastEndedCard: ShownApprovalCard?
    /// A request was settled, with the answer the harness's gate took, so the owner shows the outcome. It is not called
    /// for a request the desk's own timeout declined, since "Declined it" above the cursor would come with no context.
    var onApprovalSettled: ((_ approved: Bool, _ scope: HarnessApprovalScope) -> Void)?
    var onRequestArrived: ((HarnessApprovalRequest) -> Void)?
    /// A card started to say how its request ended, so the requesting agent's disc can turn its "!" into a check or a dash.
    var onACardEnded: ((_ endedCard: ShownApprovalCard, _ ending: ApprovalCardEnding) -> Void)?
    /// An ended card's time ran out while no other request waited, so it was the card on screen and leaves now. The agent
    /// list Glides it back into its disc. A card dropped with its task, or hidden behind a newer request, never calls this.
    var onAnEndedCardLeft: ((ShownApprovalCard) -> Void)?
    /// Whether a surface shows the card: the agent list is open, or the menu bar panel is open on its home. A request that
    /// becomes the oldest then shows there.
    var listIsShowing: () -> Bool = { false }
    /// A request became the oldest while no surface showed the card, so its summary is on no screen until the list opens.
    var onOldestRequestNeedsShowing: ((HarnessApprovalRequest) -> Void)?
    /// Whether a task still runs. A request can cross a cancel on its way from the harness, and a request for an ended
    /// task would take the oldest spot, with buttons on an ended agent's row, until it timed out.
    var taskIsRunning: (UUID) -> Bool = { _ in true }
    var onWaitingRequestsChanged: (([HarnessApprovalRequest]) -> Void)?

    /// The requests the desk's own timeout declined, so their settlement shows no outcome of its own.
    private var timedOutApprovalIDs: Set<String> = []

    private let timeoutSeconds: Double
    private let answerSettleGraceSeconds: Double
    private let secondsAnEndedCardStays: Double
    private let sendAnswer: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
    private let currentDate: () -> Date
    /// Runs `work` on the main actor after `seconds`, for the request timeout, the answer's settle grace, and the ended
    /// card's stay. A test passes one it fires by hand, so no test waits on a clock a busy machine can starve.
    private let scheduleAfter: @MainActor (_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> Void

    init(
        timeoutSeconds: Double = HarnessApprovalDesk.defaultTimeoutSeconds,
        answerSettleGraceSeconds: Double = HarnessApprovalDesk.defaultAnswerSettleGraceSeconds,
        secondsAnEndedCardStays: Double = HarnessApprovalDesk.defaultSecondsAnEndedCardStays,
        currentDate: @escaping () -> Date = Date.init,
        scheduleAfter: @escaping @MainActor (_ seconds: Double, _ work: @escaping @MainActor () -> Void) -> Void = HarnessApprovalDesk.scheduleOnTheMainActor,
        sendAnswer: @escaping (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.answerSettleGraceSeconds = answerSettleGraceSeconds
        self.secondsAnEndedCardStays = secondsAnEndedCardStays
        self.currentDate = currentDate
        self.scheduleAfter = scheduleAfter
        self.sendAnswer = sendAnswer
    }

    /// The real scheduler: a task that sleeps, then runs the work. A cancelled sleep still runs it, as the timers always did.
    static func scheduleOnTheMainActor(afterSeconds seconds: Double, work: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            work()
        }
    }

    /// After any change to the queue that may have put a new request first. Every surface's clock starts over for the new
    /// oldest, and a closed list is asked to open, since until then the new oldest's summary is on no screen.
    private func noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: String?) {
        guard waitingRequests.first?.approvalID != oldestApprovalIDBefore else { return }
        wholeSummaryShownSinceBySurface = [:]
        guard let oldestRequest = waitingRequests.first, !listIsShowing() else { return }
        onOldestRequestNeedsShowing?(oldestRequest)
    }

    /// A surface's card has now shown the whole summary of this request, from top to bottom: at once when it fits, or
    /// once the learner has scrolled through all of it. That surface's clock starts at the first report and runs until
    /// the surface closes or another request becomes the oldest.
    func theCardShowedTheWholeSummary(ofApprovalID approvalID: String, on surface: ApprovalCardSurface) {
        guard waitingRequests.first?.approvalID == approvalID, wholeSummaryShownSinceBySurface[surface] == nil else { return }
        wholeSummaryShownSinceBySurface[surface] = currentDate()
    }

    /// A surface's card has not yet shown the whole summary, or the surface closed, which discards what it had seen.
    func theCardHasNotShownTheWholeSummary(on surface: ApprovalCardSurface) {
        // Skips a write of nil over nil, since every write of a published value redraws the card.
        guard wholeSummaryShownSinceBySurface[surface] != nil else { return }
        wholeSummaryShownSinceBySurface[surface] = nil
    }

    /// Whether a Yes on this surface counts at `date`.
    func answerReadiness(on surface: ApprovalCardSurface, at date: Date) -> ApprovalAnswerReadiness {
        approvalAnswerReadiness(wholeSummaryShownSince: wholeSummaryShownSinceBySurface[surface], at: date)
    }

    /// The request a voice answer from a push-to-talk press at `date` may reach: the oldest, which an open surface's card
    /// shows and the waiting chip asks about when none is open, with whether any surface had shown its whole summary for
    /// `secondsTheCardShowsBeforeAnAnswerCounts`. Nil when none waits. A request that came after the press is one the
    /// learner was not answering.
    func approvalAtPress(at date: Date) -> ApprovalAtPress? {
        guard let oldestRequest = waitingRequests.first else { return nil }
        let wholeSummaryWasSeen = wholeSummaryShownSinceBySurface.values.contains { wholeSummaryShownSince in
            approvalAnswerReadiness(wholeSummaryShownSince: wholeSummaryShownSince, at: date) == .ready
        }
        return ApprovalAtPress(approvalID: oldestRequest.approvalID, wholeSummaryWasSeen: wholeSummaryWasSeen)
    }

    /// The approval card's buttons answer through here. A No on the oldest request counts at once. A Yes or an Always
    /// counts only when this surface's card has shown the oldest request in full for a second, so a click on a surface
    /// nobody read is ignored even when another surface was read. Returns false when the click did not count.
    @discardableResult
    func answerByClick(approvalID: String, approved: Bool, scope: HarnessApprovalScope, on surface: ApprovalCardSurface) -> Bool {
        guard waitingRequests.first?.approvalID == approvalID else {
            print("Agent harness: ignored a click on approval \(approvalID), which is not the request the card shows")
            return false
        }
        guard !approved || answerReadiness(on: surface, at: currentDate()) == .ready else {
            print("Agent harness: ignored a yes on approval \(approvalID) that came before its card showed it in full for \(Self.secondsTheCardShowsBeforeAnAnswerCounts) s")
            return false
        }
        return answer(approvalID: approvalID, approved: approved, scope: scope)
    }

    /// The request the learner answers next, which is also the one the agent list shows.
    var oldestWaitingRequest: HarnessApprovalRequest? { waitingRequests.first }

    /// The card a surface shows at `date`: the oldest waiting request, as waiting or sending, or, when none waits, the
    /// request that ended within `secondsAnEndedCardStays`, with how it ended. Nil when the card should go.
    func cardToShow(on surface: ApprovalCardSurface, at date: Date) -> ShownApprovalCard? {
        if let oldestRequest = waitingRequests.first {
            let phase: ApprovalCardPhase = answeringApprovalIDs.contains(oldestRequest.approvalID)
                ? .sending
                : .waiting(answerReadiness(on: surface, at: date))
            return ShownApprovalCard(request: oldestRequest, phase: phase)
        }
        return lastEndedCard
    }

    func receive(_ request: HarnessApprovalRequest) {
        // A repeated ID would leave two entries for one answer.
        guard !waitingRequests.contains(where: { $0.approvalID == request.approvalID }) else { return }
        guard taskIsRunning(request.taskID) else {
            print("Agent harness: dropped approval \(request.approvalID), whose task already ended")
            return
        }
        // The learner cannot judge an action the app cannot name, so it is declined without asking.
        if case .unknown = request.capability {
            print("Agent harness: declined approval \(request.approvalID) for a capability the app does not know")
            sendAnswer(request.approvalID, false, .once)
            return
        }
        let oldestApprovalIDBefore = waitingRequests.first?.approvalID
        waitingRequests.append(request)
        noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: oldestApprovalIDBefore)
        // The summary can hold clipboard text or data from the screen, so the log names only the kind of action.
        print("Agent harness: approval \(request.approvalID) requested for \(request.capability)")
        onRequestArrived?(request)
        onWaitingRequestsChanged?(waitingRequests)
        scheduleAfter(timeoutSeconds) { [weak self] in
            self?.declineIfStillWaiting(approvalID: request.approvalID)
        }
    }

    /// An answer that came first stands, since `answer` finds nothing left to decline.
    private func declineIfStillWaiting(approvalID: String) {
        guard waitingRequests.contains(where: { $0.approvalID == approvalID }), !answeringApprovalIDs.contains(approvalID) else { return }
        timedOutApprovalIDs.insert(approvalID)
        answer(approvalID: approvalID, approved: false, scope: .once)
        print("Agent harness: approval \(approvalID) timed out after \(timeoutSeconds) s, so it was declined")
    }

    /// Keeps how a request ended for a card to show, and forgets it after `secondsAnEndedCardStays` unless a newer one
    /// replaced it.
    private func showTheEnding(_ ending: ApprovalCardEnding, of request: HarnessApprovalRequest) {
        let endedCard = ShownApprovalCard(request: request, phase: .ended(ending))
        lastEndedCard = endedCard
        onACardEnded?(endedCard, ending)
        scheduleAfter(secondsAnEndedCardStays) { [weak self] in
            guard let self, self.lastEndedCard == endedCard else { return }
            self.lastEndedCard = nil
            if self.waitingRequests.isEmpty { self.onAnEndedCardLeft?(endedCard) }
        }
    }

    /// The harness took the answer but never said so, so the card would stay as "Sending your answer..." for good. The
    /// log names only the approval ID, and the card says the agent never confirmed it, since nobody knows which answer the
    /// gate took.
    private func dropAnsweringRequestIfTheHarnessNeverSettledIt(approvalID: String) {
        guard answeringApprovalIDs.contains(approvalID),
              let requestIndex = waitingRequests.firstIndex(where: { $0.approvalID == approvalID }) else { return }
        let oldestApprovalIDBefore = waitingRequests.first?.approvalID
        let request = waitingRequests.remove(at: requestIndex)
        answeringApprovalIDs.remove(approvalID)
        // The learner sent nothing for a request the desk's own timeout declined, so its card says it timed out.
        let desksOwnTimeoutDeclinedIt = timedOutApprovalIDs.remove(approvalID) != nil
        noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: oldestApprovalIDBefore)
        print("Agent harness: approval \(approvalID) was answered but not settled within \(answerSettleGraceSeconds) s, so its card was dropped")
        showTheEnding(desksOwnTimeoutDeclinedIt ? .timedOut : .noReply, of: request)
        onWaitingRequestsChanged?(waitingRequests)
    }

    /// Sends the learner's answer to the harness, which takes the first answer it gets and replies with `approval_settled`.
    /// The request stays in the queue, marked as answering, until that reply, so the desk never shows a decline that the
    /// gate did not take. Returns false when no request with this ID is waiting, or when it is already answering.
    @discardableResult
    func answer(approvalID: String, approved: Bool, scope: HarnessApprovalScope) -> Bool {
        guard waitingRequests.contains(where: { $0.approvalID == approvalID }), !answeringApprovalIDs.contains(approvalID) else { return false }
        answeringApprovalIDs.insert(approvalID)
        print("Agent harness: approval \(approvalID) answered \(approved ? "yes" : "no") (\(scope.rawValue)), waiting for the harness to settle it")
        sendAnswer(approvalID, approved, scope)
        scheduleAfter(answerSettleGraceSeconds) { [weak self] in
            self?.dropAnsweringRequestIfTheHarnessNeverSettledIt(approvalID: approvalID)
        }
        return true
    }

    /// The harness's gate took an answer for this request, a click's or a voice answer's, the first of them. The card
    /// shows how it ended, and the owner shows the outcome. A request the desk no longer holds, such as one whose task
    /// ended, changes nothing.
    func settle(approvalID: String, approved: Bool, scope: HarnessApprovalScope) {
        guard let requestIndex = waitingRequests.firstIndex(where: { $0.approvalID == approvalID }) else {
            print("Agent harness: approval \(approvalID) was settled, and the desk no longer holds it")
            return
        }
        let oldestApprovalIDBefore = waitingRequests.first?.approvalID
        let request = waitingRequests.remove(at: requestIndex)
        answeringApprovalIDs.remove(approvalID)
        let desksOwnTimeoutDeclinedIt = timedOutApprovalIDs.remove(approvalID) != nil
        noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: oldestApprovalIDBefore)
        print("Agent harness: approval \(approvalID) \(approved ? "given" : "declined") (\(scope.rawValue))")
        // A yes still shows as allowed, since it means the learner's answer beat the timeout's decline to the gate.
        let timeoutDeclinedIt = desksOwnTimeoutDeclinedIt && !approved
        showTheEnding(approved ? .allowed(scope) : (timeoutDeclinedIt ? .timedOut : .declined), of: request)
        onWaitingRequestsChanged?(waitingRequests)
        guard !timeoutDeclinedIt else { return }
        onApprovalSettled?(approved, scope)
    }

    /// Forgets every request at once when the harness process stops, so the list never opens for a request that the
    /// next task's drop would remove a moment later.
    func dropAllRequests() {
        lastEndedCard = nil
        guard !waitingRequests.isEmpty else { return }
        waitingRequests.removeAll()
        answeringApprovalIDs.removeAll()
        timedOutApprovalIDs.removeAll()
        wholeSummaryShownSinceBySurface = [:]
        onWaitingRequestsChanged?(waitingRequests)
    }

    /// Forgets a task's requests when the task ends. The harness already abandoned them, so nothing is sent. An ended
    /// card of that task goes too, since "The task goes on" would describe a task that is gone.
    func dropRequests(forTaskID taskID: UUID) {
        if lastEndedCard?.request.taskID == taskID {
            lastEndedCard = nil
        }
        let requestCountBefore = waitingRequests.count
        let oldestApprovalIDBefore = waitingRequests.first?.approvalID
        waitingRequests.removeAll { $0.taskID == taskID }
        answeringApprovalIDs.formIntersection(waitingRequests.map(\.approvalID))
        timedOutApprovalIDs.formIntersection(waitingRequests.map(\.approvalID))
        noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: oldestApprovalIDBefore)
        if waitingRequests.count != requestCountBefore {
            onWaitingRequestsChanged?(waitingRequests)
        }
    }
}

// MARK: - The helper process

/// The environment the harness is launched with: only what it reads, so none of this Mac's Anthropic credentials reach
/// the Worker. harness/main.go is the other half. CLICKY_SKILLS_DIRS lists the skills folders in the order the harness
/// searches them, joined with ":". CLICKY_MCP_CONFIG is the mcp.json of the learner's MCP servers. The few variables in
/// `harnessInheritedVariableNames` are copied so a stdio MCP server the harness starts can find its command and home.
nonisolated func agentHarnessEnvironment(
    workerBaseURL: String,
    appSecret: String?,
    skillsDirectoryURLs: [URL],
    mcpConfigURL: URL? = nil,
    parentEnvironment: [String: String] = [:]
) -> [String: String] {
    var harnessEnvironment: [String: String] = [:]
    for variableName in harnessInheritedVariableNames {
        harnessEnvironment[variableName] = parentEnvironment[variableName]
    }
    harnessEnvironment["CLICKY_WORKER_BASE_URL"] = workerBaseURL
    if let appSecret, !appSecret.isEmpty {
        harnessEnvironment["CLICKY_APP_SECRET"] = appSecret
    }
    if !skillsDirectoryURLs.isEmpty {
        harnessEnvironment["CLICKY_SKILLS_DIRS"] = skillsDirectoryURLs.map(\.path).joined(separator: ":")
    }
    if let mcpConfigURL {
        harnessEnvironment["CLICKY_MCP_CONFIG"] = mcpConfigURL.path
    }
    return harnessEnvironment
}

/// None of these is a credential. The harness copies them to a stdio MCP server, never the Worker's secret.
nonisolated let harnessInheritedVariableNames = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "SHELL"]

/// Writes the app's lines to the harness's stdin on one serial queue, so lines never interleave and a large tool
/// result, such as a screenshot, never blocks the main thread on a full pipe. It is not on the main actor, because a
/// voice command's cancel handler runs wherever the cancel happens and writes its line here too
/// (`HarnessVoiceCommandLines`).
nonisolated final class HarnessStandardInputWriter: Sendable {
    /// The stdin of the harness that runs now, or nil while none does.
    private let standardInputHandle = OSAllocatedUnfairLock<FileHandle?>(initialState: nil)
    private let writeQueue = DispatchQueue(label: "com.crodris.clicky-watch-along.agent-harness-stdin")

    func attach(_ handle: FileHandle?) {
        standardInputHandle.withLock { attachedHandle in attachedHandle = handle }
    }

    func write(_ command: HarnessCommand) {
        guard let handle = standardInputHandle.withLock({ attachedHandle in attachedHandle }) else {
            print("Agent harness: dropped a \(command.json["type"]?.stringValue ?? "message") because the harness is not running")
            return
        }
        let commandLine = command.line
        writeQueue.async {
            do {
                try handle.write(contentsOf: commandLine)
            } catch {
                print("Agent harness: could not write to the harness: \(error)")
            }
        }
    }
}

enum AgentHarnessError: Error, Equatable {
    case helperIsMissing(path: String)
    case helperCouldNotStart(String)
}

/// Launches the bundled harness, writes the app's messages to its stdin, and reads its stdout line by line into the
/// task router. A harness that exited is launched again by the next task.
@MainActor
final class AgentHarness {
    private let workerBaseURL: String
    private let appSecretDefaults: UserDefaults
    private let helperURL: URL
    let taskRouter = HarnessTaskRouter()
    /// Holds the requests the harness waits on until the learner answers them.
    private(set) lazy var approvalDesk: HarnessApprovalDesk = {
        let approvalDesk = HarnessApprovalDesk { [weak self] approvalID, approved, scope in
            self?.write(.approvalResult(approvalID: approvalID, approved: approved, scope: scope))
        }
        approvalDesk.taskIsRunning = { [weak self] taskID in self?.taskRouter.isTracking(taskID: taskID) ?? false }
        return approvalDesk
    }()

    private var runningProcess: Process?
    private var standardOutputReaderTask: Task<Void, Never>?
    /// Every write goes through this one writer and its one queue, from the main actor or a voice command's cancel handler.
    let standardInputWriter = HarnessStandardInputWriter()

    /// `helperURL` is where Xcode's "Build Agent Harness" phase puts the binary, unless a test points at another build.
    init(
        workerBaseURL: String,
        appSecretDefaults: UserDefaults = .standard,
        helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clicky-agent-harness")
    ) {
        self.workerBaseURL = workerBaseURL
        self.appSecretDefaults = appSecretDefaults
        self.helperURL = helperURL
        // A task that ends takes its waiting requests with it.
        taskRouter.onTaskEnded = { [weak self] endedTaskID in
            self?.approvalDesk.dropRequests(forTaskID: endedTaskID)
        }
    }

    /// Starts a task on the harness, with the steps of the named skill when `skill` is given. The stream ends after the
    /// task finishes or fails, or when the harness stops.
    func startTask(taskID: UUID, goal: String, frontTabTitle: String?, frontTabURL: String?, skill: String? = nil, startsPaused: Bool = false) throws -> AsyncStream<HarnessTaskEvent> {
        try launchTheHarnessIfItIsNotRunning()
        let taskEvents = taskRouter.register(taskID: taskID)
        write(.startTask(taskID: taskID, goal: goal, frontTabTitle: frontTabTitle, frontTabURL: frontTabURL, skill: skill, startsPaused: startsPaused))
        return taskEvents
    }

    /// Holds or lets go a running task's next step (`pauseTask`, `resumeTask`). A task that already ended ignores it.
    func setTaskIsPaused(_ taskIsPaused: Bool, taskID: UUID) {
        write(taskIsPaused ? .pauseTask(taskID: taskID) : .resumeTask(taskID: taskID))
    }

    func sendToolResult(taskID: UUID, toolUseID: String, content: JSONValue, isError: Bool, sourceURL: String? = nil) {
        write(.toolResult(taskID: taskID, toolUseID: toolUseID, content: content, isError: isError, sourceURL: sourceURL))
    }

    /// Answers a request the harness is waiting on. Returns false when none is waiting under this ID.
    @discardableResult
    func answerApproval(approvalID: String, approved: Bool, scope: HarnessApprovalScope) -> Bool {
        approvalDesk.answer(approvalID: approvalID, approved: approved, scope: scope)
    }

    /// Stops the task in the harness, which then sends nothing more for it.
    func cancelTask(taskID: UUID) {
        taskRouter.end(taskID: taskID)
        write(.cancelTask(taskID: taskID))
    }

    /// Starts a voice command on the brain. The stream ends after voice_command_finished or task_failed, when the harness
    /// stops, or when `endVoiceCommand` ends it. The command's tool results and its cancel go out through
    /// `HarnessVoiceCommandLines`, never through `sendToolResult` or `cancelTask`.
    func startVoiceCommand(
        taskID: UUID,
        transcript: String,
        sceneState: JSONValue,
        tools: [VoiceToolDescriptor],
        approvalAtPress: ApprovalAtPress?,
        waitsForTheFinalTranscript: Bool = false
    ) throws -> AsyncStream<HarnessTaskEvent> {
        try launchTheHarnessIfItIsNotRunning()
        let commandEvents = taskRouter.register(taskID: taskID)
        write(.voiceCommand(
            taskID: taskID,
            transcript: transcript,
            sceneState: sceneState,
            tools: tools,
            approvalAtPress: approvalAtPress,
            waitsForTheFinalTranscript: waitsForTheFinalTranscript
        ))
        return commandEvents
    }

    /// Lets a command started on the partial transcript go on, since the final transcript matched it.
    func confirmVoiceCommand(taskID: UUID) {
        write(.confirmVoiceCommand(taskID: taskID))
    }

    /// Stops routing a voice command's events, after one last event when there is one, and writes nothing, since the
    /// command's own lines say whether the harness is told to cancel it.
    func endVoiceCommand(taskID: UUID, lastEvent: HarnessTaskEvent? = nil) {
        taskRouter.end(taskID: taskID, lastEvent: lastEvent)
    }

    /// Launches the harness now, at app start, so the first voice command on the brain does not wait for the process.
    func prewarm() {
        do {
            try launchTheHarnessIfItIsNotRunning()
        } catch {
            print("Agent harness: could not start it ahead of the first voice command: \(error)")
        }
    }

    private func launchTheHarnessIfItIsNotRunning() throws {
        if runningProcess?.isRunning == true { return }
        // A harness that exited took its tasks with it. Its exit notice may not have arrived yet, so they fail here.
        if let exitedProcess = runningProcess {
            forgetTheHarnessThatExited(exitedProcess)
        }

        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw AgentHarnessError.helperIsMissing(path: helperURL.path)
        }

        let process = Process()
        process.executableURL = helperURL
        // A clean environment with only what the harness reads, so none of this Mac's Anthropic credentials reach the Worker.
        let skillsDirectoryURLs = TaskAgentFolders.skillsDirectoryURLs(bundleResourceURL: Bundle.main.resourceURL)
        if let userSkillsDirectoryURL = skillsDirectoryURLs.first {
            // So the learner finds the place to put a skill.
            try? FileManager.default.createDirectory(at: userSkillsDirectoryURL, withIntermediateDirectories: true)
        }
        process.environment = agentHarnessEnvironment(
            workerBaseURL: workerBaseURL,
            appSecret: ClickyAppSecret.current(in: appSecretDefaults),
            skillsDirectoryURLs: skillsDirectoryURLs,
            mcpConfigURL: TaskAgentFolders.mcpConfigURL(),
            parentEnvironment: ProcessInfo.processInfo.environment
        )

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        process.standardInput = standardInputPipe
        process.standardOutput = standardOutputPipe
        // The harness writes its own debug text to stderr, which belongs in the app's log.
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] exitedProcess in
            Task { @MainActor in
                self?.harnessDidExit(exitedProcess)
            }
        }

        // A write to a harness that exited would otherwise raise SIGPIPE and end the app. Ignored, it throws instead.
        signal(SIGPIPE, SIG_IGN)
        do {
            try process.run()
        } catch {
            throw AgentHarnessError.helperCouldNotStart(String(describing: error))
        }

        runningProcess = process
        standardInputWriter.attach(standardInputPipe.fileHandleForWriting)
        let standardOutputHandle = standardOutputPipe.fileHandleForReading
        standardOutputReaderTask = Task { [weak self] in
            do {
                for try await outputLine in standardOutputHandle.bytes.lines {
                    self?.handleHarnessLine(outputLine)
                }
            } catch {
                print("Agent harness: could not read its output: \(error)")
            }
        }
        print("Agent harness: started process \(process.processIdentifier)")
    }

    private func handleHarnessLine(_ outputLine: String) {
        do {
            let message = try HarnessMessage(line: outputLine)
            if case .approvalRequest(let approvalRequest) = message {
                approvalDesk.receive(approvalRequest)
                return
            }
            if case .approvalSettled(let approvalID, let approved, let scope) = message {
                approvalDesk.settle(approvalID: approvalID, approved: approved, scope: scope)
                return
            }
            taskRouter.route(message)
        } catch {
            // A line can carry a summary or clipboard text, so the log gives only its length.
            print("Agent harness: dropped a line of \(outputLine.count) characters it could not read (\(error))")
        }
    }

    private func harnessDidExit(_ exitedProcess: Process) {
        print("Agent harness: process \(exitedProcess.processIdentifier) exited with status \(exitedProcess.terminationStatus)")
        // The notice of a harness that was already replaced changes nothing.
        guard exitedProcess === runningProcess else { return }
        forgetTheHarnessThatExited(exitedProcess)
    }

    /// Every task the harness had is lost with it, so each one fails and the next task launches a fresh harness.
    private func forgetTheHarnessThatExited(_ exitedProcess: Process) {
        runningProcess = nil
        standardInputWriter.attach(nil)
        standardOutputReaderTask?.cancel()
        standardOutputReaderTask = nil
        approvalDesk.dropAllRequests()
        taskRouter.failEveryTask(reason: "The agent harness stopped with status \(exitedProcess.terminationStatus)")
    }

    private func write(_ command: HarnessCommand) {
        standardInputWriter.write(command)
    }
}
