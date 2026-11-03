//
//  LiveSceneClient.swift
//  leanring-buddy
//
//  Asks the Worker for a live scene. The cursor screen goes up as a
//  JPEG. /live-scene returns generated HTML and a quiz. /judge-answer grades
//  a spoken answer. Anything other than 200 throws.
//

import Foundation

struct LiveScenePage: Decodable {
    let html: String
    let quiz: LiveSceneQuiz
}

struct LiveSceneJudgedAnswer {
    let grade: LiveSceneQuizGrade
    let spokenReply: String
}

@MainActor
final class LiveSceneClient {
    private let liveSceneURL: URL
    private let judgeAnswerURL: URL
    private let liveSceneSession: URLSession
    private let judgeAnswerSession: URLSession

    init(workerBaseURL: String) {
        guard let liveSceneURL = URL(string: "\(workerBaseURL)/live-scene"),
              let judgeAnswerURL = URL(string: "\(workerBaseURL)/judge-answer") else {
            preconditionFailure("Worker base URL did not form live-scene URLs: \(workerBaseURL)")
        }
        self.liveSceneURL = liveSceneURL
        self.judgeAnswerURL = judgeAnswerURL

        // Sol Ultrafast builds a scene in 14 to 20 seconds. Test runs use Sonnet, which takes about 27.
        self.liveSceneSession = Self.session(timeoutInterval: 60)
        // Sonnet grades in about 3 seconds and sometimes takes 6. Past this the app falls back to a word match.
        self.judgeAnswerSession = Self.session(timeoutInterval: 8)
    }

    /// Past 60 seconds the request times out and Clicky says it couldn't build the scene.
    func requestLiveScene(question: String, cursorScreenJPEGData: Data) async throws -> LiveScenePage {
        let body = try sceneRequestBody(question: question, cursorScreenJPEGData: cursorScreenJPEGData)
        let responseData = try await postJSON(
            url: liveSceneURL,
            body: body,
            session: liveSceneSession
        )
        return try liveScene(from: responseData)
    }

    func judgeSpokenAnswer(
        question: String,
        answerLabel: String,
        explanation: String,
        transcript: String,
        heardTranscript: String
    ) async throws -> LiveSceneJudgedAnswer {
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
            session: judgeAnswerSession
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
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        // URLSession returns URLResponse. The Worker answers over HTTP.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw liveSceneAPIError(statusCode: -1, message: "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw liveSceneAPIError(
                statusCode: httpResponse.statusCode,
                message: "Live scene API error (\(httpResponse.statusCode)): \(errorBody)"
            )
        }

        try Task.checkCancellation()
        return data
    }

    private struct JudgeAnswerResponse: Decodable {
        let verdict: String
        let spokenReply: String
    }

    private func liveScene(from responseData: Data) throws -> LiveScenePage {
        do {
            return try JSONDecoder().decode(LiveScenePage.self, from: responseData)
        } catch {
            throw liveSceneAPIError(statusCode: -1, message: "Live scene response was missing html or quiz")
        }
    }

    private func judgedAnswer(from responseData: Data) throws -> LiveSceneJudgedAnswer {
        let response: JudgeAnswerResponse
        do {
            response = try JSONDecoder().decode(JudgeAnswerResponse.self, from: responseData)
        } catch {
            throw liveSceneAPIError(statusCode: -1, message: "Judge response was missing a verdict")
        }
        let grade: LiveSceneQuizGrade
        switch response.verdict {
        case "correct":
            grade = .nameAndFunctionWord
        case "asked_for_help":
            grade = .askedForHelp
        case "named_only":
            grade = .nameOnly
        case "wrong":
            grade = .wrong
        default:
            throw liveSceneAPIError(statusCode: -1, message: "Judge verdict was \(response.verdict)")
        }
        return LiveSceneJudgedAnswer(grade: grade, spokenReply: response.spokenReply)
    }

    private func liveSceneAPIError(statusCode: Int, message: String) -> NSError {
        NSError(
            domain: "LiveScene",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
