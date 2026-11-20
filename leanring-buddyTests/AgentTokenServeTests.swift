//
//  AgentTokenServeTests.swift
//  leanring-buddyTests
//
//  The serve of a new agent's token from the cursor into its slot beside the notch: when it flies, fades in, or does not
//  happen, the arc it flies along, where it starts, which display it flies to, and which study guide agents get it.
//

import CoreGraphics
import Foundation
import Testing

@testable import Clicky

@MainActor
struct AgentTokenServeTests {
    private let cursorPoint = CGPoint(x: 700, y: 400)
    private let slotPoint = CGPoint(x: 900, y: 880)

    // MARK: - Plan

    @Test func aTokenFliesFromTheCursorToItsSlotWhenThereIsASlotAndRoomForDiscs() async throws {
        let plan = agentTokenServePlan(cursorPoint: cursorPoint, slotPoint: slotPoint, slotDisplayCanShowDiscs: true, reduceMotionIsOn: false)
        let expectedPath = agentTokenServePath(from: cursorPoint, to: slotPoint)
        #expect(plan == .fly(expectedPath))
        #expect(expectedPath.start == cursorPoint)
        #expect(expectedPath.end == slotPoint)
    }

    @Test func anAgentWithNoSlotOfItsOwnGetsNoServeEvenWithReduceMotionOn() async throws {
        for reduceMotionIsOn in [false, true] {
            let plan = agentTokenServePlan(cursorPoint: cursorPoint, slotPoint: nil, slotDisplayCanShowDiscs: true, reduceMotionIsOn: reduceMotionIsOn)
            #expect(plan == .none)
        }
    }

    @Test func aDisplayThatCanShowNoDiscsGetsNoServeEvenWithASlotPointAndReduceMotionOn() async throws {
        for reduceMotionIsOn in [false, true] {
            let plan = agentTokenServePlan(cursorPoint: cursorPoint, slotPoint: slotPoint, slotDisplayCanShowDiscs: false, reduceMotionIsOn: reduceMotionIsOn)
            #expect(plan == .none)
        }
    }

    @Test func reduceMotionFadesTheTokenInAtItsSlotInsteadOfFlying() async throws {
        let plan = agentTokenServePlan(cursorPoint: cursorPoint, slotPoint: slotPoint, slotDisplayCanShowDiscs: true, reduceMotionIsOn: true)
        #expect(plan == .fadeInAtTheSlot)
    }

    // MARK: - Arc

    @Test func theFlightTakesHalfASecond() async throws {
        #expect(AgentTokenServePath.flightSeconds == 0.5)
    }

    @Test func theArcLeavesTheCursorArrivesAtTheSlotAndBowsSidewaysByAFifthOfTheDistance() async throws {
        // A flight straight up has no higher side, so it bows to the right.
        let path = agentTokenServePath(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 100, y: 300))
        #expect(path.point(atFlightProgress: 0) == CGPoint(x: 100, y: 100))
        #expect(path.point(atFlightProgress: 1) == CGPoint(x: 100, y: 300))
        // 200 points apart bows 40 points at the control point, which is the middle of the line pushed 40 to the right.
        #expect(path.control == CGPoint(x: 140, y: 200))
        // The curve itself reaches half the bow at its middle.
        #expect(path.point(atFlightProgress: 0.5) == CGPoint(x: 120, y: 200))
    }

    @Test func theArcBowsTowardTheTopWhicheverWayTheTokenTravels() async throws {
        // The line is 250 points long, so the control point sits 50 points off its middle (75, 100).
        // Up and to the right, the bow is up and to the left of the line, since that side is higher.
        let toTheUpperRight = agentTokenServePath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 150, y: 200))
        #expect(toTheUpperRight.control == CGPoint(x: 75 - 40, y: 100 + 30))
        // Up and to the left, the bow is up and to the right.
        let toTheUpperLeft = agentTokenServePath(from: CGPoint(x: 150, y: 0), to: CGPoint(x: 0, y: 200))
        #expect(toTheUpperLeft.control == CGPoint(x: 75 + 40, y: 100 + 30))
    }

    @Test func aLongFlightBowsNoMoreThanEightyPoints() async throws {
        let path = agentTokenServePath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1_000, y: 1_000))
        let midpoint = CGPoint(x: 500, y: 500)
        // A fifth of the 1,414 point distance would be 283.
        #expect(abs(hypot(path.control.x - midpoint.x, path.control.y - midpoint.y) - 80) < 0.001)
    }

    @Test func theArcNeverRisesAboveTheHigherEndSoACursorNearTheMenuBarKeepsTheTokenOnScreen() async throws {
        // Cursor in the menu bar row, 400 points left of the slot: an unclamped arc would bow 80 above both.
        let slotInTheMenuBar = CGPoint(x: 900, y: 880)
        let cursorInTheMenuBar = CGPoint(x: 500, y: 880)
        let path = agentTokenServePath(from: cursorInTheMenuBar, to: slotInTheMenuBar)
        let highestPointOfTheArc = (0...100)
            .map { path.point(atFlightProgress: Double($0) / 100).y }
            .max() ?? 0
        // A hundredth of a point of slack covers floating point error in the curve.
        #expect(highestPointOfTheArc <= 880.01)
    }

    @Test func aTokenThatStartsAtTheSameSpotAsItsSlotDoesNotMove() async throws {
        let path = agentTokenServePath(from: slotPoint, to: slotPoint)
        #expect(path.point(atFlightProgress: 0.5) == slotPoint)
    }

    @Test func theTokenEasesInAndOutAndTheProgressIsClamped() async throws {
        #expect(agentTokenServeEasedProgress(0) == 0)
        #expect(agentTokenServeEasedProgress(0.5) == 0.5)
        #expect(agentTokenServeEasedProgress(1) == 1)
        #expect(agentTokenServeEasedProgress(0.1) < 0.1)
        #expect(agentTokenServeEasedProgress(0.9) > 0.9)
        #expect(agentTokenServeEasedProgress(-1) == 0)
        #expect(agentTokenServeEasedProgress(2) == 1)
    }

    // MARK: - Where it starts and which display

    @Test func theTokenStartsAtTheCursorGlyphWhichSitsRightAndBelowTheMouse() async throws {
        let startPoint = agentTokenServeStartPoint(mouseLocation: CGPoint(x: 100, y: 500))
        // 35 right, and 25 down, which is 25 less in AppKit's upward y.
        #expect(startPoint == CGPoint(x: 135, y: 475))
    }

    @Test func theTokenFliesToTheDisplayTheMouseIsOnOrNowhereWhenItIsOnNone() async throws {
        let displayFramesByID: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            2: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080),
        ]
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 400, y: 500), displayFrames: displayFramesByID) == 1)
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 2_000, y: 500), displayFrames: displayFramesByID) == 2)
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 5_000, y: 500), displayFrames: displayFramesByID) == nil)
    }

    @Test func aMouseOnTheTopRowOfADisplayStillGetsThatDisplay() async throws {
        let displayFramesByID: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            2: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080),
        ]
        // The top row of the first display has y equal to its maxY of 982, which CGRect.contains leaves out.
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 400, y: 982), displayFrames: displayFramesByID) == 1)
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 2_000, y: 1_080), displayFrames: displayFramesByID) == 2)
    }

    @Test func aMouseOnTheTopRowOfADisplayWithAnotherStackedAboveItStaysOnThatDisplay() async throws {
        // The laptop is 982 high and the external display sits right above it, so y 982 is the laptop's top row and the
        // external display's bottom edge, which the mouse never rests on.
        let displayFramesByID: [CGDirectDisplayID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 1_512, height: 982),
            2: CGRect(x: 0, y: 982, width: 1_920, height: 1_080),
        ]
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 400, y: 982), displayFrames: displayFramesByID) == 1)
        #expect(agentTokenServeDisplayID(containing: CGPoint(x: 400, y: 983), displayFrames: displayFramesByID) == 2)
    }

    @Test func aPointOnTheEdgeTwoDisplaysShareBelongsToTheDisplayItIsInsideOfWhicheverWayTheIDsAreAssigned() async throws {
        // x 1,512 is the right display's minX and the left display's maxX. A dictionary's order depends on its keys, so the IDs go
        // both ways round, and the answer must still be the right display.
        for (leftDisplayID, rightDisplayID) in [(CGDirectDisplayID(1), CGDirectDisplayID(2)), (CGDirectDisplayID(2), CGDirectDisplayID(1))] {
            let displayFramesByID: [CGDirectDisplayID: CGRect] = [
                leftDisplayID: CGRect(x: 0, y: 0, width: 1_512, height: 982),
                rightDisplayID: CGRect(x: 1_512, y: 0, width: 1_920, height: 1_080),
            ]
            #expect(agentTokenServeDisplayID(containing: CGPoint(x: 1_512, y: 500), displayFrames: displayFramesByID) == rightDisplayID)
        }
    }

    // MARK: - Which agents

    @Test func onlyAStudyGuideOrRevisionTheLearnerAskedForIsServedAndAQuizRefreshIsNot() async throws {
        #expect(StudyGuideJob.write(focus: nil).isAskedForByTheLearner)
        #expect(StudyGuideJob.revise(instruction: "shorter").isAskedForByTheLearner)
        #expect(!StudyGuideJob.refresh.isAskedForByTheLearner)
    }
}
