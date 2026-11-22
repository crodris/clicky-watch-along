//
//  PanelHomeTests.swift
//  leanring-buddyTests
//
//  The menu bar panel's home: the header's state line, the one banner slot, the agents row, which themes the home's cards
//  show, how the arrow keys move between cards, and what VoiceOver reads for an agent's disc.
//

import Foundation
import Testing

@testable import Clicky

@MainActor
struct PanelHomeTests {
    // MARK: - The state line

    private func status(
        setupIsFinished: Bool = true,
        aRequiredPermissionIsOff: Bool = false,
        workerIsUnreachable: Bool = false,
        voiceState: CompanionVoiceState = .idle,
        aVideoQuizQuestionIsOpen: Bool = false,
        videoQuizProgress: VideoQuizProgress? = nil,
        approvalRequestsWaiting: Int = 0
    ) -> PanelHeaderStatus {
        panelHeaderStatus(
            setupIsFinished: setupIsFinished,
            aRequiredPermissionIsOff: aRequiredPermissionIsOff,
            workerIsUnreachable: workerIsUnreachable,
            voiceState: voiceState,
            aVideoQuizQuestionIsOpen: aVideoQuizQuestionIsOpen,
            videoQuizProgress: videoQuizProgress,
            approvalRequestsWaiting: approvalRequestsWaiting
        )
    }

    @Test func theStateLineFollowsTheVoiceStateAndAProblemWinsOverIt() {
        #expect(status() == .ready)
        #expect(status(voiceState: .listening) == .listening)
        #expect(status(voiceState: .processing) == .thinking)
        #expect(status(voiceState: .responding) == .speaking)
        #expect(status(aVideoQuizQuestionIsOpen: true) == .quizQuestion)
        #expect(status(approvalRequestsWaiting: 2) == .readyWithRequestsWaiting(count: 2))
        #expect(status(voiceState: .listening, approvalRequestsWaiting: 1) == .listening)
        #expect(status(workerIsUnreachable: true, voiceState: .listening) == .offline)
        #expect(status(aRequiredPermissionIsOff: true, workerIsUnreachable: true) == .needsAttention)
        #expect(status(setupIsFinished: false, aRequiredPermissionIsOff: true) == .settingUp)
        #expect(PanelHeaderStatus.offline.isAProblem && PanelHeaderStatus.needsAttention.isAProblem && !PanelHeaderStatus.ready.isAProblem)
        #expect(PanelHeaderStatus.readyWithRequestsWaiting(count: 1).spokenText == "Ready · 1 request needs you")
    }

    @Test func aRunningQuizShowsItsScoreBetweenQuestions() {
        func result(_ outcome: StudyGuideQuizOutcome) -> StudyGuideQuizResult {
            StudyGuideQuizResult(question: "What is this part?", answerLabel: "rotor", explanation: "It spins.", askedAtSeconds: 30, result: outcome)
        }
        let watching = VideoQuizProgress(quizResults: [])
        #expect(watching.stateLineText == "Quiz · watching")
        let threeOfFour = VideoQuizProgress(quizResults: [result(.gotIt), result(.gotIt), result(.missed), result(.gotIt)])
        #expect(threeOfFour.stateLineText == "Quiz · 3 of 4 right")
        #expect(status(videoQuizProgress: threeOfFour) == .quizRunning(threeOfFour))
        #expect(status(videoQuizProgress: threeOfFour).hasAButton)
        // An open question and the voice states come first, and a running quiz comes before a waiting request.
        #expect(status(aVideoQuizQuestionIsOpen: true, videoQuizProgress: threeOfFour) == .quizQuestion)
        #expect(status(voiceState: .responding, videoQuizProgress: threeOfFour) == .speaking)
        #expect(status(videoQuizProgress: watching, approvalRequestsWaiting: 1) == .quizRunning(watching))
    }

    // MARK: - The banner slot

    private func banner(
        anApprovalCardShows: Bool = false,
        setupIsFinished: Bool = true,
        stepThatIsOff: SetupStep? = nil,
        workerIsUnreachable: Bool = false
    ) -> PanelBanner? {
        panelBanner(
            anApprovalCardShows: anApprovalCardShows,
            setupIsFinished: setupIsFinished,
            firstRequiredStepThatIsOff: stepThatIsOff,
            workerIsUnreachable: workerIsUnreachable
        )
    }

    @Test func theBannerShowsTheApprovalCardFirstThenAPermissionThenTheWorker() {
        #expect(banner() == nil)
        #expect(banner(workerIsUnreachable: true) == .workerUnreachable)
        #expect(banner(stepThatIsOff: .accessibility, workerIsUnreachable: true) == .permissionOff(.accessibility))
        #expect(banner(anApprovalCardShows: true, stepThatIsOff: .microphone, workerIsUnreachable: true) == .approvalCard)
        // Before setup finishes, the checklist itself shows what is off, so the banner does not say it again.
        #expect(banner(setupIsFinished: false, stepThatIsOff: .microphone) == nil)
    }

    @Test func aProblemBannerHasWordsAndTheApprovalCardDrawsItsOwn() {
        #expect(panelProblemBannerWords(for: .approvalCard) == nil)
        let permissionWords = panelProblemBannerWords(for: .permissionOff(.accessibility))
        #expect(permissionWords?.title == "Accessibility is off")
        #expect(permissionWords?.buttonTitle == "Fix")
        #expect(panelProblemBannerWords(for: .workerUnreachable)?.buttonTitle == "Retry")
    }

    @Test func aYesInThePanelCountsOnlyOnceThePanelsOwnCardWasRead() {
        var now = Date(timeIntervalSince1970: 9_000)
        var answers: [Bool] = []
        let desk = HarnessApprovalDesk(currentDate: { now }) { _, approved, _ in answers.append(approved) }
        desk.receive(HarnessApprovalRequest(taskID: UUID(), approvalID: "approval-1", capability: .sends, summary: "Send the page."))
        // The agent list's card was read, which does not make the panel's card read.
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .agentList)
        now = now.addingTimeInterval(2)
        #expect(!desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once, on: .menuPanel))
        #expect(desk.cardToShow(on: .menuPanel, at: now)?.phase == .waiting(.summaryNotYetSeen))
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .menuPanel)
        now = now.addingTimeInterval(HarnessApprovalDesk.secondsTheCardShowsBeforeAnAnswerCounts)
        #expect(desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once, on: .menuPanel))
        #expect(answers == [true])
    }

    // MARK: - The agents row

    private let now = Date(timeIntervalSince1970: 5_000)

    private func agent(_ phase: BackgroundAgentPhase, endedSecondsAgo: TimeInterval? = nil, resultIsWaiting: Bool = false) -> BackgroundAgent {
        BackgroundAgent(
            id: UUID(),
            kind: .task,
            subject: "booster catch",
            studyGuideVideoKey: nil,
            startedAt: now.addingTimeInterval(-60),
            currentStepStartedAt: now.addingTimeInterval(-30),
            endedAt: endedSecondsAgo.map { now.addingTimeInterval(-$0) },
            phase: phase,
            resultIsWaitingToBeDelivered: resultIsWaiting,
            tokenColor: nil
        )
    }

    @Test func theAgentsRowCountsWorkingAgentsAndWaitingResultsAndHidesWithNeither() throws {
        #expect(panelAgentsSummary(agents: [], at: now) == nil)
        let running = agent(.running(completedStepCount: 0))
        let waitingAnswer = agent(.finished(.answer(spokenSummary: "It was caught", pageURL: nil)), endedSecondsAgo: 30, resultIsWaiting: true)
        let heardAnswer = agent(.finished(.answer(spokenSummary: "It was caught", pageURL: nil)), endedSecondsAgo: 30, resultIsWaiting: false)
        let expiredAnswer = agent(.finished(.answer(spokenSummary: "It was caught", pageURL: nil)), endedSecondsAgo: 11 * 60, resultIsWaiting: true)
        let summary = try #require(panelAgentsSummary(agents: [running, running, waitingAnswer, heardAnswer, expiredAnswer], at: now))
        #expect(summary.mainText == "2 working")
        #expect(summary.secondaryText == "1 result waiting")
        // The row stays while a result waits, even with nothing running.
        let onlyAWaitingResult = panelAgentsSummary(agents: [waitingAnswer], at: now)
        #expect(onlyAWaitingResult?.mainText == "No agents working")
        #expect(onlyAWaitingResult?.secondaryText == "1 result waiting")
        #expect(panelAgentsSummary(agents: [heardAnswer, expiredAnswer], at: now) == nil)
    }

    // MARK: - Theme cards

    @Test func theHomeShowsTheNewestSavedThemesThenTheBundledOnesAndAlwaysTheSelectedOne() {
        let bundled = Array(bundledThemesForTests.prefix(8))
        #expect(panelHomeThemes(selectedTheme: bundled[0], bundledThemes: bundled, savedThemesNewestFirst: []) == Array(bundled.prefix(5)))
        // A theme past the first five takes the last card, so a pick from all themes still shows on the home.
        let farTheme = bundled[7]
        let withAFarSelection = panelHomeThemes(selectedTheme: farTheme, bundledThemes: bundled, savedThemesNewestFirst: [])
        #expect(withAFarSelection == Array(bundled.prefix(4)) + [farTheme])
        // Saved themes come first, at most three of them, newest first.
        let saved = Array(bundled.suffix(4))
        let withSavedThemes = panelHomeThemes(selectedTheme: bundled[0], bundledThemes: Array(bundled.prefix(4)), savedThemesNewestFirst: saved)
        #expect(withSavedThemes == Array(saved.prefix(3)) + [bundled[0], bundled[1]])
        // A pick among the shown cards never moves a card.
        #expect(panelHomeThemes(selectedTheme: bundled[3], bundledThemes: bundled, savedThemesNewestFirst: []) == Array(bundled.prefix(5)))
        #expect(panelAllThemes(bundledThemes: Array(bundled.prefix(2)), savedThemesByName: [bundled[5]]) == [bundled[0], bundled[1], bundled[5]])
    }

    @Test func theArrowKeysMoveAlongTheGridAndStopAtItsEdges() {
        // Seven cards in rows of three: 0 1 2 / 3 4 5 / 6.
        func move(_ arrowKey: ThemeGridArrowKey, from cardIndex: Int) -> Int {
            themeGridCardIndex(afterPressing: arrowKey, from: cardIndex, columnCount: 3, cardCount: 7)
        }
        #expect(move(.right, from: 0) == 1)
        #expect(move(.right, from: 2) == 3)
        #expect(move(.right, from: 6) == 6)
        #expect(move(.left, from: 0) == 0)
        #expect(move(.left, from: 3) == 2)
        #expect(move(.down, from: 1) == 4)
        #expect(move(.down, from: 4) == 6)
        #expect(move(.down, from: 6) == 6)
        #expect(move(.up, from: 4) == 1)
        #expect(move(.up, from: 2) == 2)
        #expect(move(.up, from: 6) == 3)
        #expect(themeGridCardIndex(afterPressing: .down, from: 0, columnCount: 3, cardCount: 0) == 0)
        // Down on a last row of two cards stays put, and never slides to the card beside it.
        #expect(themeGridCardIndex(afterPressing: .down, from: 6, columnCount: 3, cardCount: 8) == 6)
    }

    // MARK: - VoiceOver

    @Test func aDiscReadsItsPeekCardsLinesForVoiceOver() {
        let waitingAgent = agent(.running(completedStepCount: 0))
        let peekContent = agentTokenPeekContent(for: waitingAgent, approvalCapability: .readsPrivate, isWaitingForApproval: true, at: now)
        let label = agentDiscAccessibilityLabel(agentName: waitingAgent.displayName, peekContent: peekContent)
        #expect(label.hasPrefix(peekContent.title))
        #expect(label.contains("Needs your OK to read private data"))
        #expect(agentDiscAccessibilityLabel(agentName: "Task", peekContent: nil) == "Task")
    }
}
