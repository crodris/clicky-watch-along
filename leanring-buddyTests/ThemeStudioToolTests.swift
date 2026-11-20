//
//  ThemeStudioToolTests.swift
//  leanring-buddyTests
//
//  How the voice router meets the Theme Studio: the four tools and when each is offered, the keyword branch that opens the
//  studio and the router rule while it is open, the chip phrases, and the scene state the router reads.
//

import Foundation
import Testing
@testable import Clicky

struct ThemeStudioToolTests {
    private func context(studioIsOpen: Bool = false, studioShowsIdeas: Bool = false, quizQuestionIsOpen: Bool = false) -> AppVoiceTool.Context {
        var context = AppVoiceTool.Context(
            sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false,
            videoQuizIsRunning: false, quizQuestionIsOpen: quizQuestionIsOpen
        )
        context.themeStudioIsOpen = studioIsOpen
        context.themeStudioShowsIdeas = studioShowsIdeas
        return context
    }

    private func themeStudioTools(in context: AppVoiceTool.Context) -> Set<AppVoiceTool> {
        Set(AppVoiceTool.available(in: context)).intersection([.designTheme, .pickThemeIdea, .saveTheme, .closeThemeStudio])
    }

    @Test func withTheStudioClosedOnlyDesigningIsOffered() {
        #expect(themeStudioTools(in: context()) == [.designTheme])
    }

    @Test func whileTheStudioDesignsEveryToolButPickAndSaveIsOffered() {
        #expect(themeStudioTools(in: context(studioIsOpen: true)) == [.designTheme, .closeThemeStudio])
    }

    @Test func whileIdeasShowAllFourToolsAreOffered() {
        #expect(themeStudioTools(in: context(studioIsOpen: true, studioShowsIdeas: true)) == [.designTheme, .pickThemeIdea, .saveTheme, .closeThemeStudio])
    }

    @Test func aQuizQuestionHoldsBackDesigningBecauseTheAnswerIsTheLearnersToGive() {
        #expect(themeStudioTools(in: context(quizQuestionIsOpen: true)).isEmpty)
    }

    @Test func theToolNamesAreTheOnesTheRouterCalls() {
        #expect(AppVoiceTool.designTheme.rawValue == "design_theme")
        #expect(AppVoiceTool.pickThemeIdea.rawValue == "pick_theme_idea")
        #expect(AppVoiceTool.saveTheme.rawValue == "save_theme")
        #expect(AppVoiceTool.closeThemeStudio.rawValue == "close_theme_studio")
    }

    @Test func designThemeTakesTheWishTheIdeaToChangeAndWhetherToUseThePicture() {
        let descriptor = AppVoiceTool.designTheme.descriptor
        #expect(!descriptor.readOnly)
        #expect(descriptor.inputSchema["required"]?.arrayValue == [.string("request")])
        let properties = descriptor.inputSchema["properties"]
        #expect(properties?["request"]?["type"]?.stringValue == "string")
        #expect(properties?["basedOnIdea"]?["type"]?.stringValue == "number")
        #expect(properties?["fromPicture"]?["type"]?.stringValue == "boolean")
    }

    @Test func pickThemeIdeaRequiresANumberAndSaveAndCloseTakeNothing() {
        #expect(AppVoiceTool.pickThemeIdea.descriptor.inputSchema["required"]?.arrayValue == [.string("number")])
        #expect(AppVoiceTool.saveTheme.descriptor.inputSchema["required"]?.arrayValue == [])
        #expect(AppVoiceTool.closeThemeStudio.descriptor.inputSchema["required"]?.arrayValue == [])
    }

    @Test func theDebugEndpointOffersDesignThemeSinceItTakesItsRequestAsAnInput() {
        #expect(!AppVoiceTool.designTheme.needsTheSpokenRequest)
    }

    @Test func theFromPictureInputMapsToWhereThePictureComesFrom() {
        #expect(ThemeStudioPictureChoice(fromPictureInput: true) == .captureAgain)
        #expect(ThemeStudioPictureChoice(fromPictureInput: false) == ThemeStudioPictureChoice.none)
        #expect(ThemeStudioPictureChoice(fromPictureInput: nil) == .keepTheCardsPicture)
    }
}

struct ThemeStudioRouterRuleTests {
    private func call(_ name: String, _ input: [String: JSONValue] = [:]) -> VoiceToolCall {
        VoiceToolCall(id: "1", name: name, input: input)
    }

    @Test func pickingSayingAndClosingHaveChipPhrasesAndDesigningHasNone() {
        #expect(call("pick_theme_idea", ["number": .number(2)]).chipPhrase == "Trying idea 2")
        #expect(call("save_theme").chipPhrase == "Theme saved")
        #expect(call("close_theme_studio").chipPhrase == "Kept your old theme")
        // design_theme's card and spoken line follow at once.
        #expect(call("design_theme", ["request": .string("cozy")]).chipPhrase == nil)
    }

    @Test func aPickWithNoUsableNumberShowsNoChip() {
        #expect(call("pick_theme_idea").chipPhrase == nil)
        #expect(call("pick_theme_idea", ["number": .number(4)]).chipPhrase == nil)
        #expect(call("pick_theme_idea", ["number": .number(0)]).chipPhrase == nil)
        #expect(call("pick_theme_idea", ["number": .number(1.5)]).chipPhrase == nil)
        #expect(call("pick_theme_idea", ["number": .string("two")]).chipPhrase == nil)
    }

    @Test func aChipShowsOnlyOnceTheCallWorkedAndOnlyForAToolTheTurnOffered() {
        let offeredToolNames: Set<String> = ["pick_theme_idea", "save_theme", "close_theme_studio", "design_theme"]
        let pick = call("pick_theme_idea", ["number": .number(3)])
        #expect(pick.chipPhraseToShow(at: .beforeTheCall, offeredToolNames: offeredToolNames) == nil)
        #expect(pick.chipPhraseToShow(at: .afterTheCall(.changed(state: nil)), offeredToolNames: offeredToolNames) == "Trying idea 3")
        #expect(pick.chipPhraseToShow(at: .afterTheCall(.failed(error: "no idea", state: nil)), offeredToolNames: offeredToolNames) == nil)
        #expect(pick.chipPhraseToShow(at: .afterTheCall(.changed(state: nil)), offeredToolNames: []) == nil)
        let design = call("design_theme", ["request": .string("cozy")])
        #expect(design.chipPhraseToShow(at: .afterTheCall(.handedOff), offeredToolNames: offeredToolNames) == nil)
    }

    @Test func designingHandsOffSoTheRouterSaysNothingAfterIt() {
        let designCall = call("design_theme", ["request": .string("cozy")])
        #expect(voiceCommandNextStep(toolCalls: [designCall], outcomes: [.handedOff], replyText: "") == .finishSilently)
    }

    @Test func theRouterTakesEveryCommandWhileTheStudioIsOpenEvenWithNothingElseLive() {
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false) == false)
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, themeStudioIsOpen: true, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
        // A quiz answer still goes to the judge, and a scene still building keeps its keyword path.
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, themeStudioIsOpen: true, phaseIsWaitingForAQuizAnswer: true, sceneIsBuilding: false) == false)
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, themeStudioIsOpen: true, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: true) == false)
    }

    @Test func theRoutersMessageCarriesTheStudiosIdeasAndHighlight() throws {
        let ideas = try threeStudioIdeas()
        let sceneState = JSONValue.object(["themeStudio": try #require(voiceCommandThemeStudioState(.showingIdeas(ideas)))])
        let message = voiceCommandUserMessageText(transcript: "two", sceneState: sceneState, recentActionLines: [])
        #expect(message.contains(#""themeStudio":{"designing":false,"highlighted":1,"ideas":["Ember","Moonlit","Forest"]}"#))
    }
}

struct KeywordBranchForThemesTests {
    @Test func designATheme() {
        #expect(keywordBranchAheadOfTheRouter(
            for: "change my theme", brainTakesEveryRequest: false, sceneIsOnScreen: false,
            phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, themeStudioIsOpen: false
        ) == .designATheme(.fromWords))
        #expect(keywordBranchAheadOfTheRouter(
            for: "make my theme from this picture", brainTakesEveryRequest: false, sceneIsOnScreen: true,
            phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, themeStudioIsOpen: false
        ) == .designATheme(.fromThePicture))
    }

    @Test func theRouterReadsTheWordsWhenTheStudioIsOpenAQuizQuestionIsOpenOrTheBrainFlagIsOn() {
        func branch(brain: Bool = false, quiz: Bool = false, studioIsOpen: Bool = false) -> KeywordBranchAheadOfTheRouter? {
            keywordBranchAheadOfTheRouter(
                for: "change my theme", brainTakesEveryRequest: brain, sceneIsOnScreen: false,
                phaseIsWaitingForAQuizAnswer: quiz, sceneIsBuilding: false, themeStudioIsOpen: studioIsOpen
            )
        }
        #expect(branch(studioIsOpen: true) == nil)
        #expect(branch(quiz: true) == nil)
        #expect(branch(brain: true) == nil)
    }

    @Test func aThemeRequestDoesNotTakeOverTheOtherKeywordBranches() {
        #expect(keywordBranchAheadOfTheRouter(
            for: "let me try it", brainTakesEveryRequest: false, sceneIsOnScreen: false,
            phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, themeStudioIsOpen: false
        ) == .startExperiment)
        #expect(keywordBranchAheadOfTheRouter(
            for: "what is this", brainTakesEveryRequest: false, sceneIsOnScreen: false,
            phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, themeStudioIsOpen: false
        ) == nil)
    }

    @Test func aFailedRouterRequestOpensTheStudioWhenTheBrainFlagSkippedItsKeywordBranch() {
        #expect(routerFailureFallback(for: "change my theme", sceneIsOnScreen: false) == .designATheme(.fromWords))
        #expect(routerFailureFallback(for: "change my theme from this picture", sceneIsOnScreen: false) == .designATheme(.fromThePicture))
    }
}
