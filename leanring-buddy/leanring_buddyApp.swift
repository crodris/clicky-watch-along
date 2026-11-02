//
//  leanring_buddyApp.swift
//  leanring-buddy
//
//  Menu bar-only companion app. No dock icon, no main window — just an
//  always-available status item in the macOS menu bar. Clicking the icon
//  opens a floating panel with companion voice controls.
//

import ServiceManagement
import SwiftUI
import Sparkle

@main
struct leanring_buddyApp: App {
    @NSApplicationDelegateAdaptor(CompanionAppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar panel managed by the AppDelegate.
        // This empty Settings scene satisfies SwiftUI's requirement for at least
        // one scene but is never shown (LSUIElement=true removes the app menu).
        Settings {
            EmptyView()
        }
    }
}

/// Manages the companion lifecycle: creates the menu bar panel and starts
/// the companion voice pipeline on launch.
@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarPanelManager: MenuBarPanelManager?
    private let companionManager = CompanionManager()
    private var sparkleUpdaterController: SPUStandardUpdaterController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Field-trip preview. Skip menu bar, analytics, and login item setup.
        if ProcessInfo.processInfo.arguments.contains("--field-trip-spec") {
            playFieldTripSpecFromLaunchArguments()
            return
        }

        print("🎯 Clicky: Starting...")
        print("🎯 Clicky: Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")")

        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 0])

        // The fork leaves analytics unconfigured so transcripts and replies
        // never reach the upstream PostHog project. Capture calls do nothing.

        menuBarPanelManager = MenuBarPanelManager(companionManager: companionManager)
        companionManager.start()
        // Auto-open the panel if the user still needs to do something:
        // either they haven't onboarded yet, or permissions were revoked.
        if !companionManager.hasCompletedOnboarding || !companionManager.allPermissionsGranted {
            menuBarPanelManager?.showPanelOnLaunch()
        }
        registerAsLoginItemIfNeeded()
        // startSparkleUpdater()
        #if DEBUG
        let launchArguments = ProcessInfo.processInfo.arguments
        if let flagIndex = launchArguments.firstIndex(of: "--field-trip-rehearsal"),
           flagIndex + 1 < launchArguments.count {
            let transcripts = launchArguments[flagIndex + 1].components(separatedBy: "|")
            let companionManager = companionManager
            Task { await companionManager.runFieldTripRehearsal(transcripts: transcripts) }
        }
        #endif
    }

    /// `--field-trip-spec <path>` reads that JSON file and plays it in the overlay.
    /// A missing path still returns early so the menu bar app does not start.
    private func playFieldTripSpecFromLaunchArguments() {
        let launchArguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = launchArguments.firstIndex(of: "--field-trip-spec") else {
            return
        }
        let specPathIndex = launchArguments.index(after: flagIndex)
        guard specPathIndex < launchArguments.endIndex else {
            print("Field trip: --field-trip-spec needs a JSON file path")
            return
        }
        let specFilePath = launchArguments[specPathIndex]
        let specFileURL = URL(fileURLWithPath: specFilePath)
        do {
            var specJSONText = try String(contentsOf: specFileURL, encoding: .utf8)
            if specJSONText.hasPrefix("\u{feff}") {
                specJSONText.removeFirst()
            }
            FieldTripOverlay.shared.play(specJSONData: Data(specJSONText.utf8))
        } catch {
            print("Field trip: could not read spec at \(specFilePath): \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        companionManager.stop()
    }

    /// Registers the app as a login item so it launches automatically on
    /// startup. Uses SMAppService which shows the app in System Settings >
    /// General > Login Items, letting the user toggle it off if they want.
    private func registerAsLoginItemIfNeeded() {
        let loginItemService = SMAppService.mainApp
        if loginItemService.status != .enabled {
            do {
                try loginItemService.register()
                print("🎯 Clicky: Registered as login item")
            } catch {
                print("⚠️ Clicky: Failed to register as login item: \(error)")
            }
        }
    }

    private func startSparkleUpdater() {
        let updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.sparkleUpdaterController = updaterController

        do {
            try updaterController.updater.start()
        } catch {
            print("⚠️ Clicky: Sparkle updater failed to start: \(error)")
        }
    }
}
