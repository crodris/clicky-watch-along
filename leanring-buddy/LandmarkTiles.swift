//
//  LandmarkTiles.swift
//  leanring-buddy
//
//  A famous place Sonnet recognized in the paused video frame, and the bundled
//  landmark page that shows Google's Photorealistic 3D Tiles of it, cut down to
//  the structure and floating over the video.
//

import AppKit
import Foundation

struct FamousPlace: Decodable {
    let name: String
    let latitude: Double
    let longitude: Double
    let heightMeters: Double
    let radiusMeters: Double
}

private struct LandmarkResponse: Decodable {
    let isFamousPlace: Bool
    let name: String?
    let latitude: Double?
    let longitude: Double?
    let heightMeters: Double?
    let radiusMeters: Double?
}

enum LandmarkClient {
    /// Sonnet answers in about 3 seconds. Past this, the scene is built by GPT instead.
    private static let requestTimeoutSeconds: TimeInterval = 10

    /// Nil when the frame does not show one famous real place.
    /// Nil also when the learner asked about something other than the place in the frame.
    static func famousPlace(workerBaseURL: String, frameGrab: VideoFrameGrab, videoTitle: String, learnerRequest: String) async throws -> FamousPlace? {
        guard let landmarkURL = URL(string: "\(workerBaseURL)/landmark") else {
            preconditionFailure("Worker base URL did not form the landmark URL: \(workerBaseURL)")
        }
        var request = URLRequest(url: landmarkURL, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "frameBase64": frameGrab.jpeg,
            "videoTitle": videoTitle,
            "learnerRequest": learnerRequest,
        ])
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Landmark returned \(statusCode)"])
        }
        let landmarkResponse = try JSONDecoder().decode(LandmarkResponse.self, from: responseData)
        guard landmarkResponse.isFamousPlace,
              let name = landmarkResponse.name,
              let latitude = landmarkResponse.latitude,
              let longitude = landmarkResponse.longitude,
              let heightMeters = landmarkResponse.heightMeters,
              let radiusMeters = landmarkResponse.radiusMeters else {
            return nil
        }
        return FamousPlace(name: name, latitude: latitude, longitude: longitude, heightMeters: heightMeters, radiusMeters: radiusMeters)
    }
}

/// The bundled landmark page with this place in it, or nil when the template is missing.
/// Tiles load from clicky-asset://tiles, which the overlay forwards to the Worker.
func landmarkTilesPageHTML(for famousPlace: FamousPlace, frameGrab: VideoFrameGrab, overlayScreen: NSScreen) -> String? {
    let templateURL = Bundle.main.url(forResource: "landmark-tiles", withExtension: "html", subdirectory: "LiveSceneAssets")
        ?? Bundle.main.url(forResource: "landmark-tiles", withExtension: "html")
    guard let templateURL, let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) else {
        print("Landmark: landmark-tiles.html is not in the app bundle")
        return nil
    }
    let landmarkData: [String: Any] = [
        "name": famousPlace.name,
        "latitude": famousPlace.latitude,
        "longitude": famousPlace.longitude,
        "heightMeters": famousPlace.heightMeters,
        "radiusMeters": famousPlace.radiusMeters,
        "tilesRootURL": "clicky-asset://tiles/v1/3dtiles/root.json",
        "dracoDecoderPath": "clicky-asset://three/",
        "frameDataURL": "data:image/jpeg;base64,\(frameGrab.jpeg)",
        "videoRect": videoRectInOverlayPage(of: frameGrab, overlayScreen: overlayScreen),
    ]
    // JSONSerialization escapes "/" as "\/", so a place name can never close the script tag.
    guard let landmarkJSON = try? JSONSerialization.data(withJSONObject: landmarkData),
          let landmarkText = String(data: landmarkJSON, encoding: .utf8) else {
        return nil
    }
    return templateHTML.replacingOccurrences(of: "/*CLICKY_LANDMARK_DATA*/", with: "window.__landmark = \(landmarkText);")
}
