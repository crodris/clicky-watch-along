//
//  AppBundleConfiguration.swift
//  leanring-buddy
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

/// The secret the Worker's gated routes require in x-clicky-app-secret: the Notion routes, /try-it-item and /room-wall, which
/// the room art panel uses, and /v1/messages, which the task agents and the voice command brain in the harness use. It
/// is a setup requirement: with none set, voice commands take the router failure fallback and the gated routes answer 401.
/// It is read from this app's defaults, so it never sits in git or in the built app. `verify-clicky.sh app-launch` copies
/// it there from worker/.dev.vars, and `defaults write com.crodris.clicky-watch-along clickyAppSecret <secret>` sets it by hand.
enum ClickyAppSecret {
    static let headerName = "x-clicky-app-secret"
    static let defaultsKey = "clickyAppSecret"

    /// The secret to send, or nil when none is set. Every reader goes through here, so the Worker requests and the
    /// harness's environment always agree.
    static func current(in userDefaults: UserDefaults = .standard) -> String? {
        let savedSecret = userDefaults.string(forKey: defaultsKey) ?? ""
        return savedSecret.isEmpty ? nil : savedSecret
    }

    /// Whether a secret is set, which the voice command brain needs.
    static func isSet(in userDefaults: UserDefaults = .standard) -> Bool {
        current(in: userDefaults) != nil
    }

    /// A request with no secret set goes out without the header, and the Worker answers it with 401. Tests pass their
    /// own defaults, since the hosted tests share Clicky.app's defaults, which hold the real secret.
    static func add(to request: inout URLRequest, from userDefaults: UserDefaults = .standard) {
        guard let secret = current(in: userDefaults) else { return }
        request.setValue(secret, forHTTPHeaderField: headerName)
    }
}

/// Builds and sends a JSON POST to a Worker route and returns the whole reply. Other Worker requests, such as the
/// streamed /chat and /tts ones that read the reply as it arrives, build their own. Each caller keeps its own session, timeout, and error type,
/// since what a non-200 reply means differs per route.
enum WorkerJSONPost {
    /// `timeoutInterval` nil keeps URLRequest's own default. `sendsAppSecret` is true only for the routes that need
    /// x-clicky-app-secret.
    static func makeRequest(
        to url: URL,
        body: Data,
        timeoutInterval: TimeInterval? = nil,
        sendsAppSecret: Bool,
        appSecretDefaults: UserDefaults = .standard
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if sendsAppSecret {
            ClickyAppSecret.add(to: &request, from: appSecretDefaults)
        }
        if let timeoutInterval {
            request.timeoutInterval = timeoutInterval
        }
        request.httpBody = body
        return request
    }

    /// The status code is -1 when the reply is not an HTTP reply, so callers branch on the code alone.
    static func send(
        _ body: Data,
        to url: URL,
        using session: URLSession,
        timeoutInterval: TimeInterval? = nil,
        sendsAppSecret: Bool
    ) async throws -> (responseData: Data, statusCode: Int) {
        let request = makeRequest(to: url, body: body, timeoutInterval: timeoutInterval, sendsAppSecret: sendsAppSecret)
        let (responseData, response) = try await session.data(for: request)
        // URLSession returns URLResponse. The Worker answers over HTTP.
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (responseData, statusCode)
    }
}
