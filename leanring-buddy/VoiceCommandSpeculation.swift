//
//  VoiceCommandSpeculation.swift
//  leanring-buddy
//
//  A voice command started on the partial transcript at push-to-talk release. On a real press the final transcript
//  arrives about 0.55 to 0.6 seconds after the release (0.7 in a rehearsal): the microphone's 0.5 second tail, then the
//  provider's final result. The screen read is in hand after about 0.2. So once the read is in, the brain starts on the
//  words heard so far, newer partial words start it again, and the harness holds the command at its first turn until the
//  final transcript confirms those words (harness/brainloop.go). This file holds the decisions: where a transcript goes,
//  whether a partial may start a command, and whether the final keeps it.
//

import Foundation

/// Where a transcript goes. One function decides it for the final transcript and for the partial one a speculative command
/// starts on, so the two can never be routed by different rules.
nonisolated enum TranscriptRoute: Equatable {
    /// "Stop the quiz" and "quiz me on this video" keep their own phrase match.
    case videoQuizCommand(VideoQuizVoiceCommand)
    /// "Put it back" sends a pop-out or scene back into its video.
    case putTheSceneBack
    /// "Show me again" replays the narration's recorded stops with no model call.
    case replayTheExplanation
    /// "Right there" places the furniture's ghost with no model call (`RoomArtConfirmPhrase`).
    case confirmTheRoomArt
    /// "Right there" paints the shirt the room art panel previews, and "go back" returns to the preview.
    case shirtPaintedStill(ShirtStillVoiceRequest)
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
    /// A background agent is running, so "hold on" reaches the router with nothing else on screen.
    var backgroundAgentIsRunning: Bool
    /// The learner paused every agent, so "go ahead" reaches the router with nothing else on screen.
    var backgroundAgentsArePaused: Bool
    /// The narration of the pop-out on screen recorded stops, so "show me again" replays them.
    var replayStopsAreRecorded: Bool = false
    /// The furniture's ghost shows, so "right there" places it and the router takes "move it left".
    var furnitureGhostShows: Bool = false
    /// What the room art panel's shirt can do by voice, so "right there" and "go back" reach it.
    var shirtStillVoiceTargets: ShirtStillVoiceTargets = .none
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
    if replayPhraseRunsAheadOfTheRouter(
        asksToReplay: asksToReplayTheExplanation(transcript),
        stopsAreRecorded: context.replayStopsAreRecorded,
        quizQuestionIsOpen: context.phaseIsWaitingForAQuizAnswer,
        themeStudioIsOpen: context.themeStudioIsOpen
    ) {
        return .replayTheExplanation
    }
    if RoomArtConfirmPhrase.runsAheadOfTheRouter(
        matches: RoomArtConfirmPhrase.matches(transcript),
        somethingWaitsToBeConfirmed: context.furnitureGhostShows,
        quizQuestionIsOpen: context.phaseIsWaitingForAQuizAnswer,
        themeStudioIsOpen: context.themeStudioIsOpen
    ) {
        return .confirmTheRoomArt
    }
    let shirtStillRequest = shirtStillVoiceRequest(for: transcript)
    if let shirtStillRequest, shirtStillPhraseRunsAheadOfTheRouter(
        request: shirtStillRequest,
        targets: context.shirtStillVoiceTargets,
        quizQuestionIsOpen: context.phaseIsWaitingForAQuizAnswer,
        themeStudioIsOpen: context.themeStudioIsOpen
    ) {
        return .shirtPaintedStill(shirtStillRequest)
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
        backgroundAgentIsRunning: context.backgroundAgentIsRunning,
        backgroundAgentsArePaused: context.backgroundAgentsArePaused,
        furnitureGhostShows: context.furnitureGhostShows,
        phaseIsWaitingForAQuizAnswer: context.phaseIsWaitingForAQuizAnswer,
        sceneIsBuilding: context.sceneIsBuilding,
        brainTakesEveryRequest: context.brainTakesEveryRequest
    )
    return routerTakesTheTranscript ? .voiceCommandRouter : .keywordPath
}

/// A transcript's words as the partial and the final transcripts are compared: lowercase, split on whitespace, with the
/// punctuation at each word's edges dropped. Apple Speech's final transcript often adds capitals and a closing period or
/// comma to the same words, which must still count as a match. Punctuation inside a word stays, so "1:30" and "130", "1.5"
/// and "15", or "it's" and "its" are different words, and a sign or decimal point right before a letter or digit stays too,
/// so "-45" and "45" differ. A partial whose numbers differ from the final's is discarded, never run.
nonisolated func transcriptWordsForComparison(_ transcript: String) -> [String] {
    transcript.lowercased()
        .components(separatedBy: .whitespacesAndNewlines)
        .map(wordWithItsEdgePunctuationDropped)
        .filter { word in !word.isEmpty }
}

/// The punctuation that stays at the start of a word when a letter or digit follows it, as in "-45", ".5", or "'cause".
private nonisolated let punctuationThatStaysBeforeALetterOrDigit: Set<Character> = [".", ":", ",", "-", "'"]

private nonisolated func wordWithItsEdgePunctuationDropped(_ word: String) -> String {
    let characters = Array(word)
    func isALetterOrDigit(_ character: Character) -> Bool { character.isLetter || character.isNumber }
    var endIndex = characters.count
    while endIndex > 0, !isALetterOrDigit(characters[endIndex - 1]) {
        endIndex -= 1
    }
    var startIndex = 0
    while startIndex < endIndex, !isALetterOrDigit(characters[startIndex]) {
        let characterAfter = startIndex + 1 < endIndex ? characters[startIndex + 1] : nil
        if punctuationThatStaysBeforeALetterOrDigit.contains(characters[startIndex]), let characterAfter, isALetterOrDigit(characterAfter) {
            break
        }
        startIndex += 1
    }
    return String(characters[startIndex..<endIndex])
}

/// Whether a command may start on the partial transcript, once the release's screen read is in hand and each time the
/// partial transcript changes after that.
nonisolated enum SpeculativeStartStep: Equatable {
    case start
    /// These words start nothing, and newer ones may: none were heard yet, or they do not go to the router yet.
    case waitForOtherWords(reason: String)
    /// Nothing this press hears can start a command.
    case doNotStart(reason: String)
}

/// A command starts on the partial transcript only when it would go to the brain in the harness exactly as the final one
/// would: words heard, the router taking them, and no approval request waiting at the press. The harness settles an
/// approval from the transcript's own words, and a no answers a waiting request even when its card was not read, so a
/// partial "yes" or "no" must never reach one. Any request at the press blocks the start, seen or not. The harness refuses
/// such a line too.
nonisolated func speculativeStartStep(
    partialTranscript: String,
    partialRoute: TranscriptRoute,
    voiceCommandsRunInTheHarness: Bool,
    approvalAtPress: ApprovalAtPress?,
    speculationIsOn: Bool
) -> SpeculativeStartStep {
    guard speculationIsOn else { return .doNotStart(reason: "speculation is turned off") }
    guard voiceCommandsRunInTheHarness else { return .doNotStart(reason: "voice commands run on the Worker router") }
    guard approvalAtPress == nil else { return .doNotStart(reason: "an approval request is waiting, and a partial yes or no could answer it") }
    guard !transcriptWordsForComparison(partialTranscript).isEmpty else { return .waitForOtherWords(reason: "no words were heard yet") }
    guard partialRoute == .voiceCommandRouter else { return .waitForOtherWords(reason: "the partial transcript does not go to the router") }
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
/// transcript goes to the router of the brain in the harness, the held command is still running there, it uses the same
/// screen read, it has the partial's words, and the tools and scene state the command was sent with are what the app
/// would send now. A held command whose first turn failed, or whose harness exited, has already ended, and the final
/// transcript then starts a fresh command, which also launches a new harness, instead of running the failure's fallback.
nonisolated func speculationStep(
    partialTranscript: String,
    finalTranscript: String,
    finalRoute: TranscriptRoute,
    voiceCommandsRunInTheHarness: Bool,
    finalUsesTheSameScreenRead: Bool,
    commandInputsAreUnchanged: Bool,
    heldCommandIsStillRunning: Bool
) -> SpeculationStep {
    guard finalRoute == .voiceCommandRouter else { return .discard(reason: "the final transcript does not go to the router") }
    guard voiceCommandsRunInTheHarness else { return .discard(reason: "voice commands moved to the Worker router") }
    guard heldCommandIsStillRunning else { return .discard(reason: "the held command already ended in the harness") }
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
    /// The request the card showed when the learner pressed push-to-talk, and whether its whole summary had shown then. A
    /// voice answer may reach only this one. It is part of the inputs, so a final transcript whose approval state differs
    /// from the partial's discards the command, whether the request is new, gone, or has been read since.
    let approvalWhenTheCommandStarted: ApprovalAtPress?

    var offeredToolNames: Set<String> { Set(tools.map(\.name)) }
    /// The read-only tools, whose calls are lookups the model reads before it acts.
    var lookupToolNames: Set<String> { Set(tools.filter(\.readOnly).map(\.name)) }
}

/// A voice command sent to the harness: its ID, the lines it writes back, its events, and when it went out.
struct StartedHarnessVoiceCommand {
    let commandID: UUID
    let lines: HarnessVoiceCommandLines
    let events: AsyncStream<HarnessTaskEvent>
    let sentAt: Date
}

/// The release's screen read once its page read is in, which every command a press starts on its partial transcript is
/// built from, and which the final transcript builds its own inputs from too.
struct ReleaseScreenReadInHand {
    let pressCount: Int
    let frontVideoState: JSONValue?
    let pageRead: VoiceCommandPageRead
}

/// A command the harness began on a press's partial transcript, which waits for that press's final transcript.
struct SpeculativeVoiceCommand {
    let partialTranscript: String
    let screenRead: ReleaseScreenReadInHand
    let inputs: VoiceCommandInputs
    let command: StartedHarnessVoiceCommand

    var pressCount: Int { screenRead.pressCount }
}

/// Where a press is in starting a voice command on its partial transcript. CompanionManager holds one, a new press ends it,
/// newer partial words start the command again, and the press's final transcript takes it.
enum VoiceCommandSpeculationState {
    /// Nothing waits for a final transcript.
    case none
    /// The release's screen read is still coming in, and the partial transcript may start a command once it is.
    case waitingForTheScreenRead(pressCount: Int, start: Task<Void, Never>)
    /// The screen read is in, and the words heard so far start nothing, so newer partial words may.
    case waitingForWords(ReleaseScreenReadInHand)
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
        case .waitingForWords:
            return nil
        case .awaitingTheFinalTranscript(let speculativeCommand):
            return speculativeCommand
        }
    }

    /// The screen read to start a command from when the press's partial words become these, or nil when they change
    /// nothing: no read is in hand yet, the words are empty, or they are the words the waiting command started on.
    /// Apple Speech's partial words lag the audio, so the words at the release are often the first one or two, and the
    /// last partial before the final transcript is the one most likely to match it.
    func screenReadToStartFrom(whenThePartialWordsBecome partialTranscript: String) -> ReleaseScreenReadInHand? {
        let newWords = transcriptWordsForComparison(partialTranscript)
        guard !newWords.isEmpty else { return nil }
        switch self {
        case .none, .waitingForTheScreenRead:
            return nil
        case .waitingForWords(let screenRead):
            return screenRead
        case .awaitingTheFinalTranscript(let speculativeCommand):
            return newWords == transcriptWordsForComparison(speculativeCommand.partialTranscript) ? nil : speculativeCommand.screenRead
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
        case .waitingForWords(let screenRead):
            guard screenRead.pressCount == pressCount else { return nil }
            self = .none
            return nil
        case .awaitingTheFinalTranscript(let speculativeCommand):
            guard speculativeCommand.pressCount == pressCount else { return nil }
            self = .none
            return speculativeCommand
        }
    }
}

extension VoiceCommandSpeculationState {
    /// The press's dictation ended with no final transcript: it came back empty, or Apple Speech heard no speech. No final
    /// transcript will ever decide the press's command, so it comes back for the caller to discard at once, the way a final
    /// transcript with other words discards it, and a start still waiting for the screen read is cancelled. Another press's
    /// state is left as it is.
    mutating func endForAnEmptyFinalTranscript(ofPress pressCount: Int) -> SpeculativeVoiceCommand? {
        takeForTheFinalTranscript(ofPress: pressCount)
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
