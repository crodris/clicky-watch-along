//
//  VoiceCommandTools.swift
//  leanring-buddy
//
//  The fast path for a spoken follow-up command. The app lists its tools in the WebMCP and MCP
//  shape ({ name, description, inputSchema }), POST /voice-command asks a fast model which to call,
//  the app runs them, and Clicky speaks a short confirmation after the screen has changed.
//  Page tools live in LiveSceneAssets/scene-tools.js. App tools (the video, the quiz, and the slow
//  paths) are listed here and run by CompanionManager.
//

import Foundation

// MARK: - JSON

/// A JSON value at the boundaries this path crosses: the page, the Worker, and the debug MCP endpoint.
nonisolated enum JSONValue: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let numberValue = try? container.decode(Double.self) {
            self = .number(numberValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let boolValue): try container.encode(boolValue)
        case .number(let numberValue): try container.encode(numberValue)
        case .string(let stringValue): try container.encode(stringValue)
        case .array(let arrayValue): try container.encode(arrayValue)
        case .object(let objectValue): try container.encode(objectValue)
        }
    }

    /// WebKit and JSONSerialization hand back Foundation objects typed as Any. Nil for anything that is not JSON.
    init?(foundationValue: Any) {
        switch foundationValue {
        case is NSNull:
            self = .null
        case let numberValue as NSNumber:
            // A Foundation Bool is an NSNumber too, and only its type ID tells them apart.
            if CFGetTypeID(numberValue) == CFBooleanGetTypeID() {
                self = .bool(numberValue.boolValue)
            } else {
                self = .number(numberValue.doubleValue)
            }
        case let stringValue as String:
            self = .string(stringValue)
        case let arrayValue as [Any]:
            var convertedValues: [JSONValue] = []
            for element in arrayValue {
                guard let convertedValue = JSONValue(foundationValue: element) else { return nil }
                convertedValues.append(convertedValue)
            }
            self = .array(convertedValues)
        case let dictionaryValue as [String: Any]:
            var convertedObject: [String: JSONValue] = [:]
            for (key, element) in dictionaryValue {
                guard let convertedValue = JSONValue(foundationValue: element) else { return nil }
                convertedObject[key] = convertedValue
            }
            self = .object(convertedObject)
        default:
            return nil
        }
    }

    /// The Foundation form WebKit's callAsyncJavaScript arguments take.
    var foundationValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let boolValue): return boolValue
        case .number(let numberValue): return numberValue
        case .string(let stringValue): return stringValue
        case .array(let arrayValue): return arrayValue.map(\.foundationValue)
        case .object(let objectValue): return objectValue.mapValues(\.foundationValue)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let objectValue) = self { return objectValue[key] }
        return nil
    }

    var numberValue: Double? {
        if case .number(let numberValue) = self { return numberValue }
        return nil
    }

    var stringValue: String? {
        if case .string(let stringValue) = self { return stringValue }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let boolValue) = self { return boolValue }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let arrayValue) = self { return arrayValue }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let objectValue) = self { return objectValue }
        return nil
    }

    /// One line of JSON with sorted keys, for logs, tool results, and the model's recent actions.
    var compactJSONText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let encodedData = try? encoder.encode(self) else { return "null" }
        return String(decoding: encodedData, as: UTF8.self)
    }
}

// MARK: - Tools

/// One tool in the WebMCP and MCP shape. readOnly marks a tool whose result the model reads before it
/// acts again, such as finding a moment in the captions, so it needs no spoken confirmation.
nonisolated struct VoiceToolDescriptor: Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let readOnly: Bool

    var workerRequestJSON: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "readOnly": .bool(readOnly),
        ])
    }

    /// The page lists its tools as { name, description, inputSchema }. Nil for an entry missing any of them.
    init?(pageToolJSON: JSONValue) {
        guard let name = pageToolJSON["name"]?.stringValue,
              let description = pageToolJSON["description"]?.stringValue,
              let inputSchema = pageToolJSON["inputSchema"],
              inputSchema["type"]?.stringValue == "object" else {
            return nil
        }
        self.init(name: name, description: description, inputSchema: inputSchema, readOnly: false)
    }

    init(name: String, description: String, inputSchema: JSONValue, readOnly: Bool) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
    }
}

/// The tools the app itself runs. Page tools come from the page, so the scene decides what it can do.
nonisolated enum AppVoiceTool: String, CaseIterable, Sendable {
    case answerWithScreen = "answer_with_screen"
    case buildNewScene = "build_new_scene"
    case popOut = "pop_out"
    case closeScene = "close_scene"
    case explainPart = "explain_part"
    case pauseVideo = "pause_video"
    case playVideo = "play_video"
    case seekRelative = "seek_relative"
    case seekToTime = "seek_to_time"
    case setSpeed = "set_speed"
    case findMoment = "find_moment"
    case endQuiz = "end_quiz"

    /// What the app can do right now. A tool that cannot work is left out, so the model never picks it.
    nonisolated struct Context: Equatable, Sendable {
        var sceneIsOnScreen: Bool
        var sceneHasLabels: Bool
        var videoIsInFront: Bool
        var videoQuizIsRunning: Bool
        /// While a quiz question waits for its answer, every utterance goes to the judge first. A hand-off
        /// to the old path would send it back to the judge, so only view and video tools are offered then.
        var quizQuestionIsOpen: Bool
    }

    static func available(in context: Context) -> [AppVoiceTool] {
        allCases.filter { appVoiceTool in
            switch appVoiceTool {
            case .answerWithScreen, .buildNewScene, .popOut:
                return !context.quizQuestionIsOpen
            case .closeScene:
                return context.sceneIsOnScreen
            case .explainPart:
                return context.sceneIsOnScreen && context.sceneHasLabels
            case .pauseVideo, .playVideo, .seekRelative, .seekToTime, .setSpeed, .findMoment:
                return context.videoIsInFront
            case .endQuiz:
                return context.videoQuizIsRunning
            }
        }
    }

    /// These two act on what the learner said, so the debug MCP endpoint, which has no spoken request, leaves them out.
    var needsTheSpokenRequest: Bool {
        self == .answerWithScreen || self == .buildNewScene
    }

    var descriptor: VoiceToolDescriptor {
        VoiceToolDescriptor(name: rawValue, description: toolDescription, inputSchema: inputSchema, readOnly: self == .findMoment)
    }

    private var toolDescription: String {
        switch self {
        case .answerWithScreen:
            return "Answer a question about what is on screen, using a screenshot. Use it for questions and for anything no other tool can do, not for changing the view."
        case .buildNewScene:
            return "Build a brand new 3D model from scratch, which takes about 10 seconds. Use it only when the learner wants a different model or a 3D view of something not on screen yet, never to turn, zoom, or open the model already showing."
        case .popOut:
            return "Lift the subject of the video frame or the largest picture in Chrome's front tab out in 3D with its parts labeled. Use it when they say pop this out."
        case .closeScene:
            return "Close the 3D scene on screen. A paused video plays again."
        case .explainPart:
            return "Say what one labeled part does, while the camera turns to it. label must be one of the scene state's labels."
        case .pauseVideo:
            return "Pause the video in Chrome's front tab."
        case .playVideo:
            return "Play the video in Chrome's front tab."
        case .seekRelative:
            return "Move the video in Chrome's front tab forward (positive seconds) or back (negative seconds)."
        case .seekToTime:
            return "Move the video in Chrome's front tab to a time, in seconds from the start."
        case .setSpeed:
            return "Set how fast the video in Chrome's front tab plays. 1 is normal speed."
        case .findMoment:
            return "Search the video's captions for where something is said. Returns up to 3 moments, best match first, with their times, so you can call seek_to_time next."
        case .endQuiz:
            return "Stop the video quiz."
        }
    }

    private var inputSchema: JSONValue {
        func objectSchema(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
            ])
        }
        func numberProperty(_ description: String) -> JSONValue {
            .object(["type": .string("number"), "description": .string(description)])
        }
        switch self {
        case .answerWithScreen, .popOut, .closeScene, .pauseVideo, .playVideo, .endQuiz:
            return objectSchema([:], required: [])
        case .buildNewScene:
            return objectSchema(
                ["asQuiz": .object(["type": .string("boolean"), "description": .string("true when they asked to be quizzed or tested on it.")])],
                required: ["asQuiz"]
            )
        case .explainPart:
            return objectSchema(["label": .object(["type": .string("string")])], required: ["label"])
        case .seekRelative:
            return objectSchema(["seconds": numberProperty("Seconds to move, negative to go back.")], required: ["seconds"])
        case .seekToTime:
            return objectSchema(["seconds": numberProperty("Seconds from the start of the video.")], required: ["seconds"])
        case .setSpeed:
            return objectSchema(["rate": numberProperty("From 0.25 to 2.")], required: ["rate"])
        case .findMoment:
            return objectSchema(["query": .object(["type": .string("string"), "description": .string("A few words that would be said at that moment.")])], required: ["query"])
        }
    }
}

// MARK: - Worker reply

/// A tool call from the model. The Worker adds confirmation to every tool's input, so it is split out here.
nonisolated struct VoiceToolCall: Equatable, Sendable {
    let id: String
    let name: String
    let input: [String: JSONValue]

    var confirmation: String {
        (input["confirmation"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var inputWithoutConfirmation: [String: JSONValue] {
        input.filter { inputKey, _ in inputKey != "confirmation" }
    }

    /// Shown on the chip next to the cursor, such as rotate_model(yawDegrees: -45).
    var chipText: String {
        let argumentsText = inputWithoutConfirmation
            .sorted { $0.key < $1.key }
            .map { argumentName, argumentValue in
                let valueText: String
                switch argumentValue {
                case .number(let numberValue):
                    valueText = numberValue.rounded() == numberValue ? String(Int(numberValue)) : String(format: "%.2f", numberValue)
                case .string(let stringValue):
                    valueText = "\"\(stringValue)\""
                default:
                    valueText = argumentValue.compactJSONText
                }
                return "\(argumentName): \(valueText)"
            }
            .joined(separator: ", ")
        return "\(name)(\(argumentsText))"
    }
}

/// POST /voice-command's reply. assistantContent goes back to the Worker unchanged on the next turn.
nonisolated struct VoiceCommandReply: Equatable, Sendable {
    let assistantContent: [JSONValue]
    let toolCalls: [VoiceToolCall]
    let text: String

    init(responseData: Data) throws {
        let responseJSON = try JSONDecoder().decode(JSONValue.self, from: responseData)
        guard let contentBlocks = responseJSON["content"]?.arrayValue else {
            throw VoiceCommandError.replyHadNoContent
        }
        assistantContent = contentBlocks
        toolCalls = contentBlocks.compactMap { contentBlock in
            guard contentBlock["type"]?.stringValue == "tool_use",
                  let id = contentBlock["id"]?.stringValue,
                  let name = contentBlock["name"]?.stringValue,
                  let input = contentBlock["input"]?.objectValue else {
                return nil
            }
            return VoiceToolCall(id: id, name: name, input: input)
        }
        text = contentBlocks
            .filter { $0["type"]?.stringValue == "text" }
            .compactMap { $0["text"]?.stringValue }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum VoiceCommandError: Error, Equatable {
    case replyHadNoContent
    case workerReturned(statusCode: Int, body: String)
}

// MARK: - Outcomes and the next step

/// What running one tool did.
nonisolated enum VoiceToolOutcome: Equatable, Sendable {
    /// The screen or video changed. state is what the page or video reports now.
    case changed(state: JSONValue?)
    /// A read-only lookup the model reads before it acts again.
    case lookedUp(result: JSONValue)
    case failed(error: String, state: JSONValue?)
    /// A slow path, such as building a new scene, took over the reply and owns what Clicky says next.
    case handedOff

    var toolResultText: String {
        switch self {
        case .changed(let state):
            return JSONValue.object(["ok": .bool(true), "state": state ?? .null]).compactJSONText
        case .lookedUp(let result):
            return JSONValue.object(["ok": .bool(true), "result": result]).compactJSONText
        case .failed(let error, let state):
            return JSONValue.object(["ok": .bool(false), "error": .string(error), "state": state ?? .null]).compactJSONText
        case .handedOff:
            return JSONValue.object(["ok": .bool(true)]).compactJSONText
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

nonisolated enum VoiceCommandNextStep: Equatable, Sendable {
    /// Say this line, which may be empty, and finish.
    case speak(String)
    /// Send the tool results back, because the model has to read a lookup or a failure before it can finish.
    case askTheModelAgain
    /// A slow path owns the rest of the reply.
    case finishSilently
}

/// The confirmations are spoken only when every tool changed the screen. A lookup or a failure goes back
/// to the model, which then acts on the lookup or says what went wrong.
nonisolated func voiceCommandNextStep(toolCalls: [VoiceToolCall], outcomes: [VoiceToolOutcome], replyText: String) -> VoiceCommandNextStep {
    if outcomes.contains(.handedOff) {
        return .finishSilently
    }
    if toolCalls.isEmpty {
        return .speak(replyText)
    }
    let modelMustReadTheResults = outcomes.contains { outcome in
        switch outcome {
        case .lookedUp, .failed: return true
        case .changed, .handedOff: return false
        }
    }
    if modelMustReadTheResults {
        return .askTheModelAgain
    }
    let confirmations = toolCalls.map(\.confirmation).filter { !$0.isEmpty }
    return .speak(confirmations.joined(separator: " "))
}

// MARK: - The message the model reads

/// One line per recent tool call, so "no, the other way" can be read against what Clicky just did.
nonisolated func voiceToolActionLine(toolCall: VoiceToolCall, outcome: VoiceToolOutcome) -> String {
    let resultWord: String
    switch outcome {
    case .changed, .lookedUp, .handedOff: resultWord = "ok"
    case .failed(let error, _): resultWord = "failed: \(error)"
    }
    return "\(toolCall.name) \(JSONValue.object(toolCall.inputWithoutConfirmation).compactJSONText) -> \(resultWord)"
}

/// Page text and captions sit inside tags the model is told never to obey, so a "<" in them could close the tag early.
nonisolated func voiceCommandUserMessageText(transcript: String, sceneState: JSONValue, recentActionLines: [String]) -> String {
    let stateText = sceneState.compactJSONText.replacingOccurrences(of: "<", with: " ")
    let actionsText = recentActionLines.joined(separator: "\n").replacingOccurrences(of: "<", with: " ")
    return """
    <scene_state>\(stateText)</scene_state>
    <recent_actions>
    \(actionsText)
    </recent_actions>
    Learner said: "\(transcript)"
    """
}

/// The router takes a command only when something is live to command: a scene on screen or a
/// video in Chrome's front tab, on any site. A quiz answer goes to the judge, and a scene still building keeps its keyword path.
nonisolated func voiceCommandRouterTakesTheTranscript(
    sceneIsOnScreen: Bool,
    videoIsInFront: Bool,
    phaseIsWaitingForAQuizAnswer: Bool,
    sceneIsBuilding: Bool
) -> Bool {
    if phaseIsWaitingForAQuizAnswer || sceneIsBuilding { return false }
    return sceneIsOnScreen || videoIsInFront
}

// MARK: - Finding a moment in the captions

nonisolated struct VideoCaptionMoment: Equatable, Sendable {
    let seconds: Double
    let text: String
}

/// The caption lines that say the query's words, best first. A line counts only when it says one of them
/// itself, so a seek lands where it is said, and the line after it adds weight because captions split sentences.
/// Short and common words do not count.
nonisolated func videoCaptionMomentsMatching(query: String, captionLines: [VideoQuizTranscriptLine], limit: Int = 3) -> [VideoCaptionMoment] {
    let wordsThatSayNothing: Set<String> = ["the", "and", "for", "that", "this", "with", "where", "when", "what", "they", "was", "are", "about", "part", "talk", "talks", "said", "says"]
    func words(in text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !wordsThatSayNothing.contains($0) })
    }
    let queryWords = words(in: query)
    guard !queryWords.isEmpty else { return [] }
    struct ScoredMoment {
        let score: Int
        let moment: VideoCaptionMoment
    }
    var scoredMoments: [ScoredMoment] = []
    for lineIndex in captionLines.indices {
        let lineMatches = queryWords.intersection(words(in: captionLines[lineIndex].text)).count
        guard lineMatches > 0 else { continue }
        let nextLineText = lineIndex + 1 < captionLines.count ? captionLines[lineIndex + 1].text : ""
        let nextLineMatches = queryWords.intersection(words(in: nextLineText)).count
        let momentText = nextLineText.isEmpty ? captionLines[lineIndex].text : "\(captionLines[lineIndex].text) \(nextLineText)"
        scoredMoments.append(ScoredMoment(
            score: lineMatches * 2 + nextLineMatches,
            moment: VideoCaptionMoment(seconds: captionLines[lineIndex].seconds, text: momentText)
        ))
    }
    return scoredMoments
        .sorted { first, second in
            if first.score != second.score { return first.score > second.score }
            return first.moment.seconds < second.moment.seconds
        }
        .prefix(limit)
        .map { scoredMoment in scoredMoment.moment }
}

// MARK: - Worker client

@MainActor
final class VoiceCommandClient {
    private let voiceCommandURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        guard let voiceCommandURL = URL(string: "\(workerBaseURL)/voice-command") else {
            preconditionFailure("Worker base URL did not form the voice command URL: \(workerBaseURL)")
        }
        self.voiceCommandURL = voiceCommandURL
        let configuration = URLSessionConfiguration.default
        // Haiku answers in about a second. Past this the app falls back to the keyword path.
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func requestToolCalls(messages: [JSONValue], tools: [VoiceToolDescriptor]) async throws -> VoiceCommandReply {
        let requestBody = JSONValue.object([
            "messages": .array(messages),
            "tools": .array(tools.map(\.workerRequestJSON)),
        ])
        var request = URLRequest(url: voiceCommandURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestBody)
        let (responseData, response) = try await session.data(for: request)
        // URLSession returns URLResponse. The Worker answers over HTTP.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            throw VoiceCommandError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        try Task.checkCancellation()
        return try VoiceCommandReply(responseData: responseData)
    }
}
