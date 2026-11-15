//
//  BackgroundTaskAgent.swift
//  leanring-buddy
//
//  The general background agent's data and Worker client: the tools the app answers for it, one turn of its reply, and
//  what the loop does next. The agent runs on POST /background-agent, which adds web search and web fetch on
//  Anthropic's side. CompanionManager owns the loop and runs these tools.
//

import Foundation

/// The tools the app runs for a task agent. Web search and web fetch are not here, because they run within the turn.
nonisolated enum TaskAgentTool: String, CaseIterable, Sendable {
    case reportStep = "report_step"
    case readVideoCaptions = "read_video_captions"
    case lookAtScreen = "look_at_screen"
    case writeNotionPage = "write_notion_page"
    case finish = "finish"

    var descriptor: VoiceToolDescriptor {
        VoiceToolDescriptor(name: rawValue, description: toolDescription, inputSchema: inputSchema, readOnly: true)
    }

    private var toolDescription: String {
        switch self {
        case .reportStep:
            return "Show the learner, next to the cursor, what you are doing now in 3 to 6 words, such as \"Searching for the booster catch\"."
        case .readVideoCaptions:
            return "Read the title, link, and timestamped captions of the YouTube video in Chrome's front tab."
        case .lookAtScreen:
            return "See a screenshot of the screen that shows the video, as it is now."
        case .writeNotionPage:
            return "Write your findings as a private Notion page, opened for the learner in a background tab. Call it at most once."
        case .finish:
            return "End the task. spokenSummary is read aloud when the learner asks what you found."
        }
    }

    private var inputSchema: JSONValue {
        func stringProperty(_ description: String) -> JSONValue {
            .object(["type": .string("string"), "description": .string(description)])
        }
        func objectSchema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
            ])
        }
        switch self {
        case .reportStep:
            return objectSchema(["step": stringProperty("What you are doing now, such as Searching for the booster catch.")], required: ["step"])
        case .readVideoCaptions, .lookAtScreen:
            return objectSchema([:], required: [])
        case .writeNotionPage:
            let sectionSchema = objectSchema(
                ["heading": stringProperty("A short heading."), "points": .object(["type": .string("array"), "items": .object(["type": .string("string")])])],
                required: ["heading", "points"]
            )
            let sourceSchema = objectSchema(["title": stringProperty("The page's title."), "url": stringProperty("The https link.")], required: ["title", "url"])
            return objectSchema(
                [
                    "title": stringProperty("The page title."),
                    "summary": stringProperty("Two to four sentences that answer the task."),
                    "sections": .object(["type": .string("array"), "items": sectionSchema]),
                    "sources": .object(["type": .string("array"), "items": sourceSchema]),
                ],
                required: ["title", "summary", "sections", "sources"]
            )
        case .finish:
            return objectSchema(["spokenSummary": stringProperty("The answer in two or three short, plain sentences, at most 50 words.")], required: ["spokenSummary"])
        }
    }
}

/// One turn of the agent's reply. Every block is kept, because the next turn must send thinking and server tool
/// results back unchanged.
nonisolated struct TaskAgentTurn: Equatable, Sendable {
    let assistantContent: [JSONValue]
    let stopReason: String
    let toolCalls: [VoiceToolCall]
    let text: String

    init(responseData: Data) throws {
        let responseJSON = try JSONDecoder().decode(JSONValue.self, from: responseData)
        guard let contentBlocks = responseJSON["content"]?.arrayValue else {
            throw TaskAgentError.replyHadNoContent
        }
        assistantContent = contentBlocks
        stopReason = responseJSON["stopReason"]?.stringValue ?? "unknown"
        toolCalls = contentBlocks.compactMap { contentBlock in
            guard contentBlock["type"]?.stringValue == "tool_use",
                  let id = contentBlock["id"]?.stringValue,
                  let name = contentBlock["name"]?.stringValue,
                  let input = contentBlock["input"]?.objectValue else {
                return nil
            }
            return VoiceToolCall(id: id, name: name, input: input)
        }
        text = contentBlocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum TaskAgentError: Error, Equatable {
    case replyHadNoContent
    case workerReturned(statusCode: Int, body: String)
    case ranOutOfTurns
    case endedWithNoAnswer
}

/// What the loop does after a turn.
nonisolated enum TaskAgentNextStep: Equatable, Sendable {
    /// A server tool ran long and Anthropic paused the turn, so the same messages go back to let it finish.
    case continueThePausedTurn
    /// Run these app tools and send their results back.
    case runTools([VoiceToolCall])
    case finished(spokenSummary: String)
    /// The agent stopped without calling finish. Its last words stand as the answer, or the task failed with none.
    case endedWithText(String)
}

/// A finish call ends the task even when other calls come with it, since the agent has decided it is done.
nonisolated func taskAgentNextStep(after turn: TaskAgentTurn) -> TaskAgentNextStep {
    if turn.stopReason == "pause_turn" {
        return .continueThePausedTurn
    }
    if let finishCall = turn.toolCalls.first(where: { $0.name == TaskAgentTool.finish.rawValue }) {
        let spokenSummary = (finishCall.input["spokenSummary"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return spokenSummary.isEmpty ? .endedWithText(turn.text) : .finished(spokenSummary: spokenSummary)
    }
    if !turn.toolCalls.isEmpty {
        return .runTools(turn.toolCalls)
    }
    return .endedWithText(turn.text)
}

/// The first message: the learner's words and the page they were on, which "this" in the task refers to.
nonisolated func taskAgentFirstMessage(goal: String, frontTabTitle: String?, frontTabURL: String?) -> String {
    var lines = ["Task from the learner: \(goal)"]
    if let frontTabTitle, let frontTabURL {
        lines.append("The learner is watching: \(frontTabTitle), \(frontTabURL)")
    }
    return lines.joined(separator: "\n")
}

/// A turn can search the web and think, so it gets far longer than a voice command. The whole task has a turn budget.
nonisolated let mostTaskAgentTurns = 14

/// The router writes the goal from the learner's words, which page text can reach, so it is kept short.
nonisolated let longestTaskAgentGoal = 400

/// A long video's captions are cut here, since every later turn sends them again.
nonisolated let longestTaskAgentCaptionText = 30_000

/// The spoken answer comes from a model that read web pages, so it is cut to about half a minute of speech.
nonisolated let longestSpokenTaskAnswer = 600

final class TaskAgentClient {
    private let backgroundAgentURL: URL
    private let notionPageURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        guard let backgroundAgentURL = URL(string: "\(workerBaseURL)/background-agent"),
              let notionPageURL = URL(string: "\(workerBaseURL)/notion-page") else {
            preconditionFailure("Worker base URL did not form the background agent URLs: \(workerBaseURL)")
        }
        self.backgroundAgentURL = backgroundAgentURL
        self.notionPageURL = notionPageURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
    }

    func requestTurn(messages: [JSONValue]) async throws -> TaskAgentTurn {
        let requestBody = JSONValue.object([
            "messages": .array(messages),
            "tools": .array(TaskAgentTool.allCases.map(\.descriptor.workerRequestJSON)),
        ])
        return try TaskAgentTurn(responseData: try await post(requestBody, to: backgroundAgentURL))
    }

    /// The agent's own write_notion_page input goes to the Worker as it is, which checks it.
    func writeNotionPage(_ pageInput: [String: JSONValue]) async throws -> URL {
        let responseData = try await post(.object(pageInput), to: notionPageURL)
        let responseJSON = try JSONDecoder().decode(JSONValue.self, from: responseData)
        guard let pageURL = responseJSON["pageURL"]?.stringValue.flatMap(URL.init(string:)) else {
            throw TaskAgentError.replyHadNoContent
        }
        return pageURL
    }

    private func post(_ requestBody: JSONValue, to url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let (responseData, response) = try await session.data(for: request)
        // URLSession returns URLResponse. The Worker answers over HTTP.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw TaskAgentError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        try Task.checkCancellation()
        return responseData
    }
}
