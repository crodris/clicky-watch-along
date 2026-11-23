//
//  DebugPaintingSaveTests.swift
//  leanring-buddyTests
//
//  Pins that only the running Debug app saves its furniture paintings, never a test run.
//

import Testing
@testable import Clicky

struct DebugPaintingSaveTests {
    @Test func onlyTheAppItselfKeepsItsPaintings() {
        #expect(debugAppKeepsItsPaintings(bundleIdentifier: "com.crodris.clicky-watch-along", environment: [:]))
        // Xcode's test host is Clicky.app with the test configuration in its environment.
        #expect(!debugAppKeepsItsPaintings(
            bundleIdentifier: "com.crodris.clicky-watch-along",
            environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        ))
        // tools/swift-check.sh runs the tests in a runner with its own bundle ID, or none.
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: "com.apple.dt.xctest.tool", environment: [:]))
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: nil, environment: [:]))
    }
}
