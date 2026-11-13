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

    private var liveScenePhase: LiveScenePhase = .idle
    /// Set each time a page plays, so narration uses Clicky's own data about the page on screen.
    private var liveScenePageOnScreen: LiveScenePageOnScreen?
    /// Bumped on every new question so a scene request still in flight cannot play late.
    private var liveSceneRequestGeneration = 0
    private var liveSceneRequestTask: Task<Void, Never>?
    private var liveSceneTourFinishedTask: Task<Void, Never>?

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
    private var pinchCancellable: AnyCancellable?
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
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

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
        LiveSceneOverlay.shared.onTourFinished = { [weak self] in
            self?.handleLiveSceneTourFinished()
        }
        LiveSceneOverlay.shared.onPartTapped = { [weak self] untrustedTappedLabel in
            self?.explainTheTappedPart(untrustedTappedLabel: untrustedTappedLabel)
        }
        LiveSceneOverlay.shared.onPageError = { [weak self] pageErrorText in
            self?.handleLiveScenePageError(pageErrorText)
        }
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        bindPinchToLiveSceneZoom()
        bindEscapeToCloseLiveScene()
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
    private func bindEscapeToCloseLiveScene() {
        escapeKeyCancellable = globalPushToTalkShortcutMonitor
            .escapeKeyPressPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.closeLiveSceneOnEscape()
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

            // A new press starts a new request, so the label from the last build is out of date.
            LiveSceneStatusLabel.shared.hide()

            showTheCursorOverlayForThisInteraction()

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            elevenLabsTTSClient.stopPlayback()
            clearDetectedElementLocation()

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
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    /// Added to the system prompt for a look-inside request. Without it Claude
    /// answers from the page and tells the learner to scroll while the scene opens.
    private static let liveSceneExploreVoiceResponseInstructions = """


    for this reply only: a labeled 3d model of what they asked about is already opening on their screen, and the camera is moving through it. reply with one short, cheerful spoken sentence about what they're seeing inside, at most 20 words. talk about the model, not the web page. never tell them to scroll, click, or look anywhere else. the only tag you may write is [POINT:none], at the very end.
    """

    // MARK: - AI Response Pipeline

    #if DEBUG
    /// Feeds transcripts through the real pipeline with no microphone, so the
    /// whole voice and quiz loop can be tested unattended. A transcript that
    /// starts with "~" does not wait for Clicky: the next one follows 6 seconds
    /// later, while a scene is still building.
    func runLiveSceneRehearsal(transcripts: [String]) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        for rehearsalStep in transcripts {
            let nextStepInterruptsThisOne = rehearsalStep.hasPrefix("~")
            // "?" waits up to 4 minutes for a video quiz question, since a pause comes whenever the video reaches it.
            let stepWaitsForAQuestion = rehearsalStep.hasPrefix("?")
            let transcript = nextStepInterruptsThisOne || stepWaitsForAQuestion ? String(rehearsalStep.dropFirst()) : rehearsalStep
            if stepWaitsForAQuestion {
                // A learner answers after hearing the question, so wait for it to start and end.
                var questionAudioHasStarted = false
                for _ in 0..<960 {
                    var questionIsWaiting = false
                    if case .awaitingAnswer = liveScenePhase { questionIsWaiting = true }
                    if questionIsWaiting && elevenLabsTTSClient.isPlaying { questionAudioHasStarted = true }
                    if questionIsWaiting && questionAudioHasStarted && !elevenLabsTTSClient.isPlaying { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            print("Live scene rehearsal: saying \"\(transcript)\" in phase \(liveScenePhase)")
            // A push-to-talk press hides the label before a transcript goes out, so the rehearsal does
            // the same, and a line the previous step left up cannot stay on screen.
            LiveSceneStatusLabel.shared.hide()
            sendTranscriptToClaudeWithScreenshot(transcript: transcript)
            if nextStepInterruptsThisOne {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                continue
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while true {
                let tourIsStillPlaying: Bool
                if case .touring = liveScenePhase { tourIsStillPlaying = true } else { tourIsStillPlaying = false }
                let clickyIsBusy = voiceState == .processing || elevenLabsTTSClient.isPlaying
                if !tourIsStillPlaying && !clickyIsBusy { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            print("Live scene rehearsal: finished, phase \(liveScenePhase)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
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

        currentResponseTask?.cancel()
        liveSceneRequestTask?.cancel()
        liveSceneTourFinishedTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        liveSceneRequestGeneration += 1
        let requestGeneration = liveSceneRequestGeneration

        // A 3D model only appears when the learner asks. During a video quiz that
        // pauses the video, and a pending question is set aside for the model.
        var sceneQuestion = transcript
        let requestedKind = liveSceneKind(for: transcript)
        if videoQuizSession.isRunning,
           requestedKind == .explore || requestedKind == .framePopout,
           videoQuizSession.quizVideoIsTheTabInFront() {
            let heardText = videoQuizSession.pauseVideoForRequestedScene()
            videoQuizQuestionIsActive = false
            liveScenePhase = .idle
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
        }

        if case .allLabelsShowing = liveScenePhase, liveSceneKind(for: transcript) == nil {
            currentResponseTask = Task {
                await self.answerAboutTheLiveSceneOnScreen(transcript: transcript)
            }
            return
        }

        if liveSceneKind(for: transcript) == .framePopout {
            clearFinishedLiveScene(resumesTheVideo: false)
            liveScenePhase = .buildingScene
            currentResponseTask = Task {
                await self.popOutTheVisibleVideoFrame(requestGeneration: requestGeneration)
            }
            return
        }

        if let requestedSceneKind = liveSceneKind(for: transcript) {
            clearFinishedLiveScene(resumesTheVideo: false)
            liveScenePhase = .buildingScene
            currentResponseTask = Task {
                await self.buildLiveSceneWithStatusLabel(
                    transcript: sceneQuestion,
                    sceneKind: requestedSceneKind,
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
                        // speakText returns after player.play() — audio is now playing
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
    private func popOutTheVisibleVideoFrame(requestGeneration: Int) async {
        LiveSceneStatusLabel.shared.show(.poppingItOut)
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
              let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen),
              LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: false, overlayScreen: overlayScreen) else {
            liveScenePhase = .idle
            await speakLiveSceneLine(failureLine)
            voiceState = .idle
            // No scene opened, so nothing will clear it and resume the video.
            if videoQuizSession.videoIsPausedForRequestedScene {
                videoQuizSession.resumeVideoAfterRequestedScene()
            }
            return
        }
        print("Frame pop-out: lifting the subject out of the frame with \(framePopout.parts.count) labels")
        liveScenePhase = .touring(quizToAskAfterTour: nil)
        liveScenePageOnScreen = .framePopout(framePopout)
        // Idle during the tour so the triangle shows, while the narration is written in the background.
        voiceState = .idle
        await narrateTheFramePopout(framePopout, narrationTrigger: .afterTour)
        guard !Task.isCancelled else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
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
            let buildingLineTask = Task { await self.speakLiveSceneStatus("Building your 3D scene") }
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
            let highlightInstructions = partLabels.isEmpty ? "" : """


            the model has these exact part names: \(partLabels.joined(separator: ", ")). start each sentence with [PART:name] using one of those exact names. use two to four short sentences.
            """
            let (fullResponseText, _) = try await claudeAPI.analyzeImageStreaming(
                images: labeledImages,
                systemPrompt: Self.companionVoiceResponseSystemPrompt
                    + Self.liveSceneExploreVoiceResponseInstructions
                    + highlightInstructions,
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

    private func clearFinishedLiveScene(resumesTheVideo: Bool = true) {
        guard case .allLabelsShowing = liveScenePhase else { return }
        LiveSceneOverlay.shared.clear()
        liveScenePhase = .idle
        guard resumesTheVideo, videoQuizSession.videoIsPausedForRequestedScene else { return }
        Task {
            await self.speakLiveSceneLine("Okay, back to the video.")
            await self.waitForClickyToFinishSpeaking()
            try? await Task.sleep(nanoseconds: 500_000_000)
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
                cursorScreenJPEGData: cursorScreenJPEGData
            )
            guard requestGeneration == liveSceneRequestGeneration else { return }
            let quizToAskAfterTour = sceneKind == .quiz ? liveScene.quiz : nil
            // The rise starts from the cursor screen's screenshot, so the scene plays on that screen.
            guard let overlayScreen = screenUnderTheMouseCursor() else { return }
            var liveScenePageHTML = liveScene.html
            if let mediaRectToRiseFrom,
               let riseScript = liveSceneRiseScriptFromTheBundle() {
                liveScenePageHTML = liveScenePageThatRisesFromTheSource(
                    generatedPageHTML: liveScene.html,
                    screenJPEGBase64: cursorScreenJPEGData.base64EncodedString(),
                    sourceRectInOverlayPage: rectInOverlayPage(of: mediaRectToRiseFrom, overlayScreen: overlayScreen),
                    riseScript: riseScript
                )
            }
            let liveSceneWasAccepted = LiveSceneOverlay.shared.playLiveScene(
                html: liveScenePageHTML,
                hidesQuizLabel: quizToAskAfterTour != nil,
                overlayScreen: overlayScreen
            )
            guard liveSceneWasAccepted else { return }
            liveScenePhase = .touring(quizToAskAfterTour: quizToAskAfterTour)
            liveScenePageOnScreen = .generatedPage
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            print("Live scene request failed: \(error.localizedDescription)")
        }
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
                    grade: wordMatchGrade,
                    spokenReply: spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: true)
                )
            case .nameOnly:
                judgedAnswer = LiveSceneJudgedAnswer(
                    grade: wordMatchGrade,
                    spokenReply: "Yes, it's \(quiz.answerLabel.lowercased())! And what does it do?"
                )
            case .askedForHelp:
                judgedAnswer = LiveSceneJudgedAnswer(
                    grade: wordMatchGrade,
                    spokenReply: spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false)
                )
            case .wrong:
                judgedAnswer = LiveSceneJudgedAnswer(
                    grade: wordMatchGrade,
                    spokenReply: "Ooh, not quite! Take another look."
                )
            }
        }
        let spokenLine = applyJudgedLiveSceneAnswer(
            judgedAnswer: judgedAnswer,
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
        judgedAnswer: LiveSceneJudgedAnswer,
        quiz: LiveSceneQuiz,
        wrongAnswerCount: Int
    ) -> String {
        switch judgedAnswer.grade {
        case .nameAndFunctionWord:
            LiveSceneOverlay.shared.reveal()
            liveScenePhase = .allLabelsShowing
            return judgedAnswer.spokenReply
        case .nameOnly:
            LiveSceneOverlay.shared.reveal()
            liveScenePhase = .awaitingFollowUpOnWhatThePartDoes(quiz)
            return judgedAnswer.spokenReply
        case .askedForHelp:
            LiveSceneOverlay.shared.reveal()
            liveScenePhase = .allLabelsShowing
            return judgedAnswer.spokenReply
        case .wrong:
            if wrongAnswerCount == 0 {
                liveScenePhase = .awaitingAnswer(quiz, wrongAnswerCount: 1)
                return judgedAnswer.spokenReply
            }
            LiveSceneOverlay.shared.reveal()
            liveScenePhase = .allLabelsShowing
            return spokenLineAfterTheQuizEnds(quiz: quiz, learnerSaidWhatThePartDoes: false)
        }
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
            if judgedAnswer.grade == .nameAndFunctionWord {
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
            spokenLine = "Sure! Let me read through this video."
        case .stop:
            videoQuizSession.stop()
            // The scene request runs in its own task, so cancelling the response task above
            // does not reach it. A new generation also keeps a reply already in flight from playing.
            if case .buildingScene = liveScenePhase {
                liveSceneRequestTask?.cancel()
                liveSceneRequestTask = nil
                liveSceneRequestGeneration += 1
                LiveSceneStatusLabel.shared.hide(onlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines)
                liveScenePhase = .idle
            }
            if videoQuizQuestionIsActive {
                videoQuizQuestionIsActive = false
                liveScenePhase = .idle
                LiveSceneOverlay.shared.clear()
            }
            spokenLine = "Okay, I'll stop quizzing. That was fun!"
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
        clearFinishedLiveScene()
        videoQuizQuestionIsActive = true
        if let framePopout,
           let overlayScreen = overlayScreen(showing: framePopout.frameGrab),
           let popoutPageHTML = framePopoutPageHTML(for: framePopout, overlayScreen: overlayScreen),
           LiveSceneOverlay.shared.playLiveScene(html: popoutPageHTML, hidesQuizLabel: true, overlayScreen: overlayScreen) {
            print("Video quiz: lifting the subject out of the frame with \(framePopout.parts.count) labels")
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
        // A frame pop-out sits over the video, so it goes away before play.
        LiveSceneOverlay.shared.clear()
        videoQuizSession.resumeVideoAfterQuestion()
    }

    private func spokenLineAfterTheQuizEnds(quiz: LiveSceneQuiz, learnerSaidWhatThePartDoes: Bool) -> String {
        if learnerSaidWhatThePartDoes {
            return "Yes! \(quiz.explanation) Nice work!"
        }
        return "Good try! \(quiz.explanation)"
    }

    /// No scene is on screen, so nothing else will resume a video paused for it.
    private func sayTheSceneCouldNotBeBuilt() async {
        liveScenePhase = .idle
        await speakLiveSceneLine("Sorry, I couldn't build that one.")
        voiceState = .idle
        if videoQuizSession.videoIsPausedForRequestedScene {
            videoQuizSession.resumeVideoAfterRequestedScene()
        }
    }

    /// A page that throws before its tour ends never posts tourFinished, so Clicky would wait on it forever.
    private func handleLiveScenePageError(_ pageErrorText: String) {
        guard case .touring(let quizToAskAfterTour) = liveScenePhase else { return }
        print("Live scene: giving up on the page after \(pageErrorText)")
        LiveSceneOverlay.shared.clear()
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

    /// Escape ends the scene and anything Clicky is still saying about it.
    /// During a video quiz question it skips that question and plays the video on.
    private func closeLiveSceneOnEscape() {
        if videoQuizQuestionIsActive {
            skipTheVideoQuizQuestion()
            return
        }
        guard case .allLabelsShowing = liveScenePhase else { return }
        currentResponseTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        voiceState = .idle
        clearFinishedLiveScene()
        scheduleTransientHideIfNeeded()
    }

    private func skipTheVideoQuizQuestion() {
        currentResponseTask?.cancel()
        liveSceneTourFinishedTask?.cancel()
        elevenLabsTTSClient.stopPlayback()
        videoQuizQuestionIsActive = false
        liveScenePhase = .idle
        LiveSceneOverlay.shared.clear()
        voiceState = .idle
        scheduleTransientHideIfNeeded()
        print("Video quiz: skipped the question on Escape")
        videoQuizSession.resumeVideoAfterQuestion()
    }

    private func handleLiveSceneTourFinished() {
        guard case .touring(let quizToAskAfterTour) = liveScenePhase else { return }
        guard let quiz = quizToAskAfterTour else {
            liveScenePhase = .allLabelsShowing
            LiveSceneOverlay.shared.letLearnerDragTheModel()
            // The tour ends close on the answer part, which only a quiz needs, so frame the whole subject again.
            LiveSceneOverlay.shared.highlightPart(labelText: "")
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
            await self.speakLiveSceneLine(quiz.question)
            guard !Task.isCancelled else { return }
            self.voiceState = .idle
            self.scheduleTransientHideIfNeeded()
        }
    }

    /// The tour can finish while Claude is still thinking, and isPlaying is
    /// false until the voice answer actually starts. Wait through that, and
    /// through playback, so the quiz is the next thing Clicky says.
    private func waitUntilTheVoiceAnswerIsQuiet() async {
        while !Task.isCancelled {
            let voiceAnswerIsStillRunning = voiceState == .processing
                || voiceState == .listening
                || elevenLabsTTSClient.isPlaying
            if !voiceAnswerIsStillRunning {
                return
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
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

    private func speakLiveSceneLine(_ line: String) async {
        do {
            try await elevenLabsTTSClient.speakText(line)
            voiceState = .responding
        } catch is CancellationError {
            return
        } catch {
            ClickyAnalytics.trackTTSError(error: error.localizedDescription)
            print("⚠️ ElevenLabs TTS error: \(error)")
            speakCreditsErrorFallback()
        }
    }

    // MARK: - Bundled Page Narration

    /// Says a few sentences about a frame pop-out, one part each, highlighting that part and pointing the
    /// blue cursor at it as it is named. The Claude call starts right away and the speech waits for the tour,
    /// so it is ready when the camera stops. The labels come from the pop-out's own parts list, because the
    /// page may not have loaded yet.
    private func narrateTheFramePopout(_ framePopout: VideoFramePopout, narrationTrigger: LiveSceneNarrationTrigger) async {
        let narrationID = UUID()
        // Every exit, a cancelled one too, sends the buddy back to the mouse if it still points for this narration.
        defer { releaseTheBuddyFromTheLiveScenePart(pointedByNarrationID: narrationID) }
        let knownPartLabels = framePopout.parts.map(\.label)
        var pausedFrameImages: [(data: Data, label: String)] = []
        if let pausedFrameJPEGData = Data(base64Encoded: framePopout.frameGrab.jpeg) {
            pausedFrameImages.append((data: pausedFrameJPEGData, label: "the paused video frame the 3d model was lifted from"))
        }
        let narrationText: String
        do {
            narrationText = try await claudeAPI.analyzeImageStreaming(
                images: pausedFrameImages,
                systemPrompt: liveSceneNarrationSystemPrompt,
                userPrompt: liveSceneNarrationUserPrompt(for: narrationTrigger, knownPartLabels: knownPartLabels),
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
            pointTheBuddy(atLiveScenePart: partScreenPoint, narrationID: narrationID)
        }
        await waitForClickyToFinishSpeaking()
    }

    /// The buddy flies on its usual arc to the part's label with the label in its bubble, and stays
    /// until the narration that pointed it releases it.
    private func pointTheBuddy(atLiveScenePart partScreenPoint: LiveScenePartScreenPoint, narrationID: UUID) {
        guard let displayFrame = NSScreen.screens.first(where: { screen in
            screen.frame.contains(partScreenPoint.globalPoint)
        })?.frame else { return }
        detectedElementPointingHold = .untilReleased(byNarrationID: narrationID)
        detectedElementBubbleText = partScreenPoint.label
        detectedElementDisplayFrame = displayFrame
        detectedElementScreenLocation = partScreenPoint.globalPoint
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

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

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
