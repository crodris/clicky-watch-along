//
//  VideoWatchAlongSession.swift
//  leanring-buddy
//
//  Listens to the video playing on the Mac, keeps a rolling 3 minute
//  transcript, and every so often asks the Worker whether this is a good
//  moment to pause the video and quiz the learner.
//

import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import Speech

enum WatchAlongVoiceCommand: Equatable {
    case start
    case stop
}

/// The watch-along command this transcript speaks, or nil when it speaks none.
/// Stop is checked first so "stop watching" never starts a session.
nonisolated func watchAlongVoiceCommand(for transcript: String) -> WatchAlongVoiceCommand? {
    let transcriptWords = transcript.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { transcriptWord in
            !transcriptWord.isEmpty
        }
    let normalizedTranscript = transcriptWords.joined(separator: " ")

    if normalizedTranscript.contains("stop watching") {
        return .stop
    }
    let startPhrases = ["watch this with me", "watch with me", "watch along"]
    let transcriptStartsWatchAlong = startPhrases.contains { startPhrase in
        normalizedTranscript.contains(startPhrase)
    }
    return transcriptStartsWatchAlong ? .start : nil
}

@MainActor
final class VideoWatchAlongSession {
    private struct HeardWord {
        let word: String
        let heardDate: Date
    }

    /// One SFSpeechRecognitionTask and the request that feeds it. The task has a
    /// time limit, so the session swaps in a new run before the old one expires.
    private final class SpeechRecognitionRun {
        let request: SFSpeechAudioBufferRecognitionRequest
        var task: SFSpeechRecognitionTask?
        /// Partial results repeat the whole utterance, so this counts the words
        /// already added to the transcript.
        var ingestedWordCount = 0

        init(request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }
    }

    private static let secondsBetweenChecks: TimeInterval = 20
    private static let minimumNewWordsPerCheck = 40
    private static let secondsToWaitAfterResumingBeforeNextCheck: TimeInterval = 30
    private static let secondsBeforeRestartingSpeechRecognition: TimeInterval = 50
    private static let secondsOfTranscriptToKeep: TimeInterval = 180
    private static let browserBundleIdentifiersThatPlayVideo: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "company.thebrowser.Browser",
    ]
    private static let virtualKeyCodeForK: CGKeyCode = 40

    private let watchMomentClient: WatchMomentClient
    private let canAskQuestionNow: @MainActor () -> Bool
    private let askQuestion: @MainActor (FieldTripQuiz) -> Void

    private(set) var isRunning = false
    /// The rehearsal reads transcript lines from a file, so it has no audio to
    /// capture and no video to pause.
    private var isRehearsal = false
    private var runningTasks: [Task<Void, Never>] = []

    private var recentWords: [HeardWord] = []
    /// The newest this many words of recentWords have not been sent in a check yet.
    private var uncheckedWordCount = 0
    private var alreadyAskedQuestions: [String] = []
    private var isWaitingForQuestionToFinish = false
    private var nextAllowedCheckDate = Date.distantPast

    private var audioStream: SCStream?
    private let systemAudioFeed = SystemAudioRecognitionFeed()
    private var speechRecognizer: SFSpeechRecognizer?
    private var currentSpeechRecognitionRun: SpeechRecognitionRun?

    init(
        workerBaseURL: String,
        canAskQuestionNow: @escaping @MainActor () -> Bool,
        askQuestion: @escaping @MainActor (FieldTripQuiz) -> Void
    ) {
        self.watchMomentClient = WatchMomentClient(workerBaseURL: workerBaseURL)
        self.canAskQuestionNow = canAskQuestionNow
        self.askQuestion = askQuestion
    }

    // MARK: - Start and stop

    func start() {
        guard !isRunning else { return }
        resetStateForNewSession()
        isRunning = true

        runningTasks = [
            Task { await self.captureAndRecognizeSystemAudio() },
            Task { await self.restartSpeechRecognitionPeriodically() },
            Task { await self.checkForMomentToPausePeriodically() },
        ]
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        isRehearsal = false
        isWaitingForQuestionToFinish = false
        for runningTask in runningTasks {
            runningTask.cancel()
        }
        runningTasks = []

        systemAudioFeed.setActiveRequest(nil)
        currentSpeechRecognitionRun?.request.endAudio()
        currentSpeechRecognitionRun?.task?.cancel()
        currentSpeechRecognitionRun = nil

        let streamToStop = audioStream
        audioStream = nil
        Task {
            try? await streamToStop?.stopCapture()
        }
    }

    /// Called once the explanation has been spoken. Presses play again and starts
    /// the pause between checks.
    func resumeVideoAfterQuestion() {
        guard isRunning, isWaitingForQuestionToFinish else { return }
        isWaitingForQuestionToFinish = false
        nextAllowedCheckDate = Date().addingTimeInterval(Self.secondsToWaitAfterResumingBeforeNextCheck)
        if !isRehearsal {
            pressKToTogglePlayback(reason: "resume")
        }
    }

    private func resetStateForNewSession() {
        recentWords = []
        uncheckedWordCount = 0
        alreadyAskedQuestions = []
        isWaitingForQuestionToFinish = false
        nextAllowedCheckDate = Date.distantPast
    }

    // MARK: - Rolling transcript

    private func appendHeardWords(_ heardWords: [String]) {
        guard !heardWords.isEmpty else { return }
        let heardDate = Date()
        for heardWord in heardWords {
            recentWords.append(HeardWord(word: heardWord, heardDate: heardDate))
        }
        uncheckedWordCount += heardWords.count

        recentWords.removeAll { recentWord in
            heardDate.timeIntervalSince(recentWord.heardDate) > Self.secondsOfTranscriptToKeep
        }
        uncheckedWordCount = min(uncheckedWordCount, recentWords.count)
    }

    private func joinedText(of words: ArraySlice<HeardWord>) -> String {
        words.map { heardWord in
            heardWord.word
        }.joined(separator: " ")
    }

    // MARK: - System audio to text

    private func captureAndRecognizeSystemAudio() async {
        guard await Self.requestSpeechRecognitionAuthorization() else {
            print("Watch along: speech recognition permission was not granted")
            stop()
            return
        }
        guard let englishSpeechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              englishSpeechRecognizer.supportsOnDeviceRecognition else {
            print("Watch along: on-device English speech recognition is not available")
            stop()
            return
        }
        speechRecognizer = englishSpeechRecognizer
        startNewSpeechRecognitionRun()

        do {
            let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = shareableContent.displays.first else {
                print("Watch along: no display to capture audio from")
                stop()
                return
            }

            let streamConfiguration = SCStreamConfiguration()
            streamConfiguration.capturesAudio = true
            // Clicky's own voice must not be transcribed as part of the video.
            streamConfiguration.excludesCurrentProcessAudio = true
            streamConfiguration.sampleRate = 16000
            streamConfiguration.channelCount = 1
            // The stream needs a display, but only the audio is used, so keep the video tiny and slow.
            streamConfiguration.width = 2
            streamConfiguration.height = 2
            streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let contentFilter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: contentFilter, configuration: streamConfiguration, delegate: nil)
            try stream.addStreamOutput(
                systemAudioFeed,
                type: .audio,
                sampleHandlerQueue: DispatchQueue(label: "watch-along.system-audio")
            )
            try await stream.startCapture()

            guard isRunning, !Task.isCancelled else {
                try? await stream.stopCapture()
                return
            }
            audioStream = stream
            print("Watch along: listening to system audio")
        } catch {
            print("Watch along: could not capture system audio: \(error)")
            stop()
        }
    }

    nonisolated private static func requestSpeechRecognitionAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus == .authorized)
            }
        }
    }

    private func startNewSpeechRecognitionRun() {
        guard let speechRecognizer else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let run = SpeechRecognitionRun(request: request)

        run.task = speechRecognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString
            Task { @MainActor in
                guard let recognizedText else { return }
                self?.ingestRecognizedText(recognizedText, from: run)
            }
        }

        // The old run is not cancelled, so it can still deliver its last words.
        let previousRun = currentSpeechRecognitionRun
        currentSpeechRecognitionRun = run
        systemAudioFeed.setActiveRequest(request)
        previousRun?.request.endAudio()
    }

    private func ingestRecognizedText(_ recognizedText: String, from run: SpeechRecognitionRun) {
        let recognizedWords = recognizedText.split(whereSeparator: { character in
            character.isWhitespace
        }).map { recognizedWord in
            String(recognizedWord)
        }
        guard recognizedWords.count > run.ingestedWordCount else { return }
        let newlyRecognizedWords = Array(recognizedWords[run.ingestedWordCount...])
        run.ingestedWordCount = recognizedWords.count
        appendHeardWords(newlyRecognizedWords)
    }

    private func restartSpeechRecognitionPeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.secondsBeforeRestartingSpeechRecognition))
            guard !Task.isCancelled else { return }
            startNewSpeechRecognitionRun()
        }
    }

    // MARK: - Checking for a moment worth pausing on

    private func checkForMomentToPausePeriodically() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.secondsBetweenChecks))
            guard !Task.isCancelled else { return }
            // Awaited here, so two checks never overlap.
            await checkForMomentToPause()
        }
    }

    private func checkForMomentToPause() async {
        guard !isWaitingForQuestionToFinish,
              Date() >= nextAllowedCheckDate,
              uncheckedWordCount >= Self.minimumNewWordsPerCheck,
              canAskQuestionNow() else {
            return
        }

        let wordCountBeingChecked = uncheckedWordCount
        let transcript = joinedText(of: recentWords[...])
        let newTranscript = joinedText(of: recentWords.suffix(wordCountBeingChecked))

        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            guard let cursorScreenCapture = screenCaptures.first(where: { screenCapture in
                screenCapture.isCursorScreen
            }) ?? screenCaptures.first else {
                return
            }

            let watchMomentResponse = try await watchMomentClient.requestWatchMoment(
                transcript: transcript,
                newTranscript: newTranscript,
                alreadyAskedQuestions: alreadyAskedQuestions,
                cursorScreenJPEGData: cursorScreenCapture.imageData
            )
            guard isRunning, !Task.isCancelled else { return }

            // Words that arrived during the request stay unchecked.
            uncheckedWordCount = max(0, uncheckedWordCount - wordCountBeingChecked)

            guard let quiz = watchMomentResponse.makeQuizIfPausing() else { return }
            pauseVideoAndAskQuestion(quiz)
        } catch {
            print("Watch along: check failed: \(error)")
        }
    }

    private func pauseVideoAndAskQuestion(_ quiz: FieldTripQuiz) {
        // The learner may have started talking to Clicky while the request was in flight.
        guard canAskQuestionNow() else {
            print("Watch along: skipped a pause because Clicky became busy")
            return
        }
        if !isRehearsal {
            guard pressKToTogglePlayback(reason: "pause") else { return }
        }
        alreadyAskedQuestions.append(quiz.question)
        isWaitingForQuestionToFinish = true
        askQuestion(quiz)
    }

    // MARK: - Pausing and resuming the video

    /// "k" is YouTube's play and pause toggle. Returns false when another app is
    /// in front, because the key would go to that app instead of the video.
    @discardableResult
    private func pressKToTogglePlayback(reason: String) -> Bool {
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let frontmostBundleIdentifier,
              Self.browserBundleIdentifiersThatPlayVideo.contains(frontmostBundleIdentifier) else {
            print("Watch along: did not \(reason) the video because the frontmost app is \(frontmostBundleIdentifier ?? "unknown"), not Chrome, Safari, or Arc")
            return false
        }

        let keyEventSource = CGEventSource(stateID: .hidSystemState)
        for keyIsDown in [true, false] {
            let keyEvent = CGEvent(
                keyboardEventSource: keyEventSource,
                virtualKey: Self.virtualKeyCodeForK,
                keyDown: keyIsDown
            )
            // A held push-to-talk modifier would turn the key into a shortcut.
            keyEvent?.flags = []
            keyEvent?.post(tap: .cghidEventTap)
        }
        print("Watch along: pressed k to \(reason) the video")
        return true
    }

    // MARK: - Rehearsal without a video

    #if DEBUG
    static func rehearsalFilePath(fromLaunchArguments launchArguments: [String]) -> String? {
        guard let flagIndex = launchArguments.firstIndex(of: "--watch-along-file"),
              flagIndex + 1 < launchArguments.count else {
            return nil
        }
        return launchArguments[flagIndex + 1]
    }

    /// Feeds each line of a text file as heard speech, one line every 2 seconds,
    /// through the same check as live audio. Nothing is captured or pressed.
    func startRehearsal(fromTranscriptFileAt transcriptFilePath: String) {
        guard !isRunning else { return }
        let transcriptFileText: String
        do {
            transcriptFileText = try String(contentsOfFile: transcriptFilePath, encoding: .utf8)
        } catch {
            print("Watch along rehearsal: could not read \(transcriptFilePath): \(error.localizedDescription)")
            return
        }
        let transcriptLines = transcriptFileText.split(separator: "\n").map { transcriptLine in
            String(transcriptLine)
        }

        resetStateForNewSession()
        isRunning = true
        isRehearsal = true
        runningTasks = [
            Task { await self.feedRehearsalTranscriptLines(transcriptLines) },
            Task { await self.checkForMomentToPausePeriodically() },
        ]
        print("Watch along rehearsal: feeding \(transcriptLines.count) lines from \(transcriptFilePath)")
    }

    private func feedRehearsalTranscriptLines(_ transcriptLines: [String]) async {
        for transcriptLine in transcriptLines {
            guard !Task.isCancelled else { return }
            let wordsInLine = transcriptLine.split(whereSeparator: { character in
                character.isWhitespace
            }).map { wordInLine in
                String(wordInLine)
            }
            appendHeardWords(wordsInLine)
            try? await Task.sleep(for: .seconds(2))
        }
        print("Watch along rehearsal: all lines fed")
    }
    #endif
}

/// Receives audio buffers on ScreenCaptureKit's queue and hands them to the
/// active speech request. A lock guards the request because the session swaps it
/// on the main actor while audio keeps arriving.
nonisolated private final class SystemAudioRecognitionFeed: NSObject, SCStreamOutput, @unchecked Sendable {
    private let activeRequestLock = NSLock()
    private var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    func setActiveRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        activeRequestLock.lock()
        activeRequest = request
        activeRequestLock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let audioPCMBuffer = Self.makeAudioPCMBuffer(from: sampleBuffer) else {
            return
        }
        activeRequestLock.lock()
        let request = activeRequest
        activeRequestLock.unlock()
        request?.append(audioPCMBuffer)
    }

    private static func makeAudioPCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = sampleBuffer.formatDescription,
              var streamBasicDescription = formatDescription.audioStreamBasicDescription,
              let audioFormat = AVAudioFormat(streamDescription: &streamBasicDescription) else {
            return nil
        }
        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let audioPCMBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return nil
        }
        audioPCMBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: audioPCMBuffer.mutableAudioBufferList
        )
        return copyStatus == noErr ? audioPCMBuffer : nil
    }
}
