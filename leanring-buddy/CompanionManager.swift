//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

/// Whether Escape, with no scene on screen, has an answer to stop. A question still being transcribed is
/// left alone, and an answer whose cursor flies to its target counts before its speech starts playing.
func escapeHasAnAnswerToStop(
    voiceState: CompanionVoiceState,
    speechIsPlaying: Bool,
    dictationIsInProgress: Bool,
    cursorIsPointingForTheAnswer: Bool
) -> Bool {
    if dictationIsInProgress {
        return false
    }
    return voiceState == .processing || voiceState == .responding || speechIsPlaying || cursorIsPointingForTheAnswer
}

/// The voice state after a panel closed and stopped its own spoken line, the Theme Studio card's or the room art panel's.
/// The line's task never resets `.responding` once it is cancelled, so the close does it, but only when the stop reached
/// that panel's own line, since audio still playing is another answer, such as one the router handed off with the panel
/// open, and that answer keeps its state.
func voiceStateAfterAPanelStoppedItsLine(_ voiceState: CompanionVoiceState, theStopReachedThePanelsLine: Bool) -> CompanionVoiceState {
    guard theStopReachedThePanelsLine, voiceState == .responding else { return voiceState }
    return .idle
}

#if DEBUG
/// In a rehearsal "?" step, "{answer}" becomes the open question's answer label, since the plan picks a new
/// question each run.
func rehearsalTranscript(_ transcript: String, answeringWith answerLabel: String) -> String {
    transcript.replacingOccurrences(of: "{answer}", with: answerLabel.lowercased())
}

/// A rehearsal step that starts with "+N " waits N more seconds before it is spoken, so a recorded take can land a
/// request on a chosen moment of a playing video. Returns the wait and the step without its prefix. A wait that is not
/// a finite number of seconds up to 10 minutes leaves the step as it is, since a larger one overflows the sleep.
/// Steps written as "a | b" keep the spaces around the bar, so the step is trimmed first, or no prefix after the first step is read.
func rehearsalStepWait(_ untrimmedRehearsalStep: String) -> (waitSeconds: Double, step: String) {
    let rehearsalStep = untrimmedRehearsalStep.trimmingCharacters(in: .whitespaces)
    guard rehearsalStep.hasPrefix("+"),
          let spaceIndex = rehearsalStep.firstIndex(of: " "),
          let waitSeconds = Double(rehearsalStep[rehearsalStep.index(after: rehearsalStep.startIndex)..<spaceIndex]),
          waitSeconds.isFinite, waitSeconds > 0, waitSeconds <= 600 else {
        return (0, rehearsalStep)
    }
    return (waitSeconds, String(rehearsalStep[rehearsalStep.index(after: spaceIndex)...]))
}

/// What a rehearsal step's first character asks for, read after any "+N " wait.
enum RehearsalStepPrefix: Character, Equatable {
    /// "~": the next step follows 6 seconds later, while this one is still going.
    case nextStepInterruptsThisOne = "~"
    /// "?": wait for a video quiz question to be asked, then answer it.
    case waitsForAQuestion = "?"
    /// "&": wait for every background agent and what their endings set off.
    case waitsForTheBackgroundAgents = "&"
    /// "^": press push-to-talk 0.3 seconds after this step's voice_command line goes to the harness, as a learner who
    /// interrupts the command would.
    case pressesPushToTalkDuringTheCommand = "^"
    /// "%": a partial transcript stands in for the words heard at the release, as a microphone would give, so the voice
    /// command can start on it before the final transcript ("%partial >> final", or "%words" when both are the same).
    case hearsAPartialTranscriptFirst = "%"
    /// "@x,y,width,height words": while push-to-talk is held, the real mouse circles that rect (global points, origin at the
    /// top left of the main display) in about 1.2 seconds, as a learner circling a picture would, then the words are spoken.
    case circlesARegionFirst = "@"
}

/// The partial and final transcripts of a "%" step: the words before " >> " are heard at the release and the words after
/// it are the final transcript, and a step with no " >> " hears the same words both times.
func rehearsalPartialAndFinalTranscripts(_ transcript: String) -> (partial: String, final: String) {
    guard let separatorRange = transcript.range(of: " >> ") else { return (transcript, transcript) }
    return (String(transcript[..<separatorRange.lowerBound]), String(transcript[separatorRange.upperBound...]))
}

/// The port of the local Worker a Debug build calls: 8787, or the whole number of 1024 to 65535 after `--worker-port`.
func debugWorkerPort(launchArguments: [String]) -> Int {
    guard let flagIndex = launchArguments.firstIndex(of: "--worker-port"),
          launchArguments.indices.contains(flagIndex + 1),
          let port = Int(launchArguments[flagIndex + 1]),
          (1024...65535).contains(port) else {
        return 8787
    }
    return port
}

/// The step's prefix, or nil, and the words spoken without it.
func rehearsalStepPrefix(_ rehearsalStep: String) -> (prefix: RehearsalStepPrefix?, transcript: String) {
    guard let firstCharacter = rehearsalStep.first, let prefix = RehearsalStepPrefix(rawValue: firstCharacter) else {
        return (nil, rehearsalStep)
    }
    return (prefix, String(rehearsalStep.dropFirst()))
}
#endif

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    /// Always true when the transcription provider does not use Speech Recognition (see `speechRecognitionPermissionIsSatisfied`).
    @Published private(set) var hasSpeechRecognitionPermission = false
    /// Chrome control is optional: only the video features need it, so it never blocks `allPermissionsGranted`.
    @Published private(set) var chromeAutomationPermissionStatus: ChromeAutomationPermissionStatus = .notAskedYet

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// How long the buddy stays on the detected element. A 3D scene part holds until its narration ends.
    @Published var detectedElementPointingHold: BuddyPointingHold = .briefly
    /// The cursor's slide along the video's progress bar before a voice seek, which BlueCursorView plays.
    let cursorScrubController = CursorScrubController()
    /// Counts up each time an instant replay stops the buddy where it is, which BlueCursorView observes.
    @Published private(set) var buddyFreezeCount = 0
    /// The cursor's latest nod, shake, or hop, which BlueCursorView plays. Set only through `playCursorEmote`.
    @Published private(set) var cursorEmoteRequest: CursorEmoteRequest?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Base URL for the Cloudflare Worker proxy. All API requests route
    /// through this so keys never ship in the app binary.
    #if DEBUG
    /// A launch with `--worker-port <port>` uses a local Worker on that port, so a verify run can use its own Worker while
    /// another checkout's holds 8787. Not private, since other files (the panel's setup page) read it too.
    static let workerBaseURL = "http://127.0.0.1:\(debugWorkerPort(launchArguments: ProcessInfo.processInfo.arguments))"
    #else
    // The upstream placeholder is an unowned host, so a release build must not
    // compile until it has a real https Worker URL for screenshots to go to.
    #error("Set workerBaseURL to your own https Worker before building Release.")
    #endif

    private lazy var claudeAPI: ClaudeAPI = {
        return ClaudeAPI(proxyURL: "\(Self.workerBaseURL)/chat", model: selectedModel)
    }()

    private lazy var elevenLabsTTSClient: ElevenLabsTTSClient = {
        return ElevenLabsTTSClient(proxyURL: "\(Self.workerBaseURL)/tts")
    }()

    private lazy var liveSceneClient: LiveSceneClient = {
        LiveSceneClient(workerBaseURL: Self.workerBaseURL)
    }()

    private lazy var studyGuideClient = StudyGuideClient(workerBaseURL: Self.workerBaseURL)
    /// The Notion page and guide JSON written for each video, filed under the video's URL when its guide was started,
    /// so a revise or an open finds it later.
    private let savedStudyGuides = SavedStudyGuides(userDefaults: .standard)
    /// The hold that keeps the blue cursor on a quiz question's "?" label, so only the end of that question releases it.
    private var quizQuestionPointingID: UUID?
    /// The one hold an instant replay points the buddy with, so only the replay releases it.
    private let instantReplayPointingID = UUID()
    private let instantReplayPanelController = InstantReplayPanelController()
    /// The pointing stops of the latest narration of the pop-out on screen, played again with no model call.
    private lazy var instantReplay = InstantReplayController(stage: InstantReplayStage(
        focusStop: { replayStop in LiveSceneOverlay.shared.focusReplayStop(replayStop) },
        endFocus: { LiveSceneOverlay.shared.endFocus() },
        showStopNumbers: { partLabels, pathReachesStop in
            LiveSceneOverlay.shared.showReplayStopNumbers(partLabels: partLabels, pathReachesStop: pathReachesStop)
        },
        hideStopNumbers: { LiveSceneOverlay.shared.hideReplayStopNumbers() },
        labelScreenPointOnceTheCameraSettles: { partLabel in
            await LiveSceneOverlay.shared.partLabelScreenPointsOnceTheCameraSettles().first { labelScreenPoint in labelScreenPoint.label == partLabel }
        },
        pointTheCursor: { [unowned self] labelScreenPoint, sentence in
            self.pointTheBuddyForTheReplay(at: labelScreenPoint, sentence: sentence)
        },
        freezeTheCursor: { [unowned self] in
            // Only the replay's own pointing is stopped, so a cursor pointing for an answer keeps its own fly-back.
            guard cursorPointsForTheReplay(pointingHold: self.detectedElementPointingHold, replayPointingID: self.instantReplayPointingID) else { return }
            self.buddyFreezeCount += 1
        },
        releaseTheCursor: { [unowned self] in self.releaseTheBuddyTheReplayFroze() },
        clearTheFocus: { LiveSceneOverlay.shared.highlightPart(labelText: "") },
        reduceMotionIsOn: { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        sleep: { seconds in try await Task.sleep(for: .seconds(seconds)) },
        showControl: { [unowned self] controlVersion in self.showTheInstantReplayControl(controlVersion: controlVersion) },
        hideControl: { [unowned self] in self.instantReplayPanelController.hide() }
    ))
    /// The Chrome tab each Notion page opened in, a guide's or a task agent's, so open_study_guide switches to it
    /// instead of opening the page twice.
    private var notionPageChromeTabIDsByPageURL: [URL: Int] = [:]
    /// Saved guides whose page Notion confirmed since launch, so the check costs one Worker call per guide per launch.
    private var studyGuidePageHandlesFoundInNotion: Set<String> = []
    /// The task of each running background agent, keyed by the agent's id, so several run at once and the agent list
    /// cancels one by its id. They are not currentResponseTask, because a push-to-talk press cancels that task and must
    /// not cancel work in the background.
    private var backgroundAgentTasks: [UUID: Task<Void, Never>] = [:]
    /// The 3D model or experiment that finished building last and has not been shown yet. It waits here when the
    /// screen was busy as it finished, until the learner says "show the model" or "show the experiment".
    private var readyBackgroundScene: ReadyBackgroundScene?
    private lazy var taskAgentClient = TaskAgentClient(workerBaseURL: Self.workerBaseURL)
    /// The Go helper process that runs every task agent's loop. The app answers the tools it asks for.
    private lazy var agentHarness: AgentHarness = {
        let agentHarness = AgentHarness(workerBaseURL: Self.workerBaseURL)
        agentHarness.approvalDesk.onRequestArrived = { [weak self] approvalRequest in
            self?.showTheApprovalRequest(approvalRequest)
        }
        agentHarness.approvalDesk.onWaitingRequestsChanged = { [weak self] waitingRequests in
            self?.syncTheApprovalWaitingState(waitingRequests)
        }
        // The panel's banner shows the card too, so a request that becomes the oldest while it is open needs no list.
        agentHarness.approvalDesk.listIsShowing = { [weak self] in
            guard let self else { return false }
            return self.agentListPanelController.isOpen || self.menuPanelShowsTheApprovalCard()
        }
        // Once a request is settled, its agent's disc turns the "!" into a check or a gray dash for a moment, and the ended
        // card Glides back into that disc when its time in the list runs out.
        agentHarness.approvalDesk.onACardEnded = { [weak self] endedCard, ending in
            self?.showTheApprovalSettledMark(agentTokenApprovalSettledMark(for: ending), onTheDiscOf: endedCard.request.taskID)
        }
        agentHarness.approvalDesk.onAnEndedCardLeft = { [weak self] endedCard in
            self?.agentListPanelController.glideTheEndedApprovalCardIntoItsDisc(endedCard)
        }
        agentHarness.approvalDesk.onOldestRequestNeedsShowing = { [weak self] approvalRequest in
            self?.agentListPanelController.openForAnApprovalRequest(fromAgentID: approvalRequest.taskID)
        }
        // The harness's gate takes the first answer to a request, a click's or a voice answer's, and says which one won.
        agentHarness.approvalDesk.onApprovalSettled = { approved, scope in
            let settledAnswer = ApprovalVoiceAnswer(approved: approved, scope: scope)
            VoiceToolCallChip.shared.show(settledAnswer.chipPhrase)
        }
        return agentHarness
    }()
    /// The request a voice answer from the latest push-to-talk press may reach: the one the card showed at the press,
    /// while it is still the oldest waiting. The brain takes the command and offers `answer_approval` only for this one,
    /// and the harness's gate settles it: a no at once, and a yes only when `wholeSummaryWasSeen`.
    private var approvalAtThePressStillWaiting: ApprovalAtPress? {
        guard let approvalAtThePress,
              agentHarness.approvalDesk.oldestWaitingRequest?.approvalID == approvalAtThePress.approvalID else { return nil }
        return approvalAtThePress
    }

    /// The text of the chip that says an agent needs the learner's OK, so answering hides that chip and never a newer one.
    private var approvalWaitingChipPrimaryText: String?
    /// What the newest finished task agent found. It is read aloud only when the learner asks, so it never talks over
    /// the video, and it stays so they can ask again.
    private var readyTaskAnswer: String?
    /// The task agent whose answer `readyTaskAnswer` holds, so its token leaves once the answer is heard or replaced.
    private var readyTaskAnswerAgentID: UUID?
    /// True until the newest answer is heard. Only then does the router take a command with no video or scene in front,
    /// so once it is heard a plain question goes back to the quick path instead of a voice command call.
    private var taskAnswerWaitsToBeHeard = false
    /// The quiz video a miss landed on while that video's guide was being written, keyed by the video's key. That guide
    /// read its quiz results when it started, so the quiz video's guide is refreshed once that guide is written, while
    /// the quiz video is still in front. After a failure, a cancel, or a tab switch the refresh is dropped, and the miss
    /// reaches the page only with the video's next refresh or revise.
    private var studyGuideRefreshIsDueForQuizVideoURLByVideoKey: [String: String] = [:]
    /// How many refreshes are checking their page in Notion before their guide agent starts, so a rehearsal step that
    /// waits for the agents does not run in between. A count, since refreshes for two videos can check at once.
    private var studyGuideRefreshesBeingChecked = 0
    /// The theme the learner picked in the menu bar panel or the settings dial, the one source of truth for it.
    let themeSettings = CompanionThemeSettings()
    /// The loop around the video or image a request looks at, which the cursor overlay draws.
    let cursorLoopController = CursorLoopController()
    /// Records the mouse while push-to-talk is held, so a loop drawn around something names the picture for that request.
    private let mousePathRecorder = MousePathRecorder()
    /// The loop the learner drew while holding push-to-talk, with the press it belongs to, so only that press's request reads it.
    private var circledRegionOfThePress: (pressCount: Int, circledRegion: CircledRegion)?
    /// What Clicky works on in the background, shown as tokens beside the notch and in the agent list.
    private(set) lazy var backgroundAgentStore = BackgroundAgentStore(themeSettings: themeSettings)
    private lazy var agentListPanelController = AgentListPanelController(
        store: backgroundAgentStore,
        themeSettings: themeSettings,
        approvalDesk: agentHarness.approvalDesk,
        actions: AgentListActions(
            cancelAgent: { [weak self] agentID in self?.cancelBackgroundAgent(agentID) },
            showReadyScene: { [weak self] in
                guard let self, agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: self.videoQuizQuestionIsActive) else { return }
                self.startShowingTheReadyBackgroundScene()
            },
            hearTaskAnswer: { [weak self] in
                guard let self, agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: self.videoQuizQuestionIsActive) else { return }
                self.startSpeakingTheTaskAnswer()
            },
            tryAgain: { [weak self] agentID in self?.tryTheBackgroundAgentAgain(agentID) },
            answerApproval: { [weak self] approvalID, approved, scope in
                self?.agentHarness.approvalDesk.answerByClick(approvalID: approvalID, approved: approved, scope: scope, on: .agentList)
            }
        )
    )
    /// The discs floating beside the notch, one per running agent or waiting result. A click opens the agent list under it.
    private lazy var agentTokenDockController = AgentTokenDockController(
        store: backgroundAgentStore,
        themeSettings: themeSettings,
        menuActions: .holdingAWaitingResultDuringAQuizQuestion(
            aVideoQuizQuestionIsOpen: { [weak self] in self?.videoQuizQuestionIsActive ?? false },
            cancelAgent: { [weak self] agentID in self?.cancelBackgroundAgent(agentID) },
            showReadyScene: { [weak self] in self?.startShowingTheReadyBackgroundScene() },
            hearTaskAnswer: { [weak self] in self?.startSpeakingTheTaskAnswer() },
            // The same path as the agent list's "Try again", which checks again whether the work may start now.
            tryAgain: { [weak self] agentID in self?.tryTheBackgroundAgentAgain(agentID) }
        )
    ) { [weak self] click in
        self?.agentListPanelController.toggle(from: click.discID, discPanelFrame: click.discPanelFrame, on: click.screen, opensOnly: click.opensOnly)
    }
    /// The radial settings dial that holding shift + option opens. Its Agents slice opens the agent list.
    private let settingsDialController = SettingsDialController()
    /// "Change my theme": the card with three theme ideas, previewed on the real cursor and saved by voice or click.
    private lazy var themeStudioController: ThemeStudioController = {
        let themeIdeasClient = ThemeIdeasClient(workerBaseURL: Self.workerBaseURL)
        return ThemeStudioController(
            themeSettings: themeSettings,
            environment: ThemeStudioController.Environment(
                speak: { [weak self] line in
                    // A failed design is also a red Callout, so the failure never rests on the voice alone. While the card stays
                    // open with its old ideas, the card's own red-tinted row says it, so the chip would say it twice.
                    let lineIsAFailure = line == ThemeStudioController.couldNotDesignLine
                    if lineIsAFailure, self?.themeStudioController.showsTheDesignFailedNotice != true {
                        VoiceToolCallChip.shared.show("Couldn't design that one", sender: .failure)
                    }
                    self?.speakAThemeStudioLine(line, isAFailure: lineIsAFailure)
                },
                stopSpeaking: { [weak self] in self?.stopTheThemeStudioSpeech() },
                playSound: { sound in sound.play() },
                captureThePicture: { [weak self] in await self?.captureThePictureForTheThemeStudio() },
                designIdeas: { themeIdeasRequest in try await themeIdeasClient.designIdeas(for: themeIdeasRequest) }
            ),
            cardPresenter: ThemeStudioPanelController(pictureTheLoopIsAround: { [weak self] in
                // The picture a design from a picture reads, which the loop is already around when the card opens. A design
                // with no picture opens next to the mouse, wherever a loop is.
                guard let self, self.themeDesignReadsAPicture else { return nil }
                return self.cursorLoopController.mediaTheRequestLoopIsAroundInAppKitCoordinates
            }, onSaveClicked: { saveOutcome in
                // The voice tool's chip comes from the router, so only a click on Save needs its own.
                guard let chipPhrase = saveOutcome.chipPhraseAfterAClickOnSave else { return }
                let chipSender: VoiceToolCallChipSender
                if case .failed = saveOutcome { chipSender = .failure } else { chipSender = .voiceToolCall }
                VoiceToolCallChip.shared.show(chipPhrase, sender: chipSender)
            })
        )
    }()
    /// The "Add theme?" card shown before a theme file the learner opened is installed.
    private lazy var themeInstallConfirmation = ThemeInstallConfirmation(
        cardPresenter: ThemeInstallCardPanelController(),
        install: { [weak self] confirmedInstall in self?.installTheConfirmedThemePackage(confirmedInstall) }
    )
    private var themeStudioSpeechTask: Task<Void, Never>?
    /// "Show me how this would look in my room" and "could I see this shirt on me": the live camera panel with the item on
    /// Chrome's front tab on the learner's wall or floor, or a shirt painted on the learner.
    private lazy var roomArtPreviewController = RoomArtPreviewController(environment: .live(
        workerBaseURL: Self.workerBaseURL,
        clearTheLiveScene: { [weak self] in self?.clearTheLiveSceneForTheRoomArtPanel() },
        // The controller says which lines report a failure, so the cursor shakes as each is said. "Here it is" and the
        // shirt's coaching do not.
        speak: { [weak self] line, isAFailure in self?.speakARoomArtLine(line, isAFailure: isAFailure) },
        loopAccentColor: { [weak self] in self?.themeSettings.shownTheme.cursorColor ?? DS.Colors.overlayCursorBlue },
        loopTracerLook: { [weak self] in
            self.map { CursorLoopTracerLook(theme: $0.themeSettings.shownTheme, picture: $0.themeSettings.shownThemePicture) }
        },
        endTheSpokenLine: { [weak self] in self?.stopTheRoomArtSpeech() },
        // A painting or a return to the live camera, by voice or by its button, or the furniture placed by voice or the Place
        // button or moved by voice, is this request's own, so its line is not dropped.
        theLearnerAskedThePanel: { [weak self] in
            guard let self else { return }
            self.roomArtRequest.continued(atPushToTalkPressCount: self.pushToTalkPressCount)
        },
        showTheChip: { phrase, isAFailure in
            VoiceToolCallChip.shared.show(phrase, sender: isAFailure ? .failure : .voiceToolCall)
        },
        thePanelOpened: { [weak self] in self?.cursorLoopController.theRoomArtPanelOpened() }
    ))
    /// The room art line waiting for its turn or playing. A new line replaces it, and every close of the panel ends it.
    private var roomArtSpeechTask: Task<Void, Never>?
    /// The playback token of the room art's own spoken line, so a close stops that exact line and never a newer answer.
    private var roomArtLineToken: SpokenLineToken?
    /// The newest room art request: its press count, so a line that lands after a newer press is dropped, and whether it
    /// still reads the page and its picture, which holds the thinking state until the panel opens.
    private var roomArtRequest = RoomArtRequestRecord()
    /// The playback token of the studio's own spoken line, so closing the card stops that exact line and never an unrelated
    /// answer that is playing when the card closes. Once the line has ended, the token matches nothing and stops nothing.
    private var themeStudioLineToken: SpokenLineToken?
    /// How many times push-to-talk has been pressed, which tells a studio line whether the learner made a request after the
    /// current design started (`themeStudioLineMayStart`).
    private var pushToTalkPressCount = 0
    private var pushToTalkPressCountWhenTheThemeDesignStarted = 0
    /// When the last press was released, which the press's transcript reads to time its voice command.
    private var lastPushToTalkRelease: PushToTalkRelease?
    /// Whether the press being released was accepted, so the release of a press ignored during the microphone's tail
    /// stamps no release time and starts no screen read.
    private var pushToTalkPressAcceptance = PushToTalkPressAcceptance()
    /// What a voice command reads from the screen, started when push-to-talk is released so it overlaps the microphone's tail
    /// and the transcript's finalization. The one owner of that read: a press clears it, a release starts it, and the
    /// transcript of the same press takes it (`screenReadForTheTranscript`).
    private var voiceCommandScreenRead: VoiceCommandScreenRead?
    private var voiceCommandScreenReadTask: Task<Void, Never>?
    /// The voice command a press started on its partial transcript once the release's screen read was in, which the final
    /// transcript of that press confirms or discards (`VoiceCommandSpeculation.swift`). A new press discards it.
    private var voiceCommandSpeculation: VoiceCommandSpeculationState = .none
    #if DEBUG
    /// The partial transcript a rehearsal step stands in for, since a rehearsal runs no microphone (a "%" step).
    private var rehearsalPartialTranscript: String?
    #endif
    private static let backgroundAgentChipSecondsOnScreen: TimeInterval = 4
    #if DEBUG
    /// How many voice_command lines went to the harness, which a rehearsal "^" step waits on before it presses.
    private var harnessVoiceCommandsSent = 0
    #endif

    #if DEBUG
    private lazy var voiceToolDebugServer = VoiceToolDebugServer(
        listTools: { [weak self] in
            await self?.voiceToolsForTheDebugServer() ?? []
        },
        callTool: { [weak self] toolName, toolInput in
            await self?.runVoiceToolFromTheDebugServer(toolName: toolName, toolInput: toolInput)
                ?? .failed(error: "Clicky is shutting down", state: nil)
        },
        answerApproval: { [weak self] approvalID, approved, scope in
            self?.agentHarness.answerApproval(approvalID: approvalID, approved: approved, scope: scope) ?? false
        }
    )
    #endif

    private var liveScenePhase: LiveScenePhase = .idle
    /// Set each time a page plays, so narration uses Clicky's own data about the page on screen.
    var liveScenePageOnScreen: LiveScenePageOnScreen?
    /// Bumped on every new question so a scene request still in flight cannot play late.
    private var liveSceneRequestGeneration = 0
    private var liveSceneRequestTask: Task<Void, Never>?
    private var liveSceneTourFinishedTask: Task<Void, Never>?
    /// The lesson of the simulation on screen: its prediction question, the learner's guess, and how far it got.
    /// Made when a simulation page plays, and cleared with the scene.
    var simulationLesson: SimulationLesson?
    /// What Clicky says after a run. A newer run's line replaces it.
    private var simulationRunNarrationTask: Task<Void, Never>?

    /// The Card that sums up a quiz when it ends, and recaps a video when it ends.
    private let videoQuizSummaryPanelController = VideoQuizSummaryPanelController()
    /// True from the moment a video's end starts to gather the discs until the Card shows, so nothing else starts meanwhile.
    private var videoRecapIsGatheringTheDiscs = false
    /// Set by a press, Escape, or a scene starting while the discs gather, so the Card does not unfold over what came next.
    private var videoRecapGatherWasCancelled = false
    /// Watches the front tab for the end of a video that has a quiz or a guide, and asks for its recap.
    private lazy var videoRecapWatcher = VideoRecapWatcher(
        chromeIsTheFrontApp: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome" },
        clickyIsBusy: { [weak self] in
            guard let self else { return true }
            return self.clickyIsBusyForAVideoRecapCard || self.videoRecapIsGatheringTheDiscs
        },
        readTheFrontTabURL: { try await ChromeFrontTabAppleEvents.frontTabURLOffTheMainActor() },
        readTheFrontVideo: { try await ChromeFrontTabAppleEvents.frontVideoEndReadingOffTheMainActor() },
        recapForVideo: { [weak self] videoURL in self?.videoRecap(forVideoURL: videoURL) },
        showTheRecapAtTheEnd: { [weak self] recap, videoURL in self?.showTheRecapAtTheEndOfTheVideo(recap, videoURL: videoURL) }
    )
    private lazy var videoQuizSession = VideoQuizSession(
        workerBaseURL: Self.workerBaseURL,
        canAskQuestionNow: { [weak self] in
            guard let self else { return false }
            switch self.liveScenePhase {
            case .idle, .allLabelsShowing:
                // A finished scene stays up until the next press, and the video is already paused.
                return self.voiceState == .idle && !self.elevenLabsTTSClient.isPlaying
            default:
                return false
            }
        },
        askQuestion: { [weak self] quiz, framePopout in
            self?.askVideoQuizQuestion(quiz, framePopout: framePopout)
        },
        speakLine: { [weak self] line, isAFailure in
            self?.speakVideoQuizLine(line, isAFailure: isAFailure)
        }
    )
    /// True from the moment a video quiz question is asked until its explanation
    /// has been spoken and the video has been resumed.
    private var videoQuizQuestionIsActive = false {
        didSet { backgroundAgentStore.aVideoQuizQuestionIsOpen = videoQuizQuestionIsActive }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var partialTranscriptCancellable: AnyCancellable?
    /// The approval request the card showed when the learner last pressed push-to-talk, or a rehearsal step stood in for
    /// a press, and whether its whole summary had shown for a second then. A voice answer can reach only this request.
    private var approvalAtThePress: ApprovalAtPress?
    private var escapeKeyCancellable: AnyCancellable?
    private var settingsDialCancellable: AnyCancellable?
    /// Keeps `DS.Move.themeSprings` equal to the shown theme's springs, the studio's preview included.
    private var themeSpringsCancellable: AnyCancellable?
    private var pinchCancellable: AnyCancellable?
    private var scrollWheelCancellable: AnyCancellable?
    private var cursorLoopVoiceStateCancellable: AnyCancellable?
    private var cursorLoopAgentSparksCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode - cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when every required permission (accessibility, screen recording, the screen content check, microphone,
    /// and Speech Recognition when the provider uses it) is granted. Used by the panel to show a single "all good" state.
    /// Chrome control is not required, since only the video features use it.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
            && hasSpeechRecognitionPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = ClaudeVoiceModel.latestModelID(
        forStoredModelID: UserDefaults.standard.string(forKey: "selectedClaudeModel")
    )

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAPI.model = model
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        LiveSceneOverlay.shared.mapTilesWorkerBaseURL = Self.workerBaseURL
        // A voice tool call's chip takes the accent of the theme on screen, preview included.
        VoiceToolCallChip.shared.themeAccentProvider = { [weak self] in
            self?.themeSettings.shownTheme.cursorColor ?? DS.Colors.overlayCursorBlue
        }
        themeSpringsCancellable = themeSettings.observeShownMoveSprings { shownSprings in
            DS.Move.themeSprings = shownSprings
            print("Theme motion: Pop \(shownSprings.pop.response) and \(shownSprings.pop.dampingFraction), Glide \(shownSprings.glide.response) and \(shownSprings.glide.dampingFraction), Point \(shownSprings.pointResponse)")
        }
        agentTokenDockController.start()
        // The brain runs in the harness process, so the first voice command must not pay its launch.
        agentHarness.prewarm()
        // The harness takes the secret from its environment when it starts, and its model calls need it. With none set, every
        // voice command fails in the harness and takes the router failure fallback.
        if !ClickyAppSecret.isSet() {
            print("Brain: no app secret, so voice commands take the router failure fallback until the clickyAppSecret default is set (defaults write com.crodris.clicky-watch-along clickyAppSecret <secret>) and Clicky restarts")
        }
        #if DEBUG
        // Off unless asked for, since any process on this Mac can reach a loopback port.
        if CommandLine.arguments.contains("--voice-tool-debug-server") {
            voiceToolDebugServer.start()
        }
        #endif
        LiveSceneOverlay.shared.onTourFinished = { [weak self] in
            self?.handleLiveSceneTourFinished()
        }
        LiveSceneOverlay.shared.onASceneStartedToShow = { [weak self] in
            self?.cursorLoopController.end(because: .aSceneStartedToShow)
            // A new scene can replace one with no clear first, so the old scene's replay stops and control go with it.
            self?.instantReplay.forget()
            // A scene rises over the video the quiz summary sits on, so the Card goes back into the video.
            self?.cancelTheVideoRecapGather()
            self?.videoQuizSummaryPanelController.close(animated: true)
        }
        LiveSceneOverlay.shared.onPartTapped = { [weak self] untrustedTappedLabel in
            guard let self else { return }
            // During a replay a click on a stop's label steps there, instead of starting a new, paid explanation.
            if self.instantReplay.goToStop(partLabel: untrustedTappedLabel) { return }
            self.explainTheTappedPart(untrustedTappedLabel: untrustedTappedLabel)
        }
        LiveSceneOverlay.shared.onReplayStopTapped = { [weak self] untrustedStopIndex in
            guard let self, !self.videoQuizQuestionIsActive else { return }
            self.instantReplay.goToStop(index: untrustedStopIndex)
        }
        videoQuizSession.onQuizEnded = { [weak self] _ in
            self?.showTheVideoQuizSummary()
        }
        // An ended approval card Glides back into its agent's disc, which only the dock knows.
        agentListPanelController.discCenterOfTheAgent = { [weak self] agentID, displayID in
            self?.agentTokenDockController.discCenter(ofTheAgent: agentID, onDisplay: displayID)
        }
        // The discs a video's end gathered at the cursor go back when the Card closes, however it closes.
        videoQuizSummaryPanelController.onClosed = { [weak self] glideOrigin in
            self?.agentTokenDockController.sendTheDiscsBack(from: glideOrigin)
        }
        videoQuizSession.onProgressChanged = { [weak self] progress in
            self?.videoQuizProgress = progress
        }
        LiveSceneOverlay.shared.accentHexForTheNextPage = { [weak self] in
            self?.themeSettings.shownTheme.cursorColorHex ?? DS.Colors.overlayCursorBlueHex
        }
        LiveSceneOverlay.shared.onPageError = { [weak self] pageErrorText in
            self?.handleLiveScenePageError(pageErrorText)
        }
        LiveSceneOverlay.shared.onSimulationRunFinished = { [weak self] runReport in
            self?.narrateTheSimulationRun(runReport)
        }
        LiveSceneOverlay.shared.onSimulationGuessSkipped = { [weak self] in
            guard let self, self.simulationLesson?.guess == .waiting else { return }
            self.simulationLesson?.guess = .skipped
            print("Simulation: the learner skipped the guess")
        }
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindPartialTranscriptsToTheVoiceCommandSpeculation()
        bindPinchToLiveSceneZoom()
        bindEscapeToCloseLiveScene()
        bindShiftOptionHoldToTheSettingsDial()
        bindTheCursorLoopToVoiceStateAndScrolling()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor - the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence - dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches - the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time - isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    /// Whether the pointing bubble leaves by shrinking into the cursor, noted by a push-to-talk press and taken once by the overlay.
    private var pointingBubbleExitRecord = PointingBubbleExitRecord()

    /// The overlay asks this once, as it hides the pointing bubble.
    func takeThePointingBubbleExit() -> TetherCalloutExit {
        pointingBubbleExitRecord.takeTheExit()
    }

    /// Asks the cursor to nod (a command was heard), shake (a failure or a first wrong answer), or hop (a right answer).
    func playCursorEmote(_ emote: CursorEmote) {
        cursorEmoteRequest = CursorEmoteRequest(emote: emote, sequenceNumber: (cursorEmoteRequest?.sequenceNumber ?? 0) + 1)
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementPointingHold = .briefly
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        liveSceneRequestTask?.cancel()
        liveSceneRequestTask = nil
        liveSceneTourFinishedTask?.cancel()
        liveSceneTourFinishedTask = nil
        shortcutTransitionCancellable?.cancel()
        pinchCancellable?.cancel()
        escapeKeyCancellable?.cancel()
        settingsDialCancellable?.cancel()
        settingsDialController.closeAtOnce()
        agentListPanelController.close()
        agentTokenDockController.stop()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        hasSpeechRecognitionPermission = speechRecognitionPermissionIsSatisfied(
            providerRequiresSpeechRecognition: buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission,
            authorizationStatus: SFSpeechRecognizer.authorizationStatus()
        )
        chromeAutomationPermissionStatus = ChromeAutomationPermissionStatus.current()

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted - once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    /// Shows the Speech Recognition prompt when the learner has not been asked, and opens System Settings when
    /// the answer was no, since macOS never asks twice.
    func requestSpeechRecognitionPermission() {
        guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
            if let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
                NSWorkspace.shared.open(privacySettingsURL)
            }
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    /// Shows the macOS prompt to control Chrome, or opens System Settings when the learner already said no.
    /// The prompt blocks until the learner answers, so it runs off the main actor.
    /// Chrome must be running, since macOS only answers for a running app.
    func requestChromeAutomationPermission() {
        switch chromeAutomationPermissionStatus {
        case .granted, .chromeIsNotRunning:
            return
        case .denied:
            if let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(automationSettingsURL)
            }
        case .notAskedYet:
            Task.detached { [weak self] in
                let statusAfterPrompt = ChromeAutomationPermissionStatus.requestFromTheLearner()
                await MainActor.run { self?.chromeAutomationPermissionStatus = statusAfterPrompt }
            }
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content - a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    screenTestFailed = !didCapture
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    screenTestFailed = true
                }
            }
        }
    }

    // MARK: - Setup checklist

    /// The last screen test capture failed, such as when the learner cancelled the screen picker. The setup step turns red.
    @Published private(set) var screenTestFailed = false
    /// The steps the learner pressed this launch. Screen Recording and Accessibility report only granted or not, so one that
    /// was pressed and is still not granted reads as turned off, with the way to fix it.
    @Published private(set) var setupStepsAskedForThisLaunch: Set<SetupStep> = []

    #if DEBUG
    /// A Debug build launched with `--show-setup` shows the setup checklist as a first run does, without clearing a
    /// permission. On a Mac that already finished onboarding, finishing it only hides it again and writes nothing the
    /// everyday Clicky shares. On one that never did, its Start is the real first run (`finishSetup`).
    @Published private(set) var showsSetupForThisLaunch = CommandLine.arguments.contains("--show-setup")
    #else
    let showsSetupForThisLaunch = false
    #endif

    /// Whether setup is finished, so the panel opens on the home instead of the setup checklist.
    var setupIsFinished: Bool { hasCompletedOnboarding && !showsSetupForThisLaunch }

    /// What macOS says about each setup step now, read without a prompt.
    var setupFacts: SetupFacts {
        SetupFacts(
            microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio),
            speechRecognitionStatus: buddyDictationManager.transcriptionProviderRequiresSpeechRecognitionPermission
                ? SFSpeechRecognizer.authorizationStatus()
                : nil,
            hasScreenRecording: hasScreenRecordingPermission,
            screenTestPassed: hasScreenContentPermission,
            screenTestFailed: screenTestFailed,
            hasAccessibility: hasAccessibilityPermission,
            chromeControlStatus: chromeAutomationPermissionStatus,
            stepsAskedForThisLaunch: setupStepsAskedForThisLaunch
        )
    }

    /// A setup row's button. Allow shows the macOS prompt, or opens System Settings once macOS will not ask again.
    func runSetupStep(_ step: SetupStep, action: SetupStepAction) {
        setupStepsAskedForThisLaunch.insert(step)
        switch action {
        case .allow:
            switch step {
            case .microphone:
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        Task { @MainActor [weak self] in self?.refreshAllPermissions() }
                    }
                } else {
                    openPrivacySettings(for: step)
                }
            case .speechRecognition:
                requestSpeechRecognitionPermission()
            case .screenRecording:
                _ = WindowPositionManager.requestScreenRecordingPermission()
            case .screenTest:
                screenTestFailed = false
                requestScreenContentPermission()
            case .accessibility:
                _ = WindowPositionManager.requestAccessibilityPermission()
            case .chromeControl:
                requestChromeAutomationPermission()
            }
        case .openSystemSettings:
            openPrivacySettings(for: step)
        case .findTheApp:
            // An unsigned Debug build can be missing from the Accessibility list, so Finder shows it to drag in.
            WindowPositionManager.revealAppInFinder()
            WindowPositionManager.openAccessibilitySettings()
        case .quitAndReopen:
            quitAndReopenClicky()
        case .openChrome:
            if let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                NSWorkspace.shared.openApplication(at: chromeURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private func openPrivacySettings(for step: SetupStep) {
        let paneAnchor: String
        switch step {
        case .microphone: paneAnchor = "Privacy_Microphone"
        case .speechRecognition: paneAnchor = "Privacy_SpeechRecognition"
        case .screenRecording, .screenTest: paneAnchor = "Privacy_ScreenCapture"
        case .accessibility: paneAnchor = "Privacy_Accessibility"
        case .chromeControl: paneAnchor = "Privacy_Automation"
        }
        if let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(paneAnchor)") {
            NSWorkspace.shared.open(privacySettingsURL)
        }
    }

    /// macOS applies a new Screen Recording grant only to a fresh launch, so this opens Clicky again a second after it quits.
    private func quitAndReopenClicky() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        do {
            try relaunch.run()
        } catch {
            print("⚠️ Setup: could not schedule the relaunch: \(error)")
            return
        }
        NSApp.terminate(nil)
    }

    /// The checklist's Start button. A first run starts Clicky's intro and writes `hasCompletedOnboarding`. A Debug
    /// `--show-setup` run on a Mac that already finished onboarding only hides the checklist again, so it writes nothing the
    /// everyday Clicky shares. On a Mac that never finished onboarding, its Start is the real first run.
    func finishSetup() {
        #if DEBUG
        // Only a Mac that already finished onboarding takes the Debug path. On one that never did, Start is the real one.
        if showsSetupForThisLaunch && hasCompletedOnboarding {
            showsSetupForThisLaunch = false
            return
        }
        showsSetupForThisLaunch = false
        #endif
        triggerOnboarding()
    }

    // MARK: - Panel actions

    /// Set by `MenuBarPanelManager`: whether the menu bar panel holds the keyboard, or closed on an Escape a moment ago.
    var menuPanelTookTheEscape: () -> Bool = { false }
    /// Set by `MenuBarPanelManager`: whether the panel is open on its home, where the banner slot shows the approval card.
    var menuPanelShowsTheApprovalCard: () -> Bool = { false }
    /// Set by `MenuBarPanelManager`: whether the panel is open on any page, which holds back the end-of-video recap.
    var menuPanelIsOpen: () -> Bool = { false }

    /// How the running video quiz is going, for the panel's state line, or nil with no quiz running.
    @Published private(set) var videoQuizProgress: VideoQuizProgress?

    /// The state line's Stop quiz button, which does what saying "stop the quiz" does.
    func stopTheVideoQuizFromThePanel() {
        handleVideoQuizVoiceCommand(.stop)
    }

    /// The desk whose card the panel's banner slot shows, as the agent list does, with its own seen state and clock.
    var approvalDesk: HarnessApprovalDesk { agentHarness.approvalDesk }

    /// The panel closed or left its home, so its approval card is off screen: the desk forgets what that card had shown,
    /// and a request still waiting opens the agent list, since no other screen shows its summary.
    func theMenuPanelStoppedShowingTheApprovalCard() {
        agentHarness.approvalDesk.theCardHasNotShownTheWholeSummary(on: .menuPanel)
        guard let oldestRequest = agentHarness.approvalDesk.oldestWaitingRequest, !agentListPanelController.isOpen else { return }
        agentListPanelController.openForAnApprovalRequest(fromAgentID: oldestRequest.taskID)
    }

    /// The agents row: the panel closes and the agent list opens next to the mouse, as the settings dial's Agents slice opens it.
    func openTheAgentListFromThePanel() {
        // The list opens before the panel closes, so the panel's close finds it open and opens no second list for a
        // waiting request (`theMenuPanelStoppedShowingTheApprovalCard`).
        if !agentListPanelController.isOpen { agentListPanelController.toggle() }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
    }

    /// The "Design one" card: the panel closes and the Theme Studio opens next to the mouse with three new ideas.
    func designAThemeFromThePanel() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        // A click starts no press, so a loop the last press drew is not this design's picture.
        circledRegionOfThePress = nil
        startDesigningATheme(request: "a new theme", basedOnIdea: nil, pictureChoice: .none)
    }

    /// The keyboard moved the focus to an agent chip in the panel: its disc in the menu bar shows the focus ring and its
    /// peek card, so the keyboard reaches the discs, which never take the keyboard themselves.
    func showTheKeyboardFocusOnTheAgentDisc(of agentID: UUID) {
        agentTokenDockController.showTheKeyboardFocus(onTheDiscOf: agentID)
    }

    /// An agent chip lost the focus, or the panel closed (nil): the ring and the peek card leave that disc, and only that
    /// disc, so a chip that loses the focus after the next chip took it never takes the next one's ring away.
    func endTheKeyboardFocusOnTheAgentDisc(of agentID: UUID?) {
        agentTokenDockController.endTheKeyboardFocus(onTheDiscOf: agentID)
    }

    /// What the agent's disc menu offers, for the panel's agent actions.
    func agentDiscMenuItemsForThePanel(agentID: UUID) -> [AgentDiscMenuItem] {
        let agent = backgroundAgentStore.agents.first { $0.id == agentID }
        return agentDiscMenuItems(
            for: agent,
            isWaitingForApproval: backgroundAgentStore.agentIDsWaitingForApproval.contains(agentID),
            aVideoQuizQuestionIsOpen: videoQuizQuestionIsActive
        )
    }

    /// Runs one of a disc's menu items from the panel. One that opens the agent list opens it under the disc, or next to the
    /// mouse when the agent has no disc on screen, such as one counted in "+N".
    func runTheAgentDiscMenuItemFromThePanel(_ menuItem: AgentDiscMenuItem, agentID: UUID) {
        // The item runs before the panel closes, so a list it opens is already open when the panel's close checks.
        if !agentTokenDockController.run(menuItem, forTheDiscOf: agentID) {
            // Only an item that opens the agent list comes back, for an agent with no disc to open it under.
            if menuItem == .reviewRequest {
                agentListPanelController.openForAnApprovalRequest(fromAgentID: agentID)
            } else if !agentListPanelController.isOpen {
                agentListPanelController.toggle()
            }
        }
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception -
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding - the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs - schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    /// Each newer partial transcript after the release may start the voice command again on its words.
    private func bindPartialTranscriptsToTheVoiceCommandSpeculation() {
        partialTranscriptCancellable = buddyDictationManager.partialTranscriptUpdates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] partialTranscript in
                self?.theLearnersPartialWordsChanged(to: partialTranscript)
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    /// Escape closes a finished scene, so the push-to-talk shortcut always means talk.
    /// With no scene on screen, it stops the answer Clicky is giving.
    private func bindEscapeToCloseLiveScene() {
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.closeLiveSceneOnEscape()
            }
    }

    /// Holding shift + option opens the settings dial, releasing the keys commits the highlighted item, and a key,
    /// a mouse button, Escape, or the event tap stopping cancels it.
    private func bindShiftOptionHoldToTheSettingsDial() {
        settingsDialCancellable = globalPushToTalkShortcutMonitor
            .settingsDialEventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settingsDialEvent in
                self?.handleSettingsDialEvent(settingsDialEvent)
            }
    }

    private func handleSettingsDialEvent(_ settingsDialEvent: SettingsDialShortcutRecognizer.Event) {
        switch settingsDialEvent {
        case .opened:
            // An open agent list would sit under the dial, and its Agents slice opens it again.
            agentListPanelController.close()
            settingsDialController.open(snapshot: SettingsDialSnapshot(
                theme: themeSettings.shownTheme,
                themePicture: themeSettings.shownThemePicture,
                modelID: selectedModel,
                isClickyCursorEnabled: isClickyCursorEnabled,
                runningAgentCount: backgroundAgentStore.agents.filter(\.isRunning).count,
                fans: SettingsDialFans(
                    bundledThemes: themeSettings.bundledThemes,
                    savedCustomThemes: themeSettings.savedCustomThemesWithSavedDates
                )
            ))
        case .released:
            if let settingsDialChoice = settingsDialController.releaseAndReturnTheChoice() {
                commitSettingsDialChoice(settingsDialChoice)
            }
        case .cancelled:
            settingsDialController.close()
        }
    }

    private func commitSettingsDialChoice(_ settingsDialChoice: SettingsDialChoice) {
        switch settingsDialChoice {
        case .theme(let theme):
            themeSettings.theme = theme
        case .model(let modelChoice):
            setSelectedModel(modelChoice.modelID)
        case .agents:
            // Opening the dial closed the list, so this opens it next to the mouse with no row expanded.
            agentListPanelController.toggle()
        case .toggleShowClicky:
            setClickyCursorEnabled(!isClickyCursorEnabled)
        case .more:
            NotificationCenter.default.post(name: .clickyShowPanel, object: nil)
        }
    }

    /// The loop around the media ends when Clicky stops thinking or starts to speak, and when the page scrolls.
    /// The label is part of the pair because Clicky speaks while a build runs, and the loop stays through that.
    private func bindTheCursorLoopToVoiceStateAndScrolling() {
        cursorLoopVoiceStateCancellable = Publishers.CombineLatest(
            $voiceState,
            LiveSceneStatusLabel.shared.statusLabelModel.$isVisible
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] voiceState, aStatusLabelIsShowing in
            self?.cursorLoopController.voiceStateChanged(to: voiceState, aStatusLabelIsShowing: aStatusLabelIsShowing)
        }
        scrollWheelCancellable = globalPushToTalkShortcutMonitor
            .scrollWheelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.cursorLoopController.end(because: .scrolled)
            }
        cursorLoopController.agentSparksMayDraw = { [weak self] in self?.agentSparksMayDraw ?? false }
        cursorLoopController.theRoomArtPanelIsOpen = { [weak self] in self?.roomArtPreviewController.isOpen ?? false }
        // A finished agent's spark completes its lap, and a failed or cancelled agent's goes at once.
        cursorLoopAgentSparksCancellable = backgroundAgentStore.$agents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agents in
                self?.cursorLoopController.agentStatusesChanged(Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.loopSparkStatus) }))
            }
    }

    /// An agent's spark may join the loop's line unless a scene covers the media or a quiz question is open, where a request's
    /// loop never draws either, the room art panel is open, or Show Clicky is off, since the overlay then fades a second after the answer.
    private var agentSparksMayDraw: Bool {
        Clicky.agentSparksMayDraw(
            clickyCursorIsEnabled: isClickyCursorEnabled,
            aSceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            aQuizQuestionIsOpen: liveScenePhaseIsWaitingForAQuizAnswer || videoQuizQuestionIsActive,
            theRoomArtPanelIsOpen: roomArtPreviewController.isOpen
        )
    }

    /// A background agent started from a tab. Its spark laps the loop when its work is on the video in front, and joins
    /// at a later release when `agentSparksMayDraw` holds it back now.
    private func theAgentStartedFromTheFrontTab(_ agentID: UUID, sourceTab: AgentSourceTab) {
        cursorLoopController.agentStarted(id: agentID, sourceTab: sourceTab)
    }

    private func bindPinchToLiveSceneZoom() {
        pinchCancellable = globalPushToTalkShortcutMonitor
            .pinchMagnificationPublisher
            .receive(on: DispatchQueue.main)
            .sink { magnification in
                LiveSceneOverlay.shared.zoomModelForPinch(magnification: magnification)
            }
    }

    /// Cancels a pending transient hide so the overlay stays up. With "Show Clicky" off, it brings the
    /// cursor back for this one interaction, and scheduleTransientHideIfNeeded fades it out after.
    private func showTheCursorOverlayForThisInteraction() {
        transientHideTask?.cancel()
        transientHideTask = nil
        guard !isClickyCursorEnabled && !isOverlayVisible else { return }
        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            pushToTalkPressCount += 1
            startRecordingTheMousePath()
            // A press while the shirt capture waits for the learner to step back cancels it, so "paint it" again arms a new one.
            roomArtPreviewController.theLearnerPressedPushToTalk()
            approvalAtThePress = agentHarness.approvalDesk.approvalAtPress(at: Date())
            pushToTalkPressAcceptance.pressWasAccepted()
            // A screen read from an earlier press is out of date the moment a new press begins.
            forgetTheVoiceCommandScreenRead()
            // So is a command the last press started on its partial transcript, whose words the learner is now replacing.
            endTheVoiceCommandSpeculation(because: "a new push-to-talk press")
            // The moves and labels on screen end in the order `PushToTalkPressStep` gives and its test pins. A new press starts
            // a new request, so the label from the last build is out of date, and so is its loop.
            for pressStep in PushToTalkPressStep.allCases {
                switch pressStep {
                case .endTheRecapGather: cancelTheVideoRecapGather()
                case .landTheFlights: agentTokenDockController.finishTheServeAtOnce()
                case .landTheScrub: cursorScrubController.landAtOnce()
                case .hideTheStatusLabel: LiveSceneStatusLabel.shared.hide()
                case .recallTheChip: VoiceToolCallChip.shared.recall()
                case .endTheCursorLoop: cursorLoopController.pushToTalkWasPressed()
                }
            }

            showTheCursorOverlayForThisInteraction()

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            // A replay stops its camera and travel and stays open at its stop, so "next" and "back" still work.
            instantReplay.stopTheTravelForAPress()
            // The learner interrupted, so a narration's bubble shrinks into the cursor instead of fading up.
            pointingBubbleExitRecord.noteThatTheLearnerInterrupted(
                pointingHold: detectedElementScreenLocation == nil ? nil : detectedElementPointingHold
            )
            clearDetectedElementLocation()
            // A cancelled narration or scene line returns without leaving the responding state, and the
            // dictation binding never replaces responding, so the listening ring would not show.
            if voiceState == .responding {
                voiceState = .idle
            }

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            // The transcript of this press may arrive after a newer press began, so it carries its own press number.
            let pressCountOfThisPress = pushToTalkPressCount
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (the ring shows the voice, not the words)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript, pushToTalkPressCount: pressCountOfThisPress)
                    },
                    endWithNoTranscript: { [weak self] in
                        self?.discardTheSpeculationOfAPressThatEndedWithNoTranscript(pressCountOfThisPress)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalkFromKeyboardShortcut had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the listening ring stuck on screen indefinitely.
            let releaseEndsAnAcceptedPress = pushToTalkPressAcceptance.releaseEndsAnAcceptedPress()
            stopRecordingTheMousePath()
            if releaseEndsAnAcceptedPress {
                lastPushToTalkRelease = PushToTalkRelease(pressCount: pushToTalkPressCount, releasedAt: Date())
            }
            // The loop's media read and the voice command's screen read both begin with Chrome's front tab, so this release
            // reads it once for both.
            let frontTabRead = FrontTabReadAtRelease()
            // The media rect is read beside the router call. It draws a loop only if the request becomes a look at it.
            cursorLoopController.pushToTalkWasReleased(frontTabRead: frontTabRead)
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            // After the stop is scheduled, since the reads below block the main actor for a moment.
            if releaseEndsAnAcceptedPress {
                startReadingTheScreenForTheVoiceCommand(frontTabRead: frontTabRead)
            }
        case .none:
            break
        }
    }

    // MARK: - Circle to select

    /// A new press forgets the last press's loop and records this one's mouse path.
    private func startRecordingTheMousePath() {
        circledRegionOfThePress = nil
        mousePathRecorder.start()
    }

    /// The release keeps the loop the path closed, if any, for this press's request.
    private func stopRecordingTheMousePath() {
        guard let circledRegion = mousePathRecorder.stop() else { return }
        circledRegionOfThePress = (pushToTalkPressCount, circledRegion)
        let rect = circledRegion.boundingRect
        print("Circle to select: the learner circled a \(Int(rect.rectWidth))x\(Int(rect.rectHeight)) point region at (\(Int(rect.rectX)), \(Int(rect.rectY)))")
    }

    /// The loop the learner drew during the current press, or nil.
    private var circledRegionOfTheCurrentPress: CircledRegion? {
        guard let circledRegionOfThePress, circledRegionOfThePress.pressCount == pushToTalkPressCount else { return nil }
        return circledRegionOfThePress.circledRegion
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two short sentences, about 35 words in total, counting any idea you end on, because the user waits through every extra sentence as audio. be direct and dense, and give the one best answer rather than every option. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - casual and warm, in normal sentence case: capitalize the start of each sentence and every name, such as people, places, languages, and nationalities (Hokusai, Japan, Japanese). no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - don't end with simple yes/no questions like "want me to explain more?" or "should I show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "You'll want to open the color inspector — it's right up in the top right area of the toolbar. Click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "HTML stands for HyperText Markup Language, it's basically the skeleton of every web page. Curious how it connects to the CSS you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "See that Source Control menu up top? Click that and hit Commit, or you can use Command Option C as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "That's over on your other monitor — see the Terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// Added to the system prompt for a look-inside request. Without it Claude
    /// answers from the page and tells the learner to scroll while the scene opens.
    /// A model with labeled parts gets one tagged sentence per part, so the length rule and the tag
    /// rule come from one place and cannot conflict. A model with no labels gets one short sentence.
    private static func liveSceneExploreVoiceResponseInstructions(partLabels: [String]) -> String {
        let lengthAndTagInstructions: String
        if partLabels.isEmpty {
            lengthAndTagInstructions = "reply with one short, plain spoken sentence about what they're seeing inside, with no exclamation marks, at most 20 words. the only tag you may write is [POINT:none], at the very end."
        } else {
            lengthAndTagInstructions = "the model has these exact part names: \(partLabels.joined(separator: ", ")). reply with two to four short, plain spoken sentences about what they're seeing inside, with no exclamation marks, at most 20 words each. start each sentence with [PART:name] using one of those exact names. the only other tag you may write is [POINT:none], at the very end."
        }
        return """


        for this reply only: a labeled 3d model of what they asked about is already opening on their screen, and the camera is moving through it. \(lengthAndTagInstructions) talk about the model, not the web page. never tell them to scroll, click, or look anywhere else.
        """
    }

    // MARK: - AI Response Pipeline

    #if DEBUG
    /// Feeds transcripts through the real pipeline with no microphone, so the
    /// whole voice and quiz loop can be tested unattended. A transcript that
    /// starts with "~" does not wait for Clicky: the next one follows 6 seconds
    /// later, while a scene is still building. In a "?" step, "{answer}" becomes
    /// the open question's answer label, since the plan picks a new question each run. A transcript that starts
    /// with "&" waits until no background agent is running, and then for what their endings set off, such as a 3D model
    /// or an experiment rising and its narration or guess question, so a demo can open the guide it just asked for,
    /// put back the model it just built, or answer the experiment's question.
    /// A transcript that starts with "+N " first waits N seconds, before any other prefix is read.
    /// A transcript that starts with "^" presses push-to-talk through the real press handler 0.3 seconds after its
    /// voice_command line goes to the harness, and releases it 0.2 seconds later.
    func runLiveSceneRehearsal(transcripts: [String]) async {
        // The microphone keeps listening 0.5 seconds after the release (`secondsToKeepListeningAfterTheShortcutIsReleased`),
        // and the provider's final transcript follows, so a rehearsal step uses 0.7 seconds for both together.
        let secondsBetweenAReleaseAndItsTranscriptInARehearsal = 0.7
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for rehearsalStepWithWait in transcripts {
            let (waitSeconds, rehearsalStep) = rehearsalStepWait(rehearsalStepWithWait)
            if waitSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            }
            let (stepPrefix, transcriptWithoutPrefix) = rehearsalStepPrefix(rehearsalStep)
            let nextStepInterruptsThisOne = stepPrefix == .nextStepInterruptsThisOne
            // "?" waits up to 4 minutes for a video quiz question, since a pause comes whenever the video reaches it.
            let stepWaitsForAQuestion = stepPrefix == .waitsForAQuestion
            let stepWaitsForTheBackgroundAgents = stepPrefix == .waitsForTheBackgroundAgents
            let stepPressesPushToTalkDuringTheCommand = stepPrefix == .pressesPushToTalkDuringTheCommand
            var transcript = transcriptWithoutPrefix
            if stepPrefix == .hearsAPartialTranscriptFirst {
                let (partialTranscript, finalTranscript) = rehearsalPartialAndFinalTranscripts(transcriptWithoutPrefix)
                rehearsalPartialTranscript = partialTranscript
                transcript = finalTranscript
            }
            // Every exit from this step, a "continue" included, stops standing in for the microphone.
            defer { rehearsalPartialTranscript = nil }
            var rectToCircle: CGRect?
            if stepPrefix == .circlesARegionFirst {
                guard let (rect, words) = rehearsalCircledRect(transcriptWithoutPrefix) else {
                    print("Live scene rehearsal: the @ step \"\(transcriptWithoutPrefix)\" has no x,y,width,height rect, so it was skipped")
                    continue
                }
                rectToCircle = rect
                transcript = words
            }
            if stepWaitsForTheBackgroundAgents {
                // A guide takes about 15 seconds and a task agent about 25.
                // An experiment built on Sonnet can take the whole background build wait, so the loop waits that long plus a minute.
                let quarterSecondsToWaitForTheAgents = Int((LiveSceneBuildWait.inTheBackground.timeoutSeconds + 60) * 4)
                for _ in 0..<quarterSecondsToWaitForTheAgents where !backgroundAgentTasks.isEmpty || studyGuideRefreshesBeingChecked > 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                await waitForTheLatestResponseTaskToFinish()
                await waitForTheTourAndSpeechToEnd()
                // The finish chip and the agent's check mark show for a few seconds before the learner speaks again.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
            if stepWaitsForAQuestion {
                // A learner answers after hearing the question, so wait for it to start and end. A second answer to
                // the same question comes after Clicky's reply to the first, so 2 quiet seconds with the question
                // waiting count as heard too.
                var questionAudioHasStarted = false
                var quietSecondsWithTheQuestionWaiting = 0.0
                for _ in 0..<960 {
                    var questionIsWaiting = false
                    if case .awaitingAnswer = liveScenePhase { questionIsWaiting = true }
                    if questionIsWaiting && elevenLabsTTSClient.isPlaying { questionAudioHasStarted = true }
                    if questionIsWaiting && questionAudioHasStarted && !elevenLabsTTSClient.isPlaying { break }
                    quietSecondsWithTheQuestionWaiting = questionIsWaiting && !elevenLabsTTSClient.isPlaying ? quietSecondsWithTheQuestionWaiting + 0.25 : 0
                    if quietSecondsWithTheQuestionWaiting >= 2 { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if case .awaitingAnswer(let openQuiz, _) = liveScenePhase {
                    transcript = rehearsalTranscript(transcript, answeringWith: openQuiz.answerLabel)
                }
            }
            print("Live scene rehearsal: saying \"\(transcript)\" in phase \(liveScenePhase)")
            // A push-to-talk press hides the label before a transcript goes out, so the rehearsal does
            // the same, and a line the previous step left up cannot stay on screen.
            LiveSceneStatusLabel.shared.hide()
            VoiceToolCallChip.shared.recall()
            pushToTalkPressCount += 1
            // A press while the shirt capture waits for the learner to step back cancels it, so "paint it" again arms a new one.
            roomArtPreviewController.theLearnerPressedPushToTalk()
            approvalAtThePress = agentHarness.approvalDesk.approvalAtPress(at: Date())
            // The same goes for the loop: a press ends the last request's, and the release starts the media rect read.
            cursorLoopController.pushToTalkWasPressed()
            startRecordingTheMousePath()
            if let rectToCircle {
                await moveTheMouseAroundForARehearsal(rectToCircle)
            }
            stopRecordingTheMousePath()
            let frontTabRead = FrontTabReadAtRelease()
            cursorLoopController.pushToTalkWasReleased(frontTabRead: frontTabRead)
            lastPushToTalkRelease = PushToTalkRelease(pressCount: pushToTalkPressCount, releasedAt: Date())
            startReadingTheScreenForTheVoiceCommand(frontTabRead: frontTabRead)
            // A real transcript arrives after the microphone's tail and the provider's final result, so the step waits
            // the same before it speaks, and the timing line's release marks mean what they mean for a real press.
            try? await Task.sleep(for: .seconds(secondsBetweenAReleaseAndItsTranscriptInARehearsal))
            let harnessVoiceCommandsSentBeforeThisStep = harnessVoiceCommandsSent
            sendTranscriptToClaudeWithScreenshot(transcript: transcript, pushToTalkPressCount: pushToTalkPressCount)
            if stepPressesPushToTalkDuringTheCommand {
                await pressPushToTalkOnceTheVoiceCommandGoesOut(afterCount: harnessVoiceCommandsSentBeforeThisStep)
            }
            if nextStepInterruptsThisOne {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                continue
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            // A quiet moment is not the end of a step: a pop-out's narration starts about a second after its
            // tour ends, so the step's own work is waited out first, then any tour or speech still going.
            await waitForTheLatestResponseTaskToFinish()
            await waitForTheTourAndSpeechToEnd()
            print("Live scene rehearsal: finished, phase \(liveScenePhase)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        await waitForTheLatestResponseTaskToFinish()
        // A scene that should have been cancelled would still be building or touring here, for up to 40 seconds.
        for _ in 0..<160 {
            var sceneIsStillInProgress = false
            if case .buildingScene = liveScenePhase { sceneIsStillInProgress = true }
            if case .touring = liveScenePhase { sceneIsStillInProgress = true }
            let clickyIsBusy = voiceState == .processing || elevenLabsTTSClient.isPlaying
            if !sceneIsStillInProgress && !clickyIsBusy { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        print("Live scene rehearsal: done, phase \(liveScenePhase)")
    }

    /// An "@" step's circle: the real mouse moves around `rect` in about 1.2 seconds with posted mouse moves, so the recorder
    /// samples it as it would a learner's hand, and a recorded take shows the pointer drawing the circle.
    private func moveTheMouseAroundForARehearsal(_ rect: CGRect) async {
        let circleSeconds = 1.2
        let pointCount = Int(circleSeconds * 60)
        print("Live scene rehearsal: circling \(rect) with the mouse")
        for point in rehearsalCirclePath(around: rect, pointCount: pointCount) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: UInt64(circleSeconds / Double(pointCount) * 1_000_000_000))
        }
    }

    /// A "^" step's press. runVoiceCommand reads the page before its first request, so the press is timed from the
    /// voice_command line, not from when the step went out. It runs the handler a real press runs, so it cancels the
    /// command and stops Clicky's audio the same way, and the release closes the dictation session the press opened.
    private func pressPushToTalkOnceTheVoiceCommandGoesOut(afterCount harnessVoiceCommandsSentBeforeThisStep: Int) async {
        // The page reads and the study guide check take a few seconds at most.
        for _ in 0..<500 where harnessVoiceCommandsSent == harnessVoiceCommandsSentBeforeThisStep {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard harnessVoiceCommandsSent > harnessVoiceCommandsSentBeforeThisStep else {
            print("Live scene rehearsal: no voice_command went to the harness within 10 seconds, so the ^ step pressed nothing.")
            return
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        print("Live scene rehearsal: pressing push-to-talk during the voice command")
        handleShortcutTransition(.pressed)
        try? await Task.sleep(nanoseconds: 200_000_000)
        handleShortcutTransition(.released)
    }

    private func waitForTheTourAndSpeechToEnd() async {
        await waitUntilNoTourOrSpeechIsPlaying()
        // When a tour ends, a quiz question or an experiment's guess question is spoken by liveSceneTourFinishedTask,
        // and its audio can start after the check above has passed, so the step also waits for that task and its speech.
        await liveSceneTourFinishedTask?.value
        await waitUntilNoTourOrSpeechIsPlaying()
    }

    private func waitUntilNoTourOrSpeechIsPlaying() async {
        while true {
            let tourIsStillPlaying: Bool
            if case .touring = liveScenePhase { tourIsStillPlaying = true } else { tourIsStillPlaying = false }
            let clickyIsBusy = voiceState == .processing || elevenLabsTTSClient.isPlaying
            if !tourIsStillPlaying && !clickyIsBusy { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// A voice command can hand its request to a new response task, such as pop_out starting the pop-out,
    /// so this waits on whichever task is current until no newer one has replaced it.
    private func waitForTheLatestResponseTaskToFinish() async {
        while let responseTask = currentResponseTask {
            await responseTask.value
            if currentResponseTask == responseTask { return }
        }
    }
    #endif

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via ElevenLabs TTS. The cursor stays in
    /// the thinking dots (processing state) until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String, pushToTalkPressCount pressCountOfTheTranscript: Int) {
        let transcriptReadyAt = Date()
        // A transcript with words is a command Clicky heard.
        playCursorEmote(.nod)
        // This transcript takes the read of its own press before any branch below returns, so no later transcript can use it,
        // and a press that gets a transcript leaves no read behind. The read is dropped when the page it describes is gone.
        let screenReadAtRelease = screenReadForTheTranscript(
            of: pressCountOfTheTranscript,
            from: voiceCommandScreenRead,
            currentPageIdentity: currentVoiceCommandPageIdentity()
        )
        if screenReadAtRelease != nil {
            // Taken, so forgetting below does not cancel its page read.
            voiceCommandScreenRead = nil
        }
        forgetTheVoiceCommandScreenRead()
        // The page read is cancelled on every path that does not hand it to a voice command.
        var screenReadIsHandedToTheVoiceCommand = false
        defer {
            if !screenReadIsHandedToTheVoiceCommand { screenReadAtRelease?.pageRead.cancel() }
        }
        let routeContext = currentTranscriptRouteContext()
        // The read started at this press's release, when there is one. Otherwise it is read once here, and only for a
        // transcript that gets past the phrase matches and the keyword branches, because each read is a round trip to
        // Chrome. A quiz answer or a scene still building reads no video.
        var frontVideoStateReadForThisTranscript: JSONValue??
        func frontVideoState() -> JSONValue? {
            if let frontVideoStateReadForThisTranscript { return frontVideoStateReadForThisTranscript }
            let frontVideoStateNow: JSONValue?
            switch frontVideoStateSourceForTheTranscript(
                phaseIsWaitingForAQuizAnswer: routeContext.phaseIsWaitingForAQuizAnswer,
                sceneIsBuilding: routeContext.sceneIsBuilding,
                screenReadAtRelease: screenReadAtRelease
            ) {
            case .noVideoIsRead:
                frontVideoStateNow = nil
            case .fromTheRelease(let frontVideoStateAtRelease):
                frontVideoStateNow = frontVideoStateAtRelease
            case .readNow:
                frontVideoStateNow = videoQuizSession.frontVideoStateForVoiceCommands()
            }
            frontVideoStateReadForThisTranscript = .some(frontVideoStateNow)
            return frontVideoStateNow
        }
        let route = transcriptRoute(for: transcript, in: routeContext, videoIsInFront: { frontVideoState() != nil })

        // A command this press started on its partial transcript is kept only when the final transcript would have sent the
        // same command, and is discarded otherwise, before the final transcript takes its route.
        var speculationOutcome: VoiceCommandSpeculationOutcome?
        var confirmedSpeculativeCommand: SpeculativeVoiceCommand?
        if let speculativeCommand = voiceCommandSpeculation.takeForTheFinalTranscript(ofPress: pressCountOfTheTranscript) {
            let finalUsesTheSameScreenRead = screenReadAtRelease != nil
            let commandInputsAreUnchanged = route == .voiceCommandRouter && finalUsesTheSameScreenRead
                && voiceCommandInputs(frontVideoState: frontVideoState(), pageRead: speculativeCommand.screenRead.pageRead) == speculativeCommand.inputs
            switch speculationStep(
                partialTranscript: speculativeCommand.partialTranscript,
                finalTranscript: transcript,
                finalRoute: route,
                finalUsesTheSameScreenRead: finalUsesTheSameScreenRead,
                commandInputsAreUnchanged: commandInputsAreUnchanged,
                // The router stops tracking a command once its task_failed arrives or its harness exits.
                heldCommandIsStillRunning: agentHarness.taskRouter.isTracking(taskID: speculativeCommand.command.commandID)
            ) {
            case .confirm:
                agentHarness.confirmVoiceCommand(taskID: speculativeCommand.command.commandID)
                confirmedSpeculativeCommand = speculativeCommand
                speculationOutcome = .kept
                print("Voice command: the final transcript kept the command started on the partial transcript")
            case .discard(let reason):
                discardTheSpeculativeVoiceCommand(speculativeCommand, because: reason)
                speculationOutcome = .discarded
            }
        }

        switch route {
        case .videoQuizCommand(let videoQuizCommand):
            handleVideoQuizVoiceCommand(videoQuizCommand)
        case .putTheSceneBack:
            respondToTranscript(transcript: transcript, requestedSceneKind: nil)
        case .confirmTheRoomArt:
            // "Right there" places the ghost with no model call, so the confirm never depends on the router.
            print("Room furniture: placed by voice")
            roomArtPreviewController.placeTheFurnitureWhereItsGhostStands()
        case .replayTheExplanation:
            // "Show me again" replays the recorded stops with no model call, so it never builds a paid scene.
            print("Instant replay: replaying on request")
            instantReplay.playFromTheStart()
        case .shirtPaintedStill(let shirtStillRequest):
            switch shirtStillRequest {
            case .paintIt:
                print("Shirt painting: arming the capture on request")
                roomArtPreviewController.paintTheShirt()
            case .backToLive:
                print("Shirt painting: back to the live camera on request")
                roomArtPreviewController.goBackToTheLiveShirt()
            }
        case .saveTheRoomArtPhoto:
            print("Room art: saving the photo on request")
            roomArtPreviewController.saveThePhoto()
        // "Animate this" and "let me try it" keep their keyword branches ahead of the router, so a demo never depends on
        // the model choosing them, unless the brain flag hands the utterance to the router.
        case .keywordBranch(.animatePicture):
            theRequestBecameALookAtTheMedia()
            respondToTranscript(transcript: transcript, requestedSceneKind: .animatedFramePopout)
        case .keywordBranch(.startExperiment):
            startTheExperimentInTheBackground(transcript: transcript)
        case .keywordBranch(.designATheme(let themeStudioRequest)):
            startDesigningATheme(request: transcript, basedOnIdea: nil, pictureChoice: themeStudioRequest == .fromThePicture ? .captureAgain : .none)
        case .keywordBranch(.showArtInMyRoom):
            theRequestBecameALookAtTheMedia()
            startShowingTheArtInMyRoom(learnerRequest: transcript)
        case .voiceCommandRouter:
            // Only the release of this transcript's own press counts, never an older press's.
            let releaseOfThisPress = lastPushToTalkRelease?.pressCount == pressCountOfTheTranscript ? lastPushToTalkRelease : nil
            screenReadIsHandedToTheVoiceCommand = true
            let timing = VoiceCommandTimingRecorder(pushToTalkReleasedAt: releaseOfThisPress?.releasedAt, transcriptReadyAt: transcriptReadyAt)
            timing.speculation = speculationOutcome
            startVoiceCommand(
                transcript: transcript,
                frontVideoState: frontVideoState(),
                pageReadStartedAtRelease: screenReadAtRelease?.pageRead,
                confirmedSpeculativeCommand: confirmedSpeculativeCommand,
                timing: timing
            )
        case .keywordPath:
            respondByTheKeywordPath(transcript: transcript)
        }
    }

    /// Starts the reads a voice command needs from the screen, at the release of push-to-talk. The front tab read, shared
    /// with the cursor loop's media read through `frontTabRead`, is Apple Events to Chrome, which must run on the main actor,
    /// so whichever reader asks first blocks the main actor for a moment, during the microphone's tail. That delays nothing
    /// the microphone needs: the audio tap runs on the audio thread, and the tail's stop is a main queue timer, which fires
    /// late only when the read outlasts the tail. The page reads that follow wait on WebKit, and the study guide check uses
    /// the release read's URL and then may wait on the Worker. It reads `frontTabURLOfTheFrontWindow` itself only for a
    /// command with no release read (the `runVoiceCommand` fallback).
    private func startReadingTheScreenForTheVoiceCommand(frontTabRead: FrontTabReadAtRelease) {
        let pressCountOfTheRead = pushToTalkPressCount
        forgetTheVoiceCommandScreenRead()
        // A quiz answer goes to the judge and a building scene keeps the keyword path, and neither reads the video.
        var sceneIsBuilding = false
        if case .buildingScene = liveScenePhase { sceneIsBuilding = true }
        guard screenReadStartsAtRelease(
            phaseIsWaitingForAQuizAnswer: liveScenePhaseIsWaitingForAQuizAnswer,
            sceneIsBuilding: sceneIsBuilding
        ) else { return }
        voiceCommandScreenReadTask = Task { @MainActor in
            // A press or a transcript between this release and the task's start has forgotten the read and cancelled the task.
            guard !Task.isCancelled else { return }
            // Nothing below suspends before the read is stored, so no press can arrive in the middle of it.
            let pageIdentityAtRelease = currentVoiceCommandPageIdentity()
            // The front tab is the one the loop's media read took, when that ran first, and its URL is the study guide check's.
            let frontTab = frontTabRead.frontTab()
            let frontVideoState = frontTab.flatMap { videoQuizSession.frontVideoStateForVoiceCommands(in: $0) }
            let screenRead = VoiceCommandScreenRead(
                pressCount: pressCountOfTheRead,
                pageIdentityAtRelease: pageIdentityAtRelease,
                frontVideoState: frontVideoState,
                pageRead: Task {
                    await self.readThePageForTheVoiceCommand(frontVideoState: frontVideoState, frontVideoURLSource: .releaseRead(frontTab?.url))
                }
            )
            voiceCommandScreenRead = screenRead
            startTheVoiceCommandOnThePartialTranscriptOnceTheScreenIsRead(screenRead)
        }
    }

    /// Starts the voice command on the words heard so far once the release's page read is in, so the model works while the
    /// final transcript is still on its way. The harness holds the command before its first call until the final transcript
    /// confirms the words, so nothing the learner can see or hear happens on a partial transcript. Newer partial words
    /// start it again (`theLearnersPartialWordsChanged`), the press's final transcript keeps or discards it
    /// (`speculationStep`), and a new press discards it.
    private func startTheVoiceCommandOnThePartialTranscriptOnceTheScreenIsRead(_ screenRead: VoiceCommandScreenRead) {
        endTheVoiceCommandSpeculation(because: "a newer release read the screen again")
        let startOnceTheScreenIsRead = Task { @MainActor in
            let pageRead = await screenRead.pageRead.value
            // A press, or this press's final transcript, ended the wait first, and the final transcript runs the normal way.
            guard !Task.isCancelled,
                  case .waitingForTheScreenRead(let pressCountWaiting, _) = self.voiceCommandSpeculation,
                  pressCountWaiting == screenRead.pressCount else { return }
            self.voiceCommandSpeculation = .none
            self.startTheVoiceCommand(
                onThePartialTranscript: self.partialTranscriptHeardSoFar(),
                from: ReleaseScreenReadInHand(pressCount: screenRead.pressCount, frontVideoState: screenRead.frontVideoState, pageRead: pageRead)
            )
        }
        voiceCommandSpeculation = .waitingForTheScreenRead(pressCount: screenRead.pressCount, start: startOnceTheScreenIsRead)
    }

    /// Newer partial words arrived after the release's screen read, before the final transcript. A command started on older
    /// words is discarded and the command starts again on these, since the words heard at the release are often only the
    /// first one or two, and the newest partial is the one most likely to match the final transcript.
    private func theLearnersPartialWordsChanged(to partialTranscript: String) {
        #if DEBUG
        // A rehearsal stands in for the microphone, so a stray partial from a real press must not replace its words.
        if rehearsalPartialTranscript != nil { return }
        #endif
        guard let screenRead = voiceCommandSpeculation.screenReadToStartFrom(whenThePartialWordsBecome: partialTranscript) else { return }
        endTheVoiceCommandSpeculation(because: "newer words were heard")
        startTheVoiceCommand(onThePartialTranscript: partialTranscript, from: screenRead)
    }

    /// Sends the command on these partial words when `speculativeStartStep` allows it, and otherwise waits for newer words
    /// or gives up on the press, which the final transcript then runs the normal way.
    private func startTheVoiceCommand(onThePartialTranscript partialTranscript: String, from screenRead: ReleaseScreenReadInHand) {
        let partialRoute = transcriptRoute(
            for: partialTranscript,
            in: currentTranscriptRouteContext(),
            videoIsInFront: { screenRead.frontVideoState != nil }
        )
        let inputs = voiceCommandInputs(frontVideoState: screenRead.frontVideoState, pageRead: screenRead.pageRead)
        let releaseOfThisPress = lastPushToTalkRelease?.pressCount == screenRead.pressCount ? lastPushToTalkRelease : nil
        let millisecondsAfterTheRelease = releaseOfThisPress.map { release in "\(Int(Date().timeIntervalSince(release.releasedAt) * 1000)) ms" } ?? "-"
        switch speculativeStartStep(
            partialTranscript: partialTranscript,
            partialRoute: partialRoute,
            approvalAtPress: inputs.approvalWhenTheCommandStarted,
            speculationIsOn: VoiceCommandSpeculation.isOn()
        ) {
        case .doNotStart(let reason):
            print("Voice command: did not start on the partial transcript, because \(reason)")
            return
        case .waitForOtherWords(let reason):
            print("Voice command: waits for newer partial words \(millisecondsAfterTheRelease) after the release, because \(reason)")
            voiceCommandSpeculation = .waitingForWords(screenRead)
            return
        case .start:
            break
        }
        do {
            let command = try startTheHarnessVoiceCommand(transcript: partialTranscript, inputs: inputs, waitsForTheFinalTranscript: true)
            voiceCommandSpeculation = .awaitingTheFinalTranscript(SpeculativeVoiceCommand(
                partialTranscript: partialTranscript,
                screenRead: screenRead,
                inputs: inputs,
                command: command
            ))
            // The words go in the log as the final transcript's do, so a discard shows what the two transcripts said.
            print("Voice command: started on the partial transcript \"\(partialTranscript)\" \(millisecondsAfterTheRelease) after the release, with \(inputs.tools.count) tools")
        } catch {
            print("Voice command: could not start on the partial transcript: \(error)")
        }
    }

    /// The words heard so far in the current press. A rehearsal step that starts with "%" stands in for them.
    private func partialTranscriptHeardSoFar() -> String {
        #if DEBUG
        if let rehearsalPartialTranscript { return rehearsalPartialTranscript }
        #endif
        return buddyDictationManager.partialTranscript
    }

    /// Ends what the last press started on its partial transcript: a start still waiting for the screen read, or a command
    /// waiting for the final transcript, which is discarded.
    private func endTheVoiceCommandSpeculation(because reason: String) {
        if let speculativeCommand = voiceCommandSpeculation.end() {
            discardTheSpeculativeVoiceCommand(speculativeCommand, because: reason)
        }
    }

    /// A press's dictation ended with no final transcript, so nothing will keep the command it started on its partial
    /// transcript, and it is discarded now instead of waiting in the harness until the next press.
    private func discardTheSpeculationOfAPressThatEndedWithNoTranscript(_ pressCount: Int) {
        if let speculativeCommand = voiceCommandSpeculation.endForAnEmptyFinalTranscript(ofPress: pressCount) {
            discardTheSpeculativeVoiceCommand(speculativeCommand, because: "the final transcript came back empty")
        }
    }

    /// Cancels a command started on the partial transcript. None of its calls ran, since the harness held them, so the
    /// cancel names no running call and the harness rolls the command back with nothing to report to the next one.
    private func discardTheSpeculativeVoiceCommand(_ speculativeCommand: SpeculativeVoiceCommand, because reason: String) {
        speculativeCommand.command.lines.commandWasCancelled()
        agentHarness.endVoiceCommand(taskID: speculativeCommand.command.commandID)
        print("Voice command: discarded the command started on the partial transcript, because \(reason)")
    }

    /// What decides a transcript's route, read from the app now.
    private func currentTranscriptRouteContext() -> TranscriptRouteContext {
        var sceneIsBuilding = false
        if case .buildingScene = liveScenePhase { sceneIsBuilding = true }
        return TranscriptRouteContext(
            themeStudioIsOpen: themeStudioController.isOpen,
            phaseIsWaitingForAQuizAnswer: liveScenePhaseIsWaitingForAQuizAnswer,
            liveSceneIsUpWithNoQuizQuestion: liveSceneIsUpWithNoQuizQuestion,
            sceneIsBuilding: sceneIsBuilding,
            sceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            brainTakesEveryRequest: BrainTakesEveryRequest.isOn(),
            backgroundSceneIsReady: readyBackgroundScene != nil,
            taskAnswerIsReady: taskAnswerWaitsToBeHeard,
            approvalIsWaiting: approvalAtThePressStillWaiting != nil,
            backgroundAgentIsRunning: backgroundAgentStore.anAgentIsRunning,
            backgroundAgentsArePaused: backgroundAgentStore.agentsArePaused,
            replayStopsAreRecorded: replayStopsAreRecordedForTheSceneOnScreen,
            furnitureGhostShows: roomArtPreviewController.phase.furnitureGhostShows,
            aRoomArtItemKeepsTheRoom: roomArtPreviewController.phase.keepsTheRoomForANewItem,
            shirtStillVoiceTargets: roomArtPreviewController.shirtStillVoiceTargetsForTheRoute,
            aRoomArtPhotoCanBeSaved: roomArtPreviewController.phase.photoTitleToSave != nil
        )
    }

    /// Which page is on screen right now, for telling a read of the page tools from a read of a page that is gone.
    private func currentVoiceCommandPageIdentity() -> VoiceCommandPageIdentity {
        let pageKind: VoiceCommandPageKind
        switch liveScenePageOnScreen {
        case nil: pageKind = .none
        case .generatedPage: pageKind = .generatedPage
        case .simulation: pageKind = .simulation
        case .framePopout: pageKind = .framePopout
        case .landmark: pageKind = .landmark
        }
        return VoiceCommandPageIdentity(
            overlayIsShowingAScene: LiveSceneOverlay.shared.isShowingAScene,
            scenesPlayedCount: LiveSceneOverlay.shared.scenesPlayedCount,
            pageKind: pageKind
        )
    }

    /// Drops the stored read, stops a read still starting, and cancels its page read. A transcript that takes the read
    /// clears `voiceCommandScreenRead` first, so the page read it keeps is not cancelled here.
    private func forgetTheVoiceCommandScreenRead() {
        voiceCommandScreenReadTask?.cancel()
        voiceCommandScreenReadTask = nil
        voiceCommandScreenRead?.pageRead.cancel()
        voiceCommandScreenRead = nil
    }

    /// The page's tools and state and the study guide check. The two page reads wait on WebKit, and the study guide check
    /// may wait on the Worker, not on each other.
    /// `frontVideoURLSource` is where the study guide check gets the front video's URL: the tab the release already read, or a
    /// fresh read of Chrome for a command that has no release read.
    private func readThePageForTheVoiceCommand(
        frontVideoState: JSONValue?,
        frontVideoURLSource: FrontVideoURLSource = .readNow
    ) async -> VoiceCommandPageRead {
        async let pageToolsRead = LiveSceneOverlay.shared.pageVoiceTools()
        async let pageStateRead = LiveSceneOverlay.shared.pageVoiceState()
        async let studyGuideExistsRead = studyGuideExistsForTheFrontVideo(frontVideoState: frontVideoState, frontVideoURLSource: frontVideoURLSource)
        let (pageTools, pageState, studyGuideExists) = await (pageToolsRead, pageStateRead, studyGuideExistsRead)
        return VoiceCommandPageRead(
            pageTools: pageTools,
            pageState: pageState,
            studyGuideExistsForTheFrontVideo: studyGuideExists,
            finishedAt: Date()
        )
    }

    /// The keyword path: a scene, a pop-out, or an answer about the screen. A scene or a pop-out is a look at the media,
    /// so it draws the loop. A plain answer does not, since no router decided that the request is about the media.
    private func respondByTheKeywordPath(transcript: String) {
        let requestedSceneKind = keywordPathSceneKind(for: transcript)
        if requestedSceneKind != nil {
            theRequestBecameALookAtTheMedia()
        }
        respondToTranscript(transcript: transcript, requestedSceneKind: requestedSceneKind)
    }

    /// The request became a look at the video or image Clicky sees, so the loop draws around it once its rect is in hand.
    /// Nothing draws while a scene covers the media or a quiz question is open, since the loop would frame the wrong thing.
    private func theRequestBecameALookAtTheMedia() {
        guard requestMayDrawALoop(
            aSceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            aQuizQuestionIsOpen: liveScenePhaseIsWaitingForAQuizAnswer || videoQuizQuestionIsActive
        ) else {
            return
        }
        cursorLoopController.requestBecameALookAtTheMedia()
    }

    /// The Theme Studio reads a region the learner circled, so the loop goes around the learner's own line.
    private func theRequestBecameALookAtTheCircledRegion(_ circledRegion: CircledRegion) {
        guard requestMayDrawALoop(
            aSceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            aQuizQuestionIsOpen: liveScenePhaseIsWaitingForAQuizAnswer || videoQuizQuestionIsActive
        ) else {
            return
        }
        cursorLoopController.requestBecameALookAtTheCircledRegion(circledRegion)
    }

    private var liveScenePhaseIsWaitingForAQuizAnswer: Bool {
        switch liveScenePhase {
        case .awaitingAnswer, .awaitingFollowUpOnWhatThePartDoes: return true
        case .idle, .buildingScene, .touring, .allLabelsShowing: return false
        }
    }

    /// The path every request took before voice tools: a quiz answer, a scene build, a pop-out, or a
    /// screenshot answer. requestedSceneKind comes from the transcript's keywords, or from the voice
    /// command model when it decides the request needs a new scene.
    private func respondToTranscript(transcript: String, requestedSceneKind: LiveSceneKind?) {
        // A new answer, scene, or pop-out takes the screen, so an open replay ends with its camera and cursor where they are.
        instantReplay.endIfOpen()
        currentResponseTask?.cancel()
        liveSceneRequestTask?.cancel()
        liveSceneTourFinishedTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        liveSceneRequestGeneration += 1
        let requestGeneration = liveSceneRequestGeneration

        // A push-to-talk press only stops Clicky talking, so a scene stays up until the learner asks to put it back.
        // A quiz question on screen is left alone, since the learner is answering it.
        if asksToPutTheSceneBack(transcript), liveSceneIsUpWithNoQuizQuestion {
            // The tour's finish task was cancelled above, so a touring scene is put back as if it had finished.
            liveScenePhase = .allLabelsShowing
            clearFinishedLiveScene()
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            print("Live scene: put back on request")
            return
        }

        // A 3D model only appears when the learner asks. It pauses the main video in Chrome's front tab, quiz or not,
        // so the video's narrator does not talk over Clicky. During a video quiz a pending question is set aside for the model.
        var sceneQuestion = transcript
        let requestedKind = requestedSceneKind
        // "Animate this" over a finished pop-out animates the picture already on screen instead of popping it out again.
        if requestedKind == .animatedFramePopout,
           case .allLabelsShowing = liveScenePhase,
           case .framePopout(let framePopoutOnScreen) = liveScenePageOnScreen {
            currentResponseTask = Task {
                await self.animateTheFramePopoutOnScreen(framePopoutOnScreen, requestGeneration: requestGeneration)
            }
            return
        }
        if requestedKind == .explore || requestedKind == .framePopout || requestedKind == .animatedFramePopout {
            let quizWatchesTheVideoInFront = videoQuizSession.isRunning && videoQuizSession.quizVideoIsTheTabInFront()
            let heardText = videoQuizSession.pauseVideoForRequestedScene()
            if quizWatchesTheVideoInFront {
                videoQuizQuestionIsActive = false
                liveScenePhase = .idle
                // The idle phase has no page, so the one on screen goes too. The new scene's own clear resumes the video.
                clearTheLiveSceneAndReleaseTheBuddy()
            }
            if !heardText.isEmpty {
                sceneQuestion = "\(transcript) The video just said: \(heardText)"
            }
        }

        if case .awaitingAnswer(let quiz, let wrongAnswerCount) = liveScenePhase {
            currentResponseTask = Task {
                await self.respondToLiveSceneAnswer(
                    transcript: transcript,
                    quiz: quiz,
                    wrongAnswerCount: wrongAnswerCount
                )
            }
            return
        }

        if case .awaitingFollowUpOnWhatThePartDoes(let quiz) = liveScenePhase {
            currentResponseTask = Task {
                await self.respondToLiveSceneFollowUpOnWhatThePartDoes(
                    transcript: transcript,
                    quiz: quiz
                )
            }
            return
        }

        if case .buildingScene = liveScenePhase {
            liveScenePhase = .idle
            // A plain question cancels the build, so the video Clicky paused for it plays again.
            // A new scene request keeps the pause for the new scene.
            if requestedKind == nil {
                Task {
                    await LiveSceneOverlay.shared.waitForReturnToFinish()
                    // A scene asked for while the old one returned owns the pause now.
                    guard aSceneThatEndedMayResumeItsVideo(liveScenePhase: self.liveScenePhase) else { return }
                    self.videoQuizSession.resumeVideoAfterRequestedScene()
                }
            }
        }

        if case .allLabelsShowing = liveScenePhase, requestedKind == nil {
            currentResponseTask = Task {
                await self.answerAboutTheLiveSceneOnScreen(transcript: transcript)
            }
            return
        }

        if requestedKind == .framePopout || requestedKind == .animatedFramePopout {
            clearFinishedLiveScene(resumesTheVideo: false)
            liveScenePhase = .buildingScene
            currentResponseTask = Task {
                await self.popOutTheVisibleVideoFrame(
                    requestGeneration: requestGeneration,
                    animatesWhatFlows: requestedKind == .animatedFramePopout
                )
            }
            return
        }

        if let requestedKind {
            clearFinishedLiveScene(resumesTheVideo: false)
            liveScenePhase = .buildingScene
            currentResponseTask = Task {
                await self.buildLiveSceneWithStatusLabel(
                    transcript: sceneQuestion,
                    sceneKind: requestedKind,
                    requestGeneration: requestGeneration
                )
            }
            return
        }

        currentResponseTask = Task {
            // Stay in processing state with the thinking dots, and show no streaming text
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt,
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    onTextChunk: { _ in
                        // No streaming text display, the thinking dots stay until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the thinking dots
                // stop, and do not follow the triangle as it flies to the target.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                // Play the response via TTS. Keep the thinking dots (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await speakTextEndingAnOpenReplay(spokenText)
                        // speakText returns once the first streamed audio is playing, so the voice state can switch now
                        voiceState = .responding
                    } catch is CancellationError {
                        // The learner spoke again, so this reply was interrupted on purpose.
                    } catch {
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again - response was interrupted
            } catch {
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// True when the YouTube frame on screen shows a famous place and its 3D tiles page is playing.
    private func playFamousPlaceFromTheVisibleVideo(learnerRequest: String, requestGeneration: Int) async -> Bool {
        let placeInFrame: (frameGrab: VideoFrameGrab, famousPlace: FamousPlace)?
        do {
            placeInFrame = try await VideoQuizSession.famousPlaceInTheVisibleFrame(
                workerBaseURL: Self.workerBaseURL,
                learnerRequest: learnerRequest
            )
        } catch {
            print("Landmark: lookup failed, building the scene instead: \(error.localizedDescription)")
            return false
        }
        guard requestGeneration == liveSceneRequestGeneration, !Task.isCancelled,
              let placeInFrame,
              let overlayScreen = overlayScreen(showing: placeInFrame.frameGrab),
              let landmarkPageHTML = landmarkTilesPageHTML(
                  for: placeInFrame.famousPlace,
                  frameGrab: placeInFrame.frameGrab,
                  overlayScreen: overlayScreen
              ),
              LiveSceneOverlay.shared.playLiveScene(html: landmarkPageHTML, hidesQuizLabel: false, rendersMapTiles: true, overlayScreen: overlayScreen) else {
            return false
        }
        print("Landmark: showing Google 3D tiles of \(placeInFrame.famousPlace.name)")
        liveScenePhase = .touring(quizToAskAfterTour: nil)
        liveScenePageOnScreen = .landmark(placeInFrame.famousPlace)
        return true
    }

    /// Lifts the subject of the paused YouTube frame, or of the largest image on any other page, out in 3D with every label showing.
    /// Sonnet and Vision take about 4 seconds, so there is no status line to speak.
    private func popOutTheVisibleVideoFrame(requestGeneration: Int, animatesWhatFlows: Bool) async {
        // A learner who asked to animate sees that word while the pop-out builds.
        LiveSceneStatusLabel.shared.show(animatesWhatFlows ? .animatingIt : .poppingItOut)
        defer {
            // Every exit hides the pop-out line, unless a newer request took over, whose own line is not ours to hide.
            if requestGeneration == liveSceneRequestGeneration {
                LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.popOutLines)
            }
        }
        await speakLiveSceneLine("Sure, let me pop that out.", isAFailure: false)
        guard !Task.isCancelled else { return }
        voiceState = .processing
        var framePopout: VideoFramePopout?
        var failureLine = "I couldn't find one thing in this frame to pop out."
        do {
            framePopout = try await VideoQuizSession.framePopoutOfTheVisibleFrame(workerBaseURL: Self.workerBaseURL)
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            print("Frame pop-out failed: \(error)")
            if let spokenFailure = (error as? LocalizedError)?.errorDescription {
                failureLine = spokenFailure
            }
        }
        guard requestGeneration == liveSceneRequestGeneration, !Task.isCancelled else { return }
        LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.popOutLines)

        guard let framePopout,
              let overlayScreen = overlayScreen(showing: framePopout.frameGrab),
              let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen, theme: themeSettings.shownTheme),
              LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: false, isFramePopout: true, overlayScreen: overlayScreen) else {
            liveScenePhase = .idle
            await speakLiveSceneLine(failureLine, isAFailure: true)
            voiceState = .idle
            // No scene opened, so nothing will clear it and resume the video.
            // A previous pop-out cleared for this request may still be landing back in its frame.
            await LiveSceneOverlay.shared.waitForReturnToFinish()
            // A scene asked for during the line or the return owns the pause now.
            if videoQuizSession.videoIsPausedForRequestedScene, aSceneThatEndedMayResumeItsVideo(liveScenePhase: liveScenePhase) {
                videoQuizSession.resumeVideoAfterRequestedScene()
            }
            return
        }
        print("Frame pop-out: lifting the subject out of the frame with \(framePopout.parts.count) labels\(framePopout.pictureShowsDepth ? " as a flat card" : "")")
        liveScenePhase = .touring(quizToAskAfterTour: nil)
        liveScenePageOnScreen = .framePopout(framePopout)
        // Sonnet draws the flows while the tour plays, and the page starts them when the tour ends.
        // A tap that stops the narration keeps the pop-out, so the flows task runs on, and showPictureFlows
        // drops them only when a newer request or another page took over.
        let pictureFlowsTask: Task<PictureFlowsOutcome, Never>? = animatesWhatFlows
            ? Task { await self.showPictureFlows(on: framePopout, requestGeneration: requestGeneration) }
            : nil
        // Idle during the tour so no thinking dots show, while the narration is written in the background.
        voiceState = .idle
        await narrateTheFramePopout(framePopout, narrationTrigger: .afterTour)
        guard !Task.isCancelled else { return }
        // A missing animation is said after the narration, so the two never talk over each other.
        let pictureFlowsOutcome = await pictureFlowsTask?.value
        // A tap while waiting cancels this task, and a line spoken now would cut off the tap's own narration.
        guard !Task.isCancelled else { return }
        if let spokenLine = pictureFlowsOutcome?.spokenLineWhenNotShowing {
            if pictureFlowsOutcome == .failed { VoiceToolCallChip.shared.show("Couldn't animate that one", sender: .failure) }
            await speakLiveSceneLine(spokenLine, isAFailure: pictureFlowsOutcome == .failed)
        }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func animateTheFramePopoutOnScreen(_ framePopout: VideoFramePopout, requestGeneration: Int) async {
        // An artwork is refused before any "animating" status or line, so Clicky never promises what it won't do.
        guard !framePopout.isArtwork else {
            print("Frame pop-out: leaving the artwork as the artist made it")
            if let artworkLine = PictureFlowsOutcome.leftTheArtworkAlone.spokenLineWhenNotShowing {
                await speakLiveSceneLine(artworkLine, isAFailure: false)
            }
            // A push-to-talk press cancels this task, and a hide scheduled now would fade the overlay while they talk.
            guard !Task.isCancelled else { return }
            scheduleTransientHideIfNeeded()
            return
        }
        LiveSceneStatusLabel.shared.show(.animatingIt)
        defer {
            // A newer request's own line is not ours to hide.
            if requestGeneration == liveSceneRequestGeneration {
                LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.popOutLines)
            }
        }
        let pictureFlowsTask = Task { await self.showPictureFlows(on: framePopout, requestGeneration: requestGeneration) }
        await speakLiveSceneLine("Sure, let me animate that.", isAFailure: false)
        // A fast "nothing flows" reply would otherwise cut this line off, since a new line stops the one playing.
        await waitForClickyToFinishSpeaking()
        guard !Task.isCancelled else { return }
        voiceState = .processing
        let pictureFlowsOutcome = await pictureFlowsTask.value
        guard !Task.isCancelled else { return }
        LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.popOutLines)
        voiceState = .idle
        if let spokenLine = pictureFlowsOutcome.spokenLineWhenNotShowing {
            if pictureFlowsOutcome == .failed { VoiceToolCallChip.shared.show("Couldn't animate that one", sender: .failure) }
            await speakLiveSceneLine(spokenLine, isAFailure: pictureFlowsOutcome == .failed)
        }
        guard !Task.isCancelled else { return }
        scheduleTransientHideIfNeeded()
    }

    private func showPictureFlows(on framePopout: VideoFramePopout, requestGeneration: Int) async -> PictureFlowsOutcome {
        // An artwork is never animated, so its flows are never asked for.
        guard !framePopout.isArtwork else {
            print("Frame pop-out: leaving the artwork as the artist made it")
            return .leftTheArtworkAlone
        }
        let pictureFlows: [PictureFlow]
        do {
            pictureFlows = try await PictureFlowsClient.requestFlows(workerBaseURL: Self.workerBaseURL, framePopout: framePopout)
        } catch {
            print("Frame pop-out: picture flows failed: \(error.localizedDescription)")
            return Task.isCancelled ? .superseded : .failed
        }
        guard requestGeneration == liveSceneRequestGeneration, !Task.isCancelled else { return .superseded }
        // Escape clears the scene without a new request, so flows that arrive after it have no pop-out to go on.
        switch liveScenePhase {
        case .touring, .allLabelsShowing:
            break
        default:
            return .superseded
        }
        // A video quiz question can replace the page without a new request, so the flows go only on their own pop-out.
        guard case .framePopout(let framePopoutOnScreen) = liveScenePageOnScreen,
              framePopoutOnScreen.frameGrab.jpeg == framePopout.frameGrab.jpeg else {
            return .superseded
        }
        guard !pictureFlows.isEmpty else {
            print("Frame pop-out: nothing flows through this picture")
            return .nothingFlows
        }
        LiveSceneOverlay.shared.showFlows(pictureFlows)
        print("Frame pop-out: streaming \(pictureFlows.count) flows")
        return .showing(flowCount: pictureFlows.count)
    }

    /// Clicky says each build status out loud as the label shows it, so the
    /// 20 second wait does not feel like the app froze. The screen read ends
    /// while the first line is still playing, so only the build lines are spoken.
    private func buildLiveSceneWithStatusLabel(
        transcript: String,
        sceneKind: LiveSceneKind,
        requestGeneration: Int
    ) async {
        LiveSceneStatusLabel.shared.show(.readingYourScreen)
        defer {
            // Every exit hides the build lines, unless a newer request took over, whose own line is not ours to hide.
            if requestGeneration == liveSceneRequestGeneration {
                LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines)
            }
        }
        await speakLiveSceneLine("Sure, let me build that for you.", isAFailure: false)
        guard !Task.isCancelled else { return }
        voiceState = .processing
        var cursorScreenJPEGData: Data?
        var labeledImages: [(data: Data, label: String)] = []
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            cursorScreenJPEGData = (screenCaptures.first { $0.isCursorScreen } ?? screenCaptures.first)?.imageData
            labeledImages = screenCaptures.map { capture in
                (data: capture.imageData, label: capture.label)
            }
        } catch {
            print("Live scene screen capture failed: \(error)")
        }
        guard !Task.isCancelled else { return }

        if let cursorScreenJPEGData {
            LiveSceneStatusLabel.shared.show(.buildingYourScene)
            let almostThereTask = Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                // A newer build owns the label now, so this older one must not swap its line.
                guard !Task.isCancelled, requestGeneration == self.liveSceneRequestGeneration else { return }
                // A press that hid the label must not bring it back, so this swaps only while "Building" shows.
                LiveSceneStatusLabel.shared.replace(.buildingYourScene, with: .almostThere)
                await self.speakLiveSceneStatus("Almost there")
            }
            let sceneRequestTask = Task {
                // A famous place in a paused video shows Google's real 3D scan instead of a generated model.
                if sceneKind == .explore, await self.playFamousPlaceFromTheVisibleVideo(
                    learnerRequest: transcript,
                    requestGeneration: requestGeneration
                ) {
                    return
                }
                await self.requestAndPlayLiveScene(
                    question: transcript,
                    sceneKind: sceneKind,
                    cursorScreenJPEGData: cursorScreenJPEGData,
                    requestGeneration: requestGeneration
                )
            }
            liveSceneRequestTask = sceneRequestTask
            let buildingLineTask = Task {
                await self.speakLiveSceneStatus("Building your 3D scene")
            }
            await sceneRequestTask.value
            almostThereTask.cancel()
            buildingLineTask.cancel()
        }
        guard requestGeneration == liveSceneRequestGeneration, !Task.isCancelled else { return }
        LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines)

        guard case .touring = liveScenePhase else {
            await sayTheSceneCouldNotBeBuilt()
            return
        }
        if case .landmark(let famousPlace) = liveScenePageOnScreen {
            await speakTheLandmarkLineAfterItsTour(famousPlace)
        } else if sceneKind == .explore {
            await speakAboutTheLiveSceneOnScreen(transcript: transcript, labeledImages: labeledImages)
        }
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func answerAboutTheLiveSceneOnScreen(transcript: String) async {
        voiceState = .processing
        do {
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            await speakAboutTheLiveSceneOnScreen(
                transcript: transcript,
                labeledImages: screenCaptures.map { capture in
                    (data: capture.imageData, label: capture.label)
                }
            )
        } catch {
            print("Live scene follow-up failed: \(error)")
        }
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// Speaks one sentence per part and highlights that part as it is spoken, so
    /// the learner can follow along on a busy model.
    private func speakAboutTheLiveSceneOnScreen(
        transcript: String,
        labeledImages: [(data: Data, label: String)]
    ) async {
        do {
            let partLabels = await LiveSceneOverlay.shared.partLabels()
            let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: labeledImages,
                systemPrompt: Self.companionVoiceResponseSystemPrompt
                    + Self.liveSceneExploreVoiceResponseInstructions(partLabels: partLabels),
                userPrompt: transcript,
                onTextChunk: { _ in }
            )
            while case .touring = liveScenePhase, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let spokenText = Self.parsePointingCoordinates(from: fullResponseText).spokenText
            for spokenPart in liveSceneSpokenParts(from: spokenText) {
                guard !Task.isCancelled else { return }
                if let partLabel = spokenPart.partLabel {
                    LiveSceneOverlay.shared.highlightPart(labelText: partLabel)
                }
                await speakLiveSceneLine(spokenPart.spokenText, isAFailure: false)
                await waitForClickyToFinishSpeaking()
            }
            LiveSceneOverlay.shared.highlightPart(labelText: "")
        } catch {
            print("Live scene explore reply failed: \(error)")
        }
    }

    /// Runs when a simulation's tour ends, which the page reports whatever else Clicky is doing, so a push-to-talk
    /// press during the tour never loses the question. The panel shows the hypothesis, and Clicky asks it out loud
    /// unless the learner already guessed. Run stays locked until `record_guess` hears an answer.
    private func askTheSimulationQuestionAfterItsTour() {
        guard case .simulation = liveScenePageOnScreen, let simulationLesson else { return }
        LiveSceneOverlay.shared.showTheSimulationQuestion(simulationLesson.predictionQuestion)
        guard simulationLesson.guess == .waiting else { return }
        liveSceneTourFinishedTask?.cancel()
        liveSceneTourFinishedTask = Task {
            await self.waitUntilTheVoiceAnswerIsQuiet()
            // Escape can close the scene during the wait, and a question with nothing on screen makes no sense.
            guard !Task.isCancelled, self.simulationLesson?.guess == .waiting,
                  case .simulation = self.liveScenePageOnScreen, LiveSceneOverlay.shared.isShowingAScene else { return }
            if await self.speakSimulationLine(simulationLesson.guessInvitation) {
                print("Simulation: asked for the guess")
            }
            guard !Task.isCancelled, self.voiceState == .responding else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// The router heard an answer to the prediction question. The guess is kept for the check after the runs.
    /// The page unlocks first, so a guess is recorded only when the learner did not already skip it with the button.
    private func recordTheSimulationGuess(_ spokenGuess: String) async -> VoiceToolOutcome {
        guard case .simulation = liveScenePageOnScreen, simulationLesson?.guess == .waiting else {
            return .failed(error: "No simulation is waiting for a guess", state: nil)
        }
        // Checked before the page unlocks, so a blank call never uses up the guess.
        guard !spokenGuess.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failed(error: "The guess was empty, so put the learner's words in guess", state: nil)
        }
        guard await LiveSceneOverlay.shared.unlockTheSimulationAfterTheGuess() else {
            return .failed(error: "The guess was already skipped, or the simulation is not on screen anymore", state: nil)
        }
        guard simulationLesson?.recordGuess(spokenGuess) == true else {
            return .failed(error: "The guess was empty", state: nil)
        }
        print("Simulation: guess recorded")
        return .changed(state: await LiveSceneOverlay.shared.pageVoiceState())
    }

    /// What Clicky says after a run, whether the learner pressed Run or asked for it by voice. In the challenge it is
    /// how close the try was. Before that it is the readouts, then, until the runs answer the prediction, the guess check:
    /// whether the guess was right and why, or what to try next. Once settled the challenge starts.
    /// The report comes from the page, so it is used only while Clicky's own record says a simulation is on screen.
    private func narrateTheSimulationRun(_ runReport: SimulationRunReport) {
        guard simulationRunMayBeNarrated(
            pageOnScreen: liveScenePageOnScreen,
            sceneIsShowing: LiveSceneOverlay.shared.isShowingAScene,
            quizQuestionIsWaiting: liveScenePhaseIsWaitingForAQuizAnswer,
            lessonExists: simulationLesson != nil
        ) else {
            return
        }
        simulationRunNarrationTask?.cancel()
        let narrationTask = Task {
            await self.waitUntilTheVoiceAnswerIsQuiet()
            guard !Task.isCancelled else { return }
            await self.speakTheWaitingChallengePrompt()
            let narrationStep = simulationRunNarrationStep(
                reportHasAChallengeOutcome: runReport.challengeOutcome != nil,
                challengeIsRunning: self.simulationLesson?.challengeIsRunning == true
            )
            if narrationStep == .sayTheChallengeOutcome, let challengeOutcome = runReport.challengeOutcome {
                if case .hit = challengeOutcome {
                    self.simulationLesson?.challengeIsRunning = false
                    self.themeSettings.shownTheme.sounds.correct.play()
                    self.playCursorEmote(.hop)
                }
                await self.speakSimulationLine(simulationChallengeSpokenLine(for: challengeOutcome))
            } else {
                if let readoutLine = simulationReadoutSpokenLine(for: runReport.readouts) {
                    await self.speakSimulationLine(readoutLine)
                }
                await self.checkTheSimulationGuessAndStartTheChallenge(runReport: runReport)
            }
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
        simulationRunNarrationTask = narrationTask
        currentResponseTask = narrationTask
    }

    private func checkTheSimulationGuessAndStartTheChallenge(runReport: SimulationRunReport) async {
        guard let lesson = simulationLesson, !lesson.predictionIsSettled else { return }
        // Counted before the check runs, so a learner whose push-to-talk keeps cancelling it still reaches the challenge.
        simulationLesson?.runsChecked += 1
        let runsChecked = simulationLesson?.runsChecked ?? 0
        let guessCheckStep = simulationGuessCheckStep(trialsTryMoreThanOneSetting: runReport.trialsTryMoreThanOneSetting, runsChecked: runsChecked)
        if guessCheckStep != .checkTheGuess {
            print("Simulation: guess check skipped after run \(runsChecked), one setting tried")
        }
        if guessCheckStep == .askForAnotherSetting {
            await speakSimulationLine(simulationTryAnotherSettingLine)
            return
        }
        let predictionCheck: SimulationPredictionCheck
        if guessCheckStep == .moveOnWithTheExplanation {
            // An open check moves on with the explanation at this run count, so none is asked for.
            predictionCheck = SimulationPredictionCheck(spokenLine: lesson.physicsExplanation, predictionIsSettled: false)
        } else {
            voiceState = .processing
            do {
                let (replyText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: [],
                    systemPrompt: simulationPredictionCheckSystemPrompt,
                    userPrompt: simulationPredictionCheckUserPrompt(lesson: lesson, runReport: runReport),
                    onTextChunk: { _ in }
                )
                predictionCheck = SimulationPredictionCheck(replyText: replyText)
            } catch {
                predictionCheck = SimulationPredictionCheck(spokenLine: lesson.physicsExplanation, predictionIsSettled: true)
                if !Task.isCancelled {
                    print("Simulation: the guess check failed, so Clicky says the page's explanation: \(error)")
                }
            }
        }
        // A newer run's narration cancels this one and then waits for Clicky to be quiet, so the processing
        // state this check set must end here, cancelled or not, or that narration would wait forever.
        if voiceState == .processing {
            voiceState = .idle
        }
        guard !Task.isCancelled else { return }
        let lessonMovesOn = predictionCheck.predictionIsSettled || runsChecked >= SimulationLesson.mostRunsCheckedBeforeTheChallenge
        if guessCheckStep == .checkTheGuess {
            print("Simulation: guess check after run \(runsChecked), settled \(predictionCheck.predictionIsSettled)")
        }
        if predictionCheck.predictionIsSettled {
            await speakSimulationLine(predictionCheck.spokenLine)
        } else if lessonMovesOn {
            // An open check says what to try next, which the lesson no longer waits for, so the learner hears why instead.
            await speakSimulationLine(lesson.physicsExplanation)
        } else {
            await speakSimulationLine(predictionCheck.spokenLine)
        }
        guard lessonMovesOn, !Task.isCancelled else { return }
        simulationLesson?.predictionIsSettled = true
        guard let challengePrompt = await LiveSceneOverlay.shared.startTheSimulationChallenge() else { return }
        print("Simulation: challenge started")
        simulationLesson?.challengeIsRunning = true
        simulationLesson?.challengePromptWaitingToBeSpoken = "\(challengePrompt) \(simulationChallengeStartSuffix)"
        await speakTheWaitingChallengePrompt()
    }

    /// The challenge has started on the page once its prompt waits here, so a narration that a newer run cancels
    /// leaves the prompt for the next narration to say first, and the challenge never starts in silence.
    private func speakTheWaitingChallengePrompt() async {
        guard let challengePromptLine = simulationLesson?.challengePromptWaitingToBeSpoken, !Task.isCancelled else { return }
        print("Simulation: saying \"\(challengePromptLine)\"")
        await speakLiveSceneLine(challengePromptLine, isAFailure: false)
        // The audio has started once speaking returns uncancelled, so it is cleared now, before the wait, or a newer
        // narration that waits for this audio to end would say the prompt a second time.
        guard !Task.isCancelled else { return }
        simulationLesson?.challengePromptWaitingToBeSpoken = nil
        await waitForClickyToFinishSpeaking()
    }

    /// Returns true when the line's own audio started and the task was not cancelled before playback stopped, so a
    /// cancel or the credits fallback reads as unsaid. A push-to-talk press stops the audio without a cancel, so it
    /// still reads as said.
    @discardableResult
    private func speakSimulationLine(_ line: String) async -> Bool {
        guard !Task.isCancelled, !line.isEmpty else { return false }
        print("Simulation: saying \"\(line)\"")
        let lineAudioStarted = await speakLiveSceneLine(line, isAFailure: false)
        await waitForClickyToFinishSpeaking()
        return lineAudioStarted && !Task.isCancelled
    }

    /// Every clear goes through here. A narration holds the buddy on a part until it releases it, and a
    /// cancelled narration can stay stuck reading label places from a page that is gone, so the clear releases it.
    /// The page's record and an experiment's lesson end here too, so the voice router never reads a question of a scene that is gone.
    func clearTheLiveSceneAndReleaseTheBuddy() {
        instantReplay.forget()
        LiveSceneOverlay.shared.clear()
        liveScenePageOnScreen = nil
        simulationLesson = nil
        if detectedElementPointingHold.holdsUntilReleased {
            clearDetectedElementLocation()
        }
    }

    private func clearFinishedLiveScene(resumesTheVideo: Bool = true) {
        guard case .allLabelsShowing = liveScenePhase else { return }
        clearTheLiveSceneAndReleaseTheBuddy()
        liveScenePhase = .idle
        guard resumesTheVideo, videoQuizSession.videoIsPausedForRequestedScene else { return }
        Task {
            await self.speakLiveSceneLine("Okay, back to the video.", isAFailure: false)
            await self.waitForClickyToFinishSpeaking()
            // Speaking the line set the voice state to responding, and a quiz asks its next question only when idle.
            if self.voiceState == .responding {
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            // A frame pop-out lands back in the paused frame before the video moves.
            await LiveSceneOverlay.shared.waitForReturnToFinish()
            // A scene asked for during the line or the return owns the pause now.
            guard aSceneThatEndedMayResumeItsVideo(liveScenePhase: self.liveScenePhase) else { return }
            self.videoQuizSession.resumeVideoAfterRequestedScene()
        }
    }

    private func requestAndPlayLiveScene(
        question: String,
        sceneKind: LiveSceneKind,
        cursorScreenJPEGData: Data,
        requestGeneration: Int
    ) async {
        guard requestGeneration == liveSceneRequestGeneration else { return }
        // Read before the request, so the rect matches the screenshot taken just before it.
        let mediaRectToRiseFrom = VideoQuizSession.screenRectOfTheMediaToRiseFrom()
        do {
            let liveScene = try await liveSceneClient.requestLiveScene(
                question: question,
                cursorScreenJPEGData: cursorScreenJPEGData,
                sceneKind: sceneKind,
                buildWait: .whileTheLearnerWatches
            )
            guard requestGeneration == liveSceneRequestGeneration else { return }
            // The rise starts from the cursor screen's screenshot, so the scene plays on that screen.
            guard let overlayScreen = screenUnderTheMouseCursor() else { return }
            _ = playGeneratedScenePage(
                html: liveScene.html,
                pageOnScreen: .generatedPage,
                quizToAskAfterTour: sceneKind == .quiz ? liveScene.quiz : nil,
                overlayScreen: overlayScreen,
                screenJPEGData: cursorScreenJPEGData,
                mediaRectToRiseFrom: mediaRectToRiseFrom
            )
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Live scene request failed: \(error.localizedDescription)")
        }
    }

    /// Plays a page from `POST /live-scene` on overlayScreen, rising out of the media rect when there is one and a
    /// screenshot of that same screen to rise from. Returns whether the overlay took the page.
    private func playGeneratedScenePage(
        html generatedPageHTML: String,
        pageOnScreen: LiveScenePageOnScreen,
        quizToAskAfterTour: LiveSceneQuiz?,
        overlayScreen: NSScreen,
        screenJPEGData: Data?,
        mediaRectToRiseFrom: ScreenRectInChromeCoordinates?
    ) -> Bool {
        var liveScenePageHTML = generatedPageHTML
        if let mediaRectToRiseFrom, let screenJPEGData,
           let riseScript = liveSceneRiseScriptFromTheBundle() {
            liveScenePageHTML = liveScenePageThatRisesFromTheSource(
                generatedPageHTML: generatedPageHTML,
                screenJPEGBase64: screenJPEGData.base64EncodedString(),
                sourceRectInOverlayPage: rectInOverlayPage(of: mediaRectToRiseFrom, overlayScreen: overlayScreen),
                riseScript: riseScript
            )
        }
        let liveSceneWasAccepted = LiveSceneOverlay.shared.playLiveScene(
            html: liveScenePageHTML,
            hidesQuizLabel: quizToAskAfterTour != nil,
            overlayScreen: overlayScreen
        )
        guard liveSceneWasAccepted else { return false }
        liveScenePhase = .touring(quizToAskAfterTour: quizToAskAfterTour)
        liveScenePageOnScreen = pageOnScreen
        return true
    }

    private func respondToLiveSceneAnswer(
        transcript: String,
        quiz: LiveSceneQuiz,
        wrongAnswerCount: Int
    ) async {
        voiceState = .processing
        let judgedAnswer: LiveSceneJudgedAnswer
        do {
            judgedAnswer = try await liveSceneClient.judgeSpokenAnswer(
                question: quiz.question,
                answerLabel: quiz.answerLabel,
                explanation: quiz.explanation,
                transcript: transcript,
                heardTranscript: quiz.heardTranscript
            )
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Live scene answer judge failed, using the word match: \(error.localizedDescription)")
            // The word match grades the answer, and these lines stand in for the model's spoken reply.
            let wordMatchGrade = LiveSceneAnswerJudge.gradeSpokenAnswer(
                transcript: transcript,
                quiz: quiz
            )
            switch wordMatchGrade {
            case .nameAndFunctionWord:
                judgedAnswer = LiveSceneJudgedAnswer(
                    verdict: .answer(wordMatchGrade),
                    spokenReply: spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: true)
                )
            case .nameOnly:
                judgedAnswer = LiveSceneJudgedAnswer(
                    verdict: .answer(wordMatchGrade),
                    spokenReply: "Yes, it's \(quiz.answerLabel.lowercased()). And what does it do?"
                )
            case .askedForHelp:
                judgedAnswer = LiveSceneJudgedAnswer(
                    verdict: .answer(wordMatchGrade),
                    spokenReply: spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false)
                )
            case .wrong:
                judgedAnswer = LiveSceneJudgedAnswer(
                    verdict: .answer(wordMatchGrade),
                    spokenReply: "Not quite. Take another look."
                )
            }
        }
        let grade: LiveSceneQuizGrade
        switch judgedAnswer.verdict {
        case .control(let quizControl):
            await respondToQuizControl(quizControl, transcript: transcript, quiz: quiz, judgeSpokenReply: judgedAnswer.spokenReply)
            return
        case .answer(let answerGrade):
            grade = answerGrade
        }
        let spokenLine = applyJudgedLiveSceneAnswer(
            grade: grade,
            judgeSpokenReply: judgedAnswer.spokenReply,
            quiz: quiz,
            wrongAnswerCount: wrongAnswerCount
        )
        await speakLiveSceneLine(spokenLine, isAFailure: false)
        await resumeVideoQuizAfterExplanation()
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// The first wrong answer keeps the model's sentence, which does not give the answer away, and offers a hint.
    /// A second wrong answer uses the closing line, so the learner hears what the part does.
    private func applyJudgedLiveSceneAnswer(
        grade: LiveSceneQuizGrade,
        judgeSpokenReply: String,
        quiz: LiveSceneQuiz,
        wrongAnswerCount: Int
    ) -> String {
        let revealOutcome = LiveSceneRevealOutcome(grade: grade, wrongAnswerCount: wrongAnswerCount)
        LiveSceneOverlay.shared.revealQuizLabel(outcome: revealOutcome, correctAnswerSound: themeSettings.shownTheme.sounds.correct)
        if let emoteForTheAnswer = cursorEmote(forAnswerOutcome: revealOutcome) { playCursorEmote(emoteForTheAnswer) }
        // After a first wrong answer the question is still open, so its bubble stays for the learner to read again.
        if !(grade == .wrong && wrongAnswerCount == 0) {
            releaseTheBuddyFromTheQuizQuestion()
        }
        if videoQuizQuestionIsActive, let studyGuideOutcome = studyGuideQuizOutcome(grade: grade, wrongAnswerCount: wrongAnswerCount),
           videoQuizSession.recordTheOpenQuestionOutcome(studyGuideOutcome) {
            refreshTheStudyGuideAfterAQuizOutcome(studyGuideOutcome)
        }
        switch grade {
        case .nameAndFunctionWord:
            liveScenePhase = .allLabelsShowing
            return judgeSpokenReply
        case .nameOnly:
            liveScenePhase = .awaitingFollowUpOnWhatThePartDoes(quiz)
            return judgeSpokenReply
        case .askedForHelp:
            liveScenePhase = .allLabelsShowing
            return judgeSpokenReply
        case .wrong:
            if wrongAnswerCount == 0 {
                liveScenePhase = .awaitingAnswer(quiz, wrongAnswerCount: 1)
                return firstWrongAnswerSpokenLine(judgeSpokenReply: judgeSpokenReply)
            }
            liveScenePhase = .allLabelsShowing
            return spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false)
        }
    }

    /// The learner asked to skip, repeat, get a hint, or change the view instead of answering.
    /// The question stays open for a repeat, a hint, or a view change.
    private func respondToQuizControl(
        _ quizControl: LiveSceneQuizControl,
        transcript: String,
        quiz: LiveSceneQuiz,
        judgeSpokenReply: String
    ) async {
        switch quizControl {
        case .skipQuestion:
            if videoQuizQuestionIsActive {
                skipTheVideoQuizQuestion()
                return
            }
            liveScenePhase = .allLabelsShowing
            LiveSceneOverlay.shared.revealQuizLabel(outcome: .revealWithoutCelebration, correctAnswerSound: themeSettings.shownTheme.sounds.correct)
            await speakLiveSceneLine(spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false), isAFailure: false)
        case .repeatQuestion:
            await speakLiveSceneLine(quiz.question, isAFailure: false)
        case .giveHint:
            // The camera turns to the part still labeled "?", which is the hint the eyes get.
            LiveSceneOverlay.shared.highlightPart(labelText: quiz.answerLabel)
            await speakLiveSceneLine(judgeSpokenReply.isEmpty ? "Here's a hint: look at the part that's glowing." : judgeSpokenReply, isAFailure: false)
        case .sceneCommand:
            startVoiceCommand(
                transcript: transcript,
                frontVideoState: videoQuizSession.frontVideoStateForVoiceCommands(),
                timing: VoiceCommandTimingRecorder(pushToTalkReleasedAt: nil, transcriptReadyAt: Date())
            )
            return
        }
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func respondToLiveSceneFollowUpOnWhatThePartDoes(
        transcript: String,
        quiz: LiveSceneQuiz
    ) async {
        voiceState = .processing
        let spokenLine: String
        do {
            let judgedAnswer = try await liveSceneClient.judgeSpokenAnswer(
                question: quiz.question,
                answerLabel: quiz.answerLabel,
                explanation: quiz.explanation,
                transcript: transcript,
                heardTranscript: quiz.heardTranscript
            )
            if case .control(let quizControl) = judgedAnswer.verdict {
                // A hint, a repeat, a skip, or a view command is not an answer, so the follow-up stays open.
                await respondToQuizControl(quizControl, transcript: transcript, quiz: quiz, judgeSpokenReply: judgedAnswer.spokenReply)
                return
            }
            if judgedAnswer.verdict == .answer(.nameAndFunctionWord) {
                spokenLine = judgedAnswer.spokenReply
            } else {
                spokenLine = spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false)
            }
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Live scene answer judge failed, using the word match: \(error.localizedDescription)")
            let transcriptSaysWhatThePartDoes = LiveSceneAnswerJudge.transcriptIncludesFunctionWord(
                transcript: transcript,
                functionWords: quiz.functionWords
            )
            spokenLine = spokenLineAfterTheQuizEnds(
                quiz: quiz,
                learnerSaidWhatThePartDoes: transcriptSaysWhatThePartDoes
            )
        }
        liveScenePhase = .allLabelsShowing
        await speakLiveSceneLine(spokenLine, isAFailure: false)
        await resumeVideoQuizAfterExplanation()
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func handleVideoQuizVoiceCommand(_ videoQuizCommand: VideoQuizVoiceCommand) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()

        let spokenLine: String
        switch videoQuizCommand {
        case .start:
            videoQuizSummaryPanelController.close(animated: true)
            videoQuizSession.start()
            spokenLine = "Sure, let me read through this video."
        case .stop:
            // The quiz summary Card shows over the video when the quiz ends, so an open replay ends first and its control goes with it.
            instantReplay.endAndForget()
            // A question's block below resets the phase, so whether a scene was building is read first.
            let aSceneWasBuilding: Bool
            if case .buildingScene = liveScenePhase { aSceneWasBuilding = true } else { aSceneWasBuilding = false }
            if videoQuizQuestionIsActive {
                videoQuizQuestionIsActive = false
                liveScenePhase = .idle
                clearTheLiveSceneAndReleaseTheBuddy()
            }
            videoQuizSession.stop()
            // The scene request runs in its own task, so cancelling the response task above
            // does not reach it. A new generation also keeps a reply already in flight from playing.
            if aSceneWasBuilding {
                liveSceneRequestTask?.cancel()
                liveSceneRequestTask = nil
                liveSceneRequestGeneration += 1
                LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines)
                liveScenePhase = .idle
            }
            // A question's pop-out lands back in its frame before the video Clicky paused for it plays.
            // The scene that would have resumed a video paused for it is gone, so nothing else will.
            Task {
                await LiveSceneOverlay.shared.waitForReturnToFinish()
                self.videoQuizSession.resumeVideoAfterQuestion()
                // A scene asked for during the return owns the pause now.
                if aSceneWasBuilding, aSceneThatEndedMayResumeItsVideo(liveScenePhase: self.liveScenePhase) {
                    self.videoQuizSession.resumeVideoAfterRequestedScene()
                }
            }
            spokenLine = "Okay, I'll stop quizzing."
        }

        currentResponseTask = Task {
            await self.speakLiveSceneLine(spokenLine, isAFailure: false)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Speaks a line from the video quiz after whatever Clicky is already saying,
    /// so a quick failure does not cut off "Let me read through this video."
    private func speakVideoQuizLine(_ line: String, isAFailure: Bool) {
        let previousSpokenLineTask = currentResponseTask
        currentResponseTask = Task {
            await previousSpokenLineTask?.value
            await self.waitUntilTheVoiceAnswerIsQuiet()
            guard !Task.isCancelled else { return }
            await self.speakLiveSceneLine(line, isAFailure: isAFailure)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// With a frame pop-out, the subject lifts out of the paused video and the question
    /// comes when its tour ends. Without one, Clicky asks by voice right away.
    private func askVideoQuizQuestion(_ quiz: LiveSceneQuiz, framePopout: VideoFramePopout?) {
        // A narration of the finished pop-out could otherwise go on to highlight and point at the question's labels, the answer included.
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        clearFinishedLiveScene()
        videoQuizQuestionIsActive = true
        if let framePopout,
           let overlayScreen = overlayScreen(showing: framePopout.frameGrab),
           let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen, theme: themeSettings.shownTheme),
           LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: true, isFramePopout: true, overlayScreen: overlayScreen) {
            print("Video quiz: lifting the subject out of the frame with \(framePopout.parts.count) labels\(framePopout.pictureShowsDepth ? " as a flat card" : "")")
            liveScenePhase = .touring(quizToAskAfterTour: quiz)
            liveScenePageOnScreen = .framePopout(framePopout)
            return
        }
        liveScenePhase = .awaitingAnswer(quiz, wrongAnswerCount: 0)
        currentResponseTask = Task {
            await self.speakLiveSceneLine(quiz.question, isAFailure: false)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    private func waitForClickyToFinishSpeaking() async {
        while elevenLabsTTSClient.isPlaying && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// A video quiz question is over once the quiz reaches .allLabelsShowing. The
    /// explanation is already playing, so press play only after it ends.
    private func resumeVideoQuizAfterExplanation() async {
        guard videoQuizQuestionIsActive, case .allLabelsShowing = liveScenePhase else { return }
        videoQuizQuestionIsActive = false
        liveScenePhase = .idle
        await waitForClickyToFinishSpeaking()
        // The learner needs a moment with the explanation before the video moves on.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await speakLiveSceneLine("Okay, back to the video.", isAFailure: false)
        await waitForClickyToFinishSpeaking()
        try? await Task.sleep(nanoseconds: 500_000_000)
        // A frame pop-out sits over the video, so it lands back in its frame and goes away before play.
        clearTheLiveSceneAndReleaseTheBuddy()
        await LiveSceneOverlay.shared.waitForReturnToFinish()
        videoQuizSession.resumeVideoAfterQuestion()
    }

    private func spokenLineAfterTheQuizEnds(quiz: LiveSceneQuiz, learnerSaidWhatThePartDoes: Bool) -> String {
        if learnerSaidWhatThePartDoes {
            return "Yes. \(quiz.explanation)"
        }
        return "Good try. \(quiz.explanation)"
    }

    /// No scene is on screen, so nothing else will resume a video paused for it.
    private func sayTheSceneCouldNotBeBuilt() async {
        liveScenePhase = .idle
        VoiceToolCallChip.shared.show("Couldn't build that one", sender: .failure)
        await speakLiveSceneLine("Sorry, I couldn't build that one.", isAFailure: true)
        voiceState = .idle
        // A pop-out whose page failed may still be landing back in its frame.
        await LiveSceneOverlay.shared.waitForReturnToFinish()
        // A scene asked for during the line or the return owns the pause now.
        guard aSceneThatEndedMayResumeItsVideo(liveScenePhase: liveScenePhase) else { return }
        videoQuizSession.resumeVideoAfterRequestedScene()
    }

    /// A page that throws before its tour ends never posts tourFinished, so Clicky would wait on it forever.
    private func handleLiveScenePageError(_ pageErrorText: String) {
        guard case .touring(let quizToAskAfterTour) = liveScenePhase else { return }
        print("Live scene: giving up on the page after \(pageErrorText)")
        clearTheLiveSceneAndReleaseTheBuddy()
        if quizToAskAfterTour != nil {
            // The question still works by voice, like a quiz moment with no pop-out.
            handleLiveSceneTourFinished()
            return
        }
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        currentResponseTask = Task {
            await self.sayTheSceneCouldNotBeBuilt()
        }
    }

    /// Runs the step `escapeStep(for:)` returns for what is open now. The order is documented on `escapeStep(for:)`.
    /// A pop-out landing in its frame hides at once. With no scene up, Escape stops the answer Clicky is giving. A finished
    /// scene clears along with anything Clicky is still saying about it.
    private func closeLiveSceneOnEscape() {
        let sceneOnScreen: EscapeSceneState
        switch liveScenePhase {
        case .idle: sceneOnScreen = .none
        case .allLabelsShowing: sceneOnScreen = .finishedWithAllLabels
        case .buildingScene, .touring, .awaitingAnswer, .awaitingFollowUpOnWhatThePartDoes: sceneOnScreen = .buildingOrTouringOrAsking
        }
        let escapeFacts = EscapeFacts(
            // The event tap also sees an Escape a text field takes as its cancel.
            aTextFieldIsBeingEdited: NSApp.keyWindow?.firstResponder is NSText,
            // The panel may close before this runs, so this also counts an Escape it closed on a moment ago.
            theMenuPanelTookTheEscape: menuPanelTookTheEscape(),
            theSettingsDialIsOpen: settingsDialController.isOpen,
            theAgentListIsOpen: agentListPanelController.isOpen,
            theThemeStudioIsOpen: themeStudioController.isOpen,
            anAddThemeCardIsOpen: themeInstallConfirmation.isOpen,
            theRoomArtPanelTakesEscape: roomArtPreviewController.takesEscape,
            theRecapIsGatheringTheDiscs: videoRecapIsGatheringTheDiscs,
            theQuizSummaryIsShowing: videoQuizSummaryPanelController.isShowing,
            anInstantReplayIsOpen: instantReplay.isOpen,
            aPopOutIsReturningToSource: LiveSceneOverlay.shared.isReturningToSource,
            aVideoQuizQuestionIsOpen: videoQuizQuestionIsActive,
            sceneOnScreen: sceneOnScreen
        )
        switch escapeStep(for: escapeFacts) {
        case .leaveItToTheTextField, .leaveItToTheMenuPanel, .leaveItToTheSettingsDial, .nothing:
            return
        case .closeTheAgentList:
            agentListPanelController.closeWithGlide()
        case .closeTheThemeStudio:
            _ = themeStudioController.closeOnEscape()
        case .declineTheAddThemeCard:
            _ = themeInstallConfirmation.cancelOnEscape()
        case .closeTheRoomArtPanel:
            // Every close runs `stopTheRoomArtSpeech`, so the camera and the spoken line stop together.
            _ = roomArtPreviewController.closeOnEscape()
        case .stopTheRecapGather:
            cancelTheVideoRecapGather()
        case .closeTheQuizSummary:
            videoQuizSummaryPanelController.close(animated: true)
        case .endTheInstantReplay:
            // The camera and the cursor stop where they are.
            instantReplay.endIfOpen()
        case .hideThePopOutAtOnce:
            clearTheLiveSceneAndReleaseTheBuddy()
        case .skipTheQuizQuestion:
            skipTheVideoQuizQuestion()
        case .stopTheReply:
            stopTheReplyOnEscape()
        case .clearTheFinishedScene:
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            voiceState = .idle
            clearFinishedLiveScene()
            scheduleTransientHideIfNeeded()
        }
    }

    /// A pop-out or explored scene is on screen, touring or finished, with no quiz question waiting on it.
    private var liveSceneIsUpWithNoQuizQuestion: Bool {
        guard !videoQuizQuestionIsActive else { return false }
        switch liveScenePhase {
        case .allLabelsShowing, .touring(quizToAskAfterTour: nil):
            return true
        default:
            return false
        }
    }

    /// With no scene on screen, Escape skips the answer Clicky is thinking about or speaking,
    /// the same way a push-to-talk press does, without asking anything new.
    private func stopTheReplyOnEscape() {
        guard escapeHasAnAnswerToStop(
            voiceState: voiceState,
            speechIsPlaying: elevenLabsTTSClient.isPlaying,
            dictationIsInProgress: buddyDictationManager.isDictationInProgress,
            cursorIsPointingForTheAnswer: detectedElementScreenLocation != nil
        ) else { return }
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        clearDetectedElementLocation()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
        print("Escape: stopped the reply")
    }

    /// Shows the Card that sums up a quiz that just ended, out of the quiz video when its tab is in front.
    private func showTheVideoQuizSummary() {
        guard let lastQuiz = videoQuizSession.lastQuizVideoURLAndResults else { return }
        videoRecapWatcher.startWatching(forVideoURL: lastQuiz.videoURL)
        guard let recap = videoRecap(forVideoURL: lastQuiz.videoURL) else { return }
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let videoRect = videoQuizSession.quizVideoIsTheTabInFront()
            ? ChromeVideoTab.screenRectOfTheLargestVisibleMediaInFrontTab().map { appKitRect(of: $0, mainDisplayHeight: mainDisplayHeight) }
            : nil
        showTheVideoRecapCard(recap, moment: .quizEnded, videoURL: lastQuiz.videoURL, videoRect: videoRect)
    }

    /// What a video's recap holds: the last quiz Clicky ran on it, when it ran on this video, and its saved study guide.
    private func videoRecap(forVideoURL videoURL: String) -> VideoRecap? {
        let lastQuiz = videoQuizSession.lastQuizVideoURLAndResults
        let quizResults = lastQuiz.map { studyGuideVideoKey(forVideoURL: $0.videoURL) == studyGuideVideoKey(forVideoURL: videoURL) ? $0.results : [] } ?? []
        return VideoRecap(quizResults: quizResults, studyGuideRecord: savedStudyGuides.record(forVideoURL: videoURL))
    }

    /// The video in Chrome's front tab ended: the discs gather at the cursor, then the Card unfolds from it.
    private func showTheRecapAtTheEndOfTheVideo(_ recap: VideoRecap, videoURL: String) {
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let videoRect = ChromeVideoTab.screenRectOfTheLargestVisibleMediaInFrontTab().map { appKitRect(of: $0, mainDisplayHeight: mainDisplayHeight) }
        let cursorPoint = agentTokenServeStartPoint(mouseLocation: NSEvent.mouseLocation)
        videoRecapIsGatheringTheDiscs = true
        videoRecapGatherWasCancelled = false
        agentTokenDockController.gatherTheDiscs(at: cursorPoint) { [weak self] in
            guard let self else { return }
            self.videoRecapIsGatheringTheDiscs = false
            // A press, Escape, or a scene during the gather, or something that opened meanwhile, keeps the Card back.
            guard videoRecapCardMayShowAfterTheGather(gatherWasCancelled: self.videoRecapGatherWasCancelled, clickyIsBusy: self.clickyIsBusyForAVideoRecapCard) else {
                print("Video recap: the Card does not unfold, since the learner moved on during the gather")
                self.agentTokenDockController.sendTheDiscsBack(from: cursorPoint)
                return
            }
            self.showTheVideoRecapCard(recap, moment: .videoEnded, videoURL: videoURL, videoRect: videoRect, cursorPoint: cursorPoint)
            // A Card that could not show (no screen) would leave the discs hidden, so they go back.
            if !self.videoQuizSummaryPanelController.isShowing {
                self.agentTokenDockController.sendTheDiscsBack(from: cursorPoint)
            }
        }
    }

    /// A press, Escape, or a scene starting ends a recap's gather: the flights land at once, the discs show in their places at
    /// once with no flight back, and the Card stays away.
    private func cancelTheVideoRecapGather() {
        guard videoRecapIsGatheringTheDiscs else { return }
        videoRecapGatherWasCancelled = true
        agentTokenDockController.sendTheDiscsBackAtOnce()
    }

    private func showTheVideoRecapCard(_ recap: VideoRecap, moment: VideoRecapMoment, videoURL: String, videoRect: CGRect?, cursorPoint: CGPoint? = nil) {
        videoQuizSummaryPanelController.show(
            recap: recap,
            moment: moment,
            cursorPoint: cursorPoint,
            videoRect: videoRect,
            accentColor: themeSettings.shownTheme.cursorColor,
            goBackToTheMissedQuestion: { [weak self] missedQuestion in
                self?.goBackToTheMissedQuizQuestion(missedQuestion)
            },
            openTheStudyGuide: { [weak self] in
                self?.openTheStudyGuideFromTheRecap(forVideoURL: videoURL)
            }
        )
        // Only a Card that showed counts as seen, so a recap that was held back still shows at the next ending.
        if videoQuizSummaryPanelController.isShowing {
            videoRecapWatcher.recapWasShown(recap, forVideoURL: videoURL)
        }
    }

    /// The Card's Study guide button: the Card closes, and the guide opens the way "open my study guide" opens it, after
    /// Notion confirms the page is still there.
    private func openTheStudyGuideFromTheRecap(forVideoURL videoURL: String) {
        videoQuizSummaryPanelController.close(animated: true)
        Task {
            guard let studyGuideRecord = await self.savedStudyGuideStillInNotion(forVideoURL: videoURL, checkEvenIfCheckedBefore: true) else {
                VoiceToolCallChip.shared.show("That study guide was deleted in Notion", sender: .failure)
                return
            }
            guard self.openTheStudyGuidePage(at: studyGuideRecord.pageURL) else {
                VoiceToolCallChip.shared.show("Couldn't open the study guide", sender: .failure)
                return
            }
        }
    }

    /// Switches to the Chrome tab the guide opened in, or opens its page, which only an https page on Notion may be.
    private func openTheStudyGuidePage(at pageURL: URL) -> Bool {
        if let chromeTabID = notionPageChromeTabIDsByPageURL[pageURL], videoQuizSession.bringChromeTabForward(tabID: chromeTabID) {
            return true
        }
        // NSWorkspace opens any URL scheme, and a guide saved by an older build was never checked.
        return pageURLIsOnNotion(pageURL) && NSWorkspace.shared.open(pageURL)
    }

    /// Whether Clicky is doing something a recap Card would cover or talk over, which the watch waits out: listening, thinking,
    /// speaking, a quiz question or a running quiz, a scene, a Card already up, the Theme Studio card, the settings dial, the
    /// agent list, the room art panel, the "Add theme?" card, or an approval waiting for the learner.
    private var clickyIsBusyForAVideoRecapCard: Bool {
        let aSceneIsUp: Bool
        if case .idle = liveScenePhase { aSceneIsUp = false } else { aSceneIsUp = true }
        return VideoRecapBusyFacts(
            aSceneIsUp: aSceneIsUp,
            clickyIsNotIdle: voiceState != .idle,
            speechIsPlaying: elevenLabsTTSClient.isPlaying,
            aQuizQuestionIsOpen: videoQuizQuestionIsActive,
            aQuizIsRunning: videoQuizSession.isRunning,
            aCardIsShowing: videoQuizSummaryPanelController.isShowing,
            theThemeStudioIsOpen: themeStudioController.isOpen,
            theSettingsDialIsOpen: settingsDialController.isOpen,
            theAgentListIsOpen: agentListPanelController.isOpen,
            theMenuBarPanelIsOpen: menuPanelIsOpen(),
            theRoomArtPanelIsOpen: roomArtPreviewController.isOpen,
            anAddThemeCardIsOpen: themeInstallConfirmation.isOpen,
            anApprovalWaits: agentHarness.approvalDesk.oldestWaitingRequest != nil
        ).clickyIsBusy
    }

    /// A click on a question in the quiz summary: the video goes back there and its pop-out shows again, with every label
    /// named and the narration a requested pop-out has. Clearing it resumes the video.
    private func goBackToTheMissedQuizQuestion(_ missedQuestion: VideoQuizMissedQuestion) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        // A scene still building would replace the pop-out when it finishes, so it is cancelled as "stop the quiz" cancels one.
        if case .buildingScene = liveScenePhase {
            liveSceneRequestTask?.cancel()
            liveSceneRequestTask = nil
            liveSceneRequestGeneration += 1
            LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines)
            liveScenePhase = .idle
        }
        // The video is about to move back to the question, so a scene on screen goes without its "back to the video".
        clearFinishedLiveScene(resumesTheVideo: false)
        let framePopout: VideoFramePopout
        switch videoQuizSession.goBackToTheMissedQuestion(missedQuestion) {
        case .showsItsPopout(let popoutOfTheQuestion):
            framePopout = popoutOfTheQuestion
        case .playsFromBeforeIt:
            return
        case .couldNotGoBack:
            // A scene build this go-back cancelled, or a requested scene it cleared, still holds the video's pause, and nothing
            // else will resume it now. A scene or pop-out that started while the old one returned owns the pause instead.
            Task {
                await LiveSceneOverlay.shared.waitForReturnToFinish()
                guard aSceneThatEndedMayResumeItsVideo(liveScenePhase: self.liveScenePhase) else { return }
                self.videoQuizSession.resumeVideoAfterRequestedScene()
            }
            currentResponseTask = Task { await self.sayTheQuizQuestionCouldNotBeShownAgain() }
            return
        }
        guard let overlayScreen = overlayScreen(showing: framePopout.frameGrab),
              let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen, theme: themeSettings.shownTheme),
              LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: false, isFramePopout: true, overlayScreen: overlayScreen) else {
            // No pop-out opened, so nothing will clear it and resume the video the go-back paused.
            videoQuizSession.resumeVideoAfterRequestedScene()
            currentResponseTask = Task { await self.sayTheQuizQuestionCouldNotBeShownAgain() }
            return
        }
        liveScenePhase = .touring(quizToAskAfterTour: nil)
        liveScenePageOnScreen = .framePopout(framePopout)
        voiceState = .idle
        currentResponseTask = Task {
            await self.narrateTheFramePopout(framePopout, narrationTrigger: .afterTour)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    private func sayTheQuizQuestionCouldNotBeShownAgain() async {
        VoiceToolCallChip.shared.show("Couldn't go back to that question", sender: .failure)
        let lineToSpeak = SpokenSceneLine.quizQuestionCouldNotBeShownAgain
        await speakLiveSceneLine(lineToSpeak.text, isAFailure: lineToSpeak.isAFailure)
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func skipTheVideoQuizQuestion() {
        // An answered question is already closed, so a skip after the answer records nothing and rebuilds no guide.
        if videoQuizSession.recordTheOpenQuestionOutcome(.skipped) {
            refreshTheStudyGuideAfterAQuizOutcome(.skipped)
        }
        currentResponseTask?.cancel()
        liveSceneTourFinishedTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        videoQuizQuestionIsActive = false
        liveScenePhase = .idle
        clearTheLiveSceneAndReleaseTheBuddy()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
        print("Video quiz: skipped the question")
        Task {
            await LiveSceneOverlay.shared.waitForReturnToFinish()
            self.videoQuizSession.resumeVideoAfterQuestion()
        }
    }

    private func handleLiveSceneTourFinished() {
        guard case .touring(let quizToAskAfterTour) = liveScenePhase else { return }
        guard let quiz = quizToAskAfterTour else {
            liveScenePhase = .allLabelsShowing
            LiveSceneOverlay.shared.letLearnerDragTheModel()
            // The tour ends close on the answer part, which only a quiz needs, so frame the whole subject again.
            LiveSceneOverlay.shared.highlightPart(labelText: "")
            askTheSimulationQuestionAfterItsTour()
            return
        }
        liveSceneTourFinishedTask?.cancel()
        liveSceneTourFinishedTask = Task {
            await self.waitUntilTheVoiceAnswerIsQuiet()
            guard !Task.isCancelled else { return }
            guard case .touring = liveScenePhase else { return }
            liveScenePhase = .awaitingAnswer(quiz, wrongAnswerCount: 0)
            // Only after the phase changes, because a new question cancels this
            // task and .touring has no way to release the mouse.
            LiveSceneOverlay.shared.letLearnerDragTheModel()
            // The "?" label's place is read while the question starts playing, as a narration reads its part's.
            let settledLabelScreenPointsTask = Task {
                await LiveSceneOverlay.shared.partLabelScreenPointsOnceTheCameraSettles()
            }
            await self.speakLiveSceneLine(quiz.question, isAFailure: false)
            self.pointTheBuddyAtTheQuizQuestion(quiz, labelScreenPoints: await settledLabelScreenPointsTask.value)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    // MARK: - Voice Commands

    /// A follow-up command while a scene is on screen or a video plays in Chrome's front tab. A fast model picks tools the page
    /// and the app offer, the screen changes, and Clicky says the model's short confirmation after that.
    /// A request that needs a new scene or a screenshot answer hands off to respondToTranscript.
    /// `confirmedSpeculativeCommand` is the command this transcript's press started on its partial transcript, which the
    /// final transcript kept, so it runs from where the harness holds it instead of being sent again.
    private func startVoiceCommand(
        transcript: String,
        frontVideoState: JSONValue?,
        pageReadStartedAtRelease: Task<VoiceCommandPageRead, Never>? = nil,
        confirmedSpeculativeCommand: SpeculativeVoiceCommand? = nil,
        timing: VoiceCommandTimingRecorder
    ) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        voiceState = .processing
        currentResponseTask = Task {
            // The dictation session's own idle reaches voiceState after this call returns, so the state is set again
            // here, the way respondToTranscript's task does, or the thinking dots vanish for the whole router call.
            self.voiceState = .processing
            await self.runVoiceCommand(
                transcript: transcript,
                frontVideoState: frontVideoState,
                pageReadStartedAtRelease: pageReadStartedAtRelease,
                confirmedSpeculativeCommand: confirmedSpeculativeCommand,
                timing: timing
            )
        }
    }

    /// What a voice command sends to the model for this page read and the app's state now. The speculative start and the
    /// final transcript both build it here, so the final transcript can tell whether the command it would send is the one
    /// already sent.
    private func voiceCommandInputs(frontVideoState: JSONValue?, pageRead: VoiceCommandPageRead) -> VoiceCommandInputs {
        // A quiz answer or a scene still building reads no video, so there is no front video for a guide to belong to.
        let studyGuideExistsForTheFrontVideo = frontVideoState != nil && pageRead.studyGuideExistsForTheFrontVideo
        let appToolContext = appVoiceToolContext(
            pageState: pageRead.pageState,
            frontVideoState: frontVideoState,
            studyGuideExistsForTheFrontVideo: studyGuideExistsForTheFrontVideo
        )
        return VoiceCommandInputs(
            tools: voiceToolsOfferedToTheModel(pageTools: pageRead.pageTools, appTools: AppVoiceTool.available(in: appToolContext), skills: TaskAgentSkillCatalog.currentSkills()),
            pageState: pageRead.pageState,
            frontVideoState: frontVideoState,
            // The harness names the waiting request's kind of action itself, so this scene state has no approvalWaiting.
            harnessSceneState: voiceCommandSceneState(pageState: pageRead.pageState, frontVideoState: frontVideoState),
            // A "yes" or "no" answers the request the card showed when the learner pressed push-to-talk, never one that came
            // on screen while they spoke or while the model ran, such as after the shown one's task ended.
            approvalWhenTheCommandStarted: approvalAtThePressStillWaiting
        )
    }

    /// Sends a voice command to the brain in the harness. A command started on the partial transcript waits there, before its
    /// first call, for `confirmVoiceCommand`.
    private func startTheHarnessVoiceCommand(transcript: String, inputs: VoiceCommandInputs, waitsForTheFinalTranscript: Bool) throws -> StartedHarnessVoiceCommand {
        let commandID = UUID()
        let standardInputWriter = agentHarness.standardInputWriter
        let commandLines = HarnessVoiceCommandLines(taskID: commandID) { harnessCommand in
            standardInputWriter.write(harnessCommand)
        }
        let commandEvents = try agentHarness.startVoiceCommand(
            taskID: commandID,
            transcript: transcript,
            sceneState: inputs.harnessSceneState,
            tools: inputs.tools,
            approvalAtPress: inputs.approvalWhenTheCommandStarted,
            waitsForTheFinalTranscript: waitsForTheFinalTranscript
        )
        #if DEBUG
        harnessVoiceCommandsSent += 1
        #endif
        return StartedHarnessVoiceCommand(commandID: commandID, lines: commandLines, events: commandEvents, sentAt: Date())
    }

    /// What decides which app tools the model is offered. The router and the Debug tool server both read it here, so the
    /// server can never list different tools than the router.
    private func appVoiceToolContext(
        pageState: JSONValue?,
        frontVideoState: JSONValue?,
        studyGuideExistsForTheFrontVideo: Bool
    ) -> AppVoiceTool.Context {
        AppVoiceTool.Context(
            sceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            sceneHasLabels: !(pageState?["labels"]?.arrayValue ?? []).isEmpty,
            videoIsInFront: frontVideoState != nil,
            videoIsOnYouTube: frontVideoState?["onYouTube"]?.boolValue == true,
            videoQuizIsRunning: videoQuizSession.isRunning,
            quizQuestionIsOpen: liveScenePhaseIsWaitingForAQuizAnswer,
            studyGuideExistsForTheFrontVideo: studyGuideExistsForTheFrontVideo,
            backgroundSceneIsReady: readyBackgroundScene != nil,
            taskAnswerIsReady: readyTaskAnswer != nil,
            simulationIsWaitingForAGuess: pageState?["lessonStage"]?.stringValue == "guess",
            simulationIsOnScreen: simulationIsOnScreen(pageOnScreen: liveScenePageOnScreen, overlayIsShowingAScene: LiveSceneOverlay.shared.isShowingAScene),
            approvalIsWaiting: approvalAtThePressStillWaiting != nil,
            themeStudioIsOpen: themeStudioController.isOpen,
            themeStudioShowsIdeas: themeStudioController.state.isShowingIdeas,
            backgroundAgentIsRunning: backgroundAgentStore.anAgentIsRunning,
            backgroundAgentsArePaused: backgroundAgentStore.agentsArePaused,
            replayStopsAreRecorded: replayStopsAreRecordedForTheSceneOnScreen,
            replayIsOpen: replayStopsAreRecordedForTheSceneOnScreen && instantReplay.isOpen,
            furnitureGhostShows: roomArtPreviewController.phase.furnitureGhostShows
        )
    }

    private func runVoiceCommand(
        transcript: String,
        frontVideoState: JSONValue?,
        pageReadStartedAtRelease: Task<VoiceCommandPageRead, Never>?,
        confirmedSpeculativeCommand: SpeculativeVoiceCommand?,
        timing: VoiceCommandTimingRecorder
    ) async {
        // Every exit logs the line once: a finished, cancelled, failed, or handed-off command.
        defer { timing.logTheLineOnce() }
        let commandStartedAt = Date()
        let pageRead: VoiceCommandPageRead
        if let confirmedSpeculativeCommand {
            pageRead = confirmedSpeculativeCommand.screenRead.pageRead
        } else {
            // The read started at the press's release is awaited when it has not finished, and a command with no read of
            // its own (a quiz scene command, or a transcript whose read was dropped) reads the page now.
            // A press during the read cancels this command, so it must not send anything to the harness.
            guard let pageReadForThisCommand = await pageReadForTheVoiceCommand(
                startedAtRelease: pageReadStartedAtRelease,
                readNow: { await readThePageForTheVoiceCommand(frontVideoState: frontVideoState) }
            ) else { return }
            pageRead = pageReadForThisCommand
        }
        timing.mark(\.screenStateReadyAt, at: pageRead.finishedAt)
        // A kept command was built from these same inputs at its start, which the final transcript checked again.
        let inputs = confirmedSpeculativeCommand?.inputs ?? voiceCommandInputs(frontVideoState: frontVideoState, pageRead: pageRead)
        let tools = inputs.tools
        print("Voice command: offering \(tools.count) tools, \(frontVideoState == nil ? "no video" : "a video") in front")
        let startedCommand: StartedHarnessVoiceCommand
        if let confirmedSpeculativeCommand {
            startedCommand = confirmedSpeculativeCommand.command
        } else {
            do {
                startedCommand = try startTheHarnessVoiceCommand(transcript: transcript, inputs: inputs, waitsForTheFinalTranscript: false)
            } catch {
                await runTheRouterFailureFallback(transcript: transcript, failureDescription: "the agent harness could not start: \(error)")
                return
            }
        }
        timing.mark(\.commandSentAt, at: startedCommand.sentAt)
        await runVoiceCommandInTheHarness(
            startedCommand,
            transcript: transcript,
            offeredToolNames: inputs.offeredToolNames,
            lookupToolNames: inputs.lookupToolNames,
            commandStartedAt: commandStartedAt,
            timing: timing
        )
    }

    /// The voice command: the brain in the harness runs the model's turns, and each tool call it sends runs here through
    /// `runOneVoiceToolCall`. A failed command, including one the Worker refused the app secret for, takes the router
    /// failure fallback.
    /// A command kept from the partial transcript arrives here once the harness was told to go on, so its events, which
    /// waited in the stream, run here like any other command's, and its event deadline starts only now.
    private func runVoiceCommandInTheHarness(
        _ startedCommand: StartedHarnessVoiceCommand,
        transcript: String,
        offeredToolNames: Set<String>,
        lookupToolNames: Set<String>,
        commandStartedAt: Date,
        timing: VoiceCommandTimingRecorder
    ) async {
        let commandID = startedCommand.commandID
        let commandLines = startedCommand.lines
        let commandEvents = startedCommand.events
        // The audio of the line the current turn speaks if every call changes the screen, fetched while the calls run.
        // Every exit that does not play it cancels it: a cancel, a hand-off, a failure, a gave-up line, or other words.
        var earlyLineFetch: SpokenLineFetch?
        defer { earlyLineFetch?.cancel() }
        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: commandLines,
            whenNoEventArrivesInTime: { [weak self] in
                commandLines.commandWasCancelled()
                self?.agentHarness.endVoiceCommand(
                    taskID: commandID,
                    lastEvent: .failed(reason: "the agent harness sent nothing in time")
                )
            },
            whenTheLineIfEveryCallChangesArrives: { spokenLine, turnToolNames in
                // A later turn's line replaces an earlier one, which a lookup or a failure made wrong.
                earlyLineFetch?.cancel()
                earlyLineFetch = nil
                let lineToSpeak = voiceCommandLineToSpeak(spokenLine)
                guard !lineToSpeak.isEmpty, earlyLineIsWorthFetching(turnToolNames: turnToolNames, lookupToolNames: lookupToolNames) else { return }
                earlyLineFetch = self.elevenLabsTTSClient.startFetching(lineToSpeak)
            },
            runTool: { toolCall in
                timing.mark(\.firstToolCallReceivedAt)
                // The harness holds the model's reply, so the call it sends is what the debug switch can show.
                self.logVoiceCommandJSONIfEnabled("tool call from the harness", [.object([
                    "id": .string(toolCall.id),
                    "name": .string(toolCall.name),
                    "input": .object(toolCall.input),
                ])])
                // A command the harness ended, or the press cancelled, leaves its outcome unshown and unrecorded.
                return await self.runOneVoiceToolCall(
                    toolCall,
                    offeredToolNames: offeredToolNames,
                    transcript: transcript,
                    commandStartedAt: commandStartedAt,
                    handOffMark: commandLines
                ) ?? .failed(error: "The command was cancelled", state: nil)
            }
        )
        // A cancelled command's stream may still be routed, and a late tool call for it must find nothing.
        agentHarness.endVoiceCommand(taskID: commandID)

        switch commandEnding {
        case .cancelled:
            return
        case .failed(let reason):
            guard !Task.isCancelled else { return }
            await runTheRouterFailureFallback(transcript: transcript, failureDescription: reason)
        case .finished(let spokenLine, let gaveUp):
            guard !Task.isCancelled else { return }
            let lineToSpeak = voiceCommandLineToSpeak(spokenLine)
            if !lineToSpeak.isEmpty {
                // An agent the command started serves its token from the cursor first, and the line plays after it lands.
                await agentTokenDockController.waitForTheServeToLand()
                guard !Task.isCancelled else { return }
                let lineAudio = voiceCommandLineAudio(lineToSpeak: lineToSpeak, earlyLineFetched: earlyLineFetch?.text)
                timing.lineAudio = lineAudio
                let lineFetch: SpokenLineFetch
                if lineAudio == .theAudioFetchedEarly, let earlyLineFetch {
                    lineFetch = earlyLineFetch
                } else {
                    // The early audio has other words, so it stops downloading before the finished line's fetch starts.
                    earlyLineFetch?.cancel()
                    earlyLineFetch = nil
                    lineFetch = elevenLabsTTSClient.startFetching(lineToSpeak)
                }
                // The player owns the fetch from here, so the cancel on the way out must not cut the line off.
                if lineFetch === earlyLineFetch { earlyLineFetch = nil }
                if await speakLiveSceneLine(lineFetch) { timing.mark(\.firstLineAudioStartedAt) }
            }
            guard !Task.isCancelled else { return }
            if gaveUp {
                if await speakTheGaveUpLine() { timing.mark(\.firstLineAudioStartedAt) }
            }
            guard !Task.isCancelled else { return }
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    /// Runs one of the model's tool calls with its chips and its log line. Nil when a push-to-talk press cancelled the
    /// command during the call, since its outcome is then never shown. A hand-off cancels this task itself when it starts
    /// the new path, and runs with no await, so it goes on to show its chip. `handOffMark` is the harness command's, which
    /// each hand-off sets and which hears when a call finished.
    private func runOneVoiceToolCall(
        _ toolCall: VoiceToolCall,
        offeredToolNames: Set<String>,
        transcript: String,
        commandStartedAt: Date,
        handOffMark: HarnessVoiceCommandLines
    ) async -> VoiceToolOutcome? {
        showTheVoiceToolCallChip(for: toolCall, at: .beforeTheCall, offeredToolNames: offeredToolNames)
        let toolStartedAt = Date()
        let outcome = await runVoiceTool(
            toolCall,
            offeredToolNames: offeredToolNames,
            transcript: transcript,
            handOffMark: handOffMark
        )
        // A push-to-talk press during a slow call, like play_video's check, ends the command here.
        if Task.isCancelled && outcome != .handedOff { return nil }
        // The call finished, so a press from here on still lets the harness hear its result before the cancel.
        handOffMark.callFinished(with: outcome)
        showTheVoiceToolCallChip(for: toolCall, at: .afterTheCall(outcome), offeredToolNames: offeredToolNames)
        print("Voice command: \(toolCall.chipText) ran in \(Int(Date().timeIntervalSince(toolStartedAt) * 1000)) ms, \(Int(Date().timeIntervalSince(commandStartedAt) * 1000)) ms after the command, \(outcome.isFailure ? "failed" : "ok")")
        logVoiceCommandJSONIfEnabled("result of \(toolCall.name)", [.string(outcome.toolResultText)])
        return outcome
    }

    /// What a failed voice command does: the keyword path, the experiment for "let me try it" with no scene,
    /// or a short line during a quiz question.
    private func runTheRouterFailureFallback(transcript: String, failureDescription: String) async {
        // During a quiz question the keyword path is the judge, which sent this command here,
        // so handing it back would loop between the two on every failure.
        if liveScenePhaseIsWaitingForAQuizAnswer {
            print("Voice command: the router failed during a quiz question: \(failureDescription)")
            await speakTheGaveUpLine()
            guard !Task.isCancelled else { return }
            voiceState = .idle
            scheduleTransientHideIfNeeded()
            return
        }
        print("Voice command: the router failed, so its fallback takes it: \(failureDescription)")
        switch routerFailureFallback(
            for: transcript,
            sceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            themeStudioIsOpen: themeStudioController.isOpen,
            furnitureGhostShows: roomArtPreviewController.phase.furnitureGhostShows,
            aRoomArtItemKeepsTheRoom: roomArtPreviewController.phase.keepsTheRoomForANewItem
        ) {
        case .giveUp:
            await speakTheGaveUpLine()
            guard !Task.isCancelled else { return }
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        case .startExperiment:
            startTheExperimentInTheBackground(transcript: transcript)
        case .designATheme(let themeStudioRequest):
            startDesigningATheme(request: transcript, basedOnIdea: nil, pictureChoice: themeStudioRequest == .fromThePicture ? .captureAgain : .none)
        case .showArtInMyRoom:
            theRequestBecameALookAtTheMedia()
            startShowingTheArtInMyRoom(learnerRequest: transcript)
        case .keywordPath:
            respondByTheKeywordPath(transcript: transcript)
        }
    }

    /// Runs only a tool this turn offered, so a model, a page, or a debug caller cannot reach one the
    /// current state left out, such as a hand-off during a quiz question.
    private func runVoiceTool(
        _ toolCall: VoiceToolCall,
        offeredToolNames: Set<String>,
        transcript: String,
        handOffMark: HarnessVoiceCommandLines? = nil
    ) async -> VoiceToolOutcome {
        guard offeredToolNames.contains(toolCall.name) else {
            return .failed(error: "\(toolCall.name) is not available right now", state: nil)
        }
        guard let appVoiceTool = AppVoiceTool(rawValue: toolCall.name) else {
            return await LiveSceneOverlay.shared.callPageVoiceTool(named: toolCall.name, input: toolCall.inputWithoutConfirmation)
        }
        return await runAppVoiceTool(
            appVoiceTool,
            input: toolCall.inputWithoutConfirmation,
            transcript: transcript,
            handOffMark: handOffMark
        )
    }

    /// Runs one app tool. Every hand-off goes through `voiceToolOutcome(of:handOffMark:)`, which sets the harness
    /// command's mark before the new path starts (see `HarnessVoiceCommandLines`). The debug server passes no mark.
    private func runAppVoiceTool(
        _ appVoiceTool: AppVoiceTool,
        input: [String: JSONValue],
        transcript: String,
        handOffMark: HarnessVoiceCommandLines? = nil
    ) async -> VoiceToolOutcome {
        if appVoiceTool.handsOffToALookAtTheMedia {
            theRequestBecameALookAtTheMedia()
        }
        let toolStep = await appVoiceToolStep(
            appVoiceTool,
            input: input,
            transcript: transcript
        )
        return voiceToolOutcome(of: toolStep, handOffMark: handOffMark)
    }

    /// What one app tool does. A hand-off returns its new path as `.handOff` and never starts it here, and every other
    /// branch returns its outcome.
    private func appVoiceToolStep(
        _ appVoiceTool: AppVoiceTool,
        input: [String: JSONValue],
        transcript: String
    ) async -> AppVoiceToolStep {
        switch appVoiceTool {
        case .answerWithScreen:
            return .handOff { self.respondToTranscript(transcript: transcript, requestedSceneKind: nil) }
        case .buildNewScene:
            let requestedSceneKind: LiveSceneKind = input["asQuiz"]?.boolValue == true ? .quiz : .explore
            return .handOff { self.respondToTranscript(transcript: transcript, requestedSceneKind: requestedSceneKind) }
        case .buildSimulation:
            switch currentExperimentRequestStep {
            case .showTheReadyExperiment:
                return .handOff { self.startShowingTheReadyBackgroundScene() }
            case .sayItIsStillBuilding:
                return .outcome(.failed(error: "The experiment is still building, so wait for it", state: nil))
            case .startBuilding:
                return .outcome(startBuildingASceneInTheBackground(whatToBuild: transcript, agentKind: .experiment))
            }
        case .popOut:
            return .handOff { self.respondToTranscript(transcript: transcript, requestedSceneKind: .framePopout) }
        case .animatePicture:
            theRequestBecameALookAtTheMedia()
            return .handOff { self.respondToTranscript(transcript: transcript, requestedSceneKind: .animatedFramePopout) }
        case .showArtInMyRoom:
            theRequestBecameALookAtTheMedia()
            return .handOff { self.startShowingTheArtInMyRoom(learnerRequest: transcript) }
        case .closeScene:
            return .handOff { self.closeTheSceneByVoice() }
        case .explainPart:
            let requestedLabel = input["label"]?.stringValue ?? ""
            return .handOff {
                if partLabelToExplain(untrustedTappedLabel: requestedLabel, pageOnScreen: self.liveScenePageOnScreen, liveScenePhase: self.liveScenePhase) != nil {
                    self.explainTheTappedPart(untrustedTappedLabel: requestedLabel)
                } else {
                    self.respondToTranscript(transcript: "what does the \(requestedLabel) do?", requestedSceneKind: nil)
                }
            }
        case .placeFurniture:
            guard roomArtPreviewController.placeTheFurnitureWhereItsGhostStands() else {
                return .outcome(.failed(error: "No furniture is being placed", state: nil))
            }
            return .outcome(.changed(state: nil))
        case .moveFurniture:
            let directionWord = input["direction"]?.stringValue
            let direction = directionWord.flatMap(RoomFurnitureNudgeDirection.init(rawValue:))
            guard directionWord == nil || direction != nil else {
                return .outcome(.failed(error: "direction must be left, right, closer, or farther", state: nil))
            }
            let turnDegrees = input["turnDegrees"]?.numberValue
            guard direction != nil || (turnDegrees ?? 0) != 0 else {
                return .outcome(.failed(error: "Give a direction, a turn, or both", state: nil))
            }
            if let refusal = roomArtPreviewController.nudgeTheFurniture(direction, distanceCentimeters: input["distanceCentimeters"]?.numberValue, turnDegrees: turnDegrees) {
                return .outcome(.failed(error: refusal.toolError, state: nil))
            }
            return .outcome(.changed(state: nil))
        case .replayExplanation:
            return .handOff { self.instantReplay.playFromTheStart() }
        case .replayStep:
            guard let replayStep = input["step"]?.stringValue.flatMap(InstantReplayStep.init(rawValue:)) else {
                return .outcome(.failed(error: "step must be next, back, or end", state: nil))
            }
            return .handOff { self.instantReplay.step(replayStep) }
        case .pauseVideo:
            return .outcome(runLearnerVideoCommand(.pause))
        case .playVideo:
            let playOutcome = runLearnerVideoCommand(.play)
            guard case .changed = playOutcome else { return .outcome(playOutcome) }
            // play() only asks. Chrome may refuse it, and a video that loads its data only now needs a moment,
            // so the state is read a few times over about 1.6 seconds before a play counts as failed.
            var videoStateAfterPlay: JSONValue?
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(400))
                videoStateAfterPlay = videoQuizSession.frontVideoStateForVoiceCommands()
                if videoStateAfterPlay?["playing"]?.boolValue == true { break }
            }
            return .outcome(learnerVideoPlayOutcome(videoStateAfterPlay: videoStateAfterPlay))
        case .seekRelative:
            guard let seconds = input["seconds"]?.numberValue else { return .outcome(.failed(error: "seconds must be a number", state: nil)) }
            return .outcome(runLearnerVideoCommand(.seekBy(seconds: seconds)))
        case .seekToTime:
            guard let seconds = input["seconds"]?.numberValue else { return .outcome(.failed(error: "seconds must be a number", state: nil)) }
            do {
                let videoState = try await videoQuizSession.seekTheFrontVideo(toSeconds: seconds) { videoTab, targetSeconds in
                    await self.scrubTheCursorAlongTheProgressBar(of: videoTab, toSeconds: targetSeconds)
                }
                return .outcome(.changed(state: .object(["video": videoState])))
            } catch {
                return .outcome(.failed(error: (error as? LocalizedError)?.errorDescription ?? "No video is in Chrome's front tab", state: nil))
            }
        case .setSpeed:
            guard let playbackRate = input["rate"]?.numberValue else { return .outcome(.failed(error: "rate must be a number", state: nil)) }
            return .outcome(runLearnerVideoCommand(.setPlaybackRate(playbackRate)))
        case .findMoment:
            do {
                let captionMoments = try await videoQuizSession.captionMomentsInTheFrontVideo(matching: input["query"]?.stringValue ?? "")
                return .outcome(.lookedUp(result: .array(captionMoments.map { captionMoment in
                    .object(["seconds": .number(captionMoment.seconds), "captions": .string(captionMoment.text)])
                })))
            } catch {
                return .outcome(.failed(error: (error as? LocalizedError)?.errorDescription ?? "Could not read this video's captions", state: nil))
            }
        case .seekToMoment:
            // One call finds the best caption line and seeks there, so the model can follow it with pop_out in the same reply.
            do {
                guard let seek = try await videoQuizSession.seekToTheCaptionMoment(matching: input["query"]?.stringValue ?? "", scrubTheCursorFirst: { videoTab, targetSeconds in
                    await self.scrubTheCursorAlongTheProgressBar(of: videoTab, toSeconds: targetSeconds)
                }) else {
                    return .outcome(.failed(error: "No caption line says that. Try other words, or use find_moment.", state: nil))
                }
                return .outcome(.changed(state: .object([
                    "video": seek.videoState,
                    "movedTo": .object(["seconds": .number(seek.captionMoment.seconds), "captions": .string(seek.captionMoment.text)]),
                ])))
            } catch {
                return .outcome(.failed(error: (error as? LocalizedError)?.errorDescription ?? "Could not read this video's captions", state: nil))
            }
        case .endQuiz:
            return .handOff { self.handleVideoQuizVoiceCommand(.stop) }
        case .makeStudyGuide:
            return .outcome(startWritingTheStudyGuide(.write(focus: studyGuideWish(fromModelText: input["focus"]?.stringValue))))
        case .reviseStudyGuide:
            guard let instruction = studyGuideWish(fromModelText: input["instruction"]?.stringValue) else {
                return .outcome(.failed(error: "instruction must say what to change", state: nil))
            }
            return .outcome(startWritingTheStudyGuide(.revise(instruction: instruction)))
        case .openStudyGuide:
            guard let frontVideoURL = videoQuizSession.frontTabURLOfTheFrontWindow() else {
                return .outcome(.failed(error: "No study guide has been written for this video yet", state: nil))
            }
            // Checked again here, since the learner may have trashed the page since the tools were offered.
            guard let studyGuideRecord = await savedStudyGuideStillInNotion(forVideoURL: frontVideoURL, checkEvenIfCheckedBefore: true) else {
                return .outcome(.failed(error: "This video's study guide was deleted in Notion, so there is nothing to open. Tell the learner, and that asking for a study guide again will write a new one.", state: nil))
            }
            guard openTheStudyGuidePage(at: studyGuideRecord.pageURL) else {
                return .outcome(.failed(error: "The study guide page would not open", state: nil))
            }
            return .outcome(.changed(state: nil))
        case .buildModelInTheBackground:
            guard let whatToBuild = input["whatToBuild"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !whatToBuild.isEmpty else {
                return .outcome(.failed(error: "whatToBuild must say what to build", state: nil))
            }
            return .outcome(startBuildingASceneInTheBackground(whatToBuild: whatToBuild, agentKind: .threeDModel))
        case .showReadyModel:
            return .handOff { self.startShowingTheReadyBackgroundScene() }
        case .startBackgroundTask:
            guard let goal = input["goal"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
                return .outcome(.failed(error: "goal must say what the task is", state: nil))
            }
            // The catalog is read again, so a skill file removed since the router built its tools is dropped here.
            let skillChoice = TaskAgentSkillCatalog.skillNameToRun(requestedName: input["skill"]?.stringValue, catalog: TaskAgentSkillCatalog.currentSkills())
            if skillChoice.skillWasDropped {
                print("Task agent: the skill \(input["skill"]?.stringValue ?? "") is not in the catalog, so the task runs with no skill")
            }
            return .outcome(startTheTaskAgent(goal: String(goal.prefix(longestTaskAgentGoal)), skillName: skillChoice.name, learnerWords: transcript))
        case .hearTaskAnswer:
            return .handOff { self.startSpeakingTheTaskAnswer() }
        case .pauseAgents:
            return .outcome(setEveryAgentIsPaused(true))
        case .resumeAgents:
            return .outcome(setEveryAgentIsPaused(false))
        case .recordGuess:
            return .outcome(await recordTheSimulationGuess(input["guess"]?.stringValue ?? ""))
        case .answerApproval:
            // The harness settles answer_approval against its own approval gate and never sends it here, so a call that
            // reaches the app, such as one from the Debug tool server, answers nothing.
            return .outcome(.failed(error: "The agent harness answers approvals, so the app has nothing to answer", state: nil))
        case .designTheme:
            let themeRequest = (input["request"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !themeRequest.isEmpty else { return .outcome(.failed(error: "request must say what the learner wants", state: nil)) }
            let basedOnIdea = input["basedOnIdea"]?.numberValue.flatMap { Int(exactly: $0) }
            let pictureChoice = ThemeStudioPictureChoice(fromPictureInput: input["fromPicture"]?.boolValue)
            return .handOff {
                self.startDesigningATheme(request: themeRequest, basedOnIdea: basedOnIdea, pictureChoice: pictureChoice)
            }
        case .pickThemeIdea:
            guard let ideaNumber = input["number"]?.numberValue.flatMap({ Int(exactly: $0) }), themeStudioController.pickIdea(number: ideaNumber) else {
                return .outcome(.failed(error: "number must be the number of an idea on the card, from 1 to 3", state: nil))
            }
            return .outcome(.changed(state: .object(["themeStudio": voiceCommandThemeStudioState(themeStudioController.state) ?? .null])))
        case .saveTheme:
            switch themeStudioController.saveTheHighlightedIdea() {
            case .saved(let themeName):
                return .outcome(.changed(state: .object(["themeSaved": .string(themeName)])))
            case .nothingToSave:
                return .outcome(.failed(error: "no idea is on the card to save", state: nil))
            case .failed:
                return .outcome(.failed(error: "the theme could not be saved", state: nil))
            }
        case .closeThemeStudio:
            themeStudioController.close()
            return .outcome(.changed(state: nil))
        }
    }

    // MARK: - Theme Studio

    /// Whether the theme design starting now reads the picture in Chrome's front tab, which the studio card opens on and
    /// rises above the cursor overlay for while it designs.
    private var themeDesignReadsAPicture = false
    /// The region the learner circled for the theme design starting now, which its picture is captured from, or nil.
    private var themeDesignCircledRegion: CircledRegion?

    /// Opens the studio or asks for new ideas, and returns at once, so the card and its spoken line say the result. The
    /// thinking state stays up while a picture is captured and designed from, so the loop around the picture shows what
    /// Clicky is looking at. Like any hand-off, it takes over the reply, so a router turn that called it ends here.
    private func startDesigningATheme(request: String, basedOnIdea: Int?, pictureChoice requestedPictureChoice: ThemeStudioPictureChoice) {
        let circledRegion = circledRegionOfTheCurrentPress
        // One press's loop names the picture of one design, so a later design, such as a Debug tool call, never reads it again.
        circledRegionOfThePress = nil
        let pictureChoice = themePictureChoice(
            requested: requestedPictureChoice,
            aRegionWasCircled: circledRegion != nil,
            changesAnIdeaOnACardWithAPicture: changesAnIdeaOnACardWithAPicture(basedOnIdea: basedOnIdea, state: themeStudioController.state)
        )
        // The request that started this design already pressed push-to-talk, so only a later press is the learner's next request.
        pushToTalkPressCountWhenTheThemeDesignStarted = pushToTalkPressCount
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        // The panel's Design one card starts a design with no press, so a replay still playing ends here, before the card opens.
        instantReplay.endForAnotherAnswer()
        cancelTheSceneStillBuilding()
        themeDesignCircledRegion = circledRegion
        if pictureChoice == .captureAgain {
            if let themeDesignCircledRegion {
                theRequestBecameALookAtTheCircledRegion(themeDesignCircledRegion)
            } else {
                theRequestBecameALookAtTheMedia()
            }
        }
        // The card opens inside `design` when the studio was closed, and reads this to know whether to open on the picture,
        // and its level reads it on every design, so a refine that keeps the card's picture does not raise it.
        themeDesignReadsAPicture = pictureChoice == .captureAgain
        themeStudioController.design(request: request, basedOnIdea: basedOnIdea, pictureChoice: pictureChoice)
        voiceState = pictureChoice == .captureAgain ? .processing : .idle
        currentResponseTask = Task {
            await self.themeStudioController.waitForTheDesign()
            guard !Task.isCancelled else { return }
            if self.voiceState == .processing {
                self.voiceState = .idle
            }
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Says a studio line once nothing else is happening: no audio playing, so a "no picture" line is not cut off by the
    /// ideas' own line, no push-to-talk held, and no request of the learner's being worked on, so it never plays over their
    /// voice or over the request that followed it. The three are checked together in one loop, since each can start while
    /// the line waits for another. The press counts tell the studio's own design apart from a request the learner made
    /// after it started, since both hold the thinking state.
    /// It has its own task, since a push-to-talk press cancels the reply task and must not drop a line the card is waiting on.
    private func speakAThemeStudioLine(_ line: String, isAFailure: Bool) {
        themeStudioSpeechTask?.cancel()
        themeStudioSpeechTask = Task {
            while !Task.isCancelled && !themeStudioLineMayStart(
                dictationIsInProgress: self.buddyDictationManager.isDictationInProgress,
                clickyIsThinking: self.voiceState == .processing,
                audioIsPlaying: self.elevenLabsTTSClient.isPlaying,
                themeStudioIsDesigning: self.themeStudioController.state.isDesigning,
                pushToTalkPressCount: self.pushToTalkPressCount,
                pushToTalkPressCountWhenTheDesignStarted: self.pushToTalkPressCountWhenTheThemeDesignStarted
            ) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            guard !Task.isCancelled else { return }
            // A line that did not start keeps the previous token, which matches nothing once that line has ended.
            if let lineToken = await self.speakLiveSceneLineAndReturnItsToken(line, isAFailure: isAFailure) {
                self.themeStudioLineToken = lineToken
            }
            await self.waitForClickyToFinishSpeaking()
            guard !Task.isCancelled else { return }
            if self.voiceState == .responding {
                self.voiceState = .idle
            }
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Ends the studio's spoken line when the card closes or saves.
    private func stopTheThemeStudioSpeech() {
        endAPanelsSpokenLine(speechTask: &themeStudioSpeechTask, lineToken: &themeStudioLineToken)
    }

    /// Ends the room art's spoken line on every close of the panel: Escape, the Close button, and a new request.
    private func stopTheRoomArtSpeech() {
        endAPanelsSpokenLine(speechTask: &roomArtSpeechTask, lineToken: &roomArtLineToken)
    }

    /// Ends a panel's spoken line when the panel closes. Cancelling the speech task also drops a line still waiting for its
    /// turn, which a bare `stopPlayback` would let start after the panel is gone. A line still loading never started
    /// playing, so cancelling the task is what ends it, and the token ends a line that is already playing. The task's own
    /// reset to idle never runs once it is cancelled, so this does it (`voiceStateAfterAPanelStoppedItsLine`).
    private func endAPanelsSpokenLine(speechTask: inout Task<Void, Never>?, lineToken: inout SpokenLineToken?) {
        speechTask?.cancel()
        speechTask = nil
        let panelLineToken = lineToken
        lineToken = nil
        let theStopReachedThePanelsLine = panelLineToken.map { elevenLabsTTSClient.stopPlayback(ifTheCurrentLineIs: $0) } ?? false
        let voiceStateAfterTheStop = voiceStateAfterAPanelStoppedItsLine(voiceState, theStopReachedThePanelsLine: theStopReachedThePanelsLine)
        guard voiceStateAfterTheStop != voiceState else { return }
        voiceState = voiceStateAfterTheStop
        scheduleTransientHideIfNeeded()
    }

    /// Cancels a scene still building, the way "let me try it" cancels it, for a request that takes over the screen
    /// instead: an experiment, the Theme Studio, or the room art panel. Left in the building phase, the router would stay
    /// off for the next command, the finished scene would play over what replaced it, and a video Clicky paused for the
    /// scene would stay paused.
    private func cancelTheSceneStillBuilding() {
        liveSceneRequestTask?.cancel()
        guard case .buildingScene = liveScenePhase else { return }
        liveSceneRequestGeneration += 1
        let cancelledBuildGeneration = liveSceneRequestGeneration
        liveScenePhase = .idle
        Task {
            await LiveSceneOverlay.shared.waitForReturnToFinish()
            // A newer scene request, or a ready experiment rising now, holds the pause for its own scene, so only the
            // latest cancel resumes the video.
            guard cancelledBuildGeneration == self.liveSceneRequestGeneration else { return }
            self.videoQuizSession.resumeVideoAfterRequestedScene()
        }
    }

    /// Reads the picture and the page and opens the room art panel. The thinking state shows while the page is read, and
    /// the panel and its spoken line say the rest. Like any hand-off, it takes over the reply. `learnerRequest` is the
    /// learner's words, which tell the page reader which item they mean.
    private func startShowingTheArtInMyRoom(learnerRequest: String) {
        roomArtRequest.start(atPushToTalkPressCount: pushToTalkPressCount)
        roomArtSpeechTask?.cancel()
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        // A scene that finished building would play over the panel, so it is cancelled first.
        cancelTheSceneStillBuilding()
        voiceState = .processing
        currentResponseTask = Task {
            await self.roomArtPreviewController.showTheArtInTheRoom(learnerRequest: learnerRequest)
            guard self.roomArtRequest.openingReturned(requestWasCancelled: Task.isCancelled) else { return }
            if self.voiceState == .processing { self.voiceState = .idle }
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Says a room art line once nothing else is happening (`roomArtLineStep`). "Here it is" lands about 14 seconds after
    /// the request, so it waits for a newer answer to finish instead of cutting it off, and it is dropped when the learner
    /// pressed push-to-talk since asking. It has its own task, since a press cancels the reply task. `isAFailure` says the
    /// line reports something that went wrong, so the cursor shakes as Clicky says it.
    private func speakARoomArtLine(_ line: String, isAFailure: Bool) {
        roomArtSpeechTask?.cancel()
        roomArtSpeechTask = Task {
            while !Task.isCancelled {
                let lineStep = self.roomArtRequest.lineStep(
                    dictationIsInProgress: self.buddyDictationManager.isDictationInProgress,
                    clickyIsThinking: self.voiceState == .processing,
                    audioIsPlaying: self.elevenLabsTTSClient.isPlaying,
                    pushToTalkPressCount: self.pushToTalkPressCount
                )
                switch lineStep {
                case .drop:
                    print("Room art: dropped the line \"\(line)\", since the learner pressed push-to-talk after asking")
                    return
                case .waitForQuiet:
                    try? await Task.sleep(nanoseconds: 200_000_000)
                case .speakNow:
                    // The token lets a close of the panel stop this line once it plays (`stopTheRoomArtSpeech`).
                    guard let lineToken = await self.speakLiveSceneLineAndReturnItsToken(line, isAFailure: isAFailure) else { return }
                    self.roomArtLineToken = lineToken
                    await self.waitForClickyToFinishSpeaking()
                    guard !Task.isCancelled else { return }
                    if self.voiceState == .responding { self.voiceState = .idle }
                    self.scheduleTransientHideIfNeeded()
                    return
                }
            }
        }
    }

    /// The room art panel floats under the live scene's window, so a scene or pop-out on screen is cleared before it opens.
    /// The clear does nothing when no scene is up, and a video paused for the scene stays paused under the panel.
    private func clearTheLiveSceneForTheRoomArtPanel() {
        clearTheLiveSceneAndReleaseTheBuddy()
        switch liveScenePhase {
        case .touring, .allLabelsShowing:
            liveSceneTourFinishedTask?.cancel()
            liveScenePhase = .idle
        default:
            break
        }
    }

    /// A JPEG of the region the learner circled, with every window but Clicky's, or else of the largest picture in Chrome's
    /// front tab, captured the way the image pop-out captures it, for a theme built from it. Nil when there is no picture on
    /// screen, or Screen Recording is off.
    private func captureThePictureForTheThemeStudio() async -> ThemeStudioPicture? {
        let pictureRect: ScreenRectInChromeCoordinates?
        let windowsToCapture: CapturedWindows
        if let themeDesignCircledRegion {
            pictureRect = themeDesignCircledRegion.boundingRect
            windowsToCapture = .everythingButClicky
        } else {
            pictureRect = VideoQuizSession.screenRectOfTheMediaToRiseFrom()
            windowsToCapture = .chromeOnly
        }
        guard let pictureRect,
              let pictureGrab = try? await CompanionScreenCaptureUtility.captureScreenRectAsJPEG(pictureRect, windows: windowsToCapture),
              let jpegData = Data(base64Encoded: pictureGrab.jpeg) else {
            return nil
        }
        return ThemeStudioPicture(jpegData: jpegData, width: pictureGrab.width, height: pictureGrab.height)
    }

    // MARK: - Task Agent

    /// Starts a general agent on the learner's task and returns at once, so the router speaks its confirmation and the
    /// video keeps playing.
    private func startTheTaskAgent(goal: String, skillName: String? = nil, learnerWords: String) -> VoiceToolOutcome {
        let agentID = backgroundAgentStore.start(kind: .task)
        agentTokenDockController.startServingTheToken(of: agentID)
        backgroundAgentStore.setSubject(goal, for: agentID)
        backgroundAgentStore.setLearnerWords(learnerWords, for: agentID)
        if let skillName {
            // The first step line, before the agent reports its own, so the learner sees which skill runs.
            backgroundAgentStore.reportStep(TaskAgentSkillCatalog.startingStepText(skillName: skillName), for: agentID)
        }
        runInTheBackground(agentID) {
            await self.runTheTaskAgent(goal: goal, skillName: skillName, agentID: agentID)
        }
        allowTryingAgain(agentID) { [weak self] in
            guard let self, self.agentMayBeTriedAgainNow(agentKind: .task) else { return false }
            // The new try keeps the words that started the first, so its approval card says them too.
            _ = self.startTheTaskAgent(goal: goal, skillName: skillName, learnerWords: learnerWords)
            return true
        }
        return .changed(state: .object(["task": .string("started")]))
    }

    /// Starts the task on the agent harness, which runs Claude's loop, and answers each tool it asks for until the task
    /// finishes or fails. Nothing is spoken while it runs. Cancelling this task stops the task in the harness.
    private func runTheTaskAgent(goal: String, skillName: String? = nil, agentID: UUID) async {
        let startedAt = Date()
        // The screenshots the agent took, which only this task's tools needed.
        defer { TaskAgentWorkspace.removeFolder(taskID: agentID) }
        let frontTab = videoQuizSession.frontTabTitleAndURLOfTheFrontWindow()
        if let frontTabURL = frontTab?.url {
            theAgentStartedFromTheFrontTab(agentID, sourceTab: .tab(url: frontTabURL))
        }
        var writtenPageURL: URL?
        do {
            let taskEvents = try agentHarness.startTask(
                taskID: agentID,
                goal: goal,
                frontTabTitle: frontTab?.title,
                frontTabURL: frontTab?.url,
                skill: skillName,
                startsPaused: backgroundAgentStore.agentsArePaused
            )
            for await taskEvent in taskEvents {
                try Task.checkCancellation()
                switch taskEvent {
                case .toolCall(let toolCall):
                    // A call the harness sent just before its pause_task arrived still waits for "go ahead", since an
                    // app tool such as open_url changes the Mac.
                    try await holdWhileEveryAgentIsPaused("the task agent's \(toolCall.toolName) call")
                    let toolRun = await runTaskAgentTool(toolCall, agentID: agentID, pageAlreadyWritten: writtenPageURL != nil)
                    writtenPageURL = toolRun.writtenPageURL ?? writtenPageURL
                    try Task.checkCancellation()
                    agentHarness.sendToolResult(taskID: agentID, toolUseID: toolCall.toolUseID, content: toolRun.content, isError: toolRun.isError, sourceURL: toolRun.sourceURL)
                case .finished(let spokenSummary):
                    try await holdWhileEveryAgentIsPaused("the task agent's answer")
                    finishTheTaskAgent(agentID, spokenSummary: spokenSummary, pageURL: writtenPageURL)
                    return
                case .failed(let reason):
                    try await holdWhileEveryAgentIsPaused("the task agent's failure")
                    throw TaskAgentError.harnessReportedFailure(reason: reason)
                case .voiceCommandFinished:
                    // Only a voice command ends this way, so a task never hears it.
                    throw TaskAgentError.harnessEndedWithNoResult
                case .planningTurnStarted, .spokenLineIfEveryCallChanges:
                    // Only a voice command's turn plans or sends an early line, so a task has nothing to do for either.
                    break
                }
            }
            // The stream also ends when this task is cancelled, which is not a failure.
            try Task.checkCancellation()
            throw TaskAgentError.harnessEndedWithNoResult
        } catch {
            if Task.isCancelled || errorIsACancellation(error) {
                agentHarness.cancelTask(taskID: agentID)
                print("Task agent: cancelled after \(Int(Date().timeIntervalSince(startedAt))) s")
                return
            }
            print("Task agent: failed after \(Int(Date().timeIntervalSince(startedAt))) s: \(error)")
            guard await holdWhileEveryAgentIsPausedUnlessCancelled("the task agent's failure") else {
                agentHarness.cancelTask(taskID: agentID)
                return
            }
            backgroundAgentStore.fail(agentID, reason: "The task could not be finished. Ask again to try once more.")
            playCursorEmote(.shake)
            bringBackTheEndingChip(ofAgent: agentID) {
                VoiceToolCallChip.shared.show("Couldn't finish the task", sender: .failure, secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen)
            }
        }
    }

    /// Runs one app tool for the agent and returns its tool_result content. A tool that fails returns an error result,
    /// so the agent can work around it instead of the task failing. `sourceURL` is the video's link for a
    /// read_video_captions result and nil for every other tool, since the harness lets the agent cite only a link it
    /// gets in that field.
    private func runTaskAgentTool(_ toolCall: HarnessToolCall, agentID: UUID, pageAlreadyWritten: Bool) async -> (content: JSONValue, isError: Bool, writtenPageURL: URL?, sourceURL: String?) {
        func errorResult(_ message: String) -> (content: JSONValue, isError: Bool, writtenPageURL: URL?, sourceURL: String?) {
            (.string(message), true, nil, nil)
        }
        switch TaskAgentTool(rawValue: toolCall.toolName) {
        case .reportStep:
            let stepText = (toolCall.input["step"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !stepText.isEmpty {
                backgroundAgentStore.reportStep(String(stepText.prefix(60)), for: agentID)
            }
            return (.string("shown"), false, nil, nil)
        case .readVideoCaptions:
            do {
                let video = try await videoQuizSession.frontVideoForStudyGuide()
                let captionText = video.transcriptLines
                    .map { transcriptLine in "[\(backgroundAgentElapsedTimeText(seconds: transcriptLine.seconds))] \(transcriptLine.text)" }
                    .joined(separator: "\n")
                let captionsResult = "Title: \(video.title)\nLink: \(video.url)\nCaptions:\n\(captionText)"
                backgroundAgentStore.setReadingHost(agentListHost(ofLink: video.url), for: agentID)
                return (.string(String(captionsResult.prefix(longestTaskAgentCaptionText))), false, nil, video.url)
            } catch {
                return errorResult((error as? LocalizedError)?.errorDescription ?? "No YouTube video with captions is in Chrome's front tab")
            }
        case .lookAtVideo:
            // The agent also reads web pages, which could ask it to look around the screen, so it sees only the video's
            // area, from Chrome's windows alone, and nothing when no video is found.
            guard let videoRect = VideoQuizSession.screenRectOfTheMediaToRiseFrom(),
                  let videoGrab = try? await CompanionScreenCaptureUtility.captureScreenRectAsJPEG(videoRect) else {
                return errorResult("No video is on screen to look at")
            }
            return (.array([.object([
                "type": .string("image"),
                "source": .object(["type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string(videoGrab.jpeg)]),
            ])]), false, nil, nil)
        case .writeNotionPage:
            guard !pageAlreadyWritten else {
                return errorResult("A page was already written for this task")
            }
            if let pageInputProblem = taskAgentPageInputProblem(toolCall.input) {
                return errorResult(pageInputProblem)
            }
            backgroundAgentStore.reportStep("Writing the page in Notion", for: agentID)
            do {
                let pageURL = try await taskAgentClient.writeNotionPage(toolCall.input)
                print("Task agent: wrote \(pageURL)")
                return (.string("Written: \(pageURL.absoluteString)"), false, pageURL, nil)
            } catch {
                print("Task agent: the Notion page failed: \(error)")
                return errorResult("The page could not be written: \(error)")
            }
        case .takeScreenshot, .readClipboard, .writeClipboard, .openURL:
            if TaskAgentTool(rawValue: toolCall.toolName) == .openURL {
                backgroundAgentStore.setReadingHost(toolCall.input["url"]?.stringValue.flatMap(agentListHost(ofLink:)), for: agentID)
            }
            let generalToolRun = await runTaskAgentGeneralTool(named: toolCall.toolName, input: toolCall.input, taskID: agentID)
            return (generalToolRun.content, generalToolRun.isError, nil, nil)
        case nil:
            // The harness asks only for the tools above, so this is a harness newer than the app.
            return errorResult("\(toolCall.toolName) is not a tool")
        }
    }

    /// Keeps a task agent's answer until the learner asks for it. A newer answer replaces the one still waiting, so the
    /// older agent's token leaves at once.
    private func holdTheTaskAnswerUntilItIsHeard(_ spokenSummary: String, forAgent agentID: UUID) {
        if let replacedTaskAnswerAgentID = readyTaskAnswerAgentID {
            backgroundAgentStore.setResultIsWaiting(false, for: replacedTaskAnswerAgentID)
        }
        readyTaskAnswerAgentID = agentID
        readyTaskAnswer = taskAgentSpokenAnswer(spokenSummary)
        taskAnswerWaitsToBeHeard = true
    }

    private func finishTheTaskAgent(_ agentID: UUID, spokenSummary: String, pageURL: URL?) {
        holdTheTaskAnswerUntilItIsHeard(spokenSummary, forAgent: agentID)
        finishTheBackgroundAgent(agentID, agentKind: .task, with: .answer(spokenSummary: spokenSummary, pageURL: pageURL))
    }

    /// Like any spoken reply, a push-to-talk press stops it.
    private func startSpeakingTheTaskAnswer() {
        guard let readyTaskAnswer else { return }
        taskAnswerWaitsToBeHeard = false
        if let readyTaskAnswerAgentID {
            backgroundAgentStore.setResultIsWaiting(false, for: readyTaskAnswerAgentID)
        }
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        currentResponseTask = Task {
            await self.speakLiveSceneLine(readyTaskAnswer, isAFailure: false)
            await self.waitForClickyToFinishSpeaking()
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    // MARK: - Installing a theme file

    /// A `.clickytheme` package the learner opened: reads and checks it, and asks "Add theme?" before installing anything. A
    /// package that does not parse is refused with a log line naming the rule it broke and a chip, with no card, and nothing
    /// changes.
    func installTheThemePackage(at themePackageURL: URL) {
        do {
            let packagePreview = try themeSettings.previewPackage(at: themePackageURL)
            themeInstallConfirmation.ask(about: PendingThemeInstall(packageURL: themePackageURL, theme: packagePreview.theme, pictureJPEG: packagePreview.pictureJPEG))
        } catch let parseError as CustomThemeParseError {
            print("Themes: refused \(themePackageURL.lastPathComponent): \(parseError.reason)")
            VoiceToolCallChip.shared.show(themeCouldNotBeAddedChipPhrase, sender: .failure)
        } catch {
            print("Themes: refused \(themePackageURL.lastPathComponent): \(error)")
            VoiceToolCallChip.shared.show(themeCouldNotBeAddedChipPhrase, sender: .failure)
        }
    }

    /// The learner added the theme on the card: installs it, puts it on, plays its done sound, and says so. The package is
    /// read and checked again, since it may have changed while the card showed.
    private func installTheConfirmedThemePackage(_ confirmedInstall: PendingThemeInstall) {
        do {
            let installedTheme = try themeSettings.installAndApply(
                packageAt: confirmedInstall.packageURL,
                expectedPreview: CustomThemeStore.ThemePackagePreview(theme: confirmedInstall.theme, pictureJPEG: confirmedInstall.pictureJPEG)
            )
            print("Themes: installed \(confirmedInstall.packageURL.lastPathComponent) as \(installedTheme.id)")
            VoiceToolCallChip.shared.show(themeAddedChipPhrase, secondaryChipText: installedTheme.name)
            installedTheme.sounds.done.play()
        } catch let parseError as CustomThemeParseError {
            print("Themes: refused \(confirmedInstall.packageURL.lastPathComponent): \(parseError.reason)")
            VoiceToolCallChip.shared.show(themeCouldNotBeAddedChipPhrase, sender: .failure)
        } catch {
            print("Themes: refused \(confirmedInstall.packageURL.lastPathComponent): \(error)")
            VoiceToolCallChip.shared.show(themeCouldNotBeAddedChipPhrase, sender: .failure)
        }
    }

    // MARK: - Task Agent Approvals

    /// A task agent's tool waits for the learner to allow it. Nothing is spoken, since the learner is usually watching a
    /// video: "Pop" plays once and the agent list opens next to the mouse with the request in its agent's row, unless the
    /// menu bar panel is open on its home, whose banner shows the card.
    /// A request the harness sent just before its pause_task shows at once too, like one that was already waiting when the
    /// learner paused, since "go ahead" answers it before it resumes the agents and a hidden card could not be answered.
    private func showTheApprovalRequest(_ approvalRequest: HarnessApprovalRequest) {
        themeSettings.shownTheme.sounds.needsYourOK.play()
        // The panel's banner already shows the card, so the list does not open over it.
        guard !menuPanelShowsTheApprovalCard() else { return }
        agentListPanelController.openForAnApprovalRequest(fromAgentID: approvalRequest.taskID)
    }

    /// Which showing of each agent's settled mark is the latest, so an older one's timer never removes a newer mark.
    private var approvalSettledMarkShowingIDs: [UUID: UUID] = [:]

    private func showTheApprovalSettledMark(_ mark: AgentTokenApprovalSettledMark, onTheDiscOf agentID: UUID) {
        let showingID = UUID()
        approvalSettledMarkShowingIDs[agentID] = showingID
        backgroundAgentStore.approvalSettledMarksByAgentID[agentID] = mark
        DispatchQueue.main.asyncAfter(deadline: .now() + agentTokenApprovalSettledMarkSeconds) { [weak self] in
            guard let self, self.approvalSettledMarkShowingIDs[agentID] == showingID else { return }
            self.approvalSettledMarkShowingIDs[agentID] = nil
            self.backgroundAgentStore.approvalSettledMarksByAgentID[agentID] = nil
        }
    }

    /// Keeps the chip in step with the approval desk, after each arrival and answer.
    private func syncTheApprovalWaitingState(_ waitingRequests: [HarnessApprovalRequest]) {
        backgroundAgentStore.agentIDsWaitingForApproval = Set(waitingRequests.map(\.taskID))
        // The oldest request of an agent speaks for it, and the requests arrive oldest first.
        backgroundAgentStore.approvalCapabilitiesByAgentID = Dictionary(waitingRequests.map { ($0.taskID, $0.capability) }, uniquingKeysWith: { oldestCapability, _ in oldestCapability })
        if let previousChipText = approvalWaitingChipPrimaryText {
            VoiceToolCallChip.shared.hide(ifShowing: previousChipText)
            approvalWaitingChipPrimaryText = nil
        }
        guard let oldestRequest = waitingRequests.first,
              let waitingAgent = backgroundAgentStore.agents.first(where: { $0.id == oldestRequest.taskID }) else { return }
        let chipTexts = approvalWaitingChipTexts(agentName: waitingAgent.displayName)
        approvalWaitingChipPrimaryText = chipTexts.primary
        VoiceToolCallChip.shared.show(
            chipTexts.primary,
            sender: chipSender(forAgent: waitingAgent.id, kind: waitingAgent.kind),
            secondaryChipText: chipTexts.secondary,
            survivesARecall: true,
            secondsOnScreen: HarnessApprovalDesk.defaultTimeoutSeconds
        )
    }

    // MARK: - Pausing every agent

    /// "Hold on" and "go ahead". The Swift agents read the Mac at once and wait before their Worker call and their ending
    /// (`waitWhileAgentsArePaused`). Each running task agent's harness task gets `pause_task` or `resume_task`, so no model
    /// turn or tool call starts for it. Push-to-talk and the voice brain never pause.
    private func setEveryAgentIsPaused(_ agentsArePaused: Bool) -> VoiceToolOutcome {
        let pauseChanged = agentsArePaused ? backgroundAgentStore.pauseEveryAgent() : backgroundAgentStore.resumeEveryAgent()
        guard pauseChanged else {
            return .failed(error: agentsArePaused ? "The agents are already paused" : "No agent is paused", state: nil)
        }
        let runningAgents = backgroundAgentStore.agents.filter(\.isRunning)
        for runningTaskAgent in runningAgents where runningTaskAgent.kind == .task {
            agentHarness.setTaskIsPaused(agentsArePaused, taskID: runningTaskAgent.id)
        }
        print("Agents: \(agentsArePaused ? "paused" : "resumed") \(runningAgents.count) running \(runningAgents.count == 1 ? "agent" : "agents")")
        return .changed(state: .object(["backgroundAgents": .string(agentsArePaused ? "paused" : "running")]))
    }

    /// Holds an agent's Worker call, a task agent's tool call, or an ending while every agent is paused, and throws once
    /// the agent was cancelled.
    /// `heldStep` names what waits, for the log.
    private func holdWhileEveryAgentIsPaused(_ heldStep: String) async throws {
        await waitWhileEveryAgentIsPaused(heldStep)
        try Task.checkCancellation()
    }

    /// The same, for a failure's ending: false when the agent was cancelled during the pause, so it shows nothing.
    private func holdWhileEveryAgentIsPausedUnlessCancelled(_ heldStep: String) async -> Bool {
        await waitWhileEveryAgentIsPaused(heldStep)
        return !Task.isCancelled
    }

    private func waitWhileEveryAgentIsPaused(_ heldStep: String) async {
        guard backgroundAgentStore.agentsArePaused else { return }
        print("Agents: holding \(heldStep) until the learner resumes")
        await backgroundAgentStore.waitWhileAgentsArePaused()
    }

    // MARK: - Background Scene Agents (3D model and experiment)

    /// "Let me try it" starts the experiment agent and says one line, so the video keeps playing while it builds.
    /// A scene still building in the foreground is cancelled first, as a plain question cancels it, so its phase and
    /// the video's pause do not stay behind.
    private func startTheExperimentInTheBackground(transcript: String) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        cancelTheSceneStillBuilding()
        let spokenLine: String
        switch currentExperimentRequestStep {
        case .showTheReadyExperiment:
            startShowingTheReadyBackgroundScene()
            return
        case .sayItIsStillBuilding:
            spokenLine = "Your experiment is still building."
        case .startBuilding:
            _ = startBuildingASceneInTheBackground(whatToBuild: transcript, agentKind: .experiment)
            spokenLine = experimentStartedSpokenLine(agentsArePaused: backgroundAgentStore.agentsArePaused)
        }
        currentResponseTask = Task {
            // The experiment agent serves its token from the cursor first, and the line plays after it lands.
            await self.agentTokenDockController.waitForTheServeToLand()
            guard !Task.isCancelled else { return }
            await self.speakLiveSceneLine(spokenLine, isAFailure: false)
            await self.waitForClickyToFinishSpeaking()
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    private var currentExperimentRequestStep: ExperimentRequestStep {
        experimentRequestStep(
            anExperimentIsReady: readyBackgroundScene?.agentKind == .experiment,
            anExperimentIsBuilding: backgroundAgentStore.anAgentIsRunning(ofKind: .experiment)
        )
    }

    /// Starts the build and returns at once, so the router speaks its confirmation and the video keeps playing.
    private func startBuildingASceneInTheBackground(whatToBuild: String, agentKind: BackgroundAgentKind) -> VoiceToolOutcome {
        let agentID = backgroundAgentStore.start(kind: agentKind)
        agentTokenDockController.startServingTheToken(of: agentID)
        runInTheBackground(agentID) {
            await self.buildTheBackgroundScene(whatToBuild: whatToBuild, agentID: agentID, agentKind: agentKind)
        }
        allowTryingAgain(agentID) { [weak self] in
            // The same rules the voice tools keep: one experiment builds at a time, a question owns the scene while it is
            // open, and a 3D model is built from a video in front.
            guard let self, self.agentMayBeTriedAgainNow(agentKind: agentKind) else { return false }
            _ = self.startBuildingASceneInTheBackground(whatToBuild: whatToBuild, agentKind: agentKind)
            return true
        }
        return .changed(state: .object(["backgroundScene": .string("started")]))
    }

    /// The same `POST /live-scene` request a scene build makes, from a screenshot of the playing video, with no status
    /// line and no pause. Like a guide, nothing is spoken while it runs. An experiment asks for a simulation page, and
    /// its lesson, the page's hypothesis and explanation, waits with the page.
    private func buildTheBackgroundScene(whatToBuild: String, agentID: UUID, agentKind: BackgroundAgentKind) async {
        let startedAt = Date()
        let sceneKind = agentKind.liveSceneKindToBuild ?? .explore
        do {
            // An experiment over a page with no video is tied to no tab, so it may rise once the screen is free.
            let buildsOverAVideo = agentKind == .threeDModel || videoQuizSession.frontVideoStateForVoiceCommands() != nil
            let sourceTabURL = buildsOverAVideo ? videoQuizSession.frontTabURLOfTheFrontWindow() : nil
            if let sourceTabURL {
                theAgentStartedFromTheFrontTab(agentID, sourceTab: .tab(url: sourceTabURL))
            }
            let heardText = videoQuizSession.whatTheQuizVideoInFrontJustSaid()
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let videoScreen = screenAndCaptureShowing(VideoQuizSession.screenRectOfTheMediaToRiseFrom(), in: screenCaptures)
            guard let videoScreenJPEGData = (videoScreen?.capture ?? screenCaptures.first)?.imageData else {
                throw BackgroundSceneBuildError.noScreenshot
            }
            try Task.checkCancellation()
            backgroundAgentStore.setSubject(whatToBuild, for: agentID)
            backgroundAgentStore.completeStep(for: agentID)
            // The frame, tab, and words above are read at once, even during a pause, so the build is of what the learner
            // asked about. Only the Worker call waits for "go ahead".
            try await holdWhileEveryAgentIsPaused("the \(agentKind.builtThingName)'s build")
            let sceneQuestion = heardText.isEmpty ? whatToBuild : "\(whatToBuild) The video just said: \(heardText)"
            let liveScene = try await liveSceneClient.requestLiveScene(question: sceneQuestion, cursorScreenJPEGData: videoScreenJPEGData, sceneKind: sceneKind, buildWait: .inTheBackground)
            // A reply that arrives during a pause waits with the agent, and never rises over what the learner held still for.
            try await holdWhileEveryAgentIsPaused("the finished \(agentKind.builtThingName)")
            // A scene cancelled from the agent list never shows, even when the Worker had already replied.
            try Task.checkCancellation()
            print("\(agentKind.displayName): built \"\(whatToBuild)\" in \(Int(Date().timeIntervalSince(startedAt))) s")
            if let replacedReadyBackgroundScene = readyBackgroundScene {
                print("\(agentKind.displayName): this \(agentKind.builtThingName) finished last, so it replaces the scene still waiting to be shown")
                backgroundAgentStore.setResultIsWaiting(false, for: replacedReadyBackgroundScene.agentID)
            }
            // The quiz fields are the page's text, so the lesson cuts them.
            let simulationLesson = agentKind == .experiment
                ? SimulationLesson(predictionQuestion: liveScene.quiz.question, physicsExplanation: liveScene.quiz.explanation)
                : nil
            readyBackgroundScene = ReadyBackgroundScene(
                agentID: agentID,
                agentKind: agentKind,
                whatToBuild: whatToBuild,
                pageHTML: liveScene.html,
                sourceTabURL: sourceTabURL,
                simulationLesson: simulationLesson
            )
            finishTheBackgroundAgent(agentID, agentKind: agentKind, with: .readyScene)
        } catch {
            if Task.isCancelled || errorIsACancellation(error) {
                print("\(agentKind.displayName): cancelled after \(Int(Date().timeIntervalSince(startedAt))) s")
                return
            }
            print("\(agentKind.displayName): failed after \(Int(Date().timeIntervalSince(startedAt))) s: \(error)")
            // A failure's chip waits through a pause like a result, and a cancel during it shows nothing.
            guard await holdWhileEveryAgentIsPausedUnlessCancelled("the \(agentKind.builtThingName)'s failure") else { return }
            backgroundAgentStore.fail(agentID, reason: "The \(agentKind.builtThingName) could not be built. Ask again to try once more.")
            playCursorEmote(.shake)
            bringBackTheEndingChip(ofAgent: agentID) {
                VoiceToolCallChip.shared.show(
                    "Couldn't build the \(agentKind.builtThingName)",
                    sender: .failure,
                    secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
                )
            }
        }
    }

    /// The screen showing the video, with its screenshot, so a background model is built from and rises on the video's
    /// own screen wherever the mouse is, since the learner may have moved on while it was built. Falls back to the screen
    /// under the mouse, with no screenshot when none matches it.
    private func screenAndCaptureShowing(
        _ mediaRect: ScreenRectInChromeCoordinates?,
        in screenCaptures: [CompanionScreenCapture]
    ) -> (screen: NSScreen, capture: CompanionScreenCapture?)? {
        let screens = NSScreen.screens
        let screenIndexShowingTheMedia = mediaRect.flatMap { mediaRect in
            indexOfTheScreenFrameHolding(mediaRect, screenFramesInAppKitCoordinates: screens.map(\.frame))
        }
        guard let screen = screenIndexShowingTheMedia.map({ screens[$0] }) ?? screenUnderTheMouseCursor() else { return nil }
        return (screen: screen, capture: screenCaptures.first { $0.displayFrame == screen.frame })
    }

    private var aReadyBackgroundSceneMayRiseNow: Bool {
        guard let readyBackgroundScene else { return false }
        var liveScenePhaseIsIdle = false
        if case .idle = liveScenePhase { liveScenePhaseIsIdle = true }
        return backgroundSceneMayRiseNow(
            readyBackgroundScene,
            // voiceState goes idle once a spoken line starts, so isPlaying covers the rest of the line.
            clickyIsIdleAndDoneSpeaking: voiceState == .idle && !elevenLabsTTSClient.isPlaying,
            aSceneOrPopOutIsBuildingOrShowing: !liveScenePhaseIsIdle || LiveSceneOverlay.shared.isShowingAScene,
            aVideoQuizQuestionIsOpen: videoQuizQuestionIsActive,
            // The panel floats under the live scene's window, so a scene rising now would cover the learner's room.
            theRoomArtPanelIsOpen: roomArtPreviewController.isOpen,
            readFrontTabURL: { self.videoQuizSession.frontTabURLOfTheFrontWindow() }
        )
    }

    /// Like a new scene request, this stops what Clicky says and puts back the scene on screen first.
    private func startShowingTheReadyBackgroundScene() {
        currentResponseTask?.cancel()
        liveSceneRequestTask?.cancel()
        liveSceneTourFinishedTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        liveSceneRequestGeneration += 1
        let requestGeneration = liveSceneRequestGeneration
        if case .touring = liveScenePhase {
            liveScenePhase = .allLabelsShowing
        }
        clearFinishedLiveScene(resumesTheVideo: false)
        currentResponseTask = Task {
            await self.showTheReadyBackgroundScene(requestGeneration: requestGeneration)
        }
    }

    /// Pauses the video it was built from and lifts the scene out of it. A 3D model then says what it shows, and an
    /// experiment waits for its tour to end, when the lesson asks for the learner's guess.
    /// The screenshot for the rise is taken now, after the pause, so the still frame matches the video under it.
    private func showTheReadyBackgroundScene(requestGeneration: Int) async {
        guard let sceneToShow = readyBackgroundScene else { return }
        readyBackgroundScene = nil
        backgroundAgentStore.setResultIsWaiting(false, for: sceneToShow.agentID)
        let logPrefix = sceneToShow.agentKind.displayName
        let sourceVideoIsInFront = sceneToShow.sourceTabURL != nil && videoQuizSession.frontTabURLOfTheFrontWindow() == sceneToShow.sourceTabURL
        if sourceVideoIsInFront {
            _ = videoQuizSession.pauseVideoForRequestedScene()
        }
        voiceState = .processing
        var screenCaptures: [CompanionScreenCapture] = []
        do {
            screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        } catch {
            print("\(logPrefix): screen capture for the rise failed, so it shows without rising: \(error)")
        }
        let mediaRectToRiseFrom = sourceVideoIsInFront ? VideoQuizSession.screenRectOfTheMediaToRiseFrom() : nil
        guard requestGeneration == liveSceneRequestGeneration, !Task.isCancelled else {
            // A push-to-talk press during the capture cancelled the rise, so the scene waits again for "show the model"
            // or "show the experiment", unless a newer one took its place. The video plays on only when no newer request
            // started, after a cleared pop-out lands, as every resume waits. Any newer request counts, since a scene request
            // holds Clicky's pause for its own scene, so a plain question asked during the capture leaves the video paused.
            if readyBackgroundScene == nil {
                readyBackgroundScene = sceneToShow
                backgroundAgentStore.setResultIsWaiting(true, for: sceneToShow.agentID)
            }
            guard requestGeneration == liveSceneRequestGeneration else { return }
            await LiveSceneOverlay.shared.waitForReturnToFinish()
            guard requestGeneration == liveSceneRequestGeneration else { return }
            videoQuizSession.resumeVideoAfterRequestedScene()
            return
        }
        let sceneIsAnExperiment = sceneToShow.agentKind == .experiment
        guard let videoScreen = screenAndCaptureShowing(mediaRectToRiseFrom, in: screenCaptures),
              playGeneratedScenePage(
                  html: sceneToShow.pageHTML,
                  pageOnScreen: sceneIsAnExperiment ? .simulation : .generatedPage,
                  quizToAskAfterTour: nil,
                  overlayScreen: videoScreen.screen,
                  screenJPEGData: videoScreen.capture?.imageData,
                  mediaRectToRiseFrom: mediaRectToRiseFrom
              ) else {
            await sayTheSceneCouldNotBeBuilt()
            return
        }
        // The lesson speaks its own guess invitation after the tour, so an experiment is not narrated here.
        simulationLesson = sceneToShow.simulationLesson
        print("\(logPrefix): showing \"\(sceneToShow.whatToBuild)\", rising out of the video \(mediaRectToRiseFrom != nil)")
        if !sceneIsAnExperiment {
            await speakAboutTheLiveSceneOnScreen(
                transcript: sceneToShow.whatToBuild,
                labeledImages: screenCaptures.map { capture in (data: capture.imageData, label: capture.label) }
            )
        }
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Study Guide

    /// A guide exists for the video in front only when that video is on YouTube and a guide is saved for it whose page
    /// is still in Notion.
    private func studyGuideExistsForTheFrontVideo(frontVideoState: JSONValue?, frontVideoURLSource: FrontVideoURLSource = .readNow) async -> Bool {
        guard frontVideoState?["onYouTube"]?.boolValue == true,
              let frontVideoURL = frontVideoURLSource.url(readNow: { videoQuizSession.frontTabURLOfTheFrontWindow() }) else {
            return false
        }
        return await savedStudyGuideStillInNotion(forVideoURL: frontVideoURL, checkEvenIfCheckedBefore: false) != nil
    }

    /// The guide saved for this video, unless its Notion page was trashed or deleted. Then the saved guide is forgotten,
    /// so the video can get a new one. Each guide is checked once per launch, or every time with checkEvenIfCheckedBefore.
    private func savedStudyGuideStillInNotion(forVideoURL videoURL: String, checkEvenIfCheckedBefore: Bool) async -> StudyGuideRecord? {
        guard let savedRecord = savedStudyGuides.record(forVideoURL: videoURL) else { return nil }
        if !checkEvenIfCheckedBefore && studyGuidePageHandlesFoundInNotion.contains(savedRecord.pageHandle) {
            return savedRecord
        }
        var pageStillExists: Bool?
        do {
            pageStillExists = try await studyGuideClient.pageStillExists(pageHandle: savedRecord.pageHandle)
        } catch {
            print("Study guide: could not check \(savedRecord.pageURL) in Notion, so the saved guide stands: \(error)")
        }
        if pageStillExists == true {
            studyGuidePageHandlesFoundInNotion.insert(savedRecord.pageHandle)
        }
        // Read after the check, since a guide agent may have started or saved a new guide meanwhile.
        let recordSavedNow = savedStudyGuides.record(forVideoURL: videoURL)
        guard savedStudyGuideIsForgotten(
            pageStillExists: pageStillExists,
            aGuideAgentIsRunningForTheVideo: backgroundAgentStore.aStudyGuideAgentIsRunning(forVideoKey: studyGuideVideoKey(forVideoURL: videoURL)),
            checkedGuideIsStillSaved: recordSavedNow?.pageHandle == savedRecord.pageHandle
        ) else {
            return recordSavedNow
        }
        print("Study guide: \(savedRecord.pageURL) is no longer in Notion, so the saved guide is forgotten")
        savedStudyGuides.forget(forVideoURL: videoURL)
        studyGuidePageHandlesFoundInNotion.remove(savedRecord.pageHandle)
        notionPageChromeTabIDsByPageURL[savedRecord.pageURL] = nil
        return nil
    }

    /// Starts the guide in the background and returns at once, so the router speaks its own confirmation
    /// and the video keeps playing. Guides for different videos run at once, but one video has one guide agent at a time.
    private func startWritingTheStudyGuide(_ studyGuideJob: StudyGuideJob) -> VoiceToolOutcome {
        guard let frontVideoURL = videoQuizSession.frontTabURLOfTheFrontWindow() else {
            return .failed(error: "No video is in Chrome's front tab", state: nil)
        }
        let videoKey = studyGuideVideoKey(forVideoURL: frontVideoURL)
        guard !backgroundAgentStore.aStudyGuideAgentIsRunning(forVideoKey: videoKey) else {
            return .failed(error: "This video's study guide is still being written", state: nil)
        }
        let agentID = backgroundAgentStore.start(kind: studyGuideJob.agentKind, studyGuideVideoKey: videoKey)
        theAgentStartedFromTheFrontTab(agentID, sourceTab: .youTubeVideo(key: videoKey))
        if studyGuideJob.isAskedForByTheLearner {
            agentTokenDockController.startServingTheToken(of: agentID)
        }
        runInTheBackground(agentID) {
            let guideWasWritten = await self.writeTheStudyGuide(studyGuideJob, agentID: agentID)
            switch queuedStudyGuideRefreshStep(
                endedGuideWasWritten: guideWasWritten,
                aGuideAgentIsRunningForTheVideo: self.backgroundAgentStore.aStudyGuideAgentIsRunning(forVideoKey: videoKey)
            ) {
            case .leaveItForTheRunningGuide:
                break
            case .dropIt:
                self.studyGuideRefreshIsDueForQuizVideoURLByVideoKey[videoKey] = nil
            case .runIt:
                if let quizVideoURLDueARefresh = self.studyGuideRefreshIsDueForQuizVideoURLByVideoKey.removeValue(forKey: videoKey) {
                    self.refreshTheStudyGuide(forQuizVideoURL: quizVideoURLDueARefresh)
                }
            }
        }
        allowTryingAgain(agentID) { [weak self] in
            // A guide is written from the video in front, so a retry waits for the video the first one was for.
            guard let self,
                  self.agentMayBeTriedAgainNow(agentKind: studyGuideJob.agentKind),
                  let frontVideoURL = self.videoQuizSession.frontTabURLOfTheFrontWindow(),
                  studyGuideVideoKey(forVideoURL: frontVideoURL) == videoKey else { return false }
            if case .failed = self.startWritingTheStudyGuide(studyGuideJob) { return false }
            return true
        }
        return .changed(state: .object(["studyGuide": .string("started")]))
    }

    /// The agent was started in the store already, so the list shows it before its task runs.
    private func runInTheBackground(_ agentID: UUID, _ agentWork: @escaping @MainActor () async -> Void) {
        backgroundAgentTasks[agentID] = Task {
            await agentWork()
            self.backgroundAgentTasks[agentID] = nil
        }
    }

    /// A missed or skipped question reaches a guide already written for the quiz video, by an update agent in the
    /// background, so the guide shows the miss without the learner asking.
    private func refreshTheStudyGuideAfterAQuizOutcome(_ outcome: StudyGuideQuizOutcome) {
        guard quizOutcomeRefreshesTheStudyGuide(outcome),
              let quizVideoURL = videoQuizSession.frontTabURLOfTheFrontWindow() else { return }
        // A guide being written read its quiz results when it started, so the refresh runs once it ends.
        let quizVideoKey = studyGuideVideoKey(forVideoURL: quizVideoURL)
        guard !backgroundAgentStore.aStudyGuideAgentIsRunning(forVideoKey: quizVideoKey) else {
            studyGuideRefreshIsDueForQuizVideoURLByVideoKey[quizVideoKey] = quizVideoURL
            return
        }
        refreshTheStudyGuide(forQuizVideoURL: quizVideoURL)
    }

    /// Nothing happens for a video with no guide, whose next guide includes the miss anyway. The page is checked in
    /// Notion first, so a miss never brings back a guide the learner trashed. When the quiz video is not in front, the
    /// miss stays in the quiz log for that video's next refresh or revise.
    private func refreshTheStudyGuide(forQuizVideoURL quizVideoURL: String) {
        guard studyGuideRefreshMayStart(forQuizVideoURL: quizVideoURL, frontVideoURL: videoQuizSession.frontTabURLOfTheFrontWindow()) else {
            return
        }
        studyGuideRefreshesBeingChecked += 1
        Task {
            defer { self.studyGuideRefreshesBeingChecked -= 1 }
            guard await self.savedStudyGuideStillInNotion(forVideoURL: quizVideoURL, checkEvenIfCheckedBefore: true) != nil,
                  studyGuideRefreshMayStart(forQuizVideoURL: quizVideoURL, frontVideoURL: self.videoQuizSession.frontTabURLOfTheFrontWindow()) else {
                return
            }
            let quizVideoKey = studyGuideVideoKey(forVideoURL: quizVideoURL)
            guard !self.backgroundAgentStore.aStudyGuideAgentIsRunning(forVideoKey: quizVideoKey) else {
                self.studyGuideRefreshIsDueForQuizVideoURLByVideoKey[quizVideoKey] = quizVideoURL
                return
            }
            print("Study guide: updating the guide with the quiz miss")
            _ = self.startWritingTheStudyGuide(.refresh)
        }
    }

    /// Nothing is spoken when the guide ends, because the learner is watching a video. The token beside the notch,
    /// the chip above the cursor, and the page in a background tab say it instead. Returns whether the guide was written.
    @discardableResult
    private func writeTheStudyGuide(_ studyGuideJob: StudyGuideJob, agentID: UUID) async -> Bool {
        let startedAt = Date()
        let agentKind = studyGuideJob.agentKind
        do {
            // The captions are read at once, even during a pause, so the guide is written for the video the learner
            // asked about. Only the Worker call below waits for "go ahead".
            let video = try await videoQuizSession.frontVideoForStudyGuide()
            backgroundAgentStore.setSubject(video.title, for: agentID)
            backgroundAgentStore.completeStep(for: agentID)
            print("Study guide: read the captions in \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s")
            var studyGuideRevision: StudyGuideRevision?
            var studyGuideFocus: String?
            var pageURLTheRevisionReplaces: URL?
            var quizResultsForTheGuide = video.quizResults
            switch studyGuideJob {
            case .write(let focus):
                // The tools were offered for the tab in front when the command arrived, and the learner may have
                // switched to a video that already has a guide since.
                guard savedStudyGuides.record(forVideoURL: video.url) == nil else {
                    throw StudyGuideError.guideAlreadyWritten
                }
                studyGuideFocus = focus
            case .revise, .refresh:
                guard let previousRecord = savedStudyGuides.record(forVideoURL: video.url) else {
                    print("Study guide: no guide to revise for \(video.url)")
                    throw StudyGuideError.noGuideToRevise
                }
                var revisionInstruction: String?
                if case .revise(let instruction) = studyGuideJob { revisionInstruction = instruction }
                studyGuideRevision = StudyGuideRevision(pageHandle: previousRecord.pageHandle, previousGuide: previousRecord.guide, instruction: revisionInstruction)
                pageURLTheRevisionReplaces = previousRecord.pageURL
                // The Worker rebuilds "Review these first" from the results it gets, so the ones already on the page
                // go along with the ones logged since launch.
                quizResultsForTheGuide = studyGuideQuizResults(saved: previousRecord.quizResults, logged: video.quizResults)
            }
            try await holdWhileEveryAgentIsPaused("the study guide's writing")
            var studyGuideRecord = try await studyGuideClient.writeStudyGuide(StudyGuideRequest(
                videoTitle: video.title,
                videoURL: video.url,
                transcriptLines: video.transcriptLines,
                quizResults: quizResultsForTheGuide,
                focus: studyGuideFocus,
                revision: studyGuideRevision
            ))
            studyGuideRecord.quizResults = quizResultsForTheGuide
            // A guide written during a pause waits to be saved and opened. A cancel meanwhile takes the cancelled path below,
            // which still keeps a revision whose old page the Worker already trashed.
            await waitWhileEveryAgentIsPaused("the written study guide")
            let agentWasCancelled = Task.isCancelled
            guard !agentWasCancelled || studyGuideJob.replyIsSavedEvenWhenCancelled else { throw CancellationError() }
            // Filed under the video the guide was written for, not whichever tab is in front now.
            savedStudyGuides.save(studyGuideRecord, forVideoURL: video.url)
            videoRecapWatcher.startWatching(forVideoURL: video.url)
            // The Worker just wrote this page, so the next voice command does not wait on a status check for it.
            studyGuidePageHandlesFoundInNotion.insert(studyGuideRecord.pageHandle)
            guard !agentWasCancelled else {
                // cancelBackgroundAgent already marked the agent cancelled, and a cancelled guide shows no chip. The tab
                // showing the trashed page still moves to the new one, so the guide never has two tabs.
                if let replacingPageURL = pageURLTheRevisionReplaces {
                    loadThePageInTheTabOfThePageItReplaces(studyGuideRecord.pageURL, replacingPageURL: replacingPageURL)
                }
                print("Study guide: kept \(studyGuideRecord.pageURL) for a cancelled agent, since its old page is already trashed")
                return false
            }
            print("Study guide: wrote \(studyGuideRecord.pageURL) in \(Int(Date().timeIntervalSince(startedAt))) s")
            finishTheBackgroundAgent(agentID, agentKind: agentKind, with: .notionPage(studyGuideRecord.pageURL), replacingPageURL: pageURLTheRevisionReplaces)
            return true
        } catch {
            if Task.isCancelled || errorIsACancellation(error) {
                // cancelBackgroundAgent already marked the agent cancelled, and a cancelled guide shows no chip.
                print("Study guide: cancelled after \(Int(Date().timeIntervalSince(startedAt))) s")
                return false
            }
            print("Study guide: failed after \(Int(Date().timeIntervalSince(startedAt))) s: \(error)")
            guard await holdWhileEveryAgentIsPausedUnlessCancelled("the study guide's failure") else { return false }
            backgroundAgentStore.fail(agentID, reason: studyGuideFailureReason(for: error))
            playCursorEmote(.shake)
            bringBackTheEndingChip(ofAgent: agentID) {
                VoiceToolCallChip.shared.show(
                    studyGuideFailureLine(for: error),
                    sender: .failure,
                    secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
                )
            }
            return false
        }
    }

    /// Loads a revision's new page in the tab Clicky opened for the page it replaces, and files that tab under the new page.
    /// False when Clicky has no tab for the replaced page or the tab is gone.
    @discardableResult
    private func loadThePageInTheTabOfThePageItReplaces(_ pageURL: URL, replacingPageURL: URL) -> Bool {
        guard let replacedPageChromeTabID = notionPageChromeTabIDsByPageURL.removeValue(forKey: replacingPageURL),
              videoQuizSession.loadPageInChromeTab(pageURL, tabID: replacedPageChromeTabID) else {
            return false
        }
        notionPageChromeTabIDsByPageURL[pageURL] = replacedPageChromeTabID
        return true
    }

    /// The ending Clicky plays for a finished agent depends on what it made. A revision's page loads in the tab of the
    /// page it replaces, which the Worker trashed, so the learner never has two tabs for one guide.
    private func finishTheBackgroundAgent(_ agentID: UUID, agentKind: BackgroundAgentKind, with result: BackgroundAgentResult, replacingPageURL: URL? = nil) {
        backgroundAgentStore.finish(agentID, with: result)
        switch result {
        case .notionPage(let pageURL):
            // The shown theme picks this done sound ("Tink" for a built-in theme), and a separate correct sound, "Glass" for a
            // built-in theme, for quiz answers.
            themeSettings.shownTheme.sounds.done.play()
            // The page opens behind the video tab. open_study_guide, asked for by voice, brings it forward instead.
            var secondaryChipText = "· say open my study guide"
            if let replacingPageURL, loadThePageInTheTabOfThePageItReplaces(pageURL, replacingPageURL: replacingPageURL) {
                secondaryChipText = "· updated in its tab"
            } else if let openedChromeTabID = videoQuizSession.openInABackgroundChromeTab(pageURL) {
                notionPageChromeTabIDsByPageURL[pageURL] = openedChromeTabID
                secondaryChipText = "· opened in a new tab"
            }
            bringBackTheEndingChip(ofAgent: agentID) { [self] in
                VoiceToolCallChip.shared.show(
                    agentKind.finishedChipText,
                    sender: chipSender(forAgent: agentID, kind: agentKind),
                    secondaryChipText: secondaryChipText,
                    secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
                )
            }
        case .readyScene:
            themeSettings.shownTheme.sounds.done.play()
            let sceneRisesNow = aReadyBackgroundSceneMayRiseNow
            bringBackTheEndingChip(ofAgent: agentID) { [self] in
                VoiceToolCallChip.shared.show(
                    agentKind.finishedChipText,
                    sender: chipSender(forAgent: agentID, kind: agentKind),
                    secondaryChipText: sceneRisesNow ? nil : "· say \(agentKind.waitingPhrase)",
                    secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
                )
            }
            if sceneRisesNow {
                startShowingTheReadyBackgroundScene()
            } else {
                print("\(agentKind.displayName): the screen is busy, so it waits for \"\(agentKind.waitingPhrase)\"")
            }
        case .answer(_, let pageURL):
            themeSettings.shownTheme.sounds.done.play()
            // Like a guide's page, a task's page opens behind the video tab.
            if let pageURL, let openedChromeTabID = videoQuizSession.openInABackgroundChromeTab(pageURL) {
                notionPageChromeTabIDsByPageURL[pageURL] = openedChromeTabID
            }
            bringBackTheEndingChip(ofAgent: agentID) { [self] in
                VoiceToolCallChip.shared.show(
                    agentKind.finishedChipText,
                    sender: chipSender(forAgent: agentID, kind: agentKind),
                    secondaryChipText: "· say what did you find",
                    secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
                )
            }
        }
    }

    /// Shows an agent's ending chip after the spark carries it from the agent's disc to the cursor (Bring back), so the chip shows
    /// where the spark lands. An agent with no disc to leave from shows the chip at once.
    private func bringBackTheEndingChip(ofAgent agentID: UUID, showTheChip: @escaping () -> Void) {
        let agentColor = backgroundAgentStore.agents.first { $0.id == agentID }?.displayColor.color ?? DS.Colors.textSecondary
        // The video the loop or an agent's spark is around, read with no new Apple Event, so the drop comes down beside it.
        agentTokenDockController.bringBack(
            agentID: agentID,
            in: agentColor,
            keepingClearOf: cursorLoopController.mediaScreenRectInAppKitCoordinates,
            showTheChip: showTheChip
        )
    }

    /// Who an ending chip speaks for: the agent's kind, and its player while a team theme is on.
    private func chipSender(forAgent agentID: UUID, kind: BackgroundAgentKind) -> VoiceToolCallChipSender {
        .backgroundAgent(color: backgroundAgentStore.displayColor(for: agentID) ?? kind.preferredPaletteColor, face: backgroundAgentStore.face(for: agentID))
    }

    /// What starts a failed agent's work again, by agent, for the agent list's "Try again". Each returns whether the work
    /// started.
    private var tryAgainActionsByAgentID: [UUID: @MainActor () -> Bool] = [:]

    /// Lets the agent list offer "Try again" if this agent fails. `start` begins the same work as a new agent.
    private func allowTryingAgain(_ agentID: UUID, start: @escaping @MainActor () -> Bool) {
        // An agent the store dropped can never be tried again, so its action goes with it.
        let agentIDsInTheStore = Set(backgroundAgentStore.agents.map(\.id))
        tryAgainActionsByAgentID = tryAgainActionsByAgentID.filter { agentIDsInTheStore.contains($0.key) }
        tryAgainActionsByAgentID[agentID] = start
        backgroundAgentStore.allowTryingAgain(agentID)
    }

    /// Whether a failed agent's work may start again now, by the rules the voice tools that start it keep.
    private func agentMayBeTriedAgainNow(agentKind: BackgroundAgentKind) -> Bool {
        backgroundAgentMayBeTriedAgain(
            agentKind: agentKind,
            aQuizQuestionIsOpen: liveScenePhaseIsWaitingForAQuizAnswer || videoQuizQuestionIsActive,
            experimentRequestStep: currentExperimentRequestStep,
            anExperimentIsOnScreen: simulationIsOnScreen(pageOnScreen: liveScenePageOnScreen, overlayIsShowingAScene: LiveSceneOverlay.shared.isShowingAScene),
            aVideoIsInFront: agentKind == .threeDModel ? videoQuizSession.frontVideoStateForVoiceCommands() != nil : false
        )
    }

    /// "Try again" on a failed agent's row. It starts the same work once, as a new agent with its own row, and the failed
    /// row stops offering it only when the work started.
    private func tryTheBackgroundAgentAgain(_ agentID: UUID) {
        guard let startTheWorkAgain = tryAgainActionsByAgentID[agentID] else { return }
        guard startTheWorkAgain() else {
            print("Agent list: could not try \(agentID) again, so its row keeps the button")
            VoiceToolCallChip.shared.show("Couldn't try that again", sender: .failure)
            return
        }
        tryAgainActionsByAgentID[agentID] = nil
        backgroundAgentStore.markTriedAgain(agentID)
    }

    /// Cancels a running agent from the agent list. A cancelled agent shows no chip, and a cancelled new guide keeps no
    /// record. A cancelled revise or refresh whose reply already arrived is saved (`StudyGuideJob.replyIsSavedEvenWhenCancelled`).
    func cancelBackgroundAgent(_ agentID: UUID) {
        backgroundAgentTasks[agentID]?.cancel()
        backgroundAgentStore.cancel(agentID)
    }

    private func runLearnerVideoCommand(_ learnerVideoCommand: LearnerVideoCommand) -> VoiceToolOutcome {
        do {
            let videoState = try videoQuizSession.runLearnerVideoCommand(learnerVideoCommand)
            return .changed(state: .object(["video": videoState]))
        } catch {
            // The quiz's failure lines say what the learner can fix, such as turning on JavaScript from Apple Events.
            return .failed(error: (error as? LocalizedError)?.errorDescription ?? "No video is in Chrome's front tab", state: nil)
        }
    }

    #if DEBUG
    private func voiceToolsForTheDebugServer() async -> [VoiceToolDescriptor] {
        let pageState = await LiveSceneOverlay.shared.pageVoiceState()
        let debugFrontVideoState = videoQuizSession.frontVideoStateForVoiceCommands()
        let appToolContext = appVoiceToolContext(
            pageState: pageState,
            frontVideoState: debugFrontVideoState,
            studyGuideExistsForTheFrontVideo: await studyGuideExistsForTheFrontVideo(frontVideoState: debugFrontVideoState)
        )
        let appTools = AppVoiceTool.available(in: appToolContext).filter { !$0.needsTheSpokenRequest }
        return voiceToolsOfferedToTheModel(pageTools: await LiveSceneOverlay.shared.pageVoiceTools(), appTools: appTools, skills: TaskAgentSkillCatalog.currentSkills())
    }

    /// Not listed by tools/list, since it is for screenshots and demo takes, not for the model.
    private static let debugSeedAgentsToolName = "debug_seed_agents"
    /// Clicks the menu bar icon, as the learner does, since a status item can sit where no script can find its window.
    private static let debugClickMenuBarIconToolName = "debug_click_menu_bar_icon"

    private func runVoiceToolFromTheDebugServer(toolName: String, toolInput: [String: JSONValue]) async -> VoiceToolOutcome {
        if toolName == Self.debugClickMenuBarIconToolName {
            NotificationCenter.default.post(name: .clickyClickMenuBarIcon, object: nil)
            return .changed(state: nil)
        }
        if toolName == Self.debugSeedAgentsToolName {
            if let kindNames = toolInput["kinds"]?.arrayValue {
                // Running agents of the kinds named, in order, with no finished or failed ones.
                let seededAgentIDs = backgroundAgentStore.seedRunningAgentsForScreenshots(kinds: kindNames.compactMap { kindName in
                    kindName.stringValue.flatMap(BackgroundAgentKind.kindNamedForSeeding)
                })
                // "serveTheToken": true flies the token from the cursor, as a tool-started agent's does. A serve in flight
                // lands at once when the next one starts, so seed one kind per call to see each flight.
                if toolInput["serveTheToken"]?.boolValue == true {
                    for seededAgentID in seededAgentIDs {
                        agentTokenDockController.startServingTheToken(of: seededAgentID)
                    }
                }
                // "waitingForApproval": true puts the seeded agents in the waiting state the approval desk gives them, so their
                // discs show the "!" face, the notch, the pulse, and the peek card's capability line.
                if toolInput["waitingForApproval"]?.boolValue == true {
                    backgroundAgentStore.agentIDsWaitingForApproval.formUnion(seededAgentIDs)
                    for seededAgentID in seededAgentIDs { backgroundAgentStore.approvalCapabilitiesByAgentID[seededAgentID] = .sends }
                }
            } else {
                seedBackgroundAgentsForScreenshots(runningAgentCount: toolInput["runningAgentCount"]?.numberValue.map { Int(min(max($0, 0), 3)) } ?? 3)
            }
            return .changed(state: nil)
        }
        // A tool call from this server is not a spoken request, so no media rect read for an earlier one may draw a loop for it.
        cursorLoopController.end(because: .newPushToTalk)
        let toolCall = VoiceToolCall(id: "debug", name: toolName, input: toolInput)
        let offeredToolNames = Set(await voiceToolsForTheDebugServer().map(\.name))
        showTheVoiceToolCallChip(for: toolCall, at: .beforeTheCall, offeredToolNames: offeredToolNames)
        let outcome = await runVoiceTool(toolCall, offeredToolNames: offeredToolNames, transcript: "")
        showTheVoiceToolCallChip(for: toolCall, at: .afterTheCall(outcome), offeredToolNames: offeredToolNames)
        return outcome
    }

    /// Puts three running agents, one finished with its ending chip, and one failed on screen with no Worker call, so
    /// every token, chip, and agent list state can be captured at once. Running agents fill from the clock and stay up
    /// until cancelled from the list. `runningAgentCount` below 3 leaves room beside the notch for the finished and failed tokens.
    private func seedBackgroundAgentsForScreenshots(runningAgentCount: Int) {
        let finishedAgentID = backgroundAgentStore.seedAgentsForScreenshots(runningAgentCount: runningAgentCount)
        // The seeded task's answer waits to be heard like a real one, so its list row's Hear answer button speaks it.
        holdTheTaskAnswerUntilItIsHeard("Karasuno won 2 sets to 1.", forAgent: finishedAgentID)
        // The agent is new to the dock, which makes its disc on the next turn of the run loop. A real agent has had its disc
        // since it started, so this waits for the disc that Bring back leaves from.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            bringBackTheEndingChip(ofAgent: finishedAgentID) { [self] in
                VoiceToolCallChip.shared.show(
                    BackgroundAgentKind.task.finishedChipText,
                    sender: chipSender(forAgent: finishedAgentID, kind: .task),
                    secondaryChipText: "· say what did you find",
                    secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
                )
            }
        }
    }
    #endif

    /// Like Escape, without cancelling the voice command that asked for it.
    private func closeTheSceneByVoice() {
        liveSceneTourFinishedTask?.cancel()
        if videoQuizQuestionIsActive {
            skipTheVideoQuizQuestion()
            return
        }
        if case .touring = liveScenePhase {
            liveScenePhase = .allLabelsShowing
        }
        clearFinishedLiveScene()
    }

    /// What the model reads about the screen: which page shows, its camera pose and labels, and the video in front.
    /// The harness adds the kind of action a waiting approval request asks for from its own approval gate, so this has no
    /// `approvalWaiting` field.
    private func voiceCommandSceneState(pageState: JSONValue?, frontVideoState: JSONValue?) -> JSONValue {
        var sceneStateFields = pageState?.objectValue ?? [:]
        let pageName: String
        switch liveScenePageOnScreen {
        case _ where !LiveSceneOverlay.shared.isShowingAScene: pageName = "none"
        case .framePopout: pageName = "framePopout"
        case .landmark: pageName = "landmark"
        case .simulation: pageName = "simulation"
        case .generatedPage, nil: pageName = "generated3DScene"
        }
        sceneStateFields["page"] = .string(pageName)
        sceneStateFields["sceneNumber"] = sceneNumberForTheSceneState(
            sceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            scenesPlayedCount: LiveSceneOverlay.shared.scenesPlayedCount
        )
        if let frontVideoState {
            sceneStateFields["video"] = frontVideoState
        }
        sceneStateFields["videoQuizIsRunning"] = .bool(videoQuizSession.isRunning)
        if liveScenePhaseIsWaitingForAQuizAnswer {
            sceneStateFields["quizQuestionIsOpen"] = .bool(true)
        }
        if case .simulation = liveScenePageOnScreen, let simulationLesson {
            sceneStateFields["predictionQuestion"] = .string(simulationLesson.predictionQuestion)
        }
        if replayStopsAreRecordedForTheSceneOnScreen {
            sceneStateFields["replay"] = voiceCommandReplayState(phase: instantReplay.phase, stopCount: instantReplay.stops.count)
        }
        if let themeStudioState = voiceCommandThemeStudioState(themeStudioController.state) {
            sceneStateFields["themeStudio"] = themeStudioState
        }
        if roomArtPreviewController.phase.furnitureGhostShows, let furnitureGhost = roomArtPreviewController.furnitureGhost {
            sceneStateFields["furnitureGhost"] = voiceCommandFurnitureGhostState(furnitureGhost)
        }
        sceneStateFields = sceneStateFieldsAddingBackgroundAgents(
            to: sceneStateFields,
            runningAgentCount: backgroundAgentStore.agents.filter(\.isRunning).count,
            agentsArePaused: backgroundAgentStore.agentsArePaused
        )
        if let readyBackgroundScene {
            sceneStateFields["readyToShow"] = .string(readyToShowStateText(
                isExperiment: readyBackgroundScene.agentKind == .experiment,
                whatToBuild: readyBackgroundScene.whatToBuild
            ))
        }
        return .object(sceneStateFields)
    }

    /// Asked as each call starts and again once it has run. A learner sees the call in plain words, at the moment
    /// `chipPhraseToShow(at:offeredToolNames:)` picks. With the debug switch on, a Debug build shows every call as code as it starts, refused ones too.
    private func showTheVoiceToolCallChip(for toolCall: VoiceToolCall, at chipMoment: VoiceToolChipMoment, offeredToolNames: Set<String>) {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: Self.logsVoiceToolCallJSONDefaultsKey) {
            if case .beforeTheCall = chipMoment {
                VoiceToolCallChip.shared.show(toolCall.chipText, chipTextIsCode: true)
            }
            return
        }
        #endif
        guard let chipPhrase = toolCall.chipPhraseToShow(at: chipMoment, offeredToolNames: offeredToolNames) else { return }
        VoiceToolCallChip.shared.show(chipPhrase)
    }

    /// The debug setting in the panel prints the full JSON of every voice command reply and tool result.
    private func logVoiceCommandJSONIfEnabled(_ what: String, _ jsonValues: [JSONValue]) {
        #if DEBUG
        guard UserDefaults.standard.bool(forKey: Self.logsVoiceToolCallJSONDefaultsKey) else { return }
        print("Voice command JSON \(what): \(JSONValue.array(jsonValues).compactJSONText)")
        #endif
    }

    static let logsVoiceToolCallJSONDefaultsKey = "logsVoiceToolCallJSON"

    /// The tour can finish while Claude is still thinking, and isPlaying is
    /// false until the voice answer actually starts. Wait through that, and
    /// through playback, so the quiz is the next thing Clicky says.
    private func waitUntilTheVoiceAnswerIsQuiet() async {
        while !Task.isCancelled {
            if !voiceAnswerIsStillRunning {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private var voiceAnswerIsStillRunning: Bool {
        voiceState == .processing
            || voiceState == .listening
            || elevenLabsTTSClient.isPlaying
    }

    /// Waits for the line in progress, because a new line would cut it off.
    /// Leaves voiceState alone so the cursor keeps showing that the build is running.
    private func speakLiveSceneStatus(_ status: String) async {
        await waitForClickyToFinishSpeaking()
        guard !Task.isCancelled else { return }
        do {
            try await speakTextEndingAnOpenReplay(status)
            print("Live scene status spoken: \(status)")
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Live scene status line failed: \(error.localizedDescription)")
        }
    }

    /// Every line Clicky says goes through here or through `playLineEndingAnOpenReplay`. A replay is silent, so a line
    /// starting means another answer, and an open replay ends first, so it never moves the camera or the cursor under that
    /// answer, whichever surface started it.
    @discardableResult
    private func speakTextEndingAnOpenReplay(_ text: String) async throws -> SpokenLineToken {
        instantReplay.endForAnotherAnswer()
        return try await elevenLabsTTSClient.speakText(text)
    }

    /// `speakTextEndingAnOpenReplay` for a line whose audio was fetched ahead, such as a voice command's line.
    private func playLineEndingAnOpenReplay(_ lineFetch: SpokenLineFetch) async throws -> SpokenLineToken {
        instantReplay.endForAnotherAnswer()
        return try await elevenLabsTTSClient.play(lineFetch)
    }

    /// How far through `text` Clicky's voice is, from 0 to 1, or nil when Clicky is not speaking that line.
    /// The speech Callout brightens its words along with it.
    func spokenFractionOfTheLine(_ text: String) -> Double? {
        elevenLabsTTSClient.spokenFraction(ofLine: text)
    }

    /// Says that a command did not work, with the red failure chip above the cursor, so the failure never rests on the voice alone.
    @discardableResult
    private func speakTheGaveUpLine() async -> Bool {
        VoiceToolCallChip.shared.show("Couldn't do that one", sender: .failure)
        return await speakLiveSceneLine(voiceCommandGaveUpLine, isAFailure: true)
    }

    /// Returns true once the line's own audio has started, and false on a cancel or when the credits fallback plays instead.
    /// `isAFailure` says the line reports something that went wrong, so the cursor shakes as Clicky says it. The caller says
    /// so, since a failure line can start with any words ("I couldn't find a YouTube video open in Chrome.").
    @discardableResult
    private func speakLiveSceneLine(_ line: String, isAFailure: Bool) async -> Bool {
        await speakLiveSceneLineAndReturnItsToken(line, isAFailure: isAFailure) != nil
    }

    /// `speakLiveSceneLine` for a line whose audio may already be fetching, such as a voice command's line fetched while its
    /// calls ran.
    private func speakLiveSceneLine(_ lineFetch: SpokenLineFetch) async -> Bool {
        await speakTheFetchedLineAndReturnItsToken(lineFetch, isAFailure: false) != nil
    }

    /// Like `speakLiveSceneLine`, but returns the token of the line once its own audio has started, for a caller that must
    /// stop that exact line later. Nil on a cancel or when the credits fallback plays instead.
    private func speakLiveSceneLineAndReturnItsToken(_ line: String, isAFailure: Bool) async -> SpokenLineToken? {
        await speakTheFetchedLineAndReturnItsToken(elevenLabsTTSClient.startFetching(line), isAFailure: isAFailure)
    }

    private func speakTheFetchedLineAndReturnItsToken(_ lineFetch: SpokenLineFetch, isAFailure: Bool) async -> SpokenLineToken? {
        if isAFailure { playCursorEmote(.shake) }
        do {
            let lineToken = try await playLineEndingAnOpenReplay(lineFetch)
            voiceState = .responding
            return lineToken
        } catch is CancellationError {
            return nil
        } catch {
            print("⚠️ ElevenLabs TTS error: \(error)")
            speakCreditsErrorFallback()
            return nil
        }
    }

    // MARK: - Bundled Page Narration

    /// Says a few sentences about a frame pop-out, one part each, highlighting that part and pointing the
    /// blue cursor at it as it is named. The Claude call starts right away and the speech waits for the tour,
    /// so it is ready when the camera stops. The labels come from the pop-out's own parts list, because the
    /// page may not have loaded yet. An animated picture lifts out with no labels, so its sentences name no part
    /// and the cursor points at nothing.
    private func narrateTheFramePopout(_ framePopout: VideoFramePopout, narrationTrigger: LiveSceneNarrationTrigger) async {
        let narrationID = UUID()
        // Each part the cursor pointed at becomes an instant replay stop, offered once the narration ends, a cut-off one
        // included, and only while the same scene is still on screen.
        let sceneNumberOfThisNarration = LiveSceneOverlay.shared.scenesPlayedCount
        var recordedReplayStops: [ReplayStop] = []
        // A replay must not move the camera or the cursor over a narration, so an open one ends and the control hides now.
        let replayNarrationNumber = instantReplay.narrationStarted()
        // Every exit, a cancelled one too, sends the buddy back to the mouse if it still points for this narration.
        defer {
            releaseTheBuddyFromTheLiveScenePart(pointedByNarrationID: narrationID)
            instantReplay.narrationEnded(
                narrationNumber: replayNarrationNumber,
                recordedStops: recordedReplayStops,
                sceneNumber: sceneNumberOfThisNarration,
                sceneIsStillOnScreen: LiveSceneOverlay.shared.isShowingAScene && LiveSceneOverlay.shared.scenesPlayedCount == sceneNumberOfThisNarration
            )
        }
        let knownPartLabels = framePopout.parts.map(\.label)
        var sourceImagesForNarration: [(data: Data, label: String)] = []
        if let sourceImageJPEGData = Data(base64Encoded: framePopout.frameGrab.jpeg) {
            sourceImagesForNarration.append((data: sourceImageJPEGData, label: framePopout.frameGrab.source.narrationImageLabel))
        }
        let narrationText: String
        do {
            narrationText = try await claudeAPI.analyzeImageStreaming(
                images: sourceImagesForNarration,
                systemPrompt: liveSceneNarrationSystemPrompt(for: framePopout.frameGrab.source, isArtwork: framePopout.isArtwork, hasPartLabels: !knownPartLabels.isEmpty),
                userPrompt: liveSceneNarrationUserPrompt(for: narrationTrigger, knownPartLabels: knownPartLabels, isArtwork: framePopout.isArtwork),
                onTextChunk: { _ in }
            ).text
        } catch {
            print("Frame pop-out narration failed: \(error)")
            return
        }
        await waitForTheLiveSceneTourToFinish()
        guard !Task.isCancelled, case .allLabelsShowing = liveScenePhase else { return }
        let spokenParts = liveSceneSpokenParts(from: narrationText)
        print("Frame pop-out narration: \(spokenParts.count) sentences for \(narrationTrigger)")
        for spokenPart in spokenParts {
            guard !Task.isCancelled else { return }
            if let replayStop = await speakLiveSceneNarrationSentence(
                spokenPart.spokenText,
                aboutPartLabel: knownPartLabel(matching: spokenPart.partLabel, knownPartLabels: knownPartLabels),
                narrationID: narrationID
            ) {
                recordedReplayStops = replayStops(recordedReplayStops, adding: replayStop)
            }
        }
        guard !Task.isCancelled else { return }
        LiveSceneOverlay.shared.highlightPart(labelText: "")
    }

    /// A click on a label after the tour is taken as "what does the <label> do?" and answered through the
    /// same narration. The page's label text is only used to look up the label in Clicky's own parts list.
    private func explainTheTappedPart(untrustedTappedLabel: String) {
        // The explanation and video resume of a quiz question are still running, and a tap must not cancel them.
        guard !videoQuizQuestionIsActive,
              let partLabel = partLabelToExplain(
                  untrustedTappedLabel: untrustedTappedLabel,
                  pageOnScreen: liveScenePageOnScreen,
                  liveScenePhase: liveScenePhase
              ),
              case .framePopout(let framePopout) = liveScenePageOnScreen else {
            print("Frame pop-out: ignored a label tap")
            return
        }
        print("Frame pop-out: explaining the tapped \(partLabel) label")
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        showTheCursorOverlayForThisInteraction()
        // A new explanation replaces the replay's stops, so a replay still open ends first.
        instantReplay.endIfOpen()
        // The mouse is on the clicked label, so the buddy flies back there while Claude writes the answer.
        if detectedElementPointingHold.holdsUntilReleased {
            clearDetectedElementLocation()
        }
        // The camera starts toward the part right away, while Claude writes the answer.
        LiveSceneOverlay.shared.highlightPart(labelText: partLabel)
        voiceState = .processing
        currentResponseTask = Task {
            await self.narrateTheFramePopout(framePopout, narrationTrigger: .partTapped(label: partLabel))
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// A nil part label means the sentence names no part on the model, so nothing is highlighted or pointed at.
    /// Returns the instant replay stop of a sentence whose part the cursor pointed at, with the camera pose then.
    private func speakLiveSceneNarrationSentence(_ spokenText: String, aboutPartLabel partLabel: String?, narrationID: UUID) async -> ReplayStop? {
        guard let partLabel else {
            await speakLiveSceneLine(spokenText, isAFailure: false)
            // The buddy stays on the last part it pointed at, and its bubble follows what Clicky says now.
            if !Task.isCancelled, detectedElementPointingHold == .untilReleased(byNarrationID: narrationID) {
                detectedElementBubbleText = spokenText
            }
            await waitForClickyToFinishSpeaking()
            return nil
        }
        LiveSceneOverlay.shared.highlightPart(labelText: partLabel)
        // The label's place and the camera's pose are read once the camera stops gliding to the part, while the sentence starts playing.
        let settledLabelScreenPointsTask = Task {
            let settledLabelScreenPoints = await LiveSceneOverlay.shared.partLabelScreenPointsOnceTheCameraSettles()
            return (settledLabelScreenPoints, await LiveSceneOverlay.shared.cameraPoseForTheReplay())
        }
        await speakLiveSceneLine(spokenText, isAFailure: false)
        let (settledLabelScreenPoints, settledCameraPose) = await settledLabelScreenPointsTask.value
        var replayStop: ReplayStop?
        if !Task.isCancelled,
           let partScreenPoint = settledLabelScreenPoints.first(where: { labelScreenPoint in labelScreenPoint.label == partLabel }) {
            pointTheBuddy(atLiveScenePart: partScreenPoint, bubbleText: spokenText, narrationID: narrationID)
            replayStop = ReplayStop(partLabel: partLabel, sentence: spokenText, cameraPose: settledCameraPose)
        }
        await waitForClickyToFinishSpeaking()
        return replayStop
    }

    // MARK: - Scrub by voice

    /// Flies the cursor to the video's progress bar, slides it to the moment, and returns as it arrives, so the seek runs
    /// then. With no line to slide along, it returns at once and the seek runs as before.
    private func scrubTheCursorAlongTheProgressBar(of videoTab: ChromeVideoTab, toSeconds targetSeconds: Double) async {
        let scrubConditions = CursorScrubConditions(
            chromeIsTheFrontApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.google.Chrome",
            cursorIsPointing: detectedElementScreenLocation != nil,
            sceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            commandWasCancelled: Task.isCancelled
        )
        guard let scrubLine = scrubLineToPlay(scrubConditions, readTheLine: { ChromeVideoTab.scrubLineOfTheVideo(in: videoTab) }) else {
            print("Scrub by voice: no line to slide along (\(scrubConditions)), so the video seeks at once")
            return
        }
        showTheCursorOverlayForThisInteraction()
        let startPoint = scrubLine.point(atSeconds: scrubLine.currentSeconds)
        let momentPoint = scrubLine.point(atSeconds: targetSeconds)
        let mouseLocation = NSEvent.mouseLocation
        // The flight and the slide each take the Point move's time for their distance, and a second more covers a busy main actor.
        let pointMoveCurve = DS.Move.point.curve
        let timeoutSeconds = pointMoveCurve.seconds(travelingPoints: hypot(startPoint.x - mouseLocation.x, startPoint.y - mouseLocation.y))
            + pointMoveCurve.seconds(travelingPoints: abs(momentPoint.x - startPoint.x))
            + 1
        let scrubOutcome = await cursorScrubController.scrubBeforeTheSeek(
            along: scrubLine,
            toSeconds: targetSeconds,
            displayFrames: NSScreen.screens.map(\.frame),
            timeoutSeconds: timeoutSeconds
        )
        // The voice command schedules the transient hide when it ends, which waits for the scrub's flight back.
        print("Scrub by voice: \(scrubOutcome) from \(Int(scrubLine.currentSeconds)) s to \(Int(targetSeconds)) s along \(scrubLine.followsTheProgressBar ? "the progress bar" : "the video's bottom edge")")
    }

    // MARK: - Instant replay

    private var replayStopsAreRecordedForTheSceneOnScreen: Bool {
        LiveSceneOverlay.shared.isShowingAScene && instantReplay.stopsAreRecorded(forSceneNumber: LiveSceneOverlay.shared.scenesPlayedCount)
    }

    /// The replay points the buddy with its own hold. A point equal to the one the buddy already has would not reach the
    /// overlay's onChange, so it moves by a hundredth of a point, which a frozen buddy needs to fly again.
    /// Returns how long the cursor's flight to the part takes: from the point the cursor points at, such as the stop before
    /// or the narration's last part, or else from the mouse, where the cursor follows it.
    private func pointTheBuddyForTheReplay(at labelScreenPoint: LiveScenePartScreenPoint, sentence: String) -> TimeInterval {
        let mouseLocation = NSEvent.mouseLocation
        let flightSeconds = replayCursorFlightSeconds(
            from: detectedElementScreenLocation ?? CGPoint(x: mouseLocation.x + StatusLabelPlacement.trianglesSpotFromTheMouse.x, y: mouseLocation.y + StatusLabelPlacement.trianglesSpotFromTheMouse.y),
            to: labelScreenPoint.globalPoint
        )
        showTheCursorOverlayForThisInteraction()
        var pointToFlyTo = labelScreenPoint.globalPoint
        if detectedElementScreenLocation == pointToFlyTo { pointToFlyTo.x += 0.01 }
        pointTheBuddy(
            atLiveScenePart: LiveScenePartScreenPoint(label: labelScreenPoint.label, globalPoint: pointToFlyTo),
            bubbleText: sentence,
            narrationID: instantReplayPointingID
        )
        return flightSeconds
    }

    /// The overlay calls this once the mouse moved away from a buddy the replay stopped, so it flies back to the mouse.
    func releaseTheBuddyTheReplayFroze() {
        releaseTheBuddyFromTheLiveScenePart(pointedByNarrationID: instantReplayPointingID)
        // A replay showed the overlay for its pointing, so with Show Clicky off it fades once the cursor is back.
        scheduleTransientHideIfNeeded()
    }

    /// A click on the replay control takes over from an answer Clicky is still giving about the scene, as a press does.
    private func stopWhatClickyIsSayingForTheReplayControl() {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        if voiceState == .responding || voiceState == .processing {
            voiceState = .idle
        }
    }

    private func showTheInstantReplayControl(controlVersion: Int) {
        Task {
            // The media read waits on the page, and a narration that started meanwhile hid the control, so a stale show draws nothing.
            guard let mediaRectOnScreen = await LiveSceneOverlay.shared.mediaRectOnScreen(),
                  self.instantReplay.controlShowIsStillWanted(controlVersion: controlVersion),
                  self.replayStopsAreRecordedForTheSceneOnScreen,
                  let visibleFrame = NSScreen.screens.first(where: { screen in screen.frame.intersects(mediaRectOnScreen) })?.visibleFrame else {
                return
            }
            self.instantReplayPanelController.show(
                for: self.instantReplay,
                stopWhatClickyIsSaying: { [weak self] in self?.stopWhatClickyIsSayingForTheReplayControl() },
                accentHex: self.themeSettings.shownTheme.cursorColorHex,
                mediaRectOnScreen: mediaRectOnScreen,
                visibleFrame: visibleFrame
            )
        }
    }

    /// The buddy flies on its usual arc to the part, the point where its label's leader line ends on the model, and
    /// stays until the narration that pointed it releases it. Its bubble shows the sentence Clicky is speaking, since
    /// the label already names the part.
    private func pointTheBuddy(atLiveScenePart partScreenPoint: LiveScenePartScreenPoint, bubbleText: String, narrationID: UUID) {
        guard let displayFrame = NSScreen.screens.first(where: { screen in
            screen.frame.contains(partScreenPoint.globalPoint)
        })?.frame else { return }
        detectedElementPointingHold = .untilReleased(byNarrationID: narrationID)
        detectedElementBubbleText = bubbleText
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = partScreenPoint.globalPoint
    }

    /// The blue cursor flies to the part the quiz's "?" label points at and its speech Callout shows the question, brightening its words along with the voice, so a
    /// learner can read a long question again while answering. It stays until the question is answered, or the scene
    /// clears, which releases any held pointing.
    private func pointTheBuddyAtTheQuizQuestion(_ quiz: LiveSceneQuiz, labelScreenPoints: [LiveScenePartScreenPoint]) {
        var quizAnswerPartLabel: String?
        if case .framePopout(let framePopoutOnScreen) = liveScenePageOnScreen {
            quizAnswerPartLabel = framePopoutOnScreen.parts.first(where: \.isQuizAnswer)?.label
        }
        guard !Task.isCancelled, case .awaitingAnswer = liveScenePhase,
              let questionLabelScreenPoint = quizQuestionLabelScreenPoint(
                in: labelScreenPoints,
                quizAnswerPartLabel: quizAnswerPartLabel,
                answerLabel: quiz.answerLabel
              ) else {
            return
        }
        let questionPointingID = UUID()
        quizQuestionPointingID = questionPointingID
        pointTheBuddy(atLiveScenePart: questionLabelScreenPoint, bubbleText: quiz.question, narrationID: questionPointingID)
    }

    private func releaseTheBuddyFromTheQuizQuestion() {
        guard let quizQuestionPointingID else { return }
        releaseTheBuddyFromTheLiveScenePart(pointedByNarrationID: quizQuestionPointingID)
        self.quizQuestionPointingID = nil
    }

    /// Only the narration that pointed the buddy releases it, so an older narration that finishes
    /// late cannot send the buddy away from a newer one's part.
    private func releaseTheBuddyFromTheLiveScenePart(pointedByNarrationID narrationID: UUID) {
        guard detectedElementPointingHold == .untilReleased(byNarrationID: narrationID) else { return }
        clearDetectedElementLocation()
    }

    /// The name and height come from the /landmark reply, so this line needs no model call.
    private func speakTheLandmarkLineAfterItsTour(_ famousPlace: FamousPlace) async {
        await waitForTheLiveSceneTourToFinish()
        guard !Task.isCancelled, case .allLabelsShowing = liveScenePhase else { return }
        let landmarkLine = landmarkNarrationLine(for: famousPlace)
        print("Landmark: saying \"\(landmarkLine)\"")
        await speakLiveSceneLine(landmarkLine, isAFailure: false)
        await waitForClickyToFinishSpeaking()
    }

    private func waitForTheLiveSceneTourToFinish() async {
        while case .touring = liveScenePhase, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while elevenLabsTTSClient.isPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor), and for a scrub's flight back
            while detectedElementScreenLocation != nil || cursorScrubController.request != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when a voice
    /// or reply request fails. Uses NSSpeechSynthesizer so it works even when
    /// ElevenLabs is down.
    private func speakCreditsErrorFallback() {
        playCursorEmote(.shake)
        let utterance = "Sorry, I lost my voice for a second. Please try that again."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed - this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately - the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. normal sentence case, with names capitalized.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
