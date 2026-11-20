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

/// Shows and hides the card. The real one is the panel next to the cursor, and a test swaps in one that records the calls,
/// since a test process has no window to show.
@MainActor
protocol ThemeStudioCardPresenting: AnyObject {
    func show(studio: ThemeStudioController)
    func hide()
}

extension ThemeStudioPanelController: ThemeStudioCardPresenting {}

@MainActor
final class ThemeStudioController: ObservableObject {
    /// What the studio needs from the rest of the app, supplied by CompanionManager.
    struct Environment {
        /// Says a line aloud.
        let speak: (String) -> Void
        /// A JPEG of the largest picture in Chrome's front tab, or nil when there is none.
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
            if state.isOpen && !oldValue.isOpen {
                cardPresenter.show(studio: self)
            } else if !state.isOpen && oldValue.isOpen {
                cardPresenter.hide()
            }
        }
    }

    private let themeSettings: CompanionThemeSettings
    private let environment: Environment
    private let cardPresenter: ThemeStudioCardPresenting
    private var designTask: Task<Void, Never>?

    init(themeSettings: CompanionThemeSettings, environment: Environment, cardPresenter: ThemeStudioCardPresenting) {
        self.themeSettings = themeSettings
        self.environment = environment
        self.cardPresenter = cardPresenter
    }

    var isOpen: Bool { state.isOpen }

    // MARK: - Designing

    /// Opens the card, or dims the ideas on it, and asks the Worker for three new ideas. It returns at once. A design that is
    /// still running is cancelled, so only the newest one's ideas arrive. `basedOnIdea` counts from 1.
    func design(request requestText: String, basedOnIdea: Int?, pictureChoice: ThemeStudioPictureChoice) {
        designTask?.cancel()
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
        switch pictureChoice {
        case .none:
            picture = nil
        case .keepTheCardsPicture:
            picture = ideasThatWereOnTheCard?.picture
        case .captureAgain:
            picture = await environment.captureThePicture() ?? ideasThatWereOnTheCard?.picture
            if picture == nil {
                environment.speak(Self.noPictureLine)
            }
        }
        guard !Task.isCancelled else { return }
        guard let themeIdeasRequest = ThemeIdeasRequest(
            request: requestText,
            currentIdeas: ideasThatWereOnTheCard?.ideas ?? [],
            basedOnIdea: basedOnIdea,
            picture: picture
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
            let stateWithIdeas = state.withIdeasArrived(arrivedIdeas)
            // The learner closed the card while the Worker worked, so there is nothing to show or say.
            guard stateWithIdeas != state else { return }
            state = stateWithIdeas
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
        state = state.pickingIdea(number: ideaNumber)
        if case .showingIdeas(let ideas) = state {
            showThePreview(of: ideas)
        }
        return true
    }

    /// Saves the highlighted idea, makes it the theme, closes the card, and plays the theme's done sound once.
    func saveTheHighlightedIdea() -> SaveOutcome {
        guard case .showingIdeas(let ideas) = state else { return .nothingToSave }
        do {
            let savedTheme = try themeSettings.saveAndApply(ideas.highlightedIdea, pictureJPEG: ideas.picture?.jpegData)
            state = state.afterSaving()
            savedTheme.sounds.done.play()
            return .saved(themeName: savedTheme.name)
        } catch {
            print("Theme studio: saving \(ideas.highlightedIdea.name) failed: \(error)")
            return .failed
        }
    }

    /// Closes the card and keeps the old theme. A design that is still running is cancelled.
    func close() {
        designTask?.cancel()
        designTask = nil
        state = state.closing()
        themeSettings.clearPreview()
    }

    /// Escape closes an open studio before it does anything else. False when the studio is closed.
    func closeOnEscape() -> Bool {
        guard isOpen else { return false }
        close()
        return true
    }

    private func showThePreview(of ideas: ThemeStudioIdeas) {
        themeSettings.preview(ideas.highlightedIdea, picture: ideas.picture.flatMap { NSImage(data: $0.jpegData) })
    }
}
