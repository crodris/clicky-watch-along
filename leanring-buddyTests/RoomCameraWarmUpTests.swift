//
//  RoomCameraWarmUpTests.swift
//  leanring-buddyTests
//
//  The built-in camera holds its first frames back while auto exposure and white balance settle, so the room art's early
//  keyframe is a well exposed frame. The device cannot run in tests, so the rule is stepped by hand with a clock.
//

import Foundation
import Testing
@testable import Clicky

/// Wraps the mutating rule so a test can call it inside `#expect`, which cannot mutate a local value.
private final class WarmUpStepper {
    private var warmUp = RoomCameraWarmUp()

    func delivers(at now: TimeInterval, exposure: Bool, whiteBalance: Bool) -> Bool {
        warmUp.shouldDeliverAFrame(now: now, isAdjustingExposure: exposure, isAdjustingWhiteBalance: whiteBalance)
    }
}

struct RoomCameraWarmUpTests {
    @Test func theLongestWaitIsThreeQuartersOfASecond() {
        #expect(RoomCameraWarmUp.longestWaitSeconds == 0.75)
    }

    @Test func aFrameWaitsWhileExposureIsStillAdjusting() {
        let warmUp = WarmUpStepper()
        #expect(!warmUp.delivers(at: 10.0, exposure: true, whiteBalance: false))
        #expect(!warmUp.delivers(at: 10.3, exposure: true, whiteBalance: false))
    }

    @Test func aFrameWaitsWhileWhiteBalanceIsStillAdjusting() {
        let warmUp = WarmUpStepper()
        #expect(!warmUp.delivers(at: 10.0, exposure: false, whiteBalance: true))
        #expect(!warmUp.delivers(at: 10.3, exposure: true, whiteBalance: true))
    }

    @Test func framesStartAsSoonAsTheDeviceReportsItHasSettled() {
        let warmUp = WarmUpStepper()
        #expect(!warmUp.delivers(at: 10.0, exposure: true, whiteBalance: true))
        #expect(!warmUp.delivers(at: 10.2, exposure: false, whiteBalance: true))
        #expect(warmUp.delivers(at: 10.4, exposure: false, whiteBalance: false))
    }

    @Test func aDeviceThatNeverSettlesStartsAfterThreeQuartersOfASecondFromTheFirstFrame() {
        let warmUp = WarmUpStepper()
        #expect(!warmUp.delivers(at: 10.0, exposure: true, whiteBalance: true))
        #expect(!warmUp.delivers(at: 10.74, exposure: true, whiteBalance: true))
        #expect(warmUp.delivers(at: 10.75, exposure: true, whiteBalance: true))
    }

    @Test func theWaitCountsFromTheFirstFrameAndNotFromTheCamerasStart() {
        let warmUp = WarmUpStepper()
        // The first frame arrives long after the object was made. The wait still runs its full 0.75 seconds from that frame.
        #expect(!warmUp.delivers(at: 500.0, exposure: true, whiteBalance: false))
        #expect(!warmUp.delivers(at: 500.5, exposure: true, whiteBalance: false))
    }

    @Test func settledFlagsOnTheFirstFramesCountOnlyAfterTheShortestWait() {
        // A session that just started can report both flags false before auto exposure has begun.
        let warmUp = WarmUpStepper()
        #expect(RoomCameraWarmUp.shortestWaitSeconds == 0.35)
        #expect(!warmUp.delivers(at: 10.0, exposure: false, whiteBalance: false))
        #expect(!warmUp.delivers(at: 10.34, exposure: false, whiteBalance: false))
        #expect(warmUp.delivers(at: 10.4, exposure: false, whiteBalance: false))
    }

    @Test func onceFramesStartTheyKeepComingWhateverTheDeviceReportsLater() {
        let warmUp = WarmUpStepper()
        #expect(!warmUp.delivers(at: 10.0, exposure: false, whiteBalance: false))
        #expect(warmUp.delivers(at: 10.4, exposure: false, whiteBalance: false))
        // Auto exposure adjusts again when the learner steps into the light, and the panel must not freeze on that.
        #expect(warmUp.delivers(at: 10.5, exposure: true, whiteBalance: true))
    }
}
