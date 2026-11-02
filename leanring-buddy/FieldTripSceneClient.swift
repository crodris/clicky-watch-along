//
//  FieldTripSceneClient.swift
//  leanring-buddy
//
//  Asks the Worker for a field-trip scene. The cursor screen goes up as a
//  JPEG. /scene returns a template spec. /live-scene returns generated HTML
//  and a quiz. /judge-answer grades a spoken answer. Anything other than 200 throws.
//

import Foundation

struct FieldTripLiveScene {
    let html: String
    let quiz: FieldTripQuiz
}

struct FieldTripJudgedAnswer {
    let grade: FieldTripQuizGrade
    let spokenReply: String
}

@MainActor
final class FieldTripSceneClient {
    private let sceneURL: URL
    private let liveSceneURL: URL
    private let judgeAnswerURL: URL
    private let session: URLSession
    private let liveSceneSession: URLSession
    private let judgeAnswerSession: URLSession

    init(workerBaseURL: String) {
        guard let sceneURL = URL(string: "\(workerBaseURL)/scene"),
              let liveSceneURL = URL(string: "\(workerBaseURL)/live-scene"),
              let judgeAnswerURL = URL(string: "\(workerBaseURL)/judge-answer") else {
            preconditionFailure("Worker base URL did not form field-trip URLs: \(workerBaseURL)")
        }
        self.sceneURL = sceneURL
        self.liveSceneURL = liveSceneURL
        self.judgeAnswerURL = judgeAnswerURL

        let configuration = URLSessionConfiguration.default
        // A template scene is one or two model calls, so this waits longer than a TTS clip.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
        self.liveSceneSession = Self.session(timeoutInterval: 30)
        self.judgeAnswerSession = Self.session(timeoutInterval: 5)
    }

    func requestScene(question: String, cursorScreenJPEGData: Data) async throws -> Data {
        let body = try sceneRequestBody(question: question, cursorScreenJPEGData: cursorScreenJPEGData)
        return try await postJSON(url: sceneURL, body: body, session: session, timeoutInterval: nil)
    }

    /// Sol Ultrafast usually answers in under 30 seconds. Past that, the caller
    /// falls back to the template scene.
    func requestLiveScene(question: String, cursorScreenJPEGData: Data) async throws -> FieldTripLiveScene {
        let body = try sceneRequestBody(question: question, cursorScreenJPEGData: cursorScreenJPEGData)
        let responseData = try await postJSON(
            url: liveSceneURL,
            body: body,
            session: liveSceneSession,
            timeoutInterval: 30
        )
        return try liveScene(from: responseData)
    }

    func judgeSpokenAnswer(
        question: String,
        answerLabel: String,
        explanation: String,
        transcript: String,
        heardTranscript: String
    ) async throws -> FieldTripJudgedAnswer {
        let body = [
            "question": question,
            "answerLabel": answerLabel,
            "explanation": explanation,
            "transcript": transcript,
            "heardTranscript": heardTranscript,
        ]
        let requestBody = try JSONSerialization.data(withJSONObject: body)
        let responseData = try await postJSON(
            url: judgeAnswerURL,
            body: requestBody,
            session: judgeAnswerSession,
            timeoutInterval: 5
        )
        return try judgedAnswer(from: responseData)
    }

    private static func session(timeoutInterval: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        return URLSession(configuration: configuration)
    }

    private func sceneRequestBody(question: String, cursorScreenJPEGData: Data) throws -> Data {
        let body = [
            "question": question,
            "screenshotBase64": cursorScreenJPEGData.base64EncodedString(),
            "screenshotMediaType": "image/jpeg",
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func postJSON(
        url: URL,
        body: Data,
        session: URLSession,
        timeoutInterval: TimeInterval?
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        // URLSession returns URLResponse. The Worker answers over HTTP.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw fieldTripAPIError(statusCode: -1, message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw fieldTripAPIError(
                statusCode: httpResponse.statusCode,
                message: "Field trip API error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        try Task.checkCancellation()
        return data
    }

    private func liveScene(from responseData: Data) throws -> FieldTripLiveScene {
        let responseJSON = try JSONSerialization.jsonObject(with: responseData)
        // JSONSerialization returns Any. The live scene response is one JSON object.
        guard let responseDictionary = responseJSON as? [String: Any] else {
            throw fieldTripAPIError(statusCode: -1, message: "Live scene response was not a JSON object")
        }
        guard let html = responseDictionary["html"] as? String,
              let quizDictionary = responseDictionary["quiz"] as? [String: Any],
              let question = quizDictionary["question"] as? String,
              let answerLabel = quizDictionary["answerLabel"] as? String,
              let explanation = quizDictionary["explanation"] as? String,
              let functionWords = quizDictionary["functionWords"] as? [String] else {
            throw fieldTripAPIError(statusCode: -1, message: "Live scene response was missing html or quiz")
        }
        let quiz = FieldTripQuiz(
            answerLabel: answerLabel,
            question: question,
            functionWords: functionWords,
            explanation: explanation
        )
        return FieldTripLiveScene(html: html, quiz: quiz)
    }

    private func judgedAnswer(from responseData: Data) throws -> FieldTripJudgedAnswer {
        let responseJSON = try JSONSerialization.jsonObject(with: responseData)
        guard let responseDictionary = responseJSON as? [String: Any],
              let verdictName = responseDictionary["verdict"] as? String,
              let spokenReply = responseDictionary["spokenReply"] as? String else {
            throw fieldTripAPIError(statusCode: -1, message: "Judge response was missing a verdict")
        }
        let grade: FieldTripQuizGrade
        switch verdictName {
        case "correct":
            grade = .nameAndFunctionWord
        case "named_only":
            grade = .nameOnly
        case "wrong":
            grade = .wrong
        default:
            throw fieldTripAPIError(statusCode: -1, message: "Judge verdict was \(verdictName)")
        }
        return FieldTripJudgedAnswer(grade: grade, spokenReply: spokenReply)
    }

    private func fieldTripAPIError(statusCode: Int, message: String) -> NSError {
        NSError(
            domain: "FieldTripScene",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
