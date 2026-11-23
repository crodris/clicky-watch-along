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
        let app = "com.crodris.clicky-watch-along"
        #expect(debugAppKeepsItsPaintings(bundleIdentifier: app, environment: [:], xcTestIsLoaded: false))
        // Xcode's test host is Clicky.app with the test configuration or the test bundle in its environment.
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: app, environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"], xcTestIsLoaded: false))
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: app, environment: ["XCTestBundlePath": "/tmp/leanring-buddyTests.xctest"], xcTestIsLoaded: false))
        // A host with XCTest loaded is a test run whatever its environment says.
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: app, environment: [:], xcTestIsLoaded: true))
        // tools/swift-check.sh runs the tests in a runner with its own bundle ID, or none.
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: "com.apple.dt.xctest.tool", environment: [:], xcTestIsLoaded: false))
        #expect(!debugAppKeepsItsPaintings(bundleIdentifier: nil, environment: [:], xcTestIsLoaded: false))
    }
}
