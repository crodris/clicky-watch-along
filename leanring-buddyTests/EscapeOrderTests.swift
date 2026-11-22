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
    ]

    /// No surface is open, so the scene decides.
    private func step(withTheScene sceneOnScreen: EscapeSceneState) -> EscapeStep {
        escapeStep(for: EscapeFacts(sceneOnScreen: sceneOnScreen))
    }

    @Test func withNoSurfaceOpenTheSceneDecides() {
        #expect(step(withTheScene: .none) == .stopTheReply)
        #expect(step(withTheScene: .finishedWithAllLabels) == .clearTheFinishedScene)
        #expect(step(withTheScene: .buildingOrTouringOrAsking) == .nothing)
    }

    @Test func eachSurfaceAloneTakesTheEscape() {
        for (fact, step) in escapeOrder {
            // A scene that would clear sits behind every surface.
            var facts = EscapeFacts(sceneOnScreen: .finishedWithAllLabels)
            facts[keyPath: fact] = true
            #expect(escapeStep(for: facts) == step, "\(fact) alone should give \(step)")
        }
    }

    @Test func aSurfaceTakesTheEscapeAheadOfEverySurfaceAfterIt() {
        for (index, entry) in escapeOrder.enumerated() {
            var facts = EscapeFacts(sceneOnScreen: .finishedWithAllLabels)
            for (laterFact, _) in escapeOrder[index...] {
                facts[keyPath: laterFact] = true
            }
            #expect(escapeStep(for: facts) == entry.step, "\(entry.fact) should come before every fact after it")
        }
    }

    @Test func theRoomArtPanelTakesTheEscapeAfterTheAddThemeCardAndAheadOfTheRecapAndTheScene() {
        let roomArtAndTheScene = EscapeFacts(theRoomArtPanelTakesEscape: true, aVideoQuizQuestionIsOpen: true, sceneOnScreen: .finishedWithAllLabels)
        #expect(escapeStep(for: roomArtAndTheScene) == .closeTheRoomArtPanel)
        #expect(escapeStep(for: EscapeFacts(theRoomArtPanelTakesEscape: true, theRecapIsGatheringTheDiscs: true)) == .closeTheRoomArtPanel)
        #expect(escapeStep(for: EscapeFacts(anAddThemeCardIsOpen: true, theRoomArtPanelTakesEscape: true)) == .declineTheAddThemeCard)
    }
}
