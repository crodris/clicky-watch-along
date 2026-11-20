//
//  BackgroundTaskAgent.swift
//  leanring-buddy
//
//  The general background agent's app side: the tools the app answers for it, the checks on what it writes, and the
//  Notion page client. Its loop, prompt, and model settings live in the Go harness (harness/), which AgentHarness.swift
//  talks to. CompanionManager runs the tools the harness asks for.
//

import AppKit
import Foundation

/// The tools the app runs for a task agent. Web search and web fetch run within Anthropic's turn, and the harness ends
/// the task on finish, so the harness asks for these and no other. MCP server tools run in the harness too.
nonisolated enum TaskAgentTool: String, Sendable {
    case reportStep = "report_step"
    case readVideoCaptions = "read_video_captions"
    case lookAtVideo = "look_at_video"
    case writeNotionPage = "write_notion_page"
    // The general tools, run by runTaskAgentGeneralTool below.
    case takeScreenshot = "take_screenshot"
    case readClipboard = "read_clipboard"
    case writeClipboard = "write_clipboard"
    case openURL = "open_url"
}

/// Where the agent's skills live. A skill is a Markdown file, <name>.md, that the harness reads when a task names it.
nonisolated enum TaskAgentFolders {
    /// ~/Library/Application Support/Clicky, which holds the learner's own skills and the MCP server config.
    static func clickyApplicationSupportURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clicky", isDirectory: true)
    }

    /// The MCP servers the learner set up, in the shape of Claude Code's mcpServers. The harness reads it when the first
    /// task starts, and a missing file means no servers.
    static func mcpConfigURL(clickyApplicationSupportURL: URL = TaskAgentFolders.clickyApplicationSupportURL()) -> URL {
        clickyApplicationSupportURL.appendingPathComponent("mcp.json")
    }

    /// The learner's folder first, so a skill they wrote overrides a bundled one of the same name, then the bundled
    /// skills. Those live in leanring-buddy/Skills, but the target's synchronized folders copy every file to the top of
    /// the bundle's Resources folder, so the bundled skills are read from there. Both readers skip a file that is not a
    /// skill.
    static func skillsDirectoryURLs(bundleResourceURL: URL?, clickyApplicationSupportURL: URL = TaskAgentFolders.clickyApplicationSupportURL()) -> [URL] {
        var skillsDirectoryURLs = [clickyApplicationSupportURL.appendingPathComponent("Skills", isDirectory: true)]
        if let bundleResourceURL {
            skillsDirectoryURLs.append(bundleResourceURL)
        }
        return skillsDirectoryURLs
    }
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

// MARK: - General tools

/// The folder that holds the files a task's tools make, such as the screenshot take_screenshot saves so a later tool can
/// pass its path. It is deleted when the task ends.
nonisolated enum TaskAgentWorkspace {
    static func folderURL(taskID: UUID, temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectoryURL.appendingPathComponent("ClickyTasks", isDirectory: true).appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    /// The next free screenshot-N.jpg in the task's folder, counting from 1.
    static func nextScreenshotURL(taskID: UUID, temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folderURL = folderURL(taskID: taskID, temporaryDirectoryURL: temporaryDirectoryURL)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        var screenshotNumber = 1
        while FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("screenshot-\(screenshotNumber).jpg").path) {
            screenshotNumber += 1
        }
        return folderURL.appendingPathComponent("screenshot-\(screenshotNumber).jpg")
    }

    static func removeFolder(taskID: UUID, temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: folderURL(taskID: taskID, temporaryDirectoryURL: temporaryDirectoryURL))
    }
}

/// The clipboard's text is cut to this, since every later turn sends a tool result again.
nonisolated let longestTaskAgentClipboardText = 20_000

/// The link open_url may open: https with a host, and short. The agent reads web pages, which can ask it to open a link,
/// so nothing else (file:, a custom app scheme, http) reaches NSWorkspace.
nonisolated func taskAgentOpenableURL(_ linkText: String) -> URL? {
    let trimmedLinkText = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedLinkText.count <= 2048,
          let url = URL(string: trimmedLinkText),
          url.scheme?.lowercased() == "https",
          let host = url.host, !host.isEmpty else {
        return nil
    }
    return url
}

/// Runs one of the general tools and returns its tool_result content. A tool that fails returns an error result, so the
/// agent can work around it. The Mac is touched only here and only for the four tools the harness lists.
@MainActor
func runTaskAgentGeneralTool(
    named toolName: String,
    input: [String: JSONValue],
    taskID: UUID,
    pasteboard: NSPasteboard = .general
) async -> (content: JSONValue, isError: Bool) {
    switch TaskAgentTool(rawValue: toolName) {
    case .takeScreenshot:
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let screenCapture = screenCaptures.first(where: \.isCursorScreen) ?? screenCaptures.first else {
                return (.string("No screen could be captured"), true)
            }
            let screenshotURL = try TaskAgentWorkspace.nextScreenshotURL(taskID: taskID)
            try screenCapture.imageData.write(to: screenshotURL)
            return (.array([
                .object(["type": .string("text"), "text": .string("Saved to \(screenshotURL.path)")]),
                .object([
                    "type": .string("image"),
                    "source": .object(["type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string(screenCapture.imageData.base64EncodedString())]),
                ]),
            ]), false)
        } catch {
            return (.string("The screenshot failed: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"), true)
        }
    case .readClipboard:
        guard let clipboardText = pasteboard.string(forType: .string), !clipboardText.isEmpty else {
            return (.string("The clipboard holds no text"), true)
        }
        return (.string(String(clipboardText.prefix(longestTaskAgentClipboardText))), false)
    case .writeClipboard:
        guard let text = input["text"]?.stringValue, !text.isEmpty else {
            return (.string("text must hold the text to copy"), true)
        }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            return (.string("The clipboard would not take the text"), true)
        }
        return (.string("Copied \(text.count) characters to the clipboard"), false)
    case .openURL:
        guard let url = taskAgentOpenableURL(input["url"]?.stringValue ?? "") else {
            return (.string("url must be an https link"), true)
        }
        guard NSWorkspace.shared.open(url) else {
            return (.string("The link would not open"), true)
        }
        return (.string("Opened \(url.absoluteString)"), false)
    case .reportStep, .readVideoCaptions, .lookAtVideo, .writeNotionPage, nil:
        return (.string("\(toolName) is not a general tool"), true)
    }
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
