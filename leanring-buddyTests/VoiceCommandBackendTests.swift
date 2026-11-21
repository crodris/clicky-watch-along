//
//  VoiceCommandBackendTests.swift
//  leanring-buddyTests
//
//  Where a launch's voice commands run: the harness brain, or the old Worker router when no app secret is set or the
//  Worker refused it. The harness half is harness/voiceapproval_test.go's `app secret refused` test.
//

import Foundation
import Testing
@testable import Clicky

struct VoiceCommandBackendTests {
    @Test func withTheFlagOnAndASecretSetCommandsRunInTheHarness() {
        let backend = VoiceCommandBackend(flagIsOn: true, appSecretIsSet: true)
        #expect(backend.runsInTheHarness)
        #expect(backend.noAppSecretLogLine == nil)
    }

    @Test func withNoAppSecretAtLaunchCommandsGoToTheOldPathAndTheLogSaysWhyOnce() {
        let backend = VoiceCommandBackend(flagIsOn: true, appSecretIsSet: false)
        #expect(!backend.runsInTheHarness)
        #expect(backend.noAppSecretLogLine == "Brain: no app secret, so voice commands use the Worker router")
    }

    @Test func withTheFlagOffCommandsGoToTheOldPathWithNoLogLine() {
        let backend = VoiceCommandBackend(flagIsOn: false, appSecretIsSet: true)
        #expect(!backend.runsInTheHarness)
        #expect(backend.noAppSecretLogLine == nil, "a learner who turned the flag off is not told about the secret")
    }

    @Test func aSecretSetInTheDefaultsReadsAsSetAndAnEmptyOrMissingOneDoesNot() throws {
        let defaultsSuiteName = "VoiceCommandBackendTests-" + UUID().uuidString
        let isolatedDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        #expect(!ClickyAppSecret.isSet(in: isolatedDefaults))
        isolatedDefaults.set("", forKey: ClickyAppSecret.defaultsKey)
        #expect(!ClickyAppSecret.isSet(in: isolatedDefaults))
        isolatedDefaults.set("a-secret", forKey: ClickyAppSecret.defaultsKey)
        #expect(ClickyAppSecret.isSet(in: isolatedDefaults))
    }

    /// `verify-clicky.sh app-launch --no-app-secret` and `--wrong-app-secret` pass this argument instead of writing the
    /// defaults, which the everyday Clicky shares.
    @Test func theDebugLaunchArgumentActsAsIfTheSecretWereMissingOrWrongAndNeverWritesTheDefaults() throws {
        let defaultsSuiteName = "VoiceCommandBackendTests-" + UUID().uuidString
        let isolatedDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName) }
        isolatedDefaults.set("the-real-secret", forKey: ClickyAppSecret.defaultsKey)

        let noModeArguments = ["Clicky", "--voice-tool-debug-server"]
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: noModeArguments) == "the-real-secret")

        let noneArguments = ["Clicky", ClickyAppSecret.debugLaunchArgument, "none"]
        let wrongArguments = ["Clicky", ClickyAppSecret.debugLaunchArgument, "wrong"]
        var requestWithNoSecret = URLRequest(url: URL(string: "http://127.0.0.1:8789/v1/messages")!)
        ClickyAppSecret.add(to: &requestWithNoSecret, from: isolatedDefaults, launchArguments: noneArguments)
        var requestWithAWrongSecret = URLRequest(url: URL(string: "http://127.0.0.1:8789/v1/messages")!)
        ClickyAppSecret.add(to: &requestWithAWrongSecret, from: isolatedDefaults, launchArguments: wrongArguments)

        #if DEBUG
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: noneArguments) == nil)
        #expect(!ClickyAppSecret.isSet(in: isolatedDefaults, launchArguments: noneArguments))
        #expect(requestWithNoSecret.value(forHTTPHeaderField: ClickyAppSecret.headerName) == nil)
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: wrongArguments) == ClickyAppSecret.secretTheWorkerRefuses)
        #expect(ClickyAppSecret.isSet(in: isolatedDefaults, launchArguments: wrongArguments))
        #expect(requestWithAWrongSecret.value(forHTTPHeaderField: ClickyAppSecret.headerName) == ClickyAppSecret.secretTheWorkerRefuses)
        // A mode word the app does not know, and a mode argument with no word after it, change nothing.
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: ["Clicky", ClickyAppSecret.debugLaunchArgument, "other"]) == "the-real-secret")
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: ["Clicky", ClickyAppSecret.debugLaunchArgument]) == "the-real-secret")
        #else
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: noneArguments) == "the-real-secret")
        #expect(ClickyAppSecret.current(in: isolatedDefaults, launchArguments: wrongArguments) == "the-real-secret")
        #endif
        #expect(isolatedDefaults.string(forKey: ClickyAppSecret.defaultsKey) == "the-real-secret", "the argument never writes the defaults")
    }

    /// The reason is the one harness/brainloop.go writes (`errAppSecretRefused`), which a harness test pins.
    @Test func aRefusedSecretResendsTheCommandOnceOnTheOldPathAndMovesTheRestOfTheLaunchThere() {
        var backend = VoiceCommandBackend(flagIsOn: true, appSecretIsSet: true)
        #expect(harnessFailureReasonAppSecretRefused == "app secret refused")

        let nextStep = nextStepAfterTheHarnessFailedACommand(reason: "app secret refused", aToolOfTheCommandRan: false, backend: &backend)

        #expect(nextStep == .resendOnTheOldPath, "the old path answers this command, and the keyword path does not")
        #expect(!backend.runsInTheHarness, "later commands of this launch go to the old path")
    }

    @Test func aRefusedSecretAfterAToolRanDoesNotResendTheCommandButStillMovesTheLaunchToTheOldPath() {
        var backend = VoiceCommandBackend(flagIsOn: true, appSecretIsSet: true)

        let nextStep = nextStepAfterTheHarnessFailedACommand(reason: "app secret refused", aToolOfTheCommandRan: true, backend: &backend)

        #expect(nextStep == .routerFailureFallback, "the old path would repeat what the tool already changed")
        #expect(!backend.runsInTheHarness)
    }

    @Test func anyOtherHarnessFailureTakesTheRouterFailureFallbackAndKeepsTheHarness() {
        var backend = VoiceCommandBackend(flagIsOn: true, appSecretIsSet: true)

        for reason in ["turn 1 got no reply from Claude within 8s", "the request to Claude failed: 401 Unauthorized", "the agent harness sent nothing in time"] {
            #expect(nextStepAfterTheHarnessFailedACommand(reason: reason, aToolOfTheCommandRan: false, backend: &backend) == .routerFailureFallback)
        }
        #expect(backend.runsInTheHarness)
    }
}
