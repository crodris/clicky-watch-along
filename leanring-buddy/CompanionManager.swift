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
import PostHog
import ScreenCaptureKit
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
    private static let workerBaseURL = "http://127.0.0.1:8787"
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

    private lazy var voiceCommandClient = VoiceCommandClient(workerBaseURL: Self.workerBaseURL)
    private lazy var studyGuideClient = StudyGuideClient(workerBaseURL: Self.workerBaseURL)
    /// The Notion page and guide JSON written for each video, filed under the video's URL when its guide was started,
    /// so a revise or an open finds it later.
    private let savedStudyGuides = SavedStudyGuides(userDefaults: .standard)
    /// The hold that keeps the blue cursor on a quiz question's "?" label, so only the end of that question releases it.
    private var quizQuestionPointingID: UUID?
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
    private lazy var agentHarness = AgentHarness(workerBaseURL: Self.workerBaseURL)
    /// What the newest finished task agent found. It is read aloud only when the learner asks, so it never talks over
    /// the video, and it stays so they can ask again.
    private var readyTaskAnswer: String?
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
    /// The Haikyu!! team theme the learner picked in the menu bar panel, the one source of truth for it.
    let themeSettings = CompanionThemeSettings()
    /// The loop around the video or image a request looks at, which the cursor overlay draws.
    let cursorLoopController = CursorLoopController()
    /// What Clicky works on in the background, shown as wingmen beside the cursor and in the agent list.
    private(set) lazy var backgroundAgentStore = BackgroundAgentStore(themeSettings: themeSettings)
    private lazy var agentListPanelController = AgentListPanelController(
        store: backgroundAgentStore,
        themeSettings: themeSettings,
        cancelAgent: { [weak self] agentID in self?.cancelBackgroundAgent(agentID) }
    )
    private static let backgroundAgentChipSecondsOnScreen: TimeInterval = 4
    /// The last few tool calls, so the model can read "no, the other way" against what Clicky just did.
    private var recentVoiceToolActionLines: [String] = []

    #if DEBUG
    private lazy var voiceToolDebugServer = VoiceToolDebugServer(
        listTools: { [weak self] in
            await self?.voiceToolsForTheDebugServer() ?? []
        },
        callTool: { [weak self] toolName, toolInput in
            await self?.runVoiceToolFromTheDebugServer(toolName: toolName, toolInput: toolInput)
                ?? .failed(error: "Clicky is shutting down", state: nil)
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
        speakLine: { [weak self] line in
            self?.speakVideoQuizLine(line)
        }
    )
    /// True from the moment a video quiz question is asked until its explanation
    /// has been spoken and the video has been resumed.
    private var videoQuizQuestionIsActive = false

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var escapeKeyCancellable: AnyCancellable?
    private var agentListShortcutCancellable: AnyCancellable?
    private var pinchCancellable: AnyCancellable?
    private var scrollWheelCancellable: AnyCancellable?
    private var cursorLoopVoiceStateCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
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

    /// Always true in this fork, so the email step never appears and no
    /// address goes to the upstream signup form.
    @Published var hasSubmittedEmail: Bool = true

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        LiveSceneOverlay.shared.mapTilesWorkerBaseURL = Self.workerBaseURL
        VoiceToolCallChip.shared.avatarWingmenAreShowing = { [weak self] in
            self?.backgroundAgentStore.agents.contains { $0.player != nil && $0.isShownAsAWingman(at: Date()) } ?? false
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
        }
        LiveSceneOverlay.shared.onPartTapped = { [weak self] untrustedTappedLabel in
            self?.explainTheTappedPart(untrustedTappedLabel: untrustedTappedLabel)
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
        bindPinchToLiveSceneZoom()
        bindEscapeToCloseLiveScene()
        bindShiftOptionHoldToTheAgentList()
        bindTheCursorLoopToVoiceStateAndScrolling()
        // Eagerly touch the Claude API so its TLS warmup handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        _ = claudeAPI

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
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
        agentListShortcutCancellable?.cancel()
        agentListPanelController.close()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

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

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
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
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
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
                // Don't override .responding — the AI response pipeline
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
                    // saying anything, no response task runs — schedule the
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

    /// Holding shift + option opens the agent list, and holding them again closes it.
    private func bindShiftOptionHoldToTheAgentList() {
        agentListShortcutCancellable = globalPushToTalkShortcutMonitor
            .agentListShortcutPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.agentListPanelController.toggle()
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

            // A new press starts a new request, so the label from the last build is out of date, and so is its loop.
            LiveSceneStatusLabel.shared.hide()
            cursorLoopController.pushToTalkWasPressed()

            showTheCursorOverlayForThisInteraction()

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()
            // A cancelled narration or scene line returns without leaving the responding state, and the
            // dictation binding never replaces responding, so the listening waveform would not show.
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
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            // The media rect is read beside the router call. It draws a loop only if the request becomes a look at it.
            cursorLoopController.pushToTalkWasReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
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
    func runLiveSceneRehearsal(transcripts: [String]) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for rehearsalStepWithWait in transcripts {
            let (waitSeconds, rehearsalStep) = rehearsalStepWait(rehearsalStepWithWait)
            if waitSeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
            }
            let nextStepInterruptsThisOne = rehearsalStep.hasPrefix("~")
            // "?" waits up to 4 minutes for a video quiz question, since a pause comes whenever the video reaches it.
            let stepWaitsForAQuestion = rehearsalStep.hasPrefix("?")
            let stepWaitsForTheBackgroundAgents = rehearsalStep.hasPrefix("&")
            var transcript = nextStepInterruptsThisOne || stepWaitsForAQuestion || stepWaitsForTheBackgroundAgents
                ? String(rehearsalStep.dropFirst())
                : rehearsalStep
            if stepWaitsForTheBackgroundAgents {
                // A guide takes about 15 seconds and a task agent about 25, so 3 minutes covers a long task and the Worker's retries.
                for _ in 0..<720 where !backgroundAgentTasks.isEmpty || studyGuideRefreshesBeingChecked > 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                await waitForTheLatestResponseTaskToFinish()
                await waitForTheTourAndSpeechToEnd()
                // The finish chip and the wingman's hop play for a few seconds before the learner speaks again.
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
            // The same goes for the loop: a press ends the last request's, and the release starts the media rect read.
            cursorLoopController.pushToTalkWasPressed()
            cursorLoopController.pushToTalkWasReleased()
            sendTranscriptToClaudeWithScreenshot(transcript: transcript)
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
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        if let videoQuizCommand = videoQuizVoiceCommand(for: transcript) {
            handleVideoQuizVoiceCommand(videoQuizCommand)
            return
        }

        // "Put it back" has its own tested phrase match, which keeps "put it back together" for the router.
        if asksToPutTheSceneBack(transcript), liveSceneIsUpWithNoQuizQuestion {
            respondToTranscript(transcript: transcript, requestedSceneKind: nil)
            return
        }
        // "Animate this" has no voice tool, so its keyword path animates the pop-out on screen or pops one out.
        if liveSceneKind(for: transcript) == .animatedFramePopout {
            theRequestBecameALookAtTheMedia()
            respondToTranscript(transcript: transcript, requestedSceneKind: .animatedFramePopout)
            return
        }

        // "Let me try it" always starts an experiment agent, with no model call to choose it, so a demo never depends on the router.
        // Once a scene is on screen the same words may mean a slider ("can I try 60 degrees"), which the router reads.
        if liveSceneKind(for: transcript) == .simulation,
           !LiveSceneOverlay.shared.isShowingAScene,
           !liveScenePhaseIsWaitingForAQuizAnswer {
            startTheExperimentInTheBackground(transcript: transcript)
            return
        }

        let phaseIsWaitingForAQuizAnswer = liveScenePhaseIsWaitingForAQuizAnswer
        var sceneIsBuilding = false
        if case .buildingScene = liveScenePhase { sceneIsBuilding = true }
        // Read once here and handed to the router, because each read is a round trip to Chrome.
        let frontVideoState = phaseIsWaitingForAQuizAnswer || sceneIsBuilding ? nil : videoQuizSession.frontVideoStateForVoiceCommands()
        let routerTakesTheTranscript = voiceCommandRouterTakesTheTranscript(
            sceneIsOnScreen: LiveSceneOverlay.shared.isShowingAScene,
            videoIsInFront: frontVideoState != nil,
            backgroundSceneIsReady: readyBackgroundScene != nil,
            taskAnswerIsReady: taskAnswerWaitsToBeHeard,
            phaseIsWaitingForAQuizAnswer: phaseIsWaitingForAQuizAnswer,
            sceneIsBuilding: sceneIsBuilding
        )
        if routerTakesTheTranscript {
            startVoiceCommand(transcript: transcript, frontVideoState: frontVideoState)
            return
        }
        respondByTheKeywordPath(transcript: transcript)
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
        guard !LiveSceneOverlay.shared.isShowingAScene,
              !liveScenePhaseIsWaitingForAQuizAnswer,
              !videoQuizQuestionIsActive else {
            return
        }
        cursorLoopController.requestBecameALookAtTheMedia()
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
            // Stay in processing (spinner) state — no streaming text displayed
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
                        // No streaming text display — spinner stays until TTS plays
                    }
                )

                guard !Task.isCancelled else { return }

                // Parse the [POINT:...] tag from Claude's response
                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
                let spokenText = parseResult.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
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
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
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

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Play the response via TTS. Keep the spinner (processing state)
                // until the audio actually starts playing, then switch to responding.
                if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    do {
                        try await elevenLabsTTSClient.speakText(spokenText)
                        // speakText returns once the first streamed audio is playing, so the voice state can switch now
                        voiceState = .responding
                    } catch is CancellationError {
                        // The learner spoke again, so this reply was interrupted on purpose.
                    } catch {
                        ClickyAnalytics.trackTTSError(error: error.localizedDescription)
                        print("⚠️ ElevenLabs TTS error: \(error)")
                        speakCreditsErrorFallback()
                    }
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
            } catch {
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
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
        await speakLiveSceneLine("Sure, let me pop that out.")
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
              let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen, theme: themeSettings.theme),
              LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: false, isFramePopout: true, overlayScreen: overlayScreen) else {
            liveScenePhase = .idle
            await speakLiveSceneLine(failureLine)
            voiceState = .idle
            // No scene opened, so nothing will clear it and resume the video.
            // A previous pop-out cleared for this request may still be landing back in its frame.
            await LiveSceneOverlay.shared.waitForReturnToFinish()
            if videoQuizSession.videoIsPausedForRequestedScene {
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
        // Idle during the tour so the triangle shows, while the narration is written in the background.
        voiceState = .idle
        await narrateTheFramePopout(framePopout, narrationTrigger: .afterTour)
        guard !Task.isCancelled else { return }
        // A missing animation is said after the narration, so the two never talk over each other.
        let pictureFlowsOutcome = await pictureFlowsTask?.value
        // A tap while waiting cancels this task, and a line spoken now would cut off the tap's own narration.
        guard !Task.isCancelled else { return }
        if let spokenLine = pictureFlowsOutcome?.spokenLineWhenNotShowing {
            await speakLiveSceneLine(spokenLine)
        }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func animateTheFramePopoutOnScreen(_ framePopout: VideoFramePopout, requestGeneration: Int) async {
        // An artwork is refused before any "animating" status or line, so Clicky never promises what it won't do.
        guard !framePopout.isArtwork else {
            print("Frame pop-out: leaving the artwork as the artist made it")
            if let artworkLine = PictureFlowsOutcome.leftTheArtworkAlone.spokenLineWhenNotShowing {
                await speakLiveSceneLine(artworkLine)
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
        await speakLiveSceneLine("Sure, let me animate that.")
        // A fast "nothing flows" reply would otherwise cut this line off, since a new line stops the one playing.
        await waitForClickyToFinishSpeaking()
        guard !Task.isCancelled else { return }
        voiceState = .processing
        let pictureFlowsOutcome = await pictureFlowsTask.value
        guard !Task.isCancelled else { return }
        LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.popOutLines)
        voiceState = .idle
        if let spokenLine = pictureFlowsOutcome.spokenLineWhenNotShowing {
            await speakLiveSceneLine(spokenLine)
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
        await speakLiveSceneLine("Sure, let me build that for you.")
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
                await speakLiveSceneLine(spokenPart.spokenText)
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
                    NSSound(named: NSSound.Name("Glass"))?.play()
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
        await speakLiveSceneLine(challengePromptLine)
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
        let lineAudioStarted = await speakLiveSceneLine(line)
        await waitForClickyToFinishSpeaking()
        return lineAudioStarted && !Task.isCancelled
    }

    /// Every clear goes through here. A narration holds the buddy on a part until it releases it, and a
    /// cancelled narration can stay stuck reading label places from a page that is gone, so the clear releases it.
    /// The page's record and an experiment's lesson end here too, so the voice router never reads a question of a scene that is gone.
    func clearTheLiveSceneAndReleaseTheBuddy() {
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
            await self.speakLiveSceneLine("Okay, back to the video.")
            await self.waitForClickyToFinishSpeaking()
            // Speaking the line set the voice state to responding, and a quiz asks its next question only when idle.
            if self.voiceState == .responding {
                self.voiceState = .idle
                self.scheduleTransientHideIfNeeded()
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            // A frame pop-out lands back in the paused frame before the video moves.
            await LiveSceneOverlay.shared.waitForReturnToFinish()
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
                sceneKind: sceneKind
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
        await speakLiveSceneLine(spokenLine)
        await resumeVideoQuizAfterExplanation()
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// The first wrong answer keeps the model's sentence, which does not give the answer away.
    /// A second wrong answer uses the closing line, so the learner hears what the part does.
    private func applyJudgedLiveSceneAnswer(
        grade: LiveSceneQuizGrade,
        judgeSpokenReply: String,
        quiz: LiveSceneQuiz,
        wrongAnswerCount: Int
    ) -> String {
        let revealOutcome = LiveSceneRevealOutcome(grade: grade, wrongAnswerCount: wrongAnswerCount)
        LiveSceneOverlay.shared.revealQuizLabel(outcome: revealOutcome)
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
                return judgeSpokenReply
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
            LiveSceneOverlay.shared.revealQuizLabel(outcome: .revealWithoutCelebration)
            await speakLiveSceneLine(spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false))
        case .repeatQuestion:
            await speakLiveSceneLine(quiz.question)
        case .giveHint:
            // The camera turns to the part still labeled "?", which is the hint the eyes get.
            LiveSceneOverlay.shared.highlightPart(labelText: quiz.answerLabel)
            await speakLiveSceneLine(judgeSpokenReply.isEmpty ? "Here's a hint: look at the part that's glowing." : judgeSpokenReply)
        case .sceneCommand:
            startVoiceCommand(transcript: transcript, frontVideoState: videoQuizSession.frontVideoStateForVoiceCommands())
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
        await speakLiveSceneLine(spokenLine)
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
            videoQuizSession.start()
            spokenLine = "Sure, let me read through this video."
        case .stop:
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
                if aSceneWasBuilding {
                    self.videoQuizSession.resumeVideoAfterRequestedScene()
                }
            }
            spokenLine = "Okay, I'll stop quizzing."
        }

        currentResponseTask = Task {
            await self.speakLiveSceneLine(spokenLine)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// Speaks a line from the video quiz after whatever Clicky is already saying,
    /// so a quick failure does not cut off "Let me read through this video."
    private func speakVideoQuizLine(_ line: String) {
        let previousSpokenLineTask = currentResponseTask
        currentResponseTask = Task {
            await previousSpokenLineTask?.value
            await self.waitUntilTheVoiceAnswerIsQuiet()
            guard !Task.isCancelled else { return }
            await self.speakLiveSceneLine(line)
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
           let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen, theme: themeSettings.theme),
           LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: true, isFramePopout: true, overlayScreen: overlayScreen) {
            print("Video quiz: lifting the subject out of the frame with \(framePopout.parts.count) labels\(framePopout.pictureShowsDepth ? " as a flat card" : "")")
            liveScenePhase = .touring(quizToAskAfterTour: quiz)
            liveScenePageOnScreen = .framePopout(framePopout)
            return
        }
        liveScenePhase = .awaitingAnswer(quiz, wrongAnswerCount: 0)
        currentResponseTask = Task {
            await self.speakLiveSceneLine(quiz.question)
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
        await speakLiveSceneLine("Okay, back to the video.")
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
        await speakLiveSceneLine("Sorry, I couldn't build that one.")
        voiceState = .idle
        // A pop-out whose page failed may still be landing back in its frame.
        await LiveSceneOverlay.shared.waitForReturnToFinish()
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

    /// Escape closes the agent list when it is open. Otherwise it ends the scene and anything Clicky is still saying about it.
    /// During a video quiz question it skips that question and plays the video on.
    /// With no scene on screen, it skips the answer Clicky is giving.
    private func closeLiveSceneOnEscape() {
        // With the agent list open, Escape only closes it.
        if agentListPanelController.isOpen {
            agentListPanelController.close()
            return
        }
        // A second Escape while a pop-out lands in its frame hides it at once.
        if LiveSceneOverlay.shared.isReturningToSource {
            clearTheLiveSceneAndReleaseTheBuddy()
            return
        }
        if videoQuizQuestionIsActive {
            skipTheVideoQuizQuestion()
            return
        }
        if case .idle = liveScenePhase {
            stopTheReplyOnEscape()
            return
        }
        guard case .allLabelsShowing = liveScenePhase else { return }
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        voiceState = .idle
        clearFinishedLiveScene()
        scheduleTransientHideIfNeeded()
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
            await self.speakLiveSceneLine(quiz.question)
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
    private func startVoiceCommand(transcript: String, frontVideoState: JSONValue?) {
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        voiceState = .processing
        currentResponseTask = Task {
            await self.runVoiceCommand(transcript: transcript, frontVideoState: frontVideoState)
        }
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
            simulationIsOnScreen: simulationIsOnScreen(pageOnScreen: liveScenePageOnScreen, overlayIsShowingAScene: LiveSceneOverlay.shared.isShowingAScene)
        )
    }

    private func runVoiceCommand(transcript: String, frontVideoState: JSONValue?) async {
        let commandStartedAt = Date()
        // The two page reads wait on WebKit, and the study guide check may wait on the Worker, not on each other.
        async let pageToolsRead = LiveSceneOverlay.shared.pageVoiceTools()
        async let pageStateRead = LiveSceneOverlay.shared.pageVoiceState()
        async let studyGuideExistsRead = studyGuideExistsForTheFrontVideo(frontVideoState: frontVideoState)
        let (pageTools, pageState, studyGuideExistsForTheFrontVideo) = await (pageToolsRead, pageStateRead, studyGuideExistsRead)
        let appToolContext = appVoiceToolContext(
            pageState: pageState,
            frontVideoState: frontVideoState,
            studyGuideExistsForTheFrontVideo: studyGuideExistsForTheFrontVideo
        )
        let tools = voiceToolsOfferedToTheModel(pageTools: pageTools, appTools: AppVoiceTool.available(in: appToolContext))
        let offeredToolNames = Set(tools.map(\.name))
        let userMessageText = voiceCommandUserMessageText(
            transcript: transcript,
            sceneState: voiceCommandSceneState(pageState: pageState, frontVideoState: frontVideoState),
            recentActionLines: recentVoiceToolActionLines
        )
        var messages: [JSONValue] = [.object(["role": .string("user"), "content": .string(userMessageText)])]

        // A lookup or a failure needs the model again, and three turns cover a lookup followed by its action.
        // When the third turn still needs the model, Clicky says the apology instead of going quiet.
        var theTurnsRanOut = false
        for _ in 0..<3 {
            theTurnsRanOut = false
            let reply: VoiceCommandReply
            do {
                reply = try await voiceCommandClient.requestToolCalls(messages: messages, tools: tools)
            } catch is CancellationError {
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // During a quiz question the keyword path is the judge, which sent this command here,
                // so handing it back would loop between the two on every failure.
                if liveScenePhaseIsWaitingForAQuizAnswer {
                    print("Voice command: the router failed during a quiz question: \(error)")
                    await speakLiveSceneLine(voiceCommandGaveUpLine)
                    break
                }
                print("Voice command: the router failed, so the keyword path takes it: \(error)")
                respondByTheKeywordPath(transcript: transcript)
                return
            }
            guard !Task.isCancelled else { return }
            logVoiceCommandJSONIfEnabled("reply", reply.assistantContent)

            var outcomes: [VoiceToolOutcome] = []
            var toolResultBlocks: [JSONValue] = []
            for toolCall in reply.toolCalls {
                // A push-to-talk press cancels this command, so its remaining calls must not run.
                guard !Task.isCancelled else { return }
                showTheVoiceToolCallChip(for: toolCall, at: .beforeTheCall, offeredToolNames: offeredToolNames)
                let toolStartedAt = Date()
                let outcome = await runVoiceTool(toolCall, offeredToolNames: offeredToolNames, transcript: transcript)
                // A push-to-talk press during a slow call, like play_video's check, ends the command here, so its outcome is
                // never shown or recorded. A hand-off cancels this task itself when it starts the new path, and runs with
                // no await, so it goes on to show its chip and record its action.
                if Task.isCancelled && outcome != .handedOff { return }
                showTheVoiceToolCallChip(for: toolCall, at: .afterTheCall(outcome), offeredToolNames: offeredToolNames)
                print("Voice command: \(toolCall.chipText) ran in \(Int(Date().timeIntervalSince(toolStartedAt) * 1000)) ms, \(Int(Date().timeIntervalSince(commandStartedAt) * 1000)) ms after the command, \(outcome.isFailure ? "failed" : "ok")")
                logVoiceCommandJSONIfEnabled("result of \(toolCall.name)", [.string(outcome.toolResultText)])
                outcomes.append(outcome)
                recentVoiceToolActionLines.append(voiceToolActionLine(toolCall: toolCall, outcome: outcome))
                recentVoiceToolActionLines = Array(recentVoiceToolActionLines.suffix(5))
                if outcome == .handedOff { break }
                toolResultBlocks.append(.object([
                    "type": .string("tool_result"),
                    "tool_use_id": .string(toolCall.id),
                    "content": .string(outcome.toolResultText),
                    "is_error": .bool(outcome.isFailure),
                ]))
            }

            switch voiceCommandNextStep(toolCalls: reply.toolCalls, outcomes: outcomes, replyText: reply.text) {
            case .finishSilently:
                // A hand-off that started its own reply cancelled this task. One that did nothing, such as
                // closing a scene with no video to resume, leaves the spinner up unless this clears it.
                guard !Task.isCancelled else { return }
                voiceState = .idle
                scheduleTransientHideIfNeeded()
                return
            case .askTheModelAgain:
                theTurnsRanOut = true
                messages.append(.object(["role": .string("assistant"), "content": .array(reply.assistantContent)]))
                messages.append(.object(["role": .string("user"), "content": .array(toolResultBlocks)]))
                continue
            case .speak(let spokenLine):
                if !spokenLine.isEmpty {
                    await speakLiveSceneLine(spokenLine)
                }
            }
            break
        }
        guard !Task.isCancelled else { return }
        if theTurnsRanOut {
            await speakLiveSceneLine(voiceCommandGaveUpLine)
        }
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    /// Runs only a tool this turn offered, so a model, a page, or a debug caller cannot reach one the
    /// current state left out, such as a hand-off during a quiz question.
    private func runVoiceTool(_ toolCall: VoiceToolCall, offeredToolNames: Set<String>, transcript: String) async -> VoiceToolOutcome {
        guard offeredToolNames.contains(toolCall.name) else {
            return .failed(error: "\(toolCall.name) is not available right now", state: nil)
        }
        guard let appVoiceTool = AppVoiceTool(rawValue: toolCall.name) else {
            return await LiveSceneOverlay.shared.callPageVoiceTool(named: toolCall.name, input: toolCall.inputWithoutConfirmation)
        }
        return await runAppVoiceTool(appVoiceTool, input: toolCall.inputWithoutConfirmation, transcript: transcript)
    }

    private func runAppVoiceTool(_ appVoiceTool: AppVoiceTool, input: [String: JSONValue], transcript: String) async -> VoiceToolOutcome {
        if appVoiceTool.handsOffToALookAtTheMedia {
            theRequestBecameALookAtTheMedia()
        }
        switch appVoiceTool {
        case .answerWithScreen:
            respondToTranscript(transcript: transcript, requestedSceneKind: nil)
            return .handedOff
        case .buildNewScene:
            respondToTranscript(transcript: transcript, requestedSceneKind: input["asQuiz"]?.boolValue == true ? .quiz : .explore)
            return .handedOff
        case .buildSimulation:
            switch currentExperimentRequestStep {
            case .showTheReadyExperiment:
                startShowingTheReadyBackgroundScene()
                return .handedOff
            case .sayItIsStillBuilding:
                return .failed(error: "The experiment is still building, so wait for it", state: nil)
            case .startBuilding:
                return startBuildingASceneInTheBackground(whatToBuild: transcript, agentKind: .experiment)
            }
        case .popOut:
            respondToTranscript(transcript: transcript, requestedSceneKind: .framePopout)
            return .handedOff
        case .closeScene:
            closeTheSceneByVoice()
            return .handedOff
        case .explainPart:
            let requestedLabel = input["label"]?.stringValue ?? ""
            if partLabelToExplain(untrustedTappedLabel: requestedLabel, pageOnScreen: liveScenePageOnScreen, liveScenePhase: liveScenePhase) != nil {
                explainTheTappedPart(untrustedTappedLabel: requestedLabel)
            } else {
                respondToTranscript(transcript: "what does the \(requestedLabel) do?", requestedSceneKind: nil)
            }
            return .handedOff
        case .pauseVideo:
            return runLearnerVideoCommand(.pause)
        case .playVideo:
            let playOutcome = runLearnerVideoCommand(.play)
            guard case .changed = playOutcome else { return playOutcome }
            // play() only asks. Chrome may refuse it, and a video that loads its data only now needs a moment,
            // so the state is read a few times over about 1.6 seconds before a play counts as failed.
            var videoStateAfterPlay: JSONValue?
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(400))
                videoStateAfterPlay = videoQuizSession.frontVideoStateForVoiceCommands()
                if videoStateAfterPlay?["playing"]?.boolValue == true { break }
            }
            return learnerVideoPlayOutcome(videoStateAfterPlay: videoStateAfterPlay)
        case .seekRelative:
            guard let seconds = input["seconds"]?.numberValue else { return .failed(error: "seconds must be a number", state: nil) }
            return runLearnerVideoCommand(.seekBy(seconds: seconds))
        case .seekToTime:
            guard let seconds = input["seconds"]?.numberValue else { return .failed(error: "seconds must be a number", state: nil) }
            return runLearnerVideoCommand(.seekTo(seconds: seconds))
        case .setSpeed:
            guard let playbackRate = input["rate"]?.numberValue else { return .failed(error: "rate must be a number", state: nil) }
            return runLearnerVideoCommand(.setPlaybackRate(playbackRate))
        case .findMoment:
            do {
                let captionMoments = try await videoQuizSession.captionMomentsInTheFrontVideo(matching: input["query"]?.stringValue ?? "")
                return .lookedUp(result: .array(captionMoments.map { captionMoment in
                    .object(["seconds": .number(captionMoment.seconds), "captions": .string(captionMoment.text)])
                }))
            } catch {
                return .failed(error: (error as? LocalizedError)?.errorDescription ?? "Could not read this video's captions", state: nil)
            }
        case .endQuiz:
            handleVideoQuizVoiceCommand(.stop)
            return .handedOff
        case .makeStudyGuide:
            return startWritingTheStudyGuide(.write(focus: studyGuideWish(fromModelText: input["focus"]?.stringValue)))
        case .reviseStudyGuide:
            guard let instruction = studyGuideWish(fromModelText: input["instruction"]?.stringValue) else {
                return .failed(error: "instruction must say what to change", state: nil)
            }
            return startWritingTheStudyGuide(.revise(instruction: instruction))
        case .openStudyGuide:
            guard let frontVideoURL = videoQuizSession.frontTabURLOfTheFrontWindow() else {
                return .failed(error: "No study guide has been written for this video yet", state: nil)
            }
            // Checked again here, since the learner may have trashed the page since the tools were offered.
            guard let studyGuideRecord = await savedStudyGuideStillInNotion(forVideoURL: frontVideoURL, checkEvenIfCheckedBefore: true) else {
                return .failed(error: "This video's study guide was deleted in Notion, so there is nothing to open. Tell the learner, and that asking for a study guide again will write a new one.", state: nil)
            }
            let pageURL = studyGuideRecord.pageURL
            if let chromeTabID = notionPageChromeTabIDsByPageURL[pageURL], videoQuizSession.bringChromeTabForward(tabID: chromeTabID) {
                return .changed(state: nil)
            }
            // NSWorkspace opens any URL scheme, and a guide saved by an older build was never checked.
            guard pageURLIsOnNotion(pageURL), NSWorkspace.shared.open(pageURL) else {
                return .failed(error: "The study guide page would not open", state: nil)
            }
            return .changed(state: nil)
        case .buildModelInTheBackground:
            guard let whatToBuild = input["whatToBuild"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !whatToBuild.isEmpty else {
                return .failed(error: "whatToBuild must say what to build", state: nil)
            }
            return startBuildingASceneInTheBackground(whatToBuild: whatToBuild, agentKind: .threeDModel)
        case .showReadyModel:
            startShowingTheReadyBackgroundScene()
            return .handedOff
        case .startBackgroundTask:
            guard let goal = input["goal"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !goal.isEmpty else {
                return .failed(error: "goal must say what the task is", state: nil)
            }
            return startTheTaskAgent(goal: String(goal.prefix(longestTaskAgentGoal)))
        case .hearTaskAnswer:
            startSpeakingTheTaskAnswer()
            return .handedOff
        case .recordGuess:
            return await recordTheSimulationGuess(input["guess"]?.stringValue ?? "")
        }
    }

    // MARK: - Task Agent

    /// Starts a general agent on the learner's task and returns at once, so the router speaks its confirmation and the
    /// video keeps playing.
    private func startTheTaskAgent(goal: String) -> VoiceToolOutcome {
        let agentID = backgroundAgentStore.start(kind: .task)
        backgroundAgentStore.setSubject(goal, for: agentID)
        runInTheBackground(agentID) {
            await self.runTheTaskAgent(goal: goal, agentID: agentID)
        }
        return .changed(state: .object(["task": .string("started")]))
    }

    /// Starts the task on the agent harness, which runs Claude's loop, and answers each tool it asks for until the task
    /// finishes or fails. Nothing is spoken while it runs. Cancelling this task stops the task in the harness.
    private func runTheTaskAgent(goal: String, agentID: UUID) async {
        let startedAt = Date()
        let frontTab = videoQuizSession.frontTabTitleAndURLOfTheFrontWindow()
        var writtenPageURL: URL?
        do {
            let taskEvents = try agentHarness.startTask(taskID: agentID, goal: goal, frontTabTitle: frontTab?.title, frontTabURL: frontTab?.url)
            for await taskEvent in taskEvents {
                try Task.checkCancellation()
                switch taskEvent {
                case .toolCall(let toolCall):
                    let toolRun = await runTaskAgentTool(toolCall, agentID: agentID, pageAlreadyWritten: writtenPageURL != nil)
                    writtenPageURL = toolRun.writtenPageURL ?? writtenPageURL
                    try Task.checkCancellation()
                    agentHarness.sendToolResult(taskID: agentID, toolUseID: toolCall.toolUseID, content: toolRun.content, isError: toolRun.isError)
                case .finished(let spokenSummary):
                    finishTheTaskAgent(agentID, spokenSummary: spokenSummary, pageURL: writtenPageURL)
                    return
                case .failed(let reason):
                    throw TaskAgentError.harnessReportedFailure(reason: reason)
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
            backgroundAgentStore.fail(agentID, reason: "The task could not be finished. Ask again to try once more.")
            VoiceToolCallChip.shared.show("Couldn't finish the task", sender: chipSender(forAgent: agentID, kind: .task), secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen)
        }
    }

    /// Runs one app tool for the agent and returns its tool_result content. A tool that fails returns an error result,
    /// so the agent can work around it instead of the task failing.
    private func runTaskAgentTool(_ toolCall: HarnessToolCall, agentID: UUID, pageAlreadyWritten: Bool) async -> (content: JSONValue, isError: Bool, writtenPageURL: URL?) {
        func errorResult(_ message: String) -> (content: JSONValue, isError: Bool, writtenPageURL: URL?) {
            (.string(message), true, nil)
        }
        switch TaskAgentTool(rawValue: toolCall.toolName) {
        case .reportStep:
            let stepText = (toolCall.input["step"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !stepText.isEmpty {
                backgroundAgentStore.reportStep(String(stepText.prefix(60)), for: agentID)
            }
            return (.string("shown"), false, nil)
        case .readVideoCaptions:
            do {
                let video = try await videoQuizSession.frontVideoForStudyGuide()
                let captionText = video.transcriptLines
                    .map { transcriptLine in "[\(backgroundAgentElapsedTimeText(seconds: transcriptLine.seconds))] \(transcriptLine.text)" }
                    .joined(separator: "\n")
                let captionsResult = "Title: \(video.title)\nLink: \(video.url)\nCaptions:\n\(captionText)"
                return (.string(String(captionsResult.prefix(longestTaskAgentCaptionText))), false, nil)
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
            ])]), false, nil)
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
                return (.string("Written: \(pageURL.absoluteString)"), false, pageURL)
            } catch {
                print("Task agent: the Notion page failed: \(error)")
                return errorResult("The page could not be written: \(error)")
            }
        case nil:
            // The harness asks only for the four tools, so this is a harness newer than the app.
            return errorResult("\(toolCall.toolName) is not a tool")
        }
    }

    private func finishTheTaskAgent(_ agentID: UUID, spokenSummary: String, pageURL: URL?) {
        readyTaskAnswer = taskAgentSpokenAnswer(spokenSummary)
        taskAnswerWaitsToBeHeard = true
        finishTheBackgroundAgent(agentID, agentKind: .task, with: .answer(spokenSummary: spokenSummary, pageURL: pageURL))
    }

    /// Like any spoken reply, a push-to-talk press stops it.
    private func startSpeakingTheTaskAnswer() {
        guard let readyTaskAnswer else { return }
        taskAnswerWaitsToBeHeard = false
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        currentResponseTask = Task {
            await self.speakLiveSceneLine(readyTaskAnswer)
            await self.waitForClickyToFinishSpeaking()
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    // MARK: - Background Scene Agents (3D model and experiment)

    /// "Let me try it" starts the experiment agent and says one line, so the video keeps playing while it builds.
    /// A scene still building in the foreground is cancelled first, as a plain question cancels it, so its phase and
    /// the video's pause do not stay behind.
    private func startTheExperimentInTheBackground(transcript: String) {
        currentResponseTask?.cancel()
        liveSceneRequestTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        if case .buildingScene = liveScenePhase {
            liveSceneRequestGeneration += 1
            let cancelledBuildGeneration = liveSceneRequestGeneration
            liveScenePhase = .idle
            Task {
                await LiveSceneOverlay.shared.waitForReturnToFinish()
                // A ready experiment rising now takes over the pause, so the video stays paused for it.
                guard cancelledBuildGeneration == self.liveSceneRequestGeneration else { return }
                self.videoQuizSession.resumeVideoAfterRequestedScene()
            }
        }
        let spokenLine: String
        switch currentExperimentRequestStep {
        case .showTheReadyExperiment:
            startShowingTheReadyBackgroundScene()
            return
        case .sayItIsStillBuilding:
            spokenLine = "Your experiment is still building."
        case .startBuilding:
            _ = startBuildingASceneInTheBackground(whatToBuild: transcript, agentKind: .experiment)
            spokenLine = "Sure, I'll build that while you watch."
        }
        currentResponseTask = Task {
            await self.speakLiveSceneLine(spokenLine)
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
        runInTheBackground(agentID) {
            await self.buildTheBackgroundScene(whatToBuild: whatToBuild, agentID: agentID, agentKind: agentKind)
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
            let heardText = videoQuizSession.whatTheQuizVideoInFrontJustSaid()
            let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            let videoScreen = screenAndCaptureShowing(VideoQuizSession.screenRectOfTheMediaToRiseFrom(), in: screenCaptures)
            guard let videoScreenJPEGData = (videoScreen?.capture ?? screenCaptures.first)?.imageData else {
                throw BackgroundSceneBuildError.noScreenshot
            }
            try Task.checkCancellation()
            backgroundAgentStore.setSubject(whatToBuild, for: agentID)
            backgroundAgentStore.completeStep(for: agentID)
            let sceneQuestion = heardText.isEmpty ? whatToBuild : "\(whatToBuild) The video just said: \(heardText)"
            let liveScene = try await liveSceneClient.requestLiveScene(question: sceneQuestion, cursorScreenJPEGData: videoScreenJPEGData, sceneKind: sceneKind)
            // A scene cancelled from the agent list never shows, even when the Worker had already replied.
            try Task.checkCancellation()
            print("\(agentKind.displayName): built \"\(whatToBuild)\" in \(Int(Date().timeIntervalSince(startedAt))) s")
            if readyBackgroundScene != nil {
                print("\(agentKind.displayName): this \(agentKind.builtThingName) finished last, so it replaces the scene still waiting to be shown")
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
            backgroundAgentStore.fail(agentID, reason: "The \(agentKind.builtThingName) could not be built. Ask again to try once more.")
            VoiceToolCallChip.shared.show(
                "Couldn't build the \(agentKind.builtThingName)",
                sender: chipSender(forAgent: agentID, kind: agentKind),
                secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
            )
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
            readyBackgroundScene = readyBackgroundScene ?? sceneToShow
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
    private func studyGuideExistsForTheFrontVideo(frontVideoState: JSONValue?) async -> Bool {
        guard frontVideoState?["onYouTube"]?.boolValue == true,
              let frontVideoURL = videoQuizSession.frontTabURLOfTheFrontWindow() else {
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

    /// Nothing is spoken when the guide ends, because the learner is watching a video. The wingman beside the cursor,
    /// the chip under it, and the page in a background tab say it instead. Returns whether the guide was written.
    @discardableResult
    private func writeTheStudyGuide(_ studyGuideJob: StudyGuideJob, agentID: UUID) async -> Bool {
        let startedAt = Date()
        let agentKind = studyGuideJob.agentKind
        do {
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
            var studyGuideRecord = try await studyGuideClient.writeStudyGuide(StudyGuideRequest(
                videoTitle: video.title,
                videoURL: video.url,
                transcriptLines: video.transcriptLines,
                quizResults: quizResultsForTheGuide,
                focus: studyGuideFocus,
                revision: studyGuideRevision
            ))
            studyGuideRecord.quizResults = quizResultsForTheGuide
            let agentWasCancelled = Task.isCancelled
            guard !agentWasCancelled || studyGuideJob.replyIsSavedEvenWhenCancelled else { throw CancellationError() }
            // Filed under the video the guide was written for, not whichever tab is in front now.
            savedStudyGuides.save(studyGuideRecord, forVideoURL: video.url)
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
            backgroundAgentStore.fail(agentID, reason: studyGuideFailureReason(for: error))
            VoiceToolCallChip.shared.show(
                studyGuideFailureLine(for: error),
                sender: chipSender(forAgent: agentID, kind: agentKind),
                secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
            )
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
            // "Glass" belongs to quiz answers.
            NSSound(named: "Tink")?.play()
            // The page opens behind the video tab. open_study_guide, asked for by voice, brings it forward instead.
            var secondaryChipText = "· say open my study guide"
            if let replacingPageURL, loadThePageInTheTabOfThePageItReplaces(pageURL, replacingPageURL: replacingPageURL) {
                secondaryChipText = "· updated in its tab"
            } else if let openedChromeTabID = videoQuizSession.openInABackgroundChromeTab(pageURL) {
                notionPageChromeTabIDsByPageURL[pageURL] = openedChromeTabID
                secondaryChipText = "· opened in a new tab"
            }
            VoiceToolCallChip.shared.show(
                agentKind.finishedChipText,
                sender: chipSender(forAgent: agentID, kind: agentKind),
                secondaryChipText: secondaryChipText,
                secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
            )
        case .readyScene:
            NSSound(named: "Tink")?.play()
            let sceneRisesNow = aReadyBackgroundSceneMayRiseNow
            VoiceToolCallChip.shared.show(
                agentKind.finishedChipText,
                sender: chipSender(forAgent: agentID, kind: agentKind),
                secondaryChipText: sceneRisesNow ? nil : "· say \(agentKind.waitingPhrase)",
                secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
            )
            if sceneRisesNow {
                startShowingTheReadyBackgroundScene()
            } else {
                print("\(agentKind.displayName): the screen is busy, so it waits for \"\(agentKind.waitingPhrase)\"")
            }
        case .answer(_, let pageURL):
            NSSound(named: "Tink")?.play()
            // Like a guide's page, a task's page opens behind the video tab.
            if let pageURL, let openedChromeTabID = videoQuizSession.openInABackgroundChromeTab(pageURL) {
                notionPageChromeTabIDsByPageURL[pageURL] = openedChromeTabID
            }
            VoiceToolCallChip.shared.show(
                agentKind.finishedChipText,
                sender: chipSender(forAgent: agentID, kind: agentKind),
                secondaryChipText: "· say what did you find",
                secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
            )
        }
    }

    /// Who an ending chip speaks for: the agent's kind, and its player while a team theme is on.
    private func chipSender(forAgent agentID: UUID, kind: BackgroundAgentKind) -> VoiceToolCallChipSender {
        .backgroundAgent(kind, player: backgroundAgentStore.player(for: agentID))
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
        return voiceToolsOfferedToTheModel(pageTools: await LiveSceneOverlay.shared.pageVoiceTools(), appTools: appTools)
    }

    /// Not listed by tools/list, since it is for screenshots and demo takes, not for the model.
    private static let debugSeedAgentsToolName = "debug_seed_agents"

    private func runVoiceToolFromTheDebugServer(toolName: String, toolInput: [String: JSONValue]) async -> VoiceToolOutcome {
        if toolName == Self.debugSeedAgentsToolName {
            seedBackgroundAgentsForScreenshots()
            return .changed(state: nil)
        }
        let toolCall = VoiceToolCall(id: "debug", name: toolName, input: toolInput)
        let offeredToolNames = Set(await voiceToolsForTheDebugServer().map(\.name))
        showTheVoiceToolCallChip(for: toolCall, at: .beforeTheCall, offeredToolNames: offeredToolNames)
        let outcome = await runVoiceTool(toolCall, offeredToolNames: offeredToolNames, transcript: "")
        showTheVoiceToolCallChip(for: toolCall, at: .afterTheCall(outcome), offeredToolNames: offeredToolNames)
        return outcome
    }

    /// Puts three running agents, one finished with its ending chip, and one failed on screen with no Worker call, so
    /// every wingman, chip, and agent list state can be captured at once. Running agents fill from the clock and stay up
    /// until cancelled from the list.
    private func seedBackgroundAgentsForScreenshots() {
        let finishedAgentID = backgroundAgentStore.seedAgentsForScreenshots()
        VoiceToolCallChip.shared.show(
            BackgroundAgentKind.task.finishedChipText,
            sender: chipSender(forAgent: finishedAgentID, kind: .task),
            secondaryChipText: "· say what did you find",
            secondsOnScreen: Self.backgroundAgentChipSecondsOnScreen
        )
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
            try await elevenLabsTTSClient.speakText(status)
            print("Live scene status spoken: \(status)")
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Live scene status line failed: \(error.localizedDescription)")
        }
    }

    /// How far through `text` Clicky's voice is, from 0 to 1, or nil when Clicky is not speaking that line.
    /// The pointing bubble types along with it.
    func spokenFractionOfTheLine(_ text: String) -> Double? {
        elevenLabsTTSClient.spokenFraction(ofLine: text)
    }

    /// Returns true once the line's own audio has started, and false on a cancel or when the credits fallback plays instead.
    @discardableResult
    private func speakLiveSceneLine(_ line: String) async -> Bool {
        do {
            try await elevenLabsTTSClient.speakText(line)
            voiceState = .responding
            return true
        } catch is CancellationError {
            return false
        } catch {
            ClickyAnalytics.trackTTSError(error: error.localizedDescription)
            print("⚠️ ElevenLabs TTS error: \(error)")
            speakCreditsErrorFallback()
            return false
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
        // Every exit, a cancelled one too, sends the buddy back to the mouse if it still points for this narration.
        defer { releaseTheBuddyFromTheLiveScenePart(pointedByNarrationID: narrationID) }
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
            await speakLiveSceneNarrationSentence(
                spokenPart.spokenText,
                aboutPartLabel: knownPartLabel(matching: spokenPart.partLabel, knownPartLabels: knownPartLabels),
                narrationID: narrationID
            )
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
    private func speakLiveSceneNarrationSentence(_ spokenText: String, aboutPartLabel partLabel: String?, narrationID: UUID) async {
        guard let partLabel else {
            await speakLiveSceneLine(spokenText)
            // The buddy stays on the last part it pointed at, and its bubble follows what Clicky says now.
            if !Task.isCancelled, detectedElementPointingHold == .untilReleased(byNarrationID: narrationID) {
                detectedElementBubbleText = spokenText
            }
            await waitForClickyToFinishSpeaking()
            return
        }
        LiveSceneOverlay.shared.highlightPart(labelText: partLabel)
        // The label's place is read once the camera stops gliding to the part, while the sentence starts playing.
        let settledLabelScreenPointsTask = Task {
            await LiveSceneOverlay.shared.partLabelScreenPointsOnceTheCameraSettles()
        }
        await speakLiveSceneLine(spokenText)
        let settledLabelScreenPoints = await settledLabelScreenPointsTask.value
        if !Task.isCancelled,
           let partScreenPoint = settledLabelScreenPoints.first(where: { labelScreenPoint in labelScreenPoint.label == partLabel }) {
            pointTheBuddy(atLiveScenePart: partScreenPoint, bubbleText: spokenText, narrationID: narrationID)
        }
        await waitForClickyToFinishSpeaking()
    }

    /// The buddy flies on its usual arc to the part's label and stays until the narration that pointed it
    /// releases it. Its bubble shows the sentence Clicky is speaking, since the label already names the part.
    private func pointTheBuddy(atLiveScenePart partScreenPoint: LiveScenePartScreenPoint, bubbleText: String, narrationID: UUID) {
        guard let displayFrame = NSScreen.screens.first(where: { screen in
            screen.frame.contains(partScreenPoint.globalPoint)
        })?.frame else { return }
        detectedElementPointingHold = .untilReleased(byNarrationID: narrationID)
        detectedElementBubbleText = bubbleText
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = partScreenPoint.globalPoint
    }

    /// The blue cursor flies to the quiz's "?" label and its bubble shows the question, typed along with the voice, so a
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
        await speakLiveSceneLine(landmarkLine)
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
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
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
        let utterance = "Sorry, I lost my voice for a second. Please try that again."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
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

        // Start playback immediately — the video plays while invisible,
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
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
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
