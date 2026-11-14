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
    private static let mainVideoJavaScript = "var videos = Array.prototype.slice.call(document.querySelectorAll('video')); var video = videos[0] || null; var largestArea = 0; videos.forEach(function (candidate) { var rect = candidate.getBoundingClientRect(); var area = rect.width * rect.height; if (area > largestArea) { largestArea = area; video = candidate; } });"

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

private enum VideoQuizFailure: Error {
    case chromeIsNotRunning
    case noYouTubeTabFound
    case noVideoOnThePage
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

    /// What Clicky says out loud, in plain words.
    var spokenLine: String {
        switch self {
        case .chromeIsNotRunning:
            return "Chrome isn't open, so I can't find a video."
        case .noYouTubeTabFound:
            return "I couldn't find a YouTube video open in Chrome."
        case .noVideoOnThePage:
            return "I couldn't find a video player on that page."
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
    private let speakLine: @MainActor (String) -> Void

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
    private var consecutiveFailedPlaybackReadCount = 0
    private var framePopoutTasksByMomentIndex: [Int: Task<VideoFramePopout?, Never>] = [:]

    init(
        workerBaseURL: String,
        canAskQuestionNow: @escaping @MainActor () -> Bool,
        askQuestion: @escaping @MainActor (LiveSceneQuiz, VideoFramePopout?) -> Void,
        speakLine: @escaping @MainActor (String) -> Void
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
        // A failure or a stop during planning would otherwise leave the planning label up.
        LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.videoQuizPlanningLines)
        print("Video quiz: stopped")
    }

    /// Pauses the YouTube video in Chrome's front tab for a 3D model or pop-out the learner asked for,
    /// with or without a quiz, so the video's narrator does not talk over Clicky. Returns what the quiz
    /// video just said, so "show me that" can be built from it, or "" when no quiz watches this video.
    /// A running quiz only pauses its own video, and Clicky holds one pause at a time.
    func pauseVideoForRequestedScene() -> String {
        guard let frontVideoTab = try? ChromeVideoTab.findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: true) else { return "" }
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
            return allTranscriptLines
                .filter { $0.seconds < playbackState.currentSeconds }
                .suffix(12)
                .map(\.text)
                .joined(separator: " ")
        } catch {
            print("Video quiz: could not pause for a 3D model: \(error)")
            return ""
        }
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
            speakLine("Okay, I've got \(spotCountText) picked out. Here we go!")
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
        speakLine(failure.spokenLine)
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
        askQuestion(moment.quiz, framePopout)
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
            framePopout.animationFrames = animationFrames
            print("Frame pop-out: playing the page image's \(animationFrames.count) animation frames")
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
        guard let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow() else { return nil }
        return try? Self.runLearnerVideoCommand(.readState, in: frontTab, title: frontTab.title, pageIsOnYouTube: urlIsOnYouTube(urlText: frontTab.url))
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

    /// The caption lines that best match the query in the video in front. The quiz's own captions are reused,
    /// and another YouTube video's captions are read once with yt-dlp and kept for the rest of the session.
    /// Any other site throws, since the captions reader keeps only YouTube's format, and the model hears the search failed.
    func captionMomentsInTheFrontVideo(matching query: String) async throws -> [VideoCaptionMoment] {
        let frontVideoTab = try ChromeVideoTab.frontTabOfTheFrontWindow()
        let captionLines: [VideoQuizTranscriptLine]
        if isRunning, currentVideoTab?.isTheSameTab(as: frontVideoTab) == true, !allTranscriptLines.isEmpty {
            captionLines = allTranscriptLines
        } else if !captionSearchMayReadTheVideoPage(urlText: frontVideoTab.url) {
            throw VideoQuizFailure.noVideoOnThePage
        } else if !urlIsOnYouTube(urlText: frontVideoTab.url) {
            // The captions reader keeps only YouTube's json3 captions, which other sites do not serve.
            throw VideoQuizFailure.captionSearchNeedsYouTube
        } else if let cachedCaptionLines = captionLinesByVideoURL[frontVideoTab.url] {
            captionLines = cachedCaptionLines
        } else {
            do {
                captionLines = try await VideoCaptionsDownloader.downloadTranscriptLines(forVideoURL: frontVideoTab.url)
            } catch VideoQuizFailure.noCaptions {
                // The quiz's own line talks about planning a quiz, which is not what the learner asked for.
                throw VideoQuizFailure.noCaptionsToSearch
            }
            captionLinesByVideoURL[frontVideoTab.url] = captionLines
        }
        return videoCaptionMomentsMatching(query: query, captionLines: captionLines)
    }

    private static func runLearnerVideoCommand(_ learnerVideoCommand: LearnerVideoCommand, in videoTab: ChromeVideoTab, title: String, pageIsOnYouTube: Bool) throws -> JSONValue {
        let javaScriptResult = try ChromeVideoTab.runJavaScript(learnerVideoCommand.javaScript, in: videoTab, timeoutSeconds: 2)
        guard javaScriptResult != "no-video",
              let pageVideoState = try? JSONDecoder().decode(JSONValue.self, from: Data(javaScriptResult.utf8)),
              let videoState = learnerVideoStateTheModelMayRead(pageVideoState: pageVideoState, tabTitle: title, pageIsOnYouTube: pageIsOnYouTube) else {
            throw VideoQuizFailure.noVideoOnThePage
        }
        return videoState
    }

    // MARK: Talking to the page

    private struct VideoPlaybackState {
        let currentSeconds: Double
        let isPaused: Bool
    }

    private static let readPlaybackStateJavaScript = "(function () { var video = document.querySelector('video'); if (!video) { return 'no-video'; } return video.currentTime + '|' + video.paused; })()"
    private static let pauseVideoJavaScript = "(function () { var video = document.querySelector('video'); if (video) { video.pause(); } return 'ok'; })()"
    private static let playVideoJavaScript = "(function () { var video = document.querySelector('video'); if (video) { video.play(); } return 'ok'; })()"
    /// Draws the playing video into a canvas and returns the JPEG and the video's place on screen.
    /// Chrome's vertical tab strip sits left of the page, so the extra window width counts as left offset.
    private static let grabFrameJavaScript = "(function () { var video = document.querySelector('video'); if (!video || !video.videoWidth) { return 'no-video'; } var scale = Math.min(1, 1280 / video.videoWidth); var canvas = document.createElement('canvas'); canvas.width = Math.round(video.videoWidth * scale); canvas.height = Math.round(video.videoHeight * scale); canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height); var rect = video.getBoundingClientRect(); return JSON.stringify({ jpeg: canvas.toDataURL('image/jpeg', 0.85).split(',')[1], width: canvas.width, height: canvas.height, videoSeconds: video.currentTime, rectX: window.screenX + (window.outerWidth - window.innerWidth) + rect.left, rectY: window.screenY + (window.outerHeight - window.innerHeight) + rect.top, rectWidth: rect.width, rectHeight: rect.height }); })()"

    private static func grabFrame(of videoTab: ChromeVideoTab) throws -> VideoFrameGrab {
        let javaScriptResult = try ChromeVideoTab.runJavaScript(Self.grabFrameJavaScript, in: videoTab)
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

// MARK: - Chrome tab

/// A YouTube watch tab in Chrome, found by AppleScript. Window and tab ids stay
/// valid while tabs move, unlike positions.
private struct ChromeVideoTab {
    let windowId: Int
    let tabId: Int
    let url: String
    let title: String

    /// The url and title change when the learner moves to another video inside the same tab, so only the ids identify it.
    func isTheSameTab(as otherVideoTab: ChromeVideoTab) -> Bool {
        windowId == otherVideoTab.windowId && tabId == otherVideoTab.tabId
    }

    /// The active tab of Chrome's front window, on any site. The voice tools check for a video with JavaScript.
    static func frontTabOfTheFrontWindow() throws -> ChromeVideoTab {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            throw VideoQuizFailure.chromeIsNotRunning
        }
        let frontTabOutput = try runAppleScript("""
        tell application "Google Chrome"
            if (count of windows) is 0 then return ""
            set frontTab to active tab of front window
            set fieldSeparator to (ASCII character 31)
            return (id of front window as text) & fieldSeparator & (id of frontTab as text) & fieldSeparator & (URL of frontTab) & fieldSeparator & (title of frontTab)
        end tell
        """)
        // ASCII 31, the unit separator, cannot appear in a URL or a tab title, while "|" can.
        let tabFields = frontTabOutput.split(separator: "\u{1F}", maxSplits: 3, omittingEmptySubsequences: false)
        guard tabFields.count == 4, let windowId = Int(tabFields[0]), let tabId = Int(tabFields[1]) else {
            throw VideoQuizFailure.noVideoOnThePage
        }
        return ChromeVideoTab(windowId: windowId, tabId: tabId, url: String(tabFields[2]), title: titleWithoutYouTubeSuffix(String(tabFields[3])))
    }

    /// The active tab of the front window if it is a YouTube watch page, else any
    /// YouTube watch tab in any Chrome window, unless `onlyTheActiveTabOfTheFrontWindow` is set.
    static func findYouTubeWatchTab(onlyTheActiveTabOfTheFrontWindow: Bool = false) throws -> ChromeVideoTab {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            throw VideoQuizFailure.chromeIsNotRunning
        }

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

        struct FoundTab {
            let videoTab: ChromeVideoTab
            let isActiveTabOfFrontWindow: Bool
        }
        let foundTabs: [FoundTab] = findTabsOutput.split(separator: "\n").compactMap { tabLine in
            let tabFields = tabLine.split(separator: "\u{1F}", maxSplits: 5, omittingEmptySubsequences: false)
            guard tabFields.count == 6,
                  let windowId = Int(tabFields[0]),
                  let tabId = Int(tabFields[1]) else {
                return nil
            }
            let isFrontWindow = tabFields[2] == "1"
            let isActiveTab = tabFields[3] == "true"
            let videoTab = ChromeVideoTab(
                windowId: windowId,
                tabId: tabId,
                url: String(tabFields[4]),
                title: Self.titleWithoutYouTubeSuffix(String(tabFields[5]))
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
    /// viewport and stretched to its box also returns its URL, since only then do its own frames line up with the capture.
    /// Only a short https URL comes back, so a large data: URL never travels through AppleScript. The page measures in CSS pixels and the window in
    /// screen points, so `screenRectInChromeCoordinates` turns them into one screen rect, using Chrome's
    /// accessibility web area when it can, and the page zoom and the screen Chrome is on when it cannot.
    private static let largestVisibleMediaJavaScript = [
        "(function () {",
        "var best = null; var bestScore = 0;",
        "var candidates = document.querySelectorAll('video, img');",
        "for (var index = 0; index < candidates.length; index++) {",
        "var element = candidates[index];",
        "var isVideo = element.tagName === 'VIDEO';",
        "if (isVideo && !element.videoWidth) { continue; }",
        "if (!isVideo && (!element.complete || (!element.naturalWidth && !/svg/i.test(element.currentSrc)))) { continue; }",
        "var style = window.getComputedStyle(element);",
        "if (style.visibility === 'hidden' || style.opacity === '0') { continue; }",
        "var rect = element.getBoundingClientRect();",
        "var left = Math.max(rect.left, 0); var top = Math.max(rect.top, 0);",
        "var right = Math.min(rect.right, window.innerWidth); var bottom = Math.min(rect.bottom, window.innerHeight);",
        "if (right <= left || bottom <= top) { continue; }",
        "var visibleArea = (right - left) * (bottom - top);",
        "var score = visibleArea * (isVideo ? 4 : 1);",
        "var isWhollyVisible = rect.left >= 0 && rect.top >= 0 && rect.right <= window.innerWidth && rect.bottom <= window.innerHeight;",
        "var imageSourceURL = !isVideo && isWhollyVisible && style.objectFit === 'fill' && /^https:/i.test(element.currentSrc) && element.currentSrc.length < 2048 ? element.currentSrc : null;",
        "if (score > bestScore) { bestScore = score; best = { left: left, top: top, width: right - left, height: bottom - top, visibleArea: visibleArea, imageSourceURL: imageSourceURL }; }",
        "}",
        "if (!best || best.visibleArea < 160 * 90) { return 'none'; }",
        "return JSON.stringify({ screenX: window.screenX, screenY: window.screenY, outerWidth: window.outerWidth, outerHeight: window.outerHeight, innerWidth: window.innerWidth, innerHeight: window.innerHeight, devicePixelRatio: window.devicePixelRatio, left: best.left, top: best.top, width: best.width, height: best.height, imageSourceURL: best.imageSourceURL });",
        "})()",
    ].joined(separator: " ")

    /// Where the media to rise from sits on screen, or nil for any failure: no Chrome, an AppleScript error,
    /// or no media big enough. The learner may be looking at anything, so this never throws.
    static func screenRectOfTheLargestVisibleMediaInFrontTab() -> ScreenRectInChromeCoordinates? {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            return nil
        }
        do {
            return try largestVisibleMediaInFrontTabOrNone()?.screenRect
        } catch {
            print("Live scene: could not read the media rect from Chrome: \(error)")
            return nil
        }
    }

    /// The same media for a pop-out, which says out loud why Chrome refused, such as JavaScript
    /// from Apple Events being off. Nil when no media is big enough.
    static func largestVisibleMediaInFrontTabOrNone() throws -> LargestVisibleMediaInFrontTab? {
        let javaScriptResult = try runAppleScript("""
        tell application "Google Chrome" to execute (active tab of front window) javascript "\(largestVisibleMediaJavaScript)"
        """)
        guard let pageGeometry = try? JSONDecoder().decode(ChromePageGeometry.self, from: Data(javaScriptResult.utf8)) else {
            return nil
        }
        // The web area of Chrome's window says where the viewport sits, which the page geometry cannot when a
        // side panel, vertical tabs, or docked DevTools take window space. The page geometry is the fallback.
        if let rectFromWebArea = screenRectInChromeCoordinates(
            from: pageGeometry,
            matchingWebAreaFrames: ChromeWebArea.webAreaFramesOfChromesFocusedWindow()
        ) {
            print("Media rect: placed from Chrome's accessibility web area")
            return LargestVisibleMediaInFrontTab(screenRect: rectFromWebArea, imageSourceURL: pageGeometry.imageSourceURL.flatMap(URL.init(string:)))
        }
        let rectFromPageGeometry = screenRectInChromeCoordinates(
            from: pageGeometry,
            backingScaleFactor: backingScaleFactorOfTheScreenHoldingTheWindow(of: pageGeometry)
        )
        print("Media rect: no matching web area, \(rectFromPageGeometry == nil ? "the page geometry gave no rect either" : "placed from the page geometry")")
        return rectFromPageGeometry.map { screenRect in
            LargestVisibleMediaInFrontTab(screenRect: screenRect, imageSourceURL: pageGeometry.imageSourceURL.flatMap(URL.init(string:)))
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

    /// Runs JavaScript in this tab and returns its result. The JavaScript must
    /// not contain double quotes or backslashes, because it sits inside an AppleScript string.
    @discardableResult
    /// A busy page can hold an Apple Event for about 2 minutes by default, which freezes the main actor,
    /// so the voice tools, which reach any site, pass a short timeout.
    static func runJavaScript(_ javaScript: String, in videoTab: ChromeVideoTab, timeoutSeconds: Int? = nil) throws -> String {
        let executeLine = "tell application \"Google Chrome\" to execute (tab id \(videoTab.tabId) of window id \(videoTab.windowId)) javascript \"\(javaScript)\""
        guard let timeoutSeconds else {
            return try runAppleScript(executeLine)
        }
        return try runAppleScript("""
        with timeout of \(timeoutSeconds) seconds
        \(executeLine)
        end timeout
        """)
    }

    /// NSAppleScript is not thread safe, so every script runs on the main actor.
    @MainActor
    private static func runAppleScript(_ appleScriptSource: String) throws -> String {
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
        var request = URLRequest(url: planURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Sonnet can take 3 tries on a long transcript.
        request.timeoutInterval = 120
        request.httpBody = try JSONEncoder().encode(RequestBody(title: title, transcriptLines: transcriptLines))

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoQuizFailure.planFailed("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw VideoQuizFailure.planFailed("Video quiz plan API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        return try JSONDecoder().decode(ResponseBody.self, from: responseData).moments
    }
}
