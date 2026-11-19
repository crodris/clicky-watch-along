//
//  BackgroundTaskAgent.swift
//  leanring-buddy
//
//  The general background agent's app side: the tools the app answers for it, the checks on what it writes, and the
//  Notion page client. Its loop, prompt, and model settings live in the Go harness (harness/), which AgentHarness.swift
//  talks to. CompanionManager runs the tools the harness asks for.
//

import Foundation

/// The tools the app runs for a task agent. Web search and web fetch run within Anthropic's turn, and the harness ends
/// the task on finish, so the harness asks for these four and no other.
nonisolated enum TaskAgentTool: String, Sendable {
    case reportStep = "report_step"
    case readVideoCaptions = "read_video_captions"
    case lookAtVideo = "look_at_video"
    case writeNotionPage = "write_notion_page"
}

nonisolated enum TaskAgentError: Error, Equatable {
    case replyHadNoPageURL
    /// The Worker's /notion-page reply named a page that is not an https page on Notion.
    case pageIsNotOnNotion
    case workerReturned(statusCode: Int, body: String)
    /// The harness ended the task with a reason, such as running out of turns or an error from the Worker.
    case harnessReportedFailure(reason: String)
    /// The harness's output ended with no result for the task and the task was not cancelled.
    case harnessEndedWithNoResult
}

/// The agent list's "Open page" and the background tab open the page this returns, so it must be on Notion.
nonisolated func taskAgentNotionPageURL(responseData: Data) throws -> URL {
    let responseJSON = try JSONDecoder().decode(JSONValue.self, from: responseData)
    guard let pageURL = responseJSON["pageURL"]?.stringValue.flatMap(URL.init(string:)) else {
        throw TaskAgentError.replyHadNoPageURL
    }
    guard pageURLIsOnNotion(pageURL) else {
        throw TaskAgentError.pageIsNotOnNotion
    }
    return pageURL
}

/// What is missing from a write_notion_page input, or nil when it can be written. Strict tools guarantee the shape,
/// not that a string says anything: an agent that called it before its research sent an empty title and summary,
/// and one demo take wrote a page whose whole body was the summary "x". The problem goes back to the agent as a tool
/// error, so it writes the page again from its research instead of leaving the learner an empty page.
nonisolated func taskAgentPageInputProblem(_ pageInput: [String: JSONValue]) -> String? {
    let emptyFields = ["title", "summary"].filter { fieldName in
        (pageInput[fieldName]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    if !emptyFields.isEmpty {
        return "The page needs a \(emptyFields.joined(separator: " and ")). Write it once your research is done."
    }
    let summary = (pageInput["summary"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if summary.count < shortestTaskAgentPageSummary {
        return "The summary \"\(summary)\" is too short to answer the task. Write two to four sentences from your research."
    }
    let sections = pageInput["sections"]?.arrayValue ?? []
    if sections.isEmpty {
        return "The page needs at least one section with a point from your research."
    }
    // The same rule the Worker applies, so a page it would refuse comes back here with a clear reason.
    func hasText(_ value: JSONValue?) -> Bool {
        !(value?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    let everySectionHasAHeadingAndPoints = sections.allSatisfy { section in
        let points = section["points"]?.arrayValue ?? []
        return hasText(section["heading"]) && !points.isEmpty && points.allSatisfy { point in hasText(point) }
    }
    if !everySectionHasAHeadingAndPoints {
        return "Every section needs a heading and at least one point, and no heading or point may be empty."
    }
    return nil
}

/// About one short sentence. A summary shorter than this is a placeholder, not an answer.
nonisolated let shortestTaskAgentPageSummary = 40

/// The router writes the goal from the learner's words, which page text can reach, so it is kept short.
nonisolated let longestTaskAgentGoal = 400

/// A long video's captions are cut here, since every later turn sends them again.
nonisolated let longestTaskAgentCaptionText = 30_000

/// The spoken answer comes from a model that read web pages, so it is cut to about half a minute of speech.
nonisolated let longestSpokenTaskAnswer = 600

/// The prompt asks for two or three sentences, and an answer in a take ran to five and about 20 seconds, so the app
/// speaks at most the first three, then cuts to longestSpokenTaskAnswer.
nonisolated func taskAgentSpokenAnswer(_ spokenSummary: String) -> String {
    var firstSentences: [String] = []
    spokenSummary.enumerateSubstrings(in: spokenSummary.startIndex..., options: .bySentences) { sentence, _, _, stop in
        if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
            firstSentences.append(sentence)
        }
        if firstSentences.count == 3 { stop = true }
    }
    return String(firstSentences.joined(separator: " ").prefix(longestSpokenTaskAnswer))
}

/// Writes the agent's page through the Worker's /notion-page route. The harness never reaches Notion, so the app does.
final class TaskAgentClient {
    private let notionPageURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        guard let notionPageURL = URL(string: "\(workerBaseURL)/notion-page") else {
            preconditionFailure("Worker base URL did not form the Notion page URL: \(workerBaseURL)")
        }
        self.notionPageURL = notionPageURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration)
    }

    /// The agent's own write_notion_page input goes to the Worker as it is, which checks it.
    func writeNotionPage(_ pageInput: [String: JSONValue]) async throws -> URL {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(JSONValue.object(pageInput)),
            to: notionPageURL,
            using: session,
            sendsAppSecret: true
        )
        guard statusCode == 200 else {
            throw TaskAgentError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        try Task.checkCancellation()
        return try taskAgentNotionPageURL(responseData: responseData)
    }
}
