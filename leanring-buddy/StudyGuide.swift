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
nonisolated enum StudyGuideQuizOutcome: String, Codable, Equatable, Sendable {
    case gotIt
    case missed
    case skipped
}

/// One answered or skipped question from a video quiz. The Worker lists the missed and skipped ones first.
/// Codable, so the results a guide was written with are saved with it and outlive a relaunch.
nonisolated struct StudyGuideQuizResult: Codable, Equatable, Sendable {
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

    /// A guide or a revision starts from a spoken request, so its token is served from the cursor. A refresh starts by
    /// itself after a quiz miss, with no request and no spoken confirmation, so its token just appears beside the notch.
    var isAskedForByTheLearner: Bool {
        switch self {
        case .write, .revise: return true
        case .refresh: return false
        }
    }

    /// A revise or refresh reply means the Worker already wrote the new page and trashed the old one, so the reply is
    /// saved even when the agent was cancelled as it arrived, or the saved guide would point at a trashed page and the
    /// new page would be lost. A cancelled new guide keeps no record.
    var replyIsSavedEvenWhenCancelled: Bool {
        switch self {
        case .write: return false
        case .revise, .refresh: return true
        }
    }
}

/// A missed or skipped question goes into the guide at once. A question the learner got right changes nothing in it.
nonisolated func quizOutcomeRefreshesTheStudyGuide(_ outcome: StudyGuideQuizOutcome) -> Bool {
    outcome != .gotIt
}

/// The Worker refuses a focus or an instruction over this many characters, counted as JavaScript counts them, in
/// UTF-16 code units.
nonisolated let longestStudyGuideWish = 300

/// The Worker refuses more quiz results than this.
nonisolated let mostStudyGuideQuizResults = 20

/// The Worker refuses a quiz result's question, answer, or explanation over this many UTF-16 code units. The planner
/// that writes them has no limit, and a saved result goes with every later revision, so the app cuts them first.
nonisolated let longestStudyGuideQuizText = 2_000

/// Keeps whole characters while they fit in the UTF-16 count, which is how the Worker's limits count, so an emoji or
/// an accent is never split. It walks the text once, since recounting UTF-16 after each cut is slow on long text.
nonisolated func textCutToUTF16Count(_ text: String, longestUTF16Count: Int) -> String {
    var keptUTF16Count = 0
    var endOfKeptText = text.startIndex
    for character in text {
        let characterUTF16Count = character.utf16.count
        guard keptUTF16Count + characterUTF16Count <= longestUTF16Count else { break }
        keptUTF16Count += characterUTF16Count
        endOfKeptText = text.index(after: endOfKeptText)
    }
    return String(text[..<endOfKeptText])
}

/// A focus or an instruction comes from the model's reading of the learner's words, so it is trimmed and cut to
/// what the Worker accepts. Nil when nothing is left, which keeps an empty focus out of the request.
nonisolated func studyGuideWish(fromModelText modelText: String?) -> String? {
    guard let trimmedText = modelText?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedText.isEmpty else {
        return nil
    }
    return textCutToUTF16Count(trimmedText, longestUTF16Count: longestStudyGuideWish)
}

/// The quiz results a revised or refreshed guide is written with: the ones its page already shows, from the saved
/// guide, then the ones logged since, so a relaunch, which empties the log, never drops a miss from the page. A
/// question logged again replaces its saved result, and the newest results are kept when there are too many.
nonisolated func studyGuideQuizResults(saved savedQuizResults: [StudyGuideQuizResult], logged loggedQuizResults: [StudyGuideQuizResult]) -> [StudyGuideQuizResult] {
    func sameQuestion(_ firstResult: StudyGuideQuizResult, _ secondResult: StudyGuideQuizResult) -> Bool {
        firstResult.question == secondResult.question && firstResult.askedAtSeconds == secondResult.askedAtSeconds
    }
    let savedResultsNotLoggedAgain = savedQuizResults.filter { savedResult in
        !loggedQuizResults.contains { loggedResult in sameQuestion(savedResult, loggedResult) }
    }
    return Array((savedResultsNotLoggedAgain + loggedQuizResults).suffix(mostStudyGuideQuizResults))
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
/// so a follow-up answer or an Escape after the answer does not add a second. Results are kept under the same video
/// key a guide is saved under, so a quiz on a playlist URL reaches the guide written from the plain watch URL.
nonisolated struct StudyGuideQuizLog: Equatable, Sendable {
    private struct OpenQuestion: Equatable, Sendable {
        let videoURL: String
        let question: String
        let answerLabel: String
        let explanation: String
        let askedAtSeconds: Double
    }

    private var openQuestion: OpenQuestion?
    private var resultsByVideoKey: [String: [StudyGuideQuizResult]] = [:]

    func results(forVideoURL videoURL: String) -> [StudyGuideQuizResult] {
        resultsByVideoKey[studyGuideVideoKey(forVideoURL: videoURL)] ?? []
    }

    mutating func questionIsAsked(videoURL: String, question: String, answerLabel: String, explanation: String, askedAtSeconds: Double) {
        openQuestion = OpenQuestion(
            videoURL: videoURL,
            question: question,
            answerLabel: answerLabel,
            explanation: explanation,
            askedAtSeconds: askedAtSeconds
        )
    }

    /// Records the outcome for the question that is open, then closes it. Does nothing when no question is open, and
    /// returns whether it recorded anything, so a skip after the answer does not rebuild the guide for nothing.
    @discardableResult
    mutating func closeTheOpenQuestion(with outcome: StudyGuideQuizOutcome) -> Bool {
        guard let openQuestion else { return false }
        self.openQuestion = nil
        resultsByVideoKey[studyGuideVideoKey(forVideoURL: openQuestion.videoURL), default: []].append(StudyGuideQuizResult(
            question: textCutToUTF16Count(openQuestion.question, longestUTF16Count: longestStudyGuideQuizText),
            answerLabel: textCutToUTF16Count(openQuestion.answerLabel, longestUTF16Count: longestStudyGuideQuizText),
            explanation: textCutToUTF16Count(openQuestion.explanation, longestUTF16Count: longestStudyGuideQuizText),
            askedAtSeconds: openQuestion.askedAtSeconds,
            result: outcome
        ))
        return true
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
    /// The quiz results the page was written with. The Worker's reply has none, so the app adds the ones it sent.
    var quizResults: [StudyGuideQuizResult] = []
}

/// A guide saved before quiz results were saved with it, and the Worker's reply, have no quizResults key.
nonisolated extension StudyGuideRecord {
    private enum CodingKeys: String, CodingKey {
        case pageHandle
        case pageURL
        case guide
        case quizResults
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pageHandle = try container.decode(String.self, forKey: .pageHandle)
        pageURL = try container.decode(URL.self, forKey: .pageURL)
        guide = try container.decode(JSONValue.self, forKey: .guide)
        quizResults = try container.decodeIfPresent([StudyGuideQuizResult].self, forKey: .quizResults) ?? []
    }
}

/// The app opens a guide's or a task agent's page with NSWorkspace, which runs any URL scheme, so it keeps only an
/// https page on Notion.
nonisolated func pageURLIsOnNotion(_ pageURL: URL) -> Bool {
    guard pageURL.scheme?.lowercased() == "https", let host = pageURL.host?.lowercased() else { return false }
    return ["notion.so", "notion.com"].contains { notionHost in host == notionHost || host.hasSuffix("." + notionHost) }
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

/// A guide is written from the video in front, so a quiz miss refreshes the quiz video's guide only while that video is
/// still in front. The caller checks again after each await, since the learner may switch tabs meanwhile.
nonisolated func studyGuideRefreshMayStart(forQuizVideoURL quizVideoURL: String, frontVideoURL: String?) -> Bool {
    guard let frontVideoURL else { return false }
    return studyGuideVideoKey(forVideoURL: frontVideoURL) == studyGuideVideoKey(forVideoURL: quizVideoURL)
}

/// A saved guide is forgotten, so the video can get a new one, only when Notion says its page is gone. When the Worker
/// cannot say (nil), the saved guide stands, so a network hiccup never loses it. A revise or refresh trashes the old page
/// before its reply arrives, so a guide with a guide agent running stands too, and so does a guide that a newer one
/// replaced during the check, since forgetting by video would drop the newer one.
nonisolated func savedStudyGuideIsForgotten(pageStillExists: Bool?, aGuideAgentIsRunningForTheVideo: Bool, checkedGuideIsStillSaved: Bool) -> Bool {
    pageStillExists == false && !aGuideAgentIsRunningForTheVideo && checkedGuideIsStillSaved
}

/// What becomes of a refresh queued for a video, by a quiz miss while its guide was being written, when that guide's
/// agent ends.
nonisolated enum QueuedStudyGuideRefreshStep: Equatable {
    /// A cancel ends an agent at once, so a newer guide agent may have started for the video before the cancelled one
    /// unwound, and the queued refresh may be that newer agent's. It runs or drops when the newer agent ends.
    case leaveItForTheRunningGuide
    /// After a failure or a cancel the refresh would fail the same way or undo the cancel. The miss stays in the quiz
    /// log, so the video's next refresh or revise sends it.
    case dropIt
    case runIt
}

nonisolated func queuedStudyGuideRefreshStep(endedGuideWasWritten: Bool, aGuideAgentIsRunningForTheVideo: Bool) -> QueuedStudyGuideRefreshStep {
    if aGuideAgentIsRunningForTheVideo { return .leaveItForTheRunningGuide }
    return endedGuideWasWritten ? .runIt : .dropIt
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
    /// A new guide was asked for a video that already has one, such as after a tab switch between the request and the
    /// write, so the video never gets a second page.
    case guideAlreadyWritten
    /// The Worker's reply named a page that is not an https page on Notion.
    case pageIsNotOnNotion
}

/// The line a failed guide shows beside the cursor. Notion not being connected is the one failure the learner can fix.
nonisolated func studyGuideFailureLine(for error: Error) -> String {
    switch error as? StudyGuideError {
    case .notionIsNotConnected:
        return "Notion isn't connected yet"
    case .guideAlreadyWritten:
        return "This video already has a study guide"
    default:
        return "Couldn't write the study guide"
    }
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
    case .guideAlreadyWritten:
        return "This video already has a study guide"
    case .pageIsNotOnNotion:
        return "The Worker named a page that is not on Notion"
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
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(studyGuideRequest),
            to: studyGuideURL,
            using: session,
            sendsAppSecret: true
        )
        return try studyGuideRecord(statusCode: statusCode, responseData: responseData)
    }

    /// Whether the guide's page is still in Notion and out of the trash. Throws when the Worker or Notion cannot say.
    func pageStillExists(pageHandle: String) async throws -> Bool {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(["pageHandle": pageHandle]),
            to: studyGuideStatusURL,
            using: session,
            // A lookup on the voice command path, so it gives up long before the 150 seconds a guide gets.
            timeoutInterval: 5,
            sendsAppSecret: true
        )
        return try studyGuidePageExists(statusCode: statusCode, responseData: responseData)
    }
}

/// A 400 is the Worker refusing a handle it did not sign, which happens to every saved handle once the Notion token
/// changes. That guide can never be revised or checked again, so it counts as gone, and the video can get a new one.
/// Any other failure means the Worker or Notion cannot say.
nonisolated func studyGuidePageExists(statusCode: Int, responseData: Data) throws -> Bool {
    if statusCode == 400 {
        return false
    }
    guard statusCode == 200 else {
        throw StudyGuideError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
    }
    struct StudyGuideStatusReply: Decodable { let pageExists: Bool }
    return try JSONDecoder().decode(StudyGuideStatusReply.self, from: responseData).pageExists
}

/// A 503 is the Worker saying it has no Notion token, which the learner can fix and Clicky says so.
/// Any other failure is a Worker or Notion error, and so is a page that is not an https page on Notion, since the
/// app opens the page it saves.
nonisolated func studyGuideRecord(statusCode: Int, responseData: Data) throws -> StudyGuideRecord {
    if statusCode == 503 {
        throw StudyGuideError.notionIsNotConnected
    }
    guard statusCode == 200 else {
        throw StudyGuideError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
    }
    let decodedStudyGuideRecord = try JSONDecoder().decode(StudyGuideRecord.self, from: responseData)
    guard pageURLIsOnNotion(decodedStudyGuideRecord.pageURL) else {
        throw StudyGuideError.pageIsNotOnNotion
    }
    return decodedStudyGuideRecord
}
