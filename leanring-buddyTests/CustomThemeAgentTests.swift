//
//  CustomThemeAgentTests.swift
//  leanring-buddyTests
//
//  What a custom theme changes about the background agents: the colors each new agent takes from the theme's own list,
//  the picture face, the ring and chip that follow, and the saved theme (not the studio's preview) deciding it all.
//

import Foundation
import SwiftUI
import Testing
@testable import Clicky

@MainActor
struct CustomThemeAgentTests {
    private func themeColor(_ hex: String) -> AgentPaletteColor {
        .custom(ThemeRGBColor(hex: hex)!)
    }

    private func customTheme(usesPicture: Bool = false) throws -> ClickyTheme {
        let idea = usesPicture ? goodPictureCursorThemeIdea : goodThemeIdea
        // A saved theme's origin, since only a saved theme has a picture.jpg to give its agents as a face.
        return try ClickyTheme.parse(themeJSON: idea, id: "moonlit-3f9a", origin: .saved(folderURL: URL(fileURLWithPath: "/tmp/moonlit-3f9a")), pictureIsAvailable: usesPicture)
    }

    @Test func aNewAgentTakesTheFirstThemeColorNoOneHasAndThenCyclesThroughThem() {
        let hexes = ["#7DD3FC", "#C4B5FD", "#FDE68A"]
        var colorsInUse: [AgentPaletteColor] = []
        for _ in 0..<3 {
            colorsInUse.append(agentPaletteColorToAssign(forCustomThemeAgentColorHexes: hexes, colorsInUse: colorsInUse))
        }
        #expect(colorsInUse == [themeColor("#7DD3FC"), themeColor("#C4B5FD"), themeColor("#FDE68A")])
        // All three are in use, so the next agents start over from the first.
        #expect(agentPaletteColorToAssign(forCustomThemeAgentColorHexes: hexes, colorsInUse: colorsInUse) == themeColor("#7DD3FC"))
        colorsInUse.append(themeColor("#7DD3FC"))
        #expect(agentPaletteColorToAssign(forCustomThemeAgentColorHexes: hexes, colorsInUse: colorsInUse) == themeColor("#C4B5FD"))
    }

    @Test func aThemeColorThatAFixedPaletteColorHoldsDoesNotCountAsInUse() {
        // Agents started under Clicky blue before the theme changed hold fixed colors, which are never a theme's.
        let hexes = ["#7DD3FC", "#C4B5FD", "#FDE68A"]
        #expect(agentPaletteColorToAssign(forCustomThemeAgentColorHexes: hexes, colorsInUse: [.teal, .amber]) == themeColor("#7DD3FC"))
    }

    @Test func agentsStartedUnderACustomThemeGetItsColorsAndNoPlayer() throws {
        let store = makeBackgroundAgentStore(theme: try customTheme())
        let firstAgentID = store.start(kind: .task)
        let secondAgentID = store.start(kind: .studyGuide)
        #expect(store.agents.first { $0.id == firstAgentID }?.tokenColor == themeColor("#7DD3FC"))
        #expect(store.agents.first { $0.id == secondAgentID }?.tokenColor == themeColor("#C4B5FD"))
        #expect(store.agents.allSatisfy { $0.rosterFace == nil })
        #expect(store.face(for: firstAgentID) == .triangle)
        // A later agent never recolors an agent that already has its color.
        store.start(kind: .task)
        #expect(store.agents.first { $0.id == firstAgentID }?.tokenColor == themeColor("#7DD3FC"))
    }

    @Test func aThemeThatUsesThePictureGivesItsAgentsThePictureFace() throws {
        let store = makeBackgroundAgentStore(theme: try customTheme(usesPicture: true))
        let agentID = store.start(kind: .task)
        #expect(store.face(for: agentID) == .themePicture(themeID: "moonlit-3f9a"))
    }

    @Test func aFacelessAgentIsATriangleAndAPlayerAgentKeepsItsPlayer() throws {
        let clickyBlueStore = makeBackgroundAgentStore()
        #expect(clickyBlueStore.face(for: clickyBlueStore.start(kind: .task)) == .triangle)
        let karasuno = bundledTheme("school-karasuno")
        let schoolStore = makeBackgroundAgentStore(theme: karasuno)
        let player = try #require(rosterPlayers(of: karasuno).first)
        #expect(schoolStore.face(for: schoolStore.start(kind: .task)) == .rosterFace(AgentRosterFace(player: player, of: karasuno)))
    }

    @Test func theStudiosPreviewNeverColorsAnAgent() throws {
        let themeSettings = makeThemeSettings()
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        themeSettings.preview(try customTheme(), picture: nil)
        let agentID = store.start(kind: .task)
        // The saved theme is still Clicky blue, so the agent takes the fixed palette's teal.
        #expect(store.agents.first { $0.id == agentID }?.tokenColor == .teal)
    }

    @Test func theRingAndTheChipFollowTheAgentsThemeColor() throws {
        let store = makeBackgroundAgentStore(theme: try customTheme())
        let agentID = store.start(kind: .task)
        let agent = try #require(store.agents.first { $0.id == agentID })
        #expect(agentTokenRingColorChoice(for: agent) == .assigned(themeColor("#7DD3FC")))
        #expect(store.displayColor(for: agentID) == themeColor("#7DD3FC"))
        store.fail(agentID, reason: "x")
        let failedAgent = try #require(store.agents.first { $0.id == agentID })
        #expect(agentTokenRingColorChoice(for: failedAgent) == .failed)
    }

    @Test func theChipsIconIsRoundForAThemePictureAndATileForATriangle() {
        #expect(VoiceToolCallChipSender.backgroundAgent(color: .teal, face: .themePicture(themeID: "moonlit-3f9a")).iconShape == .circularPortrait)
        #expect(VoiceToolCallChipSender.backgroundAgent(color: themeColor("#7DD3FC"), face: .triangle).iconShape == .roundedSquareTile)
    }


    @Test func aThemeColorsChipLettersAreHalfAsBrightAsTheColor() {
        let chipColor = themeColor("#7DD3FC").chipTextColor
        #expect(chipColor == Color(red: 0x7D / 255.0 * 0.5, green: 0xD3 / 255.0 * 0.5, blue: 0xFC / 255.0 * 0.5))
    }
}
