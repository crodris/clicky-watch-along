//
//  SceneNumberTests.swift
//  leanring-buddyTests
//
//  The scene state's `sceneNumber`, which the harness brain's undo record reads to tell one scene from the next
//  (harness/brainundo.go, `sceneIdentity`).
//

import Foundation
import Testing
@testable import Clicky

struct SceneNumberTests {
    @Test func aShowingSceneIsNamedByHowManyScenesHavePlayed() {
        #expect(sceneNumberForTheSceneState(sceneIsOnScreen: true, scenesPlayedCount: 3) == .number(3))
    }

    @Test func aNewSceneOfTheSameKindGetsADifferentNumber() {
        let firstPopout = sceneNumberForTheSceneState(sceneIsOnScreen: true, scenesPlayedCount: 3)
        let secondPopout = sceneNumberForTheSceneState(sceneIsOnScreen: true, scenesPlayedCount: 4)
        #expect(firstPopout != secondPopout)
    }

    @Test func withNoSceneOnScreenThereIsNoNumber() {
        #expect(sceneNumberForTheSceneState(sceneIsOnScreen: false, scenesPlayedCount: 3) == nil)
    }
}
