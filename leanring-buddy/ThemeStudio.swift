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

    /// The highlighted idea was saved, which closes the card.
    func afterSaving() -> ThemeStudioState {
        isShowingIdeas ? .closed : self
    }

    /// The learner closed the card, with Escape, "never mind", or the Close button. The old theme stays.
    func closing() -> ThemeStudioState {
        .closed
    }
}

// MARK: - Opening the studio

/// Where the first ideas come from.
nonisolated enum ThemeStudioRequest: Equatable, Sendable {
    /// From the learner's words alone.
    case fromWords
    /// From the largest picture in Chrome's front tab, which the loop is drawn around.
    case fromThePicture
}

/// A keyword branch ahead of the router, like "let me try it", since its words always mean the same thing: the word
/// "theme" with change, new, make, design, create, customize, or redo within four words of it. The words "this picture",
/// "this image", "this photo", or "match this" make it a request from the picture.
/// Whether the router sees the utterance instead, while the studio is already open, during a quiz question, or with the
/// brain flag on, is decided by `keywordBranchAheadOfTheRouter`.
nonisolated func asksToDesignATheme(_ transcript: String) -> ThemeStudioRequest? {
    let words = transcript.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    let themeWordIndexes = words.indices.filter { words[$0] == "theme" || words[$0] == "themes" }
    let wordsThatMakeAThemeRequest: Set<String> = ["change", "new", "make", "design", "create", "customize", "customise", "redo"]
    let nearestWordsToCheck = 4
    let nameTheTheme = themeWordIndexes.contains { themeWordIndex in
        let nearbyIndexes = max(0, themeWordIndex - nearestWordsToCheck)...min(words.count - 1, themeWordIndex + nearestWordsToCheck)
        return nearbyIndexes.contains { wordsThatMakeAThemeRequest.contains(words[$0]) }
    }
    guard nameTheTheme else { return nil }

    let wordPairsThatPointAtThePicture: Set<[String]> = [["this", "picture"], ["this", "image"], ["this", "photo"], ["match", "this"]]
    let pointsAtThePicture = words.indices.dropLast().contains { wordIndex in
        wordPairsThatPointAtThePicture.contains([words[wordIndex], words[wordIndex + 1]])
    }
    return pointsAtThePicture ? .fromThePicture : .fromWords
}

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
/// answer with a 400 never goes out.
nonisolated struct ThemeIdeasRequest: Equatable, Sendable {
    static let longestRequestText = 500

    let request: String
    let currentIdeas: [CustomTheme]
    /// 1 to 3, the idea on the card the change applies to. Only set with `currentIdeas`.
    let basedOnIdea: Int?
    let picture: ThemeStudioPicture?

    /// Nil for an empty request. A request over 500 characters is cut, more than 3 current ideas are dropped, and a
    /// `basedOnIdea` outside the current ideas is left out.
    init?(request requestText: String, currentIdeas: [CustomTheme], basedOnIdea: Int?, picture: ThemeStudioPicture?) {
        let trimmedRequest = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequest.isEmpty else { return nil }
        request = String(trimmedRequest.prefix(Self.longestRequestText))
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
