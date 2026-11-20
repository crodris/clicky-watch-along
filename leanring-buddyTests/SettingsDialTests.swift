//
//  SettingsDialTests.swift
//  leanring-buddyTests
//
//  The settings dial that holding shift + option opens: which slice or fan item the pointer picks, what releasing
//  commits, and where a screen edge moves the dial.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

/// A pointer offset from the dial's center, written as an angle (0 right, 90 down) and a distance.
private func pointerOffset(atAngleDegrees angleDegrees: Double, distance: CGFloat) -> CGVector {
    let angleInRadians = angleDegrees * .pi / 180
    return CGVector(dx: cos(angleInRadians) * distance, dy: sin(angleInRadians) * distance)
}

private let insideThePlateDistance: CGFloat = 80
private let beyondThePlateDistance: CGFloat = 152

struct SettingsDialPickingTests {

    @Test func insideThePlateEachSliceIsPickedAtItsOwnAngle() {
        let nothingHighlighted = SettingsDialSelection(slice: nil, fanItemIndex: nil)
        for slice in SettingsDialSlice.allCases {
            let selection = nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: slice.angleDegrees, distance: insideThePlateDistance))
            #expect(selection.slice == slice, "\(slice)")
            #expect(selection.fanItemIndex == nil, "\(slice)")
        }
    }

    @Test func theSliceChangesHalfwayBetweenTwoTokens() {
        let nothingHighlighted = SettingsDialSelection(slice: nil, fanItemIndex: nil)
        // Team is at -90 and Model at -18, so the halfway angle is -54, and each side flips one degree past it.
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -55, distance: insideThePlateDistance)).slice == .team)
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -53, distance: insideThePlateDistance)).slice == .model)
        // More is at 198, which atan2 reports as -162. Its halfway angle to Team is -126.
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -162, distance: insideThePlateDistance)).slice == .more)
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -127, distance: insideThePlateDistance)).slice == .more)
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -125, distance: insideThePlateDistance)).slice == .team)
    }

    @Test func theCenterPicksNothingAndClearsAnEarlierPick() {
        let teamHighlighted = SettingsDialSelection(slice: .team, fanItemIndex: 3)
        let selectionInTheCenter = teamHighlighted.afterPointerMoved(to: CGVector(dx: 10, dy: -10))
        #expect(selectionInTheCenter == SettingsDialSelection(slice: nil, fanItemIndex: nil))
        #expect(SettingsDialChoice(committing: selectionInTheCenter) == nil)
    }

    @Test func theDeadZoneEndsExactlyWhereItIsDefined() {
        let nothingHighlighted = SettingsDialSelection(slice: nil, fanItemIndex: nil)
        let justInside = nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: 54, distance: SettingsDialGeometry.centerDeadZoneRadius))
        let justOutside = nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: 54, distance: SettingsDialGeometry.centerDeadZoneRadius + 1))
        #expect(justInside.slice == nil)
        #expect(justOutside.slice == .agents)
    }

    @Test func withNoFanOpenAPointerBeyondThePlateStillPicksTheSliceAtItsAngle() {
        // A fast flick can jump past the plate in one move, and it must still land on the slice it was aimed at.
        let nothingHighlighted = SettingsDialSelection(slice: nil, fanItemIndex: nil)
        let flickedToShow = nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: 126, distance: beyondThePlateDistance))
        #expect(flickedToShow.slice == .show)
        #expect(SettingsDialChoice(committing: flickedToShow) == .toggleShowClicky)

        // Beyond the plate at Team's angle opens its fan, with no item picked yet.
        let flickedToTeam = nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -90, distance: SettingsDialGeometry.plateRadius + 1))
        #expect(flickedToTeam.slice == .team)
        #expect(flickedToTeam.openFanLayout != nil)
    }

    @Test func theTeamFanPicksEachBallWithClickyBlueAndRandomAtTheEnds() throws {
        let teamFanLayout = try #require(SettingsDialSlice.team.fanLayout)
        #expect(teamFanLayout.itemCount == CompanionTheme.allChoices.count)
        #expect(teamFanLayout.angleDegrees(ofItemAt: 0) == -168)
        #expect(abs(teamFanLayout.angleDegrees(ofItemAt: teamFanLayout.itemCount - 1) - -12) < 0.000_001)

        let teamOpen = SettingsDialSelection(slice: .team, fanItemIndex: nil)
        for itemIndex in 0..<teamFanLayout.itemCount {
            let pointerOnTheBall = pointerOffset(atAngleDegrees: teamFanLayout.angleDegrees(ofItemAt: itemIndex), distance: SettingsDialGeometry.fanRadius)
            let selection = teamOpen.afterPointerMoved(to: pointerOnTheBall)
            #expect(selection.slice == .team)
            #expect(selection.fanItemIndex == itemIndex)
            #expect(SettingsDialChoice(committing: selection) == .theme(CompanionTheme.allChoices[itemIndex]))
        }
        #expect(CompanionTheme.allChoices.first == .clickyBlue)
        #expect(CompanionTheme.allChoices.last == .random)
        #expect(CompanionTheme.allChoices.count == 12)
    }

    @Test func theModelFanPicksSonnetThenOpus() throws {
        let modelFanLayout = try #require(SettingsDialSlice.model.fanLayout)
        let modelOpen = SettingsDialSelection(slice: .model, fanItemIndex: nil)
        let onSonnet = modelOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: modelFanLayout.angleDegrees(ofItemAt: 0), distance: SettingsDialGeometry.fanRadius))
        let onOpus = modelOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: modelFanLayout.angleDegrees(ofItemAt: 1), distance: SettingsDialGeometry.fanRadius))
        #expect(SettingsDialChoice(committing: onSonnet) == .model(.sonnet))
        #expect(SettingsDialChoice(committing: onOpus) == .model(.opus))
        #expect(SettingsDialModelChoice.sonnet.modelID == ClaudeVoiceModel.sonnetModelID)
        #expect(SettingsDialModelChoice.opus.modelID == ClaudeVoiceModel.opusModelID)
    }

    @Test func aFanStaysOpenWhileThePointerTravelsOutwardAcrossAnotherSlicesAngle() {
        // Team's fan is open and the pointer goes outward at Agents' angle: the slice must stay Team, and no item is under it.
        let teamOpen = SettingsDialSelection(slice: .team, fanItemIndex: nil)
        let acrossAgentsAngle = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.agents.angleDegrees, distance: beyondThePlateDistance))
        #expect(acrossAgentsAngle.slice == .team)
        #expect(acrossAgentsAngle.fanItemIndex == nil)
        #expect(SettingsDialChoice(committing: acrossAgentsAngle) == nil)

        // Travelling outward along Model's angle keeps Team open and picks Team's item at that angle, never a Model item.
        let acrossModelAngle = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.model.angleDegrees, distance: beyondThePlateDistance))
        #expect(acrossModelAngle.slice == .team)

        // Coming back inside the plate at Agents' angle is what changes the slice.
        let backInsideAtAgents = acrossAgentsAngle.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.agents.angleDegrees, distance: insideThePlateDistance))
        #expect(backInsideAtAgents.slice == .agents)
        #expect(backInsideAtAgents.fanItemIndex == nil)
    }

    @Test func thePlateBoundaryDecidesBetweenPickingASliceAndPickingAFanItem() {
        let teamOpen = SettingsDialSelection(slice: .team, fanItemIndex: nil)
        let angleOfClickyBlueBall = SettingsDialSlice.team.fanLayout!.angleDegrees(ofItemAt: 0)
        // On the plate's edge the pointer is still inside, so it picks the slice at that angle, which is Show here.
        let onTheEdge = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.show.angleDegrees, distance: SettingsDialGeometry.plateRadius))
        #expect(onTheEdge.slice == .show)
        // One point past it the open fan takes over.
        let pastTheEdge = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: angleOfClickyBlueBall, distance: SettingsDialGeometry.plateRadius + 1))
        #expect(pastTheEdge.slice == .team)
        #expect(pastTheEdge.fanItemIndex == 0)
    }

    @Test func anAngleBeyondTheEndOfTheFanPicksNoItem() {
        let teamOpen = SettingsDialSelection(slice: .team, fanItemIndex: nil)
        // The fan ends at -12 degrees and its items are about 14 degrees apart, so 20 degrees is past Random.
        let pastRandom = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: 20, distance: SettingsDialGeometry.fanRadius))
        #expect(pastRandom.slice == .team)
        #expect(pastRandom.fanItemIndex == nil)
    }

    @Test func wanderingPastThePickingRadiusPicksNothingButKeepsAnOpenFanOpen() {
        let teamWithAnItem = SettingsDialSelection(slice: .team, fanItemIndex: 4)
        let farAway = teamWithAnItem.afterPointerMoved(to: pointerOffset(atAngleDegrees: -100, distance: SettingsDialGeometry.pickingOuterRadius + 1))
        #expect(farAway.slice == .team)
        #expect(farAway.fanItemIndex == nil)
        #expect(SettingsDialChoice(committing: farAway) == nil)

        // With no fan open, far away is the same as the center: nothing.
        let showHighlighted = SettingsDialSelection(slice: .show, fanItemIndex: nil)
        let farFromShow = showHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: 126, distance: SettingsDialGeometry.pickingOuterRadius + 1))
        #expect(farFromShow == SettingsDialSelection(slice: nil, fanItemIndex: nil))
    }

    @Test func releasingOnTheSlicesWithoutAFanCommitsTheirAction() {
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .agents, fanItemIndex: nil)) == .agents)
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .show, fanItemIndex: nil)) == .toggleShowClicky)
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .more, fanItemIndex: nil)) == .more)
        // Team and Model commit only an item of their fan.
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .team, fanItemIndex: nil)) == nil)
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .model, fanItemIndex: nil)) == nil)
    }

    @Test func aDialShiftedOffThePointerPicksNothingUntilThePointerMoves() {
        // An edge moved the dial so the pointer starts 190 points above its center, in the Team fan's area.
        let pointerWhenOpened = pointerOffset(atAngleDegrees: -90, distance: 190)
        var picker = SettingsDialPicker(pointerOffsetWhenOpened: pointerWhenOpened)
        picker.pointerMoved(to: pointerWhenOpened)
        #expect(picker.selection == SettingsDialSelection(slice: nil, fanItemIndex: nil))

        // A small tremor under 10 points still picks nothing.
        picker.pointerMoved(to: CGVector(dx: pointerWhenOpened.dx + 6, dy: pointerWhenOpened.dy))
        #expect(picker.selection.slice == nil)

        // Real movement arms it, and from then on it follows the pointer.
        picker.pointerMoved(to: pointerOffset(atAngleDegrees: 54, distance: insideThePlateDistance))
        #expect(picker.selection.slice == .agents)
        picker.pointerMoved(to: pointerWhenOpened)
        #expect(picker.selection.slice == .team)
    }
}

struct SettingsDialPlacementTests {

    private let visibleFrame = CGRect(x: 0, y: 25, width: 1440, height: 850)

    @Test func theDialCentersOnTheMouseWhenEverythingFits() {
        let mouseLocation = CGPoint(x: 700, y: 450)
        #expect(SettingsDialPlacement.dialCenter(forMouseLocation: mouseLocation, visibleFrame: visibleFrame) == mouseLocation)
    }

    @Test func eachEdgeMovesTheDialInwardByExactlyWhatSticksOut() {
        // AppKit's y grows upward, so the top of the screen is maxY.
        let nearTheTop = SettingsDialPlacement.dialCenter(forMouseLocation: CGPoint(x: 700, y: 870), visibleFrame: visibleFrame)
        #expect(nearTheTop == CGPoint(x: 700, y: visibleFrame.maxY - SettingsDialPlacement.reachAbove))

        let nearTheBottom = SettingsDialPlacement.dialCenter(forMouseLocation: CGPoint(x: 700, y: 30), visibleFrame: visibleFrame)
        #expect(nearTheBottom == CGPoint(x: 700, y: visibleFrame.minY + SettingsDialPlacement.reachBelow))

        let nearTheLeft = SettingsDialPlacement.dialCenter(forMouseLocation: CGPoint(x: 5, y: 450), visibleFrame: visibleFrame)
        #expect(nearTheLeft == CGPoint(x: SettingsDialPlacement.reachLeft, y: 450))

        let nearTheRightTopCorner = SettingsDialPlacement.dialCenter(forMouseLocation: CGPoint(x: 1439, y: 874), visibleFrame: visibleFrame)
        #expect(nearTheRightTopCorner == CGPoint(x: visibleFrame.maxX - SettingsDialPlacement.reachRight, y: visibleFrame.maxY - SettingsDialPlacement.reachAbove))
    }

    @Test func aScreenSmallerThanTheDialCentersTheDialOnTheScreen() {
        let tinyFrame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let center = SettingsDialPlacement.dialCenter(forMouseLocation: CGPoint(x: 110, y: 110), visibleFrame: tinyFrame)
        // The window reaches farther above the center than below it, so the center sits that much below the screen's middle.
        let windowMiddleY = center.y + (SettingsDialPlacement.reachAbove - SettingsDialPlacement.reachBelow) / 2
        #expect(center.x == tinyFrame.midX)
        #expect(windowMiddleY == tinyFrame.midY)
    }
}
