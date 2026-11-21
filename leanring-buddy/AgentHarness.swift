//
//  AgentHarness.swift
//  leanring-buddy
//
//  The task agent's loop runs in a Go helper process, harness/ in the repo, bundled at Contents/Helpers/
//  clicky-agent-harness. With the brainRunsInTheHarness flag on, the voice command brain (harness/brain.go) runs there
//  too. The app and the harness talk in JSON lines on the harness's stdin and stdout. The harness runs Claude through
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
    /// The turn of a voice command the call came from, counted from 0, since only the first may answer an approval.
    /// Nil for a task's call.
    let turnIndex: Int?

    init(toolUseID: String, toolName: String, input: [String: JSONValue], turnIndex: Int? = nil) {
        self.toolUseID = toolUseID
        self.toolName = toolName
        self.input = input
        self.turnIndex = turnIndex
    }
}

/// What the app hears from the harness for one task or voice command. The stream of events ends after finished,
/// failed, or voiceCommandFinished.
nonisolated enum HarnessTaskEvent: Equatable, Sendable {
    case toolCall(HarnessToolCall)
    case finished(spokenSummary: String)
    case failed(reason: String)
    /// A voice command ended. spokenLine may be empty, and gaveUp says its last turn still needed the model.
    case voiceCommandFinished(spokenLine: String, gaveUp: Bool)
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
    case log(message: String)

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
                    input: input,
                    turnIndex: messageJSON["turnIndex"]?.numberValue.flatMap { turnIndex in Int(exactly: turnIndex) }
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
        case "log":
            self = .log(message: try requiredText("message"))
        default:
            throw ParseError.unknownType(messageType)
        }
    }
}

// MARK: - Messages to the harness

nonisolated enum HarnessCommand: Equatable, Sendable {
    /// `skill` names a skill file the harness reads from its skills folders, or is nil for a task with no skill.
    case startTask(taskID: UUID, goal: String, frontTabTitle: String?, frontTabURL: String?, skill: String?)
    /// `content` is a string or an array of content blocks, such as the image block look_at_video returns.
    /// `sourceURL` is the video link a read_video_captions result is about. The harness lets a task cite only that link
    /// from it and never reads a link out of `content`, which a video's own text can write, so it is set for that tool
    /// alone and left out of the line otherwise.
    case toolResult(taskID: UUID, toolUseID: String, content: JSONValue, isError: Bool, sourceURL: String? = nil)
    case cancelTask(taskID: UUID)
    /// The answer to one approval_request, named by the harness's approvalID.
    case approvalResult(approvalID: String, approved: Bool, scope: HarnessApprovalScope)
    /// Starts a voice command on the brain. `sceneState` is `voiceCommandSceneState`'s object, `recentActions` the
    /// `voiceToolActionLine` strings, and `tools` the list after `voiceToolsOfferedToTheModel`.
    case voiceCommand(taskID: UUID, transcript: String, sceneState: JSONValue, recentActions: [String], tools: [VoiceToolDescriptor])
    /// A voice command's tool_result, which carries what the tool did, so the brain knows whether to speak, ask the
    /// model again, or stop for a hand-off.
    case voiceToolResult(taskID: UUID, toolUseID: String, outcome: VoiceToolOutcome)

    var json: JSONValue {
        switch self {
        case .startTask(let taskID, let goal, let frontTabTitle, let frontTabURL, let skill):
            return .object([
                "type": .string("start_task"),
                "taskID": .string(taskID.uuidString),
                "goal": .string(goal),
                "frontTabTitle": frontTabTitle.map(JSONValue.string) ?? .null,
                "frontTabURL": frontTabURL.map(JSONValue.string) ?? .null,
                "skill": skill.map(JSONValue.string) ?? .null,
            ])
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
        case .cancelTask(let taskID):
            return .object(["type": .string("cancel_task"), "taskID": .string(taskID.uuidString)])
        case .approvalResult(let approvalID, let approved, let scope):
            return .object([
                "type": .string("approval_result"),
                "approvalID": .string(approvalID),
                "approved": .bool(approved),
                "scope": .string(scope.rawValue),
            ])
        case .voiceCommand(let taskID, let transcript, let sceneState, let recentActions, let tools):
            return .object([
                "type": .string("voice_command"),
                "taskID": .string(taskID.uuidString),
                "transcript": .string(transcript),
                "sceneState": sceneState,
                "recentActions": .array(recentActions.map(JSONValue.string)),
                "tools": .array(tools.map(\.workerRequestJSON)),
            ])
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
        case .approvalRequest:
            // AgentHarness hands these to its approval desk before they reach the router.
            break
        case .log(let logText):
            print(logText)
        case .toolCall(let taskID, let toolCall):
            eventContinuationsByTaskID[taskID]?.yield(.toolCall(toolCall))
        case .taskFinished(let taskID, let spokenSummary):
            end(taskID: taskID, lastEvent: .finished(spokenSummary: spokenSummary))
        case .taskFailed(let taskID, let reason):
            end(taskID: taskID, lastEvent: .failed(reason: reason))
        case .voiceCommandFinished(let taskID, let spokenLine, let gaveUp):
            end(taskID: taskID, lastEvent: .voiceCommandFinished(spokenLine: spokenLine, gaveUp: gaveUp))
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

/// Holds each approval_request until the learner answers it, its task ends, or `timeoutSeconds` pass, which declines it.
/// Requests wait in arrival order, and the learner answers the oldest first (by the buttons in the agent list, or by
/// voice with `answer_approval`). The desk only keeps the queue and sends the answers. `onRequestArrived` and
/// `onWaitingRequestsChanged` let CompanionManager show the request, and a Debug build's `debug_answer_approval` tool
/// answers through `answer(approvalID:approved:scope:)` like the buttons do.
@MainActor
final class HarnessApprovalDesk: ObservableObject {
    /// How long a request waits for an answer before it is declined, so a learner who walked away does not leave the
    /// agent waiting for good. harness/approval.go waits as long as the task lives.
    nonisolated static let defaultTimeoutSeconds: Double = 120

    /// A yes, by voice or by click, counts only once the approval card has shown the oldest request's whole summary
    /// this long without a break. The list opens next to the mouse, so a click the learner meant for the page could
    /// otherwise be taken as Yes, and a summary on screen for an instant is one nobody read.
    nonisolated static let secondsTheCardShowsBeforeAnAnswerCounts: Double = 1

    /// Oldest first.
    @Published private(set) var waitingRequests: [HarnessApprovalRequest] = []
    /// When the approval card at the top of the open agent list last showed the oldest request's whole summary, or nil
    /// while no card shows all of it: the list is closed, the summary is scrolled away from its end, or a new request
    /// just became the oldest.
    private var oldestRequestVisibleSince: Date?
    var onRequestArrived: ((HarnessApprovalRequest) -> Void)?
    /// Whether the agent list is open, so a request that becomes the oldest shows in its card.
    var listIsShowing: () -> Bool = { false }
    /// A request became the oldest while the list was closed, so its summary is on no screen until the list opens.
    var onOldestRequestNeedsShowing: ((HarnessApprovalRequest) -> Void)?
    /// Whether a task still runs. A request can cross a cancel on its way from the harness, and a request for an ended
    /// task would take the oldest spot, with buttons on an ended agent's row, until it timed out.
    var taskIsRunning: (UUID) -> Bool = { _ in true }
    var onWaitingRequestsChanged: (([HarnessApprovalRequest]) -> Void)?

    private let timeoutSeconds: Double
    private let sendAnswer: (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
    private let currentDate: () -> Date

    init(
        timeoutSeconds: Double = HarnessApprovalDesk.defaultTimeoutSeconds,
        currentDate: @escaping () -> Date = Date.init,
        sendAnswer: @escaping (_ approvalID: String, _ approved: Bool, _ scope: HarnessApprovalScope) -> Void
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.currentDate = currentDate
        self.sendAnswer = sendAnswer
    }

    /// After any change to the queue that may have put a new request first. The card's clock starts over for the new
    /// oldest, and a closed list is asked to open, since until then the new oldest's summary is on no screen.
    private func noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: String?) {
        guard waitingRequests.first?.approvalID != oldestApprovalIDBefore else { return }
        oldestRequestVisibleSince = nil
        guard let oldestRequest = waitingRequests.first, !listIsShowing() else { return }
        onOldestRequestNeedsShowing?(oldestRequest)
    }

    /// The approval card shows the whole summary of this request, after the list opened, after the request became the
    /// oldest, or after the learner scrolled the summary to its end.
    func theCardShowedTheWholeSummary(ofApprovalID approvalID: String) {
        guard waitingRequests.first?.approvalID == approvalID, oldestRequestVisibleSince == nil else { return }
        oldestRequestVisibleSince = currentDate()
    }

    /// The card stopped showing the whole summary: the list closed, or the summary scrolled away from its end.
    func theCardStoppedShowingTheWholeSummary() {
        oldestRequestVisibleSince = nil
    }

    /// The oldest request, when the card has shown its whole summary for `secondsTheCardShowsBeforeAnAnswerCounts`
    /// at `date`, such as the push-to-talk press that starts a voice answer or a click. Any other request is one the
    /// learner could not have read, so a yes cannot answer it.
    func oldestRequestIDTheLearnerHasSeen(at date: Date) -> String? {
        guard let oldestRequest = waitingRequests.first,
              let oldestRequestVisibleSince,
              date.timeIntervalSince(oldestRequestVisibleSince) >= Self.secondsTheCardShowsBeforeAnAnswerCounts else { return nil }
        return oldestRequest.approvalID
    }

    /// The approval card's buttons answer through here. A click on a request the card has not shown in full for a
    /// second is ignored. Returns false when the click did not count.
    @discardableResult
    func answerByClick(approvalID: String, approved: Bool, scope: HarnessApprovalScope) -> Bool {
        guard oldestRequestIDTheLearnerHasSeen(at: currentDate()) == approvalID else {
            print("Agent harness: ignored a click on approval \(approvalID) that came before its card showed it in full for \(Self.secondsTheCardShowsBeforeAnAnswerCounts) s")
            return false
        }
        return answer(approvalID: approvalID, approved: approved, scope: scope)
    }

    /// The request the learner answers next, which is also the one the agent list shows.
    var oldestWaitingRequest: HarnessApprovalRequest? { waitingRequests.first }

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
        Task { [weak self, timeoutSeconds] in
            try? await Task.sleep(for: .seconds(timeoutSeconds))
            self?.declineIfStillWaiting(approvalID: request.approvalID)
        }
    }

    /// An answer that came first stands, since `answer` finds nothing left to decline.
    private func declineIfStillWaiting(approvalID: String) {
        if answer(approvalID: approvalID, approved: false, scope: .once) {
            print("Agent harness: approval \(approvalID) timed out after \(timeoutSeconds) s, so it was declined")
        }
    }

    /// Returns false when no request with this ID is waiting, such as one already answered.
    @discardableResult
    func answer(approvalID: String, approved: Bool, scope: HarnessApprovalScope) -> Bool {
        guard let requestIndex = waitingRequests.firstIndex(where: { $0.approvalID == approvalID }) else { return false }
        let oldestApprovalIDBefore = waitingRequests.first?.approvalID
        waitingRequests.remove(at: requestIndex)
        noteWhenTheOldestRequestShowed(oldestApprovalIDBefore: oldestApprovalIDBefore)
        print("Agent harness: approval \(approvalID) \(approved ? "given" : "declined") (\(scope.rawValue))")
        sendAnswer(approvalID, approved, scope)
        onWaitingRequestsChanged?(waitingRequests)
        return true
    }

    /// Forgets every request at once when the harness process stops, so the list never opens for a request that the
    /// next task's drop would remove a moment later.
    func dropAllRequests() {
        guard !waitingRequests.isEmpty else { return }
        waitingRequests.removeAll()
        oldestRequestVisibleSince = nil
        onWaitingRequestsChanged?(waitingRequests)
    }

    /// Forgets a task's requests when the task ends. The harness already abandoned them, so nothing is sent.
    func dropRequests(forTaskID taskID: UUID) {
        let requestCountBefore = waitingRequests.count
        let oldestApprovalIDBefore = waitingRequests.first?.approvalID
        waitingRequests.removeAll { $0.taskID == taskID }
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
    func startTask(taskID: UUID, goal: String, frontTabTitle: String?, frontTabURL: String?, skill: String? = nil) throws -> AsyncStream<HarnessTaskEvent> {
        try launchTheHarnessIfItIsNotRunning()
        let taskEvents = taskRouter.register(taskID: taskID)
        write(.startTask(taskID: taskID, goal: goal, frontTabTitle: frontTabTitle, frontTabURL: frontTabURL, skill: skill))
        return taskEvents
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
    func startVoiceCommand(taskID: UUID, transcript: String, sceneState: JSONValue, recentActions: [String], tools: [VoiceToolDescriptor]) throws -> AsyncStream<HarnessTaskEvent> {
        try launchTheHarnessIfItIsNotRunning()
        let commandEvents = taskRouter.register(taskID: taskID)
        write(.voiceCommand(taskID: taskID, transcript: transcript, sceneState: sceneState, recentActions: recentActions, tools: tools))
        return commandEvents
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
            appSecret: appSecretDefaults.string(forKey: ClickyAppSecret.defaultsKey),
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
