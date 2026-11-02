//
//  FieldTripSession.swift
//  leanring-buddy
//
//  Phase of a field-trip question, the quiz hidden inside the scene, and the
//  word match that decides whether a spoken answer is right.
//

import Foundation

enum FieldTripSceneKind {
    /// Every label stays visible, and nothing is asked after the tour.
    case explore
    /// One label shows "?" and Clicky asks what that part is and what it does after the tour.
    case quiz
}

enum FieldTripPhase {
    case idle
    case buildingScene(FieldTripSceneKind)
    case touring(quizToAskAfterTour: FieldTripQuiz?)
    case awaitingAnswer(FieldTripQuiz, wrongAnswerCount: Int)
    /// The learner named the part. Clicky is waiting to hear what it does.
    case awaitingFollowUpOnWhatThePartDoes(FieldTripQuiz, missedFunctionAnswerCount: Int)
    /// The scene stays on screen until the next question clears it.
    case allLabelsShowing
}

enum FieldTripQuizGrade: Equatable {
    case nameAndFunctionWord
    case nameOnly
    case wrong
    case askedForHelp
}

struct FieldTripQuiz {
    let answerLabel: String
    let question: String
    let functionWords: [String]
    let explanation: String
    /// What the learner has heard of a video so far, so an answer is graded on that.
    var heardTranscript = ""

    init(
        answerLabel: String,
        question: String,
        functionWords: [String] = [],
        explanation: String = ""
    ) {
        self.answerLabel = answerLabel
        self.question = question
        self.functionWords = functionWords
        self.explanation = explanation
    }

    init(specJSONData: Data) throws {
        let specJSONValue = try JSONSerialization.jsonObject(with: specJSONData)
        // JSONSerialization returns Any. A scene spec is one JSON object.
        // quiz is an object, and parts is an array of objects.
        guard let specDictionary = specJSONValue as? [String: Any] else {
            throw FieldTripSpecDecodingError.specWasNotAJSONObject
        }
        guard let quizDictionary = specDictionary["quiz"] as? [String: Any],
              let partId = quizDictionary["partId"] as? String,
              let question = quizDictionary["question"] as? String,
              let parts = specDictionary["parts"] as? [[String: Any]] else {
            throw FieldTripSpecDecodingError.quizOrPartsWereMissing
        }
        let answerPart = parts.first { part in
            // Each part is a JSON object. Its id is a string.
            let partIdInSpec = part["id"] as? String
            return partIdInSpec == partId
        }
        // The matching part's label is the spoken answer.
        guard let answerPart, let answerLabel = answerPart["label"] as? String else {
            throw FieldTripSpecDecodingError.answerLabelWasMissing
        }
        self.answerLabel = answerLabel
        self.question = question
        self.functionWords = quizDictionary["functionWords"] as? [String] ?? []
        self.explanation = quizDictionary["explanation"] as? String ?? ""
    }
}

enum FieldTripSpecDecodingError: Error, CustomStringConvertible {
    case specWasNotAJSONObject
    case quizOrPartsWereMissing
    case answerLabelWasMissing

    var description: String {
        switch self {
        case .specWasNotAJSONObject:
            return "Field trip spec was not a JSON object"
        case .quizOrPartsWereMissing:
            return "Field trip spec was missing a quiz or parts"
        case .answerLabelWasMissing:
            return "Field trip quiz part had no label"
        }
    }
}

enum FieldTripAnswerJudge {
    /// Lowercases both strings, turns punctuation into spaces, and splits on
    /// words. Right when every word of the label shows up in the transcript.
    nonisolated static func isCorrect(transcript: String, answerLabel: String) -> Bool {
        let transcriptWords = words(in: transcript)
        let answerWords = words(in: answerLabel)
        return answerWords.allSatisfy { answerWord in
            transcriptWords.contains(answerWord)
        }
    }

    /// A quiz with no function words is complete once the learner names the part.
    /// Older specs have nothing else to grade.
    nonisolated static func gradeSpokenAnswer(transcript: String, quiz: FieldTripQuiz) -> FieldTripQuizGrade {
        let lowercaseTranscript = transcript.lowercased()
        let learnerAskedForHelp = ["no idea", "don't know", "dont know", "tell me", "not sure"].contains { helpPhrase in
            lowercaseTranscript.contains(helpPhrase)
        }
        if learnerAskedForHelp {
            return .askedForHelp
        }
        let transcriptNamesThePart = isCorrect(transcript: transcript, answerLabel: quiz.answerLabel)
        if !transcriptNamesThePart {
            return .wrong
        }
        let transcriptSaysWhatThePartDoes = quiz.functionWords.isEmpty
            || transcriptIncludesFunctionWord(transcript: transcript, functionWords: quiz.functionWords)
        if transcriptSaysWhatThePartDoes {
            return .nameAndFunctionWord
        }
        return .nameOnly
    }

    nonisolated static func transcriptIncludesFunctionWord(transcript: String, functionWords: [String]) -> Bool {
        let transcriptWords = words(in: transcript)
        return functionWords.contains { functionWord in
            let functionWordTokens = words(in: functionWord)
            guard !functionWordTokens.isEmpty else {
                return false
            }
            return functionWordTokens.allSatisfy { functionWordToken in
                transcriptWords.contains(functionWordToken)
            }
        }
    }

    nonisolated private static func words(in text: String) -> [String] {
        let lowercaseText = text.lowercased()
        let textWithPunctuationAsSpaces = lowercaseText.map { character -> Character in
            let characterIsPunctuation = character.unicodeScalars.allSatisfy { scalar in
                CharacterSet.punctuationCharacters.contains(scalar)
            }
            if characterIsPunctuation {
                return " "
            }
            return character
        }
        let cleanedText = String(textWithPunctuationAsSpaces)
        return cleanedText.split(whereSeparator: { character in
            character.isWhitespace
        }).map { word in
            String(word)
        }
    }
}

/// The scene this transcript asks for, or nil when it asks for none. A quiz
/// request wins, because "show me inside and quiz me" wants the quiz.
nonisolated func fieldTripSceneKind(for transcript: String) -> FieldTripSceneKind? {
    let lowercaseTranscript = transcript.lowercased()
    let asksToBeQuizzed = lowercaseTranscript.range(
        of: #"\b(quiz\w*|test me|kiss me)\b"#,
        options: .regularExpression
    ) != nil
    if asksToBeQuizzed {
        return .quiz
    }
    let asksToLookInside = lowercaseTranscript.contains("inside")
        || lowercaseTranscript.contains("look like")
        || lowercaseTranscript.contains("show me")
        || lowercaseTranscript.contains("3d")
        || lowercaseTranscript.contains("3-d")
        || lowercaseTranscript.contains("three d ")
    return asksToLookInside ? .explore : nil
}

/// Splits "[PART:Aorta] It carries blood. [PART:Heart] It pumps." into one entry
/// per tagged sentence. Text with no tags comes back as a single entry.
nonisolated func fieldTripSpokenParts(from responseText: String) -> [(partLabel: String?, spokenText: String)] {
    let tagPattern = #"\[PART:([^\]]+)\]"#
    guard let tagExpression = try? NSRegularExpression(pattern: tagPattern) else {
        return [(nil, responseText)]
    }
    let fullRange = NSRange(responseText.startIndex..., in: responseText)
    let tagMatches = tagExpression.matches(in: responseText, range: fullRange)
    guard let firstTagRange = tagMatches.first.flatMap({ Range($0.range, in: responseText) }) else {
        return [(nil, responseText)]
    }

    var spokenParts: [(partLabel: String?, spokenText: String)] = []
    let textBeforeFirstTag = responseText[..<firstTagRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    if !textBeforeFirstTag.isEmpty {
        spokenParts.append((nil, textBeforeFirstTag))
    }
    for (matchIndex, tagMatch) in tagMatches.enumerated() {
        guard let wholeTagRange = Range(tagMatch.range, in: responseText),
              let labelRange = Range(tagMatch.range(at: 1), in: responseText) else { continue }
        let nextTagStart = matchIndex + 1 < tagMatches.count
            ? Range(tagMatches[matchIndex + 1].range, in: responseText)?.lowerBound ?? responseText.endIndex
            : responseText.endIndex
        let spokenText = responseText[wholeTagRange.upperBound..<nextTagStart]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !spokenText.isEmpty {
            spokenParts.append((String(responseText[labelRange]), spokenText))
        }
    }
    return spokenParts
}
