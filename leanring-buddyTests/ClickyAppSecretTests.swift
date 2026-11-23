//
//  ClickyAppSecretTests.swift
//  leanring-buddyTests
//
//  The app secret is a setup requirement: the voice command brain in the harness and the gated Worker routes need it.
//  `ClickyAppSecret.isSet` reads it from the defaults, and an empty value counts as not set.
//

import Foundation
import Testing
@testable import Clicky

struct ClickyAppSecretTests {
    @Test func aSecretSetInTheDefaultsReadsAsSetAndAnEmptyOrMissingOneDoesNot() throws {
        let defaultsSuiteName = "ClickyAppSecretTests-" + UUID().uuidString
        let isolatedDefaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defer { isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName) }

        #expect(!ClickyAppSecret.isSet(in: isolatedDefaults))
        isolatedDefaults.set("", forKey: ClickyAppSecret.defaultsKey)
        #expect(!ClickyAppSecret.isSet(in: isolatedDefaults))
        isolatedDefaults.set("a-secret", forKey: ClickyAppSecret.defaultsKey)
        #expect(ClickyAppSecret.isSet(in: isolatedDefaults))
    }
}
