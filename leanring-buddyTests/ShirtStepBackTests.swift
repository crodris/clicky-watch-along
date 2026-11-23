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
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.0) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.2) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.4) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.6) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.8) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.99) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.0) == .freezeNow)
    }

    @Test func theHoldIsOneSecondAndTheCountdownHasThreeNumbers() {
        #expect(ShirtStepBackCapture.secondsToHoldStill == 1.0 && ShirtStepBackCapture.countdownNumbers == 3)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0) == 3)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0.3) == 3)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0.4) == 2)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 0.7) == 1)
        #expect(ShirtStepBackCapture.countdownNumber(afterHolding: 5) == 1)
    }

    @Test func leavingTheReadyFramingRestartsTheHold() {
        var capture = capture()
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.0) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 1.8) == .counting(number: 1))
        // A learner who leans in again is judged too close, whatever the torso says.
        #expect(capture.advance(framingKind: .standBack, torso: torso(), at: 1.9) == .keepWaiting)
        #expect(capture.advance(framingKind: .noPerson, torso: nil, at: 2.0) == .keepWaiting)
        #expect(capture.advance(framingKind: nil, torso: torso(), at: 2.1) == .keepWaiting)
        // Back in the ready framing, the hold starts over from 3 and needs its whole second again.
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.5) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.4) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 3.5) == .freezeNow)
    }

    @Test func aTorsoWithNoTorsoInTheReadyFramingNeverCounts() {
        var capture = capture()
        #expect(capture.advance(framingKind: .ready, torso: nil, at: 1) == .keepWaiting)
    }

    @Test func movingTheShouldersRestartsTheHoldFromWhereTheyAreNow() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.0)
        // 3 pixels is 0.03 shoulder widths, inside the 0.04 limit.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 323), at: 1.25) == .counting(number: 3))
        // 11 pixels is 0.11 shoulder widths, past the limit: the hold starts over at the new place.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 331), at: 1.5) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 331), at: 2.4) == .counting(number: 1))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 331), at: 2.5) == .freezeNow)
    }

    @Test func movingUpAndDownRestartsTheHoldToo() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerY: 150), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerY: 156), at: 1.5) == .counting(number: 3))
    }

    @Test func aChangeOfShoulderWidthRestartsTheHoldAsTheLearnerSteppingBackDoes() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 100), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 103), at: 1.5) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(shoulderWidth: 95), at: 1.6) == .counting(number: 3))
    }

    @Test func slowDriftIsMeasuredFromTheStartOfTheHoldNotFromTheLastFrame() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 1.0)
        // Each step is 1.5 pixels, under the limit from the frame before, but 4.5 pixels from the start is over it.
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 321.5), at: 1.2) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 323), at: 1.4) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 324.5), at: 1.6) == .counting(number: 3))
    }

    @Test func aCaptureGivesUpAfterTenSecondsWithNoHold() {
        var capture = capture(armedAt: 5)
        #expect(capture.advance(framingKind: .standBack, torso: torso(), at: 14.9) == .keepWaiting)
        #expect(capture.advance(framingKind: .standBack, torso: torso(), at: 15.0) == .giveUp)
    }

    @Test func aHoldUnderWayFinishesBeforeTheCaptureGivesUp() {
        var capture = capture(armedAt: 0)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 9.75) == .counting(number: 3))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 10.25) == .counting(number: 2))
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 10.75) == .freezeNow)
    }

    @Test func aMoveAfterTheLimitGivesUpInsteadOfStartingANewHold() {
        var capture = capture(armedAt: 0)
        _ = capture.advance(framingKind: .ready, torso: torso(centerX: 320), at: 9.9)
        #expect(capture.advance(framingKind: .ready, torso: torso(centerX: 380), at: 10.1) == .giveUp)
    }

    @Test func aFreezeThatFoundNothingStartsTheHoldOver() {
        var capture = capture()
        _ = capture.advance(framingKind: .ready, torso: torso(), at: 1.0)
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.0) == .freezeNow)
        capture.restartTheHold()
        #expect(capture.advance(framingKind: .ready, torso: torso(), at: 2.1) == .counting(number: 3))
    }

    @Test func reduceMotionShowsTheNumbersWithNoScaleAnimation() {
        #expect(shirtCountdownNumberStartScale(reduceMotionIsOn: true) == 1)
        #expect(shirtCountdownNumberStartScale(reduceMotionIsOn: false) > 1)
    }
}

struct ShirtStepBackPhaseTests {
    private let firstID = ShirtPaintingID(number: 1)
    private let secondID = ShirtPaintingID(number: 2)
    private let live = RoomArtPhase.showingTheShirt(title: "Tee")

    private func armed(_ id: ShirtPaintingID) -> RoomArtPhase { .waitingForTheLearnerToStepBack(title: "Tee", id: id) }

    @Test func askingAgainWhileArmedRestartsTheCaptureUnderANewID() {
        #expect(armed(firstID).armingTheShirtCapture(id: secondID) == armed(secondID))
    }

    @Test func onlyTheCurrentCapturesHoldStartsThePainting() {
        #expect(armed(firstID).afterTheLearnerHeldStill(id: firstID) == .paintingTheShirt(title: "Tee", id: firstID))
        // An event from a capture the learner restarted changes nothing.
        #expect(armed(secondID).afterTheLearnerHeldStill(id: firstID) == armed(secondID))
        #expect(live.afterTheLearnerHeldStill(id: firstID) == live)
        #expect(RoomArtPhase.closed.afterTheLearnerHeldStill(id: firstID) == .closed)
    }

    @Test func onlyTheCurrentCapturesTimeOutBringsTheLivePreviewBack() {
        #expect(armed(firstID).afterTheStepBackTimedOut(id: firstID) == live)
        #expect(armed(secondID).afterTheStepBackTimedOut(id: firstID) == armed(secondID))
        #expect(live.afterTheStepBackTimedOut(id: firstID) == live)
        #expect(RoomArtPhase.paintingTheShirt(title: "Tee", id: firstID).afterTheStepBackTimedOut(id: firstID) == .paintingTheShirt(title: "Tee", id: firstID))
    }

    @Test func goingBackCancelsAWaitingCapture() {
        #expect(armed(firstID).backToTheLiveShirt() == live)
    }

    @Test func theStatusLineSaysToStepBackAndIsNotAFailure() {
        #expect(armed(firstID).statusLine(theSurfaceIsLost: false, shirtCoachingLine: "Stand back") == "Step back and hold still.")
        #expect(!armed(firstID).statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(!armed(firstID).theItemIsPlacedByClicking)
        #expect(roomArtShirtStepBackLine == "Step back and hold still.")
        #expect(roomArtShirtStepBackTimeoutLine == "I can't see your shoulders yet. Say right there when you're ready.")
    }

    @Test func theVoiceAndTheButtonSeeAWaitingCapture() {
        #expect(armed(firstID).shirtStillVoiceTargets == .stepBack)
        #expect(live.shirtStillVoiceTargets == .livePreview)
    }

    @Test func theLoopFadesWhenTheLivePreviewGoesIntoAWaitingCaptureAndTracesAgainWhenItPaints() {
        let fading = RoomArtLoopState.drawing(beganAt: 4).after(phaseChangedTo: armed(firstID), at: 10)
        #expect(fading == .fadingOut(beganAt: 4, tracesTheLine: true))
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: armed(firstID), at: 10) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .paintingTheShirt(title: "Tee", id: firstID), at: 12) == .drawing(beganAt: 12))
    }
}
