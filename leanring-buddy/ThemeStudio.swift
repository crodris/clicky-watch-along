//
//  ThemeStudio.swift
//  leanring-buddy
//
//  The Theme Studio's pure parts. "Hey Clicky, change my theme" opens a card next to the cursor with three theme ideas,
//  and the learner picks, refines, and saves one by voice or click. This file holds the state machine behind the card (the
//  transitions are plain functions, so tests check each one), the phrase that opens the studio, the router's view of it,
//  and the `POST /theme-ideas` request and reply. `ThemeStudioController` runs it and `ThemeStudioPanel` draws it.
//

import Foundation

// MARK: - The picture

/// The picture the learner pointed at, a JPEG of the largest picture in Chrome's front tab. The studio keeps it, so a
/// refinement keeps designing from it and a save keeps it beside the theme.
nonisolated struct ThemeStudioPicture: Equatable, Sendable {
    let jpegData: Data
    let width: Int
    let height: Int

    var jpegBase64: String { jpegData.base64EncodedString() }
}

// MARK: - State

/// What the card shows: 1 to 3 ideas with one highlighted. The highlighted idea is the one on the real cursor.
nonisolated struct ThemeStudioIdeas: Equatable, Sendable {
    let title: String
    /// 1 to 3 ideas, each with a temporary id.
    let ideas: [CustomTheme]
    var highlightedIdeaIndex: Int
    let picture: ThemeStudioPicture?

    var highlightedIdea: CustomTheme { ideas[highlightedIdeaIndex] }

    /// The first idea is highlighted when ideas arrive. Nil with no ideas, and more than 3 are cut, so `ideas` is never
    /// empty and `highlightedIdeaIndex` always points at one.
    init?(title: String, ideas: [CustomTheme], picture: ThemeStudioPicture?) {
        guard !ideas.isEmpty else { return nil }
        self.title = title
        self.ideas = Array(ideas.prefix(3))
        self.highlightedIdeaIndex = 0
        self.picture = picture
    }
}

nonisolated enum ThemeStudioState: Equatable, Sendable {
    case closed
    /// A Worker call is running. The ideas that were on the card stay there, dimmed, until the new ones arrive.
    case designing(previousIdeas: ThemeStudioIdeas?)
    case showingIdeas(ThemeStudioIdeas)

    var isOpen: Bool { self != .closed }

    var isShowingIdeas: Bool {
        if case .showingIdeas = self { return true }
        return false
    }

    var isDesigning: Bool {
        if case .designing = self { return true }
        return false
    }

    /// The ideas on the card, which are dimmed while a new design runs.
    var ideasOnTheCard: ThemeStudioIdeas? {
        switch self {
        case .closed: return nil
        case .designing(let previousIdeas): return previousIdeas
        case .showingIdeas(let ideas): return ideas
        }
    }

    // MARK: Transitions

    /// The learner asked for ideas: from nothing, a new card, and from ideas on the card, the same card with them dimmed. A
    /// design that is already running is replaced by the new one, which keeps the same previous ideas.
    func startingADesign() -> ThemeStudioState {
        switch self {
        case .closed: return .designing(previousIdeas: nil)
        case .designing(let previousIdeas): return .designing(previousIdeas: previousIdeas)
        case .showingIdeas(let ideas): return .designing(previousIdeas: ideas)
        }
    }

    /// The Worker's ideas arrived. They count only while a design runs, so a reply for a card the learner already closed,
    /// or for ideas already replaced, changes nothing.
    func withIdeasArrived(_ arrivedIdeas: ThemeStudioIdeas) -> ThemeStudioState {
        guard case .designing = self else { return self }
        return .showingIdeas(arrivedIdeas)
    }

    /// The design failed: back to the ideas that were on the card, or closed when there were none.
    func afterTheDesignFailed() -> ThemeStudioState {
        guard case .designing(let previousIdeas) = self else { return self }
        guard let previousIdeas else { return .closed }
        return .showingIdeas(previousIdeas)
    }

    /// Highlights idea `ideaNumber`, counting from 1, as the learner says it. Only ideas on show can be picked, and a
    /// number with no idea changes nothing.
    func pickingIdea(number ideaNumber: Int) -> ThemeStudioState {
        guard case .showingIdeas(var ideas) = self, ideas.ideas.indices.contains(ideaNumber - 1) else { return self }
        ideas.highlightedIdeaIndex = ideaNumber - 1
        return .showingIdeas(ideas)
    }

    /// Whether the learner can pick idea `ideaNumber`, counting from 1: ideas are on show and one has that number.
    func hasIdea(number ideaNumber: Int) -> Bool {
        guard case .showingIdeas(let ideas) = self else { return false }
        return ideas.ideas.indices.contains(ideaNumber - 1)
    }

    /// The highlighted idea was saved, which closes the card.
    func afterSaving() -> ThemeStudioState {
        isShowingIdeas ? .closed : self
    }

    /// The learner closed the card, with Escape, "never mind", or the Close button. The old theme stays.
    func closing() -> ThemeStudioState {
        .closed
    }
}

// MARK: - Tags

/// What the card says about the highlighted idea, in words, as short tags: a picture cursor's look, how it moves, and the sounds.
nonisolated func themeStudioTags(for idea: CustomTheme) -> [String] {
    var tags: [String] = []
    // A drawn cursor shows itself on the tile, so only a picture cursor gets a tag, since its fit and tint are easy to miss.
    if case .picture(let style) = idea.cursor {
        var pictureTag = "cursor: your picture"
        if style.fit == .circle { pictureTag += ", round" }
        if style.tintHex != nil && style.tintStrength > 0 { pictureTag += ", tinted" }
        tags.append(pictureTag)
    }
    if idea.motion.turnsTowardMovement { tags.append("turns as it moves") }
    if idea.motion.trailStreaks > 0 {
        tags.append(idea.motion.trailStreaks == 1 ? "1 trail streak" : "\(idea.motion.trailStreaks) trail streaks")
    }
    switch idea.motion.whileThinking {
    case .none: break
    case .spin: tags.append("spins while thinking")
    case .pulse: tags.append("pulses while thinking")
    case .wobble: tags.append("wobbles while thinking")
    }
    if idea.motion.whileListening == .pulse { tags.append("pulses while you talk") }
    tags.append("sounds: \(idea.sounds.done.rawValue), \(idea.sounds.correct.rawValue), \(idea.sounds.needsYourOK.rawValue)")
    return tags
}

nonisolated extension ThemeRGBColor {
    /// Whether dark letters read better than white ones on this color, by WCAG contrast: dark wins above a luminance of about
    /// 0.18. The Save button fills with the idea's accent, so its letters take this instead of the idea's own contrast color,
    /// which the model may have picked for something else.
    var readsBetterWithDarkInk: Bool { relativeLuminance > 0.179 }
}

// MARK: - Opening the studio

/// Where the picture for a design comes from.
nonisolated enum ThemeStudioPictureChoice: Equatable, Sendable {
    /// No picture: design from the words alone.
    case none
    /// The picture the card already has, so a refinement keeps designing from it.
    case keepTheCardsPicture
    /// The largest picture in Chrome's front tab now, or the card's own picture when there is none to capture.
    case captureAgain

    /// What `design_theme`'s `fromPicture` input means: true when the learner points at a picture, false when they drop the
    /// one the card has, and left out when they said nothing about it, which keeps the card's picture.
    init(fromPictureInput fromPicture: Bool?) {
        switch fromPicture {
        case true?: self = .captureAgain
        case false?: self = .none
        case nil: self = .keepTheCardsPicture
        }
    }
}

/// Where the first ideas come from.
nonisolated enum ThemeStudioRequest: Equatable, Sendable {
    /// From the learner's words alone.
    case fromWords
    /// From the largest picture in Chrome's front tab, which the loop is drawn around.
    case fromThePicture
}

/// A keyword branch ahead of the router, like "let me try it", since its words always mean the same thing: the learner
/// asks for a theme of their own or Clicky's. That takes two things, and a theme the learner is only reading about has
/// neither:
/// - a request word within the four words before "theme": a design word (change, make, design, create, customize,
///   customise, redo, switch) or an asking word (give, want, need, get, try, like), and
/// - an owner word: my, your, or Clicky's directly before "theme", or one of the forms that also fit a theme for something
///   else, which count only when "theme" ends the request or is followed by please, like, that, with, based, or, when the
///   words point at the picture, from:
///   my, your, or Clicky's one word before "theme", "a" one word before it, as in "a cozy theme", or, with a design word,
///   "a" directly before it, as in "create a theme". "The" never counts.
///
/// So "change my theme to something cozy", "make me a new theme", "I want a new theme that feels like rain", and "create
/// a cozy theme" open the studio. "How does the author change the theme here" has no owner word, "what's the new theme in
/// chapter two" has neither word, "I need a theme for my essay" pairs an asking word with a bare "a", "I need a good theme
/// for my essay" and "I want a new theme song" go on past "theme", and "I need a theme of loss for my essay" is followed by
/// "of", so those are questions for the router. "New theme" or "a new theme", alone or with "hey", "okay", "Clicky", or
/// "please" around it, is a request too, since nothing else is in it to ask about. The words "this picture", "this image",
/// "this photo", or "match this" make it a request from the picture.
/// Whether the router sees the utterance instead, while the studio is already open, during a quiz question, or with the
/// brain flag on, is decided by `keywordBranchAheadOfTheRouter`.
nonisolated func asksToDesignATheme(_ transcript: String) -> ThemeStudioRequest? {
    // An apostrophe stays inside a word, so "Clicky's" is one word, and a curly one from speech recognition reads the same.
    // Any other possessive "'s" comes off, so "my theme's colors" and "this image's colors" match as "theme" and "image".
    let apostrophes = CharacterSet(charactersIn: "'")
    let words = transcript.lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .components(separatedBy: CharacterSet.alphanumerics.union(apostrophes).inverted)
        .map { $0.trimmingCharacters(in: apostrophes) }
        .map { $0.hasSuffix("'s") && $0 != "clicky's" ? String($0.dropLast(2)) : $0 }
        .filter { !$0.isEmpty }

    let wordsAroundANewThemeRequest: Set<String> = ["hey", "okay", "ok", "clicky", "please", "a"]
    let isTheWholeRequestNewTheme = words.filter { !wordsAroundANewThemeRequest.contains($0) } == ["new", "theme"]

    let themeWordIndexes = words.indices.filter { words[$0] == "theme" || words[$0] == "themes" }
    let wordsThatAskToDesignATheme: Set<String> = ["change", "make", "design", "create", "customize", "customise", "redo", "switch"]
    let wordsThatAskForATheme: Set<String> = ["give", "want", "need", "get", "try", "like"]
    let wordsThatMayFollowARequestedTheme: Set<String> = ["please", "like", "that", "with", "based"]
    let wordPairsThatPointAtThePicture: Set<[String]> = [["this", "picture"], ["this", "image"], ["this", "photo"], ["match", "this"]]
    let pointsAtThePicture = words.indices.dropLast().contains { wordIndex in
        wordPairsThatPointAtThePicture.contains([words[wordIndex], words[wordIndex + 1]])
    }
    let wordsThatNameTheLearnerOrClicky: Set<String> = ["my", "your", "clicky's", "clickys"]
    let nearestWordsToCheck = 4
    let nameTheTheme = themeWordIndexes.contains { themeWordIndex in
        // "The theme of this poem" asks about a theme that already exists, whatever words come before it.
        let wordAfterTheTheme = words.indices.contains(themeWordIndex + 1) ? words[themeWordIndex + 1] : nil
        guard wordAfterTheTheme != "of" else { return false }

        let wordIndexesBeforeTheTheme = max(0, themeWordIndex - nearestWordsToCheck)..<themeWordIndex
        let aDesignWordIsNearby = wordIndexesBeforeTheTheme.contains { wordsThatAskToDesignATheme.contains(words[$0]) }
        let anAskingWordIsNearby = wordIndexesBeforeTheTheme.contains { wordsThatAskForATheme.contains(words[$0]) }
        guard aDesignWordIsNearby || anAskingWordIsNearby else { return false }

        // "Change my theme" says whose theme it is right before "theme", and that alone is enough.
        let wordBeforeTheTheme = words.indices.contains(themeWordIndex - 1) ? words[themeWordIndex - 1] : nil
        let wordTwoBeforeTheTheme = words.indices.contains(themeWordIndex - 2) ? words[themeWordIndex - 2] : nil
        if let wordBeforeTheTheme, wordsThatNameTheLearnerOrClicky.contains(wordBeforeTheTheme) { return true }

        // The other owners, "my" one word earlier ("my whole theme"), "a" one word earlier ("a cozy theme"), and a bare "a"
        // with a design word ("create a theme"), also fit a theme for something else: "I need a good theme for my essay",
        // "I want a new theme song", or "make a theme for my presentation". So they count only when the request ends at
        // "theme" or goes on to say how the theme should look.
        // "From" counts only toward the picture, so "make a theme from this image" opens and "a theme from this poem" does not.
        let theRequestEndsAtTheTheme = wordAfterTheTheme.map { wordAfterTheTheme in
            wordsThatMayFollowARequestedTheme.contains(wordAfterTheTheme) || (wordAfterTheTheme == "from" && pointsAtThePicture)
        } ?? true
        guard theRequestEndsAtTheTheme else { return false }
        let theLearnerOrClickyOwnsIt = wordTwoBeforeTheTheme.map(wordsThatNameTheLearnerOrClicky.contains) ?? false
        let aDescribedThemeIsAskedFor = wordTwoBeforeTheTheme == "a"
        let aThemeIsAskedToBeDesigned = wordBeforeTheTheme == "a" && aDesignWordIsNearby
        return theLearnerOrClickyOwnsIt || aDescribedThemeIsAskedFor || aThemeIsAskedToBeDesigned
    }
    guard nameTheTheme || isTheWholeRequestNewTheme else { return nil }
    return pointsAtThePicture ? .fromThePicture : .fromWords
}

// MARK: - When a line may play

/// Whether a line the studio has queued may start now: the learner is not holding push-to-talk, no audio is playing, and
/// Clicky is not thinking about a request, so the line never plays over the learner's voice, over another line, or over
/// the request that followed it.
/// The studio's own design holds the thinking state while it reads a picture, so that state does not hold a line back while
/// a design runs. Otherwise the "no picture" line would wait for the ideas, and their line would replace it.
/// A push-to-talk press after the design started means any thinking state since then is the learner's new request, so the
/// design stops excusing it. The presses are compared as counts, since the design cannot tell whose thinking it sees.
nonisolated func themeStudioLineMayStart(
    dictationIsInProgress: Bool,
    clickyIsThinking: Bool,
    audioIsPlaying: Bool,
    themeStudioIsDesigning: Bool,
    pushToTalkPressCount: Int,
    pushToTalkPressCountWhenTheDesignStarted: Int
) -> Bool {
    if dictationIsInProgress || audioIsPlaying { return false }
    let learnerPressedSinceTheDesignStarted = pushToTalkPressCount != pushToTalkPressCountWhenTheDesignStarted
    let thinkingBelongsToTheStudiosOwnDesign = themeStudioIsDesigning && !learnerPressedSinceTheDesignStarted
    return thinkingBelongsToTheStudiosOwnDesign || !clickyIsThinking
}

// MARK: - What a save says

/// What the chip under the cursor says when a theme is saved, by the voice tool (`save_theme`) or by a click on Save.
nonisolated let themeSavedChipPhrase = "Theme saved"

/// What the chip says when a click on Save could not write the theme. The voice tool reports the same failure to the router.
nonisolated let themeCouldNotBeSavedChipPhrase = "Couldn't save the theme"

// MARK: - What the router reads

/// The studio's part of the router's scene state: the idea names, which one is highlighted (counting from 1), and whether a
/// design is running. Nil while the studio is closed. The idea names are text the model wrote, so they are short, and the
/// message builder takes any "<" out of the state.
nonisolated func voiceCommandThemeStudioState(_ state: ThemeStudioState) -> JSONValue? {
    guard let ideasOnTheCard = state.ideasOnTheCard else {
        return state.isDesigning ? .object(["ideas": .array([]), "designing": .bool(true)]) : nil
    }
    return .object([
        "ideas": .array(ideasOnTheCard.ideas.map { .string($0.name) }),
        "highlighted": .number(Double(ideasOnTheCard.highlightedIdeaIndex + 1)),
        "designing": .bool(state.isDesigning),
    ])
}

// MARK: - POST /theme-ideas

/// The body of `POST /theme-ideas`, with the Worker's limits applied before it is sent, so a request the Worker would
/// answer with a 400 never goes out. The Worker counts text in UTF-16 code units, as JavaScript does, so the request is cut
/// by that count and never by characters. Three ideas that passed the parser stay under the Worker's 24,000 character cap on
/// `currentIdeas`, since the parser limits their shapes and paths.
nonisolated struct ThemeIdeasRequest: Equatable, Sendable {
    static let longestRequestText = 500

    let request: String
    let currentIdeas: [CustomTheme]
    /// 1 to 3, the idea on the card the change applies to. Only set with `currentIdeas`.
    let basedOnIdea: Int?
    let picture: ThemeStudioPicture?

    /// Nil for an empty request. A request over 500 UTF-16 code units is cut, more than 3 current ideas are dropped, and a
    /// `basedOnIdea` outside the current ideas is left out.
    init?(request requestText: String, currentIdeas: [CustomTheme], basedOnIdea: Int?, picture: ThemeStudioPicture?) {
        let trimmedRequest = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else { return nil }
        request = textCutToUTF16Count(trimmedRequest, longestUTF16Count: Self.longestRequestText)
        self.currentIdeas = Array(currentIdeas.prefix(3))
        if let basedOnIdea, self.currentIdeas.indices.contains(basedOnIdea - 1) {
            self.basedOnIdea = basedOnIdea
        } else {
            self.basedOnIdea = nil
        }
        self.picture = picture
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = ["request": .string(request)]
        if !currentIdeas.isEmpty {
            fields["currentIdeas"] = .array(currentIdeas.map(\.ideaJSON))
        }
        if let basedOnIdea {
            fields["basedOnIdea"] = .number(Double(basedOnIdea))
        }
        if let picture {
            fields["picture"] = .object([
                "jpegBase64": .string(picture.jpegBase64),
                "width": .number(Double(picture.width)),
                "height": .number(Double(picture.height)),
            ])
        }
        return .object(fields)
    }
}

/// The Worker's reply, parsed at the boundary: a title for the card, the line Clicky speaks, and the ideas, each already a
/// checked `CustomTheme` with a temporary id.
nonisolated struct ThemeIdeasReply: Equatable, Sendable {
    let title: String
    let spokenLine: String
    let ideas: [CustomTheme]

    /// `pictureWasSent` says whether the request carried a picture, since a theme that uses the picture is refused without one.
    init(responseData: Data, pictureWasSent: Bool) throws {
        let reply = try JSONDecoder().decode(JSONValue.self, from: responseData)
        guard let title = reply["title"]?.stringValue, (1...60).contains(title.count) else {
            throw CustomThemeParseError(reason: "title must be text of 1 to 60 characters")
        }
        guard let spokenLine = reply["spokenLine"]?.stringValue, (1...160).contains(spokenLine.count) else {
            throw CustomThemeParseError(reason: "spokenLine must be text of 1 to 160 characters")
        }
        guard let ideaValues = reply["ideas"]?.arrayValue, (1...3).contains(ideaValues.count) else {
            throw CustomThemeParseError(reason: "ideas must be a list of 1 to 3 ideas")
        }
        self.title = title
        self.spokenLine = spokenLine
        ideas = try ideaValues.enumerated().map { ideaIndex, ideaValue in
            try CustomTheme.parse(idea: ideaValue, id: "idea-\(ideaIndex + 1)", pictureIsAvailable: pictureWasSent)
        }
    }
}

nonisolated enum ThemeIdeasError: Error, Equatable {
    case workerReturned(statusCode: Int, body: String)
}

@MainActor
final class ThemeIdeasClient {
    private let themeIdeasURL: URL
    private let session: URLSession

    /// Sonnet writes three whole themes in about 5 to 15 seconds, longer with a picture to read. Past this the studio says
    /// it could not design the ideas.
    private static let timeoutSeconds: TimeInterval = 40

    init(workerBaseURL: String) {
        guard let themeIdeasURL = URL(string: "\(workerBaseURL)/theme-ideas") else {
            preconditionFailure("Worker base URL did not form the theme ideas URL: \(workerBaseURL)")
        }
        self.themeIdeasURL = themeIdeasURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: configuration)
    }

    func designIdeas(for themeIdeasRequest: ThemeIdeasRequest) async throws -> ThemeIdeasReply {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(themeIdeasRequest.json),
            to: themeIdeasURL,
            using: session,
            sendsAppSecret: false
        )
        guard statusCode == 200 else {
            throw ThemeIdeasError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        try Task.checkCancellation()
        return try ThemeIdeasReply(responseData: responseData, pictureWasSent: themeIdeasRequest.picture != nil)
    }
}
