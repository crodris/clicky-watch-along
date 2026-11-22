//
//  VideoQuizSession.swift
//  leanring-buddy
//
//  Quizzes the learner on a YouTube video playing in Chrome. It reads the
//  video's captions once, asks the Worker to pick the moments ahead of time,
//  then watches the video's clock through AppleScript and pauses it at each
//  moment so Clicky can ask the question.
//

import AppKit
import Foundation

// MARK: - Voice command

nonisolated enum VideoQuizVoiceCommand: Equatable {
    case start
    case stop
}

/// The video-quiz command this transcript speaks, or nil when it speaks none.
/// Start needs a video word and a quiz word, so "watch this with me" alone
/// never pauses anything. Stop is checked first so "stop quizzing" never starts a quiz.
nonisolated func videoQuizVoiceCommand(for transcript: String) -> VideoQuizVoiceCommand? {
    let transcriptWords = transcript.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { transcriptWord in
            !transcriptWord.isEmpty
        }
    let normalizedTranscript = transcriptWords.joined(separator: " ")

    // The stop word has to sit right before the quiz word, so "quiz me at the end of the video" still starts one.
    let asksToStopTheQuiz = normalizedTranscript.range(
        of: #"\b(stop|end|cancel|quit|exit|done with)( the| this| our| my)?( video)? (quiz|quizzing)\b"#,
        options: .regularExpression
    ) != nil
    // A request to stop still counts when speech recognition drops the last word ("can we stop the").
    let asksToStopWithoutNamingTheQuiz = normalizedTranscript.range(
        of: #"\b(can we|could we|let s|lets|please) stop\b"#,
        options: .regularExpression
    ) != nil
    if asksToStopTheQuiz || asksToStopWithoutNamingTheQuiz || normalizedTranscript.contains("stop watching") {
        return .stop
    }

    let transcriptNamesAVideo = transcriptWords.contains { transcriptWord in
        transcriptWord == "video" || transcriptWord == "videos" || transcriptWord.hasPrefix("watch")
    }
    let transcriptAsksToBeQuizzed = transcriptWords.contains { transcriptWord in
        transcriptWord.hasPrefix("quiz")
    } || normalizedTranscript.contains("test me")
        // Apple Speech hears "quiz me" as "kiss me" often enough to matter.
        || normalizedTranscript.contains("kiss me")
    return transcriptNamesAVideo && transcriptAsksToBeQuizzed ? .start : nil
}

/// Whether the quiz phrases above are matched before the router reads the words. With the Theme Studio card open the router
/// reads every word, since "can we stop" would otherwise say "Okay, I'll stop quizzing." with no quiz, and "quiz me on this
/// video" would start one under the card. The router still offers `end_quiz` while a quiz runs. An open quiz question keeps
/// the phrases, since the router takes no command then and the words would otherwise be graded as an answer.
nonisolated func videoQuizPhrasesAreMatchedAheadOfTheRouter(themeStudioIsOpen: Bool, phaseIsWaitingForAQuizAnswer: Bool) -> Bool {
    !themeStudioIsOpen || phaseIsWaitingForAQuizAnswer
}

/// The page's answer about its video goes into the model's prompt, and any page can rewrite what its scripts return.
/// So only the five expected fields pass, each with its expected type, and the tab title is cut short.
/// Whether the tab is on YouTube comes from the tab's URL, which the page cannot rewrite.
/// Nil when a field is missing or has the wrong type.
nonisolated func learnerVideoStateTheModelMayRead(pageVideoState: JSONValue, tabTitle: String, pageIsOnYouTube: Bool) -> JSONValue? {
    guard let seconds = pageVideoState["seconds"]?.numberValue,
          let durationSeconds = pageVideoState["durationSeconds"]?.numberValue,
          let playbackRate = pageVideoState["playbackRate"]?.numberValue,
          let paused = pageVideoState["paused"]?.boolValue,
          let playing = pageVideoState["playing"]?.boolValue else {
        return nil
    }
    return .object([
        "seconds": .number(seconds),
        "durationSeconds": .number(durationSeconds),
        "playbackRate": .number(playbackRate),
        "paused": .bool(paused),
        "playing": .bool(playing),
        "title": .string(String(tabTitle.prefix(120))),
        // From the tab's URL, which the page cannot rewrite, so the app can offer caption search only on YouTube.
        "onYouTube": .bool(pageIsOnYouTube),
    ])
}

/// True for youtube.com and its subdomains, and false for a lookalike such as notyoutube.com.
nonisolated func urlIsOnYouTube(urlText: String) -> Bool {
    guard var host = URL(string: urlText)?.host()?.lowercased() else { return false }
    while host.hasSuffix(".") { host.removeLast() }
    return host == "youtube.com" || host.hasSuffix(".youtube.com")
}

/// True for a watch page on YouTube itself. A page on another site that only mentions a YouTube watch URL, such as a
/// Wayback Machine copy, is not one, since its video cannot be grabbed through YouTube's player.
nonisolated func urlIsAYouTubeWatchPage(urlText: String) -> Bool {
    urlIsOnYouTube(urlText: urlText) && URL(string: urlText)?.path == "/watch"
}

/// Caption search hands the front tab's URL to yt-dlp, so it reads only https pages on a public host,
/// never a page on this Mac or on the local network.
nonisolated func captionSearchMayReadTheVideoPage(urlText: String) -> Bool {
    guard let pageURL = URL(string: urlText), pageURL.scheme == "https", var host = pageURL.host()?.lowercased() else {
        return false
    }
    // "localhost." with its trailing dot is the same host as "localhost".
    while host.hasSuffix(".") { host.removeLast() }
    if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal") {
        return false
    }
    // A bare IP address is either local or not a video site the learner browses to, so none is read.
    let hostIsAnIPAddress = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
    return !hostIsAnIPAddress
}

/// A change to the video the learner asked for by voice. The JavaScript only ever embeds numbers
/// Swift formats, and uses single quotes, because it runs inside a double-quoted AppleScript string.
nonisolated enum LearnerVideoCommand: Equatable {
    case readState
    case pause
    case play
    case seekBy(seconds: Double)
    case seekTo(seconds: Double)
    case setPlaybackRate(Double)

    var javaScript: String {
        let change: String
        switch self {
        case .readState:
            change = ""
        case .pause:
            change = "video.pause();"
        case .play:
            change = "video.play();"
        case .seekBy(let seconds):
            change = "video.currentTime = Math.max(0, Math.min(video.duration || 1e9, video.currentTime + \(Self.javaScriptNumber(seconds))));"
        case .seekTo(let seconds):
            change = "video.currentTime = Math.max(0, Math.min(video.duration || 1e9, \(Self.javaScriptNumber(seconds))));"
        case .setPlaybackRate(let playbackRate):
            change = "video.playbackRate = \(Self.javaScriptNumber(min(2, max(0.25, playbackRate))));"
        }
        return "(function () { \(Self.mainVideoJavaScript) if (!video) { return 'no-video'; } \(change) return JSON.stringify({ seconds: Math.round(video.currentTime), durationSeconds: Number.isFinite(video.duration) ? Math.round(video.duration) : 0, paused: video.paused, playing: !video.paused && video.readyState >= 3, playbackRate: video.playbackRate }); })()"
    }

    /// Picks the page's main video: the largest one on screen, so a preview or an ad thumbnail never wins.
    /// A page whose videos all have no size, such as a background tab mid-layout, falls back to the first one.
    /// The requested-scene pause and its play use it too, so they act on the same video as the voice tools.
    static let mainVideoJavaScript = "var videos = Array.prototype.slice.call(document.querySelectorAll('video')); var video = videos[0] || null; var largestArea = 0; videos.forEach(function (candidate) { var rect = candidate.getBoundingClientRect(); var area = rect.width * rect.height; if (area > largestArea) { largestArea = area; video = candidate; } });"

    /// NaN and infinity are not JavaScript literals the page can read, so they become 0.
    private static func javaScriptNumber(_ value: Double) -> String {
        value.isFinite ? String(value) : "0"
    }
}

// MARK: - Transcript and moments

nonisolated struct VideoQuizTranscriptLine: Encodable, Equatable {
    let seconds: Double
    let text: String
}

nonisolated private struct CaptionsJSON3Document: Decodable {
    struct Event: Decodable {
        let tStartMs: Int?
        /// Marks an event that only extends the previous one, so it holds no new text.
        let aAppend: Int?
        let segs: [Segment]?
    }

    struct Segment: Decodable {
        let utf8: String?
    }

    let events: [Event]
}

/// Turns YouTube's json3 captions into one transcript line per caption event,
/// stamped with the second the line starts at, to one decimal place.
nonisolated func videoQuizTranscriptLines(fromCaptionsJSON3Data captionsJSON3Data: Data) throws -> [VideoQuizTranscriptLine] {
    let captionsDocument = try JSONDecoder().decode(CaptionsJSON3Document.self, from: captionsJSON3Data)
    var transcriptLines: [VideoQuizTranscriptLine] = []
    for captionEvent in captionsDocument.events {
        guard captionEvent.aAppend == nil,
              let startMilliseconds = captionEvent.tStartMs,
              let captionSegments = captionEvent.segs else {
            continue
        }
        let captionText = captionSegments
            .map { captionSegment in captionSegment.utf8 ?? "" }
            .joined()
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !captionText.isEmpty else { continue }
        let startSecondsRoundedToOneDecimal = (Double(startMilliseconds) / 100).rounded() / 10
        transcriptLines.append(VideoQuizTranscriptLine(seconds: startSecondsRoundedToOneDecimal, text: captionText))
    }
    return transcriptLines
}

struct VideoQuizMoment {
    let pauseAtSeconds: Double
    /// What the moment is about, in the planner's words. The frame parts call looks for it in the frame.
    let subject: String
    let quiz: LiveSceneQuiz
}

/// The Worker sends each moment as one flat object, so the quiz decodes from the same keys.
/// The init lives in an extension so the memberwise init stays available.
extension VideoQuizMoment: Decodable {
    private enum CodingKeys: String, CodingKey {
        case pauseAtSeconds
        case subject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pauseAtSeconds = try container.decode(Double.self, forKey: .pauseAtSeconds)
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        quiz = try LiveSceneQuiz(from: decoder)
    }
}

/// A moment stays askable for this long after its pause time, so a learner who
/// seeks a little past it still gets the question. Further behind counts as skipped.
nonisolated let videoQuizSecondsAMomentStaysAskableAfterItsPause: Double = 5

/// The first moment not yet asked whose pause time the video has reached, or nil.
/// Asked moments are never asked again, so seeking backward cannot repeat a question.
nonisolated func videoQuizMomentIndexToAsk(
    currentSeconds: Double,
    pauseAtSecondsPerMoment: [Double],
    askedMomentIndices: Set<Int>
) -> Int? {
    pauseAtSecondsPerMoment.indices.first { momentIndex in
        let pauseAtSeconds = pauseAtSecondsPerMoment[momentIndex]
        return !askedMomentIndices.contains(momentIndex)
            && currentSeconds >= pauseAtSeconds
            && currentSeconds - pauseAtSeconds <= videoQuizSecondsAMomentStaysAskableAfterItsPause
    }
}

// MARK: - Failures

enum VideoQuizFailure: Error {
    case chromeIsNotRunning
    case noYouTubeTabFound
    case noVideoOnThePage
    case chromeHasNoWindow
    case noImageOrVideoToPopOut
    case javaScriptFromAppleEventsIsOff
    case notAllowedToControlChrome
    case chromeScriptFailed(String)
    case captionsToolFailed(String)
    case noCaptions
    case noCaptionsToSearch
    case captionSearchNeedsYouTube
    case planFailed(String)
    case lostTheYouTubeTab
    case theVideoChangedWhileReadingItsCaptions

    /// What Clicky says out loud, in plain words.
    var spokenLine: String {
        switch self {
        case .chromeIsNotRunning:
            return "Chrome isn't open, so I can't find a video."
        case .noYouTubeTabFound:
            return "I couldn't find a YouTube video open in Chrome."
        case .noVideoOnThePage:
            return "I couldn't find a video player on that page."
        case .chromeHasNoWindow:
            return "Chrome has no window open, so I can't find a video."
        case .noImageOrVideoToPopOut:
            return "I couldn't find an image or a video in Chrome to pop out."
        case .javaScriptFromAppleEventsIsOff:
            return "JavaScript from Apple Events is turned off in Chrome. Turn it on under View, Developer, then ask me again."
        case .notAllowedToControlChrome:
            return "I'm not allowed to control Chrome yet. Allow it in System Settings under Privacy and Security, Automation, then ask me again."
        case .chromeScriptFailed:
            return "Chrome wouldn't let me read the video."
        case .captionsToolFailed:
            return "I couldn't download the captions for this video."
        case .noCaptions:
            return "This video has no captions, so I can't plan a quiz."
        case .noCaptionsToSearch:
            return "This video has no captions I can search."
        case .captionSearchNeedsYouTube:
            return "I can only search the captions of YouTube videos for now."
        case .planFailed:
            return "I couldn't pick quiz spots for this video."
        case .lostTheYouTubeTab:
            return "I lost the YouTube tab, so I stopped the quiz."
        case .theVideoChangedWhileReadingItsCaptions:
            return "The video in front changed while I was reading its captions, so I didn't move it."
        }
    }
}

/// A requested pop-out speaks these lines when it fails.
extension VideoQuizFailure: LocalizedError {
    var errorDescription: String? { spokenLine }
}

// MARK: - Who paused the video

/// Why Clicky holds a video paused. Clicky presses play again only for a pause it holds,
/// so a video the learner paused is never held and never played.
nonisolated enum ClickyVideoPauseReason: Equatable {
    case quizQuestion
    case requestedScene
}

/// A question may be asked only while its own pause is still held. A requested scene that took the pause
/// over, or a video that has already played on, means the question would run under the scene or the video.
nonisolated func quizQuestionMayStillBeAsked(heldPauseReason: ClickyVideoPauseReason?) -> Bool {
    heldPauseReason == .quizQuestion
}

/// Whether Clicky holds the video's pause once a pop-out or 3D model was requested over it.
/// It holds the pause when it pauses a playing video itself, or already held this video's pause
/// for a quiz question. A video the learner paused stays theirs, so it is not held and not resumed.
nonisolated func clickyHoldsTheVideoPauseAfterASceneRequest(videoIsPlaying: Bool, clickyAlreadyHoldsThePause: Bool) -> Bool {
    videoIsPlaying || clickyAlreadyHoldsThePause
}

// MARK: - Summary

/// "2:14" for a time in a video, or "1:02:05" past an hour, as YouTube writes it.
nonisolated func videoTimestampText(seconds: Double) -> String {
    let wholeSeconds = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
    let hours = wholeSeconds / 3600
    let minutes = (wholeSeconds % 3600) / 60
    let secondsPart = wholeSeconds % 60
    if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secondsPart) }
    return String(format: "%d:%02d", minutes, secondsPart)
}

/// A question of a finished quiz that the learner missed or skipped, which the summary lists so they can go back to it.
nonisolated struct VideoQuizMissedQuestion: Equatable, Sendable, Identifiable {
    let question: String
    /// The video time the quiz paused at, which a click seeks back to.
    let askedAtSeconds: Double
    var id: Double { askedAtSeconds }
    var timestampText: String { videoTimestampText(seconds: askedAtSeconds) }
}

/// What the Card at the end of a quiz shows: the score and each question to go back to, in video order.
/// A skip counts as a miss, as it does for the study guide's "Review these first".
nonisolated struct VideoQuizSummary: Equatable, Sendable {
    let rightCount: Int
    let questionCount: Int
    let missedQuestions: [VideoQuizMissedQuestion]

    /// Nil when the learner finished no question, since a quiz stopped before its first answer has nothing to sum up.
    init?(quizResults: [StudyGuideQuizResult]) {
        guard !quizResults.isEmpty else { return nil }
        questionCount = quizResults.count
        rightCount = quizResults.filter { $0.result == .gotIt }.count
        missedQuestions = quizResults
            .filter { $0.result != .gotIt }
            .sorted { $0.askedAtSeconds < $1.askedAtSeconds }
            .map { VideoQuizMissedQuestion(question: $0.question, askedAtSeconds: $0.askedAtSeconds) }
    }

    var scoreText: String { "\(rightCount) of \(questionCount) right" }

    var captionText: String {
        switch missedQuestions.count {
        case 0: return questionCount == 1 ? "You got it right." : "You got every one right."
        case 1: return "One to look at again. Click it to jump back to it."
        default: return "\(missedQuestions.count) to look at again. Click one to jump back to it."
        }
    }
}

/// How a running quiz is going, which the menu bar panel's state line shows: "Quiz · 3 of 4 right".
nonisolated struct VideoQuizProgress: Equatable, Sendable {
    let rightCount: Int
    let answeredCount: Int

    /// "Quiz · watching" before the first answer, since "0 of 0 right" says nothing.
    var stateLineText: String {
        answeredCount == 0 ? "Quiz · watching" : "Quiz · \(rightCount) of \(answeredCount) right"
    }

    init(quizResults: [StudyGuideQuizResult]) {
        answeredCount = quizResults.count
        rightCount = quizResults.filter { $0.result == .gotIt }.count
    }
}

// MARK: - Session

@MainActor
final class VideoQuizSession {
    private static let secondsBetweenPlaybackReads: TimeInterval = 0.5
    private static let secondsBetweenBusyChecks: TimeInterval = 0.2
    /// A stuck conversation must not leave the video paused forever.
    private static let secondsToWaitForClickyToBeFreeBeforeResuming: TimeInterval = 60
    private static let failedPlaybackReadsBeforeGivingUp = 6
    private static let secondsForTheReadyLineToFinish: Double = 3.5
    /// The frame parts call takes about 4 seconds, so the frame is grabbed this early
    /// and the 3D scene is ready when the video pauses.
    private static let secondsBeforeThePauseToGrabTheFrame: Double = 6
    private static let secondsToWaitForThePopoutAtThePause: TimeInterval = 8

    private let workerBaseURL: String
    private let canAskQuestionNow: @MainActor () -> Bool
    private let askQuestion: @MainActor (LiveSceneQuiz, VideoFramePopout?) -> Void
    /// Says a line after whatever Clicky is saying. The second value is true for a line that reports a failure, so the cursor shakes.
    private let speakLine: @MainActor (String, Bool) -> Void

    private(set) var isRunning = false
    private var runningTask: Task<Void, Never>?

    private var currentVideoTab: ChromeVideoTab?
    private var moments: [VideoQuizMoment] = []
    private var askedMomentIndices: Set<Int> = []
    /// The one record of a video Clicky paused, with the tab it paused. Nil means Clicky holds no pause,
    /// including when the learner paused the video. The tab is kept because the learner can switch tabs before the resume.
    private struct VideoPausedByClicky {
        let reason: ClickyVideoPauseReason
        let tab: ChromeVideoTab
    }
    private var videoPausedByClicky: VideoPausedByClicky?
    var videoIsPausedForRequestedScene: Bool {
        videoPausedByClicky?.reason == .requestedScene
    }
    private var allTranscriptLines: [VideoQuizTranscriptLine] = []
    /// The questions the learner finished, per video, for the study guide. Kept after the quiz stops.
    private var studyGuideQuizLog = StudyGuideQuizLog()
    private var consecutiveFailedPlaybackReadCount = 0
    private var framePopoutTasksByMomentIndex: [Int: Task<VideoFramePopout?, Never>] = [:]
    /// The questions the learner finished in this quiz, for the summary. The study guide's log keeps every quiz of a video.
    private var quizResultsOfThisQuiz: [StudyGuideQuizResult] = []
    /// The pop-out each question showed, by the video time it paused at, so the summary can show it again.
    /// Kept after the quiz ends, until the next quiz starts.
    private var questionPopoutsByAskedSeconds: [Double: VideoFramePopout] = [:]
    /// Called once when a quiz ends with at least one question finished, whether every moment was asked or the learner stopped it.
    var onQuizEnded: ((VideoQuizSummary) -> Void)?
    /// Called when a quiz starts, after each finished question, and with nil when it stops.
    var onProgressChanged: ((VideoQuizProgress?) -> Void)?

    /// The address of the video the last quiz ran on and the questions it finished, kept until the next quiz starts. Nil before
    /// any question was finished. The end-of-video recap sums up this quiz, since only its pop-outs can be shown again.
    var lastQuizVideoURLAndResults: (videoURL: String, results: [StudyGuideQuizResult])? {
        guard let currentVideoTab, !quizResultsOfThisQuiz.isEmpty else { return nil }
        return (currentVideoTab.url, quizResultsOfThisQuiz)
    }

    init(
        workerBaseURL: String,
        canAskQuestionNow: @escaping @MainActor () -> Bool,
        askQuestion: @escaping @MainActor (LiveSceneQuiz, VideoFramePopout?) -> Void,
        speakLine: @escaping @MainActor (String, Bool) -> Void
    ) {
        self.workerBaseURL = workerBaseURL
        self.canAskQuestionNow = canAskQuestionNow
        self.askQuestion = askQuestion
        self.speakLine = speakLine
    }

    // MARK: Start and stop

    func start() {
        guard !isRunning else { return }
        isRunning = true
        moments = []
        askedMomentIndices = []
        consecutiveFailedPlaybackReadCount = 0
        framePopoutTasksByMomentIndex = [:]
        quizResultsOfThisQuiz = []
        questionPopoutsByAskedSeconds = [:]
        onProgressChanged?(VideoQuizProgress(quizResults: []))
        runningTask = Task {
            await self.planAndRunQuiz()
        }
    }

    /// Leaves a question's pause held. The caller plays it with resumeVideoAfterQuestion once the
    /// question's pop-out has landed back in its frame.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        runningTask?.cancel()
        runningTask = nil
        for framePopoutTask in framePopoutTasksByMomentIndex.values {
            framePopoutTask.cancel()
        }
        framePopoutTasksByMomentIndex = [:]
        studyGuideQuizLog.discardTheOpenQuestion()
        // A failure or a stop during planning would otherwise leave the planning label up.
        LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.videoQuizPlanningLines)
        print("Video quiz: stopped")
        onProgressChanged?(nil)
        if let summary = VideoQuizSummary(quizResults: quizResultsOfThisQuiz) {
            print("Video quiz: \(summary.scoreText), \(summary.missedQuestions.count) to look at again")
            onQuizEnded?(summary)
        }
    }

    /// Pauses the main video in Chrome's front tab, on any public https site, for a 3D model or pop-out the learner asked
    /// for, with or without a quiz, so the video's narrator does not talk over Clicky and the scene rises out of a
    /// still frame. Returns what the quiz video just said, so "show me that" can be built from it, or "" when no quiz
    /// watches this video. A running quiz only pauses its own video, and Clicky holds one pause at a time.
    func pauseVideoForRequestedScene() -> String {
        guard let frontVideoTab = try? ChromeVideoTab.frontTabOfTheFrontWindow(),
              captionSearchMayReadTheVideoPage(urlText: frontVideoTab.url) else { return "" }
        let quizWatchesTheFrontVideo = isRunning && currentVideoTab?.isTheSameTab(as: frontVideoTab) == true
        if isRunning && !quizWatchesTheFrontVideo { return "" }
        if let heldVideoTab = videoPausedByClicky?.tab, !heldVideoTab.isTheSameTab(as: frontVideoTab) { return "" }
        do {
            let playbackState = try readPlaybackState(of: frontVideoTab)
            if !playbackState.isPaused {
                try ChromeVideoTab.runJavaScript(Self.pauseVideoJavaScript, in: frontVideoTab)
            }
            if clickyHoldsTheVideoPauseAfterASceneRequest(
                videoIsPlaying: !playbackState.isPaused,
                clickyAlreadyHoldsThePause: videoPausedByClicky != nil
            ) {
                videoPausedByClicky = VideoPausedByClicky(reason: .requestedScene, tab: frontVideoTab)
            }
            print("Video quiz: paused for a requested 3D model, held by Clicky \(videoIsPausedForRequestedScene)")
            guard quizWatchesTheFrontVideo else { return "" }
            return quizCaptionText(heardBefore: playbackState.currentSeconds)
        } catch VideoQuizFailure.noVideoOnThePage {
            // A pop-out of a picture on a page with no video has nothing to pause.
            return ""
        } catch {
            print("Video quiz: could not pause for a 3D model: \(error)")
            return ""
        }
    }

    /// What the quiz video in front said before its playhead, for a 3D model built in the background while it plays.
    /// Empty when the quiz does not watch the front video, since only the quiz holds captions.
    func whatTheQuizVideoInFrontJustSaid() -> String {
        guard isRunning,
              let frontVideoTab = try? ChromeVideoTab.findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: true),
              currentVideoTab?.isTheSameTab(as: frontVideoTab) == true,
              let playbackState = try? readPlaybackState(of: frontVideoTab) else {
            return ""
        }
        return quizCaptionText(heardBefore: playbackState.currentSeconds)
    }

    private func quizCaptionText(heardBefore playheadSeconds: Double) -> String {
        allTranscriptLines
            .filter { $0.seconds < playheadSeconds }
            .suffix(12)
            .map(\.text)
            .joined(separator: " ")
    }

    /// Presses play once the scene is gone, but only for a pause Clicky made for it.
    func resumeVideoAfterRequestedScene() {
        guard videoIsPausedForRequestedScene else { return }
        playTheVideoClickyPaused()
        endTheQuizWhenEveryMomentWasAsked()
    }

    /// True when the quiz's YouTube tab is the active tab of Chrome's front window. A scene asked for
    /// over any other page is not about this video, so it must not pause or resume it.
    func quizVideoIsTheTabInFront() -> Bool {
        guard let currentVideoTab,
              let frontVideoTab = try? ChromeVideoTab.findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: true) else {
            return false
        }
        return frontVideoTab.isTheSameTab(as: currentVideoTab)
    }

    /// Called once the explanation has been spoken. Presses play again, and ends
    /// the session after the last moment.
    func resumeVideoAfterQuestion() {
        guard videoPausedByClicky?.reason == .quizQuestion else { return }
        playTheVideoClickyPaused()
        endTheQuizWhenEveryMomentWasAsked()
    }

    private func playTheVideoClickyPaused() {
        guard let pausedVideoTab = videoPausedByClicky?.tab else { return }
        videoPausedByClicky = nil
        do {
            try ChromeVideoTab.runJavaScript(Self.playVideoJavaScript, in: pausedVideoTab)
            print("Video quiz: resumed the video")
        } catch {
            print("Video quiz: could not resume the video: \(error)")
        }
    }

    /// No moments yet means the quiz is still planning, which is not the end.
    private func endTheQuizWhenEveryMomentWasAsked() {
        guard isRunning, !moments.isEmpty, askedMomentIndices.count == moments.count else { return }
        print("Video quiz: all \(moments.count) moments asked")
        stop()
    }

    // MARK: Planning

    private func planAndRunQuiz() async {
        do {
            let videoTab = try ChromeVideoTab.findYouTubeWatchTab()
            currentVideoTab = videoTab
            print("Video quiz: found tab \"\(videoTab.title)\" at \(videoTab.url)")

            // Reading the clock now also finds out early if Chrome blocks JavaScript.
            let playbackState = try readPlaybackState(of: videoTab)
            print("Video quiz: video clock reads \(playbackState.currentSeconds)s, paused \(playbackState.isPaused)")

            let planningStartDate = Date()
            // Reading and planning take 10 to 15 seconds, so the label says what Clicky is doing meanwhile.
            LiveSceneStatusLabel.shared.show(.readingTheTranscript)
            let transcriptLines = try await VideoCaptionsDownloader.downloadTranscriptLines(forVideoURL: videoTab.url)
            guard isRunning, !Task.isCancelled else { return }
            print("Video quiz: read \(transcriptLines.count) caption lines")
            allTranscriptLines = transcriptLines

            // A press that hid the reading label must not bring the planning label back.
            LiveSceneStatusLabel.shared.replace(.readingTheTranscript, with: .pickingQuizSpots)
            let plannedMoments = try await VideoQuizPlanClient(workerBaseURL: workerBaseURL).requestPlan(
                title: videoTab.title,
                transcriptLines: transcriptLines.filter { transcriptLine in
                    transcriptLine.seconds >= playbackState.currentSeconds
                }
            )
            guard isRunning, !Task.isCancelled else { return }
            LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.videoQuizPlanningLines)
            moments = plannedMoments.map { plannedMoment in
                var quizWithWhatWasHeard = plannedMoment.quiz
                quizWithWhatWasHeard.heardTranscript = transcriptLines
                    .filter { $0.seconds < plannedMoment.pauseAtSeconds }
                    .suffix(40)
                    .map(\.text)
                    .joined(separator: " ")
                return VideoQuizMoment(
                    pauseAtSeconds: plannedMoment.pauseAtSeconds,
                    subject: plannedMoment.subject,
                    quiz: quizWithWhatWasHeard
                )
            }
            let planningSeconds = Date().timeIntervalSince(planningStartDate)
            for (momentIndex, moment) in plannedMoments.enumerated() {
                print("Video quiz: moment \(momentIndex + 1) at \(moment.pauseAtSeconds)s, answer \"\(moment.quiz.answerLabel)\": \(moment.quiz.question)")
            }
            print("Video quiz: planned \(plannedMoments.count) moments in \(String(format: "%.1f", planningSeconds))s")

            let spotCountText = plannedMoments.count == 1 ? "1 spot" : "\(plannedMoments.count) spots"
            speakLine("Okay, I've got \(spotCountText) picked out.", false)
            // The line takes about this long, and the video should start after it.
            try await Task.sleep(for: .seconds(Self.secondsForTheReadyLineToFinish))
            guard isRunning else { return }
            try ChromeVideoTab.runJavaScript(Self.playVideoJavaScript, in: videoTab)
            print("Video quiz: started the video")
            await pollPlaybackUntilTheQuizEnds(videoTab: videoTab)
        } catch is CancellationError {
            return
        } catch let failure as VideoQuizFailure {
            fail(with: failure)
        } catch {
            fail(with: .planFailed(String(describing: error)))
        }
    }

    private func fail(with failure: VideoQuizFailure) {
        guard isRunning, !Task.isCancelled else { return }
        print("Video quiz: failed: \(failure)")
        speakLine(failure.spokenLine, true)
        stop()
    }

    // MARK: Watching the video's clock

    private func pollPlaybackUntilTheQuizEnds(videoTab: ChromeVideoTab) async {
        while isRunning, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.secondsBetweenPlaybackReads))
            guard isRunning, !Task.isCancelled, videoPausedByClicky == nil else { continue }

            let playbackState: VideoPlaybackState
            do {
                playbackState = try readPlaybackState(of: videoTab)
                consecutiveFailedPlaybackReadCount = 0
            } catch {
                consecutiveFailedPlaybackReadCount += 1
                print("Video quiz: could not read the video clock (\(consecutiveFailedPlaybackReadCount)): \(error)")
                if consecutiveFailedPlaybackReadCount >= Self.failedPlaybackReadsBeforeGivingUp {
                    fail(with: .lostTheYouTubeTab)
                }
                continue
            }

            startFramePopoutIfItIsTime(currentSeconds: playbackState.currentSeconds, videoTab: videoTab)

            guard let momentIndexToAsk = videoQuizMomentIndexToAsk(
                currentSeconds: playbackState.currentSeconds,
                pauseAtSecondsPerMoment: moments.map { moment in moment.pauseAtSeconds },
                askedMomentIndices: askedMomentIndices
            ) else {
                continue
            }
            await pauseVideoAndAskQuestion(
                momentIndex: momentIndexToAsk,
                videoSecondsWhenReached: playbackState.currentSeconds,
                videoTab: videoTab
            )
        }
    }

    private func pauseVideoAndAskQuestion(
        momentIndex: Int,
        videoSecondsWhenReached: Double,
        videoTab: ChromeVideoTab
    ) async {
        do {
            try ChromeVideoTab.runJavaScript(Self.pauseVideoJavaScript, in: videoTab)
        } catch {
            // The next read tries again, because the moment is not marked asked yet.
            print("Video quiz: could not pause the video: \(error)")
            return
        }
        askedMomentIndices.insert(momentIndex)
        videoPausedByClicky = VideoPausedByClicky(reason: .quizQuestion, tab: videoTab)
        let moment = moments[momentIndex]
        print("Video quiz: paused at \(videoSecondsWhenReached)s for moment \(momentIndex + 1), planned for \(moment.pauseAtSeconds)s")
        let framePopout = await framePopoutForThePausedFrame(momentIndex: momentIndex, videoTab: videoTab)
        guard isRunning, !Task.isCancelled else { return }

        var secondsWaitedForClickyToBeFree: TimeInterval = 0
        while !canAskQuestionNow() {
            guard isRunning, !Task.isCancelled else { return }
            if secondsWaitedForClickyToBeFree >= Self.secondsToWaitForClickyToBeFreeBeforeResuming {
                print("Video quiz: Clicky stayed busy, skipping the question for moment \(momentIndex + 1)")
                resumeVideoAfterQuestion()
                return
            }
            try? await Task.sleep(for: .seconds(Self.secondsBetweenBusyChecks))
            secondsWaitedForClickyToBeFree += Self.secondsBetweenBusyChecks
        }
        guard isRunning, !Task.isCancelled else { return }
        guard quizQuestionMayStillBeAsked(heldPauseReason: videoPausedByClicky?.reason) else {
            print("Video quiz: skipping the question for moment \(momentIndex + 1), its pause is no longer held")
            return
        }
        studyGuideQuizLog.questionIsAsked(
            videoURL: videoTab.url,
            question: moment.quiz.question,
            answerLabel: moment.quiz.answerLabel,
            explanation: moment.quiz.explanation,
            askedAtSeconds: moment.pauseAtSeconds
        )
        if let framePopout {
            questionPopoutsByAskedSeconds[moment.pauseAtSeconds] = framePopout
        }
        askQuestion(moment.quiz, framePopout)
    }

    /// Counts the open video quiz question as answered or skipped for the study guide. Only the first outcome
    /// of a question counts, so a follow-up grade on the same question adds nothing, and this returns false for it.
    @discardableResult
    func recordTheOpenQuestionOutcome(_ outcome: StudyGuideQuizOutcome) -> Bool {
        guard studyGuideQuizLog.closeTheOpenQuestion(with: outcome) else { return false }
        if let currentVideoTab, let recordedResult = studyGuideQuizLog.results(forVideoURL: currentVideoTab.url).last {
            quizResultsOfThisQuiz.append(recordedResult)
            onProgressChanged?(VideoQuizProgress(quizResults: quizResultsOfThisQuiz))
        }
        return true
    }

    /// What going back to a missed question did.
    enum GoingBackToAMissedQuestion {
        /// The video waits paused at the question, and this is its pop-out with every label named.
        case showsItsPopout(VideoFramePopout)
        /// The question was asked by voice alone, so the video plays again from 10 seconds before it.
        case playsFromBeforeIt
        /// The quiz tab is gone or shows another video now, or Chrome refused a script, so the go-back stopped there.
        case couldNotGoBack
    }

    /// For a question the summary lists: brings the quiz video's tab forward, moves the video to where the question paused,
    /// and holds it paused for the pop-out. Clearing the pop-out resumes the video, as for a pop-out the learner asked for.
    func goBackToTheMissedQuestion(_ missedQuestion: VideoQuizMissedQuestion) -> GoingBackToAMissedQuestion {
        guard let quizVideoTab = currentVideoTab else { return .couldNotGoBack }
        // The go-back takes over Clicky's one pause, whether or not it finds the quiz video. A video it held paused on another
        // tab stays paused, since pressing play on it could play two videos at once, and Clicky forgets that pause, as it does
        // a learner's.
        if let heldVideoTab = videoPausedByClicky?.tab, !heldVideoTab.isTheSameTab(as: quizVideoTab) {
            videoPausedByClicky = nil
            print("Video quiz: let go of the pause it held on another tab, which stays paused")
        }
        // The learner may have closed the tab or moved it to another video since the quiz ended, and seeking that one
        // to the old time would lift the old frame over a different video.
        guard (try? ChromeVideoTab.bringTabForward(tabID: quizVideoTab.tabId)) == true,
              let frontVideoTab = try? ChromeVideoTab.frontTabOfTheFrontWindow(),
              frontVideoTab.isTheSamePage(as: quizVideoTab) else {
            print("Video quiz: the quiz video is no longer in its tab, so it cannot go back to \(missedQuestion.timestampText)")
            return .couldNotGoBack
        }
        guard var framePopout = questionPopoutsByAskedSeconds[missedQuestion.askedAtSeconds] else {
            do {
                try ChromeVideoTab.runJavaScript(LearnerVideoCommand.seekTo(seconds: max(0, missedQuestion.askedAtSeconds - 10)).javaScript, in: quizVideoTab)
                try ChromeVideoTab.runJavaScript(Self.playVideoJavaScript, in: quizVideoTab)
            } catch {
                print("Video quiz: could not go back to \(missedQuestion.timestampText): \(error)")
                return .couldNotGoBack
            }
            // The quiz video plays again, so a pause Clicky held on it is over.
            videoPausedByClicky = nil
            print("Video quiz: went back to \(missedQuestion.timestampText), a question with no pop-out")
            return .playsFromBeforeIt
        }
        do {
            try ChromeVideoTab.runJavaScript(LearnerVideoCommand.seekTo(seconds: missedQuestion.askedAtSeconds).javaScript, in: quizVideoTab)
            try ChromeVideoTab.runJavaScript(Self.pauseVideoJavaScript, in: quizVideoTab)
        } catch {
            print("Video quiz: could not go back to \(missedQuestion.timestampText): \(error)")
            return .couldNotGoBack
        }
        videoPausedByClicky = VideoPausedByClicky(reason: .requestedScene, tab: quizVideoTab)
        // The question is over, so no label waits to be named, and the video's printed labels may show the answer again.
        framePopout.parts = framePopout.parts.map { part in
            VideoFramePopout.Part(label: part.label, x: part.x, y: part.y, isQuizAnswer: false)
        }
        framePopout.textBoxesToHide = []
        print("Video quiz: went back to \(missedQuestion.timestampText) and shows its pop-out again")
        return .showsItsPopout(framePopout)
    }

    // MARK: Lifting the subject out of the frame

    /// The famous place in the frame the YouTube tab shows right now, if there is one.
    /// Nil when no YouTube tab is open or the frame shows no famous place.
    static func famousPlaceInTheVisibleFrame(workerBaseURL: String, learnerRequest: String) async throws -> (frameGrab: VideoFrameGrab, famousPlace: FamousPlace)? {
        // A YouTube tab behind the page the learner is looking at is not what they asked about.
        guard let videoTab = try? ChromeVideoTab.findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: true) else { return nil }
        let frameGrab = try grabFrame(of: videoTab)
        guard let famousPlace = try await LandmarkClient.famousPlace(
            workerBaseURL: workerBaseURL,
            frameGrab: frameGrab,
            videoTitle: videoTab.title,
            learnerRequest: learnerRequest
        ) else {
            return nil
        }
        return (frameGrab, famousPlace)
    }

    /// Where the largest visible video or image in Chrome's front tab sits on screen, for a scene to rise from.
    static func screenRectOfTheMediaToRiseFrom() -> ScreenRectInChromeCoordinates? {
        ChromeVideoTab.screenRectOfTheLargestVisibleMediaInFrontTab()
    }

    /// The frame the YouTube tab shows right now, or the largest image on any other page,
    /// for a pop-out the learner asked for. Nil when Sonnet or Vision finds no single subject in it.
    static func framePopoutOfTheVisibleFrame(workerBaseURL: String) async throws -> VideoFramePopout? {
        let frameGrab: VideoFrameGrab
        // An animated page image downloads while Sonnet reads the frame, and the pop-out waits for it only briefly after that.
        var pageImageAnimationTask: Task<[PageImageAnimationFrame]?, Never>?
        do {
            // Only the video in front is the one the learner pointed at.
            let videoTab = try ChromeVideoTab.findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: true)
            frameGrab = try grabFrame(of: videoTab)
            print("Video quiz: grabbed a \(frameGrab.width)x\(frameGrab.height) frame at \(frameGrab.videoSeconds ?? 0)s for a requested pop-out")
        } catch VideoQuizFailure.noYouTubeTabFound {
            // A cross-origin image cannot be read from a page canvas, so the screen under it is captured instead.
            do {
                guard let media = try ChromeVideoTab.largestVisibleMediaInFrontTabOrNone(),
                      let screenGrab = try await CompanionScreenCaptureUtility.captureScreenRectAsJPEG(media.screenRect) else {
                    throw VideoQuizFailure.noImageOrVideoToPopOut
                }
                frameGrab = screenGrab
                // A capture cut off at a display edge no longer matches the image's own frames.
                // With Reduce Motion the page keeps the still frame, so nothing is downloaded.
                if let imageSourceURL = media.imageSourceURL, screenGrab.screenRect == media.screenRect,
                   !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    pageImageAnimationTask = Task {
                        await PageImageAnimation.frames(
                            atImageURL: imageSourceURL,
                            frameWidth: screenGrab.width,
                            frameHeight: screenGrab.height,
                            capturedFrameJPEGBase64: screenGrab.jpeg
                        )
                    }
                }
            } catch {
                print("Video quiz: could not capture an image for a requested pop-out: \(error)")
                switch error {
                case VideoQuizFailure.javaScriptFromAppleEventsIsOff, VideoQuizFailure.notAllowedToControlChrome:
                    // The learner can fix these, so they hear them.
                    throw error
                default:
                    // A chrome:// page refuses the script and a failed screen capture throws its own error.
                    // Neither is "Chrome wouldn't let me read the video", so the learner hears that no image was found.
                    throw VideoQuizFailure.noImageOrVideoToPopOut
                }
            }
            print("Video quiz: captured a \(frameGrab.width)x\(frameGrab.height) image from the screen for a requested pop-out")
        }
        // No question is being asked, so no label gets the quiz mark.
        let foundFramePopout: VideoFramePopout?
        do {
            foundFramePopout = try await VideoFramePopoutClient.requestPopout(
                workerBaseURL: workerBaseURL,
                frameGrab: frameGrab,
                subject: "",
                question: "",
                answerLabel: ""
            )
        } catch {
            pageImageAnimationTask?.cancel()
            throw error
        }
        guard var framePopout = foundFramePopout else {
            pageImageAnimationTask?.cancel()
            return nil
        }
        if let pageImageAnimationTask,
           let animationFrames = await animationFramesReadyInTime(from: pageImageAnimationTask) {
            framePopout.playAnimationFrames(animationFrames)
            print("Frame pop-out: playing the page image's \(animationFrames.count) animation frames, with no labels")
        }
        return framePopout
    }

    /// A slow image host must not hold the pop-out, so the frames get this long after Sonnet answers, and then the still frame plays.
    private static let secondsToWaitForAnimationFramesAfterThePopout: Double = 1.5

    private static func animationFramesReadyInTime(
        from pageImageAnimationTask: Task<[PageImageAnimationFrame]?, Never>
    ) async -> [PageImageAnimationFrame]? {
        let deadlineTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(secondsToWaitForAnimationFramesAfterThePopout * 1_000_000_000))
            pageImageAnimationTask.cancel()
        }
        defer { deadlineTask.cancel() }
        return await pageImageAnimationTask.value
    }

    /// Grabs the frame while the video plays, a few seconds before the next pause.
    private func startFramePopoutIfItIsTime(currentSeconds: Double, videoTab: ChromeVideoTab) {
        guard let momentIndex = moments.indices.first(where: { momentIndex in
            !askedMomentIndices.contains(momentIndex)
                && framePopoutTasksByMomentIndex[momentIndex] == nil
                && currentSeconds >= moments[momentIndex].pauseAtSeconds - Self.secondsBeforeThePauseToGrabTheFrame
                && currentSeconds < moments[momentIndex].pauseAtSeconds
        }) else {
            return
        }
        framePopoutTasksByMomentIndex[momentIndex] = startFramePopoutTask(momentIndex: momentIndex, videoTab: videoTab)
    }

    private func startFramePopoutTask(momentIndex: Int, videoTab: ChromeVideoTab) -> Task<VideoFramePopout?, Never>? {
        let moment = moments[momentIndex]
        let frameGrab: VideoFrameGrab
        do {
            frameGrab = try Self.grabFrame(of: videoTab)
        } catch {
            print("Video quiz: could not grab a frame for moment \(momentIndex + 1): \(error)")
            return nil
        }
        print("Video quiz: grabbed a \(frameGrab.width)x\(frameGrab.height) frame at \(frameGrab.videoSeconds ?? 0)s for moment \(momentIndex + 1)")
        let workerBaseURL = workerBaseURL
        return Task {
            let requestStartDate = Date()
            do {
                let framePopout = try await VideoFramePopoutClient.requestPopout(
                    workerBaseURL: workerBaseURL,
                    frameGrab: frameGrab,
                    subject: moment.subject,
                    question: moment.quiz.question,
                    answerLabel: moment.quiz.answerLabel
                )
                let requestSeconds = String(format: "%.1f", Date().timeIntervalSince(requestStartDate))
                if let framePopout {
                    print("Video quiz: found the subject and \(framePopout.parts.count) parts for moment \(momentIndex + 1) in \(requestSeconds)s")
                } else {
                    print("Video quiz: no subject to lift out for moment \(momentIndex + 1) (\(requestSeconds)s)")
                }
                return framePopout
            } catch {
                print("Video quiz: frame parts failed for moment \(momentIndex + 1): \(error.localizedDescription)")
                return nil
            }
        }
    }

    /// Uses the early grab when it found a subject. The pop-out covers the video with
    /// its own frame, so a frame from a few seconds earlier still lines up. The paused
    /// frame is grabbed only when the early grab found nothing or never ran.
    private func framePopoutForThePausedFrame(momentIndex: Int, videoTab: ChromeVideoTab) async -> VideoFramePopout? {
        if let earlyFramePopoutTask = framePopoutTasksByMomentIndex[momentIndex],
           let earlyFramePopout = await waitForFramePopout(earlyFramePopoutTask) {
            return earlyFramePopout
        }
        guard isRunning, !Task.isCancelled else { return nil }
        print("Video quiz: grabbing the paused frame for moment \(momentIndex + 1)")
        guard let pausedFramePopoutTask = startFramePopoutTask(momentIndex: momentIndex, videoTab: videoTab) else { return nil }
        framePopoutTasksByMomentIndex[momentIndex] = pausedFramePopoutTask
        return await waitForFramePopout(pausedFramePopoutTask)
    }

    private func waitForFramePopout(_ framePopoutTask: Task<VideoFramePopout?, Never>) async -> VideoFramePopout? {
        let waitStartDate = Date()
        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(Self.secondsToWaitForThePopoutAtThePause))
            framePopoutTask.cancel()
        }
        let framePopout = await framePopoutTask.value
        timeoutTask.cancel()
        print("Video quiz: waited \(String(format: "%.1f", Date().timeIntervalSince(waitStartDate)))s at the pause for the 3D frame")
        return framePopout
    }

    // MARK: Voice commands for the video in front

    private var captionLinesByVideoURL: [String: [VideoQuizTranscriptLine]] = [:]

    /// The main video in Chrome's front tab, on any site, as the voice command model sees it, or nil when the
    /// page has none. A video inside a frame from another site cannot be reached by a page script, so it counts as none.
    func frontVideoStateForVoiceCommands() -> JSONValue? {
        let frontTab: ChromeVideoTab
        do {
            frontTab = try ChromeVideoTab.frontTabOfTheFrontWindow()
        } catch {
            print("Front video: could not read the front tab: \(error)")
            return nil
        }
        return frontVideoStateForVoiceCommands(in: frontTab)
    }

    /// The same read of a front tab the caller already has, so a release that reads the tab once for several readers does not
    /// read it again here. A read that finds no video says why in the log, since "no video" and "Chrome refused" send the
    /// model different tools and look the same afterwards. `runLearnerVideoCommand` logs a reply with no video state.
    func frontVideoStateForVoiceCommands(in frontTab: ChromeVideoTab) -> JSONValue? {
        do {
            return try Self.runLearnerVideoCommand(.readState, in: frontTab, title: frontTab.title, pageIsOnYouTube: urlIsOnYouTube(urlText: frontTab.url))
        } catch VideoQuizFailure.noVideoOnThePage {
            return nil
        } catch {
            print("Front video: could not read the video state of the front tab (\(URL(string: frontTab.url)?.host() ?? "unknown host")): \(error)")
            return nil
        }
    }

    /// Runs a pause, play, seek, or speed change the learner asked for on the video in front, and returns its state.
    /// A pause or play the learner asks for is theirs, so Clicky drops its own record of a pause on that tab
    /// and will not press play on it later.
    func runLearnerVideoCommand(_ learnerVideoCommand: LearnerVideoCommand) throws -> JSONValue {
        let frontVideoTab = try ChromeVideoTab.frontTabOfTheFrontWindow()
        let videoState = try Self.runLearnerVideoCommand(learnerVideoCommand, in: frontVideoTab, title: frontVideoTab.title, pageIsOnYouTube: urlIsOnYouTube(urlText: frontVideoTab.url))
        switch learnerVideoCommand {
        case .pause, .play:
            if let heldVideoTab = videoPausedByClicky?.tab, heldVideoTab.isTheSameTab(as: frontVideoTab) {
                videoPausedByClicky = nil
                print("Video quiz: the learner took over the pause Clicky held")
            }
        case .seekBy, .seekTo, .setPlaybackRate, .readState:
            break
        }
        return videoState
    }

    /// The caption lines that best match the query in the video in front.
    func captionMomentsInTheFrontVideo(matching query: String) async throws -> [VideoCaptionMoment] {
        let frontVideoTab = try ChromeVideoTab.frontTabOfTheFrontWindow()
        let captionLines = try await captionLines(ofTheVideoIn: frontVideoTab)
        return videoCaptionMomentsMatching(query: query, captionLines: captionLines)
    }

    /// Moves the video in front to the caption line that best matches the query, and returns that line with the video's
    /// state, or nil as the line when no caption line matches. Reading the captions can take seconds, since yt-dlp may
    /// have to download them, so the learner may have switched tabs or videos by then. The seek runs only when the
    /// front tab is still the tab and the page whose captions were read, and fails otherwise instead of moving video B
    /// to video A's time.
    func seekToTheCaptionMoment(matching query: String) async throws -> (captionMoment: VideoCaptionMoment, videoState: JSONValue)? {
        let tabWhoseCaptionsAreRead = try ChromeVideoTab.frontTabOfTheFrontWindow()
        let captionLines = try await captionLines(ofTheVideoIn: tabWhoseCaptionsAreRead)
        guard let bestCaptionMoment = videoCaptionMomentsMatching(query: query, captionLines: captionLines).first else { return nil }
        let tabInFrontNow = try ChromeVideoTab.frontTabOfTheFrontWindow()
        guard tabInFrontNow.isTheSamePage(as: tabWhoseCaptionsAreRead) else {
            throw VideoQuizFailure.theVideoChangedWhileReadingItsCaptions
        }
        // Seek the tab that was checked, since reading the front tab again could find another one switched to meanwhile.
        let videoState = try Self.runLearnerVideoCommand(
            .seekTo(seconds: bestCaptionMoment.seconds),
            in: tabInFrontNow,
            title: tabInFrontNow.title,
            pageIsOnYouTube: urlIsOnYouTube(urlText: tabInFrontNow.url)
        )
        return (bestCaptionMoment, videoState)
    }

    /// The URL of the active tab of Chrome's front window, or nil when Chrome has none to read.
    func frontTabURLOfTheFrontWindow() -> String? {
        try? ChromeVideoTab.frontTabOfTheFrontWindow().url
    }

    /// The page a task agent's "this" refers to. Nil when Chrome has no window.
    func frontTabTitleAndURLOfTheFrontWindow() -> (title: String, url: String)? {
        guard let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow() else { return nil }
        return (title: frontTab.title, url: frontTab.url)
    }

    /// Opens a page in a new Chrome tab behind the one the learner is on, and returns the new tab's id.
    /// Nil when Chrome would not take it, so the caller can say how to open the page by voice instead.
    func openInABackgroundChromeTab(_ pageURL: URL) -> Int? {
        do {
            return try ChromeVideoTab.openInABackgroundTab(pageURL)
        } catch {
            print("Background tab: could not open \(pageURL): \(error)")
            return nil
        }
    }

    /// Loads a page in the tab with this id without switching to it. False when the learner closed the tab, the page is
    /// not https, or Chrome would not take the script, so the caller opens a new tab instead.
    func loadPageInChromeTab(_ pageURL: URL, tabID: Int) -> Bool {
        guard let appleScriptSource = appleScriptToLoadPageInChromeTab(pageURL: pageURL, tabID: tabID) else { return false }
        do {
            return try ChromeVideoTab.runTabScript(appleScriptSource) == "found"
        } catch {
            print("Background tab: could not load \(pageURL) in tab \(tabID): \(error)")
            return false
        }
    }

    /// Switches Chrome to the tab with this id and brings its window to the front.
    /// False when the learner closed the tab or Chrome would not take the script, so the caller opens the page again.
    func bringChromeTabForward(tabID: Int) -> Bool {
        do {
            return try ChromeVideoTab.bringTabForward(tabID: tabID)
        } catch {
            print("Background tab: could not bring tab \(tabID) forward: \(error)")
            return false
        }
    }

    /// The YouTube video in Chrome's front tab with its captions and the quiz results Clicky holds for it, for a study guide.
    /// The URL is read once here, so the guide is filed under the video its captions came from even if the learner switches tabs meanwhile.
    /// Throws the same errors as the caption search, such as a page that is not on YouTube or a video with no captions.
    func frontVideoForStudyGuide() async throws -> StudyGuideVideo {
        let frontVideoTab = try ChromeVideoTab.frontTabOfTheFrontWindow()
        let captionLines = try await captionLines(ofTheVideoIn: frontVideoTab)
        guard !captionLines.isEmpty else { throw VideoQuizFailure.noCaptionsToSearch }
        return StudyGuideVideo(
            title: frontVideoTab.title,
            url: frontVideoTab.url,
            transcriptLines: captionLines,
            quizResults: Array(studyGuideQuizLog.results(forVideoURL: frontVideoTab.url).suffix(mostStudyGuideQuizResults))
        )
    }

    /// The quiz's own captions are reused when it runs on this very video, and another YouTube video's captions are
    /// read once with yt-dlp and kept for the rest of the session.
    /// Any other site throws, since the captions reader keeps only YouTube's format, and the model hears the search failed.
    private func captionLines(ofTheVideoIn frontVideoTab: ChromeVideoTab) async throws -> [VideoQuizTranscriptLine] {
        // The tab's ids stay the same when the learner moves to another video inside it, so the URL must match too.
        if isRunning, currentVideoTab?.isTheSameTab(as: frontVideoTab) == true, currentVideoTab?.url == frontVideoTab.url, !allTranscriptLines.isEmpty {
            return allTranscriptLines
        } else if !captionSearchMayReadTheVideoPage(urlText: frontVideoTab.url) {
            throw VideoQuizFailure.noVideoOnThePage
        } else if !urlIsOnYouTube(urlText: frontVideoTab.url) {
            // The captions reader keeps only YouTube's json3 captions, which other sites do not serve.
            throw VideoQuizFailure.captionSearchNeedsYouTube
        } else if let cachedCaptionLines = captionLinesByVideoURL[frontVideoTab.url] {
            return cachedCaptionLines
        } else {
            let downloadedCaptionLines: [VideoQuizTranscriptLine]
            do {
                downloadedCaptionLines = try await VideoCaptionsDownloader.downloadTranscriptLines(forVideoURL: frontVideoTab.url)
            } catch VideoQuizFailure.noCaptions {
                // The quiz's own line talks about planning a quiz, which is not what the learner asked for.
                throw VideoQuizFailure.noCaptionsToSearch
            }
            captionLinesByVideoURL[frontVideoTab.url] = downloadedCaptionLines
            return downloadedCaptionLines
        }
    }

    private static func runLearnerVideoCommand(_ learnerVideoCommand: LearnerVideoCommand, in videoTab: ChromeVideoTab, title: String, pageIsOnYouTube: Bool) throws -> JSONValue {
        let javaScriptResult = try ChromeVideoTab.runJavaScript(learnerVideoCommand.javaScript, in: videoTab)
        switch videoStateInTheScriptReply(javaScriptResult, title: title, pageIsOnYouTube: pageIsOnYouTube) {
        case .success(let videoState):
            return videoState
        case .failure(let reasonTheReplyHoldsNoVideoState):
            print("Front video: no video state for the front tab (\(URL(string: videoTab.url)?.host() ?? "unknown host")), because \(reasonTheReplyHoldsNoVideoState.rawValue)")
            throw VideoQuizFailure.noVideoOnThePage
        }
    }

    /// Why a video command's reply holds no video state. Each reason leaves the learner with no video tools, so the log
    /// names it: a page with no video differs from a page script that threw, which Chrome returns as an empty reply.
    enum ReasonTheReplyHoldsNoVideoState: String, Error {
        case thePageHasNoVideo = "the page has no video it can reach"
        case theScriptReturnedNothing = "the page script returned nothing"
        case theReplyIsNotJSON = "the page script's reply is not JSON"
        case theStateWasRefused = "the page's video state failed the check of what the model may read"
    }

    static func videoStateInTheScriptReply(_ javaScriptResult: String, title: String, pageIsOnYouTube: Bool) -> Result<JSONValue, ReasonTheReplyHoldsNoVideoState> {
        if javaScriptResult == "no-video" { return .failure(.thePageHasNoVideo) }
        if javaScriptResult.isEmpty { return .failure(.theScriptReturnedNothing) }
        guard let pageVideoState = try? JSONDecoder().decode(JSONValue.self, from: Data(javaScriptResult.utf8)) else {
            return .failure(.theReplyIsNotJSON)
        }
        guard let videoState = learnerVideoStateTheModelMayRead(pageVideoState: pageVideoState, tabTitle: title, pageIsOnYouTube: pageIsOnYouTube) else {
            return .failure(.theStateWasRefused)
        }
        return .success(videoState)
    }

    // MARK: Talking to the page

    private struct VideoPlaybackState {
        let currentSeconds: Double
        let isPaused: Bool
    }

    // The page's largest video, so a preview or a second player on a page such as x.com is never the one paused.
    static let readPlaybackStateJavaScript = "(function () { \(LearnerVideoCommand.mainVideoJavaScript) if (!video) { return 'no-video'; } return video.currentTime + '|' + video.paused; })()"
    static let pauseVideoJavaScript = "(function () { \(LearnerVideoCommand.mainVideoJavaScript) if (video) { video.pause(); } return 'ok'; })()"
    static let playVideoJavaScript = "(function () { \(LearnerVideoCommand.mainVideoJavaScript) if (video) { video.play(); } return 'ok'; })()"
    /// Draws the page's main video into a canvas and returns the JPEG and the video's place on screen.
    /// Chrome's vertical tab strip sits left of the page, so the extra window width counts as left offset.
    static let grabFrameJavaScript = "(function () { \(LearnerVideoCommand.mainVideoJavaScript) if (!video || !video.videoWidth) { return 'no-video'; } var scale = Math.min(1, 1280 / video.videoWidth); var canvas = document.createElement('canvas'); canvas.width = Math.round(video.videoWidth * scale); canvas.height = Math.round(video.videoHeight * scale); canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height); var rect = video.getBoundingClientRect(); return JSON.stringify({ jpeg: canvas.toDataURL('image/jpeg', 0.85).split(',')[1], width: canvas.width, height: canvas.height, videoSeconds: video.currentTime, rectX: window.screenX + (window.outerWidth - window.innerWidth) + rect.left, rectY: window.screenY + (window.outerHeight - window.innerHeight) + rect.top, rectWidth: rect.width, rectHeight: rect.height }); })()"

    private static func grabFrame(of videoTab: ChromeVideoTab) throws -> VideoFrameGrab {
        let javaScriptResult = try ChromeVideoTab.runJavaScript(Self.grabFrameJavaScript, in: videoTab, timeoutSeconds: ChromeVideoTab.frameGrabTimeoutSeconds)
        if javaScriptResult == "no-video" {
            throw VideoQuizFailure.noVideoOnThePage
        }
        return try JSONDecoder().decode(VideoFrameGrab.self, from: Data(javaScriptResult.utf8))
    }

    private func readPlaybackState(of videoTab: ChromeVideoTab) throws -> VideoPlaybackState {
        let javaScriptResult = try ChromeVideoTab.runJavaScript(Self.readPlaybackStateJavaScript, in: videoTab)
        if javaScriptResult == "no-video" {
            throw VideoQuizFailure.noVideoOnThePage
        }
        let resultParts = javaScriptResult.split(separator: "|")
        guard resultParts.count == 2,
              let currentSeconds = Double(resultParts[0]) else {
            throw VideoQuizFailure.chromeScriptFailed("Unexpected clock reading: \(javaScriptResult)")
        }
        return VideoPlaybackState(currentSeconds: currentSeconds, isPaused: resultParts[1] == "true")
    }
}

/// The AppleScript that runs JavaScript in one Chrome tab, cut short after `timeoutSeconds`.
/// The JavaScript must not contain double quotes or backslashes, because it sits inside an AppleScript string.
nonisolated func appleScriptToRunJavaScript(_ javaScript: String, tabId: Int, windowId: Int, timeoutSeconds: Int) -> String {
    """
    with timeout of \(timeoutSeconds) seconds
    tell application "Google Chrome" to execute (tab id \(tabId) of window id \(windowId)) javascript "\(javaScript)"
    end timeout
    """
}

/// The AppleScript that opens a page as the last tab of Chrome's front window and then puts the window back on the tab
/// the learner was watching, so a finished guide never takes over the screen. Nil unless the page is https.
/// A URL's text has quotes and backslashes percent-encoded, so it sits safely inside the AppleScript string.
nonisolated func appleScriptToOpenInABackgroundTab(pageURL: URL) -> String? {
    guard pageURL.scheme?.lowercased() == "https" else { return nil }
    let pageURLText = pageURL.absoluteString
    return """
    tell application "Google Chrome"
        if (count of windows) is 0 then error "Chrome has no window"
        set frontChromeWindow to front window
        set originalActiveTabIndex to active tab index of frontChromeWindow
        tell frontChromeWindow to set newTab to make new tab at end of tabs with properties {URL:"\(pageURLText)"}
        set active tab index of frontChromeWindow to originalActiveTabIndex
        return id of newTab
    end tell
    """
}

/// Finds the tab by id in any Chrome window, makes it the window's active tab, and brings the window and Chrome forward.
/// Returns "found" or "missing". It reads each window's tab ids in one Apple Event, since one event per tab is slow with many tabs.
/// Chrome gives tab ids as text, so a comparison with a number never matches.
nonisolated func appleScriptToLoadPageInChromeTab(pageURL: URL, tabID: Int) -> String? {
    guard pageURL.scheme?.lowercased() == "https" else { return nil }
    return """
    tell application "Google Chrome"
        repeat with chromeWindow in windows
            set tabIDs to id of every tab of chromeWindow
            repeat with tabIndex from 1 to count of tabIDs
                if (item tabIndex of tabIDs as text) is "\(tabID)" then
                    set URL of tab tabIndex of chromeWindow to "\(pageURL.absoluteString)"
                    return "found"
                end if
            end repeat
        end repeat
        return "missing"
    end tell
    """
}

nonisolated func appleScriptToBringChromeTabForward(tabID: Int) -> String {
    """
    tell application "Google Chrome"
        repeat with chromeWindow in windows
            set tabIDs to id of every tab of chromeWindow
            repeat with tabIndex from 1 to count of tabIDs
                if (item tabIndex of tabIDs as text) is "\(tabID)" then
                    set active tab index of chromeWindow to tabIndex
                    set index of chromeWindow to 1
                    activate
                    return "found"
                end if
            end repeat
        end repeat
        return "missing"
    end tell
    """
}

// MARK: - Chrome tab

/// A YouTube watch tab in Chrome, found by AppleScript. Window and tab ids stay
/// valid while tabs move, unlike positions.
struct ChromeVideoTab {
    let windowId: Int
    let tabId: Int
    let url: String
    let title: String

    /// The url and title change when the learner moves to another video inside the same tab, so only the ids identify it.
    func isTheSameTab(as otherVideoTab: ChromeVideoTab) -> Bool {
        windowId == otherVideoTab.windowId && tabId == otherVideoTab.tabId
    }

    /// The same tab showing the same page. A tab that moved to another video keeps its ids but changes its url, so a
    /// caption search that took a while checks both before it seeks.
    func isTheSamePage(as otherVideoTab: ChromeVideoTab) -> Bool {
        isTheSameTab(as: otherVideoTab) && url == otherVideoTab.url
    }

    /// The active tab of Chrome's front window, on any site. The voice tools check for a video with JavaScript.
    static func frontTabOfTheFrontWindow() throws -> ChromeVideoTab {
        let frontTabOutput = try runAppleScript("""
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set frontTab to active tab of front window
            set fieldSeparator to (ASCII character 31)
            return (id of front window as text) & fieldSeparator & (id of frontTab as text) & fieldSeparator & (URL of frontTab) & fieldSeparator & (title of frontTab)
        end tell
        """)
        return try frontTab(fromAppleScriptOutput: frontTabOutput)
    }

    /// The front tab from the script above, which returns "" when Chrome has no window.
    static func frontTab(fromAppleScriptOutput frontTabOutput: String) throws -> ChromeVideoTab {
        if frontTabOutput.isEmpty {
            throw VideoQuizFailure.chromeHasNoWindow
        }
        // ASCII 31, the unit separator, cannot appear in a URL or a tab title, while "|" can.
        let tabFields = frontTabOutput.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
        guard tabFields.count == 4, let windowId = Int(tabFields[0]), let tabId = Int(tabFields[1]) else {
            // Only the field count goes in the message, since the fields hold the tab's URL and title.
            throw VideoQuizFailure.chromeScriptFailed("The front tab read returned \(tabFields.count) fields")
        }
        return ChromeVideoTab(windowId: windowId, tabId: tabId, url: String(tabFields[2]), title: titleWithoutYouTubeSuffix(String(tabFields[3])))
    }

    /// The active tab of the front window if it is a YouTube watch page, else any
    /// YouTube watch tab in any Chrome window, unless `onlyTheActiveTabOfTheFrontWindow` is set.
    static func findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: Bool = false) throws -> ChromeVideoTab {
        // Chrome lists windows front to back. Each output line is
        // windowId, tabId, windowPosition, isActiveTab, url, and title, split by ASCII 31, which cannot appear in a URL or a title
        // Every Apple Event costs about 17 ms, so each window's tabs are read in three batches rather than
        // one event per tab, which took about 640 ms with 28 tabs open. When only the front tab matters,
        // its URL alone decides, so a page that is not a YouTube video costs two or three events.
        let findTabsAppleScript: String
        if onlyTheActiveTabOfTheFrontWindow {
            findTabsAppleScript = """
            tell application "Google Chrome"
                set fieldSeparator to (ASCII character 31)
                if (count of windows) is 0 then return ""
                set frontTab to active tab of front window
                set tabURL to URL of frontTab
                if tabURL does not contain "youtube.com/watch" then return ""
                return (id of front window as text) & fieldSeparator & (id of frontTab as text) & fieldSeparator & "1" & fieldSeparator & "true" & fieldSeparator & tabURL & fieldSeparator & (title of frontTab)
            end tell
            """
        } else {
            findTabsAppleScript = """
            tell application "Google Chrome"
                set fieldSeparator to (ASCII character 31)
                set matchingTabLines to {}
                repeat with windowPosition from 1 to (count of windows)
                    set chromeWindow to window windowPosition
                    set windowId to id of chromeWindow
                    set activeTabIdOfWindow to id of active tab of chromeWindow
                    set tabIds to id of every tab of chromeWindow
                    set tabURLs to URL of every tab of chromeWindow
                    set tabTitles to title of every tab of chromeWindow
                    repeat with tabIndex from 1 to (count of tabIds)
                        set tabURL to item tabIndex of tabURLs
                        if tabURL contains "youtube.com/watch" then
                            set tabId to item tabIndex of tabIds
                            set tabIsActive to (tabId = activeTabIdOfWindow)
                            set end of matchingTabLines to (windowId as text) & fieldSeparator & (tabId as text) & fieldSeparator & (windowPosition as text) & fieldSeparator & (tabIsActive as text) & fieldSeparator & tabURL & fieldSeparator & (item tabIndex of tabTitles)
                        end if
                    end repeat
                end repeat
                set AppleScript's text item delimiters to linefeed
                return matchingTabLines as text
            end tell
            """
        }
        let findTabsOutput = try runAppleScript(findTabsAppleScript)
        return try preferredYouTubeWatchTab(fromFoundTabsOutput: findTabsOutput, onlyTheActiveTabOfTheFrontWindow: onlyTheActiveTabOfTheFrontWindow)
    }

    /// Reads the lines `findYouTubeWatchTab`'s script returns and picks the tab to use. The script's own filter is a
    /// substring match, so a page on another site that only contains a watch URL, such as a Wayback Machine copy, comes back
    /// too, and is dropped here. Throws when no YouTube watch tab is left, so a pop-out falls back to the page's image.
    static func preferredYouTubeWatchTab(fromFoundTabsOutput findTabsOutput: String, onlyTheActiveTabOfTheFrontWindow: Bool) throws -> ChromeVideoTab {
        struct FoundTab {
            let videoTab: ChromeVideoTab
            let isActiveTabOfFrontWindow: Bool
        }
        let foundTabs: [FoundTab] = findTabsOutput.split(separator: "\n").compactMap { tabLine in
            let tabFields = tabLine.split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false)
            guard tabFields.count == 6,
                  let windowId = Int(tabFields[0]),
                  let tabId = Int(tabFields[1]),
                  urlIsAYouTubeWatchPage(urlText: String(tabFields[4])) else {
                return nil
            }
            let isFrontWindow = tabFields[2] == "1"
            let isActiveTab = tabFields[3] == "true"
            let videoTab = ChromeVideoTab(
                windowId: windowId,
                tabId: tabId,
                url: String(tabFields[4]),
                title: titleWithoutYouTubeSuffix(String(tabFields[5]))
            )
            return FoundTab(videoTab: videoTab, isActiveTabOfFrontWindow: isFrontWindow && isActiveTab)
        }

        let activeTabOfTheFrontWindow = foundTabs.first { foundTab in foundTab.isActiveTabOfFrontWindow }
        let preferredTab = onlyTheActiveTabOfTheFrontWindow ? activeTabOfTheFrontWindow : activeTabOfTheFrontWindow ?? foundTabs.first
        guard let preferredTab else {
            throw VideoQuizFailure.noYouTubeTabFound
        }
        return preferredTab.videoTab
    }

    /// Picks the media in the active tab of Chrome's front window that the learner is most likely looking at:
    /// the largest visible video or image, with a video counting four times its area. Images that show nothing
    /// (not loaded, hidden, or fully transparent) are skipped. A loaded image with no natural width is skipped
    /// too, except an SVG, which can have only a viewBox and so no natural width. Returns the window's and
    /// the element's raw page geometry as JSON, or 'none' under 160x90 visible. An image wholly inside the
    /// viewport and stretched to its box also returns its URL (`imageSourceURL`), since only then do its own frames line up
    /// with the capture. Any visible image also returns its file's URL (`imageFileURL`), cropped or partly scrolled out of
    /// view, since room art wants the whole file and not what the screen shows of it (a cookie banner over a product photo).
    /// Only a short https URL comes back, so a large data: URL never travels through AppleScript.
    /// A video the page has not started can sit above the player that shows its thumbnail, with only a thin slice of the
    /// element in the viewport. When under half of a video is visible and a close ancestor of about its size is almost
    /// wholly visible, that ancestor's box is the media, so the loop goes around the player the learner sees. The page measures in CSS pixels and the window in
    /// screen points, so `screenRectInChromeCoordinates` turns them into one screen rect, using Chrome's
    /// accessibility web area when it can, and the page zoom and the screen Chrome is on when it cannot.
    static let largestVisibleMediaJavaScript = [
        "(function () {",
        "var best = null; var bestScore = 0;",
        "function visibleShare(box) {",
        "var visibleLeft = Math.max(box.left, 0); var visibleTop = Math.max(box.top, 0); var visibleRight = Math.min(box.right, window.innerWidth); var visibleBottom = Math.min(box.bottom, window.innerHeight);",
        "if (visibleRight <= visibleLeft || visibleBottom <= visibleTop || !box.width || !box.height) { return 0; }",
        "return ((visibleRight - visibleLeft) * (visibleBottom - visibleTop)) / (box.width * box.height);",
        "}",
        "function boxOfTheVideoTheLearnerSees(video, videoRect) {",
        "if (visibleShare(videoRect) >= 0.5) { return videoRect; }",
        "var ancestor = video.parentElement;",
        "for (var level = 0; ancestor && level < 6; level++) {",
        "var ancestorRect = ancestor.getBoundingClientRect();",
        "var areaRatio = (ancestorRect.width * ancestorRect.height) / (videoRect.width * videoRect.height);",
        "if (areaRatio >= 0.8 && areaRatio <= 1.25 && visibleShare(ancestorRect) >= 0.9) { return ancestorRect; }",
        "ancestor = ancestor.parentElement;",
        "}",
        "return videoRect;",
        "}",
        "var candidates = document.querySelectorAll('video, img');",
        "for (var index = 0; index < candidates.length; index++) {",
        "var element = candidates[index];",
        "var isVideo = element.tagName === 'VIDEO';",
        "if (isVideo && !element.videoWidth) { continue; }",
        "if (!isVideo && (!element.complete || (!element.naturalWidth && !/svg/i.test(element.currentSrc)))) { continue; }",
        "var style = window.getComputedStyle(element);",
        "if (style.visibility === 'hidden' || style.opacity === '0') { continue; }",
        "var rect = element.getBoundingClientRect();",
        "if (isVideo) { rect = boxOfTheVideoTheLearnerSees(element, rect); }",
        "var left = Math.max(rect.left, 0); var top = Math.max(rect.top, 0);",
        "var right = Math.min(rect.right, window.innerWidth); var bottom = Math.min(rect.bottom, window.innerHeight);",
        "if (right <= left || bottom <= top) { continue; }",
        "var visibleArea = (right - left) * (bottom - top);",
        "var score = visibleArea * (isVideo ? 4 : 1);",
        "var isWhollyVisible = rect.left >= 0 && rect.top >= 0 && rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;",
        "var imageSourceURL = !isVideo && isWhollyVisible && style.objectFit === 'fill' && /^https:/i.test(element.currentSrc) && element.currentSrc.length < 2048 ? element.currentSrc : null;",
        "var imageFileURL = !isVideo && /^https:/i.test(element.currentSrc) && element.currentSrc.length < 2048 ? element.currentSrc : null;",
        "if (score > bestScore) { bestScore = score; best = { left: left, top: top, width: right - left, height: bottom - top, visibleArea: visibleArea, imageSourceURL: imageSourceURL, imageFileURL: imageFileURL }; }",
        "}",
        "if (!best || best.visibleArea < 160 * 90) { return 'none'; }",
        "return JSON.stringify({ screenX: window.screenX, screenY: window.screenY, outerWidth: window.outerWidth, outerHeight: window.outerHeight, innerWidth: window.innerWidth, innerHeight: window.innerHeight, devicePixelRatio: window.devicePixelRatio, left: best.left, top: best.top, width: best.width, height: best.height, imageSourceURL: best.imageSourceURL, imageFileURL: best.imageFileURL });",
        "})()",
    ].joined(separator: " ")

    /// Opens the page as a new tab at the end of Chrome's front window without switching to it, and returns the tab's id.
    /// Throws when Chrome is not running, has no window, or refuses the script, and never opens a page that is not https.
    static func openInABackgroundTab(_ pageURL: URL) throws -> Int {
        guard let appleScriptSource = appleScriptToOpenInABackgroundTab(pageURL: pageURL) else {
            throw VideoQuizFailure.chromeScriptFailed("Only https pages open in a background tab")
        }
        let newTabIDText = try runAppleScript(appleScriptSource)
        guard let newTabID = Int(newTabIDText) else {
            throw VideoQuizFailure.chromeScriptFailed("The new tab's id was not a number: \(newTabIDText)")
        }
        return newTabID
    }

    /// Whether a tab with this id was found and brought forward. Throws when Chrome is not running or refuses the script.
    static func bringTabForward(tabID: Int) throws -> Bool {
        try runTabScript(appleScriptToBringChromeTabForward(tabID: tabID)) == "found"
    }

    /// Runs a script that finds a tab by id. Throws when Chrome is not running or refuses the script.
    static func runTabScript(_ appleScriptSource: String) throws -> String {
        try runAppleScript(appleScriptSource)
    }

    /// What the page reports about its window and its largest visible video or image, from one Apple Event with no
    /// accessibility read. Nil when no media is big enough. The loop's poll compares these once a second.
    static func pageGeometryOfTheLargestVisibleMediaInFrontTab() throws -> ChromePageGeometry? {
        let javaScriptResult = try runAppleScript("""
        with timeout of 2 seconds
        tell application "Google Chrome" to execute (active tab of front window) javascript "\(largestVisibleMediaJavaScript)"
        end timeout
        """)
        return try? JSONDecoder().decode(ChromePageGeometry.self, from: Data(javaScriptResult.utf8))
    }

    /// Where the media to rise from sits on screen, or nil for any failure: no Chrome, an AppleScript error,
    /// or no media big enough. The learner may be looking at anything, so this never throws.
    static func screenRectOfTheLargestVisibleMediaInFrontTab() -> ScreenRectInChromeCoordinates? {
        do {
            return try largestVisibleMediaInFrontTabOrNone()?.screenRect
        } catch {
            print("Live scene: could not read the media rect from Chrome: \(error)")
            return nil
        }
    }

    /// The same media for a pop-out, which says out loud why Chrome refused, such as JavaScript
    /// from Apple Events being off. Nil when no media is big enough. The front tab can be any busy site, so the read
    /// gets the voice tools' 2 second timeout instead of freezing the main actor.
    static func largestVisibleMediaInFrontTabOrNone() throws -> LargestVisibleMediaInFrontTab? {
        guard let pageGeometry = try pageGeometryOfTheLargestVisibleMediaInFrontTab() else {
            return nil
        }
        // The web area of Chrome's window says where the viewport sits, which the page geometry cannot when a
        // side panel, vertical tabs, or docked DevTools take window space. The page geometry is the fallback.
        if let rectFromWebArea = screenRectInChromeCoordinates(
            from: pageGeometry,
            matchingWebAreaFrames: ChromeWebArea.webAreaFramesOfChromesFocusedWindow()
        ) {
            print("Media rect: placed from Chrome's accessibility web area")
            return LargestVisibleMediaInFrontTab(screenRect: rectFromWebArea, pageGeometry: pageGeometry, imageSourceURL: pageGeometry.imageSourceURL.flatMap(URL.init(string:)))
        }
        let rectFromPageGeometry = screenRectInChromeCoordinates(
            from: pageGeometry,
            backingScaleFactor: backingScaleFactorOfTheScreenHoldingTheWindow(of: pageGeometry)
        )
        print("Media rect: no matching web area, \(rectFromPageGeometry == nil ? "the page geometry gave no rect either" : "placed from the page geometry")")
        return rectFromPageGeometry.map { screenRect in
            LargestVisibleMediaInFrontTab(screenRect: screenRect, pageGeometry: pageGeometry, imageSourceURL: pageGeometry.imageSourceURL.flatMap(URL.init(string:)))
        }
    }

    /// The pixel density of the screen that holds the largest part of Chrome's window, which the page zoom is
    /// measured against. Falls back to the main screen's, then to 1 when no screen is known.
    private static func backingScaleFactorOfTheScreenHoldingTheWindow(of pageGeometry: ChromePageGeometry) -> Double {
        let fallbackBackingScaleFactor = Double(NSScreen.main?.backingScaleFactor ?? 1)
        let windowRect = ScreenRectInChromeCoordinates(
            rectX: pageGeometry.screenX,
            rectY: pageGeometry.screenY,
            rectWidth: pageGeometry.outerWidth,
            rectHeight: pageGeometry.outerHeight
        )
        let screens = NSScreen.screens
        guard let screenIndex = indexOfTheScreenFrameHolding(windowRect, screenFramesInAppKitCoordinates: screens.map(\.frame)) else {
            return fallbackBackingScaleFactor
        }
        return Double(screens[screenIndex].backingScaleFactor)
    }

    private static func titleWithoutYouTubeSuffix(_ tabTitle: String) -> String {
        let youTubeSuffix = " - YouTube"
        return tabTitle.hasSuffix(youTubeSuffix) ? String(tabTitle.dropLast(youTubeSuffix.count)) : tabTitle
    }

    /// A page with an alert() or a stuck script holds an Apple Event for about 2 minutes, which freezes the main actor,
    /// so every script runs with a short timeout. Grabbing a frame draws a canvas, so it gets longer.
    static let defaultJavaScriptTimeoutSeconds = 2
    static let frameGrabTimeoutSeconds = 5

    /// Runs JavaScript in this tab and returns its result. The JavaScript must
    /// not contain double quotes or backslashes, because it sits inside an AppleScript string.
    @discardableResult
    static func runJavaScript(_ javaScript: String, in videoTab: ChromeVideoTab, timeoutSeconds: Int = defaultJavaScriptTimeoutSeconds) throws -> String {
        try runAppleScript(appleScriptToRunJavaScript(javaScript, tabId: videoTab.tabId, windowId: videoTab.windowId, timeoutSeconds: timeoutSeconds))
    }

    /// Whether the largest video of Chrome's front tab has played to its end, and the tab's address, in one Apple Event. Nil
    /// when the page has no video or Chrome has no window. Throws when Chrome refuses the script.
    @MainActor
    static func readWhetherTheFrontVideoHasEnded() throws -> FrontVideoEndReading? {
        let scriptReply = try runAppleScript(appleScriptToRunJavaScriptInTheFrontTab(FrontVideoEndReading.pageScript, timeoutSeconds: defaultJavaScriptTimeoutSeconds))
        return FrontVideoEndReading(scriptReply: scriptReply)
    }

    /// Whether Chrome is open. Tests replace it, since a developer's Chrome is usually running.
    static var chromeIsRunning: () -> Bool = { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty }

    /// NSAppleScript is not thread safe, so every script runs on the main actor.
    /// Every Chrome script comes through here, and `tell application "Google Chrome"` would launch Chrome when it is closed,
    /// so a closed Chrome throws before any script runs.
    @MainActor
    private static func runAppleScript(_ appleScriptSource: String) throws -> String {
        guard chromeIsRunning() else {
            throw VideoQuizFailure.chromeIsNotRunning
        }
        guard let appleScript = NSAppleScript(source: appleScriptSource) else {
            throw VideoQuizFailure.chromeScriptFailed("The AppleScript did not compile")
        }
        var appleScriptErrorInfo: NSDictionary?
        let scriptResult = appleScript.executeAndReturnError(&appleScriptErrorInfo)
        if let appleScriptErrorInfo {
            throw failure(fromAppleScriptErrorInfo: appleScriptErrorInfo)
        }
        return scriptResult.stringValue ?? ""
    }

    private static func failure(fromAppleScriptErrorInfo appleScriptErrorInfo: NSDictionary) -> VideoQuizFailure {
        let errorMessage = appleScriptErrorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
        let errorNumber = appleScriptErrorInfo[NSAppleScript.errorNumber] as? Int
        let lowercaseErrorMessage = errorMessage.lowercased()

        if lowercaseErrorMessage.contains("javascript") && lowercaseErrorMessage.contains("turned off") {
            return .javaScriptFromAppleEventsIsOff
        }
        // -1743 is errAEEventNotPermitted, the macOS Automation permission being refused.
        if errorNumber == -1743 {
            return .notAllowedToControlChrome
        }
        return .chromeScriptFailed(errorMessage)
    }
}

// MARK: - Captions

#if DEBUG
/// A debug captions file counts only when its name holds the playing video's ID, read from the URL's `v` parameter,
/// so a leftover setting never feeds one video's captions to another.
func debugCaptionsFileApplies(captionsFilePath: String, videoURL: String) -> Bool {
    guard let videoID = URLComponents(string: videoURL)?.queryItems?.first(where: { $0.name == "v" })?.value,
          !videoID.isEmpty else {
        return false
    }
    return (captionsFilePath as NSString).lastPathComponent.contains(videoID)
}
#endif

private enum VideoCaptionsDownloader {
    private static let ytDlpCandidatePaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
    private static let secondsBeforeGivingUpOnYtDlp: TimeInterval = 45

    /// Runs yt-dlp for the English captions only. Asking for "en.*" also asks for
    /// every translation, which YouTube answers with a 429.
    static func downloadTranscriptLines(forVideoURL videoURL: String) async throws -> [VideoQuizTranscriptLine] {
        #if DEBUG
        // When YouTube rate-limits this Mac's caption requests, a rehearsal can use captions fetched elsewhere:
        // `defaults write <bundle id> debugVideoQuizCaptionsJSON3Path /path/<video id>.json3`. The quiz and
        // find_moment both read through here.
        if let captionsFilePath = UserDefaults.standard.string(forKey: "debugVideoQuizCaptionsJSON3Path") {
            if debugCaptionsFileApplies(captionsFilePath: captionsFilePath, videoURL: videoURL),
               let captionsData = FileManager.default.contents(atPath: captionsFilePath) {
                print("Video quiz: reading captions from \(captionsFilePath) instead of yt-dlp")
                let transcriptLines = try videoQuizTranscriptLines(fromCaptionsJSON3Data: captionsData)
                guard !transcriptLines.isEmpty else { throw VideoQuizFailure.noCaptions }
                return transcriptLines
            }
            print("Video quiz: the debug captions file \(captionsFilePath) does not apply to \(videoURL), so yt-dlp reads the captions")
        }
        #endif
        guard let ytDlpPath = ytDlpCandidatePaths.first(where: { candidatePath in
            FileManager.default.isExecutableFile(atPath: candidatePath)
        }) else {
            throw VideoQuizFailure.captionsToolFailed("yt-dlp is not installed")
        }

        let captionsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("clicky-video-quiz-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: captionsDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: captionsDirectory)
        }

        let ytDlpProcess = Process()
        ytDlpProcess.executableURL = URL(fileURLWithPath: ytDlpPath)
        ytDlpProcess.arguments = [
            "--skip-download",
            "--no-playlist",
            "--write-auto-subs",
            "--write-subs",
            "--sub-langs", "en",
            "--sub-format", "json3",
            "-o", captionsDirectory.appendingPathComponent("%(id)s.%(ext)s").path,
            // The voice tools pass whatever page is in front, so only sites yt-dlp knows are read, never a crawl of any page.
            "--use-extractors", "default,-generic",
            // A yt-dlp config on this Mac could add options, such as an exec step, to a URL from any page.
            "--ignore-config",
            // Everything after this is the URL, even if it starts with a dash.
            "--",
            videoURL,
        ]
        ytDlpProcess.standardOutput = FileHandle.nullDevice
        ytDlpProcess.standardError = FileHandle.nullDevice

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(secondsBeforeGivingUpOnYtDlp))
            if ytDlpProcess.isRunning {
                ytDlpProcess.terminate()
            }
        }
        defer {
            timeoutTask.cancel()
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                ytDlpProcess.terminationHandler = { _ in
                    continuation.resume()
                }
                do {
                    try ytDlpProcess.run()
                } catch {
                    continuation.resume(throwing: VideoQuizFailure.captionsToolFailed("yt-dlp did not start: \(error)"))
                }
            }
        } onCancel: {
            if ytDlpProcess.isRunning {
                ytDlpProcess.terminate()
            }
        }
        try Task.checkCancellation()

        guard ytDlpProcess.terminationStatus == 0 else {
            throw VideoQuizFailure.captionsToolFailed("yt-dlp exited with status \(ytDlpProcess.terminationStatus)")
        }

        let writtenFileNames = try FileManager.default.contentsOfDirectory(atPath: captionsDirectory.path)
        guard let captionsFileName = writtenFileNames.first(where: { writtenFileName in
            writtenFileName.hasSuffix(".json3")
        }) else {
            throw VideoQuizFailure.noCaptions
        }
        let captionsData = try Data(contentsOf: captionsDirectory.appendingPathComponent(captionsFileName))
        let transcriptLines = try videoQuizTranscriptLines(fromCaptionsJSON3Data: captionsData)
        guard !transcriptLines.isEmpty else {
            throw VideoQuizFailure.noCaptions
        }
        return transcriptLines
    }
}

// MARK: - Worker plan

private struct VideoQuizPlanClient {
    private struct RequestBody: Encodable {
        let title: String
        let transcriptLines: [VideoQuizTranscriptLine]
    }

    private struct ResponseBody: Decodable {
        let moments: [VideoQuizMoment]
    }

    let workerBaseURL: String

    func requestPlan(title: String, transcriptLines: [VideoQuizTranscriptLine]) async throws -> [VideoQuizMoment] {
        guard let planURL = URL(string: "\(workerBaseURL)/video-quiz-plan") else {
            throw VideoQuizFailure.planFailed("Worker base URL did not form a /video-quiz-plan URL: \(workerBaseURL)")
        }
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(RequestBody(title: title, transcriptLines: transcriptLines)),
            to: planURL,
            using: URLSession.shared,
            // Sonnet can take 3 tries on a long transcript.
            timeoutInterval: 120,
            sendsAppSecret: false
        )
        guard statusCode != -1 else {
            throw VideoQuizFailure.planFailed("Invalid response")
        }
        guard statusCode == 200 else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw VideoQuizFailure.planFailed("Video quiz plan API error (\(statusCode)): \(errorBody)")
        }

        return try JSONDecoder().decode(ResponseBody.self, from: responseData).moments
    }
}
