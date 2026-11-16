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
    let verdict: LiveSceneJudgeVerdict
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
    /// `sceneKind` picks a 3D model or, for `.simulation`, a page the learner can run.
    func requestLiveScene(question: String, cursorScreenJPEGData: Data, sceneKind: LiveSceneKind) async throws -> LiveScenePage {
        let body = try sceneRequestBody(question: question, cursorScreenJPEGData: cursorScreenJPEGData, sceneKind: sceneKind)
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

    private func sceneRequestBody(question: String, cursorScreenJPEGData: Data, sceneKind: LiveSceneKind) throws -> Data {
        let body = [
            "question": question,
            "screenshotBase64": cursorScreenJPEGData.base64EncodedString(),
            "screenshotMediaType": "image/jpeg",
            "kind": sceneKind.workerRequestKind,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func postJSON(
        url: URL,
        body: Data,
        session: URLSession
    ) async throws -> Data {
        let (data, statusCode) = try await WorkerJSONPost.send(body, to: url, using: session, sendsAppSecret: false)

        guard statusCode != -1 else {
            throw liveSceneAPIError(statusCode: -1, message: "Invalid response")
        }

        guard statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw liveSceneAPIError(
                statusCode: statusCode,
                message: "Live scene API error (\(statusCode)): \(errorBody)"
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
        guard let verdict = liveSceneJudgeVerdict(workerVerdict: response.verdict) else {
            throw liveSceneAPIError(statusCode: -1, message: "Judge verdict was \(response.verdict)")
        }
        return LiveSceneJudgedAnswer(verdict: verdict, spokenReply: response.spokenReply)
    }

    private func liveSceneAPIError(statusCode: Int, message: String) -> NSError {
        NSError(
            domain: "LiveScene",
            code: statusCode,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

/// The Worker's verdict word, or nil for a word this app version does not know.
nonisolated func liveSceneJudgeVerdict(workerVerdict: String) -> LiveSceneJudgeVerdict? {
    switch workerVerdict {
    case "correct": return .answer(.nameAndFunctionWord)
    case "named_only": return .answer(.nameOnly)
    case "wrong": return .answer(.wrong)
    case "asked_for_help": return .answer(.askedForHelp)
    case "skip_question": return .control(.skipQuestion)
    case "repeat_question": return .control(.repeatQuestion)
    case "wants_hint": return .control(.giveHint)
    case "scene_command": return .control(.sceneCommand)
    default: return nil
    }
}
