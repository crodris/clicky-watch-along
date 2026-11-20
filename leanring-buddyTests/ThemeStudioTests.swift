//
//  ThemeStudioTests.swift
//  leanring-buddyTests
//
//  The Theme Studio's state machine, the phrase that opens it, what the router reads about it, and the POST /theme-ideas
//  request and reply.
//

import Foundation
import Testing
@testable import Clicky

// MARK: - Fixtures

nonisolated func themeIdea(named ideaName: String, id: String = "idea-1") throws -> CustomTheme {
    try CustomTheme.parse(idea: replacingField(in: goodThemeIdea, at: ["name"], with: .string(ideaName)), id: id, pictureIsAvailable: false)
}

nonisolated let sampleStudioPicture = ThemeStudioPicture(jpegData: Data([0xFF, 0xD8, 0xFF, 0xD9]), width: 1280, height: 720)

/// Three ideas named Ember, Moonlit, and Forest with the first highlighted.
nonisolated func threeStudioIdeas(picture: ThemeStudioPicture? = nil) throws -> ThemeStudioIdeas {
    let ideas = [try themeIdea(named: "Ember", id: "idea-1"), try themeIdea(named: "Moonlit", id: "idea-2"), try themeIdea(named: "Forest", id: "idea-3")]
    return try #require(ThemeStudioIdeas(title: "Three ideas for a cozy night", ideas: ideas, picture: picture))
}

// MARK: - State machine

struct ThemeStudioStateTests {
    @Test func askingForIdeasOpensTheCardInTheDesigningStateWithNothingBehindIt() {
        #expect(ThemeStudioState.closed.startingADesign() == .designing(previousIdeas: nil))
    }

    @Test func askingForChangesDimsTheIdeasOnTheCardInsteadOfClearingThem() throws {
        let ideas = try threeStudioIdeas()
        #expect(ThemeStudioState.showingIdeas(ideas).startingADesign() == .designing(previousIdeas: ideas))
    }

    @Test func aNewDesignWhileOneRunsKeepsTheSamePreviousIdeas() throws {
        let ideas = try threeStudioIdeas()
        #expect(ThemeStudioState.designing(previousIdeas: ideas).startingADesign() == .designing(previousIdeas: ideas))
        #expect(ThemeStudioState.designing(previousIdeas: nil).startingADesign() == .designing(previousIdeas: nil))
    }

    @Test func arrivingIdeasReplaceTheCardOnlyWhileADesignRuns() throws {
        let arrivedIdeas = try threeStudioIdeas()
        #expect(ThemeStudioState.designing(previousIdeas: nil).withIdeasArrived(arrivedIdeas) == .showingIdeas(arrivedIdeas))
        #expect(ThemeStudioState.designing(previousIdeas: try threeStudioIdeas()).withIdeasArrived(arrivedIdeas) == .showingIdeas(arrivedIdeas))
        // A reply for a card the learner closed meanwhile, or for ideas already on show, changes nothing.
        #expect(ThemeStudioState.closed.withIdeasArrived(arrivedIdeas) == .closed)
        let otherIdeas = try #require(ThemeStudioIdeas(title: "Other", ideas: [try themeIdea(named: "Solo")], picture: nil))
        #expect(ThemeStudioState.showingIdeas(otherIdeas).withIdeasArrived(arrivedIdeas) == .showingIdeas(otherIdeas))
    }

    @Test func aFailedDesignGoesBackToThePreviousIdeasOrClosesTheCard() throws {
        let ideas = try threeStudioIdeas()
        #expect(ThemeStudioState.designing(previousIdeas: ideas).afterTheDesignFailed() == .showingIdeas(ideas))
        #expect(ThemeStudioState.designing(previousIdeas: nil).afterTheDesignFailed() == .closed)
        // A failure for a card that is no longer designing leaves it alone.
        #expect(ThemeStudioState.closed.afterTheDesignFailed() == .closed)
        #expect(ThemeStudioState.showingIdeas(ideas).afterTheDesignFailed() == .showingIdeas(ideas))
    }

    @Test func pickingAnIdeaHighlightsItByItsNumberCountingFromOne() throws {
        let ideas = try threeStudioIdeas()
        let pickedState = ThemeStudioState.showingIdeas(ideas).pickingIdea(number: 3)
        guard case .showingIdeas(let pickedIdeas) = pickedState else {
            Issue.record("expected ideas on show")
            return
        }
        #expect(pickedIdeas.highlightedIdeaIndex == 2)
        #expect(pickedIdeas.highlightedIdea.name == "Forest")
    }

    @Test func aNumberWithNoIdeaOrAStateWithNoIdeasOnShowPicksNothing() throws {
        let ideas = try threeStudioIdeas()
        for badNumber in [0, 4, -1] {
            #expect(ThemeStudioState.showingIdeas(ideas).pickingIdea(number: badNumber) == .showingIdeas(ideas))
        }
        #expect(ThemeStudioState.closed.pickingIdea(number: 1) == .closed)
        // Dimmed ideas cannot be picked while a new design runs.
        #expect(ThemeStudioState.designing(previousIdeas: ideas).pickingIdea(number: 2) == .designing(previousIdeas: ideas))
    }

    @Test func savingClosesTheCardOnlyWhenIdeasAreOnShow() throws {
        let ideas = try threeStudioIdeas()
        #expect(ThemeStudioState.showingIdeas(ideas).afterSaving() == .closed)
        #expect(ThemeStudioState.designing(previousIdeas: ideas).afterSaving() == .designing(previousIdeas: ideas))
        #expect(ThemeStudioState.closed.afterSaving() == .closed)
    }

    @Test func closingFromAnyStateClosesTheCard() throws {
        let ideas = try threeStudioIdeas()
        #expect(ThemeStudioState.showingIdeas(ideas).closing() == .closed)
        #expect(ThemeStudioState.designing(previousIdeas: ideas).closing() == .closed)
        #expect(ThemeStudioState.designing(previousIdeas: nil).closing() == .closed)
        #expect(ThemeStudioState.closed.closing() == .closed)
    }

    @Test func theStateReportsWhatIsOpenAndWhatTheCardShows() throws {
        let ideas = try threeStudioIdeas()
        #expect(!ThemeStudioState.closed.isOpen)
        #expect(ThemeStudioState.designing(previousIdeas: nil).isOpen)
        #expect(ThemeStudioState.designing(previousIdeas: nil).ideasOnTheCard == nil)
        #expect(ThemeStudioState.designing(previousIdeas: ideas).ideasOnTheCard == ideas)
        #expect(ThemeStudioState.showingIdeas(ideas).isShowingIdeas)
        #expect(!ThemeStudioState.designing(previousIdeas: ideas).isShowingIdeas)
    }

    @Test func aSetOfIdeasHoldsOneToThreeIdeasWithTheFirstHighlighted() throws {
        #expect(ThemeStudioIdeas(title: "None", ideas: [], picture: nil) == nil)
        let fourIdeas = try (1...4).map { try themeIdea(named: "Idea \($0)", id: "idea-\($0)") }
        let cutIdeas = try #require(ThemeStudioIdeas(title: "Four", ideas: fourIdeas, picture: nil))
        #expect(cutIdeas.ideas.count == 3)
        #expect(cutIdeas.highlightedIdeaIndex == 0)
    }
}

// MARK: - Opening the studio

struct AsksToDesignAThemeTests {
    @Test func themeWithAChangeWordNearbyOpensTheStudioFromTheWords() {
        let phrases = [
            "change my theme",
            "Hey Clicky, change my theme",
            "can you make me a new theme",
            "design a theme for night",
            "create a cozy theme",
            "customize my theme",
            "redo the theme",
            "I want a new theme",
            "make my theme something cozy for night",
        ]
        for phrase in phrases {
            #expect(asksToDesignATheme(phrase) == .fromWords, "\(phrase)")
        }
    }

    @Test func thePictureWordsMakeItARequestFromThePicture() {
        let phrases = [
            "make my theme from this picture",
            "make a theme from this image",
            "design a theme from this photo",
            "change my theme to match this",
            "Make my theme from THIS picture.",
        ]
        for phrase in phrases {
            #expect(asksToDesignATheme(phrase) == .fromThePicture, "\(phrase)")
        }
    }

    @Test func otherWordsAboutThePictureDoNotMakeItARequestFromThePicture() {
        #expect(asksToDesignATheme("change my theme, that picture is pretty") == .fromWords)
        #expect(asksToDesignATheme("make a theme, this is great") == .fromWords)
    }

    @Test func aThemeWithNoChangeWordNearbyOrNoThemeAtAllOpensNothing() {
        #expect(asksToDesignATheme("what is the theme of this video") == nil)
        #expect(asksToDesignATheme("change the playback speed") == nil)
        #expect(asksToDesignATheme("make a model of this engine") == nil)
        #expect(asksToDesignATheme("") == nil)
        // The change word is more than four words from "theme".
        #expect(asksToDesignATheme("make sure you tell me one more time about the theme") == nil)
    }
}

// MARK: - What the router reads

struct ThemeStudioRouterStateTests {
    @Test func theStudioShowsItsIdeaNamesTheHighlightedNumberAndWhetherADesignRuns() throws {
        let ideas = try threeStudioIdeas()
        #expect(voiceCommandThemeStudioState(.closed) == nil)
        #expect(voiceCommandThemeStudioState(.showingIdeas(ideas))?.compactJSONText
            == #"{"designing":false,"highlighted":1,"ideas":["Ember","Moonlit","Forest"]}"#)
        #expect(voiceCommandThemeStudioState(ThemeStudioState.showingIdeas(ideas).pickingIdea(number: 2))?.compactJSONText
            == #"{"designing":false,"highlighted":2,"ideas":["Ember","Moonlit","Forest"]}"#)
        #expect(voiceCommandThemeStudioState(.designing(previousIdeas: ideas))?.compactJSONText
            == #"{"designing":true,"highlighted":1,"ideas":["Ember","Moonlit","Forest"]}"#)
        #expect(voiceCommandThemeStudioState(.designing(previousIdeas: nil))?.compactJSONText == #"{"designing":true,"ideas":[]}"#)
    }
}

// MARK: - POST /theme-ideas

struct ThemeIdeasRequestTests {
    @Test func aPlainRequestSendsOnlyTheWords() throws {
        let themeIdeasRequest = try #require(ThemeIdeasRequest(request: "  something cozy for night ", currentIdeas: [], basedOnIdea: nil, picture: nil))
        #expect(themeIdeasRequest.json.compactJSONText == #"{"request":"something cozy for night"}"#)
    }

    @Test func anEmptyRequestIsNotSent() {
        #expect(ThemeIdeasRequest(request: "   ", currentIdeas: [], basedOnIdea: nil, picture: nil) == nil)
    }

    @Test func aRequestOver500CharactersIsCutToTheWorkersLimit() throws {
        let themeIdeasRequest = try #require(ThemeIdeasRequest(request: String(repeating: "a", count: 600), currentIdeas: [], basedOnIdea: nil, picture: nil))
        #expect(themeIdeasRequest.request.count == 500)
    }

    @Test func aRefinementSendsTheCurrentIdeasInTheReplysIdeaShapeAndTheIdeaToChange() throws {
        let ideas = try threeStudioIdeas().ideas
        let themeIdeasRequest = try #require(ThemeIdeasRequest(request: "make it a star", currentIdeas: ideas, basedOnIdea: 2, picture: nil))
        let json = themeIdeasRequest.json
        #expect(json["basedOnIdea"]?.numberValue == 2)
        #expect(json["currentIdeas"]?.arrayValue?.count == 3)
        #expect(json["currentIdeas"]?.arrayValue?[1] == ideas[1].ideaJSON)
        #expect(json["currentIdeas"]?.arrayValue?[1]["name"]?.stringValue == "Moonlit")
    }

    @Test func aBasedOnIdeaNeedsCurrentIdeasAndMustBeOneOfThem() throws {
        let ideas = try threeStudioIdeas().ideas
        #expect(ThemeIdeasRequest(request: "x", currentIdeas: [], basedOnIdea: 1, picture: nil)?.basedOnIdea == nil)
        #expect(ThemeIdeasRequest(request: "x", currentIdeas: ideas, basedOnIdea: 4, picture: nil)?.basedOnIdea == nil)
        #expect(ThemeIdeasRequest(request: "x", currentIdeas: ideas, basedOnIdea: 0, picture: nil)?.basedOnIdea == nil)
        #expect(ThemeIdeasRequest(request: "x", currentIdeas: ideas, basedOnIdea: 3, picture: nil)?.basedOnIdea == 3)
    }

    @Test func moreThanThreeCurrentIdeasAreCutToThree() throws {
        let fourIdeas = try (1...4).map { try themeIdea(named: "Idea \($0)", id: "idea-\($0)") }
        let themeIdeasRequest = try #require(ThemeIdeasRequest(request: "x", currentIdeas: fourIdeas, basedOnIdea: nil, picture: nil))
        #expect(themeIdeasRequest.currentIdeas.count == 3)
    }

    @Test func aPictureGoesAsBase64WithItsSize() throws {
        let themeIdeasRequest = try #require(ThemeIdeasRequest(request: "from this", currentIdeas: [], basedOnIdea: nil, picture: sampleStudioPicture))
        let pictureJSON = try #require(themeIdeasRequest.json["picture"])
        #expect(pictureJSON["jpegBase64"]?.stringValue == Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString())
        #expect(pictureJSON["width"]?.numberValue == 1280)
        #expect(pictureJSON["height"]?.numberValue == 720)
    }
}

struct ThemeIdeasReplyTests {
    private func replyJSON(ideas: [JSONValue]? = nil, title: JSONValue = .string("Three ideas for a cozy night"), spokenLine: JSONValue = .string("Here are three.")) -> Data {
        let reply = JSONValue.object([
            "title": title,
            "spokenLine": spokenLine,
            "ideas": .array(ideas ?? [goodThemeIdea, goodThemeIdea, goodThemeIdea]),
        ])
        return Data(reply.compactJSONText.utf8)
    }

    @Test func aGoodReplyParsesIntoThreeIdeasWithTemporaryIds() throws {
        let reply = try ThemeIdeasReply(responseData: replyJSON(), pictureWasSent: false)
        #expect(reply.title == "Three ideas for a cozy night")
        #expect(reply.spokenLine == "Here are three.")
        #expect(reply.ideas.map(\.id) == ["idea-1", "idea-2", "idea-3"])
    }

    @Test func aReplyWithTheWrongNumberOfIdeasOrBadTextIsRefused() {
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(ideas: []), pictureWasSent: false) }
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(ideas: Array(repeating: goodThemeIdea, count: 4)), pictureWasSent: false) }
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(title: .string("")), pictureWasSent: false) }
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(title: .string(String(repeating: "a", count: 61))), pictureWasSent: false) }
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(spokenLine: .string(String(repeating: "a", count: 161))), pictureWasSent: false) }
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(spokenLine: .null), pictureWasSent: false) }
    }

    @Test func oneBadIdeaRefusesTheWholeReply() {
        let badIdea = replacingField(in: goodThemeIdea, at: ["accent"], with: .string("#101211"))
        #expect(throws: CustomThemeParseError.self) {
            try ThemeIdeasReply(responseData: replyJSON(ideas: [goodThemeIdea, badIdea, goodThemeIdea]), pictureWasSent: false)
        }
    }

    @Test func anIdeaThatUsesThePictureNeedsTheRequestToHaveSentOne() throws {
        let ideas = [goodPictureCursorThemeIdea, goodThemeIdea, goodThemeIdea]
        #expect(throws: CustomThemeParseError.self) { try ThemeIdeasReply(responseData: replyJSON(ideas: ideas), pictureWasSent: false) }
        let reply = try ThemeIdeasReply(responseData: replyJSON(ideas: ideas), pictureWasSent: true)
        #expect(reply.ideas[0].usesPicture)
    }

    @Test func aReplyThatIsNotJSONThrows() {
        #expect(throws: (any Error).self) { try ThemeIdeasReply(responseData: Data("not json".utf8), pictureWasSent: false) }
    }
}
