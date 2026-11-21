//
//  InstantReplayTests.swift
//  leanring-buddyTests
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
private final class RecordingReplayStage {
    var calls: [String] = []
    var reduceMotionIsOn = false
    /// Each sleep waits here until the test lets it go, so a test decides when a dwell ends.
    var pendingSleeps: [CheckedContinuation<Void, Error>] = []
    var labelPointReads = 0
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
        },
        freezeTheCursor: { [unowned self] in self.calls.append("freeze") },
        releaseTheCursor: { [unowned self] in self.calls.append("release") },
        clearTheFocus: { [unowned self] in self.calls.append("clearFocus") },
        reduceMotionIsOn: { [unowned self] in self.reduceMotionIsOn },
        sleep: { [unowned self] _ in
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
        let windowSize = CGSize(width: 224, height: 60)
        // AppKit's y grows up, so a video near the top leaves room below it.
        let videoNearTheTop = CGRect(x: 200, y: 400, width: 800, height: 450)
        let underTheVideo = instantReplayControlOrigin(windowSize: windowSize, shadowMargin: 12, mediaRectOnScreen: videoNearTheTop, visibleFrame: visibleFrame)
        #expect(abs(underTheVideo.x - 488) < 0.001)
        // The Card's top, 12 points under the window's top, is 14 points under the video.
        #expect(abs(underTheVideo.y + windowSize.height - 12 - 386) < 0.001)
        let videoAtTheBottom = CGRect(x: 200, y: 0, width: 800, height: 450)
        let insideTheVideo = instantReplayControlOrigin(windowSize: windowSize, shadowMargin: 12, mediaRectOnScreen: videoAtTheBottom, visibleFrame: visibleFrame)
        #expect(abs(insideTheVideo.y + 12 - 14) < 0.001)
        let videoAtTheRightEdge = CGRect(x: 1300, y: 400, width: 140, height: 200)
        let keptOnScreen = instantReplayControlOrigin(windowSize: windowSize, shadowMargin: 12, mediaRectOnScreen: videoAtTheRightEdge, visibleFrame: visibleFrame)
        #expect(abs(keptOnScreen.x + windowSize.width - 12 - 1432) < 0.001)
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
