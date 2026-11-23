//
//  ThemeStudioController.swift
//  leanring-buddy
//
//  Runs the Theme Studio: it owns the state machine's current state, calls POST /theme-ideas, puts the highlighted idea on
//  the real cursor as a preview, and saves the idea the learner picks. Every decision about what a state allows lives in
//  `ThemeStudioState`. This class only moves between states, talks to the Worker, and touches the theme settings, so
//  CompanionManager's part is wiring.
//

import AppKit
import Combine
import Foundation

/// Why the card closes, which decides how it leaves: a save flies the idea's cursor into the real cursor first, and every
/// other close shrinks the card into the cursor.
nonisolated enum ThemeStudioCardClosing: Equatable, Sendable {
    case dismissed
    /// The learner saved `idea`, whose picture (if it uses one) is `pictureJPEG`.
    case saved(idea: ClickyTheme, pictureJPEG: Data?)
}

/// Shows and hides the card. The real one is the panel next to the cursor, and a test swaps in one that records the calls,
/// since a test process has no window to show.
@MainActor
protocol ThemeStudioCardPresenting: AnyObject {
    func show(studio: ThemeStudioController)
    func hide(because reason: ThemeStudioCardClosing)
}

extension ThemeStudioPanelController: ThemeStudioCardPresenting {}

extension ThemeStudioController.SaveOutcome {
    /// What the chip above the cursor says after a click on Save, or nil when there was nothing to save. The voice tool
    /// reports its outcome to the router, which shows its own chip, so this is for the card's button alone.
    nonisolated var chipPhraseAfterAClickOnSave: String? {
        switch self {
        case .saved: return themeSavedChipPhrase
        case .nothingToSave: return nil
        case .failed: return themeCouldNotBeSavedChipPhrase
        }
    }
}

@MainActor
final class ThemeStudioController: ObservableObject {
    /// What the studio needs from the rest of the app, supplied by CompanionManager.
    struct Environment {
        /// Says a line aloud.
        let speak: (String) -> Void
        /// Ends a line the studio is saying or has queued to say, so a closed card never keeps talking.
        let stopSpeaking: () -> Void
        /// Plays a theme sound through the speakers.
        let playSound: (ThemeSound) -> Void
        /// A JPEG of the region the learner circled, or else of the largest picture in Chrome's front tab, or nil when there is none.
        let captureThePicture: () async -> ThemeStudioPicture?
        /// Asks the Worker for ideas (`POST /theme-ideas`).
        let designIdeas: (ThemeIdeasRequest) async throws -> ThemeIdeasReply
    }

    enum SaveOutcome: Equatable {
        case saved(themeName: String)
        case nothingToSave
        case failed
    }

    static let couldNotDesignLine = "Sorry, I couldn't design that one."
    static let noPictureLine = "I don't see a picture in Chrome's front tab, so I'll go from your words."

    @Published private(set) var state: ThemeStudioState = .closed {
        didSet {
            if state.isOpen { lastOpenState = state }
            if state.isOpen && !oldValue.isOpen {
                isStampingTheSavedIdea = false
                cardPresenter.show(studio: self)
            } else if !state.isOpen && oldValue.isOpen {
                let reasonTheCardCloses = closingReason
                closingReason = .dismissed
                cardPresenter.hide(because: reasonTheCardCloses)
            }
        }
    }

    /// How many times ideas have arrived since the card opened. The card's tiles take it as their identity, so each arrival
    /// lands its tiles again, 90 ms apart, even when a refinement replaces ideas that were already on show.
    @Published private(set) var ideasArrivalCount = 0
    /// True while the card shows its old ideas after a design failed, so it says so in a red Callout. Any new design, pick,
    /// or close clears it.
    @Published private(set) var showsTheDesignFailedNotice = false
    /// True from a save until the card is gone, so the saved idea's tile shows its stamp while its cursor flies out.
    @Published private(set) var isStampingTheSavedIdea = false
    /// The last state the card showed while it was open. A card that closes plays its move on the carrier with this state,
    /// not the closed one, so what flies into the cursor is what the learner saw.
    private(set) var lastOpenState: ThemeStudioState = .closed

    /// How long before each sound of the sound preview, so the three never overlap.
    static let defaultSecondsBetweenPreviewSounds = 0.7

    let themeSettings: CompanionThemeSettings
    private let environment: Environment
    private let cardPresenter: ThemeStudioCardPresenting
    private var designTask: Task<Void, Never>?
    private var soundPreviewTask: Task<Void, Never>?
    private var closingReason: ThemeStudioCardClosing = .dismissed
    private let secondsBetweenPreviewSounds: Double

    init(
        themeSettings: CompanionThemeSettings,
        environment: Environment,
        cardPresenter: ThemeStudioCardPresenting,
        secondsBetweenPreviewSounds: Double = ThemeStudioController.defaultSecondsBetweenPreviewSounds
    ) {
        self.themeSettings = themeSettings
        self.environment = environment
        self.cardPresenter = cardPresenter
        self.secondsBetweenPreviewSounds = secondsBetweenPreviewSounds
    }

    var isOpen: Bool { state.isOpen }

    // MARK: - Designing

    /// Opens the card, or dims the ideas on it, and asks the Worker for three new ideas. It returns at once. A design that is
    /// still running is cancelled, so only the newest one's ideas arrive. `basedOnIdea` counts from 1.
    func design(request requestText: String, basedOnIdea: Int?, pictureChoice: ThemeStudioPictureChoice) {
        designTask?.cancel()
        soundPreviewTask?.cancel()
        showsTheDesignFailedNotice = false
        let ideasThatWereOnTheCard = state.ideasOnTheCard
        state = state.startingADesign()
        designTask = Task {
            await self.runTheDesign(
                requestText: requestText,
                basedOnIdea: basedOnIdea,
                pictureChoice: pictureChoice,
                ideasThatWereOnTheCard: ideasThatWereOnTheCard
            )
        }
    }

    /// Returns when the design that is running has finished, so a test never waits a guessed time.
    func waitForTheDesign() async {
        await designTask?.value
    }

    private func runTheDesign(
        requestText: String,
        basedOnIdea: Int?,
        pictureChoice: ThemeStudioPictureChoice,
        ideasThatWereOnTheCard: ThemeStudioIdeas?
    ) async {
        let picture: ThemeStudioPicture?
        // A capture that found nothing falls back to the card's picture, which is not new.
        var pictureIsNew = false
        switch pictureChoice {
        case .none:
            picture = nil
        case .keepTheCardsPicture:
            picture = ideasThatWereOnTheCard?.picture
        case .captureAgain:
            let capturedPicture = await environment.captureThePicture()
            pictureIsNew = capturedPicture != nil
            picture = capturedPicture ?? ideasThatWereOnTheCard?.picture
            if picture == nil {
                environment.speak(Self.noPictureLine)
            }
        }
        guard !Task.isCancelled else { return }
        guard let themeIdeasRequest = ThemeIdeasRequest(
            request: requestText,
            currentIdeas: ideasThatWereOnTheCard?.ideas ?? [],
            basedOnIdea: basedOnIdea,
            picture: picture,
            pictureIsNew: pictureIsNew
        ) else {
            print("Theme studio: the request was empty")
            failTheDesign()
            return
        }

        let startedAt = Date()
        do {
            let reply = try await environment.designIdeas(themeIdeasRequest)
            guard !Task.isCancelled else { return }
            guard let arrivedIdeas = ThemeStudioIdeas(title: reply.title, ideas: reply.ideas, picture: picture) else {
                failTheDesign()
                return
            }
            print("Theme studio: designed \(reply.ideas.count) ideas in \(Int(Date().timeIntervalSince(startedAt))) s")
            // A card closed, or a design replaced, while the Worker worked cancelled this task, so the ideas here are the newest.
            state = state.withIdeasArrived(arrivedIdeas)
            ideasArrivalCount += 1
            showThePreview(of: arrivedIdeas)
            environment.speak(reply.spokenLine)
        } catch {
            if Task.isCancelled || errorIsACancellation(error) { return }
            print("Theme studio: the design failed after \(Int(Date().timeIntervalSince(startedAt))) s: \(error)")
            failTheDesign()
        }
    }

    private func failTheDesign() {
        let stateAfterTheFailure = state.afterTheDesignFailed()
        guard stateAfterTheFailure != state else { return }
        state = stateAfterTheFailure
        if case .showingIdeas(let ideas) = state {
            showsTheDesignFailedNotice = true
            showThePreview(of: ideas)
        } else {
            themeSettings.clearPreview()
        }
        environment.speak(Self.couldNotDesignLine)
    }

    // MARK: - Picking, saving, closing

    /// Highlights idea `ideaNumber`, counting from 1, and shows it on the real cursor. False when no such idea is on show.
    @discardableResult
    func pickIdea(number ideaNumber: Int) -> Bool {
        guard state.hasIdea(number: ideaNumber) else { return false }
        soundPreviewTask?.cancel()
        showsTheDesignFailedNotice = false
        state = state.pickingIdea(number: ideaNumber)
        if case .showingIdeas(let ideas) = state {
            showThePreview(of: ideas)
        }
        return true
    }

    /// Saves the highlighted idea, makes it the theme, closes the card, ends the line Clicky was saying about the ideas, and
    /// plays the theme's done sound once.
    func saveTheHighlightedIdea() -> SaveOutcome {
        guard case .showingIdeas(let ideas) = state else { return .nothingToSave }
        do {
            let savedTheme = try themeSettings.saveAndApply(ideas.highlightedIdea, pictureJPEG: ideas.picture?.jpegData)
            soundPreviewTask?.cancel()
            showsTheDesignFailedNotice = false
            closingReason = .saved(idea: ideas.highlightedIdea, pictureJPEG: ideas.picture?.jpegData)
            isStampingTheSavedIdea = true
            state = state.afterSaving()
            // The card is gone, so a line still describing its ideas would talk over the done sound.
            environment.stopSpeaking()
            environment.playSound(savedTheme.sounds.done)
            return .saved(themeName: savedTheme.name)
        } catch {
            print("Theme studio: saving \(ideas.highlightedIdea.name) failed: \(error)")
            return .failed
        }
    }

    /// Closes the card and keeps the old theme. A design that is still running is cancelled, and so is the line Clicky is
    /// saying about the ideas, since nothing is left on the card for it to describe.
    func close() {
        designTask?.cancel()
        designTask = nil
        soundPreviewTask?.cancel()
        soundPreviewTask = nil
        showsTheDesignFailedNotice = false
        state = state.closing()
        themeSettings.clearPreview()
        environment.stopSpeaking()
    }

    /// Escape closes an open studio before it does anything else. False when the studio is closed.
    func closeOnEscape() -> Bool {
        guard isOpen else { return false }
        close()
        return true
    }

    // MARK: - Sound preview

    /// Plays the highlighted idea's three sounds in a row, so the learner hears them before saving. A new preview, a pick, a
    /// new design, a save, and a close end one that is still playing.
    func playTheHighlightedIdeasSounds() {
        guard case .showingIdeas(let ideas) = state else { return }
        soundPreviewTask?.cancel()
        let previewSteps = themeSoundPreviewPlan(for: ideas.highlightedIdea, secondsBetweenSounds: secondsBetweenPreviewSounds)
        soundPreviewTask = Task {
            var secondsAlreadyWaited = 0.0
            for previewStep in previewSteps {
                let secondsToWait = previewStep.secondsAfterTheStart - secondsAlreadyWaited
                if secondsToWait > 0 {
                    try? await Task.sleep(for: .seconds(secondsToWait))
                }
                guard !Task.isCancelled else { return }
                secondsAlreadyWaited = previewStep.secondsAfterTheStart
                environment.playSound(previewStep.sound)
            }
        }
    }

    /// Returns when the sound preview that is playing has ended, so a test never waits a guessed time.
    func waitForTheSoundPreview() async {
        await soundPreviewTask?.value
    }

    private func showThePreview(of ideas: ThemeStudioIdeas) {
        themeSettings.preview(ideas.highlightedIdea, picture: ideas.picture.flatMap { NSImage(data: $0.jpegData) })
    }
}
