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
    case buildSimulation = "build_simulation"
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
    case makeStudyGuide = "make_study_guide"
    case reviseStudyGuide = "revise_study_guide"
    case openStudyGuide = "open_study_guide"
    case buildModelInTheBackground = "build_model_in_background"
    case showReadyModel = "show_ready_model"
    case startBackgroundTask = "start_background_task"
    case hearTaskAnswer = "hear_task_answer"
    case recordGuess = "record_guess"

    /// Whether the tool turns the request into a look at the media on screen, which draws the loop around it.
    /// A turn that only runs tools, such as turning a model or seeking a video, never does.
    var handsOffToALookAtTheMedia: Bool {
        switch self {
        case .answerWithScreen, .buildNewScene, .popOut:
            return true
        default:
            return false
        }
    }

    /// What the app can do right now. A tool that cannot work is left out, so the model never picks it.
    nonisolated struct Context: Equatable, Sendable {
        var sceneIsOnScreen: Bool
        var sceneHasLabels: Bool
        var videoIsInFront: Bool
        /// Caption search reads only YouTube's captions.
        var videoIsOnYouTube: Bool
        var videoQuizIsRunning: Bool
        /// While a quiz question waits for its answer, every utterance goes to the judge first. A hand-off
        /// to the old path would send it back to the judge, so only view and video tools are offered then.
        var quizQuestionIsOpen: Bool
        /// A study guide was already written for the YouTube video in front, so it can be revised or opened.
        var studyGuideExistsForTheFrontVideo = false
        /// A 3D model or experiment built in the background waits for the learner to ask for it.
        var backgroundSceneIsReady = false
        /// A task agent finished, and its answer waits until the learner asks what it found.
        var taskAnswerIsReady = false
        /// A simulation asked its prediction question, and Run stays locked until the learner guesses.
        var simulationIsWaitingForAGuess = false
        /// An experiment is on screen, so another build would be a second paid build of the same topic.
        var simulationIsOnScreen = false
    }

    static func available(in context: Context) -> [AppVoiceTool] {
        allCases.filter { appVoiceTool in
            switch appVoiceTool {
            case .answerWithScreen, .buildNewScene, .popOut:
                return !context.quizQuestionIsOpen
            // With an experiment on screen, set_control and run_simulation change it, and a second build costs a model call.
            case .buildSimulation:
                return !context.quizQuestionIsOpen && !context.simulationIsOnScreen
            // While a question is open the scene is the question's, so closing it or explaining a part,
            // which may be the answer, waits until the learner answers or skips.
            case .closeScene:
                return context.sceneIsOnScreen && !context.quizQuestionIsOpen
            case .explainPart:
                return context.sceneIsOnScreen && context.sceneHasLabels && !context.quizQuestionIsOpen
            case .pauseVideo, .playVideo, .seekRelative, .seekToTime, .setSpeed:
                return context.videoIsInFront
            case .findMoment:
                return context.videoIsInFront && context.videoIsOnYouTube
            case .endQuiz:
                return context.videoQuizIsRunning
            // The guide is written from the video's captions, which only YouTube's are read. A question's own
            // answers are part of the guide, so it waits until the learner answers or skips.
            // A video gets one guide, so once it has one the model can only open or revise it.
            case .makeStudyGuide:
                return context.videoIsInFront && context.videoIsOnYouTube && !context.quizQuestionIsOpen && !context.studyGuideExistsForTheFrontVideo
            case .reviseStudyGuide, .openStudyGuide:
                return context.videoIsInFront && context.videoIsOnYouTube && !context.quizQuestionIsOpen && context.studyGuideExistsForTheFrontVideo
            // The model is built from a screenshot of the video, so it needs a video in front. A question's scene is the
            // question's, so a model waits to show until the learner answers or skips.
            case .buildModelInTheBackground:
                return context.videoIsInFront && !context.quizQuestionIsOpen
            case .showReadyModel:
                return context.backgroundSceneIsReady && !context.quizQuestionIsOpen
            // A question's own answer could come from the web, so a task waits until the learner answers or skips.
            case .startBackgroundTask:
                return !context.quizQuestionIsOpen
            case .hearTaskAnswer:
                return context.taskAnswerIsReady && !context.quizQuestionIsOpen
            case .recordGuess:
                return context.simulationIsWaitingForAGuess && !context.quizQuestionIsOpen
            }
        }
    }

    /// These act on what the learner said, so the debug MCP endpoint, which has no spoken request, leaves them out.
    var needsTheSpokenRequest: Bool {
        self == .answerWithScreen || self == .buildNewScene || self == .buildSimulation
    }

    var descriptor: VoiceToolDescriptor {
        VoiceToolDescriptor(name: rawValue, description: toolDescription, inputSchema: inputSchema, readOnly: self == .findMoment)
    }

    private var toolDescription: String {
        switch self {
        case .answerWithScreen:
            return "Answer a question about what is on screen, using a screenshot. Use it for questions and for anything no other tool can do, not for changing the view."
        case .buildNewScene:
            return "Build a 3D view now, which pauses the video and takes about 20 seconds. Use it when the learner asks to show, see, or render something in 3D, such as \"show me this in 3D\" over a video, where a famous real place appears as its real 3D scan, and when they want a different model or something not on screen yet. When they ask to build, make, or create a 3D model, use build_model_in_background instead, if it is offered. When they want to try it, play with it, or simulate it, use build_simulation instead. Never use it to turn, zoom, or open the model already showing."
        case .buildSimulation:
            return "Build a playable experiment of what the video or screen shows, such as a ball launched at an angle, a lever, or a pendulum, with sliders and a Run button. It builds in the background for about 30 to 40 seconds while the video keeps playing, and then rises out of the video, or waits until the learner asks to see it if something else is on screen. Use it when the learner says let me try it, let me play with it, can I try it, or simulate this, and no simulation is on screen yet. When one is on screen, use set_control and run_simulation instead. Your confirmation is a few plain words that it has started, such as \"setting it up\", never that it is done."
        case .popOut:
            return "Lift the subject of the video frame or the largest picture in Chrome's front tab out in 3D with its parts labeled. Use it only when they say pop this out or pop it out."
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
        case .makeStudyGuide:
            return "Write a Notion study guide for the YouTube video in Chrome's front tab. It runs in the background for up to a minute while the video keeps playing, and a chip under the cursor shows when the page is ready, with nothing spoken. Use it when the learner asks for a study guide, notes, or a summary page in Notion. Put an extra wish, such as only the part about the engine, in focus. Your confirmation is a few plain words that it has started, such as \"writing it now\", never that it is done."
        case .reviseStudyGuide:
            return "Change the study guide already written for this video, such as making it shorter, adding detail on one part, or adding a section. The new page replaces the old one in Notion and is written in the background. Put what to change in instruction, in the learner's words. Your confirmation is a few plain words that it has started, such as \"updating it now\", never that it is done."
        case .openStudyGuide:
            return "Open this video's study guide page in Notion. Use it when the learner asks to see, open, or go to the guide, and when they ask for a new study guide, since this video already has one. In that case your confirmation says they already have a guide for this video and you are opening it."
        case .buildModelInTheBackground:
            return "Build a 3D model of what the video shows in the background, for about 20 seconds, while the video keeps playing. When it is ready it rises out of the video, or waits until the learner asks for it if something else is on screen. Use it when the learner asks to build, make, or create a 3D model, such as \"build me a 3D model of this engine\", or asks for one while they keep watching. Use build_new_scene instead when they ask to show, see, or render something in 3D right now, and for a famous real place, whose real 3D scan only build_new_scene shows. Put what to build in whatToBuild, in the learner's words. Your confirmation is a few plain words that it has started, such as \"starting the model\", never that it is done."
        case .showReadyModel:
            return "Show the 3D model or experiment built in the background, which is ready and waiting. It pauses the video and rises out of it. Use it when the learner asks to see, show, or open the model or the experiment."
        case .startBackgroundTask:
            return "Hand a task to a background agent that works on its own for a minute or two while the learner keeps watching. It can search the web, read this video's captions, look at the video, and write a Notion page. Use it when the learner asks you to find out, look up, research, compare, check, or collect something that needs more than a quick answer from the screen, such as \"find out how this compares to the first booster catch\". Use make_study_guide for a study guide of this video, and build_model_in_background for a 3D model. Put the task in goal, in the learner's words, with what this or that refers to on screen. Your confirmation is a few plain words that it has started, such as \"looking into it\", never that it is done."
        case .hearTaskAnswer:
            return "Say what the background task agent found. Use it when the learner asks what it found, what the answer was, or to hear the result."
        case .recordGuess:
            return "Record the learner's guess to the simulation's prediction question, the scene state's predictionQuestion, which unlocks the Run button and the dashed path. Use it for any answer to that question, even a short or unsure one, such as \"60 goes farther\", \"they tie\", or \"the first one\". Do not use it for a command such as changing a control or running it. Put the guess in guess, in the learner's words. Your confirmation is a few plain words, such as \"got it, now try it\"."
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
        case .answerWithScreen, .buildSimulation, .popOut, .closeScene, .pauseVideo, .playVideo, .endQuiz:
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
        case .makeStudyGuide:
            return objectSchema(["focus": .object(["type": .string("string"), "description": .string("An extra wish for the guide, such as only the part about the engine. Leave it out when they made none.")])], required: [])
        case .recordGuess:
            return objectSchema(["guess": .object(["type": .string("string"), "description": .string("The learner's guess, in their words.")])], required: ["guess"])
        case .reviseStudyGuide:
            return objectSchema(["instruction": .object(["type": .string("string"), "description": .string("What to change about the guide, in the learner's words.")])], required: ["instruction"])
        case .openStudyGuide, .showReadyModel, .hearTaskAnswer:
            return objectSchema([:], required: [])
        case .startBackgroundTask:
            return objectSchema(["goal": .object(["type": .string("string"), "description": .string("The task in the learner's words, with what it refers to on screen.")])], required: ["goal"])
        case .buildModelInTheBackground:
            return objectSchema(["whatToBuild": .object(["type": .string("string"), "description": .string("What to build, in the learner's words, such as this jet engine.")])], required: ["whatToBuild"])
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

    /// What the chip next to the cursor says, in words a learner reads at a glance, such as "Turning it left".
    /// Nil for a call whose own status line or answer follows at once, like pop_out's "Popping it out",
    /// for a call that changes nothing (a zoom factor of 1, a seek that rounds to 0 seconds), for a missing
    /// or out-of-range argument (a negative or non-finite seek time), and for a name this app does not know.
    /// `chipPhraseToShow(at:)` decides when the phrase shows.
    var chipPhrase: String? {
        let numberInput = { (argumentName: String) in self.input[argumentName]?.numberValue }
        let textInput = { (argumentName: String) in self.input[argumentName]?.stringValue }
        switch name {
        case "rotate_model":
            if let yawDegrees = numberInput("yawDegrees"), yawDegrees != 0 {
                return yawDegrees < 0 ? "Turning it left" : "Turning it right"
            }
            if let pitchDegrees = numberInput("pitchDegrees"), pitchDegrees != 0 {
                return pitchDegrees > 0 ? "Looking from above" : "Looking from below"
            }
            return "Turning it"
        case "zoom":
            // The page refuses a missing factor and does nothing at 1, so the chip says nothing either.
            guard let zoomFactor = numberInput("factor"), zoomFactor != 1 else { return nil }
            return zoomFactor > 1 ? "Zooming in" : "Zooming out"
        case "zoom_to_part":
            return textInput("label").map { partLabel in "Zooming in on the \(partLabel)" } ?? "Zooming in"
        case "reset_view":
            return "Back to the start"
        case "explode_view":
            // The page refuses a missing amount, so the chip says nothing for it.
            guard let explodeAmount = numberInput("amount") else { return nil }
            return explodeAmount > 0 ? "Pulling it apart" : "Putting it together"
        case "set_inside_view":
            // The page opens the cutaway only for a true open, so the chip reads it the same way.
            return input["open"]?.boolValue == true ? "Opening it up" : "Closing it up"
        case "set_control":
            // The page refuses a missing name or value, so the chip says nothing for them either.
            guard let controlName = textInput("name"), let controlValue = numberInput("value") else { return nil }
            let valueText = Int(exactly: controlValue).map(String.init) ?? String(format: "%.1f", controlValue)
            return "Setting \(controlName) to \(valueText)"
        case "run_simulation":
            return "Running it"
        case "record_guess":
            return "Got your guess"
        case "set_labels":
            // The page shows labels only for a true visible, so the chip reads it the same way.
            return input["visible"]?.boolValue == true ? "Showing the labels" : "Hiding the labels"
        case "close_scene":
            return "Putting it back"
        case "explain_part":
            return textInput("label").map { partLabel in "The \(partLabel)" }
        case "pause_video":
            return "Pausing the video"
        case "play_video":
            return "Playing the video"
        case "seek_relative":
            guard let seconds = numberInput("seconds"), let wholeSeconds = Int(exactly: abs(seconds).rounded()), wholeSeconds > 0 else { return nil }
            let secondsText = wholeSeconds == 1 ? "1 second" : "\(wholeSeconds) seconds"
            return seconds > 0 ? "Skipping ahead \(secondsText)" : "Going back \(secondsText)"
        case "seek_to_time":
            guard let seconds = numberInput("seconds"), seconds >= 0, let wholeSeconds = Int(exactly: seconds.rounded()) else { return nil }
            return "Jumping to \(wholeSeconds / 60):\(String(format: "%02d", wholeSeconds % 60))"
        case "set_speed":
            guard let rate = numberInput("rate") else { return nil }
            // A fixed POSIX locale keeps "1.5x" from reading "1,5x" in a comma-decimal locale.
            let rateText = rate.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
            return rate == 1 ? "Normal speed" : "Playing at \(rateText)x"
        case "find_moment":
            return textInput("query").map { query in "Finding \u{201C}\(query)\u{201D}" } ?? "Searching the captions"
        case "end_quiz":
            return "Ending the quiz"
        case "make_study_guide":
            return "Starting your study guide"
        case "revise_study_guide":
            return "Updating your study guide"
        case "open_study_guide":
            return "Opening your study guide"
        case "build_model_in_background":
            return "Starting your 3D model"
        case "build_simulation":
            return "Starting your experiment"
        case "start_background_task":
            return "Starting a task"
        default:
            // pop_out, build_new_scene, answer_with_screen, show_ready_model, and hear_task_answer hand off to a path with
            // its own status line, thinking dots, rising scene, or voice.
            return nil
        }
    }

    /// The phrase the chip shows at this moment of the call, or nil. A lookup like find_moment changes nothing on screen,
    /// so its chip shows while it runs. Any other call's chip waits until the call worked, so a refused call never
    /// shows a chip claiming it happened.
    func chipPhraseToShow(at chipMoment: VoiceToolChipMoment) -> String? {
        let callIsALookup = AppVoiceTool(rawValue: name)?.descriptor.readOnly == true
        switch chipMoment {
        case .beforeTheCall:
            return callIsALookup ? chipPhrase : nil
        case .afterTheCall(let outcome):
            // Showing a ready experiment is a hand-off, since its rise and the lesson's own voice follow at once.
            // Only starting a build is a call whose chip says so.
            if name == AppVoiceTool.buildSimulation.rawValue && outcome == .handedOff { return nil }
            return callIsALookup || outcome.isFailure ? nil : chipPhrase
        }
    }

    /// The same, but a call to a tool this turn did not offer shows nothing, since `runVoiceTool` refuses it without running it.
    func chipPhraseToShow(at chipMoment: VoiceToolChipMoment, offeredToolNames: Set<String>) -> String? {
        guard offeredToolNames.contains(name) else { return nil }
        return chipPhraseToShow(at: chipMoment)
    }

    /// The call as code, such as rotate_model(yawDegrees: -45). Debug builds show it on the chip
    /// while the panel's "Log tool call JSON" switch is on, and the log always prints it.
    var chipText: String {
        let argumentsText = inputWithoutConfirmation
            .sorted { $0.key < $1.key }
            .map { argumentName, argumentValue in
                let valueText: String
                switch argumentValue {
                case .number(let numberValue):
                    // Int(exactly:) is nil for a huge or fractional value, which Int() would trap on.
                    valueText = Int(exactly: numberValue).map(String.init) ?? String(format: "%.2f", numberValue)
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

/// When the voice tool chip is asked what to show: as a call starts, or once it has run.
nonisolated enum VoiceToolChipMoment: Sendable {
    case beforeTheCall
    case afterTheCall(VoiceToolOutcome)
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

/// The page tools scene-tools.js defines. A page can rewrite what it lists, so only these names are offered
/// from it, and none of them can shadow an app tool.
nonisolated let pageVoiceToolNames: Set<String> = ["rotate_model", "zoom", "zoom_to_part", "reset_view", "explode_view", "set_inside_view", "set_control", "run_simulation", "set_labels"]

/// A page's tool description is page text the model reads, so it is cut to a length that fits the bundled tools' own
/// text, the longest being set_control's with three controls.
nonisolated let longestPageToolDescription = 1000

/// A page's tool input schema is page text the model reads too, and it is not cut, so a page tool whose schema
/// encodes to more bytes than this is dropped. The bundled tools' schemas are a few hundred bytes.
nonisolated let largestPageToolInputSchemaBytes = 2000

/// The Worker refuses a request with two tools of one name, which would send every command to the keyword path, so a
/// page that lists a name twice keeps its first entry.
nonisolated func voiceToolsOfferedToTheModel(pageTools: [VoiceToolDescriptor], appTools: [AppVoiceTool]) -> [VoiceToolDescriptor] {
    var pageToolNamesSeen: Set<String> = []
    let knownPageTools = pageTools
        .filter { pageTool in
            pageVoiceToolNames.contains(pageTool.name)
                && pageTool.inputSchema.compactJSONText.utf8.count <= largestPageToolInputSchemaBytes
                && pageToolNamesSeen.insert(pageTool.name).inserted
        }
        .map { pageTool in
            VoiceToolDescriptor(
                name: pageTool.name,
                description: String(pageTool.description.prefix(longestPageToolDescription)),
                inputSchema: pageTool.inputSchema,
                readOnly: pageTool.readOnly
            )
        }
    return knownPageTools + appTools.map(\.descriptor)
}

/// Spoken text comes from the model, which reads page text, so it is cut to a length that fits a confirmation or one sentence.
nonisolated let longestSpokenVoiceCommandLine = 300

/// The confirmations are spoken only when every tool changed the screen. A lookup or a failure goes back
/// to the model, which then acts on the lookup or says what went wrong.
nonisolated func voiceCommandNextStep(toolCalls: [VoiceToolCall], outcomes: [VoiceToolOutcome], replyText: String) -> VoiceCommandNextStep {
    if outcomes.contains(.handedOff) {
        return .finishSilently
    }
    if toolCalls.isEmpty {
        return .speak(String(replyText.prefix(longestSpokenVoiceCommandLine)))
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
    return .speak(String(confirmations.joined(separator: " ").prefix(longestSpokenVoiceCommandLine)))
}

/// What Clicky says when the router's turns run out with the model still waiting on a lookup or a failure, so the learner
/// is never left in silence. It is always this apology, never the model's last words: the Worker tells the model that
/// text next to a tool call is never spoken, so that text was written before the call ran and can claim a success that failed.
nonisolated let voiceCommandGaveUpLine = "Sorry, I couldn't do that one."

/// A play counts only once the video is really playing, meaning not paused and holding data to play, so Clicky
/// never says "playing" over a stopped video. Chrome refuses a video with sound on a page never clicked, and
/// some pages load their video only after a click, which leaves an empty player that reports itself unpaused.
/// Either way the failure goes back to the model, which tells the learner to click the video's play button once.
nonisolated func learnerVideoPlayOutcome(videoStateAfterPlay: JSONValue?) -> VoiceToolOutcome {
    guard let videoStateAfterPlay else {
        return .failed(error: "The video is gone from Chrome's front tab", state: nil)
    }
    let videoState = JSONValue.object(["video": videoStateAfterPlay])
    if videoStateAfterPlay["playing"]?.boolValue != true {
        return .failed(error: "The video did not start. Some pages only load or play their video after a click, so the learner should click the video's play button once.", state: videoState)
    }
    return .changed(state: videoState)
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

/// The router takes a command only when something is live to command: a scene on screen, a
/// video in Chrome's front tab, on any site, a 3D model or experiment built in the background waiting to be shown, or a task answer
/// waiting to be heard, since "what did you find" may come from the page the task agent opened.
/// A quiz answer goes to the judge, and a scene still building keeps its keyword path.
nonisolated func voiceCommandRouterTakesTheTranscript(
    sceneIsOnScreen: Bool,
    videoIsInFront: Bool,
    backgroundSceneIsReady: Bool = false,
    taskAnswerIsReady: Bool = false,
    phaseIsWaitingForAQuizAnswer: Bool,
    sceneIsBuilding: Bool
) -> Bool {
    if phaseIsWaitingForAQuizAnswer || sceneIsBuilding { return false }
    return sceneIsOnScreen || videoIsInFront || backgroundSceneIsReady || taskAnswerIsReady
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
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(requestBody),
            to: voiceCommandURL,
            using: session,
            sendsAppSecret: false
        )
        guard statusCode == 200 else {
            throw VoiceCommandError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        try Task.checkCancellation()
        return try VoiceCommandReply(responseData: responseData)
    }
}
