//
//  StudyGuide.swift
//  leanring-buddy
//
//  The app half of the Notion study guide. The learner asks for one by voice while a YouTube video plays,
//  the Worker's POST /study-guide drafts it with Sonnet and writes the Notion page, and the app keeps
//  the page and the guide JSON so a later request can revise or open it.
//  The request and reply shapes are fixed by the Worker's contract. The app never reads the guide's
//  fields: it stores the JSON and sends it back unchanged as the revision's previousGuide.
//

import Foundation

// MARK: - Request

/// How the learner did on one video quiz question, as the Worker's page layout reads it.
nonisolated enum StudyGuideQuizOutcome: String, Encodable, Equatable, Sendable {
    case gotIt
    case missed
    case skipped
}

/// One answered or skipped question from a video quiz. The Worker lists the missed and skipped ones first.
nonisolated struct StudyGuideQuizResult: Encodable, Equatable, Sendable {
    let question: String
    let answerLabel: String
    let explanation: String
    /// The video time the quiz paused at.
    let askedAtSeconds: Double
    let result: StudyGuideQuizOutcome
}

/// Present only when the learner asks to change a guide that already exists.
nonisolated struct StudyGuideRevision: Encodable, Equatable, Sendable {
    /// The handle of the Notion page the new guide replaces, sent back as the Worker signed it.
    let pageHandle: String
    /// The guide the Worker returned last time, sent back unchanged.
    let previousGuide: JSONValue
    /// Nil for a refresh, which keeps the guide's words and rebuilds the page with the newest quiz results.
    let instruction: String?
}

nonisolated struct StudyGuideRequest: Encodable, Equatable, Sendable {
    let videoTitle: String
    let videoURL: String
    let transcriptLines: [VideoQuizTranscriptLine]
    let quizResults: [StudyGuideQuizResult]
    /// An extra wish from the learner, such as "only the part about the engine". Left out of the JSON when nil.
    let focus: String?
    /// Left out of the JSON when nil.
    let revision: StudyGuideRevision?
}

/// What the learner asked the guide to do.
nonisolated enum StudyGuideJob: Equatable, Sendable {
    case write(focus: String?)
    case revise(instruction: String)
    /// After a missed or skipped quiz question, so it reaches "Review these first" of the guide already written.
    case refresh

    var agentKind: BackgroundAgentKind {
        switch self {
        case .write, .revise: return .studyGuide
        case .refresh: return .studyGuideUpdate
        }
    }
}

/// A missed or skipped question goes into the guide at once. A question the learner got right changes nothing in it.
nonisolated func quizOutcomeRefreshesTheStudyGuide(_ outcome: StudyGuideQuizOutcome) -> Bool {
    outcome != .gotIt
}

/// The Worker refuses a focus or an instruction over this many characters.
nonisolated let longestStudyGuideWish = 300

/// The Worker refuses more quiz results than this.
nonisolated let mostStudyGuideQuizResults = 20

/// A focus or an instruction comes from the model's reading of the learner's words, so it is trimmed and cut to
/// what the Worker accepts. Nil when nothing is left, which keeps an empty focus out of the request.
nonisolated func studyGuideWish(fromModelText modelText: String?) -> String? {
    guard let trimmedText = modelText?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedText.isEmpty else {
        return nil
    }
    return String(trimmedText.prefix(longestStudyGuideWish))
}

// MARK: - Quiz results

/// How a graded answer counts toward the guide, or nil while the question is still open.
/// A correct name counts as got it only on the first try, and asking for help or a second wrong answer counts as missed.
/// A first wrong answer leaves the question open for another try, so it has no outcome yet.
func studyGuideQuizOutcome(grade: LiveSceneQuizGrade, wrongAnswerCount: Int) -> StudyGuideQuizOutcome? {
    switch grade {
    case .nameAndFunctionWord, .nameOnly:
        return wrongAnswerCount == 0 ? .gotIt : .missed
    case .askedForHelp:
        return .missed
    case .wrong:
        return wrongAnswerCount == 0 ? nil : .missed
    }
}

/// The video quiz questions the learner has finished, per video. At most one result is kept per question,
/// so a follow-up answer or an Escape after the answer does not add a second.
nonisolated struct StudyGuideQuizLog: Equatable, Sendable {
    private struct OpenQuestion: Equatable, Sendable {
        let videoURL: String
        let question: String
        let answerLabel: String
        let explanation: String
        let askedAtSeconds: Double
    }

    private var openQuestion: OpenQuestion?
    private(set) var resultsByVideoURL: [String: [StudyGuideQuizResult]] = [:]

    mutating func questionIsAsked(videoURL: String, question: String, answerLabel: String, explanation: String, askedAtSeconds: Double) {
        openQuestion = OpenQuestion(
            videoURL: videoURL,
            question: question,
            answerLabel: answerLabel,
            explanation: explanation,
            askedAtSeconds: askedAtSeconds
        )
    }

    /// Records the outcome for the question that is open, then closes it. Does nothing when no question is open.
    mutating func closeTheOpenQuestion(with outcome: StudyGuideQuizOutcome) {
        guard let openQuestion else { return }
        self.openQuestion = nil
        resultsByVideoURL[openQuestion.videoURL, default: []].append(StudyGuideQuizResult(
            question: openQuestion.question,
            answerLabel: openQuestion.answerLabel,
            explanation: openQuestion.explanation,
            askedAtSeconds: openQuestion.askedAtSeconds,
            result: outcome
        ))
    }

    /// For a quiz that stops with a question open, which the learner never answered or skipped.
    mutating func discardTheOpenQuestion() {
        openQuestion = nil
    }
}

/// What the app reads from the video in Chrome's front tab to write a guide about it.
nonisolated struct StudyGuideVideo: Equatable, Sendable {
    let title: String
    let url: String
    let transcriptLines: [VideoQuizTranscriptLine]
    let quizResults: [StudyGuideQuizResult]
}

// MARK: - Worker reply and client

/// The page Notion made and the guide behind it. The guide stays opaque JSON.
/// Codable, so a saved guide is stored as JSON and read back after a relaunch.
nonisolated struct StudyGuideRecord: Codable, Equatable, Sendable {
    /// The page id with the Worker's signature, opaque to the app. Only a signed handle lets a revision trash its page.
    let pageHandle: String
    let pageURL: URL
    let guide: JSONValue
}

/// The key a guide is saved under: the YouTube video id, so the same video opened at another time or from a playlist
/// finds the same guide. A URL with no video id in it is its own key.
nonisolated func studyGuideVideoKey(forVideoURL videoURLText: String) -> String {
    guard let videoURLComponents = URLComponents(string: videoURLText), let host = videoURLComponents.host?.lowercased() else {
        return videoURLText
    }
    let pathParts = videoURLComponents.path.split(separator: "/").map(String.init)
    if host == "youtu.be", let videoID = pathParts.first {
        return videoID
    }
    guard host == "youtube.com" || host.hasSuffix(".youtube.com") else { return videoURLText }
    if let videoID = videoURLComponents.queryItems?.first(where: { $0.name == "v" })?.value, !videoID.isEmpty {
        return videoID
    }
    if pathParts.count >= 2, ["shorts", "live", "embed"].contains(pathParts[0]) {
        return pathParts[1]
    }
    return videoURLText
}

/// The guides written so far, one UserDefaults entry per video, so a guide outlives a relaunch and a video never gets a
/// second page. The demo's record-shot.sh deletes its video's entry by this key, so keep the two in step.
nonisolated struct SavedStudyGuides {
    static let userDefaultsKeyPrefix = "savedStudyGuide."

    let userDefaults: UserDefaults

    func record(forVideoURL videoURLText: String) -> StudyGuideRecord? {
        guard let savedJSON = userDefaults.data(forKey: Self.userDefaultsKey(forVideoURL: videoURLText)) else { return nil }
        return try? JSONDecoder().decode(StudyGuideRecord.self, from: savedJSON)
    }

    func save(_ studyGuideRecord: StudyGuideRecord, forVideoURL videoURLText: String) {
        guard let recordJSON = try? JSONEncoder().encode(studyGuideRecord) else { return }
        userDefaults.set(recordJSON, forKey: Self.userDefaultsKey(forVideoURL: videoURLText))
    }

    /// For a guide whose Notion page is gone, so the video can get a new one.
    func forget(forVideoURL videoURLText: String) {
        userDefaults.removeObject(forKey: Self.userDefaultsKey(forVideoURL: videoURLText))
    }

    private static func userDefaultsKey(forVideoURL videoURLText: String) -> String {
        userDefaultsKeyPrefix + studyGuideVideoKey(forVideoURL: videoURLText)
    }
}

nonisolated enum StudyGuideError: Error, Equatable {
    /// The Worker has no Notion token, which it reports as a 503.
    case notionIsNotConnected
    case workerReturned(statusCode: Int, body: String)
    /// A revision was asked for a video that has no guide yet.
    case noGuideToRevise
}

/// The line a failed guide shows beside the cursor. Notion not being connected is the one failure the learner can fix.
nonisolated func studyGuideFailureLine(for error: Error) -> String {
    if let studyGuideError = error as? StudyGuideError, studyGuideError == .notionIsNotConnected {
        return "Notion isn't connected yet"
    }
    return "Couldn't write the study guide"
}

/// Why a guide failed, in the agent list, where there is room for more than the line beside the cursor.
nonisolated func studyGuideFailureReason(for error: Error) -> String {
    switch error as? StudyGuideError {
    case .notionIsNotConnected:
        return "Notion isn't connected yet"
    case .workerReturned(let statusCode, _):
        return "The Worker answered \(statusCode)"
    case .noGuideToRevise:
        return "No study guide has been written for this video yet"
    case nil:
        return (error as? LocalizedError)?.errorDescription ?? "Couldn't write the study guide"
    }
}

/// A guide cancelled from the agent list ends its request with one of these, which is not a failure.
nonisolated func errorIsACancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

@MainActor
final class StudyGuideClient {
    private let studyGuideURL: URL
    private let studyGuideStatusURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        guard let studyGuideURL = URL(string: "\(workerBaseURL)/study-guide"),
              let studyGuideStatusURL = URL(string: "\(workerBaseURL)/study-guide-status") else {
            preconditionFailure("Worker base URL did not form the study guide URLs: \(workerBaseURL)")
        }
        self.studyGuideURL = studyGuideURL
        self.studyGuideStatusURL = studyGuideStatusURL
        let configuration = URLSessionConfiguration.default
        // Sonnet drafts the guide in 20 to 60 seconds, and Notion takes a few more.
        configuration.timeoutIntervalForRequest = 150
        configuration.timeoutIntervalForResource = 150
        session = URLSession(configuration: configuration)
    }

    func writeStudyGuide(_ studyGuideRequest: StudyGuideRequest) async throws -> StudyGuideRecord {
        var request = URLRequest(url: studyGuideURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(studyGuideRequest)
        let (responseData, response) = try await session.data(for: request)
        // URLSession returns URLResponse. The Worker answers over HTTP.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return try studyGuideRecord(statusCode: statusCode, responseData: responseData)
    }

    /// Whether the guide's page is still in Notion and out of the trash. Throws when the Worker or Notion cannot say.
    func pageStillExists(pageHandle: String) async throws -> Bool {
        var request = URLRequest(url: studyGuideStatusURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A lookup on the voice command path, so it gives up long before the 150 seconds a guide gets.
        request.timeoutInterval = 5
        request.httpBody = try JSONEncoder().encode(["pageHandle": pageHandle])
        let (responseData, response) = try await session.data(for: request)
        // URLSession returns URLResponse. The Worker answers over HTTP.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw StudyGuideError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        struct StudyGuideStatusReply: Decodable { let pageExists: Bool }
        return try JSONDecoder().decode(StudyGuideStatusReply.self, from: responseData).pageExists
    }
}

/// A 503 is the Worker saying it has no Notion token, which the learner can fix and Clicky says so.
/// Any other failure is a Worker or Notion error.
nonisolated func studyGuideRecord(statusCode: Int, responseData: Data) throws -> StudyGuideRecord {
    if statusCode == 503 {
        throw StudyGuideError.notionIsNotConnected
    }
    guard statusCode == 200 else {
        throw StudyGuideError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
    }
    return try JSONDecoder().decode(StudyGuideRecord.self, from: responseData)
}
