//
//  VideoRecapTests.swift
//  leanring-buddyTests
//
//  The end-of-video recap: what its lines say and where they come from, when a video counts as ended, when the watch shows
//  the recap and when it stays quiet, the Card at 2x with the recap's sections, and the discs gathering at the cursor.
//

import AppKit
import CoreServices
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct VideoRecapTests {
    private let videoURL = "https://www.youtube.com/watch?v=L24Wf0VlTE0"

    private func quizResult(_ question: String, at askedAtSeconds: Double, _ outcome: StudyGuideQuizOutcome, explanation: String = "Lava rises through it.") -> StudyGuideQuizResult {
        StudyGuideQuizResult(question: question, answerLabel: "vent", explanation: explanation, askedAtSeconds: askedAtSeconds, result: outcome)
    }

    private func studyGuide(summary: String?, pageURL: String = "https://www.notion.so/p1") throws -> StudyGuideRecord {
        var guideFields: [String: JSONValue] = ["title": .string("How Volcanoes Work")]
        if let summary { guideFields["summary"] = .string(summary) }
        return StudyGuideRecord(pageHandle: "handle", pageURL: try #require(URL(string: pageURL)), guide: .object(guideFields))
    }

    // MARK: - What the recap says

    @Test func aVideoWithNoQuizAndNoGuideHasNoRecap() {
        #expect(VideoRecap(quizResults: [], studyGuideRecord: nil) == nil)
    }

    @Test func theGuidesSummaryComesFirstThenTheExplanationsOfTheAnswersGotRightInVideoOrder() throws {
        let recap = try #require(VideoRecap(
            quizResults: [
                quizResult("B?", at: 200, .gotIt, explanation: "The chamber holds the magma."),
                quizResult("A?", at: 40, .gotIt, explanation: "The vent lets lava out."),
                quizResult("C?", at: 300, .missed, explanation: "Never shown, since it was missed."),
            ],
            studyGuideRecord: try studyGuide(summary: "Volcanoes move magma from deep underground to the surface.")
        ))
        #expect(recap.learnedLines == [
            "Volcanoes move magma from deep underground to the surface.",
            "The vent lets lava out.",
            "The chamber holds the magma.",
        ])
        #expect(recap.summary?.scoreText == "2 of 3 right")
    }

    @Test func withNoGuideTheLearnedLinesAreTheRightAnswersAloneAndMissesAreNeverLearned() throws {
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 40, .missed), quizResult("B?", at: 90, .skipped)], studyGuideRecord: nil))
        #expect(recap.learnedLines.isEmpty)
        #expect(recap.studyGuideURL == nil)
    }

    @Test func atMostThreeLinesShowAndARepeatedLineShowsOnce() throws {
        let recap = try #require(VideoRecap(
            quizResults: [
                quizResult("A?", at: 10, .gotIt, explanation: "One."),
                quizResult("B?", at: 20, .gotIt, explanation: "One."),
                quizResult("C?", at: 30, .gotIt, explanation: "Two."),
                quizResult("D?", at: 40, .gotIt, explanation: "Three."),
                quizResult("E?", at: 50, .gotIt, explanation: "Four."),
            ],
            studyGuideRecord: nil
        ))
        #expect(recap.learnedLines == ["One.", "Two.", "Three."])
    }

    @Test func aGuideOnlyRecapHasNoScoreAndTheVideoDoneTitle() throws {
        let recap = try #require(VideoRecap(quizResults: [], studyGuideRecord: try studyGuide(summary: "A short summary.")))
        #expect(recap.summary == nil)
        #expect(recap.title(when: .videoEnded) == "Video done")
        #expect(recap.title(when: .quizEnded) == "Video done")
        #expect(recap.studyGuideURL == URL(string: "https://www.notion.so/p1"))
    }

    @Test func aQuizRecapIsTitledByWhatEndedIt() throws {
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        #expect(recap.title(when: .quizEnded) == "Quiz done")
        #expect(recap.title(when: .videoEnded) == "Video done")
    }

    @Test func theStudyGuideLinkIsKeptOnlyForAnHTTPSPageOnNotion() throws {
        let notionGuide = try studyGuide(summary: nil)
        #expect(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: notionGuide)?.studyGuideURL != nil)
        let otherSiteGuide = try studyGuide(summary: nil, pageURL: "https://example.com/page")
        #expect(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: otherSiteGuide)?.studyGuideURL == nil)
        let fileGuide = try studyGuide(summary: nil, pageURL: "file:///etc/passwd")
        #expect(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: fileGuide)?.studyGuideURL == nil)
    }

    @Test func aLongLineIsCutAtAWordWithAnEllipsisAndWhitespaceCollapses() {
        #expect(recapLine("  The vent \n lets   lava out. ") == "The vent lets lava out.")
        let longLine = Array(repeating: "lava", count: 60).joined(separator: " ")
        let cutLine = recapLine(longLine)
        #expect(cutLine.count <= VideoRecap.longestLearnedLine)
        #expect(cutLine.hasSuffix("lava…"))
        // A word longer than the limit is cut inside the word rather than dropped.
        #expect(recapLine(String(repeating: "x", count: 300)).count == VideoRecap.longestLearnedLine)
    }

    // MARK: - When a video has ended

    @Test func thePageScriptsReplyIsReadAsEndedOrNotAndKeepsABarInTheAddress() throws {
        let ended = try #require(FrontVideoEndReading(scriptReply: "1|\(videoURL)"))
        #expect(ended.hasEnded && ended.pageURL == videoURL)
        let playing = try #require(FrontVideoEndReading(scriptReply: "0|https://example.com/watch?q=a|b"))
        #expect(!playing.hasEnded && playing.pageURL == "https://example.com/watch?q=a|b")
        #expect(FrontVideoEndReading(scriptReply: "no-video") == nil)
        #expect(FrontVideoEndReading(scriptReply: "") == nil)
        #expect(FrontVideoEndReading(scriptReply: "2|https://example.com") == nil)
        #expect(FrontVideoEndReading(scriptReply: "1|") == nil)
    }

    @Test func theRecapReadsAskChromeForItsFrontTabByChromesOwnCodes() throws {
        let urlEvent = ChromeFrontTabAppleEvents.frontTabURLEvent()
        #expect(urlEvent.eventClass == AEEventClass(kAECoreSuite) && urlEvent.eventID == AEEventID(kAEGetData))
        let address = try #require(urlEvent.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        #expect(address.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == ChromeFrontTabAppleEvents.fourCharacterCode("URL "))
        let activeTab = try #require(address.forKeyword(AEKeyword(keyAEContainer)))
        #expect(activeTab.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue == ChromeFrontTabAppleEvents.fourCharacterCode("acTa"))
        #expect(activeTab.forKeyword(AEKeyword(keyAEContainer))?.forKeyword(AEKeyword(keyAEDesiredClass))?.typeCodeValue == ChromeFrontTabAppleEvents.fourCharacterCode("cwin"))

        let scriptEvent = ChromeFrontTabAppleEvents.runJavaScriptInTheFrontTabEvent(FrontVideoEndReading.pageScript)
        #expect(scriptEvent.eventClass == ChromeFrontTabAppleEvents.fourCharacterCode("CrSu") && scriptEvent.eventID == ChromeFrontTabAppleEvents.fourCharacterCode("ExJa"))
        // The script goes as its own text parameter, so no quoting can break it.
        #expect(scriptEvent.paramDescriptor(forKeyword: ChromeFrontTabAppleEvents.fourCharacterCode("JvSc"))?.stringValue == FrontVideoEndReading.pageScript)
    }

    private func endedReading(_ hasEnded: Bool, url: String? = nil) -> FrontVideoEndReading? {
        FrontVideoEndReading(scriptReply: "\(hasEnded ? "1" : "0")|\(url ?? videoURL)")
    }

    @Test func anEndedVideoWithSomethingToRecapShowsItsRecapOnce() {
        let keys: Set<String> = ["L24Wf0VlTE0"]
        let first = videoEndWatchStep(reading: endedReading(true), videoKeysWithSomethingToRecap: keys, state: VideoEndWatchState())
        #expect(first.decision == .showTheRecap(videoKey: "L24Wf0VlTE0"))
        // The video stays ended for the seconds before the next one autoplays, and every read of it waits.
        let second = videoEndWatchStep(reading: endedReading(true), videoKeysWithSomethingToRecap: keys, state: first.state)
        #expect(second.decision == .wait)
    }

    @Test func aVideoThatPlaysAgainIsWatchedForItsNextEnding() {
        let keys: Set<String> = ["L24Wf0VlTE0"]
        let afterTheFirstEnding = videoEndWatchStep(reading: endedReading(true), videoKeysWithSomethingToRecap: keys, state: VideoEndWatchState()).state
        let whilePlayingAgain = videoEndWatchStep(reading: endedReading(false), videoKeysWithSomethingToRecap: keys, state: afterTheFirstEnding)
        #expect(whilePlayingAgain.decision == .wait)
        let endingAgain = videoEndWatchStep(reading: endedReading(true), videoKeysWithSomethingToRecap: keys, state: whilePlayingAgain.state)
        #expect(endingAgain.decision == .showTheRecap(videoKey: "L24Wf0VlTE0"))
    }

    @Test func aVideoNobodyTookAQuizOnOrWroteAGuideForShowsNothingWhenItEnds() {
        let step = videoEndWatchStep(reading: endedReading(true), videoKeysWithSomethingToRecap: ["another-video"], state: VideoEndWatchState())
        #expect(step.decision == .wait)
        // It is not marked handled either, so a quiz taken on it later still finds its ending unhandled.
        #expect(step.state.videoKeyOfTheHandledEnding == nil)
    }

    @Test func aFailedReadChangesNothing() {
        let handledState = VideoEndWatchState(videoKeyOfTheHandledEnding: "L24Wf0VlTE0")
        let step = videoEndWatchStep(reading: nil, videoKeysWithSomethingToRecap: ["L24Wf0VlTE0"], state: handledState)
        #expect(step.decision == .wait)
        #expect(step.state == handledState)
    }

    @Test func aPlaylistAddressAndAPlainWatchAddressAreTheSameVideo() {
        let step = videoEndWatchStep(
            reading: endedReading(true, url: "https://www.youtube.com/watch?v=L24Wf0VlTE0&list=PL1&index=3"),
            videoKeysWithSomethingToRecap: ["L24Wf0VlTE0"],
            state: VideoEndWatchState()
        )
        #expect(step.decision == .showTheRecap(videoKey: "L24Wf0VlTE0"))
    }

    @Test func aRecapTheLearnerAlreadySawIsNotShownAgainButAChangedOneIs() throws {
        let quizOnly = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        #expect(videoRecapToShowAtTheEnd(recap: quizOnly, lastShownRecap: quizOnly) == nil)
        #expect(videoRecapToShowAtTheEnd(recap: nil, lastShownRecap: quizOnly) == nil)
        #expect(videoRecapToShowAtTheEnd(recap: quizOnly, lastShownRecap: nil) == quizOnly)
        let withAGuide = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: try studyGuide(summary: "Summary.")))
        #expect(videoRecapToShowAtTheEnd(recap: withAGuide, lastShownRecap: quizOnly) == withAGuide)
    }

    // MARK: - The watch

    private struct ChromeRefusedTheScript: Error {}

    @MainActor private final class WatchFixture {
        var chromeIsFront = true
        var isBusy = false
        var frontTabURL = "https://www.youtube.com/watch?v=L24Wf0VlTE0"
        var reading: FrontVideoEndReading?
        var readsFail = false
        var becomesBusyDuringTheRead = false
        var recap: VideoRecap?
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var urlReadCount = 0
        var readCount = 0
        var shownRecaps: [VideoRecap] = []
        lazy var watcher = VideoRecapWatcher(
            chromeIsTheFrontApp: { [unowned self] in chromeIsFront },
            clickyIsBusy: { [unowned self] in isBusy },
            readTheFrontTabURL: { [unowned self] in
                urlReadCount += 1
                if readsFail { throw ChromeRefusedTheScript() }
                return frontTabURL
            },
            readTheFrontVideo: { [unowned self] in
                readCount += 1
                if becomesBusyDuringTheRead { isBusy = true }
                return reading
            },
            now: { [unowned self] in clock },
            recapForVideo: { [unowned self] _ in recap },
            showTheRecapAtTheEnd: { [unowned self] recap, _ in shownRecaps.append(recap) }
        )
    }

    @Test func theWatchReadsNothingUntilAVideoHasSomethingToRecap() async {
        let fixture = WatchFixture()
        fixture.reading = endedReading(true)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.readCount == 0)
    }

    @Test func theWatchReadsOnlyWhileChromeIsTheFrontAppAndClickyIsFree() async throws {
        let fixture = WatchFixture()
        fixture.recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        fixture.reading = endedReading(true)
        fixture.watcher.startWatching(forVideoURL: videoURL)
        fixture.chromeIsFront = false
        await fixture.watcher.readTheFrontVideoOnce()
        fixture.chromeIsFront = true
        fixture.isBusy = true
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.readCount == 0)
        // The ending was never read, so it still earns its recap once Clicky is free.
        fixture.isBusy = false
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps.count == 1)
    }

    @Test func theWatchShowsARecapOnceForAnEndingAndNothingWhenItsCardAlreadyShowedIt() async throws {
        let fixture = WatchFixture()
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        fixture.recap = recap
        fixture.reading = endedReading(true)
        fixture.watcher.startWatching(forVideoURL: videoURL)
        // The end of the quiz showed this very recap already.
        fixture.watcher.recapWasShown(recap, forVideoURL: videoURL)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps.isEmpty)
        // A guide written since changes the recap, so the next ending shows it.
        fixture.reading = endedReading(false)
        await fixture.watcher.readTheFrontVideoOnce()
        fixture.recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: try studyGuide(summary: "Summary.")))
        fixture.reading = endedReading(true)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps == [fixture.recap])
        // The same ending read again shows nothing more.
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps.count == 1)
    }

    @Test func theWatchRunsThePageScriptOnlyOnAWatchedVideo() async throws {
        let fixture = WatchFixture()
        fixture.recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        fixture.reading = endedReading(true)
        fixture.watcher.startWatching(forVideoURL: videoURL)
        // Another site in front: the address is read, and the page script never runs there.
        fixture.frontTabURL = "https://example.com/some-page-with-an-alert"
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.urlReadCount == 1 && fixture.readCount == 0)
        fixture.frontTabURL = videoURL
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.readCount == 1 && fixture.shownRecaps.count == 1)
    }

    @Test func aFailedReadBacksTheWatchOffForThirtySeconds() async throws {
        let fixture = WatchFixture()
        fixture.watcher.startWatching(forVideoURL: videoURL)
        fixture.readsFail = true
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.urlReadCount == 1)
        // Three seconds later, the next poll leaves Chrome alone.
        fixture.clock.addTimeInterval(videoEndWatchSecondsBetweenReads)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.urlReadCount == 1)
        fixture.clock.addTimeInterval(videoEndWatchSecondsToWaitAfterAFailedRead)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.urlReadCount == 2)
    }

    @Test func aRecapThatTurnsBusyDuringTheReadWaitsAndShowsAtTheNextRead() async throws {
        let fixture = WatchFixture()
        fixture.reading = endedReading(true)
        fixture.recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        fixture.watcher.startWatching(forVideoURL: videoURL)
        // A press lands while the page script runs off the main actor.
        fixture.becomesBusyDuringTheRead = true
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps.isEmpty)
        // The ending was not used up, so once Clicky is free the same ending shows its recap.
        fixture.becomesBusyDuringTheRead = false
        fixture.isBusy = false
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps.count == 1)
    }

    @Test func aHeldBackRecapIsNotMarkedSeenSoItStillShowsAtTheNextEnding() async throws {
        let fixture = WatchFixture()
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        fixture.recap = recap
        fixture.reading = endedReading(true)
        fixture.watcher.startWatching(forVideoURL: videoURL)
        // The watch asks for the Card but the owner holds it back and never calls `recapWasShown`.
        await fixture.watcher.readTheFrontVideoOnce()
        fixture.reading = endedReading(false)
        await fixture.watcher.readTheFrontVideoOnce()
        fixture.reading = endedReading(true)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps == [recap, recap])
        // Once a Card showed it, the next ending shows nothing.
        fixture.watcher.recapWasShown(recap, forVideoURL: videoURL)
        fixture.reading = endedReading(false)
        await fixture.watcher.readTheFrontVideoOnce()
        fixture.reading = endedReading(true)
        await fixture.watcher.readTheFrontVideoOnce()
        #expect(fixture.shownRecaps.count == 2)
    }

    @Test func eachThingClickyDoesOrShowsHoldsTheRecapBackTheMenuBarPanelIncluded() {
        #expect(!VideoRecapBusyFacts().clickyIsBusy)
        let eachFact: [WritableKeyPath<VideoRecapBusyFacts, Bool>] = [
            \.aSceneIsUp, \.clickyIsNotIdle, \.speechIsPlaying, \.aQuizQuestionIsOpen, \.aQuizIsRunning, \.aCardIsShowing,
            \.theThemeStudioIsOpen, \.theSettingsDialIsOpen, \.theAgentListIsOpen, \.theMenuBarPanelIsOpen,
            \.theRoomArtPanelIsOpen, \.anAddThemeCardIsOpen, \.anApprovalWaits,
        ]
        for fact in eachFact {
            var busyFacts = VideoRecapBusyFacts()
            busyFacts[keyPath: fact] = true
            #expect(busyFacts.clickyIsBusy, "\(fact) alone should hold the recap back")
        }
    }

    @Test func theCardUnfoldsAfterTheGatherOnlyWhenNobodyMovedOnAndClickyIsFree() {
        #expect(videoRecapCardMayShowAfterTheGather(gatherWasCancelled: false, clickyIsBusy: false))
        #expect(!videoRecapCardMayShowAfterTheGather(gatherWasCancelled: true, clickyIsBusy: false))
        #expect(!videoRecapCardMayShowAfterTheGather(gatherWasCancelled: false, clickyIsBusy: true))
    }

    // MARK: - Gathered discs that show again

    @Test func gatheredDiscsShowAgainForAnApprovalOrANewDiscOnTheirDisplayOnly() {
        let displayID: CGDirectDisplayID = 1
        let otherDisplayID: CGDirectDisplayID = 2
        let gatheredDisc = AgentTokenDiscID(displayID: displayID, tokenSlot: .agent(UUID()))
        let newDisc = AgentTokenDiscID(displayID: displayID, tokenSlot: .agent(UUID()))
        let discOnAnotherDisplay = AgentTokenDiscID(displayID: otherDisplayID, tokenSlot: .agent(UUID()))
        func mustShowAgain(gathered: Set<AgentTokenDiscID> = [gatheredDisc], onScreen: Set<AgentTokenDiscID>, waiting: Bool = false) -> Bool {
            gatheredDiscsMustShowAgain(gatheredDiscIDs: gathered, gatheredDisplayID: displayID, discIDsOnScreen: onScreen, anAgentWaitsForApproval: waiting)
        }
        #expect(!mustShowAgain(onScreen: [gatheredDisc]))
        #expect(mustShowAgain(onScreen: [gatheredDisc, newDisc]))
        #expect(!mustShowAgain(onScreen: [gatheredDisc, discOnAnotherDisplay]))
        #expect(mustShowAgain(onScreen: [gatheredDisc], waiting: true))
        // Nothing is gathered, so nothing shows again.
        #expect(!mustShowAgain(gathered: [], onScreen: [newDisc], waiting: true))
    }

    // MARK: - The gather

    @Test func aGatherEndsOnceSoASendBackAfterAnAtOnceEndFliesNothing() {
        let displayID: CGDirectDisplayID = 1
        let firstDisc = AgentTokenDiscID(displayID: displayID, tokenSlot: .agent(UUID()))
        let pausedDisc = AgentTokenDiscID(displayID: displayID, tokenSlot: .paused)
        var recapGather = AgentTokenRecapGather()
        recapGather.gathered([
            .init(discID: firstDisc, overflowCount: 0, center: CGPoint(x: 900, y: 970)),
            .init(discID: pausedDisc, overflowCount: 0, center: CGPoint(x: 928, y: 970)),
        ], onDisplay: displayID)
        // While gathered, a "go ahead" flight that lands, or the paused disc fading in after "hold on", leaves the disc hidden.
        #expect(recapGather.hides(firstDisc))
        #expect(recapGather.hides(pausedDisc))
        #expect(!recapGather.hides(AgentTokenDiscID(displayID: 2, tokenSlot: .agent(UUID()))))
        // A press ends the gather and shows both discs at once.
        let shownAtOnce = recapGather.end()
        #expect(shownAtOnce.discs.map(\.discID) == [firstDisc, pausedDisc])
        #expect(shownAtOnce.displayID == displayID)
        // The gather's flights then land and the recap asks to send the discs back, which finds none to fly.
        let sentBackAfterwards = recapGather.end()
        #expect(sentBackAfterwards.discs.isEmpty && sentBackAfterwards.displayID == nil)
        #expect(!recapGather.hides(firstDisc))
    }

    @Test func withNoDiscOnScreenTheGatherFinishesAtOnceAndSendingBackDoesNothing() {
        let themeSettings = makeThemeSettings()
        let dock = AgentTokenDockController(
            store: BackgroundAgentStore(themeSettings: themeSettings),
            themeSettings: themeSettings,
            menuActions: AgentDiscMenuActions(cancelAgent: { _ in }, showReadyScene: {}, hearTaskAnswer: {}, tryAgain: { _ in }),
            onDiscClicked: { _ in }
        )
        var gatheredCount = 0
        dock.gatherTheDiscs(at: CGPoint(x: 100, y: 100)) { gatheredCount += 1 }
        // The Card must unfold even when no disc shows, such as a learner with no agents.
        #expect(gatheredCount == 1)
        dock.sendTheDiscsBack(from: CGPoint(x: 100, y: 100))
    }

    // MARK: - The Card at 2x

    private func render(_ recap: VideoRecap, moment: VideoRecapMoment) throws -> NSBitmapImageRep {
        let card = VideoQuizSummaryCardView(recap: recap, moment: moment, accentColor: Color(hex: "#3380FF"), goBackToTheMissedQuestion: { _ in }, openTheStudyGuide: {}, close: {})
        let renderer = ImageRenderer(content: card.padding(30).background(Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    @Test func theRecapCardGrowsWithItsSectionsAndKeepsItsWidthAndSurface() throws {
        let quizOnly = try #require(VideoRecap(quizResults: [quizResult("What is this?", at: 40, .gotIt)], studyGuideRecord: nil))
        let fullRecap = try #require(VideoRecap(
            quizResults: [
                quizResult("What does the vent do when the pressure under the volcano builds up for a long time?", at: 134, .missed),
                quizResult("What is this?", at: 40, .gotIt, explanation: "The crater is the opening at the top where lava and ash leave the volcano."),
            ],
            studyGuideRecord: try studyGuide(summary: "Volcanoes move magma from deep underground to the surface through a vent.")
        ))
        let quizOnlyPixels = try render(quizOnly, moment: .videoEnded)
        let fullPixels = try render(fullRecap, moment: .videoEnded)
        #expect(fullPixels.pixelsWide == (30 + 320 + 30) * 2)
        #expect(fullPixels.pixelsHigh > quizOnlyPixels.pixelsHigh)
        let cardSurface = try #require(fullPixels.colorAt(x: (30 + 4) * 2, y: fullPixels.pixelsHigh / 2))
        #expect(cardSurface.redComponent < 0.12 && cardSurface.greenComponent < 0.12 && cardSurface.blueComponent < 0.15)
        let rightMargin = try #require(fullPixels.colorAt(x: fullPixels.pixelsWide - 20, y: fullPixels.pixelsHigh / 2))
        #expect(rightMargin.redComponent > 0.9)
    }

    // MARK: - The panel

    @Test(.showsARealWindow) func theRecapCardUnfoldsFromWhereTheDiscsLandedAndTellsTheOwnerWhenItCloses() throws {
        let screen = try #require(NSScreen.screens.first, "the test host has no screen to show the Card on")
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        let controller = VideoQuizSummaryPanelController()
        var closedWithGlideOrigins: [CGPoint] = []
        controller.onClosed = { closedWithGlideOrigins.append($0) }
        // The video sits on the first screen, so the Card shows there whichever display the mouse is on.
        let videoRect = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 225)
        let landingPoint = CGPoint(x: screen.frame.midX + 7, y: screen.frame.midY + 3)
        controller.show(recap: recap, moment: .videoEnded, cursorPoint: landingPoint, videoRect: videoRect, accentColor: Color(hex: "#3380FF"), goBackToTheMissedQuestion: { _ in }, openTheStudyGuide: {})
        #expect(controller.isShowing)
        controller.close(animated: false)
        // Closing a Card that is not showing reports nothing, so the discs are sent back once.
        controller.close(animated: false)
        #expect(closedWithGlideOrigins == [landingPoint])
    }

    @Test func theGlideOriginIsWhereTheDiscsLandedUnlessThatIsOffTheCardsDisplay() {
        // Two displays side by side, with made-up frames, so the result never depends on this Mac's displays.
        let cardScreenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let videoRect = CGRect(x: 200, y: 300, width: 800, height: 450)
        let mouseLocation = CGPoint(x: 50, y: 60)
        let landedOnTheCardsDisplay = CGPoint(x: 862, y: 556.5)
        let landedOnTheOtherDisplay = CGPoint(x: 1922.5, y: 972.5)
        #expect(videoRecapGlideOrigin(cursorPoint: landedOnTheCardsDisplay, cardScreenFrame: cardScreenFrame, videoRect: videoRect, mouseLocation: mouseLocation) == landedOnTheCardsDisplay)
        #expect(videoRecapGlideOrigin(cursorPoint: landedOnTheOtherDisplay, cardScreenFrame: cardScreenFrame, videoRect: videoRect, mouseLocation: mouseLocation) == CGPoint(x: 600, y: 750))
        #expect(videoRecapGlideOrigin(cursorPoint: nil, cardScreenFrame: cardScreenFrame, videoRect: nil, mouseLocation: mouseLocation) == mouseLocation)
    }

    @Test(.showsARealWindow) func aLandingPointOffTheCardsDisplayFallsBackToTheVideosTopEdge() throws {
        let screen = try #require(NSScreen.screens.first, "the test host has no screen to show the Card on")
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt)], studyGuideRecord: nil))
        let controller = VideoQuizSummaryPanelController()
        var closedWithGlideOrigins: [CGPoint] = []
        controller.onClosed = { closedWithGlideOrigins.append($0) }
        let videoRect = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 225)
        let landingPointOnAnotherDisplay = CGPoint(x: screen.frame.maxX + 5000, y: screen.frame.midY)
        controller.show(recap: recap, moment: .videoEnded, cursorPoint: landingPointOnAnotherDisplay, videoRect: videoRect, accentColor: Color(hex: "#3380FF"), goBackToTheMissedQuestion: { _ in }, openTheStudyGuide: {})
        controller.close(animated: false)
        #expect(closedWithGlideOrigins == [CGPoint(x: videoRect.midX, y: videoRect.maxY)])
    }
}
