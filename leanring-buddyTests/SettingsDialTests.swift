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

/// The fans with no saved theme: the bundled themes from themes/.
private extension SettingsDialFans {
    static let builtIn = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
}

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
        // Theme is at -90 and Model at -18, so the halfway angle is -54, and each side flips one degree past it.
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -55, distance: insideThePlateDistance)).slice == .theme)
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -53, distance: insideThePlateDistance)).slice == .model)
        // More is at 198, which atan2 reports as -162. Its halfway angle to Theme is -126.
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -162, distance: insideThePlateDistance)).slice == .more)
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -127, distance: insideThePlateDistance)).slice == .more)
        #expect(nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -125, distance: insideThePlateDistance)).slice == .theme)
    }

    @Test func theCenterPicksNothingAndClearsAnEarlierPick() {
        let themeHighlighted = SettingsDialSelection(slice: .theme, fanItemIndex: 3)
        let selectionInTheCenter = themeHighlighted.afterPointerMoved(to: CGVector(dx: 10, dy: -10))
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

        // Beyond the plate at Theme's angle opens its fan, with no item picked yet.
        let flickedToTheme = nothingHighlighted.afterPointerMoved(to: pointerOffset(atAngleDegrees: -90, distance: SettingsDialGeometry.plateRadius + 1))
        #expect(flickedToTheme.slice == .theme)
        #expect(flickedToTheme.openFanLayout(in: .builtIn) != nil)
    }

    @Test func theThemeFanPicksEachBallWithClickyBlueFirst() throws {
        let themeFanLayout = try #require(SettingsDialFans.builtIn.layout(of: .theme))
        #expect(themeFanLayout.itemCount == bundledThemesForTests.count)
        #expect(themeFanLayout.angleDegrees(ofItemAt: 0) == -168)
        #expect(abs(themeFanLayout.angleDegrees(ofItemAt: themeFanLayout.itemCount - 1) - -12) < 0.000_001)

        let themeOpen = SettingsDialSelection(slice: .theme, fanItemIndex: nil)
        for itemIndex in 0..<themeFanLayout.itemCount {
            let pointerOnTheBall = pointerOffset(atAngleDegrees: themeFanLayout.angleDegrees(ofItemAt: itemIndex), distance: SettingsDialGeometry.fanRadius)
            let selection = themeOpen.afterPointerMoved(to: pointerOnTheBall)
            #expect(selection.slice == .theme)
            #expect(selection.fanItemIndex == itemIndex)
            #expect(SettingsDialChoice(committing: selection) == .theme(bundledThemesForTests[itemIndex]))
        }
        #expect(bundledThemesForTests.first == clickyBlueTheme)
        #expect(bundledThemesForTests.count == 11)
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
        // Theme's fan is open and the pointer goes outward at Agents' angle: the slice must stay Theme, and no item is under it.
        let themeOpen = SettingsDialSelection(slice: .theme, fanItemIndex: nil)
        let acrossAgentsAngle = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.agents.angleDegrees, distance: beyondThePlateDistance))
        #expect(acrossAgentsAngle.slice == .theme)
        #expect(acrossAgentsAngle.fanItemIndex == nil)
        #expect(SettingsDialChoice(committing: acrossAgentsAngle) == nil)

        // Travelling outward along Model's angle keeps Theme open and picks Theme's item at that angle, never a Model item.
        let acrossModelAngle = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.model.angleDegrees, distance: beyondThePlateDistance))
        #expect(acrossModelAngle.slice == .theme)

        // Coming back inside the plate at Agents' angle is what changes the slice.
        let backInsideAtAgents = acrossAgentsAngle.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.agents.angleDegrees, distance: insideThePlateDistance))
        #expect(backInsideAtAgents.slice == .agents)
        #expect(backInsideAtAgents.fanItemIndex == nil)
    }

    @Test func thePlateBoundaryDecidesBetweenPickingASliceAndPickingAFanItem() throws {
        // The fan's spacing divides by the number of themes read from themes/. Fewer than 2 themes leave no ball at the
        // expected angle, so name that here instead of failing on a pick.
        #expect(bundledThemesForTests.count >= 2, "themes/ loaded only \(bundledThemesForTests.count) themes, so the Theme fan has no spacing")
        let themeOpen = SettingsDialSelection(slice: .theme, fanItemIndex: nil)
        let themeFanLayout = try #require(SettingsDialFans.builtIn.layout(of: .theme), "the built-in fans have no Theme layout")
        let angleOfClickyBlueBall = themeFanLayout.angleDegrees(ofItemAt: 0)
        // On the plate's edge the pointer is still inside, so it picks the slice at that angle, which is Show here.
        let onTheEdge = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: SettingsDialSlice.show.angleDegrees, distance: SettingsDialGeometry.plateRadius))
        #expect(onTheEdge.slice == .show)
        // One point past it the open fan takes over.
        let pastTheEdge = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: angleOfClickyBlueBall, distance: SettingsDialGeometry.plateRadius + 1))
        #expect(pastTheEdge.slice == .theme)
        #expect(pastTheEdge.fanItemIndex == 0)
    }

    @Test func anAngleBeyondTheEndOfTheFanPicksNoItem() {
        let themeOpen = SettingsDialSelection(slice: .theme, fanItemIndex: nil)
        // The fan ends at -12 degrees and its items are about 16 degrees apart, so 20 degrees is past the last ball.
        let pastTheLastBall = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: 20, distance: SettingsDialGeometry.fanRadius))
        #expect(pastTheLastBall.slice == .theme)
        #expect(pastTheLastBall.fanItemIndex == nil)
    }

    @Test func wanderingPastThePickingRadiusPicksNothingButKeepsAnOpenFanOpen() {
        let themeWithAnItem = SettingsDialSelection(slice: .theme, fanItemIndex: 4)
        let farAway = themeWithAnItem.afterPointerMoved(to: pointerOffset(atAngleDegrees: -100, distance: SettingsDialGeometry.pickingOuterRadius + 1))
        #expect(farAway.slice == .theme)
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
        // Theme and Model commit only an item of their fan.
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .theme, fanItemIndex: nil)) == nil)
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .model, fanItemIndex: nil)) == nil)
    }

    @Test func aDialShiftedOffThePointerPicksNothingUntilThePointerMoves() {
        // An edge moved the dial so the pointer starts 190 points above its center, in the Theme fan's area.
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
        #expect(picker.selection.slice == .theme)
    }
}

struct SettingsDialPlacementTests {
    @MainActor
    @Test func theFirstRunHintSaysHowToPick() {
        #expect(SettingsDialView.firstRunHintText == "Hold ⇧⌥ · flick, release to pick")
    }

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


// MARK: - Saved themes in the Theme fan

/// The moment the saved-theme tests count back from, so no test depends on the clock.
private let referenceSavedDate = Date(timeIntervalSinceReferenceDate: 1_000_000)

/// A saved theme named `themeName`, saved `minutesAgo` minutes before the reference moment.
private func savedTheme(named themeName: String, id themeID: String, minutesAgo: Double) throws -> SavedCustomTheme {
    let idea = replacingField(in: goodThemeIdea, at: ["name"], with: .string(themeName))
    return SavedCustomTheme(
        theme: try ClickyTheme.parse(themeJSON: idea, id: themeID, pictureIsAvailable: false),
        savedDate: referenceSavedDate.addingTimeInterval(-minutesAgo * 60)
    )
}

/// Fans whose saved themes carry `themeNames` in order, the first saved last, so the Theme fan lists them in that order
/// after the bundled themes.
private func fansWithSavedThemes(named themeNames: [String]) throws -> SettingsDialFans {
    let savedThemes = try themeNames.enumerated().map { themeIndex, themeName in
        try savedTheme(named: themeName, id: "theme-\(themeIndex)", minutesAgo: Double(themeIndex))
    }
    return SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: savedThemes)
}

/// A name of the 24 characters a saved theme may have, in the widest letter, so it is the widest label any theme can make.
private let widestPossibleThemeName = String(repeating: "W", count: 24)

private let builtInThemeFanItemCount = bundledThemesForTests.count
/// The Theme fan holds 11 items with no saved theme and 14 with three.
private let themeFanItemCounts = [11, 12, 13, 14]

private func themeFanBallCenter(itemIndex: Int, in fans: SettingsDialFans) -> CGPoint {
    let angleInRadians = (fans.layout(of: .theme)?.angleDegrees(ofItemAt: itemIndex) ?? 0) * .pi / 180
    return CGPoint(
        x: cos(angleInRadians) * SettingsDialGeometry.fanRadius,
        y: sin(angleInRadians) * SettingsDialGeometry.fanRadius
    )
}

struct SettingsDialSavedThemeFanTests {

    @Test func withNoSavedThemeTheThemeFanIsTheBundledThemes() {
        let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
        #expect(fans == .builtIn)
        #expect(fans.themeFanThemes == bundledThemesForTests)
        #expect(fans.layout(of: .theme)?.itemCount == 11)
    }

    @Test func theNewestThreeSavedThemesFollowTheBundledOnesNewestFirst() throws {
        // Handed over in name order, as the store lists them, so the order below comes from the dates alone.
        let savedThemes = [
            try savedTheme(named: "Aurora", id: "aurora-0001", minutesAgo: 500),
            try savedTheme(named: "Ember", id: "ember-0002", minutesAgo: 3),
            try savedTheme(named: "Moonlit", id: "moonlit-0003", minutesAgo: 90),
            try savedTheme(named: "Zen", id: "zen-0004", minutesAgo: 40),
        ]
        let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: savedThemes)
        #expect(Array(fans.themeFanThemes.prefix(bundledThemesForTests.count)) == bundledThemesForTests)
        #expect(fans.themeFanThemes.last.map(\.name) == "Moonlit")
        #expect(fans.themeFanThemes.suffix(3).map(\.name) == ["Ember", "Zen", "Moonlit"])
        #expect(!fans.themeFanThemes.contains(savedThemes[0].theme), "the oldest of four is left out")
    }

    @Test func twoThemesSavedAtTheSameMomentKeepTheOrderOfTheirIds() throws {
        let firstSavedTheme = try savedTheme(named: "Beta", id: "beta-0002", minutesAgo: 5)
        let secondSavedTheme = try savedTheme(named: "Alpha", id: "alpha-0001", minutesAgo: 5)
        let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [firstSavedTheme, secondSavedTheme])
        #expect(fans.themeFanThemes.suffix(2).map(\.name) == ["Alpha", "Beta"])
        #expect(SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [secondSavedTheme, firstSavedTheme]) == fans)
    }

    @Test func releasingOnASavedThemeCommitsThatThemeAsACustomTheme() throws {
        let savedThemes = [
            try savedTheme(named: "Ember", id: "ember-0001", minutesAgo: 1),
            try savedTheme(named: "Moonlit", id: "moonlit-0002", minutesAgo: 2),
            try savedTheme(named: "Zen", id: "zen-0003", minutesAgo: 3),
        ]
        let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: savedThemes)
        let themeFanLayout = try #require(fans.layout(of: .theme))
        let themeOpen = SettingsDialSelection(slice: .theme, fanItemIndex: nil)
        for (savedThemeIndex, savedTheme) in savedThemes.enumerated() {
            let itemIndex = builtInThemeFanItemCount + savedThemeIndex
            let pointerOnTheBall = pointerOffset(atAngleDegrees: themeFanLayout.angleDegrees(ofItemAt: itemIndex), distance: SettingsDialGeometry.fanRadius)
            let selection = themeOpen.afterPointerMoved(to: pointerOnTheBall, fans: fans)
            #expect(selection.fanItemIndex == itemIndex, "\(savedTheme.theme.name)")
            #expect(SettingsDialChoice(committing: selection, fans: fans) == .theme(savedTheme.theme), "\(savedTheme.theme.name)")
        }
    }

    @Test func anItemPastTheEndOfTheFanCommitsNothing() {
        // The built-in fan has 11 items, so index 11 is where a saved theme would be, and with none saved it is no item.
        #expect(SettingsDialChoice(committing: SettingsDialSelection(slice: .theme, fanItemIndex: builtInThemeFanItemCount), fans: .builtIn) == nil)
    }

    @Test(arguments: themeFanItemCounts)
    func everyThemeFanItemPicksItselfAndTheFanStaysOpenAsThePointerTravelsOutward(itemCount: Int) throws {
        let fans = try fansWithSavedThemes(named: (0..<(itemCount - builtInThemeFanItemCount)).map { "Saved \($0)" })
        #expect(fans.themeFanThemes.count == itemCount)
        let themeFanLayout = try #require(fans.layout(of: .theme))
        #expect(themeFanLayout.itemCount == itemCount)
        // The ends do not move as items are added, so Clicky blue keeps the room its label needs.
        #expect(abs(themeFanLayout.angleDegrees(ofItemAt: 0) - -168) < 0.000_001)
        #expect(abs(themeFanLayout.angleDegrees(ofItemAt: itemCount - 1) - -12) < 0.000_001)

        let themeOpen = SettingsDialSelection(slice: .theme, fanItemIndex: nil)
        for itemIndex in 0..<itemCount {
            let pointerOnTheBall = pointerOffset(atAngleDegrees: themeFanLayout.angleDegrees(ofItemAt: itemIndex), distance: SettingsDialGeometry.fanRadius)
            let selection = themeOpen.afterPointerMoved(to: pointerOnTheBall, fans: fans)
            #expect(selection.slice == .theme)
            #expect(selection.fanItemIndex == itemIndex)
            #expect(SettingsDialChoice(committing: selection, fans: fans) == .theme(fans.themeFanThemes[itemIndex]))
        }
        // Travelling outward along any other token's angle keeps Theme's fan open.
        for slice in SettingsDialSlice.allCases where slice != .theme {
            let beyondThePlate = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: slice.angleDegrees, distance: beyondThePlateDistance), fans: fans)
            #expect(beyondThePlate.slice == .theme, "\(slice)")
        }
        // An angle past the last item picks no item, however many items the fan holds.
        let pastTheLastItem = themeOpen.afterPointerMoved(to: pointerOffset(atAngleDegrees: 20, distance: SettingsDialGeometry.fanRadius), fans: fans)
        #expect(pastTheLastItem.fanItemIndex == nil)
    }

    @Test(arguments: themeFanItemCounts)
    func noFanBallTouchesItsNeighborWhenOneOfThemIsEnlarged(itemCount: Int) throws {
        let fans = try fansWithSavedThemes(named: (0..<(itemCount - builtInThemeFanItemCount)).map { "Saved \($0)" })
        let enlargedRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        let ordinaryRadius = SettingsDialGeometry.fanBallDiameter / 2
        for itemIndex in 1..<itemCount {
            let gapBetweenCenters = hypot(
                themeFanBallCenter(itemIndex: itemIndex, in: fans).x - themeFanBallCenter(itemIndex: itemIndex - 1, in: fans).x,
                themeFanBallCenter(itemIndex: itemIndex, in: fans).y - themeFanBallCenter(itemIndex: itemIndex - 1, in: fans).y
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

    @Test(arguments: themeFanItemCounts)
    func everyThemeFanLabelFitsInsideTheWindowAndCoversNoBall(itemCount: Int) throws {
        // Every saved theme has the widest name a theme can have, which is the hardest label to fit.
        let fans = try fansWithSavedThemes(named: Array(repeating: widestPossibleThemeName, count: itemCount - builtInThemeFanItemCount))
        let emphasizedBallRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        let otherBallRadius = SettingsDialGeometry.fanBallDiameter / 2
        let ballCenters = fans.themeFanThemes.indices.map { themeFanBallCenter(itemIndex: $0, in: fans) }
        for (itemIndex, theme) in fans.themeFanThemes.enumerated() {
            let labelText = SettingsDialLabel.fanLabelText(theme.name, ballCenterOffset: ballCenters[itemIndex], ballRadius: emphasizedBallRadius)
            let pillSize = SettingsDialLabel.pillSize(forText: labelText)
            let pillCenter = SettingsDialLabel.fanLabelCenterOffset(
                ballCenterOffset: ballCenters[itemIndex],
                ballRadius: emphasizedBallRadius,
                labelPillSize: pillSize
            )
            let pillRect = rect(centeredAt: pillCenter, size: pillSize)
            let itemDescription = "\(theme.name) at \(itemIndex) of \(itemCount)"

            // "Shiratorizawa", "Aoba Johsai", and "Clicky blue" are the long built-in ones, and none of them is cut.
            if itemIndex < builtInThemeFanItemCount {
                #expect(labelText == theme.name, "\(itemDescription) was cut")
            }
            #expect(dialWindowOffsets.contains(pillRect), "\(itemDescription) sticks out of the dial's window")
            #expect(distance(from: ballCenters[itemIndex], to: pillRect) >= emphasizedBallRadius, "\(itemDescription) covers its own ball")
            for (otherIndex, otherBallCenter) in ballCenters.enumerated() where otherIndex != itemIndex {
                #expect(distance(from: otherBallCenter, to: pillRect) >= otherBallRadius, "\(itemDescription) covers the ball at \(otherIndex)")
            }
        }
    }

    @Test func aLongSavedNameIsCutWithAnEllipsisAndAShortOneIsNot() throws {
        // The saved themes are items 11, 12, and 13 of 14, at -36, -24, and -12 degrees, in the order of these names.
        let fans = try fansWithSavedThemes(named: [widestPossibleThemeName, "Ember", "Moonlit Harbor"])
        let emphasizedBallRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        func labelText(forItemAt itemIndex: Int) -> String {
            SettingsDialLabel.fanLabelText(
                fans.themeFanThemes[itemIndex].name,
                ballCenterOffset: themeFanBallCenter(itemIndex: itemIndex, in: fans),
                ballRadius: emphasizedBallRadius
            )
        }
        let widestNameLabel = labelText(forItemAt: builtInThemeFanItemCount)
        #expect(widestNameLabel.hasSuffix("…"))
        #expect(widestNameLabel.count > 2, "the cut keeps some of the name")
        #expect(widestNameLabel.count < widestPossibleThemeName.count)
        #expect(labelText(forItemAt: builtInThemeFanItemCount + 1) == "Ember")
        // The last item has the least room, and it still keeps the first word of a 14 character name.
        #expect(labelText(forItemAt: builtInThemeFanItemCount + 2).hasPrefix("Moonlit"))
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

    @Test func theTokensAreNamedThemeModelAgentsShowAndMoreClockwiseFromTheTop() {
        #expect(SettingsDialSlice.allCases.map(\.title) == ["Theme", "Model", "Agents", "Show", "More"])
        #expect(SettingsDialSlice.allCases.map(\.angleDegrees) == [-90, -18, 54, 126, 198])
    }

    @Test func everyTokenLabelFitsInsideTheWindowAndCoversNoToken() {
        let tokenCenters = Dictionary(uniqueKeysWithValues: SettingsDialSlice.allCases.map { slice -> (SettingsDialSlice, CGPoint) in
            let angleInRadians = slice.angleDegrees * .pi / 180
            return (slice, CGPoint(
                x: cos(angleInRadians) * SettingsDialGeometry.tokenRingRadius,
                y: sin(angleInRadians) * SettingsDialGeometry.tokenRingRadius
            ))
        })
        for slice in SettingsDialSlice.allCases {
            let pillSize = SettingsDialLabel.pillSize(forText: slice.title)
            let offsetY = SettingsDialLabel.tokenLabelCenterOffsetY(for: slice, labelPillHeight: pillSize.height)
            let pillRect = rect(centeredAt: CGPoint(x: tokenCenters[slice]!.x, y: tokenCenters[slice]!.y + offsetY), size: pillSize)

            #expect(dialWindowOffsets.contains(pillRect), "\(slice) label sticks out of the dial's window")
            #expect((offsetY < 0) == (slice == .theme), "\(slice) label is on the wrong side of its token")
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

// MARK: - The cursor under the dial

/// The dial draws its own cursor glyph in the center, so the overlay's cursor, which sits 35 points right of and 25 below the
/// mouse under the plate, hides while the dial is on screen. Before, it showed through the plate as the dial faded in and out.
@MainActor
struct SettingsDialBuddyTests {
    private let everyNavigationMode: [BuddyNavigationMode] = [.followingCursor, .navigatingToTarget, .pointingAtTarget]

    @Test func noBuddyDrawsOnAnyScreenInAnyModeWhileTheDialIsOnScreen() {
        for navigationMode in everyNavigationMode {
            for anotherScreensBuddyIsBusy in [false, true] {
                for isCursorOnThisScreen in [false, true] {
                    #expect(!buddyIsVisible(
                        navigationMode: navigationMode,
                        anotherScreensBuddyIsBusy: anotherScreensBuddyIsBusy,
                        isCursorOnThisScreen: isCursorOnThisScreen,
                        settingsDialIsOnScreen: true
                    ), "\(navigationMode), another screen busy \(anotherScreensBuddyIsBusy), cursor here \(isCursorOnThisScreen)")
                }
            }
        }
    }

    @Test func theBuddyDrawsAsBeforeWhenNoDialIsOnScreen() {
        func isVisible(_ navigationMode: BuddyNavigationMode, anotherScreensBuddyIsBusy: Bool = false, isCursorOnThisScreen: Bool = true) -> Bool {
            buddyIsVisible(
                navigationMode: navigationMode,
                anotherScreensBuddyIsBusy: anotherScreensBuddyIsBusy,
                isCursorOnThisScreen: isCursorOnThisScreen,
                settingsDialIsOnScreen: false
            )
        }
        // Following the mouse, it draws on the screen the mouse is on, and on no other, or while another screen's buddy is busy.
        #expect(isVisible(.followingCursor))
        #expect(!isVisible(.followingCursor, isCursorOnThisScreen: false))
        #expect(!isVisible(.followingCursor, anotherScreensBuddyIsBusy: true))
        // Flying to a target or pointing at it, the buddy draws wherever its own screen draws it.
        #expect(isVisible(.navigatingToTarget, isCursorOnThisScreen: false))
        #expect(isVisible(.pointingAtTarget, anotherScreensBuddyIsBusy: true, isCursorOnThisScreen: false))
    }

    @Test func thePresenceFollowsTheDialsWindow() {
        let presence = SettingsDialPresence()
        #expect(!presence.isOnScreen)
        presence.dialWindowIsOnScreen()
        #expect(presence.isOnScreen)
        presence.dialWindowIsGone()
        #expect(!presence.isOnScreen)
    }

    /// The real controller: the dial is on screen from `open` until its window is removed, so the overlay hides its cursor
    /// for the dial's whole life, its fade in and out included.
    @Test(.showsARealWindow)
    func theControllerTellsThePresenceFromOpenUntilItsWindowIsRemoved() throws {
        let presence = SettingsDialPresence()
        let suiteName = "SettingsDialBuddyTests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let controller = SettingsDialController(userDefaults: userDefaults, presence: presence)
        controller.open(snapshot: SettingsDialSnapshot(
            theme: clickyBlueTheme,
            themePicture: nil,
            modelID: "claude-sonnet-5-5",
            isClickyCursorEnabled: true,
            runningAgentCount: 0,
            fans: SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
        ))
        #expect(presence.isOnScreen)
        // A release that cancels keeps the window while it fades, and the presence stays until the window is removed.
        controller.close()
        #expect(presence.isOnScreen)
        controller.closeAtOnce()
        #expect(!presence.isOnScreen)
    }
}
