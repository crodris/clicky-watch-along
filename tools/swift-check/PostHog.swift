// Stand-in for the PostHog package, so swift-check.sh can build the app's sources without fetching it.
import Foundation

public final class PostHogConfig {
    public init(apiKey: String, host: String) {}
}

public final class PostHogSDK {
    public static let shared = PostHogSDK()
    public func setup(_ config: PostHogConfig) {}
    public func capture(_ event: String, properties: [String: Any]? = nil) {}
    public func identify(_ id: String, userProperties: [String: Any]? = nil) {}
}
