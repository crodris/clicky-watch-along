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

/// The secret the Worker's Notion routes require in x-clicky-app-secret. It is read from this app's defaults, so it
/// never sits in git or in the built app. `verify-clicky.sh app-launch` copies it there from worker/.dev.vars, and
/// `defaults write com.crodris.clicky-watch-along clickyAppSecret <secret>` sets it by hand.
enum ClickyAppSecret {
    static let headerName = "x-clicky-app-secret"
    static let defaultsKey = "clickyAppSecret"

    /// A request with no secret set goes out without the header, and the Worker answers it with 401.
    static func add(to request: inout URLRequest) {
        guard let secret = UserDefaults.standard.string(forKey: defaultsKey), !secret.isEmpty else { return }
        request.setValue(secret, forHTTPHeaderField: headerName)
    }
}
