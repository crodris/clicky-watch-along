//
//  AgentTokenTests.swift
//  leanring-buddyTests
//
//  The agent tokens beside the notch: which agents have a token and in what rank, how many discs fit, which tokens
//  show in which position (stability, "+N"), the free space rules, the ring color per theme, and how a waiting result
//  keeps its token.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct AgentTokenTests {
    private let startedAt = Date(timeIntervalSince1970: 1_000)

    private func agent(
        _ phase: BackgroundAgentPhase,
        kind: BackgroundAgentKind = .task,
        startedAfter secondsAfterStart: TimeInterval = 0,
        endedAfter secondsToEnd: TimeInterval? = nil,
        resultIsWaiting: Bool = false,
        player: HaikyuPlayer? = nil
    ) -> BackgroundAgent {
        let agentStartedAt = startedAt.addingTimeInterval(secondsAfterStart)
        return BackgroundAgent(
            id: UUID(),
            kind: kind,
            subject: nil,
            studyGuideVideoKey: nil,
            startedAt: agentStartedAt,
            currentStepStartedAt: agentStartedAt,
            endedAt: secondsToEnd.map { agentStartedAt.addingTimeInterval($0) },
            phase: phase,
            player: player,
            resultIsWaitingToBeDelivered: resultIsWaiting
        )
    }

    private func agentIDs(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: - Which agents have a token

    @Test func aTokenShowsWhileRunningAndForFourSecondsAfterAnEndButNotAfterACancel() async throws {
        let guideURL = try #require(URL(string: "https://www.notion.so/p1"))
        let finishedGuide = agent(.finished(.notionPage(guideURL)), kind: .studyGuide, endedAfter: 10)
        let endedAt = startedAt.addingTimeInterval(10)
        #expect(agent(.running(completedStepCount: 1)).tokenRank(at: endedAt.addingTimeInterval(500)) == .running)
        #expect(finishedGuide.tokenRank(at: endedAt.addingTimeInterval(3.9)) == .ending)
        #expect(finishedGuide.tokenRank(at: endedAt.addingTimeInterval(4)) == nil)
        let failedAgent = agent(.failed(reason: "x"), endedAfter: 10)
        #expect(failedAgent.tokenRank(at: endedAt.addingTimeInterval(1)) == .ending)
        #expect(failedAgent.tokenRank(at: endedAt.addingTimeInterval(4)) == nil)
        #expect(agent(.cancelled, endedAfter: 10).tokenRank(at: endedAt) == nil)
    }

    @Test func aWaitingResultKeepsItsTokenForTenMinutesAndAnythingDeliveredLeavesAfterItsChip() async throws {
        let waitingModel = agent(.finished(.readyScene), kind: .threeDModel, endedAfter: 20, resultIsWaiting: true)
        let endedAt = startedAt.addingTimeInterval(20)
        #expect(waitingModel.tokenRank(at: endedAt.addingTimeInterval(2)) == .waitingResult)
        #expect(waitingModel.tokenRank(at: endedAt.addingTimeInterval(599)) == .waitingResult)
        #expect(waitingModel.tokenRank(at: endedAt.addingTimeInterval(600)) == nil)

        // Delivered inside the 4 seconds of its chip, it stays until the chip ends. Delivered later, it is already gone.
        let deliveredModel = agent(.finished(.readyScene), kind: .threeDModel, endedAfter: 20, resultIsWaiting: false)
        #expect(deliveredModel.tokenRank(at: endedAt.addingTimeInterval(3)) == .ending)
        #expect(deliveredModel.tokenRank(at: endedAt.addingTimeInterval(30)) == nil)
    }

    @Test func tokensRankRunningThenWaitingResultsThenEndingsAndTheNewestComesFirstInEachRank() async throws {
        let olderRunning = agent(.running(completedStepCount: 0), startedAfter: 0)
        let newerRunning = agent(.running(completedStepCount: 0), startedAfter: 5)
        let olderWaiting = agent(.finished(.readyScene), kind: .threeDModel, startedAfter: 0, endedAfter: 20, resultIsWaiting: true)
        let newerWaiting = agent(.finished(.answer(spokenSummary: "x", pageURL: nil)), startedAfter: 0, endedAfter: 30, resultIsWaiting: true)
        let failed = agent(.failed(reason: "x"), startedAfter: 0, endedAfter: 31)
        let cancelled = agent(.cancelled, startedAfter: 0, endedAfter: 31)
        let ranked = agentsWithTokens(
            from: [failed, olderWaiting, cancelled, olderRunning, newerWaiting, newerRunning],
            at: startedAt.addingTimeInterval(32)
        )
        #expect(ranked.map(\.id) == [newerRunning, olderRunning, newerWaiting, olderWaiting, failed].map(\.id))
    }

    @Test func theStoreKeepsAResultWaitingUntilItIsDeliveredAndANewerResultReplacesIt() async throws {
        let store = makeBackgroundAgentStore()
        let modelAgentID = store.start(kind: .threeDModel)
        let guideAgentID = store.start(kind: .studyGuide)
        let taskAgentID = store.start(kind: .task)
        store.finish(modelAgentID, with: .readyScene)
        store.finish(guideAgentID, with: .notionPage(try #require(URL(string: "https://www.notion.so/p1"))))
        store.finish(taskAgentID, with: .answer(spokenSummary: "x", pageURL: nil))
        func isWaiting(_ agentID: UUID) -> Bool? { store.agents.first { $0.id == agentID }?.resultIsWaitingToBeDelivered }
        #expect(isWaiting(modelAgentID) == true)
        #expect(isWaiting(guideAgentID) == false)
        #expect(isWaiting(taskAgentID) == true)

        store.setResultIsWaiting(false, for: modelAgentID)
        #expect(isWaiting(modelAgentID) == false)
        // A scene that was about to rise and has to wait after all gets its token back.
        store.setResultIsWaiting(true, for: modelAgentID)
        #expect(isWaiting(modelAgentID) == true)

        // A running agent has no result to wait for.
        let runningAgentID = store.start(kind: .experiment)
        store.setResultIsWaiting(true, for: runningAgentID)
        #expect(isWaiting(runningAgentID) == false)
    }

    // MARK: - Positions

    @Test func nothingFloatsWhereNotOneDiscFits() async throws {
        let ranked = agentIDs(2)
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: ranked, positionCount: 0) == AgentTokenLayout(shownAgentIDs: [], overflowCount: 0))
    }

    @Test func everyAgentShowsWhenTheyFitInThreeOrFewerPositions() async throws {
        let ranked = agentIDs(3)
        for positionCount in 3...4 {
            let layout = agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: ranked, positionCount: positionCount)
            #expect(layout == AgentTokenLayout(shownAgentIDs: ranked, overflowCount: 0))
        }
        let twoAgents = Array(ranked.prefix(2))
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: twoAgents, positionCount: 2) == AgentTokenLayout(shownAgentIDs: twoAgents, overflowCount: 0))
        let oneAgent = Array(ranked.prefix(1))
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: oneAgent, positionCount: 1) == AgentTokenLayout(shownAgentIDs: oneAgent, overflowCount: 0))
    }

    @Test func theLastPositionBecomesAPlusNDiscWhenTheAgentsDoNotFit() async throws {
        let ranked = agentIDs(6)
        // Four positions: three tokens and a "+3".
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: Array(ranked.prefix(4)), positionCount: 4) == AgentTokenLayout(shownAgentIDs: Array(ranked.prefix(3)), overflowCount: 1))
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: ranked, positionCount: 4) == AgentTokenLayout(shownAgentIDs: Array(ranked.prefix(3)), overflowCount: 3))
        // Three positions: two tokens and a "+N". Two positions: one token and a "+N". One position: only the "+N" disc.
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: Array(ranked.prefix(4)), positionCount: 3) == AgentTokenLayout(shownAgentIDs: Array(ranked.prefix(2)), overflowCount: 2))
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: Array(ranked.prefix(3)), positionCount: 2) == AgentTokenLayout(shownAgentIDs: Array(ranked.prefix(1)), overflowCount: 2))
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: Array(ranked.prefix(2)), positionCount: 1) == AgentTokenLayout(shownAgentIDs: [], overflowCount: 2))
        // More than four positions are never used.
        #expect(agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: ranked, positionCount: 9) == AgentTokenLayout(shownAgentIDs: Array(ranked.prefix(3)), overflowCount: 3))
    }

    @Test func aShownTokenIsNeverDisplacedWhenAHigherRankedAgentArrives() async throws {
        let shownIDs = agentIDs(2)
        let newRunningID = UUID()
        // The new running agent ranks first, but the two tokens already floating keep their positions, and it takes the open one.
        let layout = agentTokenLayout(previouslyShownAgentIDs: shownIDs, rankedAgentIDs: [newRunningID] + shownIDs, positionCount: 4)
        #expect(layout == AgentTokenLayout(shownAgentIDs: shownIDs + [newRunningID], overflowCount: 0))

        // With every token position taken, the newcomer waits in "+1" however high it ranks.
        let threeShownIDs = agentIDs(3)
        let fullLayout = agentTokenLayout(previouslyShownAgentIDs: threeShownIDs, rankedAgentIDs: [newRunningID] + threeShownIDs, positionCount: 4)
        #expect(fullLayout == AgentTokenLayout(shownAgentIDs: threeShownIDs, overflowCount: 1))
    }

    @Test func aTokenThatLeavesClosesTheGapAndTheNextByRankFillsTheOpenPosition() async throws {
        let first = UUID(), failed = UUID(), third = UUID(), waitingInPlusN = UUID()
        let beforeTheFailedTokenLeaves = agentTokenLayout(previouslyShownAgentIDs: [], rankedAgentIDs: [first, third, waitingInPlusN, failed], positionCount: 4)
        #expect(beforeTheFailedTokenLeaves.shownAgentIDs == [first, third, waitingInPlusN])
        // The failed token holds its slot through its chip even though the running agent waits in "+N".
        let whileTheFailedTokenHoldsItsSlot = agentTokenLayout(previouslyShownAgentIDs: [first, failed, third], rankedAgentIDs: [first, third, waitingInPlusN, failed], positionCount: 4)
        #expect(whileTheFailedTokenHoldsItsSlot == AgentTokenLayout(shownAgentIDs: [first, failed, third], overflowCount: 1))
        // When it leaves, the others close the gap and the waiting agent takes the open position, with no "+N" left.
        let afterTheFailedTokenLeaves = agentTokenLayout(previouslyShownAgentIDs: [first, failed, third], rankedAgentIDs: [first, third, waitingInPlusN], positionCount: 4)
        #expect(afterTheFailedTokenLeaves == AgentTokenLayout(shownAgentIDs: [first, third, waitingInPlusN], overflowCount: 0))
    }

    @Test func whenLessSpaceOpensUpTheTokensAtTheEndGiveWay() async throws {
        let shownIDs = agentIDs(3)
        let layout = agentTokenLayout(previouslyShownAgentIDs: shownIDs, rankedAgentIDs: shownIDs, positionCount: 2)
        #expect(layout == AgentTokenLayout(shownAgentIDs: [shownIDs[0]], overflowCount: 2))
        // The "+N" disc needing its position also takes the last token's, as the spec's "last position" rule says.
        let fourAgents = agentIDs(4)
        let threePositions = agentTokenLayout(previouslyShownAgentIDs: Array(fourAgents.prefix(3)), rankedAgentIDs: fourAgents, positionCount: 3)
        #expect(threePositions == AgentTokenLayout(shownAgentIDs: Array(fourAgents.prefix(2)), overflowCount: 2))
    }

    @Test func aTokenForAnAgentThatNoLongerHasOneIsDroppedFromItsPosition() async throws {
        let shownIDs = agentIDs(3)
        let layout = agentTokenLayout(previouslyShownAgentIDs: shownIDs, rankedAgentIDs: [shownIDs[0], shownIDs[2]], positionCount: 4)
        #expect(layout == AgentTokenLayout(shownAgentIDs: [shownIDs[0], shownIDs[2]], overflowCount: 0))
    }

    // MARK: - Free space

    @Test func discsFitWhileThereIsRoomForTheirGapsAndTheEdges() async throws {
        // 10 before the first disc, 6 before the status icon, and n discs take 28n - 6.
        #expect(agentTokenPositionCount(freeSpaceMinX: 948, endOfFreeSpaceX: 948 + 218) == 4)
        #expect(agentTokenPositionCount(freeSpaceMinX: 0, endOfFreeSpaceX: 10 + 28 * 3 - 6 + 6) == 3)
        #expect(agentTokenPositionCount(freeSpaceMinX: 0, endOfFreeSpaceX: 10 + 28 * 3 - 6 + 6 - 1) == 2)
        #expect(agentTokenPositionCount(freeSpaceMinX: 0, endOfFreeSpaceX: 10 + 22 + 6) == 1)
        #expect(agentTokenPositionCount(freeSpaceMinX: 0, endOfFreeSpaceX: 10 + 22 + 6 - 1) == 0)
        #expect(agentTokenPositionCount(freeSpaceMinX: 500, endOfFreeSpaceX: 400) == 0)
    }

    @Test func freeSpaceStartsAtTheNotchOrPastTheMenusThatContinuePastIt() async throws {
        #expect(agentTokenFreeSpaceMinX(notchMaxX: 948, screenMidX: 855, lastMenuTitleMaxX: nil) == 948)
        // Menus that end before or behind the notch change nothing.
        #expect(agentTokenFreeSpaceMinX(notchMaxX: 948, screenMidX: 855, lastMenuTitleMaxX: 700) == 948)
        #expect(agentTokenFreeSpaceMinX(notchMaxX: 948, screenMidX: 855, lastMenuTitleMaxX: 948) == 948)
        // Menus that continue past the notch push the start 8 points past the last title.
        #expect(agentTokenFreeSpaceMinX(notchMaxX: 948, screenMidX: 855, lastMenuTitleMaxX: 1010) == 1018)
    }

    @Test func withNoNotchFreeSpaceStartsAtTheCenterOrPastTheLastMenuTitleWhicheverIsFurtherRight() async throws {
        #expect(agentTokenFreeSpaceMinX(notchMaxX: nil, screenMidX: 960, lastMenuTitleMaxX: nil) == 960)
        #expect(agentTokenFreeSpaceMinX(notchMaxX: nil, screenMidX: 960, lastMenuTitleMaxX: 500) == 960)
        #expect(agentTokenFreeSpaceMinX(notchMaxX: nil, screenMidX: 960, lastMenuTitleMaxX: 1200) == 1208)
    }

    @Test func theFirstStatusIconRightOfTheFreeSpaceInsideTheMenuBarEndsIt() async throws {
        let menuBarStrip = CGRect(x: 0, y: 0, width: 1710, height: 33)
        let statusWindowFrames = [
            CGRect(x: 1400, y: 0, width: 30, height: 33),
            CGRect(x: 1166, y: 0, width: 30, height: 33),
            // Left of the free space, so it is another item's window and does not narrow it.
            CGRect(x: 100, y: 0, width: 30, height: 33),
            // A window on the status layer far below the menu bar.
            CGRect(x: 1000, y: 600, width: 30, height: 33),
        ]
        #expect(firstStatusIconMinX(statusWindowFrames: statusWindowFrames, menuBarStrip: menuBarStrip, rightOf: 948) == 1166)
        #expect(firstStatusIconMinX(statusWindowFrames: [], menuBarStrip: menuBarStrip, rightOf: 948) == nil)
    }

    @Test func aMenuBarShowsOnlyWhileTheVisibleFrameLeavesRoomForIt() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        #expect(menuBarIsShowing(screenFrame: screenFrame, visibleFrame: CGRect(x: 0, y: 0, width: 1710, height: 1073)))
        // Full screen or a hidden menu bar: the visible frame reaches the top edge.
        #expect(!menuBarIsShowing(screenFrame: screenFrame, visibleFrame: screenFrame))
    }

    // MARK: - Each agent's own color

    @Test func theKindColorsAndTheSpareColorsAreTheSixPaletteColorsInOrder() async throws {
        #expect(AgentPaletteColor.fixedPalette == [.teal, .amber, .violet, .lime, .sky, .pink])
        #expect(AgentPaletteColor.teal.color == Color(hex: "#2dd4bf"))
        #expect(AgentPaletteColor.amber.color == Color(hex: "#FFB020"))
        #expect(AgentPaletteColor.violet.color == Color(hex: "#a78bfa"))
        #expect(AgentPaletteColor.lime.color == Color(hex: "#84cc16"))
        #expect(AgentPaletteColor.sky.color == Color(hex: "#38bdf8"))
        #expect(AgentPaletteColor.pink.color == Color(hex: "#f472b6"))
        #expect(BackgroundAgentKind.studyGuide.preferredPaletteColor == .amber)
        #expect(BackgroundAgentKind.studyGuideUpdate.preferredPaletteColor == .amber)
        #expect(BackgroundAgentKind.threeDModel.preferredPaletteColor == .violet)
        #expect(BackgroundAgentKind.experiment.preferredPaletteColor == .lime)
        #expect(BackgroundAgentKind.task.preferredPaletteColor == .teal)
    }

    @Test func anAgentTakesItsKindColorWhenNoOneElseHasIt() async throws {
        #expect(agentPaletteColorToAssign(forKind: .task, colorsInUse: []) == .teal)
        #expect(agentPaletteColorToAssign(forKind: .threeDModel, colorsInUse: [.teal, .amber]) == .violet)
    }

    @Test func anAgentWhoseKindColorIsTakenGetsTheFirstPaletteColorNoOneHas() async throws {
        #expect(agentPaletteColorToAssign(forKind: .task, colorsInUse: [.teal]) == .amber)
        #expect(agentPaletteColorToAssign(forKind: .task, colorsInUse: [.teal, .amber]) == .violet)
        // The first free color skips one that a different kind already holds.
        #expect(agentPaletteColorToAssign(forKind: .studyGuide, colorsInUse: [.amber, .teal, .violet]) == .lime)
    }

    @Test func theColorsNeverRepeatUntilAllSixAreInUseAndThenTheyCycleThroughThePalette() async throws {
        var colorsInUse: [AgentPaletteColor] = []
        for _ in 0..<6 {
            colorsInUse.append(agentPaletteColorToAssign(forKind: .task, colorsInUse: colorsInUse))
        }
        #expect(colorsInUse == [.teal, .amber, .violet, .lime, .sky, .pink])
        #expect(agentPaletteColorToAssign(forKind: .task, colorsInUse: colorsInUse) == .teal)
        colorsInUse.append(.teal)
        #expect(agentPaletteColorToAssign(forKind: .task, colorsInUse: colorsInUse) == .amber)
        colorsInUse.append(.amber)
        #expect(agentPaletteColorToAssign(forKind: .task, colorsInUse: colorsInUse) == .violet)
    }

    @Test func threeTaskAgentsGetThreeDifferentColorsAndKeepThemForTheirWholeLife() async throws {
        let store = makeBackgroundAgentStore()
        let firstTaskID = store.start(kind: .task)
        let secondTaskID = store.start(kind: .task)
        let thirdTaskID = store.start(kind: .task)
        func color(of agentID: UUID) -> AgentPaletteColor? { store.agents.first { $0.id == agentID }?.tokenColor }
        #expect([firstTaskID, secondTaskID, thirdTaskID].map(color(of:)) == [.teal, .amber, .violet])
        // A later agent starting, finishing, or failing never recolors an agent that already has its color.
        store.start(kind: .studyGuide)
        store.fail(secondTaskID, reason: "x")
        #expect([firstTaskID, secondTaskID, thirdTaskID].map(color(of:)) == [.teal, .amber, .violet])
        #expect(store.displayColor(for: secondTaskID) == .amber)
    }

    @Test func aKindColorIsReusedOnceTheAgentThatHeldItLeavesButNotWhileItsResultWaits() async throws {
        let store = makeBackgroundAgentStore()
        let firstModelID = store.start(kind: .threeDModel)
        #expect(store.agents.first { $0.id == firstModelID }?.tokenColor == .violet)
        // Its result waits to be shown, so the agent still holds violet and the next model gets a spare color.
        store.finish(firstModelID, with: .readyScene)
        let secondModelID = store.start(kind: .threeDModel)
        #expect(store.agents.first { $0.id == secondModelID }?.tokenColor == .teal)
        // Once the first model's result is shown, and a cancelled agent too, violet is free again.
        store.setResultIsWaiting(false, for: firstModelID)
        store.cancel(secondModelID)
        let thirdModelID = store.start(kind: .threeDModel)
        #expect(store.agents.first { $0.id == thirdModelID }?.tokenColor == .violet)
    }

    @Test func anAgentThatIsATeamPlayerHasNoAssignedColorAndNeverTakesOneAwayFromOthers() async throws {
        let store = makeBackgroundAgentStore(theme: .school(.karasuno))
        let playerAgentID = store.start(kind: .task)
        #expect(store.agents.first { $0.id == playerAgentID }?.tokenColor == nil)
        #expect(store.agents.first { $0.id == playerAgentID }?.player != nil)
    }

    // MARK: - Clicks and the list's buttons

    @Test func theSameAgentOnTwoDisplaysIsTwoDiscsSoAClickOnTheOtherOneMovesTheList() async throws {
        let agentID = UUID()
        let onTheLaptop = AgentTokenDiscID(displayID: 1, tokenSlot: .agent(agentID))
        #expect(onTheLaptop == AgentTokenDiscID(displayID: 1, tokenSlot: .agent(agentID)))
        #expect(onTheLaptop != AgentTokenDiscID(displayID: 2, tokenSlot: .agent(agentID)))
        #expect(onTheLaptop != AgentTokenDiscID(displayID: 1, tokenSlot: .agent(UUID())))
        #expect(AgentTokenDiscID(displayID: 1, tokenSlot: .overflow) != AgentTokenDiscID(displayID: 2, tokenSlot: .overflow))
    }

    @Test func theAgentListDeliversAWaitingResultUnderTheSameRuleAsTheVoiceTools() async throws {
        var voiceToolContext = AppVoiceTool.Context(sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: true, videoIsOnYouTube: true, videoQuizIsRunning: true, quizQuestionIsOpen: false)
        voiceToolContext.backgroundSceneIsReady = true
        voiceToolContext.taskAnswerIsReady = true
        for aVideoQuizQuestionIsOpen in [false, true] {
            voiceToolContext.quizQuestionIsOpen = aVideoQuizQuestionIsOpen
            let availableVoiceTools = AppVoiceTool.available(in: voiceToolContext)
            let listMayDeliver = agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: aVideoQuizQuestionIsOpen)
            #expect(availableVoiceTools.contains(.showReadyModel) == listMayDeliver)
            #expect(availableVoiceTools.contains(.hearTaskAnswer) == listMayDeliver)
        }
    }

    @Test func theStorePublishesWhenAQuizQuestionOpensSoAnOpenListRedrawsItsButtons() async throws {
        let store = makeBackgroundAgentStore()
        var changesPublished = 0
        let subscription = store.objectWillChange.sink { changesPublished += 1 }
        #expect(agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: store.aVideoQuizQuestionIsOpen))
        store.aVideoQuizQuestionIsOpen = true
        #expect(changesPublished == 1)
        #expect(!agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: store.aVideoQuizQuestionIsOpen))
        store.aVideoQuizQuestionIsOpen = false
        #expect(changesPublished == 2)
        subscription.cancel()
    }

    // MARK: - Ring color

    @Test func theRingTakesTheTeamColorForAPlayerAndTheKindColorUnderClickyBlue() async throws {
        let player = HaikyuSchool.karasuno.roster[0]
        #expect(agentTokenRingColorChoice(for: agent(.running(completedStepCount: 0), player: player)) == .school(.karasuno))
        #expect(agentTokenRingColorChoice(for: agent(.running(completedStepCount: 0), kind: .experiment)) == .assigned(.lime))
        #expect(agentTokenRingColorChoice(for: agent(.finished(.readyScene), kind: .threeDModel, endedAfter: 5, player: player)) == .school(.karasuno))
    }

    @Test func aFailedTokenIsRedWhateverTheTeamAndInarizakisRingIsTheLightColor() async throws {
        let player = HaikyuSchool.nekoma.roster[0]
        #expect(agentTokenRingColorChoice(for: agent(.failed(reason: "x"), endedAfter: 5, player: player)) == .failed)
        #expect(agentTokenRingColorChoice(for: agent(.failed(reason: "x"), kind: .experiment, endedAfter: 5)) == .failed)
        #expect(AgentTokenRingColorChoice.failed.color == DS.Colors.destructive)
        // Inarizaki's near-black team color would vanish on the dark ring track, so its accent is already the light color.
        #expect(HaikyuSchool.inarizaki.accentHex == "#F4F4F5")
        #expect(AgentTokenRingColorChoice.school(.inarizaki).color == HaikyuSchool.inarizaki.accentColor)
        #expect(AgentTokenRingColorChoice.assigned(.teal).color == DS.Colors.backgroundAgentTaskTeal)
    }
}
