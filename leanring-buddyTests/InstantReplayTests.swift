//
//  InstantReplayTests.swift
//  leanring-buddyTests
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Clicky

@MainActor
private final class RecordingReplayStage {
    var calls: [String] = []
    var reduceMotionIsOn = false
    /// Each sleep waits here until the test lets it go, so a test decides when a dwell ends.
    var pendingSleeps: [CheckedContinuation<Void, Error>] = []
    var labelPointReads = 0
    /// What each flight of the cursor takes, as the app works it out from the theme and the distance.
    var cursorFlightSeconds: TimeInterval = 0.9
    /// How long each sleep was asked to wait, in order.
    var sleepSeconds: [Double] = []
    var lastControlVersion = 0
    /// When true, each label read waits here until the test lets it go, as the page does while the camera turns.
    var holdsLabelReads = false
    var pendingLabelReads: [CheckedContinuation<Void, Never>] = []

    lazy var stage = InstantReplayStage(
        focusStop: { [unowned self] replayStop in self.calls.append("focus \(replayStop.partLabel)") },
        endFocus: { [unowned self] in self.calls.append("endFocus") },
        showStopNumbers: { [unowned self] partLabels, pathReachesStop in
            self.calls.append("numbers \(partLabels.joined(separator: ",")) to \(pathReachesStop)")
        },
        hideStopNumbers: { [unowned self] in self.calls.append("hideNumbers") },
        labelScreenPointOnceTheCameraSettles: { [unowned self] partLabel in
            self.labelPointReads += 1
            if self.holdsLabelReads {
                await withCheckedContinuation { continuation in self.pendingLabelReads.append(continuation) }
            }
            return LiveScenePartScreenPoint(label: partLabel, globalPoint: CGPoint(x: 10, y: 20))
        },
        pointTheCursor: { [unowned self] labelScreenPoint, sentence in
            self.calls.append("point \(labelScreenPoint.label): \(sentence)")
            return self.cursorFlightSeconds
        },
        freezeTheCursor: { [unowned self] in self.calls.append("freeze") },
        releaseTheCursor: { [unowned self] in self.calls.append("release") },
        clearTheFocus: { [unowned self] in self.calls.append("clearFocus") },
        reduceMotionIsOn: { [unowned self] in self.reduceMotionIsOn },
        sleep: { [unowned self] seconds in
            self.sleepSeconds.append(seconds)
            try await withCheckedThrowingContinuation { continuation in self.pendingSleeps.append(continuation) }
        },
        showControl: { [unowned self] controlVersion in
            self.lastControlVersion = controlVersion
            self.calls.append("showControl")
        },
        hideControl: { [unowned self] in self.calls.append("hideControl") }
    )

    func finishTheNextSleep() {
        guard !pendingSleeps.isEmpty else { return }
        pendingSleeps.removeFirst().resume()
    }

    /// A test often ends with a dwell still waiting, such as after End or `forget()`, which cancel the travel but cannot
    /// wake this fake sleep. Each one is resumed here when the test lets the recorder go, so no task stays suspended. It
    /// throws, so the travel returns without touching the stage, whose closures hold this recorder unowned.
    deinit {
        for pendingSleep in pendingSleeps { pendingSleep.resume(throwing: CancellationError()) }
    }
}

private let threeStops = [
    ReplayStop(partLabel: "chain", sentence: "The chain turns the back wheel.", cameraPose: ReplayCameraPose(yaw: 0.6, pitch: 0.18, distance: 900)),
    ReplayStop(partLabel: "saddle", sentence: "You sit here.", cameraPose: ReplayCameraPose(yaw: 0.2, pitch: 0.1, distance: 800)),
    ReplayStop(partLabel: "fork", sentence: "The fork holds the front wheel.", cameraPose: nil),
]

/// Lets the replay's task run until it has nothing left to do but wait.
@MainActor
private func letTheReplayRun() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
struct InstantReplayTests {
    @Test func aPlayThroughVisitsEveryStopInOrderAndEndsAfterTheLast() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        #expect(replay.phase == .playingThrough(stopIndex: 0))
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        // The last dwell ends the replay where the camera settled, and the cursor goes back to the mouse with no freeze.
        #expect(replay.phase == .notOpen)
        #expect(recorder.calls.suffix(3) == ["hideNumbers", "release", "clearFocus"])
        #expect(!recorder.calls.contains("endFocus"))
        let pointedLabels = recorder.calls.filter { $0.hasPrefix("point") }
        #expect(pointedLabels == [
            "point chain: The chain turns the back wheel.",
            "point saddle: You sit here.",
            "point fork: The fork holds the front wheel.",
        ])
        #expect(recorder.calls.contains("numbers chain,saddle,fork to 2"))
    }

    @Test func escapeDuringATravelStopsTheCameraAndTheCursorAndNothingMovesAfterIt() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        #expect(replay.endIfOpen())
        let callsAtTheEnd = recorder.calls
        #expect(callsAtTheEnd.suffix(3) == ["endFocus", "freeze", "hideNumbers"])
        // The dwell the play-through was in ends after Escape, and the old travel must not go on to the next stop.
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        #expect(recorder.calls == callsAtTheEnd)
        #expect(replay.phase == .notOpen)
        // A second Escape finds no replay, so it goes on to the scene.
        #expect(!replay.endIfOpen())
    }

    @Test func aCameraTurnThatEndsAfterEscapePointsTheCursorNowhere() async {
        let recorder = RecordingReplayStage()
        recorder.holdsLabelReads = true
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        replay.endIfOpen()
        // The camera was still turning when Escape came, and its settled label arrives afterward.
        for pendingLabelRead in recorder.pendingLabelReads { pendingLabelRead.resume() }
        await letTheReplayRun()
        #expect(!recorder.calls.contains { $0.hasPrefix("point") })
    }

    @Test func aStepCancelsTheTravelAndStopsAtTheChosenStop() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        replay.step(.next)
        await letTheReplayRun()
        #expect(replay.phase == .stoppedAt(stopIndex: 1))
        // The old dwell ending does nothing, and a stopped replay has no dwell of its own.
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        #expect(replay.phase == .stoppedAt(stopIndex: 1))
        #expect(recorder.calls.last == "point saddle: You sit here.")
        #expect(recorder.pendingSleeps.isEmpty)
        replay.step(.back)
        replay.step(.back)
        await letTheReplayRun()
        #expect(replay.phase == .stoppedAt(stopIndex: 0))
    }

    @Test func aNewReplayDuringADwellIsNotMovedOnByTheOldDwell() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        // Replay again while the first stop's dwell waits: the old dwell ends first, and must not move the new replay on.
        replay.playFromTheStart()
        await letTheReplayRun()
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        #expect(replay.phase == .playingThrough(stopIndex: 0))
        #expect(!recorder.calls.contains("focus saddle"))
    }

    @Test func backAtTheFirstStopLeavesACursorAtRestAlone() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.step(.next)
        await letTheReplayRun()
        #expect(replay.phase == .stoppedAt(stopIndex: 0))
        let callsAtTheFirstStop = recorder.calls
        replay.step(.back)
        await letTheReplayRun()
        #expect(recorder.calls == callsAtTheFirstStop)
    }

    @Test func pushToTalkStopsTheTravelAndKeepsTheReplayOpenAtItsStop() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        replay.stopTheTravelForAPress()
        #expect(replay.phase == .stoppedAt(stopIndex: 0))
        #expect(recorder.calls.last == "endFocus")
        let callsAfterThePress = recorder.calls
        recorder.finishTheNextSleep()
        await letTheReplayRun()
        #expect(recorder.calls == callsAfterThePress)
    }

    @Test func reduceMotionShowsEveryStopAtOnceAndNeverMovesOnByItself() async {
        let recorder = RecordingReplayStage()
        recorder.reduceMotionIsOn = true
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        #expect(replay.showsTheReduceMotionList)
        #expect(replay.phase == .stoppedAt(stopIndex: 0))
        #expect(recorder.calls.contains("numbers chain,saddle,fork to 2"))
        #expect(recorder.pendingSleeps.isEmpty)
    }

    @Test func aClickOnAStopsLabelStepsThereOnlyDuringAReplay() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        // With no replay open, a label click is a question about the part, which the caller answers.
        #expect(!replay.goToStop(partLabel: "fork"))
        replay.playFromTheStart()
        #expect(replay.goToStop(partLabel: "fork"))
        #expect(replay.phase == .stoppedAt(stopIndex: 2))
        #expect(!replay.goToStop(partLabel: "bell"))
        #expect(!replay.goToStop(index: 7))
    }

    @Test func stopsBelongToTheSceneTheyWereRecordedOnAndAClearForgetsThem() {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer([], sceneNumber: 4)
        #expect(!replay.stopsAreRecorded(forSceneNumber: 4))
        #expect(!recorder.calls.contains("showControl"))
        replay.offer(threeStops, sceneNumber: 4)
        #expect(replay.stopsAreRecorded(forSceneNumber: 4))
        #expect(!replay.stopsAreRecorded(forSceneNumber: 5))
        replay.forget()
        #expect(!replay.stopsAreRecorded(forSceneNumber: 4))
        #expect(recorder.calls.last == "hideControl")
    }

    @Test func phaseTransitions() {
        #expect(InstantReplayPhase.notOpen.afterStep(.next, stopCount: 3) == .stoppedAt(stopIndex: 0))
        #expect(InstantReplayPhase.stoppedAt(stopIndex: 2).afterStep(.next, stopCount: 3) == .stoppedAt(stopIndex: 2))
        #expect(InstantReplayPhase.playingThrough(stopIndex: 1).afterStep(.back, stopCount: 3) == .stoppedAt(stopIndex: 0))
        #expect(InstantReplayPhase.stoppedAt(stopIndex: 1).afterStep(.end, stopCount: 3) == .notOpen)
        #expect(InstantReplayPhase.playingThrough(stopIndex: 1).afterTheStopDwelt(stopCount: 3) == .playingThrough(stopIndex: 2))
        #expect(InstantReplayPhase.playingThrough(stopIndex: 2).afterTheStopDwelt(stopCount: 3) == .notOpen)
        #expect(InstantReplayPhase.playingThrough(stopIndex: 1).afterTheTravelStopped == .stoppedAt(stopIndex: 1))
    }

    @Test func underTheSlowestThemeALongFlightStillLeavesTheWholeDwellAtTheStop() async throws {
        // The slowest Point move a theme may set (a response of 0.6) and a flight across a wide screen: the longest one, 1.68 s.
        var slowestSprings = ThemeMoveSprings.standard
        slowestSprings.pointResponse = ThemeMoveSprings.pointResponseLimits.upperBound
        let longestFlightSeconds = replayCursorFlightSeconds(from: .zero, to: CGPoint(x: 2400, y: 0), pointMoveCurve: DS.Move.point.curve(using: slowestSprings))
        #expect(abs(longestFlightSeconds - 1.68) < 0.001)
        let recorder = RecordingReplayStage()
        recorder.cursorFlightSeconds = longestFlightSeconds
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        let firstSleepSeconds = try #require(recorder.sleepSeconds.first)
        // The chain's sentence is six words, so it dwells 1.8 seconds, all of them after the cursor lands.
        let dwellAfterTheLanding = firstSleepSeconds - longestFlightSeconds
        #expect(abs(dwellAfterTheLanding - replayStopDwellSeconds(for: threeStops[0].sentence)) < 0.001)
        #expect(dwellAfterTheLanding >= 1.0)
        _ = replay.endIfOpen()
    }

    @Test func eachStopDwellsTheLargerOfOneAndAHalfSecondsAndAThirdOfASecondAWord() {
        #expect(replayStopDwellSeconds(for: "You sit here.") == 1.5)
        let fifteenWords = Array(repeating: "word", count: 15).joined(separator: " ")
        #expect(abs(replayStopDwellSeconds(for: fifteenWords) - 4.5) < 0.0001)
    }

    @Test func aSentenceAboutAPartThatHasAStopJoinsThatStop() {
        let firstStop = ReplayStop(partLabel: "chain", sentence: "The chain turns.", cameraPose: nil)
        let secondStop = ReplayStop(partLabel: "fork", sentence: "The fork steers.", cameraPose: nil)
        let thirdStop = ReplayStop(partLabel: "chain", sentence: "It needs oil.", cameraPose: nil)
        let stops = replayStops(replayStops(replayStops([], adding: firstStop), adding: secondStop), adding: thirdStop)
        #expect(stops.map(\.partLabel) == ["chain", "fork"])
        #expect(stops[0].sentence == "The chain turns. It needs oil.")
    }

    @Test func onlyTheNewestNarrationOffersItsStops() {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        let tappedAwayNarration = replay.narrationStarted()
        let newestNarration = replay.narrationStarted()
        // The narration a tap cancelled unwinds after the next one started, and must not bring its stops or control back.
        replay.narrationEnded(narrationNumber: tappedAwayNarration, recordedStops: threeStops, sceneNumber: 4, sceneIsStillOnScreen: true)
        #expect(!replay.stopsAreRecorded(forSceneNumber: 4))
        #expect(!recorder.calls.contains("showControl"))
        replay.narrationEnded(narrationNumber: newestNarration, recordedStops: Array(threeStops.prefix(1)), sceneNumber: 4, sceneIsStillOnScreen: true)
        #expect(replay.stops.count == 1)
        #expect(recorder.calls.last == "showControl")
    }

    @Test func aNarrationThatRecordsNothingKeepsTheStopsBeforeIt() {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        let failedNarration = replay.narrationStarted()
        #expect(recorder.calls.last == "hideControl")
        replay.narrationEnded(narrationNumber: failedNarration, recordedStops: [], sceneNumber: 4, sceneIsStillOnScreen: true)
        #expect(replay.stopsAreRecorded(forSceneNumber: 4))
        #expect(recorder.calls.last == "showControl")
        // A narration whose scene left the screen offers nothing.
        let narrationOnAGoneScene = replay.narrationStarted()
        replay.narrationEnded(narrationNumber: narrationOnAGoneScene, recordedStops: threeStops, sceneNumber: 4, sceneIsStillOnScreen: false)
        #expect(recorder.calls.last == "hideControl")
    }

    @Test func aShowThatFinishesAfterALaterHideDrawsNothing() {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        let versionOfTheShow = recorder.lastControlVersion
        #expect(replay.controlShowIsStillWanted(controlVersion: versionOfTheShow))
        // A tap starts the next narration while the show still waits on the page.
        _ = replay.narrationStarted()
        #expect(!replay.controlShowIsStillWanted(controlVersion: versionOfTheShow))
    }

    @Test func aNarrationStartingEndsAnOpenReplay() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        _ = replay.narrationStarted()
        #expect(replay.phase == .notOpen)
        #expect(recorder.calls.suffix(2) == ["hideNumbers", "hideControl"])
    }

    @Test func stoppingTheQuizEndsAnOpenReplayAndTakesTheControlAway() async {
        // The review of PR 88 found that the quiz summary Card showed with the replay control still under the video.
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        replay.endAndForget()
        #expect(recorder.calls.suffix(4) == ["endFocus", "freeze", "hideNumbers", "hideControl"])
        #expect(replay.phase == .notOpen)
        #expect(replay.stops.isEmpty)
    }

    @Test func anotherAnswerStopsAMovingReplayAndLeavesACommandsCameraMoveAlone() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.playFromTheStart()
        await letTheReplayRun()
        // A surface with no press, such as the panel's Hear answer, speaks during a play-through: camera and cursor stop.
        replay.endForAnotherAnswer()
        #expect(recorder.calls.suffix(3) == ["endFocus", "freeze", "hideNumbers"])
        #expect(replay.phase == .notOpen)

        // The same holds at the second stop, whose travel starts inside the first stop's task.
        let atTheSecondStop = RecordingReplayStage()
        let movingOn = InstantReplayController(stage: atTheSecondStop.stage)
        movingOn.offer(threeStops, sceneNumber: 4)
        movingOn.playFromTheStart()
        await letTheReplayRun()
        atTheSecondStop.finishTheNextSleep()
        await letTheReplayRun()
        #expect(movingOn.phase == .playingThrough(stopIndex: 1))
        movingOn.endForAnotherAnswer()
        #expect(atTheSecondStop.calls.suffix(3) == ["endFocus", "freeze", "hideNumbers"])

        // The review of PR 88 found that after a press, a camera command's spoken confirmation stopped the turn it confirmed.
        let afterAPress = RecordingReplayStage()
        let pressedReplay = InstantReplayController(stage: afterAPress.stage)
        pressedReplay.offer(threeStops, sceneNumber: 4)
        pressedReplay.playFromTheStart()
        await letTheReplayRun()
        pressedReplay.stopTheTravelForAPress()
        let callsAfterThePress = afterAPress.calls
        pressedReplay.endForAnotherAnswer()
        #expect(Array(afterAPress.calls.dropFirst(callsAfterThePress.count)) == ["hideNumbers", "release"])
        #expect(pressedReplay.phase == .notOpen)
    }

    @Test func everyLineClickySaysGoesThroughTheOneCallThatEndsAnOpenReplay() throws {
        // The review of PR 88 found surfaces, such as the panel's Hear answer, that spoke with a replay still moving the
        // cursor. Only the wrapper may start a line, so a new surface cannot speak under a replay.
        // tools/swift-check.sh links this file into its package, so the link is resolved to find the repository.
        let repositoryRootURL = URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let companionManagerSource = try String(contentsOf: repositoryRootURL.appendingPathComponent("leanring-buddy/CompanionManager.swift"), encoding: .utf8)
        #expect(companionManagerSource.components(separatedBy: "elevenLabsTTSClient.speakText(").count - 1 == 1)
        // A line whose audio was fetched ahead plays through its own wrapper, which ends an open replay first too.
        #expect(companionManagerSource.components(separatedBy: "elevenLabsTTSClient.play(").count - 1 == 1)
        let playWrapperStart = try #require(companionManagerSource.range(of: "private func playLineEndingAnOpenReplay("))
        let playWrapperSource = companionManagerSource[playWrapperStart.upperBound...]
        let playReplayEnd = try #require(playWrapperSource.range(of: "instantReplay.endForAnotherAnswer()"))
        let playLineStart = try #require(playWrapperSource.range(of: "elevenLabsTTSClient.play(lineFetch)"))
        #expect(playReplayEnd.upperBound <= playLineStart.lowerBound)
        let wrapperStart = try #require(companionManagerSource.range(of: "private func speakTextEndingAnOpenReplay("))
        let wrapperSource = companionManagerSource[wrapperStart.upperBound...]
        let replayEnd = try #require(wrapperSource.range(of: "instantReplay.endForAnotherAnswer()"))
        let lineStart = try #require(wrapperSource.range(of: "elevenLabsTTSClient.speakText(text)"))
        // The replay ends before the line starts, so the camera and the cursor are still before the answer is heard.
        #expect(replayEnd.upperBound <= lineStart.lowerBound)
    }

    @Test func theTranscriptRouteReplaysOnlyWhileStopsAreRecorded() {
        var popOutWithStops = TranscriptRouteContext(
            themeStudioIsOpen: false,
            phaseIsWaitingForAQuizAnswer: false,
            liveSceneIsUpWithNoQuizQuestion: true,
            sceneIsBuilding: false,
            sceneIsOnScreen: true,
            brainTakesEveryRequest: false,
            backgroundSceneIsReady: false,
            taskAnswerIsReady: false,
            approvalIsWaiting: false,
            backgroundAgentIsRunning: false,
            backgroundAgentsArePaused: false,
            replayStopsAreRecorded: true
        )
        #expect(transcriptRoute(for: "show me again", in: popOutWithStops, videoIsInFront: { true }) == .replayTheExplanation)
        // A partial or final transcript that is not the whole phrase goes to the router as before.
        #expect(transcriptRoute(for: "show me the wing again", in: popOutWithStops, videoIsInFront: { true }) == .voiceCommandRouter)
        popOutWithStops.replayStopsAreRecorded = false
        #expect(transcriptRoute(for: "show me again", in: popOutWithStops, videoIsInFront: { true }) == .voiceCommandRouter)
    }

    @Test func showMeAgainRunsAheadOfTheRouterOnlyWhenNothingElseHoldsTheWords() {
        #expect(replayPhraseRunsAheadOfTheRouter(asksToReplay: true, stopsAreRecorded: true, quizQuestionIsOpen: false, themeStudioIsOpen: false))
        #expect(!replayPhraseRunsAheadOfTheRouter(asksToReplay: true, stopsAreRecorded: true, quizQuestionIsOpen: false, themeStudioIsOpen: true))
        #expect(!replayPhraseRunsAheadOfTheRouter(asksToReplay: true, stopsAreRecorded: true, quizQuestionIsOpen: true, themeStudioIsOpen: false))
        #expect(!replayPhraseRunsAheadOfTheRouter(asksToReplay: true, stopsAreRecorded: false, quizQuestionIsOpen: false, themeStudioIsOpen: false))
        #expect(!replayPhraseRunsAheadOfTheRouter(asksToReplay: false, stopsAreRecorded: true, quizQuestionIsOpen: false, themeStudioIsOpen: false))
    }

    @Test func theReplayStopsOnlyACursorItPointedItself() {
        let replayPointingID = UUID()
        #expect(cursorPointsForTheReplay(pointingHold: .untilReleased(byNarrationID: replayPointingID), replayPointingID: replayPointingID))
        #expect(!cursorPointsForTheReplay(pointingHold: .briefly, replayPointingID: replayPointingID))
        #expect(!cursorPointsForTheReplay(pointingHold: .untilReleased(byNarrationID: UUID()), replayPointingID: replayPointingID))
    }

    @Test func noReplayOpenMeansNoCursorOfTheReplaysToFreeze() async {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer(threeStops, sceneNumber: 4)
        replay.forget()
        replay.offer(threeStops, sceneNumber: 5)
        replay.playFromTheStart()
        // Only a replay already open has a travel, and a cursor of its own, to stop.
        #expect(!recorder.calls.contains("freeze"))
        replay.step(.next)
        #expect(recorder.calls.contains("freeze"))
    }

    @Test func showMeAgainReplaysAndAQuestionThatStartsTheSameWayDoesNot() {
        for transcript in ["Show me again.", "hey clicky, show me that again please", "Replay that", "can you replay it?"] {
            #expect(asksToReplayTheExplanation(transcript), "\(transcript)")
        }
        for transcript in ["show me again how the gears turn", "again", "show me the chain", "play the video again", "do that again", "play it again"] {
            #expect(!asksToReplayTheExplanation(transcript), "\(transcript)")
        }
    }

    @Test func theCountReadsStopsBeforeAReplayAndAPlaceDuringOne() {
        #expect(instantReplayCountText(phase: .notOpen, stopCount: 3) == "3 stops")
        #expect(instantReplayCountText(phase: .notOpen, stopCount: 1) == "1 stop")
        #expect(instantReplayCountText(phase: .playingThrough(stopIndex: 1), stopCount: 3) == "2 of 3")
    }

    @Test func aPagePoseParsesOnlyWithThreeFiniteNumbers() {
        #expect(ReplayCameraPose(pageValue: ["yaw": 0.5, "pitch": 0.1, "distance": 700.0]) == ReplayCameraPose(yaw: 0.5, pitch: 0.1, distance: 700))
        #expect(ReplayCameraPose(pageValue: ["yaw": 0.5, "pitch": 0.1]) == nil)
        #expect(ReplayCameraPose(pageValue: ["yaw": Double.nan, "pitch": 0.1, "distance": 700.0]) == nil)
        #expect(ReplayCameraPose(pageValue: nil) == nil)
        #expect(ReplayCameraPose(pageValue: ["yaw": true, "pitch": 0.1, "distance": 700.0]) == nil)
    }

    @Test func aStopNumberClickParsesAtThePageBoundary() {
        #expect(LiveScenePageEvent(messageBody: "stopTapped:2") == .replayStopTapped(untrustedStopIndex: 2))
        #expect(LiveScenePageEvent(messageBody: "stopTapped:-1") == nil)
        #expect(LiveScenePageEvent(messageBody: "stopTapped:two") == nil)
    }

    @Test func theControlSitsUnderTheMediaOrInsideItsBottomEdge() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let cardSize = CGSize(width: 200, height: 36)
        // AppKit's y grows up, so a video near the top leaves room below it.
        let videoNearTheTop = CGRect(x: 200, y: 400, width: 800, height: 450)
        let underTheVideo = instantReplayControlOrigin(cardSize: cardSize, mediaRectOnScreen: videoNearTheTop, visibleFrame: visibleFrame)
        // Centered, with the Card's top 14 points under the video.
        #expect(underTheVideo == CGPoint(x: 500, y: 350))
        let videoAtTheBottom = CGRect(x: 200, y: 0, width: 800, height: 450)
        let insideTheVideo = instantReplayControlOrigin(cardSize: cardSize, mediaRectOnScreen: videoAtTheBottom, visibleFrame: visibleFrame)
        #expect(insideTheVideo.y == 14)
        let videoAtTheRightEdge = CGRect(x: 1300, y: 400, width: 140, height: 200)
        let keptOnScreen = instantReplayControlOrigin(cardSize: cardSize, mediaRectOnScreen: videoAtTheRightEdge, visibleFrame: visibleFrame)
        #expect(keptOnScreen.x + cardSize.width == 1432)
    }

    private func controlView(phase: InstantReplayPhase) -> InstantReplayControlView {
        let stops = ["fan", "vent", "nozzle"].map { partLabel in
            ReplayStop(partLabel: partLabel, sentence: "This is the \(partLabel).", cameraPose: nil)
        }
        return InstantReplayControlView(phase: phase, stops: stops, showsTheReduceMotionList: false, accentHex: "#3380FF", playFromTheStart: {}, step: { _ in })
    }

    @Test(arguments: [InstantReplayPhase.notOpen, .stoppedAt(stopIndex: 1)])
    func theControlsWindowHoldsTheCardsWholeShadow(phase: InstantReplayPhase) throws {
        let renderer = ImageRenderer(content: controlView(phase: phase).background(Color.white))
        renderer.scale = 2
        let pixels = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        if let dumpFolder = ProcessInfo.processInfo.environment["CLICKY_RENDER_DUMP_DIR"],
           let pngData = pixels.representation(using: .png, properties: [:]) {
            try pngData.write(to: URL(fileURLWithPath: dumpFolder).appendingPathComponent("replay-control-\(phase.isOpen ? "open" : "offered").png"))
        }
        // The Card shows, just inside its left edge.
        let cardPixel = try #require(pixels.colorAt(x: Int((AgentListWindowMargins.leading + 2) * 2), y: Int((AgentListWindowMargins.top + 16) * 2)))
        #expect(cardPixel.redComponent < 0.35)
        // Along every edge of the window the shadow has faded to within 7.5% of a white page. The 12 point margin this
        // control had before cut the shadow at 22% under the Card, which showed as a rectangle.
        let middleColumn = pixels.pixelsWide / 2
        let middleRow = Int((AgentListWindowMargins.top + 20) * 2)
        let edgePixels = [
            (middleColumn, 0), (middleColumn, pixels.pixelsHigh - 1), (0, middleRow), (pixels.pixelsWide - 1, middleRow),
        ]
        for (column, row) in edgePixels {
            let edgePixel = try #require(pixels.colorAt(x: column, y: row))
            #expect(edgePixel.redComponent > 0.925, "edge pixel \(column), \(row) is \(edgePixel.redComponent)")
        }
    }

    /// The media and the visible frame sit far off every screen, so no one sees the panel.
    @Test(.showsARealWindow) func aHideDuringTheOpenLeavesNoPanelAndTheNextShowOpensANewOne() async throws {
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        replay.offer([ReplayStop(partLabel: "fan", sentence: "This is the fan.", cameraPose: nil)], sceneNumber: 1)
        let panelController = InstantReplayPanelController()
        let visibleFrame = CGRect(x: -20_000, y: -20_000, width: 1440, height: 900)
        let mediaRectOnScreen = CGRect(x: -19_800, y: -19_600, width: 800, height: 450)
        func showTheControl() {
            panelController.show(for: replay, stopWhatClickyIsSaying: {}, accentHex: "#3380FF", mediaRectOnScreen: mediaRectOnScreen, visibleFrame: visibleFrame)
        }
        showTheControl()
        defer { panelController.hide() }
        let hiddenPanel = try #require(panelController.panel)
        #expect(!NSScreen.screens.contains { screen in screen.frame.intersects(hiddenPanel.frame) })
        // The Card is centered under the media, 14 points down, whatever the window's margins are.
        let cardFrame = AgentListWindowMargins.cardFrame(inWindowFrame: hiddenPanel.frame)
        #expect(abs(cardFrame.midX - mediaRectOnScreen.midX) <= 1)
        #expect(abs(cardFrame.maxY - (mediaRectOnScreen.minY - 14)) <= 1)
        // An open replay adds Back, Next, and End, so the window widens around the same place.
        let widthBeforeTheReplay = hiddenPanel.frame.width
        replay.playFromTheStart()
        let widenDeadline = Date().addingTimeInterval(10)
        while hiddenPanel.frame.width <= widthBeforeTheReplay, Date() < widenDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(hiddenPanel.frame.width > widthBeforeTheReplay)
        // Hidden at once, while it still grows in, in the app's order: the replay forgets its stops and then hides the
        // control. The fading control takes no click and keeps what it showed.
        let fadingView = try #require(hiddenPanel.contentView as? FirstMouseHostingView<InstantReplayControlView>)
        replay.forget()
        panelController.hide()
        #expect(panelController.panel == nil)
        #expect(hiddenPanel.ignoresMouseEvents)
        try await Task.sleep(for: .milliseconds(20))
        #expect(fadingView.rootView.stops.count == 1)
        #expect(fadingView.rootView.phase.isOpen)
        replay.offer([ReplayStop(partLabel: "vent", sentence: "This is the vent.", cameraPose: nil)], sceneNumber: 1)
        showTheControl()
        let shownPanel = try #require(panelController.panel)
        #expect(shownPanel !== hiddenPanel)
        // The first panel's fade ends and takes it off the screen, and the new panel stays.
        let deadline = Date().addingTimeInterval(10)
        while hiddenPanel.isVisible, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!hiddenPanel.isVisible)
        #expect(shownPanel.isVisible)
    }

    /// The pointer a test moves by hand, off every screen like the panel.
    @MainActor
    private final class TestPointer {
        var location = CGPoint(x: -30_000, y: -30_000)
    }

    @MainActor
    private struct OffScreenControl {
        let panelController = InstantReplayPanelController()
        let pointer = TestPointer()
        /// Kept here, since the stage holds its recorder unowned.
        let recorder: RecordingReplayStage
        let replay: InstantReplayController

        init() {
            recorder = RecordingReplayStage()
            replay = InstantReplayController(stage: recorder.stage)
            panelController.mouseLocationOnScreen = { [pointer] in pointer.location }
        }

        func show(accentHex: String = "#3380FF", stopWhatClickyIsSaying: @escaping () -> Void = {}, replayController: InstantReplayController? = nil) {
            panelController.show(
                for: replayController ?? replay,
                stopWhatClickyIsSaying: stopWhatClickyIsSaying,
                accentHex: accentHex,
                mediaRectOnScreen: CGRect(x: -19_800, y: -19_600, width: 800, height: 450),
                visibleFrame: CGRect(x: -20_000, y: -20_000, width: 1440, height: 900)
            )
        }

        /// Where the window will sit, read by showing it with the pointer far away.
        func windowFrame() throws -> CGRect {
            show()
            defer { panelController.hide() }
            return try #require(panelController.panel).frame
        }
    }

    private func inTheCard(of windowFrame: CGRect) -> CGPoint {
        let cardFrame = AgentListWindowMargins.cardFrame(inWindowFrame: windowFrame)
        return CGPoint(x: cardFrame.midX, y: cardFrame.midY)
    }

    private func inTheShadowMargin(of windowFrame: CGRect) -> CGPoint {
        let cardFrame = AgentListWindowMargins.cardFrame(inWindowFrame: windowFrame)
        return CGPoint(x: cardFrame.midX, y: cardFrame.minY - 20)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test(.showsARealWindow) func theWindowTakesTheMouseOverTheCardAndPassesItThroughInTheShadowMargin() async throws {
        let control = OffScreenControl()
        let windowFrame = try control.windowFrame()
        control.pointer.location = inTheCard(of: windowFrame)
        control.show()
        defer { control.panelController.hide() }
        let panel = try #require(control.panelController.panel)
        #expect(!panel.ignoresMouseEvents)
        // The pointer is near the window, so its 60 Hz timer reads it. The test fires that timer itself, since under a full
        // run the main actor can hold a real tick back for seconds.
        let timer = try #require(control.panelController.clickThroughTimer)
        control.pointer.location = inTheShadowMargin(of: windowFrame)
        timer.fire()
        #expect(panel.ignoresMouseEvents)
        control.pointer.location = inTheCard(of: windowFrame)
        timer.fire()
        #expect(!panel.ignoresMouseEvents)
    }

    @Test(.showsARealWindow) func aShowAndAResizeCheckThePointerAtOnce() async throws {
        let control = OffScreenControl()
        let windowFrame = try control.windowFrame()
        control.pointer.location = inTheShadowMargin(of: windowFrame)
        // No wait: a click before the first tick must already reach the page.
        control.show()
        defer { control.panelController.hide() }
        let panel = try #require(control.panelController.panel)
        #expect(panel.ignoresMouseEvents)
        control.panelController.hide()
        // The window an open replay widens to, read with the pointer far away.
        control.pointer.location = CGPoint(x: -30_000, y: -30_000)
        control.replay.offer(threeStops, sceneNumber: 1)
        control.show()
        let offeredPanel = try #require(control.panelController.panel)
        let offeredFrame = offeredPanel.frame
        control.replay.playFromTheStart()
        try await waitUntil { offeredPanel.frame.width > offeredFrame.width }
        let openFrame = offeredPanel.frame
        control.panelController.hide()
        control.replay.step(.end)
        // A point in the open window's margin, too far outside the narrower window for it to read the mouse, so only the
        // resize itself can check the pointer.
        let pointInTheNewMargin = CGPoint(x: openFrame.minX + 4, y: openFrame.midY)
        let pointerNearDistance = ShadowMarginMousePassThrough.pointerNearDistance
        #expect(!offeredFrame.insetBy(dx: -pointerNearDistance, dy: -pointerNearDistance).contains(pointInTheNewMargin))
        control.pointer.location = pointInTheNewMargin
        control.show()
        let resizedPanel = try #require(control.panelController.panel)
        #expect(resizedPanel.frame == offeredFrame)
        #expect(!resizedPanel.ignoresMouseEvents)
        #expect(control.panelController.clickThroughTimer == nil)
        control.replay.playFromTheStart()
        try await waitUntil { resizedPanel.frame.width > offeredFrame.width }
        #expect(resizedPanel.frame == openFrame)
        #expect(resizedPanel.ignoresMouseEvents)
        control.replay.forget()
        withExtendedLifetime(control.recorder) {}
    }

    @Test(.showsARealWindow) func theMouseIsReadOnlyWhileThePointerIsNearTheWindow() async throws {
        let control = OffScreenControl()
        control.show()
        defer { control.panelController.hide() }
        let panel = try #require(control.panelController.panel)
        let entryView = try #require(control.panelController.pointerEntryView)
        #expect(control.panelController.clickThroughTimer == nil)
        #expect(!panel.ignoresMouseEvents)
        func entryTrackingArea() -> NSTrackingArea? {
            entryView.trackingAreas.first { $0.owner === entryView && $0.options.contains(.activeAlways) }
        }
        // The pointer comes back, which the window's tracking area reports.
        control.pointer.location = inTheShadowMargin(of: panel.frame)
        let madeEnterEvent: NSEvent? = NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        )
        let enterEvent = try #require(madeEnterEvent)
        let areaBeforeThePass = try #require(entryTrackingArea())
        // A drag that ends over the margin, such as one that turns the model, must report the entry too.
        #expect(areaBeforeThePass.options.contains(.enabledDuringMouseDrag))
        entryView.mouseEntered(with: enterEvent)
        #expect(panel.ignoresMouseEvents)
        #expect(control.panelController.clickThroughTimer != nil)
        control.pointer.location = CGPoint(x: -30_000, y: -30_000)
        try await waitUntil { control.panelController.clickThroughTimer == nil }
        #expect(control.panelController.clickThroughTimer == nil)
        // Away from the window it takes the mouse again, with a new tracking area that can report the next entry.
        #expect(!panel.ignoresMouseEvents)
        #expect(entryTrackingArea() !== areaBeforeThePass)
        // A pointer on the window's very edge, where the tracking area reports an entry, counts as near.
        control.pointer.location = CGPoint(x: panel.frame.midX, y: panel.frame.maxY)
        entryView.mouseEntered(with: enterEvent)
        #expect(control.panelController.clickThroughTimer != nil)
        control.panelController.hide()
        #expect(control.panelController.clickThroughTimer == nil)
    }

    @Test(.showsARealWindow) func theMouseTimerEndsWhenTheControllerGoesAway() async throws {
        var panelController: InstantReplayPanelController? = InstantReplayPanelController()
        let recorder = RecordingReplayStage()
        let replay = InstantReplayController(stage: recorder.stage)
        func show() {
            panelController?.show(
                for: replay, stopWhatClickyIsSaying: {}, accentHex: "#3380FF",
                mediaRectOnScreen: CGRect(x: -19_800, y: -19_600, width: 800, height: 450),
                visibleFrame: CGRect(x: -20_000, y: -20_000, width: 1440, height: 900)
            )
        }
        panelController?.mouseLocationOnScreen = { CGPoint(x: -30_000, y: -30_000) }
        show()
        let panel = try #require(panelController?.panel)
        // The test releases the controller, so the window is closed directly.
        defer { panel.orderOut(nil) }
        let pointOnTheCard = inTheCard(of: panel.frame)
        panelController?.mouseLocationOnScreen = { pointOnTheCard }
        show()
        let timer = try #require(panelController?.clickThroughTimer)
        // Assigned after the declaration, so the compiler sees a mutation and no `weak let` is needed (Xcode 26.0 and 26.1 lack it).
        weak var releasedController: InstantReplayPanelController?
        releasedController = panelController
        panelController = nil
        try await waitUntil { !timer.isValid }
        #expect(releasedController == nil)
        #expect(!timer.isValid)
    }

    @Test(.showsARealWindow) func aSecondShowTakesTheNewestReplayAccentAndStopClosure() async throws {
        let control = OffScreenControl()
        var firstStopCount = 0
        var secondStopCount = 0
        control.replay.offer(threeStops, sceneNumber: 1)
        control.show(accentHex: "#3380FF", stopWhatClickyIsSaying: { firstStopCount += 1 })
        defer { control.panelController.hide() }
        let panel = try #require(control.panelController.panel)
        let secondRecorder = RecordingReplayStage()
        let secondReplay = InstantReplayController(stage: secondRecorder.stage)
        secondReplay.offer([threeStops[0]], sceneNumber: 2)
        control.show(accentHex: "#FF0000", stopWhatClickyIsSaying: { secondStopCount += 1 }, replayController: secondReplay)
        #expect(control.panelController.panel === panel)
        let hostingView = try #require(panel.contentView as? FirstMouseHostingView<InstantReplayControlView>)
        #expect(hostingView.rootView.accentHex == "#FF0000")
        #expect(hostingView.rootView.stops.count == 1)
        hostingView.rootView.playFromTheStart()
        #expect(secondStopCount == 1)
        #expect(firstStopCount == 0)
        #expect(secondReplay.isOpen)
        #expect(!control.replay.isOpen)
        // The control follows the newest replay's changes.
        try await waitUntil { hostingView.rootView.phase.isOpen }
        #expect(hostingView.rootView.phase.isOpen)
        secondReplay.forget()
        withExtendedLifetime((control.recorder, secondRecorder)) {}
    }

    @Test(.showsARealWindow) func anUpdateQueuedByAnEarlierReplayNeverDrawsOverTheNewestOne() async throws {
        let control = OffScreenControl()
        control.replay.offer(threeStops, sceneNumber: 1)
        control.show(accentHex: "#3380FF")
        defer { control.panelController.hide() }
        let panel = try #require(control.panelController.panel)
        let hostingView = try #require(panel.contentView as? FirstMouseHostingView<InstantReplayControlView>)
        let secondRecorder = RecordingReplayStage()
        let secondReplay = InstantReplayController(stage: secondRecorder.stage)
        secondReplay.offer([threeStops[0]], sceneNumber: 2)
        // The first replay changes, which queues its update, and the second one is shown in the same turn.
        control.replay.offer(Array(threeStops.prefix(2)), sceneNumber: 1)
        control.show(accentHex: "#FF0000", replayController: secondReplay)
        // The main queue runs in order, so the first replay's queued update has run once this block does.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(hostingView.rootView.stops.count == 1)
        withExtendedLifetime((control.recorder, secondRecorder)) {}
    }

    @Test func theReplayToolsAreOfferedOnlyWhileTheyCanWork() {
        var context = AppVoiceTool.Context(
            sceneIsOnScreen: true, sceneHasLabels: true, videoIsInFront: true, videoIsOnYouTube: true,
            videoQuizIsRunning: false, quizQuestionIsOpen: false
        )
        #expect(!AppVoiceTool.available(in: context).contains(.replayExplanation))
        context.replayStopsAreRecorded = true
        #expect(AppVoiceTool.available(in: context).contains(.replayExplanation))
        #expect(!AppVoiceTool.available(in: context).contains(.replayStep))
        context.replayIsOpen = true
        #expect(AppVoiceTool.available(in: context).contains(.replayStep))
        context.quizQuestionIsOpen = true
        #expect(!AppVoiceTool.available(in: context).contains(.replayExplanation))
        #expect(!AppVoiceTool.available(in: context).contains(.replayStep))
    }

    @Test func theReplayStepChipSaysEachStep() {
        let nextCall = VoiceToolCall(id: "1", name: "replay_step", input: ["step": .string("next")])
        let endCall = VoiceToolCall(id: "2", name: "replay_step", input: ["step": .string("end")])
        let unknownCall = VoiceToolCall(id: "3", name: "replay_step", input: ["step": .string("sideways")])
        #expect(nextCall.chipPhrase == "Next stop")
        #expect(endCall.chipPhrase == "Ended the replay")
        #expect(unknownCall.chipPhrase == nil)
    }

    @Test func theSceneStateSaysWhereTheReplayIs() {
        #expect(voiceCommandReplayState(phase: .notOpen, stopCount: 3) == .object(["stops": .number(3), "open": .bool(false)]))
        #expect(voiceCommandReplayState(phase: .stoppedAt(stopIndex: 1), stopCount: 3) == .object(["stops": .number(3), "open": .bool(true), "atStop": .number(2)]))
    }
}
