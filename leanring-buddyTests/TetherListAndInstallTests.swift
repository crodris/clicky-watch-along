//
//  TetherListAndInstallTests.swift
//  leanring-buddyTests
//
//  The Tether agent list, the settings dial's way out, and the "Add theme?" card: the line under a row's title, the
//  header's counts, where the list's window sits so its Card stays on screen and its shadow has room, the flags behind
//  "Try again", how the dial closes, and the queue of theme files waiting for an answer.
//

import AppKit
import Foundation
import Testing

@testable import Clicky

// MARK: - The agent list

@MainActor
struct AgentListLiveLineTests {
    private func store(withATaskAgent agentID: inout UUID?) -> BackgroundAgentStore {
        let store = makeBackgroundAgentStore()
        agentID = store.start(kind: .task)
        return store
    }

    @Test func aRunningTaskAgentSaysItsOwnStepAndTheSiteItReads() {
        var agentID: UUID?
        let store = store(withATaskAgent: &agentID)
        let runningAgentID = try! #require(agentID)
        store.reportStep("Comparing the two catches", for: runningAgentID)
        #expect(agentListLiveLine(for: store.agents[0], approvalState: .none) == AgentListLiveLine(text: "Comparing the two catches", tone: .normal))

        store.setReadingHost("nasa.gov", for: runningAgentID)
        #expect(agentListLiveLine(for: store.agents[0], approvalState: .none)?.text == "Comparing the two catches · nasa.gov")
    }

    @Test func theNextStepClearsTheSiteTheLastStepRead() {
        var agentID: UUID?
        let store = store(withATaskAgent: &agentID)
        let runningAgentID = try! #require(agentID)
        store.reportStep("Reading the launch page", for: runningAgentID)
        store.setReadingHost("spacex.com", for: runningAgentID)
        store.reportStep("Writing the page in Notion", for: runningAgentID)
        #expect(store.agents[0].readingHost == nil)
        #expect(agentListLiveLine(for: store.agents[0], approvalState: .none)?.text == "Writing the page in Notion")
    }

    @Test func anEndedAgentTakesNoReadingHost() {
        var agentID: UUID?
        let store = store(withATaskAgent: &agentID)
        let runningAgentID = try! #require(agentID)
        store.cancel(runningAgentID)
        store.setReadingHost("nasa.gov", for: runningAgentID)
        #expect(store.agents[0].readingHost == nil)
    }

    @Test func aFailedRowSaysWhyAndACancelledRowSaysSo() {
        var failedID: UUID?
        let store = store(withATaskAgent: &failedID)
        let cancelledID = store.start(kind: .task)
        store.fail(try! #require(failedID), reason: "The task could not be finished.")
        store.cancel(cancelledID)
        let failedAgent = store.agents.first { $0.id == failedID }!
        let cancelledAgent = store.agents.first { $0.id == cancelledID }!
        #expect(agentListLiveLine(for: failedAgent, approvalState: .none) == AgentListLiveLine(text: "The task could not be finished.", tone: .failure))
        #expect(agentListLiveLine(for: cancelledAgent, approvalState: .none) == AgentListLiveLine(text: "Cancelled", tone: .quiet))
    }

    @Test func aWaitingApprovalWinsOverTheStepText() {
        var agentID: UUID?
        let store = store(withATaskAgent: &agentID)
        store.reportStep("Opening the page", for: try! #require(agentID))
        let line = agentListLiveLine(for: store.agents[0], approvalState: .waitsItsTurn(.sends))
        #expect(line == AgentListLiveLine(text: "Needs your OK after the one above", tone: .needsYou))
    }

    @Test func aFinishedAgentWithNothingWaitingAddsNoLine() throws {
        let store = makeBackgroundAgentStore()
        let guideID = store.start(kind: .studyGuide)
        let pageURL = try #require(URL(string: "https://www.notion.so/page"))
        store.finish(guideID, with: .notionPage(pageURL))
        #expect(agentListLiveLine(for: store.agents[0], approvalState: .none) == nil)
    }

    @Test func aFinishedTaskWaitingToBeHeardSaysTheAnswerIsReady() {
        let store = makeBackgroundAgentStore()
        let taskID = store.start(kind: .task)
        store.finish(taskID, with: .answer(spokenSummary: "Found it.", pageURL: nil))
        #expect(agentListLiveLine(for: store.agents[0], approvalState: .none) == AgentListLiveLine(text: "Answer ready to hear", tone: .normal))
    }

    @Test func theHeaderCountsRunningAgentsAndThoseNeedingAnOK() {
        #expect(agentListHeaderCounts(runningAgentCount: 3, agentsNeedingAnOKCount: 0) == (running: "3 running", needsYou: nil))
        #expect(agentListHeaderCounts(runningAgentCount: 3, agentsNeedingAnOKCount: 1) == (running: "3 running", needsYou: "1 needs you"))
        #expect(agentListHeaderCounts(runningAgentCount: 3, agentsNeedingAnOKCount: 2) == (running: "3 running", needsYou: "2 need you"))
    }

    @Test func aFailedAgentIsTriedAgainOnlyByTheRulesTheVoiceToolsKeep() {
        func mayRetry(_ kind: BackgroundAgentKind, quiz: Bool = false, step: ExperimentRequestStep = .startBuilding, experimentOnScreen: Bool = false, video: Bool = true) -> Bool {
            backgroundAgentMayBeTriedAgain(agentKind: kind, aQuizQuestionIsOpen: quiz, experimentRequestStep: step, anExperimentIsOnScreen: experimentOnScreen, aVideoIsInFront: video)
        }
        #expect(mayRetry(.experiment))
        #expect(!mayRetry(.experiment, step: .sayItIsStillBuilding))
        #expect(!mayRetry(.experiment, step: .showTheReadyExperiment))
        #expect(!mayRetry(.experiment, experimentOnScreen: true))
        #expect(mayRetry(.threeDModel))
        #expect(!mayRetry(.threeDModel, video: false))
        #expect(mayRetry(.task))
        #expect(mayRetry(.studyGuide))
        // An open quiz question owns every kind of work.
        for kind in [BackgroundAgentKind.experiment, .threeDModel, .task, .studyGuide, .studyGuideUpdate] {
            #expect(!mayRetry(kind, quiz: true))
        }
    }

    @Test func theApprovalCardReportsToTheDeskOnlyWhileTheListIsListening() {
        let uiState = AgentListUIState(expandedAgentID: nil)
        var reports: [String] = []
        // The hidden panel, and the copy that plays on the carrier, report while the list is not listening: nothing reaches the desk.
        uiState.report(toTheDesk: { reports.append("shown whole") })
        #expect(reports.isEmpty)

        // The report waits and goes out when the real panel is on screen, so its clock starts then and never earlier.
        uiState.startListeningForTheDesk()
        #expect(reports == ["shown whole"])
        uiState.report(toTheDesk: { reports.append("not whole") })
        #expect(reports == ["shown whole", "not whole"])

        // Once the list starts to close, the copy that plays while it closes reports nothing.
        uiState.stopListeningForTheDesk()
        uiState.report(toTheDesk: { reports.append("late") })
        #expect(reports == ["shown whole", "not whole"])
        uiState.startListeningForTheDesk()
        #expect(reports == ["shown whole", "not whole"])
    }

    @Test func theLiveLineNamesTheSiteWithoutWwwAndOnlyForALinkWithAHost() {
        #expect(agentListHost(ofLink: "https://www.NASA.gov/missions/starship") == "nasa.gov")
        #expect(agentListHost(ofLink: "https://youtu.be/abc") == "youtu.be")
        #expect(agentListHost(ofLink: "not a link") == nil)
        #expect(agentListHost(ofLink: "") == nil)
    }

    @Test func aFailedAgentOffersTryAgainOnceThatTheAppAllowsAndNeverAfterItIsUsed() {
        let store = makeBackgroundAgentStore()
        let agentID = store.start(kind: .task)
        #expect(!store.agents[0].canBeTriedAgain)
        store.allowTryingAgain(agentID)
        #expect(store.agents[0].canBeTriedAgain)
        store.markTriedAgain(agentID)
        #expect(!store.agents[0].canBeTriedAgain)
    }
}

struct AgentListWindowPlacementTests {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let windowSize = CGSize(width: 348, height: 300)

    @Test func theWindowSitsOutsideTheCardByTheShadowMargins() {
        let cardTopLeft = CGPoint(x: 500, y: 600)
        let windowFrame = AgentListWindowMargins.windowFrame(cardTopLeft: cardTopLeft, windowSize: windowSize, visibleFrame: visibleFrame)
        #expect(windowFrame.minX == 500 - AgentListWindowMargins.leading)
        #expect(windowFrame.maxY == 600 + AgentListWindowMargins.top)
    }

    @Test func aClickInTheShadowMarginIsOutsideTheCard() {
        let windowFrame = AgentListWindowMargins.windowFrame(cardTopLeft: CGPoint(x: 500, y: 600), windowSize: windowSize, visibleFrame: visibleFrame)
        let cardFrame = AgentListWindowMargins.cardFrame(inWindowFrame: windowFrame)
        #expect(cardFrame == CGRect(x: 500, y: 600 - (windowSize.height - AgentListWindowMargins.vertical), width: 300, height: windowSize.height - AgentListWindowMargins.vertical))
        // 20 points under the card is inside the window, in the margin where the shadow draws.
        let clickInTheShadow = CGPoint(x: cardFrame.midX, y: cardFrame.minY - 20)
        #expect(windowFrame.contains(clickInTheShadow))
        #expect(!cardFrame.contains(clickInTheShadow))
    }

    @Test func aCardAtTheScreenEdgeIsKeptOnScreenWhileItsMarginMayReachPastIt() {
        // A card whose top-left corner is above and left of the screen is moved in, so the card itself is whole on screen.
        let windowFrame = AgentListWindowMargins.windowFrame(cardTopLeft: CGPoint(x: -50, y: 1000), windowSize: windowSize, visibleFrame: visibleFrame)
        let cardFrame = CGRect(
            x: windowFrame.minX + AgentListWindowMargins.leading,
            y: windowFrame.minY + AgentListWindowMargins.bottom,
            width: windowSize.width - AgentListWindowMargins.horizontal,
            height: windowSize.height - AgentListWindowMargins.vertical
        )
        #expect(visibleFrame.contains(cardFrame))
        #expect(cardFrame.minX == 0)
        #expect(cardFrame.maxY == 900)
    }

    @Test func aCardNearTheBottomRightIsMovedUpAndLeftSoItIsWhole() {
        let windowFrame = AgentListWindowMargins.windowFrame(cardTopLeft: CGPoint(x: 1400, y: 50), windowSize: windowSize, visibleFrame: visibleFrame)
        let cardFrame = CGRect(
            x: windowFrame.minX + AgentListWindowMargins.leading,
            y: windowFrame.minY + AgentListWindowMargins.bottom,
            width: windowSize.width - AgentListWindowMargins.horizontal,
            height: windowSize.height - AgentListWindowMargins.vertical
        )
        #expect(visibleFrame.contains(cardFrame))
    }
}

// MARK: - The dial's way out

struct SettingsDialClosingFormTests {
    @Test func aCommitFliesTheChosenItemIntoTheCursorAtTheGlideCloseTime() {
        let form = SettingsDialClosingForm.form(committedAChoice: true, reduceMotionIsOn: false)
        let expectedSeconds = DS.Move.glide.curve.timeScaled(by: DS.Move.glideCloseTimeFactor).seconds()
        #expect(form == .flyTheChosenItemIntoTheCursor(seconds: expectedSeconds))
        // At 0.7x the close is quicker than the open.
        #expect(expectedSeconds < DS.Move.glide.curve.seconds())
    }

    @Test func aCancelAndAReleaseOverNothingFadeTheDialOutIn120Milliseconds() {
        #expect(SettingsDialClosingForm.form(committedAChoice: false, reduceMotionIsOn: false) == .fadeOut(seconds: 0.12))
    }

    @Test func reduceMotionFadesTheDialOutInPlaceEvenForACommit() {
        #expect(SettingsDialClosingForm.form(committedAChoice: true, reduceMotionIsOn: true) == .fadeOut(seconds: DS.Move.fadeSeconds))
        #expect(SettingsDialClosingForm.form(committedAChoice: false, reduceMotionIsOn: true) == .fadeOut(seconds: DS.Move.fadeSeconds))
    }
}

// MARK: - Add theme?

@MainActor
private final class RecordingInstallCard: ThemeInstallCardPresenting {
    private(set) var shownInstalls: [PendingThemeInstall] = []
    private(set) var hideCount = 0
    private var decisions: [(Bool) -> Void] = []

    func show(_ pendingInstall: PendingThemeInstall, decide: @escaping (Bool) -> Void) {
        shownInstalls.append(pendingInstall)
        decisions.append(decide)
    }

    func hide() { hideCount += 1 }

    /// The learner answers the card that is showing.
    func answerTheNewestCard(added: Bool) { decisions.last?(added) }
    func answerTheFirstCardAgain(added: Bool) { decisions.first?(added) }
}

@MainActor
struct ThemeInstallConfirmationTests {
    private func pendingInstall(named fileName: String) throws -> PendingThemeInstall {
        let theme = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "installing", origin: .idea, pictureIsAvailable: false)
        return PendingThemeInstall(packageURL: URL(fileURLWithPath: "/tmp/\(fileName).clickytheme"), theme: theme, pictureJPEG: nil)
    }

    @Test func nothingInstallsUntilTheLearnerAddsTheTheme() throws {
        let card = RecordingInstallCard()
        var installed: [PendingThemeInstall] = []
        let confirmation = ThemeInstallConfirmation(cardPresenter: card, install: { installed.append($0) })
        let moonlit = try pendingInstall(named: "Moonlit")

        confirmation.ask(about: moonlit)
        #expect(card.shownInstalls == [moonlit])
        #expect(installed.isEmpty)
        card.answerTheNewestCard(added: true)
        #expect(installed == [moonlit])
        #expect(card.hideCount == 1)
        #expect(!confirmation.isOpen)
    }

    @Test func cancellingInstallsNothing() throws {
        let card = RecordingInstallCard()
        var installed: [PendingThemeInstall] = []
        let confirmation = ThemeInstallConfirmation(cardPresenter: card, install: { installed.append($0) })
        confirmation.ask(about: try pendingInstall(named: "Moonlit"))
        card.answerTheNewestCard(added: false)
        #expect(installed.isEmpty)
        #expect(!confirmation.isOpen)
    }

    @Test func escapeAnswersTheCardWithANoAndNothingInstalls() throws {
        let card = RecordingInstallCard()
        var installed: [PendingThemeInstall] = []
        let confirmation = ThemeInstallConfirmation(cardPresenter: card, install: { installed.append($0) })
        #expect(!confirmation.cancelOnEscape())
        confirmation.ask(about: try pendingInstall(named: "Moonlit"))
        #expect(confirmation.cancelOnEscape())
        #expect(installed.isEmpty)
        #expect(!confirmation.isOpen)
    }

    @Test func filesOpenedTogetherAreAskedAboutOneAtATimeInTheOrderTheyCame() throws {
        let card = RecordingInstallCard()
        var installed: [PendingThemeInstall] = []
        let confirmation = ThemeInstallConfirmation(cardPresenter: card, install: { installed.append($0) })
        let first = try pendingInstall(named: "First")
        let second = try pendingInstall(named: "Second")
        confirmation.ask(about: first)
        confirmation.ask(about: second)
        // The second waits behind the first.
        #expect(card.shownInstalls == [first])

        card.answerTheNewestCard(added: false)
        #expect(card.shownInstalls == [first, second])
        card.answerTheNewestCard(added: true)
        #expect(installed == [second])
    }

    @Test func theSameFileOpenedTwiceIsAskedAboutOnce() throws {
        let card = RecordingInstallCard()
        var installed: [PendingThemeInstall] = []
        let confirmation = ThemeInstallConfirmation(cardPresenter: card, install: { installed.append($0) })
        confirmation.ask(about: try pendingInstall(named: "Moonlit"))
        confirmation.ask(about: try pendingInstall(named: "Moonlit"))
        card.answerTheNewestCard(added: true)
        #expect(installed.count == 1)
        #expect(card.shownInstalls.count == 1)
        #expect(!confirmation.isOpen)
    }

    @Test func aLateAnswerFromACardTheNextOneReplacedChangesNothing() throws {
        let card = RecordingInstallCard()
        var installed: [PendingThemeInstall] = []
        let confirmation = ThemeInstallConfirmation(cardPresenter: card, install: { installed.append($0) })
        confirmation.ask(about: try pendingInstall(named: "First"))
        confirmation.ask(about: try pendingInstall(named: "Second"))
        card.answerTheNewestCard(added: false)
        // The first card's button is pressed again after the second card replaced it.
        card.answerTheFirstCardAgain(added: true)
        #expect(installed.isEmpty)
        #expect(confirmation.isOpen)
    }

    @Test func theCardSaysHowTheThemeMovesWithoutTheSounds() throws {
        let theme = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "installing", origin: .idea, pictureIsAvailable: false)
        #expect(themeInstallCardTitle(for: theme) == "Add \"Moonlit\" to Clicky?")
        let summary = themeInstallCardSummary(for: theme)
        #expect(!summary.contains("sounds"))
        #expect(summary.first?.isUppercase == true)
    }
}
