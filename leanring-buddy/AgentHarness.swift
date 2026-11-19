//
//  AgentHarness.swift
//  leanring-buddy
//
//  The task agent's loop runs in a Go helper process, harness/ in the repo, bundled at Contents/Helpers/
//  clicky-agent-harness. The app and the harness talk in JSON lines on the harness's stdin and stdout. The harness
//  runs Claude through the Worker's /v1/messages passthrough and asks the app only for the tools that touch the Mac
//  or Notion. harness/protocol.go is the other half of the messages in this file.
//

import Foundation

// MARK: - Messages from the harness

/// One tool call of a task agent's turn. The name stays text, so a name this app does not know still reaches the task
/// loop, which answers it with an error instead of leaving the agent waiting.
nonisolated struct HarnessToolCall: Equatable, Sendable {
    let toolUseID: String
    let toolName: String
    let input: [String: JSONValue]
}

/// What the app hears from the harness for one task. The stream of events ends after finished or failed.
nonisolated enum HarnessTaskEvent: Equatable, Sendable {
    case toolCall(HarnessToolCall)
    case finished(spokenSummary: String)
    case failed(reason: String)
}

/// One line the harness wrote, checked at the boundary. A line that is not one of these is dropped and logged.
nonisolated enum HarnessMessage: Equatable, Sendable {
    case ready
    case toolCall(taskID: UUID, HarnessToolCall)
    case taskFinished(taskID: UUID, spokenSummary: String)
    case taskFailed(taskID: UUID, reason: String)
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
        case "tool_call":
            guard let input = messageJSON["input"]?.objectValue else {
                throw ParseError.missingField(messageType: messageType, fieldName: "input")
            }
            self = .toolCall(
                taskID: try requiredTaskID(),
                HarnessToolCall(toolUseID: try requiredText("toolUseID"), toolName: try requiredText("name"), input: input)
            )
        case "task_finished":
            self = .taskFinished(taskID: try requiredTaskID(), spokenSummary: try requiredText("spokenSummary"))
        case "task_failed":
            self = .taskFailed(taskID: try requiredTaskID(), reason: try requiredText("reason"))
        case "log":
            self = .log(message: try requiredText("message"))
        default:
            throw ParseError.unknownType(messageType)
        }
    }
}

// MARK: - Messages to the harness

nonisolated enum HarnessCommand: Equatable, Sendable {
    case startTask(taskID: UUID, goal: String, frontTabTitle: String?, frontTabURL: String?)
    /// `content` is a string or an array of content blocks, such as the image block look_at_video returns.
    case toolResult(taskID: UUID, toolUseID: String, content: JSONValue, isError: Bool)
    case cancelTask(taskID: UUID)

    var json: JSONValue {
        switch self {
        case .startTask(let taskID, let goal, let frontTabTitle, let frontTabURL):
            return .object([
                "type": .string("start_task"),
                "taskID": .string(taskID.uuidString),
                "goal": .string(goal),
                "frontTabTitle": frontTabTitle.map(JSONValue.string) ?? .null,
                "frontTabURL": frontTabURL.map(JSONValue.string) ?? .null,
            ])
        case .toolResult(let taskID, let toolUseID, let content, let isError):
            return .object([
                "type": .string("tool_result"),
                "taskID": .string(taskID.uuidString),
                "toolUseID": .string(toolUseID),
                "content": content,
                "isError": .bool(isError),
            ])
        case .cancelTask(let taskID):
            return .object(["type": .string("cancel_task"), "taskID": .string(taskID.uuidString)])
        }
    }

    /// One line, since JSON text escapes every newline inside a string.
    var line: Data {
        Data((json.compactJSONText + "\n").utf8)
    }
}

// MARK: - Routing a task's messages

/// Hands each harness message to the task it belongs to. The harness is one process for every task, and each task
/// reads its own stream of events.
@MainActor
final class HarnessTaskRouter {
    private var eventContinuationsByTaskID: [UUID: AsyncStream<HarnessTaskEvent>.Continuation] = [:]

    var hasATaskRunning: Bool { !eventContinuationsByTaskID.isEmpty }

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
        case .log(let logText):
            print(logText)
        case .toolCall(let taskID, let toolCall):
            eventContinuationsByTaskID[taskID]?.yield(.toolCall(toolCall))
        case .taskFinished(let taskID, let spokenSummary):
            end(taskID: taskID, lastEvent: .finished(spokenSummary: spokenSummary))
        case .taskFailed(let taskID, let reason):
            end(taskID: taskID, lastEvent: .failed(reason: reason))
        }
    }

    /// Ends a task's stream, after one last event when there is one. A task the router does not know is ignored,
    /// since a cancelled task may still have a message on its way.
    func end(taskID: UUID, lastEvent: HarnessTaskEvent? = nil) {
        guard let eventContinuation = eventContinuationsByTaskID.removeValue(forKey: taskID) else { return }
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

// MARK: - The helper process

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
    private let taskRouter = HarnessTaskRouter()

    private var runningProcess: Process?
    private var standardInputHandle: FileHandle?
    private var standardOutputReaderTask: Task<Void, Never>?
    /// Every write goes through this one queue, so lines never interleave and a large tool result, such as a screenshot,
    /// never blocks the main thread on a full pipe.
    private let standardInputWriteQueue = DispatchQueue(label: "com.crodris.clicky-watch-along.agent-harness-stdin")

    /// `helperURL` is where Xcode's "Build Agent Harness" phase puts the binary, unless a test points at another build.
    init(
        workerBaseURL: String,
        appSecretDefaults: UserDefaults = .standard,
        helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clicky-agent-harness")
    ) {
        self.workerBaseURL = workerBaseURL
        self.appSecretDefaults = appSecretDefaults
        self.helperURL = helperURL
    }

    /// Starts a task on the harness. The stream ends after the task finishes or fails, or when the harness stops.
    func startTask(taskID: UUID, goal: String, frontTabTitle: String?, frontTabURL: String?) throws -> AsyncStream<HarnessTaskEvent> {
        try launchTheHarnessIfItIsNotRunning()
        let taskEvents = taskRouter.register(taskID: taskID)
        write(.startTask(taskID: taskID, goal: goal, frontTabTitle: frontTabTitle, frontTabURL: frontTabURL))
        return taskEvents
    }

    func sendToolResult(taskID: UUID, toolUseID: String, content: JSONValue, isError: Bool) {
        write(.toolResult(taskID: taskID, toolUseID: toolUseID, content: content, isError: isError))
    }

    /// Stops the task in the harness, which then sends nothing more for it.
    func cancelTask(taskID: UUID) {
        taskRouter.end(taskID: taskID)
        write(.cancelTask(taskID: taskID))
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
        var harnessEnvironment = ["CLICKY_WORKER_BASE_URL": workerBaseURL]
        if let appSecret = appSecretDefaults.string(forKey: ClickyAppSecret.defaultsKey), !appSecret.isEmpty {
            harnessEnvironment["CLICKY_APP_SECRET"] = appSecret
        }
        process.environment = harnessEnvironment

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
        standardInputHandle = standardInputPipe.fileHandleForWriting
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
            taskRouter.route(try HarnessMessage(line: outputLine))
        } catch {
            print("Agent harness: dropped a line it could not read (\(error)): \(outputLine.prefix(200))")
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
        standardInputHandle = nil
        standardOutputReaderTask?.cancel()
        standardOutputReaderTask = nil
        taskRouter.failEveryTask(reason: "The agent harness stopped with status \(exitedProcess.terminationStatus)")
    }

    private func write(_ command: HarnessCommand) {
        guard let standardInputHandle else {
            print("Agent harness: dropped a \(command.json["type"]?.stringValue ?? "message") because the harness is not running")
            return
        }
        let commandLine = command.line
        standardInputWriteQueue.async {
            do {
                try standardInputHandle.write(contentsOf: commandLine)
            } catch {
                print("Agent harness: could not write to the harness: \(error)")
            }
        }
    }
}
