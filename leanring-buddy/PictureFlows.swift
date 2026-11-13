//
//  PictureFlows.swift
//  leanring-buddy
//
//  Streams of what flows through a popped-out picture, like air through an engine or blood
//  through a heart. Sonnet draws them through POST /picture-flows when the learner says
//  "animate this", and the pop-out page streams particles along them.
//

import Foundation

struct PictureFlow: Decodable, Equatable {
    /// Names what flows. The pop-out page maps each one to its own palette.
    enum Color: String, Decodable {
        case blue, red, orange, cyan, green, yellow, white
    }

    let color: Color
    /// The path in frame pixels, as [x, y] pairs, in the order the stream moves.
    let points: [[Int]]
}

/// What came of asking for a picture's flows, and what Clicky says when none are showing.
enum PictureFlowsOutcome: Equatable {
    case showing(flowCount: Int)
    case nothingFlows
    case failed
    /// A newer request took over, so this one says nothing.
    case superseded

    var spokenLineWhenNotShowing: String? {
        switch self {
        case .showing, .superseded:
            return nil
        case .nothingFlows:
            return "I don't see anything flowing through this picture to animate."
        case .failed:
            return "Sorry, I couldn't animate that one."
        }
    }
}

enum PictureFlowsClient {
    private struct FlowsResponse: Decodable {
        let flows: [PictureFlow]
    }

    /// Sonnet answers in about 4 seconds, while the pop-out tour plays.
    private static let requestTimeoutSeconds: TimeInterval = 15

    /// Empty when nothing in the picture flows.
    static func requestFlows(workerBaseURL: String, framePopout: VideoFramePopout) async throws -> [PictureFlow] {
        guard let flowsURL = URL(string: "\(workerBaseURL)/picture-flows") else {
            preconditionFailure("Worker base URL did not form the picture flows URL: \(workerBaseURL)")
        }
        var request = URLRequest(url: flowsURL, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "frameBase64": framePopout.frameGrab.jpeg,
            "frameWidth": framePopout.frameGrab.width,
            "frameHeight": framePopout.frameGrab.height,
            "partLabels": framePopout.parts.map(\.label),
        ])
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Picture flows returned \(statusCode): \(String(decoding: responseData.prefix(300), as: UTF8.self))",
            ])
        }
        return try JSONDecoder().decode(FlowsResponse.self, from: responseData).flows
    }
}
