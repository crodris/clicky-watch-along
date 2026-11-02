//
//  FieldTripSceneClient.swift
//  leanring-buddy
//
//  Asks the Worker for a field-trip spec. The cursor screen goes up as a
//  JPEG. The response body is the scene JSON. Anything other than 200 throws.
//

import Foundation

@MainActor
final class FieldTripSceneClient {
    private let sceneURL: URL
    private let session: URLSession

    init(workerBaseURL: String) {
        guard let sceneURL = URL(string: "\(workerBaseURL)/scene") else {
            preconditionFailure("Worker base URL did not form a /scene URL: \(workerBaseURL)")
        }
        self.sceneURL = sceneURL

        let configuration = URLSessionConfiguration.default
        // A live scene is one or two model calls, so this waits longer than a TTS clip.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: configuration)
    }

    func requestScene(question: String, cursorScreenJPEGData: Data) async throws -> Data {
        var request = URLRequest(url: sceneURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = [
            "question": question,
            "screenshotBase64": cursorScreenJPEGData.base64EncodedString(),
            "screenshotMediaType": "image/jpeg",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        // URLSession returns URLResponse. The Worker answers over HTTP.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "FieldTripScene",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response"]
            )
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "FieldTripScene",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Scene API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        try Task.checkCancellation()
        return data
    }
}
