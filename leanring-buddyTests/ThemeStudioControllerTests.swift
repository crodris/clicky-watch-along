//
//  ThemeStudioControllerTests.swift
//  leanring-buddyTests
//
//  The studio controller with a stubbed Worker and a card that only records being shown: designing, the preview on the
//  real cursor, picking, refining, saving, closing, and a reply that arrives after the card is gone.
//

import AppKit
import Foundation
import SwiftUI
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

/// A drawing of a view: raw sRGB bytes, 4 for each pixel, in rows from the top. Reading each pixel through `colorAt`
/// holds the main actor for seconds.
struct DrawingPixels {
    let width: Int
    private(set) var height: Int
    let pixelsPerPoint: CGFloat
    private(set) var bytes: Data

    init(drawing image: CGImage, widthInPoints: CGFloat) throws {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        width = image.width
        height = image.height
        pixelsPerPoint = CGFloat(image.width) / widthInPoints
        bytes = Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }

    /// This drawing with clear rows added below it, up to `pixelHeight`. A drawing that is already taller keeps its
    /// height, so it never matches a shorter drawing.
    func withClearRowsBelow(upTo pixelHeight: Int) -> DrawingPixels {
        var taller = self
        taller.height = max(height, pixelHeight)
        taller.bytes.append(Data(count: (taller.height - height) * width * 4))
        return taller
    }

    /// Fails the test unless `other` is the size of this drawing, since a comparison reads the same pixel of each.
    func requireTheSameSize(as other: DrawingPixels) throws {
        try #require(
            other.width == width && other.height == height,
            "the drawings differ in size: \(width) by \(height) pixels and \(other.width) by \(other.height)"
        )
    }

    /// How many channels differ from those of `other`, a drawing of the same size, from the window's top edge down to
    /// `points`, or in the whole drawing. Two drawings of one state can round the Card's gradient and shadow a few levels
    /// apart, so those do not count. The scan runs off the main actor, which it would otherwise hold from every other test.
    func channelsThatDiffer(from other: DrawingPixels, downTo points: CGFloat? = nil) async throws -> Int {
        try requireTheSameSize(as: other)
        let byteCount = points.map { Int(max(0, $0) * pixelsPerPoint) * width * 4 } ?? bytes.count
        let (ownBytes, otherBytes) = (bytes.prefix(byteCount), other.bytes.prefix(byteCount))
        return await Task.detached {
            zip(ownBytes, otherBytes).count { abs(Int($0) - Int($1)) > 6 }
        }.value
    }
}

/// The card in a window off every screen that is never ordered front. The hosting view is the window's content, as in the
/// card's panel, so it grows the window as the card grows. `ImageRenderer` would draw the hover views as placeholders.
@MainActor
private final class OffscreenCard {
    private let window: NSWindow
    private let hostingView: NSHostingView<ThemeStudioCardView>
    var size: CGSize { hostingView.bounds.size }
    /// The height the card asks for, whatever size its window is.
    var fittingHeight: CGFloat { hostingView.fittingSize.height }

    init(studio: ThemeStudioController, size givenSize: CGSize? = nil) {
        hostingView = NSHostingView(rootView: ThemeStudioCardView(
            studio: studio, landsTilesIn: false, onSaveClicked: { _ in },
            onHighlightedCursorCenterChange: { _ in }, onContentSizeChange: { _ in }
        ))
        let size = givenSize ?? hostingView.fittingSize
        window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)
    }

    func draw() throws -> DrawingPixels {
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: hostingView.bounds.width)
    }

    func close() {
        window.close()
    }
}

/// The two changes that add or remove the failed design row, and so change the card's height.
enum ThemeStudioCardHeightChange: CaseIterable {
    case theDesignFails
    case aNewDesignStartsAfterAFailure
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

/// The card before a save and as the save leaves it, with the saved tile stamped, for ideas that all have `accentHex`.
@MainActor
func themeStudioCardDrawingsAroundASave(accentHex: String) async throws -> (beforeTheSave: DrawingPixels, stamped: DrawingPixels) {
    var drawings: (beforeTheSave: DrawingPixels, stamped: DrawingPixels)?
    // The save writes a theme, so it goes to a store of its own.
    try await withATemporaryThemeStore { store in
        let harness = StudioHarness(themeSettings: makeThemeSettings(customThemeStore: store))
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"], stillCursor: true, accentHex: accentHex) }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        let cardBeforeTheSave = OffscreenCard(studio: harness.studio)
        defer { cardBeforeTheSave.close() }
        let beforeTheSave = try cardBeforeTheSave.draw()
        _ = harness.studio.saveTheHighlightedIdea()
        try #require(harness.studio.isStampingTheSavedIdea)
        // A new card draws the stamp in place, with nothing to animate from.
        let stampedCard = OffscreenCard(studio: harness.studio, size: cardBeforeTheSave.size)
        defer { stampedCard.close() }
        drawings = (beforeTheSave, try stampedCard.draw())
    }
    return try #require(drawings)
}

private func reply(names: [String], spokenLine: String = "Here are three.", pictureCursor: Bool = false, stillCursor: Bool = false, accentHex: String? = nil) throws -> ThemeIdeasReply {
    let ideas = names.map { ideaName -> JSONValue in
        var idea = replacingField(in: pictureCursor ? goodPictureCursorThemeIdea : goodThemeIdea, at: ["name"], with: .string(ideaName))
        if let accentHex {
            idea = replacingField(in: idea, at: ["accent"], with: .string(accentHex))
        }
        // A cursor with no streaks and no thinking motion draws the same pixels at any moment.
        if stillCursor {
            idea = replacingField(in: idea, at: ["motion", "trailStreaks"], with: .number(0))
            idea = replacingField(in: idea, at: ["motion", "whileThinking"], with: .string("none"))
        }
        return idea
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
        #expect(harness.requestsSentToTheWorker[0].pictureIsNew)
        harness.studio.design(request: "tint it blue", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[1].picture == picture)
        #expect(!harness.requestsSentToTheWorker[1].pictureIsNew)
        harness.studio.design(request: "use this one instead", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[2].picture == picture)
        // The capture found nothing, so the card's picture went again, and it is not new.
        #expect(!harness.requestsSentToTheWorker[2].pictureIsNew)
        #expect(!harness.spokenLines.contains(ThemeStudioController.noPictureLine))
    }

    @Test func aChangeToAnIdeaThatSaysThisPictureAgainKeepsTheCircledPictureAndCapturesNothing() async throws {
        let circledLogo = try smallJPEGPicture()
        let largestPictureInTheTab = ThemeStudioPicture(jpegData: circledLogo.jpegData, width: 16, height: 16)
        let harness = StudioHarness()
        harness.picturesTheCaptureReturns = [circledLogo, largestPictureInTheTab]
        harness.workerReplies = [{ try reply(names: ["A", "B", "C"], pictureCursor: true) }, { try reply(names: ["A2", "B2", "C2"]) }]
        harness.studio.design(request: "make my theme from this picture", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        // The router may set fromPicture true for "turn the logo into a drawn cursor", with no new circle.
        let pictureChoice = themePictureChoice(
            requested: ThemeStudioPictureChoice(fromPictureInput: true),
            aRegionWasCircled: false,
            changesAnIdeaOnACardWithAPicture: true
        )
        harness.studio.design(request: "turn the logo into a drawn cursor", basedOnIdea: 1, pictureChoice: pictureChoice)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[1].picture == circledLogo)
        #expect(harness.requestsSentToTheWorker[1].basedOnIdea == 1)
        #expect(harness.requestsSentToTheWorker[1].currentIdeas.map(\.name) == ["A", "B", "C"])
        #expect(harness.picturesTheCaptureReturns == [largestPictureInTheTab])
    }

    @Test func aNewPictureOverAnOpenCardIsSentAsNewWithTheCardsIdeas() async throws {
        let picture = try smallJPEGPicture()
        let harness = StudioHarness()
        harness.picturesTheCaptureReturns = [picture]
        harness.workerReplies = [{ try reply(names: ["A", "B", "C"]) }, { try reply(names: ["A2", "B2", "C2"], pictureCursor: true) }]
        harness.studio.design(request: "something with stars", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        harness.studio.design(request: "make my theme from this picture", basedOnIdea: nil, pictureChoice: .captureAgain)
        await harness.studio.waitForTheDesign()
        #expect(harness.requestsSentToTheWorker[1].currentIdeas.map(\.name) == ["A", "B", "C"])
        #expect(harness.requestsSentToTheWorker[1].picture == picture)
        #expect(harness.requestsSentToTheWorker[1].pictureIsNew)
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
        // The save writes a theme, so it goes to a store of its own, never the one other tests read as empty.
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

    /// The notice is a row of the Card, not a Callout: a red-tinted fill across the Card's content with a red cross on it.
    @Test func theFailedNoticeIsARedTintedRowAcrossTheCard() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { throw WorkerFailure() }]
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        harness.studio.design(request: "more", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        await harness.studio.waitForTheDesign()

        let card = OffscreenCard(studio: harness.studio)
        defer { card.close() }
        let pixels = try card.draw()

        func channels(of color: Color) throws -> [Int] {
            let color = try #require(NSColor(color).usingColorSpace(.sRGB))
            return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
        }
        let tintChannels = try channels(of: DS.Colors.destructiveSurface)
        let crossChannels = try channels(of: DS.Colors.destructiveText)
        let (bytes, width, height) = (pixels.bytes, pixels.width, pixels.height)
        // The scan runs off the main actor, which it would otherwise hold from every other test.
        let scan = await Task.detached {
            func pixel(at offset: Int, isCloseTo expected: [Int]) -> Bool {
                (0..<3).allSatisfy { abs(Int(bytes[offset + $0]) - expected[$0]) < 8 }
            }
            var widestTintedRunInPixels = 0
            var redCrossPixels = 0
            for y in 0..<height {
                var tintedRunInPixels = 0
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    tintedRunInPixels = pixel(at: offset, isCloseTo: tintChannels) ? tintedRunInPixels + 1 : 0
                    widestTintedRunInPixels = max(widestTintedRunInPixels, tintedRunInPixels)
                    if pixel(at: offset, isCloseTo: crossChannels) { redCrossPixels += 1 }
                }
            }
            return (widestTintedRunInPixels: widestTintedRunInPixels, redCrossPixels: redCrossPixels, ranOnTheMainThread: pthread_main_np() != 0)
        }.value
        #expect(!scan.ranOnTheMainThread)
        // The row spans the Card inside its 14 point padding, less its own round ends.
        #expect(CGFloat(scan.widestTintedRunInPixels) / pixels.pixelsPerPoint > ThemeStudioPanelController.cardWidth - 28 - 20)
        #expect(scan.redCrossPixels > 5)
    }

    /// Changes the height of a card already on show, and draws its first frame after the change beside the same state drawn
    /// by a new card at its own fitting size, which has nothing to animate from. The first card's window grows with its
    /// card but does not shrink here, so the settled drawing gets clear rows down to the first frame's height. A first
    /// frame that is cut off stays shorter than the settled drawing.
    private func firstAndSettledFrames(after change: ThemeStudioCardHeightChange) async throws -> (first: DrawingPixels, settled: DrawingPixels) {
        let harness = StudioHarness()
        let gate = DesignGate()
        let ideas = { try reply(names: ["Ember", "Moonlit", "Forest"], stillCursor: true) }
        let heldFailure: () async throws -> ThemeIdeasReply = {
            await gate.wait()
            throw WorkerFailure()
        }
        harness.workerReplies = change == .theDesignFails ? [ideas, heldFailure] : [ideas, { throw WorkerFailure() }, heldFailure]
        func designAgain() {
            harness.studio.design(request: "more", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        }
        func letTheHeldDesignFail() async {
            await gate.waitUntilSomeoneIsWaiting()
            gate.open()
            await harness.studio.waitForTheDesign()
        }
        harness.studio.design(request: "cozy", basedOnIdea: nil, pictureChoice: .none)
        await harness.studio.waitForTheDesign()
        if change == .aNewDesignStartsAfterAFailure {
            designAgain()
            await harness.studio.waitForTheDesign()
        }

        let card = OffscreenCard(studio: harness.studio)
        defer { card.close() }
        _ = try card.draw()
        let firstFrame: DrawingPixels
        switch change {
        case .theDesignFails:
            designAgain()
            _ = try card.draw()
            await letTheHeldDesignFail()
            firstFrame = try card.draw()
        case .aNewDesignStartsAfterAFailure:
            designAgain()
            firstFrame = try card.draw()
        }
        let settledCard = OffscreenCard(studio: harness.studio)
        defer { settledCard.close() }
        let settledDrawing = try settledCard.draw()
        // A cut off reference would match a first frame that is cut off the same way. It is measured before the held design
        // fails, which changes the card's height.
        let settledCardIsWhole = CGFloat(settledDrawing.height) == settledCard.fittingHeight * settledDrawing.pixelsPerPoint
        // The held design is let go before the check can throw, so it never runs against a released harness.
        if change == .aNewDesignStartsAfterAFailure {
            await letTheHeldDesignFail()
        }
        try #require(settledCardIsWhole, "the settled card is cut off")
        let settledFrame = settledDrawing.withClearRowsBelow(upTo: firstFrame.height)
        return (firstFrame, settledFrame)
    }

    /// An animated height change slid the card down its window and left the outgoing "Designing…" behind, cut off at the
    /// card's top edge.
    @Test(arguments: ThemeStudioCardHeightChange.allCases)
    func theHeaderStaysInsideTheCardWhenItsHeightChanges(_ change: ThemeStudioCardHeightChange) async throws {
        let frames = try await firstAndSettledFrames(after: change)
        // The window's margin, the card's 14 point padding, and the header's one line of text.
        let headerBottom = AgentListWindowMargins.top + 14 + 16
        #expect(try await frames.first.channelsThatDiffer(from: frames.settled, downTo: headerBottom) == 0)
    }

    /// An animated height change put the failed design row at its final place while the hint and Save were still on their way
    /// down, so they drew over each other.
    @Test(arguments: ThemeStudioCardHeightChange.allCases)
    func nothingDrawsOverAnythingElseWhenTheCardsHeightChanges(_ change: ThemeStudioCardHeightChange) async throws {
        let frames = try await firstAndSettledFrames(after: change)
        #expect(frames.first.height == frames.settled.height)
        #expect(try await frames.first.channelsThatDiffer(from: frames.settled) == 0)
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

@MainActor
struct ThemeStudioCardGlideInCloseTests {
    @Test(.showsARealWindow, .enabled(if: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "the card Glides only with Reduce Motion off"))
    func aCardClosedDuringItsGlideInShowsNothingWhole() throws {
        let harness = StudioHarness()
        let cardPanel = ThemeStudioPanelController(onSaveClicked: { _ in })
        cardPanel.show(studio: harness.studio)
        let glideIn = try #require(cardPanel.openingFlight, "the card should Glide out of the cursor")
        #expect(!glideIn.carriedViewIsHidden)
        // Escape before the Glide lands. The carried copy would otherwise rest whole for 0.05 seconds over the closing card.
        cardPanel.hide(because: .dismissed)
        #expect(glideIn.carriedViewIsHidden)
        #expect(cardPanel.openingFlight == nil)
    }

    /// A design from a picture raises the real card above the cursor overlay while it runs, and a refine that keeps the
    /// card's picture, which draws no loop, leaves it below, so the previewed cursor still draws over the card.
    @Test(.showsARealWindow)
    func theCardRisesOnlyWhileADesignThatReadsThePictureRuns() async throws {
        let harness = StudioHarness()
        harness.workerReplies = [{ try reply(names: ["Ember", "Moonlit", "Forest"]) }, { try reply(names: ["Ember", "Dusk", "Fern"]) }]
        var theDesignReadsAPicture = true
        let cardPanel = ThemeStudioPanelController(
            pictureTheLoopIsAround: { theDesignReadsAPicture ? CGRect(x: 200, y: 300, width: 600, height: 400) : nil },
            onSaveClicked: { _ in }
        )
        let cursorOverlayLevel = NSWindow.Level.screenSaver.rawValue + 1

        harness.studio.design(request: "a theme from this picture", basedOnIdea: nil, pictureChoice: .none)
        cardPanel.show(studio: harness.studio)
        #expect(try #require(cardPanel.windowLevel).rawValue > cursorOverlayLevel)
        await harness.studio.waitForTheDesign()
        #expect(try #require(cardPanel.windowLevel).rawValue < cursorOverlayLevel)

        theDesignReadsAPicture = false
        harness.studio.design(request: "make it round", basedOnIdea: 1, pictureChoice: .keepTheCardsPicture)
        #expect(harness.studio.state.isDesigning)
        #expect(try #require(cardPanel.windowLevel).rawValue < cursorOverlayLevel)
        await harness.studio.waitForTheDesign()
        cardPanel.hide(because: .dismissed)
    }
}
