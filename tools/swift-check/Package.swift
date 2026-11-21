// swift-tools-version: 6.2
// Mirrors the leanring-buddy target's Swift settings in leanring-buddy.xcodeproj. Change both together.
import PackageDescription

let appTargetSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .define("DEBUG"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The Xcode test target sets no default isolation, so a test that calls main actor code must say `@MainActor` itself.
// The tests here compile the same way, or a test that passes here would fail to compile in CI.
let testTargetSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .define("DEBUG"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "ClickySwiftCheck",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "Clicky", swiftSettings: appTargetSettings),
        .testTarget(name: "ClickyTests", dependencies: ["Clicky"], swiftSettings: testTargetSettings),
    ]
)
