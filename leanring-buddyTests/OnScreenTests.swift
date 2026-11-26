//
//  OnScreenTests.swift
//  leanring-buddyTests
//
//  The gate for tests that put a real window on screen.
//

import AppKit
import Testing

/// Whether a test that shows a real window may run: only with `CLICKY_TESTS_MAY_SHOW_WINDOWS=1` and a screen to show it on.
func realWindowTestsMayRun(environment: [String: String], screenCount: Int) -> Bool {
    environment["CLICKY_TESTS_MAY_SHOW_WINDOWS"] == "1" && screenCount > 0
}

/// A test that shows one of Clicky's real panels, such as the Theme Studio card or the agent list, draws it on the screen of
/// whoever runs the test. On the developer's Mac that is the desktop they work on.
/// `tools/swift-check.sh` runs from agent sessions too, and on 2026-11-25 one put the card there with no warning.
/// So these tests run only where no one is looking: CI sets `CLICKY_TESTS_MAY_SHOW_WINDOWS=1` for the test host
/// (`TEST_RUNNER_CLICKY_TESTS_MAY_SHOW_WINDOWS` in `ci.yml`). Set it yourself to run them on your own screen.
extension Trait where Self == ConditionTrait {
    static var showsARealWindow: Self {
        .enabled(
            if: realWindowTestsMayRun(environment: ProcessInfo.processInfo.environment, screenCount: NSScreen.screens.count),
            "it shows a real window, so it runs only with CLICKY_TESTS_MAY_SHOW_WINDOWS=1 and a screen"
        )
    }
}

struct OnScreenTests {
    @Test func aRealWindowTestRunsOnlyWithTheSwitchSetAndAScreen() {
        #expect(realWindowTestsMayRun(environment: ["CLICKY_TESTS_MAY_SHOW_WINDOWS": "1"], screenCount: 1))
        #expect(!realWindowTestsMayRun(environment: [:], screenCount: 1))
        #expect(!realWindowTestsMayRun(environment: ["CLICKY_TESTS_MAY_SHOW_WINDOWS": "0"], screenCount: 1))
        #expect(!realWindowTestsMayRun(environment: ["CLICKY_TESTS_MAY_SHOW_WINDOWS": "1"], screenCount: 0))
    }

    /// A skipped test passes, so without this check CI would stay green if the variable stopped reaching the test host.
    /// CI builds the app with a `.ci-<runner>` bundle ID suffix, and no local run has one.
    @Test(.enabled(if: Bundle.main.bundleIdentifier?.contains(".ci-") == true, "only CI's test host must run the real-window tests"))
    func ciRunsTheTestsThatShowARealWindow() {
        #expect(
            realWindowTestsMayRun(environment: ProcessInfo.processInfo.environment, screenCount: NSScreen.screens.count),
            "CI's test host would skip the real-window tests: CLICKY_TESTS_MAY_SHOW_WINDOWS must reach it as 1, and it needs a screen"
        )
    }
}
