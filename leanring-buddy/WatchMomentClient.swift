//
//  WatchMomentClient.swift
//  leanring-buddy
//
//  Asks the Worker whether the last stretch of a video is a good moment to
//  pause and quiz the learner. Anything other than a 200 throws.
//

import Foundation

struct WatchMomentResponse: Decodable {
    let shouldPause: Bool
    let question: String?
    let answerLabel: String?
    let functionWords: [String]?
    let explanation: String?

    /// The quiz for this moment, or nil when the Worker said not to pause or
    /// left out the question or the answer.
    func makeQuizIfPausing() -> FieldTripQuiz? {
        guard shouldPause,
              let question, !question.isEmpty,
              let answerLabel, !answerLabel.isEmpty else {
            return nil
        }
        return FieldTripQuiz(
            answerLabel: answerLabel,
            question: question,
            functionWords: functionWords ?? [],
            explanation: explanation ?? ""
        )
    }
}

@MainActor
final class WatchMomentClient {
    private let watchMomentURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        guard let watchMomentURL = URL(string: "\(workerBaseURL)/watch-moment") else {
            preconditionFailure("Worker base URL did not form a /watch-moment URL: \(workerBaseURL)")
        }
        self.watchMomentURL = watchMomentURL

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration)
    }

    func requestWatchMoment(
        transcript: String,
        newTranscript: String,
        alreadyAskedQuestions: [String],
        cursorScreenJPEGData: Data
    ) async throws -> WatchMomentResponse {
        var request = URLRequest(url: watchMomentURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Dictionary values are strings and an array of strings, so a plain
        // JSON dictionary is enough here.
        let body: [String: Any] = [
            "transcript": transcript,
            "newTranscript": newTranscript,
            "alreadyAskedQuestions": alreadyAskedQuestions,
            "screenshotBase64": cursorScreenJPEGData.base64EncodedString(),
            "screenshotMediaType": "image/jpeg",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        // URLSession returns URLResponse. The Worker answers over HTTP.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "WatchMoment",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "WatchMoment",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Watch moment API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        return try JSONDecoder().decode(WatchMomentResponse.self, from: data)
    }
}
