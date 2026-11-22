//
//  EscapeOrderTests.swift
//  leanring-buddyTests
//

import Testing
@testable import Clicky

struct EscapeOrderTests {
    /// Every fact in the Escape order, first to last, with the step it gives.
    private let escapeOrder: [(fact: WritableKeyPath<EscapeFacts, Bool>, step: EscapeStep)] = [
        (\.aTextFieldIsBeingEdited, .leaveItToTheTextField),
        (\.theMenuPanelTookTheEscape, .leaveItToTheMenuPanel),
        (\.theSettingsDialIsOpen, .leaveItToTheSettingsDial),
        (\.theAgentListIsOpen, .closeTheAgentList),
        (\.theThemeStudioIsOpen, .closeTheThemeStudio),
        (\.anAddThemeCardIsOpen, .declineTheAddThemeCard),
        (\.theRoomArtPanelTakesEscape, .closeTheRoomArtPanel),
        (\.theRecapIsGatheringTheDiscs, .stopTheRecapGather),
        (\.theQuizSummaryIsShowing, .closeTheQuizSummary),
        (\.anInstantReplayIsOpen, .endTheInstantReplay),
        (\.aPopOutIsReturningToSource, .hideThePopOutAtOnce),
        (\.aVideoQuizQuestionIsOpen, .skipTheQuizQuestion),
        (\.noSceneIsUp, .stopTheReply),
        (\.aFinishedSceneShowsAllItsLabels, .clearTheFinishedScene),
    ]

    @Test func eachSurfaceAloneTakesTheEscape() {
        #expect(escapeStep(for: EscapeFacts()) == .nothing)
        for (fact, step) in escapeOrder {
            var facts = EscapeFacts()
            facts[keyPath: fact] = true
            #expect(escapeStep(for: facts) == step, "\(fact) alone should give \(step)")
        }
    }

    @Test func aSurfaceTakesTheEscapeAheadOfEverySurfaceAfterIt() {
        for (index, entry) in escapeOrder.enumerated() {
            var facts = EscapeFacts()
            for (laterFact, _) in escapeOrder[index...] {
                facts[keyPath: laterFact] = true
            }
            #expect(escapeStep(for: facts) == entry.step, "\(entry.fact) should come before every fact after it")
        }
    }

    @Test func theRoomArtPanelTakesTheEscapeAfterTheAddThemeCardAndAheadOfTheRecapAndTheScene() {
        let roomArtAndTheScene = EscapeFacts(theRoomArtPanelTakesEscape: true, aVideoQuizQuestionIsOpen: true, aFinishedSceneShowsAllItsLabels: true)
        #expect(escapeStep(for: roomArtAndTheScene) == .closeTheRoomArtPanel)
        #expect(escapeStep(for: EscapeFacts(theRoomArtPanelTakesEscape: true, theRecapIsGatheringTheDiscs: true)) == .closeTheRoomArtPanel)
        #expect(escapeStep(for: EscapeFacts(anAddThemeCardIsOpen: true, theRoomArtPanelTakesEscape: true)) == .declineTheAddThemeCard)
    }
}
