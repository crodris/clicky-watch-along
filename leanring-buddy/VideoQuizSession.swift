//
//  VideoQuizSession.swift
//  leanring-buddy
//
//  Quizzes the learner on a YouTube video playing in Chrome. It reads the
//  video's captions once, asks the Worker to pick three moments ahead of time,
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

    if normalizedTranscript.contains("stop quizzing") || normalizedTranscript.contains("stop watching") {
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
    let quiz: FieldTripQuiz
    let subject: String
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
    case javaScriptFromAppleEventsIsOff
    case notAllowedToControlChrome
    case chromeScriptFailed(String)
    case captionsToolFailed(String)
    case noCaptions
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
        case .planFailed:
            return "I couldn't pick quiz spots for this video."
        case .lostTheYouTubeTab:
            return "I lost the YouTube tab, so I stopped the quiz."
        }
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

    private let workerBaseURL: String
    private let canAskQuestionNow: @MainActor () -> Bool
    private let askQuestion: @MainActor (FieldTripQuiz) -> Void
    private let speakLine: @MainActor (String) -> Void

    private(set) var isRunning = false
    private var runningTask: Task<Void, Never>?

    private var currentVideoTab: ChromeVideoTab?
    private var moments: [VideoQuizMoment] = []
    private var askedMomentIndices: Set<Int> = []
    private var isWaitingForQuestionToFinish = false
    private var consecutiveFailedPlaybackReadCount = 0

    init(
        workerBaseURL: String,
        canAskQuestionNow: @escaping @MainActor () -> Bool,
        askQuestion: @escaping @MainActor (FieldTripQuiz) -> Void,
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
        isWaitingForQuestionToFinish = false
        consecutiveFailedPlaybackReadCount = 0
        runningTask = Task {
            await self.planAndRunQuiz()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isWaitingForQuestionToFinish = false
        runningTask?.cancel()
        runningTask = nil
        print("Video quiz: stopped")
    }

    /// Called once the explanation has been spoken. Presses play again, and ends
    /// the session after the last moment.
    func resumeVideoAfterQuestion() {
        guard isRunning, isWaitingForQuestionToFinish, let currentVideoTab else { return }
        isWaitingForQuestionToFinish = false
        do {
            try ChromeVideoTab.runJavaScript(Self.playVideoJavaScript, in: currentVideoTab)
            print("Video quiz: resumed the video")
        } catch {
            print("Video quiz: could not resume the video: \(error)")
        }
        if askedMomentIndices.count == moments.count {
            print("Video quiz: all \(moments.count) moments asked")
            stop()
        }
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
            let transcriptLines = try await VideoCaptionsDownloader.downloadTranscriptLines(forVideoURL: videoTab.url)
            guard isRunning, !Task.isCancelled else { return }
            print("Video quiz: read \(transcriptLines.count) caption lines")

            let plannedMoments = try await VideoQuizPlanClient(workerBaseURL: workerBaseURL).requestPlan(
                title: videoTab.title,
                transcriptLines: transcriptLines.filter { transcriptLine in
                    transcriptLine.seconds >= playbackState.currentSeconds
                }
            )
            guard isRunning, !Task.isCancelled else { return }
            moments = plannedMoments.map { plannedMoment in
                var quizWithWhatWasHeard = plannedMoment.quiz
                quizWithWhatWasHeard.heardTranscript = transcriptLines
                    .filter { $0.seconds < plannedMoment.pauseAtSeconds }
                    .suffix(40)
                    .map(\.text)
                    .joined(separator: " ")
                return VideoQuizMoment(
                    pauseAtSeconds: plannedMoment.pauseAtSeconds,
                    quiz: quizWithWhatWasHeard,
                    subject: plannedMoment.subject
                )
            }
            let planningSeconds = Date().timeIntervalSince(planningStartDate)
            for (momentIndex, moment) in plannedMoments.enumerated() {
                print("Video quiz: moment \(momentIndex + 1) at \(moment.pauseAtSeconds)s, answer \"\(moment.quiz.answerLabel)\": \(moment.quiz.question)")
            }
            print("Video quiz: planned \(plannedMoments.count) moments in \(String(format: "%.1f", planningSeconds))s")

            speakLine("Okay, I've got \(plannedMoments.count) spots picked out. Press play whenever you're ready!")
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
            guard isRunning, !Task.isCancelled, !isWaitingForQuestionToFinish else { continue }

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
        isWaitingForQuestionToFinish = true
        let moment = moments[momentIndex]
        print("Video quiz: paused at \(videoSecondsWhenReached)s for moment \(momentIndex + 1), planned for \(moment.pauseAtSeconds)s")

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
        askQuestion(moment.quiz)
    }

    // MARK: Talking to the page

    private struct VideoPlaybackState {
        let currentSeconds: Double
        let isPaused: Bool
    }

    private static let readPlaybackStateJavaScript = "(function () { var video = document.querySelector('video'); if (!video) { return 'no-video'; } return video.currentTime + '|' + video.paused; })()"
    private static let pauseVideoJavaScript = "(function () { var video = document.querySelector('video'); if (video) { video.pause(); } return 'ok'; })()"
    private static let playVideoJavaScript = "(function () { var video = document.querySelector('video'); if (video) { video.play(); } return 'ok'; })()"

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

    /// The active tab of the front window if it is a YouTube watch page, else any
    /// YouTube watch tab in any Chrome window.
    static func findYouTubeWatchTab() throws -> ChromeVideoTab {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty else {
            throw VideoQuizFailure.chromeIsNotRunning
        }

        // Chrome lists windows front to back. Each output line is
        // windowId|tabId|windowPosition|isActiveTab|url|title
        let findTabsAppleScript = """
        tell application "Google Chrome"
            set matchingTabLines to {}
            repeat with windowPosition from 1 to (count of windows)
                set chromeWindow to window windowPosition
                set activeTabIdOfWindow to id of active tab of chromeWindow
                repeat with chromeTab in (tabs of chromeWindow)
                    set tabURL to URL of chromeTab
                    if tabURL contains "youtube.com/watch" then
                        set tabIsActive to ((id of chromeTab) = activeTabIdOfWindow)
                        set end of matchingTabLines to (id of chromeWindow as text) & "|" & (id of chromeTab as text) & "|" & (windowPosition as text) & "|" & (tabIsActive as text) & "|" & tabURL & "|" & (title of chromeTab)
                    end if
                end repeat
            end repeat
            set AppleScript's text item delimiters to linefeed
            return matchingTabLines as text
        end tell
        """
        let findTabsOutput = try runAppleScript(findTabsAppleScript)

        struct FoundTab {
            let videoTab: ChromeVideoTab
            let isActiveTabOfFrontWindow: Bool
        }
        let foundTabs: [FoundTab] = findTabsOutput.split(separator: "\n").compactMap { tabLine in
            let tabFields = tabLine.split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
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

        let preferredTab = foundTabs.first { foundTab in foundTab.isActiveTabOfFrontWindow } ?? foundTabs.first
        guard let preferredTab else {
            throw VideoQuizFailure.noYouTubeTabFound
        }
        return preferredTab.videoTab
    }

    private static func titleWithoutYouTubeSuffix(_ tabTitle: String) -> String {
        let youTubeSuffix = " - YouTube"
        return tabTitle.hasSuffix(youTubeSuffix) ? String(tabTitle.dropLast(youTubeSuffix.count)) : tabTitle
    }

    /// Runs JavaScript in this tab and returns its result. The JavaScript must
    /// not contain double quotes or backslashes, because it sits inside an AppleScript string.
    @discardableResult
    static func runJavaScript(_ javaScript: String, in videoTab: ChromeVideoTab) throws -> String {
        try runAppleScript("""
        tell application "Google Chrome" to execute (tab id \(videoTab.tabId) of window id \(videoTab.windowId)) javascript "\(javaScript)"
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

private enum VideoCaptionsDownloader {
    private static let ytDlpCandidatePaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
    private static let secondsBeforeGivingUpOnYtDlp: TimeInterval = 45

    /// Runs yt-dlp for the English captions only. Asking for "en.*" also asks for
    /// every translation, which YouTube answers with a 429.
    static func downloadTranscriptLines(forVideoURL videoURL: String) async throws -> [VideoQuizTranscriptLine] {
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
        struct PlannedMoment: Decodable {
            let pauseAtSeconds: Double
            let question: String
            let answerLabel: String
            let functionWords: [String]
            let explanation: String
            let subject: String
        }

        let moments: [PlannedMoment]
    }

    let workerBaseURL: String

    func requestPlan(title: String, transcriptLines: [VideoQuizTranscriptLine]) async throws -> [VideoQuizMoment] {
        guard let planURL = URL(string: "\(workerBaseURL)/video-quiz-plan") else {
            throw VideoQuizFailure.planFailed("Worker base URL did not form a /video-quiz-plan URL: \(workerBaseURL)")
        }
        var request = URLRequest(url: planURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(RequestBody(title: title, transcriptLines: transcriptLines))

        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VideoQuizFailure.planFailed("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: responseData, encoding: .utf8) ?? "Unknown error"
            throw VideoQuizFailure.planFailed("Video quiz plan API error (\(httpResponse.statusCode)): \(errorBody)")
        }

        let responseBody = try JSONDecoder().decode(ResponseBody.self, from: responseData)
        return responseBody.moments.map { plannedMoment in
            VideoQuizMoment(
                pauseAtSeconds: plannedMoment.pauseAtSeconds,
                quiz: FieldTripQuiz(
                    answerLabel: plannedMoment.answerLabel,
                    question: plannedMoment.question,
                    functionWords: plannedMoment.functionWords,
                    explanation: plannedMoment.explanation
                ),
                subject: plannedMoment.subject
            )
        }
    }
}
