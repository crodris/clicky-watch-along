//
//  SceneResumeTests.swift
//  leanring-buddyTests
//
//  When a video Clicky paused for a scene that failed, was cancelled, or cleared may play again.
//

import Testing
@testable import Clicky

struct SceneResumeTests {
    @Test func theVideoPlaysAgainOnlyWhileNoSceneIsBuildingOrOnScreen() {
        #expect(aSceneThatEndedMayResumeItsVideo(liveScenePhase: .idle))
        // A scene or pop-out asked for during the failure line or the return holds the pause for itself.
        #expect(!aSceneThatEndedMayResumeItsVideo(liveScenePhase: .buildingScene))
        #expect(!aSceneThatEndedMayResumeItsVideo(liveScenePhase: .touring(quizToAskAfterTour: nil)))
        #expect(!aSceneThatEndedMayResumeItsVideo(liveScenePhase: .allLabelsShowing))
    }
}
