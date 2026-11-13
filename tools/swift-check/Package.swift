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

let package = Package(
    name: "ClickySwiftCheck",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "PostHog", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "Sparkle", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "Clicky", dependencies: ["PostHog", "Sparkle"], swiftSettings: appTargetSettings),
        .testTarget(name: "ClickyTests", dependencies: ["Clicky"], swiftSettings: appTargetSettings),
    ]
)
