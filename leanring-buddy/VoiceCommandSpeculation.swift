//
//  VoiceCommandSpeculation.swift
//  leanring-buddy
//
//  A voice command started on the partial transcript at push-to-talk release. The final transcript arrives about 0.7
//  seconds after the release (the microphone's 0.5 second tail, then the provider's final result), while the screen read
//  is in hand after about 0.3. So once the read is in, the brain starts on the words heard so far, and the harness holds
//  the command at its first turn until the final transcript confirms those words (harness/brainloop.go). This file holds
//  the decisions: where a transcript goes, whether a partial may start a command, and whether the final keeps it.
//

import Foundation

/// Where a transcript goes. One function decides it for the final transcript and for the partial one a speculative command
/// starts on, so the two can never be routed by different rules.
nonisolated enum TranscriptRoute: Equatable {
    /// "Stop the quiz" and "quiz me on this video" keep their own phrase match.
    case videoQuizCommand(VideoQuizVoiceCommand)
    /// "Put it back" sends a pop-out or scene back into its video.
    case putTheSceneBack
    /// "Animate this", "let me try it", and "change my theme" run with no model call.
    case keywordBranch(KeywordBranchAheadOfTheRouter)
    /// The voice command router, on the harness brain or the Worker.
    case voiceCommandRouter
    /// A quiz answer, a scene still building, or a request with nothing on screen for the router to command.
    case keywordPath
}

/// What the route reads from the app, apart from the transcript and whether a video is in front.
nonisolated struct TranscriptRouteContext: Equatable, Sendable {
    var themeStudioIsOpen: Bool
    var phaseIsWaitingForAQuizAnswer: Bool
    var liveSceneIsUpWithNoQuizQuestion: Bool
    var sceneIsBuilding: Bool
    var sceneIsOnScreen: Bool
    var brainTakesEveryRequest: Bool
    var backgroundSceneIsReady: Bool
    var taskAnswerIsReady: Bool
    var approvalIsWaiting: Bool
}

/// The route of a transcript, checked in the order the app has always checked it. `videoIsInFront` is asked only for a
/// transcript that gets past the phrase matches and the keyword branches, since a fresh read of it is a round trip to Chrome.
nonisolated func transcriptRoute(
    for transcript: String,
    in context: TranscriptRouteContext,
    videoIsInFront: () -> Bool
) -> TranscriptRoute {
    if videoQuizPhrasesAreMatchedAheadOfTheRouter(
        themeStudioIsOpen: context.themeStudioIsOpen,
        phaseIsWaitingForAQuizAnswer: context.phaseIsWaitingForAQuizAnswer
    ), let videoQuizCommand = videoQuizVoiceCommand(for: transcript) {
        return .videoQuizCommand(videoQuizCommand)
    }
    // "Put it back" has its own tested phrase match, which keeps "put it back together" for the router.
    if asksToPutTheSceneBack(transcript), context.liveSceneIsUpWithNoQuizQuestion {
        return .putTheSceneBack
    }
    if let keywordBranch = keywordBranchAheadOfTheRouter(
        for: transcript,
        brainTakesEveryRequest: context.brainTakesEveryRequest,
        sceneIsOnScreen: context.sceneIsOnScreen,
        phaseIsWaitingForAQuizAnswer: context.phaseIsWaitingForAQuizAnswer,
        sceneIsBuilding: context.sceneIsBuilding,
        themeStudioIsOpen: context.themeStudioIsOpen
    ) {
        return .keywordBranch(keywordBranch)
    }
    let routerTakesTheTranscript = voiceCommandRouterTakesTheTranscript(
        sceneIsOnScreen: context.sceneIsOnScreen,
        videoIsInFront: videoIsInFront(),
        backgroundSceneIsReady: context.backgroundSceneIsReady,
        taskAnswerIsReady: context.taskAnswerIsReady,
        approvalIsWaiting: context.approvalIsWaiting,
        themeStudioIsOpen: context.themeStudioIsOpen,
        phaseIsWaitingForAQuizAnswer: context.phaseIsWaitingForAQuizAnswer,
        sceneIsBuilding: context.sceneIsBuilding,
        brainTakesEveryRequest: context.brainTakesEveryRequest
    )
    return routerTakesTheTranscript ? .voiceCommandRouter : .keywordPath
}

/// A transcript's words as the partial and the final transcripts are compared: lowercase, with punctuation and symbols
/// dropped and runs of whitespace taken as one break. Apple Speech's final transcript often adds capitals and punctuation
/// to the same words, which must still count as a match. Dropping a character, not breaking on it, can make two words one
/// ("left,right"), which only ever costs a discard.
nonisolated func transcriptWordsForComparison(_ transcript: String) -> [String] {
    let keptScalars = transcript.lowercased().unicodeScalars.filter { scalar in
        CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
    return String(String.UnicodeScalarView(keptScalars))
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { word in !word.isEmpty }
}

/// Whether a command may start on the partial transcript once the release's screen read is in hand.
nonisolated enum SpeculativeStartStep: Equatable {
    case start
    case doNotStart(reason: String)
}

/// A command starts on the partial transcript only when it would go to the brain in the harness exactly as the final one
/// would: words heard, the router taking them, and no request the learner may be answering. The harness settles an
/// approval from the transcript's own words, so a partial "yes" must never reach it, and the harness refuses such a line too.
nonisolated func speculativeStartStep(
    partialTranscript: String,
    partialRoute: TranscriptRoute,
    voiceCommandsRunInTheHarness: Bool,
    approvalIDSeenAtPress: String?,
    speculationIsOn: Bool
) -> SpeculativeStartStep {
    guard speculationIsOn else { return .doNotStart(reason: "speculation is turned off") }
    guard voiceCommandsRunInTheHarness else { return .doNotStart(reason: "voice commands run on the Worker router") }
    guard approvalIDSeenAtPress == nil else { return .doNotStart(reason: "an approval request may be answered") }
    guard !transcriptWordsForComparison(partialTranscript).isEmpty else { return .doNotStart(reason: "no words were heard yet") }
    guard partialRoute == .voiceCommandRouter else { return .doNotStart(reason: "the partial transcript does not go to the router") }
    return .start
}

/// What the final transcript does with a command started on the partial one.
nonisolated enum SpeculationStep: Equatable {
    /// The command goes on, and the app runs its calls as they come.
    case confirm
    /// The app cancels the command, which leaves nothing in the harness's session, and runs the final transcript the
    /// normal way.
    case discard(reason: String)
}

/// The final transcript keeps the command only when everything the command was started from still holds: the final
/// transcript goes to the router of the brain in the harness, it uses the same screen read, it has the partial's words,
/// and the tools and scene state the command was sent with are what the app would send now.
nonisolated func speculationStep(
    partialTranscript: String,
    finalTranscript: String,
    finalRoute: TranscriptRoute,
    voiceCommandsRunInTheHarness: Bool,
    finalUsesTheSameScreenRead: Bool,
    commandInputsAreUnchanged: Bool
) -> SpeculationStep {
    guard finalRoute == .voiceCommandRouter else { return .discard(reason: "the final transcript does not go to the router") }
    guard voiceCommandsRunInTheHarness else { return .discard(reason: "voice commands moved to the Worker router") }
    guard finalUsesTheSameScreenRead else { return .discard(reason: "the page the command read is gone") }
    guard transcriptWordsForComparison(partialTranscript) == transcriptWordsForComparison(finalTranscript) else {
        return .discard(reason: "the final transcript has other words")
    }
    guard commandInputsAreUnchanged else { return .discard(reason: "what the command offers changed") }
    return .confirm
}

/// What a voice command sends to the model, built from one screen read and the app's state at that moment. A command
/// started on the partial transcript is kept only when the inputs built again for the final transcript are the same.
struct VoiceCommandInputs: Equatable {
    let tools: [VoiceToolDescriptor]
    let pageState: JSONValue?
    let frontVideoState: JSONValue?
    /// The scene state the harness reads. It has no `approvalWaiting`, since the harness names the waiting request itself.
    let harnessSceneState: JSONValue
    /// The request the learner could see when they pressed push-to-talk, the only one a "yes" may answer.
    let approvalIDWaitingWhenTheCommandStarted: String?

    var offeredToolNames: Set<String> { Set(tools.map(\.name)) }
}

/// A voice command sent to the harness: its ID, the lines it writes back, its events, and when it went out.
struct StartedHarnessVoiceCommand {
    let commandID: UUID
    let lines: HarnessVoiceCommandLines
    let events: AsyncStream<HarnessTaskEvent>
    let sentAt: Date
}

/// A command the harness began on a press's partial transcript, which waits for that press's final transcript.
struct SpeculativeVoiceCommand {
    let pressCount: Int
    let partialTranscript: String
    /// The release's page read the command was built from, which the final transcript builds its own inputs from too.
    let pageRead: VoiceCommandPageRead
    let inputs: VoiceCommandInputs
    let command: StartedHarnessVoiceCommand
}

/// Where a press is in starting a voice command on its partial transcript. CompanionManager holds one, a new press ends it,
/// and the press's final transcript takes it.
enum VoiceCommandSpeculationState {
    /// No command waits for a final transcript.
    case none
    /// The release's screen read is still coming in, and the partial transcript may start a command once it is.
    case waitingForTheScreenRead(pressCount: Int, start: Task<Void, Never>)
    /// A command started on the partial transcript, held by the harness until the final transcript confirms it.
    case awaitingTheFinalTranscript(SpeculativeVoiceCommand)
}

extension VoiceCommandSpeculationState {
    /// Ends what the last press started, for a new press or a newer release: a start still waiting for the screen read is
    /// cancelled, and a command waiting for its final transcript comes back for the caller to discard.
    mutating func end() -> SpeculativeVoiceCommand? {
        defer { self = .none }
        switch self {
        case .none:
            return nil
        case .waitingForTheScreenRead(_, let startOnceTheScreenIsRead):
            startOnceTheScreenIsRead.cancel()
            return nil
        case .awaitingTheFinalTranscript(let speculativeCommand):
            return speculativeCommand
        }
    }

    /// The command the final transcript's own press started on its partial transcript, which the final transcript now keeps
    /// or discards. A start of that press still waiting for its screen read is cancelled, since the final transcript runs
    /// the normal way. Another press's state is left as it is.
    mutating func takeForTheFinalTranscript(ofPress pressCount: Int) -> SpeculativeVoiceCommand? {
        switch self {
        case .none:
            return nil
        case .waitingForTheScreenRead(let pressCountWaiting, let startOnceTheScreenIsRead):
            guard pressCountWaiting == pressCount else { return nil }
            startOnceTheScreenIsRead.cancel()
            self = .none
            return nil
        case .awaitingTheFinalTranscript(let speculativeCommand):
            guard speculativeCommand.pressCount == pressCount else { return nil }
            self = .none
            return speculativeCommand
        }
    }
}

/// How a timed voice command relates to speculation, for its timing line.
nonisolated enum VoiceCommandSpeculationOutcome: Equatable, Sendable {
    /// The command started on the partial transcript and the final one kept it.
    case kept
    /// A command started on the partial transcript and the final one discarded it, so this command is the final one's.
    case discarded
}

/// The switch for starting voice commands on the partial transcript. It is on, and a Debug build launched with
/// `--no-voice-command-speculation` turns it off, so a run can measure the same commands both ways. This is the one place
/// that reads it.
nonisolated enum VoiceCommandSpeculation {
    static let debugLaunchArgumentThatTurnsItOff = "--no-voice-command-speculation"

    static func isOn(launchArguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        if launchArguments.contains(debugLaunchArgumentThatTurnsItOff) { return false }
        #endif
        return true
    }
}
