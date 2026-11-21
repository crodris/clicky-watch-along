//
//  VoiceCommandTiming.swift
//  leanring-buddy
//
//  The moments of one routed voice command, so its latency is measured stage by stage. The command runs on the
//  harness brain or on the Worker router, and both record the same marks. The app logs one line when the command ends.
//

import Foundation

/// The moments of one voice command. A mark the command never reached stays nil and prints as "-".
nonisolated struct VoiceCommandTiming: Equatable, Sendable {
    /// The learner let go of push-to-talk. Nil for a command that is not timed from its press, such as a quiz scene command:
    /// its press went to the quiz answer judge first, so its transcript mark comes after the `/judge-answer` call.
    var pushToTalkReleasedAt: Date?
    /// The transcript reached the app.
    var transcriptReadyAt: Date?
    /// Everything the command reads from the screen was in hand: the front video, the page's tools and state, and the
    /// study guide check. With the read started at push-to-talk release this is earlier than the transcript.
    var screenStateReadyAt: Date?
    /// The command went to the harness, or the first request went to the Worker.
    var commandSentAt: Date?
    /// The first tool call of the model reached the app.
    var firstToolCallReceivedAt: Date?
    /// The audio of the first line the command spoke started playing.
    var firstLineAudioStartedAt: Date?
    /// Whether the finished line played the audio fetched while the calls ran, or a fetch started after them. Nil for a
    /// command that spoke no finished line, or that ran on the Worker router, which sends no early line.
    var lineAudio: VoiceCommandLineAudio?

    /// The log line's text, which starts with the first duration. A duration whose two marks are not both set is "-".
    /// It ends with `line_audio=`: `fetched_early`, `fetched_now`, or `-`.
    var logLine: String {
        let durations: [(name: String, from: Date?, to: Date?)] = [
            ("release_to_transcript_ms", pushToTalkReleasedAt, transcriptReadyAt),
            ("release_to_screen_state_ms", pushToTalkReleasedAt, screenStateReadyAt),
            ("transcript_to_request_ms", transcriptReadyAt, commandSentAt),
            ("request_to_first_call_ms", commandSentAt, firstToolCallReceivedAt),
            ("first_call_to_first_line_ms", firstToolCallReceivedAt, firstLineAudioStartedAt),
            ("release_to_first_line_ms", pushToTalkReleasedAt, firstLineAudioStartedAt),
        ]
        let durationFields = durations.map { duration in
            guard let from = duration.from, let to = duration.to else { return "\(duration.name)=-" }
            return "\(duration.name)=\(Int((to.timeIntervalSince(from) * 1000).rounded()))"
        }
        let lineAudioField: String
        switch lineAudio {
        case .theAudioFetchedEarly: lineAudioField = "line_audio=fetched_early"
        case .aFetchStartedNow: lineAudioField = "line_audio=fetched_now"
        case nil: lineAudioField = "line_audio=-"
        }
        return (durationFields + [lineAudioField]).joined(separator: " ")
    }
}

/// When one push-to-talk press was released. Its transcript counts only the release of its own press.
nonisolated struct PushToTalkRelease: Equatable, Sendable {
    let pressCount: Int
    let releasedAt: Date
}

/// Whether a release ends a press that was accepted. A press that arrives while the microphone's tail still runs is ignored,
/// and its release must neither stamp a later release time nor start a second screen read.
nonisolated struct PushToTalkPressAcceptance: Sendable {
    private var anAcceptedPressIsHeld = false

    mutating func pressWasAccepted() {
        anAcceptedPressIsHeld = true
    }

    /// True for the release of an accepted press, once. A release with no accepted press behind it is false.
    mutating func releaseEndsAnAcceptedPress() -> Bool {
        defer { anAcceptedPressIsHeld = false }
        return anAcceptedPressIsHeld
    }
}

/// Collects one command's marks. The first mark of each kind wins, since a command that falls back to the old path
/// sends twice, and it prints its line once.
@MainActor
final class VoiceCommandTimingRecorder {
    private(set) var timing: VoiceCommandTiming
    private var lineWasLogged = false

    init(pushToTalkReleasedAt: Date?, transcriptReadyAt: Date) {
        timing = VoiceCommandTiming(pushToTalkReleasedAt: pushToTalkReleasedAt, transcriptReadyAt: transcriptReadyAt)
    }

    /// Where the finished line's audio came from. A command speaks one finished line, so it is set once.
    var lineAudio: VoiceCommandLineAudio? {
        get { timing.lineAudio }
        set { timing.lineAudio = newValue }
    }

    func mark(_ moment: WritableKeyPath<VoiceCommandTiming, Date?>, at date: Date = Date()) {
        guard timing[keyPath: moment] == nil else { return }
        timing[keyPath: moment] = date
    }

    /// Prints the command's timing line, once, however many exits the command has.
    func logTheLineOnce() {
        guard !lineWasLogged else { return }
        lineWasLogged = true
        print("Voice command timing: \(timing.logLine)")
    }
}
