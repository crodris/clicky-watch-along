//
//  LiveSceneTourEndTests.swift
//  leanring-buddyTests
//
//  When a scene's camera tour ends: when its page reports it, or at the deadline when a generated page never does,
//  so Clicky never waits forever to narrate a scene or ask its quiz question (`LiveSceneTourEnd`).
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct LiveSceneTourEndTests {
    @Test func aPageThatReportsTwiceEndsItsTourOnce() {
        var tourEnd = LiveSceneTourEnd()
        tourEnd.pageStarted(sceneNumber: 1)
        let firstReportEndedTheTour = tourEnd.pageReportedTheTourFinished()
        #expect(firstReportEndedTheTour)
        let secondReportEndedTheTour = tourEnd.pageReportedTheTourFinished()
        #expect(!secondReportEndedTheTour)
        let deadlineAfterTheReportEndedTheTour = tourEnd.deadlinePassed(forSceneNumber: 1)
        #expect(!deadlineAfterTheReportEndedTheTour)
    }

    @Test func theDeadlineEndsATourThePageNeverEnded() {
        var tourEnd = LiveSceneTourEnd()
        tourEnd.pageStarted(sceneNumber: 1)
        let deadlineEndedTheTour = tourEnd.deadlinePassed(forSceneNumber: 1)
        #expect(deadlineEndedTheTour)
        // The page's own endTour, which the deadline runs, posts tourFinished, and that must not end the tour again.
        let reportAfterTheDeadlineEndedTheTour = tourEnd.pageReportedTheTourFinished()
        #expect(!reportAfterTheDeadlineEndedTheTour)
    }

    @Test func anEarlierScenesDeadlineLeavesTheNewerScenesTourOpen() {
        var tourEnd = LiveSceneTourEnd()
        tourEnd.pageStarted(sceneNumber: 1)
        tourEnd.pageStarted(sceneNumber: 2)
        let firstScenesDeadlineEndedATour = tourEnd.deadlinePassed(forSceneNumber: 1)
        #expect(!firstScenesDeadlineEndedATour)
        let secondScenesDeadlineEndedItsTour = tourEnd.deadlinePassed(forSceneNumber: 2)
        #expect(secondScenesDeadlineEndedItsTour)
    }

    @Test func aClearedScenesDeadlineEndsNothing() {
        var tourEnd = LiveSceneTourEnd()
        tourEnd.pageStarted(sceneNumber: 1)
        tourEnd.sceneCleared()
        let deadlineAfterTheClearEndedTheTour = tourEnd.deadlinePassed(forSceneNumber: 1)
        #expect(!deadlineAfterTheClearEndedTheTour)
        let reportAfterTheClearEndedTheTour = tourEnd.pageReportedTheTourFinished()
        #expect(!reportAfterTheClearEndedTheTour)
    }
}
