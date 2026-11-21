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
    @Test func aRequestWordAndAnOwnerWordBeforeThemeOpenTheStudioFromTheWords() {
        let phrases = [
            "change my theme",
            "Hey Clicky, change my theme",
            "make me a new theme",
            "can you make me a new theme",
            "give me a new theme",
            "create a theme",
            "customize my theme",
            "customise my theme",
            "redo my theme",
            "switch my theme",
            "change your theme",
            "change Clicky's theme",
            "change Clicky\u{2019}s theme",
            "change Clickys theme",
            "make my theme something cozy for night",
        ]
        for phrase in phrases {
            #expect(asksToDesignATheme(phrase) == .fromWords, "\(phrase)")
        }
    }

    @Test func newThemeAloneOrWithPleaseIsARequestButNotInsideAQuestion() {
        let phrases = [
            "new theme", "New theme.", "new theme please", "Hey Clicky, new theme please",
            "Clicky, new theme", "okay Clicky, new theme", "new theme, Clicky", "a new theme please",
        ]
        for phrase in phrases {
            #expect(asksToDesignATheme(phrase) == .fromWords, "\(phrase)")
        }
        // The same words inside a longer utterance ask about a theme that already exists.
        for phrase in ["what's the new theme please", "tell me about the new theme", "new theme in chapter two", "I love the new theme please"] {
            #expect(asksToDesignATheme(phrase) == nil, "\(phrase)")
        }
    }

    @Test func thePictureWordsMakeItARequestFromThePicture() {
        let phrases = [
            "make my theme from this picture",
            "make a theme from this image",
            "design a theme from this photo",
            "design a theme from this picture",
            "design me a theme from this picture",
            "change my theme to match this",
            "Make my theme from THIS picture.",
        ]
        for phrase in phrases {
            #expect(asksToDesignATheme(phrase) == .fromThePicture, "\(phrase)")
        }
    }

    @Test func otherWordsAboutThePictureDoNotMakeItARequestFromThePicture() {
        #expect(asksToDesignATheme("change my theme, that picture is pretty") == .fromWords)
        #expect(asksToDesignATheme("make a theme please, this is great") == .fromWords)
        // Natural requests with a want word or one word between the owner and "theme".
        #expect(asksToDesignATheme("I want a new theme") == .fromWords)
        #expect(asksToDesignATheme("create a cozy theme") == .fromWords)
        #expect(asksToDesignATheme("can I get a different theme") == .fromWords)
        #expect(asksToDesignATheme("I'd like to try a darker theme from this picture") == .fromThePicture)
        // A possessive "'s" comes off, so "theme's" and "image's" read as "theme" and "image".
        #expect(asksToDesignATheme("change my theme's colors") == .fromWords)
        #expect(asksToDesignATheme("design a theme from this image's colors") == .fromThePicture)
    }

    @Test func anAskingWordWithABareAAsksAboutSomethingElse() {
        // "need", "want", "give", and "get" with "a" right before "theme" ask for a theme for an essay, a song, or a story.
        #expect(asksToDesignATheme("I need a theme for my essay") == nil)
        #expect(asksToDesignATheme("give me a theme for my story") == nil)
        #expect(asksToDesignATheme("I want a theme song for my video") == nil)
        #expect(asksToDesignATheme("did you get a theme from this poem") == nil)
        // A design word with a bare "a" still asks for one, and so does an asking word with a described theme.
        #expect(asksToDesignATheme("create a theme") == .fromWords)
        #expect(asksToDesignATheme("give me a new theme") == .fromWords)
        #expect(asksToDesignATheme("I'd like a new theme") == .fromWords)
    }

    @Test func aThemeForSomethingElseOpensNothingUnlessTheOwnerIsRightBeforeIt() {
        // Past "theme", the words say what the theme is for, so the learner asks about an essay, a song, or a poem.
        #expect(asksToDesignATheme("I need a good theme for my essay") == nil)
        #expect(asksToDesignATheme("give me a catchy theme for my story") == nil)
        #expect(asksToDesignATheme("I want a new theme song for my video") == nil)
        #expect(asksToDesignATheme("did you get a clear theme from this poem") == nil)
        #expect(asksToDesignATheme("make a theme for my presentation") == nil)
        #expect(asksToDesignATheme("I need my essay's theme to be clearer") == nil)
        // Words that say how the theme should look keep it a request, and "my theme" right before it is one whatever follows.
        #expect(asksToDesignATheme("I want a new theme that feels like a rainy night") == .fromWords)
        #expect(asksToDesignATheme("make me a theme with soft colors") == .fromWords)
        #expect(asksToDesignATheme("change my theme to something cozy") == .fromWords)
    }

    @Test func aQuestionAboutAWorksThemeOpensNothing() {
        // "change" sits within four words of "theme", but nobody says whose theme it is, so the learner asks about a work.
        #expect(asksToDesignATheme("how does the author change the theme here") == nil)
        // "new" sits next to "theme", but there is no request word and no owner word.
        #expect(asksToDesignATheme("what's the new theme in chapter two") == nil)
        // The learner asks what a theme is and wants none designed.
        #expect(asksToDesignATheme("what's the main theme of this new poem") == nil)
        #expect(asksToDesignATheme("explain the theme of this new picture") == nil)
        // "need" and "a" make a request for a theme, but "of" after it names a work's theme.
        #expect(asksToDesignATheme("I need a theme of loss for my essay") == nil)
        // A request word that comes only after "theme" is not a request for one.
        #expect(asksToDesignATheme("theme make") == nil)
    }

    @Test func aRequestWordWithNoOwnerWordOrAnOwnerWordWithNoRequestWordOpensNothing() {
        // "the" says nothing about whose theme it is, so it stays a question about the screen.
        #expect(asksToDesignATheme("change the theme") == nil)
        #expect(asksToDesignATheme("make the new theme darker") == nil)
        // An owner word alone asks about the theme, not for another.
        #expect(asksToDesignATheme("what is my theme") == nil)
        #expect(asksToDesignATheme("tell me about a new theme") == nil)
    }

    @Test func aThemeWithNoChangeWordNearbyOrNoThemeAtAllOpensNothing() {
        #expect(asksToDesignATheme("what is the theme of this video") == nil)
        #expect(asksToDesignATheme("change the playback speed") == nil)
        #expect(asksToDesignATheme("make a model of this engine") == nil)
        #expect(asksToDesignATheme("") == nil)
        // The change word is more than four words from "theme".
        #expect(asksToDesignATheme("make sure you tell me one more time about my theme") == nil)
    }
}

// MARK: - When a line may play

struct ThemeStudioLineTimingTests {
    /// The design started at press number 3, and `pressesSinceTheDesignStarted` is how many presses came after it.
    private func lineMayStart(
        dictation: Bool = false, thinking: Bool = false, audioPlaying: Bool = false, designing: Bool = false,
        pressesSinceTheDesignStarted: Int = 0
    ) -> Bool {
        themeStudioLineMayStart(
            dictationIsInProgress: dictation, clickyIsThinking: thinking, audioIsPlaying: audioPlaying, themeStudioIsDesigning: designing,
            pushToTalkPressCount: 3 + pressesSinceTheDesignStarted, pushToTalkPressCountWhenTheDesignStarted: 3
        )
    }

    @Test func aLineWaitsForPushToTalkAnAnswerBeingWorkedOnAndAudioAllAtOnce() {
        #expect(lineMayStart())
        #expect(!lineMayStart(dictation: true))
        // The learner's request that began while the line waited for push-to-talk holds it back too.
        #expect(!lineMayStart(thinking: true))
        #expect(!lineMayStart(audioPlaying: true))
    }

    @Test func theStudiosOwnDesignDoesNotHoldItsPictureLineBackButStillYieldsToVoiceAndAudio() {
        #expect(lineMayStart(thinking: true, designing: true))
        #expect(!lineMayStart(dictation: true, thinking: true, designing: true))
        #expect(!lineMayStart(thinking: true, audioPlaying: true, designing: true))
    }

    @Test func aPushToTalkPressAfterTheDesignStartedMakesThinkingTheLearnersRequestAndHoldsTheLineBack() {
        // The thinking state while a design runs is still the studio's own until the learner presses.
        #expect(lineMayStart(thinking: true, designing: true, pressesSinceTheDesignStarted: 0))
        // After a press, the same state is the learner's request, whether or not the design is still running.
        #expect(!lineMayStart(thinking: true, designing: true, pressesSinceTheDesignStarted: 1))
        #expect(!lineMayStart(thinking: true, designing: false, pressesSinceTheDesignStarted: 1))
        // A press that left Clicky idle holds nothing back, so the line still plays once the learner's request ended.
        #expect(lineMayStart(thinking: false, designing: true, pressesSinceTheDesignStarted: 1))
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

    @Test func aRequestIsCutByUTF16UnitsLikeTheWorkerCountsAndNeverSplitsACharacter() throws {
        // A rocket is 1 Character and 2 UTF-16 units, so 400 of them are 800 units. Cutting by characters would keep 500
        // characters, which the Worker counts as 1000 units and refuses.
        let rockets = String(repeating: "🚀", count: 400)
        let rocketRequest = try #require(ThemeIdeasRequest(request: rockets, currentIdeas: [], basedOnIdea: nil, picture: nil))
        #expect(rocketRequest.request.utf16.count == 500)
        #expect(rocketRequest.request.count == 250)
        // With one unit used by a letter, the 250th rocket would end at 501, so it is left out whole instead of split.
        let letterThenRockets = "a" + rockets
        let oddRequest = try #require(ThemeIdeasRequest(request: letterThenRockets, currentIdeas: [], basedOnIdea: nil, picture: nil))
        #expect(oddRequest.request.utf16.count == 499)
        #expect(oddRequest.request == "a" + String(repeating: "🚀", count: 249))
        // Text under the limit is untouched.
        let shortRequest = try #require(ThemeIdeasRequest(request: "🚀 go", currentIdeas: [], basedOnIdea: nil, picture: nil))
        #expect(shortRequest.request == "🚀 go")
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

// MARK: - The card's words and colors

struct ThemeStudioCardTextTests {
    @Test func theTagsSayTheMotionAndTheSoundsOfADrawnCursor() throws {
        let tags = themeStudioTags(for: try themeIdea(named: "Moonlit"))
        #expect(tags == [
            "turns as it moves",
            "3 trail streaks",
            "spins while thinking",
            "pulses while you talk",
            "sounds: Purr, Glass, Pop",
        ])
    }

    @Test func aPictureCursorAndAQuietIdeaHaveTheirOwnTags() throws {
        let pictureIdea = try CustomTheme.parse(idea: goodPictureCursorThemeIdea, id: "idea-1", pictureIsAvailable: true)
        #expect(themeStudioTags(for: pictureIdea).first == "cursor: your picture, tinted")
        var quietIdea = replacingField(in: goodThemeIdea, at: ["motion"], with: .object([
            "turnsTowardMovement": .bool(false), "trailStreaks": .number(2), "whileThinking": .string("none"), "whileListening": .string("none"),
        ]))
        quietIdea = replacingField(in: quietIdea, at: ["cursor", "shapes", "1"], with: .null)
        let tags = themeStudioTags(for: try CustomTheme.parse(idea: quietIdea, id: "idea-1", pictureIsAvailable: false))
        // A cursor that does not turn still trails streaks behind its movement, so they are listed.
        #expect(tags == ["2 trail streaks", "sounds: Purr, Glass, Pop"])
        let roundIdea = replacingField(in: goodPictureCursorThemeIdea, at: ["cursor", "picture"], with: .object([
            "fit": .string("circle"), "outline": .string("#FFFFFF"), "tint": .null, "tintStrength": .number(0),
        ]))
        #expect(themeStudioTags(for: try CustomTheme.parse(idea: roundIdea, id: "idea-1", pictureIsAvailable: true)).first == "cursor: your picture, round")
    }

    @Test func anIdeaCanBePickedOnlyWhileIdeasShowAndOnlyByANumberTheyHave() throws {
        let ideas = try threeStudioIdeas()
        #expect(ThemeStudioState.showingIdeas(ideas).hasIdea(number: 1))
        #expect(ThemeStudioState.showingIdeas(ideas).hasIdea(number: 3))
        #expect(!ThemeStudioState.showingIdeas(ideas).hasIdea(number: 4))
        #expect(!ThemeStudioState.showingIdeas(ideas).hasIdea(number: 0))
        #expect(!ThemeStudioState.designing(previousIdeas: ideas).hasIdea(number: 1))
        #expect(!ThemeStudioState.closed.hasIdea(number: 1))
    }

    @Test func theSaveButtonsLettersAreDarkOnABrightAccentAndWhiteOnADarkOne() throws {
        #expect(try #require(ThemeRGBColor(hex: "#7DD3FC")).readsBetterWithDarkInk)
        #expect(try #require(ThemeRGBColor(hex: "#FDE68A")).readsBetterWithDarkInk)
        // A deep violet or blue still has the contrast of 3 the Worker needs against the overlay's dark surface, but white letters read better on it.
        #expect(!(try #require(ThemeRGBColor(hex: "#2563EB")).readsBetterWithDarkInk))
        #expect(!(try #require(ThemeRGBColor(hex: "#7C3AED")).readsBetterWithDarkInk))
    }
}
