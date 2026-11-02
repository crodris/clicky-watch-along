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
    /// One label shows "?" and Clicky asks the learner to name that part after the tour.
    case quiz
}

enum FieldTripPhase {
    case idle
    case buildingScene(FieldTripSceneKind)
    case touring(quizToAskAfterTour: FieldTripQuiz?)
    case awaitingAnswer(FieldTripQuiz, wrongAnswerCount: Int)
    /// The scene stays on screen until the next question clears it.
    case allLabelsShowing
}

struct FieldTripQuiz {
    let answerLabel: String
    let question: String

    init(answerLabel: String, question: String) {
        self.answerLabel = answerLabel
        self.question = question
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
        of: #"\b(quiz\w*|test me)\b"#,
        options: .regularExpression
    ) != nil
    if asksToBeQuizzed {
        return .quiz
    }
    let asksToLookInside = lowercaseTranscript.contains("inside")
        || lowercaseTranscript.contains("look like")
        || lowercaseTranscript.contains("show me")
    return asksToLookInside ? .explore : nil
}
