//
//  ThemeStudioControllerTests.swift
//  leanring-buddyTests
//
//  The studio controller with a stubbed Worker and a card that only records being shown: designing, the preview on the
//  real cursor, picking, refining, saving, closing, and a reply that arrives after the card is gone.
//

import AppKit
import Foundation
import Testing
@testable import Clicky

@MainActor
private final class RecordingCardPresenter: ThemeStudioCardPresenting {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    func show(studio: ThemeStudioController) { showCount += 1 }
    var lastClosingReason: ThemeStudioCardClosing?
    func hide(because reason: ThemeStudioCardClosing) {
        hideCount += 1
        lastClosingReason = reason
    }
}

/// Holds a stubbed Worker call until the test lets it go, so a test can act while a design is still running.
@MainActor
private final class DesignGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }

    func waitUntilSomeoneIsWaiting() async {
        while !isWaiting { await Task.yield() }
    }
}

@MainActor
private final class StudioHarness {
    let themeSettings: CompanionThemeSettings
    let presenter = RecordingCardPresenter()
    var spokenLines: [String] = []
    /// Whether the card's failed notice was already up as each line was spoken, which the app reads to leave out a chip that would repeat it.
    var failedNoticeWasShowingWhenSpoken: [Bool] = []
    private(set) var stopSpeakingCount = 0
    var playedSounds: [ThemeSound] = []
    var requestsSentToTheWorker: [ThemeIdeasRequest] = []
    var picturesTheCaptureReturns: [ThemeStudioPicture?] = []
    /// What the stubbed Worker does for each call, in order. A call past the end fails.
    var workerReplies: [() async throws -> ThemeIdeasReply] = []
    private(set) var studio: ThemeStudioController!

    init(themeSettings suppliedThemeSettings: CompanionThemeSettings? = nil, secondsBetweenPreviewSounds: Double = 0) {
        themeSettings = suppliedThemeSettings ?? makeThemeSettings()
        studio = ThemeStudioController(
            themeSettings: themeSettings,
            environment: ThemeStudioController.Environment(
                speak: { [unowned self] line in
                    self.spokenLines.append(line)
                    self.failedNoticeWasShowingWhenSpoken.append(self.studio.showsTheDesignFailedNotice)
                },
                stopSpeaking: { [unowned self] in self.stopSpeakingCount += 1 },
                playSound: { [unowned self] sound in self.playedSounds.append(sound) },
                captureThePicture: { [unowned self] in self.picturesTheCaptureReturns.isEmpty ? nil : self.picturesTheCaptureReturns.removeFirst() },
                designIdeas: { [unowned self] request in
                    self.requestsSentToTheWorker.append(request)
                    guard !self.workerReplies.isEmpty else { throw URLError(.cannotConnectToHost) }
                    return try await self.workerReplies.removeFirst()()
                }
            ),
            cardPresenter: presenter,
            secondsBetweenPreviewSounds: secondsBetweenPreviewSounds
        )
    }
}

private struct WorkerFailure: Error {}

private func reply(names: [String], spokenLine: String = "Here are three.", pictureCursor: Bool = false) throws -> ThemeIdeasReply {
    let ideas = names.map { ideaName -> JSONValue in
        replacingField(in: pictureCursor ? goodPictureCursorThemeIdea : goodThemeIdea, at: ["name"], with: .string(ideaName))
    }
    let body = JSONValue.object(["title": .string("Ideas"), "spokenLine": .string(spokenLine), "ideas": .array(ideas)])
    return try ThemeIdeasReply(responseData: Data(body.compactJSONText.utf8), pictureWasSent: pictureCursor)
}

/// A real 8 by 8 JPEG, since the preview decodes the picture into an image.
private func smallJPEGPicture() throws -> ThemeStudioPicture {
    let bitmap = try #require(NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ))
    let jpegData = try #require(bitmap.representation(using: .jpeg, properties: [:]))
    return ThemeStudioPicture(jpegData: jpegData, width: 8, height: 8)
}

@MainActor
struct ThemeStudioControllerTests {
    @Test func designingOpensTheCardAndTheIdeasShowOnTheRealCursorWithTheSpokenLine() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"], spokenLine: "Here are three. Say one, two, or three.") }]

        harness.studio.design(request: "something cozy for night", basedOnIdea: nil, pictureChoice: .none)
        #expect(harness.studio.state == .designing(previousIdeas: nil))
        #expect(harness.presenter.showCount == 1)
        // Nothing is spoken and nothing previews while the Worker works.
        #expect(harness.spokenLines.isEmpty)
        #expect(harness.themeSettings.previewTheme == nil)

        await harness.studio.waitForTheDesign()
        guard case .showingIdeas(let ideas) = harness.studio.state else {
            Issue.record("expected ideas on show, got \(harness.studio.state)")
            return
        }
        #expect(ideas.ideas.map(\.name) == ["Ember", "Moonlit", "Forest"])
        #expect(harness.themeSettings.shownTheme == ideas.ideas[0])
        #expect(harness.spokenLines == ["Here are three. Say one, two, or three."])
        #expect(harness.requestsSentToTheWorker.map(\.request) == ["something cozy for night"])
        #expect(harness.requestsSentToTheWorker[0].currentIdeas.isEmpty)
    }

    @Test func aFailedFirstDesignClosesTheCardAndSaysSo() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.state == .closed)
        #expect(harness.presenter.hideCount == 1)
        #expect(harness.spokenLines == [ThemeStudioController.couldNotDesignLine])
        #expect(harness.themeSettings.previewTheme == nil)
    }

    @Test func aFailedRefinementGoesBackToTheIdeasThatWereOnTheCard() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        guard case .showingIdeas(let firstIdeas) = harness.studio.state else { Issue.record("no ideas"); return }
        harness.studio.pickIdea(number: 2)
        harness.spokenLines.removeAll()

        harness.studio.design(request: "make it a star", basedOnIdea: 2, pictureChoice: .keepTheCardsPicture)
        guard case .designing(let dimmedIdeas?) = harness.studio.state else { Issue.record("not designing"); return }
        #expect(dimmedIdeas.ideas == firstIdeas.ideas)
        #expect(dimmedIdeas.highlightedIdeaIndex == 1)
        await harness.studio.waitForTheDesign()

        guard case .showingIdeas(let backIdeas) = harness.studio.state else { Issue.record("no ideas after the failure"); return }
        #expect(backIdeas.ideas == firstIdeas.ideas)
        #expect(backIdeas.highlightedIdeaIndex == 1)
        #expect(harness.themeSettings.shownTheme == firstIdeas.ideas[1])
        #expect(harness.spokenLines == [ThemeStudioController.couldNotDesignLine])
        #expect(harness.presenter.showCount == 1)
        #expect(harness.presenter.hideCount == 0)
    }

    @Test func aRefinementSendsTheIdeasOnTheCardAndWhichOneToChange() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { try reply(names: ["Moonlit star", "Two", "Three"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        harness.studio.design(request: "make the cursor a star", basedOnIdea: 2, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()

        let refinement = harness.requestsSentToTheWorker[1]
        #expect(refinement.currentIdeas.map(\.name) == ["Ember", "Moonlit", "Forest"])
        #expect(refinement.basedOnIdea == 2)
        guard case .showingIdeas(let ideas) = harness.studio.state else { Issue.record("no ideas"); return }
        #expect(ideas.ideas.map(\.name) == ["Moonlit star", "Two", "Three"])
        // The new ideas start with the first highlighted.
        #expect(ideas.highlightedIdeaIndex == 0)
        #expect(harness.themeSettings.shownTheme == ideas.ideas[0])
    }

    @Test func pickingAnIdeaPutsItOnTheCursorAndANumberWithNoIdeaDoesNothing() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        guard case .showingIdeas(let ideas) = harness.studio.state else { Issue.record("no ideas"); return }

        #expect(harness.studio.pickIdea(number: 3))
        #expect(harness.themeSettings.shownTheme == ideas.ideas[2])
        #expect(!harness.studio.pickIdea(number: 4))
        #expect(!harness.studio.pickIdea(number: 0))
        #expect(harness.themeSettings.shownTheme == ideas.ideas[2])
    }

    @Test func nothingCanBePickedOrSavedWhileTheFirstIdeasAreStillComing() async throws {
        let gate = DesignGate()
        let harness = StudioHarness()
        harness.workerReplies = [{ await gate.wait(); return try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await gate.waitUntilSomeoneIsWaiting()

        #expect(!harness.studio.pickIdea(number: 1))
        #expect(harness.studio.saveTheHighlightedIdea() == .nothingToSave)
        // Nothing was saved and the card stays open, so no line is cut.
        #expect(harness.stopSpeakingCount == 0)
        gate.open()
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.state.isShowingIdeas)
    }

    @Test func savingMakesTheHighlightedIdeaTheThemeWritesItAndClosesTheCard() async throws {
        try await withATemporaryThemeStore { store in
            let harness = StudioHarness(themeSettings: makeThemeSettings(customThemeStore: store))
            harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
            harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
            await harness.studio.waitForTheDesign()
            harness.studio.pickIdea(number: 2)
            #expect(harness.stopSpeakingCount == 0)

            #expect(harness.studio.saveTheHighlightedIdea() == .saved(themeName: "Moonlit"))
            #expect(harness.studio.state == .closed)
            // The card is gone, so the line about its ideas stops, as it does when the card is closed.
            #expect(harness.stopSpeakingCount == 1)
            #expect(harness.presenter.hideCount == 1)
            #expect(harness.themeSettings.previewTheme == nil)
            let savedTheme = harness.themeSettings.theme
            guard case .saved = savedTheme.origin else { Issue.record("not a saved theme"); return }
            #expect(savedTheme.name == "Moonlit")
            #expect(harness.playedSounds == [savedTheme.sounds.done])
            #expect(savedTheme.id.hasPrefix("moonlit-"))
            #expect(store.loadSavedThemes().map(\.theme) == [savedTheme])
        }
    }

    @Test func aThemeThatUsesThePictureIsSavedWithItBesideIt() async throws {
        let picture = try smallJPEGPicture()
        try await withATemporaryThemeStore { store in
            let harness = StudioHarness(themeSettings: makeThemeSettings(customThemeStore: store))
            harness.picturesTheCaptureReturns = [picture]
            harness.workerReplies = [{ try reply(names: ["Photo", "Two", "Three"], pictureCursor: true) }]
            harness.studio.design(request: "make my theme from this picture", basedOnIdea: nil, pictureChoice: .captureAgain)
            await harness.studio.waitForTheDesign()
            #expect(harness.requestsSentToTheWorker[0].picture == picture)
            // The preview shows the picture before anything is saved.
            #expect(harness.themeSettings.shownThemePicture != nil)

            guard case .saved = harness.studio.saveTheHighlightedIdea(), case .saved = harness.themeSettings.theme.origin else {
                Issue.record("not saved")
                return
            }
            let savedTheme = harness.themeSettings.theme
            let savedPictureData = try Data(contentsOf: store.pictureURL(forThemeID: savedTheme.id))
            #expect(savedPictureData == picture.jpegData)
            #expect(savedTheme.usesPicture)
        }
    }

    @Test func aRequestFromAPictureWithNoPictureToCaptureSaysSoAndDesignsFromTheWords() async throws {
        let harness = StudioHarness()
        harness.picturesTheCaptureReturns = [nil]
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "make my theme from this picture", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        #expect(harness.spokenLines.first == ThemeStudioController.noPictureLine)
        #expect(harness.requestsSentToTheWorker[0].picture == nil)
        #expect(harness.studio.state.isShowingIdeas)
    }

    @Test func aRefinementKeepsTheCardsPictureAndACaptureThatFindsNothingFallsBackToIt() async throws {
        let picture = try smallJPEGPicture()
        let harness = StudioHarness()
        harness.picturesTheCaptureReturns = [picture, nil]
        harness.workerReplies = [{ try reply(names: ["A", "B", "C"], pictureCursor: true) }, { try reply(names: ["A2", "B2", "C2"], pictureCursor: true) }, { try reply(names: ["A3", "B3", "C3"], pictureCursor: true) }]
        harness.studio.design(request: "from this picture", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        harness.studio.design(request: "tint it blue", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[1].picture == picture)
        harness.studio.design(request: "use this one instead", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[2].picture == picture)
        #expect(!harness.spokenLines.contains(ThemeStudioController.noPictureLine))
    }

    @Test func aPictureChoiceOfNoneDropsThePictureFromARefinement() async throws {
        let picture = try smallJPEGPicture()
        let harness = StudioHarness()
        harness.picturesTheCaptureReturns = [picture]
        harness.workerReplies = [{ try reply(names: ["A", "B", "C"], pictureCursor: true) }, { try reply(names: ["A2", "B2", "C2"]) }]
        harness.studio.design(request: "from this picture", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        harness.studio.design(request: "forget the picture, go green", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[1].picture == nil)
    }

    @Test func closingKeepsTheOldThemeAndEndsThePreview() async throws {
        let harness = StudioHarness(themeSettings: makeThemeSettings(startingWith: bundledTheme("school-nekoma")))
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()

        harness.studio.close()
        #expect(harness.studio.state == .closed)
        #expect(harness.themeSettings.theme == bundledTheme("school-nekoma"))
        #expect(harness.themeSettings.shownTheme == bundledTheme("school-nekoma"))
        #expect(harness.presenter.hideCount == 1)
    }

    @Test func escapeClosesAnOpenStudioAndLeavesAClosedOneToTheRestOfEscape() async throws {
        let harness = StudioHarness()
        #expect(!harness.studio.closeOnEscape())
        #expect(harness.stopSpeakingCount == 0)
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.closeOnEscape())
        #expect(harness.studio.state == .closed)
    }

    @Test func closingTheCardStopsTheLineClickyIsSayingAboutItsIdeas() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.spokenLines.count == 1)
        #expect(harness.stopSpeakingCount == 0)

        harness.studio.close()
        #expect(harness.stopSpeakingCount == 1)

        // Escape closes through the same path, so it stops the line too.
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy again", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.closeOnEscape())
        #expect(harness.stopSpeakingCount == 2)
    }

    @Test func ideasThatArriveAfterTheCardWasClosedAreDroppedAndNothingIsSpoken() async throws {
        let gate = DesignGate()
        let harness = StudioHarness()
        harness.workerReplies = [{ await gate.wait(); return try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await gate.waitUntilSomeoneIsWaiting()

        harness.studio.close()
        gate.open()
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.state == .closed)
        #expect(harness.themeSettings.previewTheme == nil)
        #expect(harness.spokenLines.isEmpty)
    }

    @Test func aNewDesignReplacesOneStillRunningSoOnlyTheNewestIdeasArrive() async throws {
        let firstGate = DesignGate()
        let harness = StudioHarness()
        harness.workerReplies = [
            { await firstGate.wait(); return try reply(names: ["Old one", "Old two", "Old three"], spokenLine: "Old line.") },
            { try reply(names: ["New one", "New two", "New three"], spokenLine: "New line.") },
        ]
        harness.studio.design(request: "first", basedOnIdea: nil, pictureChoice: .none)
        await firstGate.waitUntilSomeoneIsWaiting()
        harness.studio.design(request: "second", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        firstGate.open()
        // Let the cancelled first design run to its end.
        for _ in 0..<20 { await Task.yield() }

        guard case .showingIdeas(let ideas) = harness.studio.state else { Issue.record("no ideas"); return }
        #expect(ideas.ideas.map(\.name) == ["New one", "New two", "New three"])
        #expect(harness.spokenLines == ["New line."])
        #expect(harness.presenter.showCount == 1)
    }
}

// MARK: - Tether: sound preview, the stamp, the failed notice, and how the card closes

@MainActor
struct ThemeStudioTetherTests {
    @Test func theSoundPreviewPlansTheDoneCorrectAndNeedsYourOKSoundsInARow() {
        let idea = try! reply(names: ["Sample"]).ideas[0]
        let plan = themeSoundPreviewPlan(for: idea, secondsBetweenSounds: 0.7)
        #expect(plan.map(\.sound) == [idea.sounds.done, idea.sounds.correct, idea.sounds.needsYourOK])
        #expect(plan.map(\.secondsAfterTheStart) == [0, 0.7, 1.4])
    }

    @Test func thePreviewPlaysTheHighlightedIdeasThreeSoundsInOrderAndOnlyWhileIdeasShow() async throws {
        let harness = StudioHarness()
        // Nothing plays before ideas show.
        harness.studio.playTheHighlightedIdeasSounds()
        await harness.studio.waitForTheSoundPreview()
        #expect(harness.playedSounds.isEmpty)

        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        guard case .showingIdeas(let ideas) = harness.studio.state else { Issue.record("no ideas"); return }
        harness.studio.playTheHighlightedIdeasSounds()
        await harness.studio.waitForTheSoundPreview()
        let sounds = ideas.highlightedIdea.sounds
        #expect(harness.playedSounds == [sounds.done, sounds.correct, sounds.needsYourOK])
    }

    @Test func aNewDesignStopsASoundPreviewThatIsStillPlaying() async throws {
        let harness = StudioHarness(secondsBetweenPreviewSounds: 30)
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        harness.studio.playTheHighlightedIdeasSounds()
        // The first sound plays at once, and the second is 30 seconds away.
        while harness.playedSounds.isEmpty { await Task.yield() }
        // A new design ends the preview before its first ideas arrive, so the sounds never play over the new ones.
        harness.studio.design(request: "more", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheSoundPreview()
        #expect(harness.playedSounds.count == 1)
        await harness.studio.waitForTheDesign()
    }

    @Test func aSaveClosesTheCardForASaveAndStampsTheTile() async throws {
        try await withATemporaryThemeStore { store in
            let harness = StudioHarness(themeSettings: makeThemeSettings(customThemeStore: store))
            harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
            harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
            await harness.studio.waitForTheDesign()
            guard case .showingIdeas(let ideas) = harness.studio.state else { Issue.record("no ideas"); return }
            #expect(!harness.studio.isStampingTheSavedIdea)

            #expect(harness.studio.saveTheHighlightedIdea() == .saved(themeName: ideas.highlightedIdea.name))
            #expect(harness.studio.isStampingTheSavedIdea)
            #expect(harness.presenter.lastClosingReason == .saved(idea: ideas.highlightedIdea, pictureJPEG: nil))
            // The card draws its last open state while it closes on the carrier.
            #expect(harness.studio.lastOpenState == .showingIdeas(ideas))
        }
    }

    @Test func everyCloseThatIsNotASaveClosesTheCardAsDismissed() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        harness.studio.close()
        #expect(harness.presenter.lastClosingReason == .dismissed)
        #expect(!harness.studio.isStampingTheSavedIdea)
    }

    @Test func aFailedRefinementShowsTheFailedNoticeUntilTheNextPickOrDesign() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { throw WorkerFailure() }, { try reply(names: ["A", "B", "C"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(!harness.studio.showsTheDesignFailedNotice)

        harness.studio.design(request: "more", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.showsTheDesignFailedNotice)
        harness.studio.pickIdea(number: 2)
        #expect(!harness.studio.showsTheDesignFailedNotice)
    }

    @Test func theFailedNoticeIsUpBeforeTheFailureLineIsSpokenSoTheChipCanLeaveItOut() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        harness.spokenLines.removeAll()
        harness.failedNoticeWasShowingWhenSpoken.removeAll()
        harness.studio.design(request: "more", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()
        #expect(harness.spokenLines == [ThemeStudioController.couldNotDesignLine])
        #expect(harness.failedNoticeWasShowingWhenSpoken == [true])
    }

    @Test func aFirstDesignThatFailsSpeaksTheFailureLineWithNoNoticeSoTheChipShows() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.spokenLines == [ThemeStudioController.couldNotDesignLine])
        #expect(harness.failedNoticeWasShowingWhenSpoken == [false])
    }

    @Test func aFirstDesignThatFailsClosesTheCardWithNoNotice() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.state == .closed)
        #expect(!harness.studio.showsTheDesignFailedNotice)
    }

    @Test func eachArrivalOfIdeasCountsSoTheTilesLandAgain() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { try reply(names: ["A", "B", "C"]) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.ideasArrivalCount == 1)
        harness.studio.design(request: "again", basedOnIdea: nil, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()
        #expect(harness.studio.ideasArrivalCount == 2)
    }
}
