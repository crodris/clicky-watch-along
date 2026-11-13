// Stand-in for the Sparkle package, so swift-check.sh can build the app's sources without fetching it.
import Foundation

public final class SPUStandardUpdaterController {
    public init(startingUpdater: Bool, updaterDelegate: Any?, userDriverDelegate: Any?) {}
    public var updater: SPUUpdater { SPUUpdater() }
}

public final class SPUUpdater {
    public func start() throws {}
}
