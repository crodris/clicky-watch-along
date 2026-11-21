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
import SwiftUI
import Testing
@testable import Clicky

/// A pointer offset from the dial's center, written as an angle (0 right, 90 down) and a distance.
private func pointerOffset(atAngleDegrees angleDegrees: Double, distance: CGFloat) -> CGVector {
    let angleInRadians = angleDegrees * .pi / 180
    return CGVector(dx: cos(angleInRadians) * distance, dy: sin(angleInRadians) * distance)
}

private let insideThePlateDistance: CGFloat = 80
private let beyondThePlateDistance: CGFloat = 152

/// The picking tests below describe the dial before the learner saves a theme, so they pick from the built-in fans. The
/// saved-theme tests pass their own fans.
private extension SettingsDialSelection {
    func afterPointerMoved(to pointerOffset: CGVector) -> SettingsDialSelection {
        afterPointerMoved(to: pointerOffset, fans: .builtIn)
    }
}

private extension SettingsDialChoice {
    init?(committing selection: SettingsDialSelection) {
        self.init(committing: selection, fans: .builtIn)
    }
}

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
        #expect(flickedToTeam.openFanLayout(in: .builtIn) != nil)
    }

    @Test func theTeamFanPicksEachBallWithClickyBlueAndRandomAtTheEnds() throws {
        let teamFanLayout = try #require(SettingsDialFans.builtIn.layout(of: .team))
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
        let modelFanLayout = try #require(SettingsDialFans.builtIn.layout(of: .model))
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
        let angleOfClickyBlueBall = SettingsDialFans.builtIn.layout(of: .team)!.angleDegrees(ofItemAt: 0)
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
        var picker = SettingsDialPicker(pointerOffsetWhenOpened: pointerWhenOpened, fans: .builtIn)
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

    @Test func aScreenSmallerThanTheDialCentersTheDialsWindowOnTheScreen() {
        let tinyFrame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let center = SettingsDialPlacement.dialCenter(forMouseLocation: CGPoint(x: 110, y: 110), visibleFrame: tinyFrame)
        // The window reaches farther above the center than below it, and farther right than left, so the window, not the
        // dial's center, sits in the screen's middle.
        let windowMiddleX = center.x + (SettingsDialPlacement.reachRight - SettingsDialPlacement.reachLeft) / 2
        let windowMiddleY = center.y + (SettingsDialPlacement.reachAbove - SettingsDialPlacement.reachBelow) / 2
        #expect(windowMiddleX == tinyFrame.midX)
        #expect(windowMiddleY == tinyFrame.midY)
    }
}


// MARK: - Saved themes in the Team fan

/// The moment the saved-theme tests count back from, so no test depends on the clock.
private let referenceSavedDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

/// A saved theme named `themeName`, saved `minutesAgo` minutes before the reference moment.
private func savedTheme(named themeName: String, id themeID: String, minutesAgo: Double) throws -> SavedCustomTheme {
    let idea = replacingField(in: goodThemeIdea, at: ["name"], with: .string(themeName))
    return SavedCustomTheme(
        theme: try CustomTheme.parse(idea: idea, id: themeID, pictureIsAvailable: false),
        savedDate: referenceSavedDate.addingTimeInterval(-minutesAgo * 60)
    )
}

/// Fans whose saved themes carry `themeNames` in order, the first saved last, so the Team fan lists them in that order
/// after Random.
private func fansWithSavedThemes(named themeNames: [String]) throws -> SettingsDialFans {
    let savedThemes = try themeNames.enumerated().map { themeIndex, themeName in
        try savedTheme(named: themeName, id: "theme-\(themeIndex)", minutesAgo: Double(themeIndex))
    }
    return SettingsDialFans(savedCustomThemes: savedThemes)
}

/// A name of the 24 characters a saved theme may have, in the widest letter, so it is the widest label any theme can make.
private let widestPossibleThemeName = String(repeating: "W", count: 24)

private let builtInTeamFanItemCount = CompanionTheme.allChoices.count
/// The Team fan holds 12 items with no saved theme and 15 with three.
private let teamFanItemCounts = [12, 13, 14, 15]

private func teamFanBallCenter(itemIndex: Int, in fans: SettingsDialFans) -> CGPoint {
    let angleInRadians = (fans.layout(of: .team)?.angleDegrees(ofItemAt: itemIndex) ?? 0) * .pi / 180
    return CGPoint(
        x: cos(angleInRadians) * SettingsDialGeometry.fanRadius,
        y: sin(angleInRadians) * SettingsDialGeometry.fanRadius
    )
}

struct SettingsDialSavedThemeFanTests {

    @Test func withNoSavedThemeTheTeamFanIsTheTwelveBuiltInChoices() {
        let fans = SettingsDialFans(savedCustomThemes: [])
        #expect(fans == .builtIn)
        #expect(fans.teamThemes == CompanionTheme.allChoices)
        #expect(fans.layout(of: .team)?.itemCount == 12)
    }

    @Test func theNewestThreeSavedThemesFollowRandomNewestFirst() throws {
        // Handed over in name order, as the store lists them, so the order below comes from the dates alone.
        let savedThemes = [
            try savedTheme(named: "Aurora", id: "aurora-0001", minutesAgo: 500),
            try savedTheme(named: "Ember", id: "ember-0002", minutesAgo: 3),
            try savedTheme(named: "Moonlit", id: "moonlit-0003", minutesAgo: 90),
            try savedTheme(named: "Zen", id: "zen-0004", minutesAgo: 40),
        ]
        let fans = SettingsDialFans(savedCustomThemes: savedThemes)
        #expect(Array(fans.teamThemes.prefix(12)) == CompanionTheme.allChoices)
        #expect(fans.teamThemes.last.map(\.displayName) == "Moonlit")
        #expect(fans.teamThemes.suffix(3).map(\.displayName) == ["Ember", "Zen", "Moonlit"])
        #expect(!fans.teamThemes.contains(.custom(savedThemes[0].theme)), "the oldest of four is left out")
    }

    @Test func twoThemesSavedAtTheSameMomentKeepTheOrderOfTheirIds() throws {
        let firstSavedTheme = try savedTheme(named: "Beta", id: "beta-0002", minutesAgo: 5)
        let secondSavedTheme = try savedTheme(named: "Alpha", id: "alpha-0001", minutesAgo: 5)
        let fans = SettingsDialFans(savedCustomThemes: [firstSavedTheme, secondSavedTheme])
        #expect(fans.teamThemes.suffix(2).map(\.displayName) == ["Alpha", "Beta"])
        #expect(SettingsDialFans(savedCustomThemes: [secondSavedTheme, firstSavedTheme]) == fans)
    }

    @Test func releasingOnASavedThemeCommitsThatThemeAsACustomTheme() throws {
        let savedThemes = [
            try savedTheme(named: "Ember", id: "ember-0001", minutesAgo: 1),
            try savedTheme(named: "Moonlit", id: "moonlit-0002", minutesAgo: 2),
            try savedTheme(named: "Zen", id: "zen-0003", minutesAgo: 3),
        ]
        let fans = SettingsDialFans(savedCustomThemes: savedThemes)
        let teamFanLayout = try #require(fans.layout(of: .team))
        let teamOpen = SettingsDialSelection(slice: .team, fanItemIndex: nil)
        for (savedThemeIndex, savedTheme) in savedThemes.enumerated() {
            let itemIndex = builtInTeamFanItemCount + savedThemeIndex
            let pointerOnTheBall = pointerOffset(atAngleDegrees: teamFanLayout.angleDegrees(ofItemAt: itemIndex), distance: SettingsDialGeometry.fanRadius)
            let selection = teamOpen.afterPointerMoved(to: pointerOnTheBall, fans: fans)
            #expect(selection.fanItemIndex == itemIndex, "\(savedTheme.theme.name)")
            #expect(SettingsDialChoice(committing: selection, fans: fans) == .theme(.custom(savedTheme.theme)), "\(savedTheme.theme.name)")
        }
    }

    @Test func anItemPastTheEndOfTheFanCommitsNothing() {
        // The built-in fan has 12 items, so index 12 is where a saved theme would be, and with none saved it is no item.
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .team, fanItemIndex: builtInTeamFanItemCount), fans: .builtIn) == nil)
    }

    @Test(arguments: teamFanItemCounts)
    func everyTeamFanItemPicksItselfAndTheFanStaysOpenAsThePointerTravelsOutward(itemCount: Int) throws {
        let fans = try fansWithSavedThemes(named: (0..<(itemCount - builtInTeamFanItemCount)).map { "Saved \($0)" })
        #expect(fans.teamThemes.count == itemCount)
        let teamFanLayout = try #require(fans.layout(of: .team))
        #expect(teamFanLayout.itemCount == itemCount)
        // The ends do not move as items are added, so Clicky blue keeps the room its label needs.
        #expect(abs(teamFanLayout.angleDegrees(ofItemAt: 0) - -168) < 0.000_001)
        #expect(abs(teamFanLayout.angleDegrees(ofItemAt: itemCount - 1) - -12) < 0.000_001)

        let teamOpen = SettingsDialSelection(slice: .team, fanItemIndex: nil)
        for itemIndex in 0..<itemCount {
            let pointerOnTheBall = pointerOffset(atAngleDegrees: teamFanLayout.angleDegrees(ofItemAt: itemIndex), distance: SettingsDialGeometry.fanRadius)
            let selection = teamOpen.afterPointerMoved(to: pointerOnTheBall, fans: fans)
            #expect(selection.slice == .team)
            #expect(selection.fanItemIndex == itemIndex)
            #expect(SettingsDialChoice(committing: selection, fans: fans) == .theme(fans.teamThemes[itemIndex]))
        }
        // Travelling outward along any other token's angle keeps Team's fan open.
        for slice in SettingsDialSlice.allCases where slice != .team {
            let beyondThePlate = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: slice.angleDegrees, distance: beyondThePlateDistance), fans: fans)
            #expect(beyondThePlate.slice == .team, "\(slice)")
        }
        // An angle past the last item picks no item, however many items the fan holds.
        let pastTheLastItem = teamOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: 20, distance: SettingsDialGeometry.fanRadius), fans: fans)
        #expect(pastTheLastItem.fanItemIndex == nil)
    }

    @Test(arguments: teamFanItemCounts)
    func noFanBallTouchesItsNeighborWhenOneOfThemIsEnlarged(itemCount: Int) throws {
        let fans = try fansWithSavedThemes(named: (0..<(itemCount - builtInTeamFanItemCount)).map { "Saved \($0)" })
        let enlargedRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        let ordinaryRadius = SettingsDialGeometry.fanBallDiameter / 2
        for itemIndex in 1..<itemCount {
            let gapBetweenCenters = hypot(
                teamFanBallCenter(itemIndex: itemIndex, in: fans).x - teamFanBallCenter(itemIndex: itemIndex - 1, in: fans).x,
                teamFanBallCenter(itemIndex: itemIndex, in: fans).y - teamFanBallCenter(itemIndex: itemIndex - 1, in: fans).y
            )
            #expect(gapBetweenCenters > enlargedRadius + ordinaryRadius + 2, "items \(itemIndex - 1) and \(itemIndex) of \(itemCount)")
        }
    }
}

// MARK: - Labels

/// The distance from a point to a rectangle, zero when the point is inside it.
private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let nearestX = min(max(point.x, rect.minX), rect.maxX)
    let nearestY = min(max(point.y, rect.minY), rect.maxY)
    return hypot(point.x - nearestX, point.y - nearestY)
}

private func rect(centeredAt center: CGPoint, size: CGSize) -> CGRect {
    CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
}

/// The window around the dial's center, as offsets from the center with y growing down.
private var dialWindowOffsets: CGRect {
    CGRect(
        x: -SettingsDialPlacement.reachLeft,
        y: -SettingsDialPlacement.reachAbove,
        width: SettingsDialPlacement.reachLeft + SettingsDialPlacement.reachRight,
        height: SettingsDialPlacement.reachAbove + SettingsDialPlacement.reachBelow
    )
}

struct SettingsDialLabelTests {

    @Test(arguments: teamFanItemCounts)
    func everyTeamFanLabelFitsInsideTheWindowAndCoversNoBall(itemCount: Int) throws {
        // Every saved theme has the widest name a theme can have, which is the hardest label to fit.
        let fans = try fansWithSavedThemes(named: Array(repeating: widestPossibleThemeName, count: itemCount - builtInTeamFanItemCount))
        let emphasizedBallRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        let otherBallRadius = SettingsDialGeometry.fanBallDiameter / 2
        let ballCenters = fans.teamThemes.indices.map { teamFanBallCenter(itemIndex: $0, in: fans) }
        for (itemIndex, theme) in fans.teamThemes.enumerated() {
            let labelText = SettingsDialLabel.fanLabelText(theme.displayName, ballCenterOffset: ballCenters[itemIndex], ballRadius: emphasizedBallRadius)
            let pillSize = SettingsDialLabel.pillSize(forText: labelText)
            let pillCenter = SettingsDialLabel.fanLabelCenterOffset(
                ballCenterOffset: ballCenters[itemIndex],
                ballRadius: emphasizedBallRadius,
                labelPillSize: pillSize
            )
            let pillRect = rect(centeredAt: pillCenter, size: pillSize)
            let itemDescription = "\(theme.displayName) at \(itemIndex) of \(itemCount)"

            // "Shiratorizawa", "Aoba Johsai", and "Clicky blue" are the long built-in ones, and none of them is cut.
            if itemIndex < builtInTeamFanItemCount {
                #expect(labelText == theme.displayName, "\(itemDescription) was cut")
            }
            #expect(dialWindowOffsets.contains(pillRect), "\(itemDescription) sticks out of the dial's window")
            #expect(distance(from: ballCenters[itemIndex], to: pillRect) >= emphasizedBallRadius, "\(itemDescription) covers its own ball")
            for (otherIndex, otherBallCenter) in ballCenters.enumerated() where otherIndex != itemIndex {
                #expect(distance(from: otherBallCenter, to: pillRect) >= otherBallRadius, "\(itemDescription) covers the ball at \(otherIndex)")
            }
        }
    }

    @Test func aLongSavedNameIsCutWithAnEllipsisAndAShortOneIsNot() throws {
        // The saved themes are items 12, 13, and 14 of 15, at -34, -23, and -12 degrees, in the order of these names.
        let fans = try fansWithSavedThemes(named: [widestPossibleThemeName, "Ember", "Moonlit Harbor"])
        let emphasizedBallRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        func labelText(forItemAt itemIndex: Int) -> String {
            SettingsDialLabel.fanLabelText(
                fans.teamThemes[itemIndex].displayName,
                ballCenterOffset: teamFanBallCenter(itemIndex: itemIndex, in: fans),
                ballRadius: emphasizedBallRadius
            )
        }
        let widestNameLabel = labelText(forItemAt: builtInTeamFanItemCount)
        #expect(widestNameLabel.hasSuffix("…"))
        #expect(widestNameLabel.count > 2, "the cut keeps some of the name")
        #expect(widestNameLabel.count < widestPossibleThemeName.count)
        #expect(labelText(forItemAt: builtInTeamFanItemCount + 1) == "Ember")
        // The last item has the least room, and it still keeps the first word of a 14 character name.
        #expect(labelText(forItemAt: builtInTeamFanItemCount + 2).hasPrefix("Moonlit"))
    }

    @Test func aCutNameNeverShowsASpaceBeforeTheEllipsis() {
        let rightEndBallCenter = CGPoint(
            x: cos(-12 * .pi / 180) * SettingsDialGeometry.fanRadius,
            y: sin(-12 * .pi / 180) * SettingsDialGeometry.fanRadius
        )
        // As the run of narrow letters before the space grows by one, the cut moves one letter at a time, so it lands right
        // after the space for one of these names, where an untrimmed cut would read "iiiiiiiiiiiiii …".
        var cutNameCount = 0
        for narrowLetterCount in 1...30 {
            let fullName = String(repeating: "i", count: narrowLetterCount) + " " + String(repeating: "W", count: 10)
            let labelText = SettingsDialLabel.fanLabelText(
                fullName,
                ballCenterOffset: rightEndBallCenter,
                ballRadius: SettingsDialGeometry.emphasizedFanBallDiameter / 2
            )
            if labelText.hasSuffix("…") { cutNameCount += 1 }
            #expect(!labelText.dropLast().hasSuffix(" "), "\"\(labelText)\" from \(narrowLetterCount) narrow letters")
        }
        #expect(cutNameCount > 10, "the sweep must cut most of these names for the check to mean anything")
    }

    @Test func everyTokenLabelFitsInsideTheWindowAndCoversNoToken() {
        let tokenCenters = Dictionary(uniqueKeysWithValues: SettingsDialSlice.allCases.map { slice -> (SettingsDialSlice, CGPoint) in
            let angleInRadians = slice.angleDegrees * .pi / 180
            return (slice, CGPoint(
                x: cos(angleInRadians) * SettingsDialGeometry.tokenRingRadius,
                y: sin(angleInRadians) * SettingsDialGeometry.tokenRingRadius
            ))
        })
        let titles: [SettingsDialSlice: String] = [.team: "Team", .model: "Model", .agents: "Agents", .show: "Show", .more: "More"]
        for slice in SettingsDialSlice.allCases {
            let pillSize = SettingsDialLabel.pillSize(forText: titles[slice] ?? "")
            let offsetY = SettingsDialLabel.tokenLabelCenterOffsetY(for: slice, labelPillHeight: pillSize.height)
            let pillRect = rect(centeredAt: CGPoint(x: tokenCenters[slice]!.x, y: tokenCenters[slice]!.y + offsetY), size: pillSize)

            #expect(dialWindowOffsets.contains(pillRect), "\(slice) label sticks out of the dial's window")
            #expect((offsetY < 0) == (slice == .team), "\(slice) label is on the wrong side of its token")
            for (tokenSlice, tokenCenter) in tokenCenters {
                #expect(distance(from: tokenCenter, to: pillRect) >= SettingsDialGeometry.tokenDiameter / 2, "\(slice) label covers the \(tokenSlice) token")
            }
        }
    }
}

// MARK: - Custom cursor in the dial

@MainActor
struct SettingsDialCustomCursorRenderTests {

    /// Renders at 2x and reads the pixels, since a cursor that scales on paper can still draw outside its slot or nothing.
    private func renderedPixels(of view: some View, side: CGFloat) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    @Test func aShapesCursorIsScaledToTheLongestSideItIsGivenAndLeavesTheRestOfTheSlotEmpty() throws {
        let theme = try parsedThemeIdea()
        // The star spans box x 5.2 through 18.8 on its middle row, so at 2x in a 44 point slot, the pixel at x 34 is 17 points
        // in. A 12 point cursor has not reached it, and a 44 point cursor is already past it. A cursor drawn at its natural
        // 24 points would fill the pixel in the first case, and miss it in the second.
        let smallCursorPixels = try #require(renderedPixels(
            of: SettingsDialCustomCursor(customTheme: theme, picture: nil, longestSide: 12),
            side: 44
        ))
        #expect(try #require(smallCursorPixels.colorAt(x: 44, y: 44)).alphaComponent > 0.9)
        #expect(try #require(smallCursorPixels.colorAt(x: 34, y: 44)).alphaComponent < 0.05)
        #expect(try #require(smallCursorPixels.colorAt(x: 8, y: 44)).alphaComponent < 0.05)

        let largeCursorPixels = try #require(renderedPixels(
            of: SettingsDialCustomCursor(customTheme: theme, picture: nil, longestSide: 44),
            side: 44
        ))
        #expect(try #require(largeCursorPixels.colorAt(x: 24, y: 44)).alphaComponent > 0.9)
    }

    @Test func aWidePictureCursorIsScaledToTheSlotAndNotClippedByIt() throws {
        let theme = try parsedThemeIdea(goodPictureCursorThemeIdea, pictureIsAvailable: true)
        // A solid red 80 by 20 picture draws 32 by 12 points as a cursor, so 22 by 8.25 points scaled into a 22 point slot.
        let picture = NSImage(size: NSSize(width: 80, height: 20), flipped: false) { drawingRect in
            NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            drawingRect.fill()
            return true
        }
        let pixels = try #require(renderedPixels(
            of: SettingsDialCustomCursor(customTheme: theme, picture: picture, longestSide: 22),
            side: 44
        ))
        // The picture spans pixels 22 through 66 across and about 36 through 52 down. Its outline stays inside that box.
        #expect(try #require(pixels.colorAt(x: 44, y: 44)).alphaComponent > 0.95)
        #expect(try #require(pixels.colorAt(x: 26, y: 44)).alphaComponent > 0.9)
        #expect(try #require(pixels.colorAt(x: 62, y: 44)).alphaComponent > 0.9)
        #expect(try #require(pixels.colorAt(x: 14, y: 44)).alphaComponent < 0.05)
        #expect(try #require(pixels.colorAt(x: 44, y: 24)).alphaComponent < 0.05)
    }
}
