//
//  CursorFlightMotionTests.swift
//  leanring-buddyTests
//
//  How the cursor gets to a target or back to the mouse: the swooping arc normally, and a short fade under Reduce Motion.
//

import Testing

@testable import Clicky

struct CursorFlightMotionTests {
    @Test func theCursorTravelsAlongTheArcWhenReduceMotionIsOff() {
        #expect(cursorFlightMotion(reduceMotionIsOn: false) == .travelAlongArc)
    }

    @Test func theCursorFadesToTheDestinationWithNoTravelWhenReduceMotionIsOn() {
        #expect(cursorFlightMotion(reduceMotionIsOn: true) == .fadeToDestination)
    }
}
