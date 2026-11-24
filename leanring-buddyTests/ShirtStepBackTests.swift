//
//  ShirtStepBackTests.swift
//  leanring-buddyTests
//
//  The step-back countdown of the shirt try-on's painted still: the capture's hold, countdown, and time out stepped by hand
//  with an injected clock, and the phase transitions around it. No test sleeps.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

/// A torso whose shoulders are 100 pixels apart, centered at `centerX`, with hips well below.
private func torso(centerX: Double = 320, centerY: Double = 150, shoulderWidth: Double = 100) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: CGPoint(x: centerX - shoulderWidth / 2, y: centerY), imageRightShoulder: CGPoint(x: centerX + shoulderWidth / 2, y: centerY),
        imageLeftHip: CGPoint(x: centerX - shoulderWidth * 0.4, y: centerY + 145), imageRightHip: CGPoint(x: centerX + shoulderWidth * 0.4, y: centerY + 145),
        hipsWereEstimated: false, shouldersAreSeen: true
    )
}

struct ShirtStepBackCaptureTests {
    private func capture(armedAt: TimeInterval = 0) -> ShirtStepBackCapture { ShirtStepBackCapture(armedAt: armedAt) }

    @Test func theCountdownRunsThreeTwoOneAndFreezesAfterTheWholeHold() {
        var capture = capture()
        // The learner settles for half a second with no number on screen, then the countdown shows.
        #expect(ShirtStepBackCapture.secondsToSettleBeforeTheCountdown == 0.5)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.0) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.49) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.5) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.9) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.0) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.4) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.5) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.99) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.0) == .freezeNow)
    }

    /// The numbers a learner would see on the panel, one frame every 1/30 s from `start` to `end`, with each run of the
    /// same number shown once and a frame with no number left out, until the frame freezes.
    private func numbersShown(from start: TimeInterval, to end: TimeInterval, torsoAt: (TimeInterval) -> BodyTorso) -> (numbers: [Int], froze: Bool) {
        var capture = capture()
        var numbers: [Int] = []
        for frameNumber in 0...Int(((end - start) * 30).rounded()) {
            let time = start + Double(frameNumber) / 30
            switch capture.advance(framingKind: .ready, torso: torsoAt(time), at: time) {
            case .counting(let number): if numbers.last != number { numbers.append(number) }
            case .freezeNow: return (numbers, true)
            case .keepWaiting, .giveUp: break
            }
        }
        return (numbers, false)
    }

    @Test func aLearnerStillSettlingAfterTheStepBackSeesOneCountdownThatNeverStartsOver() {
        // Chris's dry run showed 3, 2, then 3, 2, 1. The framing reads ready while the learner is still settling from the
        // step back: here the shoulders drift 8 pixels (0.08 shoulder widths) and slow down over about a second.
        let shown = numbersShown(from: 1.0, to: 6.0) { time in torso(centerX: 320 + 8 * (1 - exp(-(time - 1.0)))) }
        #expect(shown.froze)
        #expect(shown.numbers == [3, 2, 1], "the countdown started over: \(shown.numbers)")
    }

    @Test func aSmallSwayDuringTheCountdownDoesNotStartItOver() {
        // A learner holding still sways and breathes: once the countdown shows, the shoulders swaying 6 pixels (0.06 shoulder
        // widths) back and forth keep it going.
        let shown = numbersShown(from: 1.0, to: 6.0) { time in
            let secondsIntoTheCountdown = time - 1.0 - ShirtStepBackCapture.secondsToSettleBeforeTheCountdown
            return torso(centerX: secondsIntoTheCountdown > 0 ? 320 + 6 * sin(secondsIntoTheCountdown * 4) : 320)
        }
        #expect(shown.froze)
        #expect(shown.numbers == [3, 2, 1], "the countdown started over: \(shown.numbers)")
    }

    @Test func realPoseJitterOfALearnerStandingStillGivesOneCountdown() {
        // Vision's body pose results for the standing photo held still under sensor noise, before its sway starts at 2.5 s
        // (`fastSwayPoseRuns`, one run every 1/15 s), with the run's own time as the frame time.
        var capture = capture(armedAt: -1)
        var numbers: [Int] = []
        var froze = false
        for run in fastSwayPoseRuns where run.time < 2.5 && !froze {
            switch capture.advance(framingKind: .ready, torso: run.torso, at: run.time) {
            case .counting(let number): if numbers.last != number { numbers.append(number) }
            case .freezeNow: froze = true
            case .keepWaiting, .giveUp: break
            }
        }
        #expect(froze)
        #expect(numbers == [3, 2, 1], "the countdown started over: \(numbers)")
    }

    @Test func theHoldIsOneAndAHalfSecondsWithHalfASecondPerNumber() {
        #expect(ShirtStepBackCapture.secondsToHoldStill == 1.5 && ShirtStepBackCapture.countdownNumbers == 3)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0) == 3)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0.49) == 3)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0.5) == 2)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 1.0) == 1)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 5) == 1)
    }

    @Test func noHoldStartsInTheFirstThreeQuartersOfASecondAfterArming() {
        var capture = capture(armedAt: 5)
        #expect(ShirtStepBackCapture.secondsBeforeAHoldMayStart == 0.75)
        // A learner already in the ready framing at the keyboard does not start a hold while Clicky still says to step back.
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 5.0) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 5.74) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 5.75) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 6.25) == .counting(number: 3))
        // The countdown counts from the frame it started on, not from the arming.
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 7.75) == .freezeNow)
    }

    @Test func leavingTheReadyFramingRestartsTheHold() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.5) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.0) == .counting(number: 2))
        // A learner who leans in again is judged too close, whatever the torso says.
        #expect(capture.advance(framingKind: .standBack, torso: torso(), at: 2.1) == .keepWaiting)
        #expect(capture.advance(framingKind: .noPerson, torso: nil, at: 2.2) == .keepWaiting)
        #expect(capture.advance(framingKind: nil, torso: torso(), at: 2.3) == .keepWaiting)
        // Back in the ready framing, the learner settles again with no number, and the countdown needs its whole 1.5 seconds.
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.5) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.0) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 4.4) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 4.5) == .freezeNow)
    }

    @Test func aTorsoWithNoTorsoInTheReadyFramingNeverCounts() {
        var capture = capture()
        #expect(capture.advance(framingKind: .ready, torso: nil, at: 1) == .keepWaiting)
    }

    @Test func shouldersOnTopOfEachOtherNeverStartAHold() {
        var capture = capture()
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 0), at: 1) == .keepWaiting)
    }

    @Test func movingTheShouldersWhileSettlingStartsTheSettleOverFromWhereTheyAreNow() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.0)
        // 3 pixels is 0.03 shoulder widths, inside the 0.04 settle limit.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 323), at: 1.25) == .keepWaiting)
        // 5 pixels is 0.05 shoulder widths, past it: the settle starts over at the new place, still with no number.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 325), at: 1.4) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 325), at: 1.89) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 325), at: 1.9) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 325), at: 3.4) == .freezeNow)
    }

    @Test func movingUpAndDownWhileSettlingStartsTheSettleOverToo() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerY: 150), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerY: 155), at: 1.2) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerY: 155), at: 1.5) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerY: 155), at: 1.7) == .counting(number: 3))
    }

    @Test func aChangeOfShoulderWidthWhileSettlingStartsTheSettleOverAsTheLearnerSteppingBackDoes() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 100), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 103), at: 1.3) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 95), at: 1.4) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 95), at: 1.8) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 95), at: 1.9) == .counting(number: 3))
    }

    @Test func slowDriftWhileSettlingIsMeasuredFromTheStartOfTheSettleNotFromTheLastFrame() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.0)
        // Each step is 1.5 pixels, under the limit from the frame before, but 4.5 pixels from the start is over it.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 321.5), at: 1.1) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 323), at: 1.2) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 324.5), at: 1.3) == .keepWaiting)
        // The settle started over at 1.3, so half a second from the first frame is not enough.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 324.5), at: 1.5) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 324.5), at: 1.8) == .counting(number: 3))
    }

    @Test func aRealMoveDuringTheCountdownStopsItAndTheNumberGoesUntilTheLearnerSettlesAgain() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.5) == .counting(number: 3))
        // 9 pixels is 0.09 shoulder widths from where the countdown began, inside its 0.1 limit.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 329), at: 2.0) == .counting(number: 2))
        // 11 pixels is past it: the countdown stops with no number, and the settle starts over.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 331), at: 2.1) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 331), at: 2.6) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 331), at: 4.2) == .freezeNow)
    }

    @Test func slowDriftDuringTheCountdownIsMeasuredFromWhereTheCountdownBegan() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.5) == .counting(number: 3))
        // Each step is 4 pixels, under the limit from the frame before, but 12 pixels from where the countdown began is over it.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 324), at: 1.7) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 328), at: 1.9) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 332), at: 2.1) == .keepWaiting)
    }

    @Test func aCaptureGivesUpAfterEighteenSecondsWithNoHold() {
        var capture = capture(armedAt: 5)
        #expect(capture.advance(framingKind: .standBack, torso: torso(), at: 22.9) == .keepWaiting)
        #expect(capture.advance(framingKind: .standBack, torso: torso(), at: 23.0) == .giveUp)
    }

    @Test func aHoldUnderWayFinishesBeforeTheCaptureGivesUp() {
        var capture = capture(armedAt: 0)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 17.0) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 17.5) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 18.0) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 19.0) == .freezeNow)
    }

    @Test func aMoveAfterTheLimitGivesUpInsteadOfStartingANewHold() {
        var capture = capture(armedAt: 0)
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 17.9)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 380), at: 18.1) == .giveUp)
    }

    @Test func aFreezeThatFoundNothingStartsTheHoldOver() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(), at: 1.0)
        _ = capture.advance(framingKind: .ready, torso: torso(), at: 1.5)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.0) == .freezeNow)
        capture.restartTheHold()
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.1) == .keepWaiting)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.6) == .counting(number: 3))
    }

    @Test func eachNumberTicksTheFreezeHasItsOwnSoundAndARestartOrATimeOutIsSilent() {
        #expect(shirtCountdownSound(for: .countdown(3)) == .tick)
        #expect(shirtCountdownSound(for: .countdown(1)) == .tick)
        #expect(shirtCountdownSound(for: .countdown(nil)) == nil)
        #expect(shirtCountdownSound(for: .timedOut) == nil)
        #expect(ShirtCountdownSound.tick.systemSoundName != ShirtCountdownSound.freeze.systemSoundName)
    }

    @Test func theCountdownSoundsAreNotTheThemesDoneCorrectOrNeedsYourOKSounds() {
        // The bundled themes play Tink, Glass, and Pop for those, so the countdown never sounds like an agent finishing.
        let themeSoundNames: Set<String> = ["Tink", "Glass", "Pop"]
        #expect(!themeSoundNames.contains(ShirtCountdownSound.tick.systemSoundName))
        #expect(!themeSoundNames.contains(ShirtCountdownSound.freeze.systemSoundName))
    }

    @Test func reduceMotionShowsTheNumbersWithNoScaleAnimation() {
        #expect(shirtCountdownNumberStartScale(reduceMotionIsOn: true) == 1)
        #expect(shirtCountdownNumberStartScale(reduceMotionIsOn: false) > 1)
    }
}

struct ShirtStepBackPhaseTests {
    private let firstID = ShirtPaintingID(number: 1)
    private let secondID = ShirtPaintingID(number: 2)
    private let ready = RoomArtPhase.readyToPaintTheShirt(title: "Tee")

    private func armed(_ id: ShirtPaintingID) -> RoomArtPhase { .waitingForTheLearnerToStepBack(title: "Tee", id: id) }

    @Test func paintItArmsTheCaptureAndAskingAgainRestartsItUnderANewID() {
        #expect(ready.armingTheShirtCapture(id: firstID) == armed(firstID))
        #expect(armed(firstID).armingTheShirtCapture(id: secondID) == armed(secondID))
        // One painting runs at a time.
        let painting = RoomArtPhase.paintingTheShirt(title: "Tee", id: firstID)
        #expect(painting.armingTheShirtCapture(id: secondID) == painting)
    }

    @Test func onlyTheCurrentCapturesHoldStartsThePainting() {
        #expect(armed(firstID).afterTheLearnerHeldStill(id: firstID) == .paintingTheShirt(title: "Tee", id: firstID))
        // An event from a capture the learner restarted changes nothing.
        #expect(armed(secondID).afterTheLearnerHeldStill(id: firstID) == armed(secondID))
        #expect(ready.afterTheLearnerHeldStill(id: firstID) == ready)
        #expect(RoomArtPhase.closed.afterTheLearnerHeldStill(id: firstID) == .closed)
    }

    @Test func onlyTheCurrentCapturesTimeOutGoesBackToWaitingForPaintIt() {
        #expect(armed(firstID).afterTheStepBackTimedOut(id: firstID) == ready)
        #expect(armed(secondID).afterTheStepBackTimedOut(id: firstID) == armed(secondID))
        #expect(ready.afterTheStepBackTimedOut(id: firstID) == ready)
        #expect(RoomArtPhase.paintingTheShirt(title: "Tee", id: firstID).afterTheStepBackTimedOut(id: firstID) == .paintingTheShirt(title: "Tee", id: firstID))
    }

    @Test func goingBackCancelsAWaitingCapture() {
        #expect(armed(firstID).backToTheLiveShirt() == ready)
    }

    @Test func theStatusLineCoachesWhileTheCaptureWaitsAndSaysToHoldStillOnceTheLearnerIsFramed() {
        // The capture is where the framing matters, so its coaching shows there.
        #expect(armed(firstID).statusLine(theSurfaceIsLost: false, shirtCoachingLine: "Stand back") == "Stand back")
        #expect(armed(firstID).statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil) == "Step back and hold still.")
        #expect(!armed(firstID).statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(!armed(firstID).theItemIsPlacedByClicking)
        #expect(roomArtShirtStepBackLine == "Step back and hold still.")
        #expect(roomArtShirtStepBackTimeoutLine == "I can't see your shoulders yet. Say paint it when you're ready.")
    }

    @Test func beforeThePaintingTheStatusLineSaysHowToStartItWhereverTheLearnerStands() {
        #expect(ready.statusLine(theSurfaceIsLost: false, shirtCoachingLine: "Stand back") == roomArtShirtReadyStatusLine)
        #expect(ready.statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil) == roomArtShirtReadyStatusLine)
        #expect(!ready.statusLineIsAFailure(theSurfaceIsLost: false))
    }

    @Test func theInvitationSaysToHoldThePoseOrTheStillPhotoComesBack() {
        // The painted top follows the learner only near the pose it was painted in, so the line before the painting says so.
        #expect(roomArtShirtReadyLine.contains("Say paint it"))
        #expect(roomArtShirtReadyLine.contains("step back and hold still"))
        #expect(roomArtShirtReadyLine.contains("stay in about the same pose"))
        #expect(roomArtShirtReadyLine.contains("still photo"))
    }

    @Test func theVoiceAndTheButtonSeeAWaitingCapture() {
        #expect(armed(firstID).shirtStillVoiceTargets == .stepBack)
        #expect(ready.shirtStillVoiceTargets == .readyToPaint)
    }

    @Test func theLoopTracesOnlyOnceTheFrameFreezes() {
        let fading = RoomArtLoopState.drawing(beganAt: 4).after(phaseChangedTo: armed(firstID), at: 10)
        #expect(fading == .fadingOut(beganAt: 4, tracesTheLine: true))
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: armed(firstID), at: 10) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .paintingTheShirt(title: "Tee", id: firstID), at: 12) == .drawing(beganAt: 12))
    }
}
