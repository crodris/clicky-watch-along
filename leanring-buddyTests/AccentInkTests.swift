//
//  AccentInkTests.swift
//  leanring-buddyTests
//
//  Text and icons on an accent fill take whichever of near-black and white reads better on that fill. Each surface that
//  draws on an accent is rendered at 2x with a theme where one fixed color would be wrong, and its ink pixels are counted.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

/// How many pixels of a part of a 2x render are the near-black ink and how many are white. Whatever is drawn in the ink
/// is the larger count, since the part holds only the accent fill and what is drawn on it.
private struct InkPixelCounts {
    let nearBlack: Int
    let white: Int
}

@MainActor
struct AccentInkTests {
    /// Renders `view` at 2x and counts the ink pixels inside `partInPoints`, or in the whole render when nil.
    private func inkPixels(of view: some View, in partInPoints: CGRect? = nil) throws -> InkPixelCounts {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let part = partInPoints.map { CGRect(x: $0.minX * 2, y: $0.minY * 2, width: $0.width * 2, height: $0.height * 2) }
            ?? CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        var nearBlack = 0
        var white = 0
        for y in Int(part.minY)..<Int(part.maxY) {
            for x in Int(part.minX)..<Int(part.maxX) {
                guard let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.99 else { continue }
                let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                if channels.allSatisfy({ $0 < 0.12 }) { nearBlack += 1 }
                if channels.allSatisfy({ $0 > 0.92 }) { white += 1 }
            }
        }
        return InkPixelCounts(nearBlack: nearBlack, white: white)
    }

    /// A square inside the Callout's 26 point icon disc, for a Callout padded by 20 points in the render.
    private let calloutIconPart = CGRect(x: 20 + 7 + 5, y: 20 + 7 + 5, width: 16, height: 16)

    private func callout(accentHex: String, @ViewBuilder icon: () -> some View) -> some View {
        TetherCallout(accent: Color(hex: accentHex), rim: .chip, icon: icon) {
            Text("Turning it left")
        }
        .fixedSize()
        .padding(20)
    }

    @Test func theSceneStylesheetCarriesTheInkOfItsAccent() {
        let shiratorizawaScript = sceneStyleUserScriptSource(styleSheet: "", accentHex: "#A0457F")
        #expect(shiratorizawaScript.contains(##"root.style.setProperty("--clicky-accent-ink", "#FFFFFF");"##))
        let clickyBlueScript = sceneStyleUserScriptSource(styleSheet: "", accentHex: "#3380FF")
        #expect(clickyBlueScript.contains(##"root.style.setProperty("--clicky-accent-ink", "#0B0C0E");"##))
    }

    @Test func theCalloutsIconsAreWhiteOnADarkAccentAndNearBlackOnABrightOne() throws {
        let cursorIconOnShiratorizawa = try inkPixels(of: callout(accentHex: "#A0457F") { TetherCalloutCursorIcon() }, in: calloutIconPart)
        #expect(cursorIconOnShiratorizawa.white > 20 && cursorIconOnShiratorizawa.nearBlack == 0)
        let crossIconOnShiratorizawa = try inkPixels(of: callout(accentHex: "#A0457F") { TetherCalloutCrossIcon() }, in: calloutIconPart)
        #expect(crossIconOnShiratorizawa.white > 20 && crossIconOnShiratorizawa.nearBlack == 0)
        let symbolOnShiratorizawa = try inkPixels(of: callout(accentHex: "#A0457F") { Image(systemName: "hand.point.up.left.fill") }, in: calloutIconPart)
        #expect(symbolOnShiratorizawa.white > 20 && symbolOnShiratorizawa.nearBlack == 0)
        let cursorIconOnClickyBlue = try inkPixels(of: callout(accentHex: "#3380FF") { TetherCalloutCursorIcon() }, in: calloutIconPart)
        #expect(cursorIconOnClickyBlue.nearBlack > 20 && cursorIconOnClickyBlue.white == 0)
    }

    @Test func thePrimaryButtonsLettersReadOnTheirAccent() throws {
        // Nekoma's red is the closest call: white reads at 4.49 and near-black at 4.35.
        let studioButtonOnNekoma = try inkPixels(of: ThemeStudioButton(title: "Save", style: .primary(accentHex: "#E0313B"), isEnabled: true) {})
        #expect(studioButtonOnNekoma.white > 20 && studioButtonOnNekoma.nearBlack == 0)
        let studioButtonOnClickyBlue = try inkPixels(of: ThemeStudioButton(title: "Save", style: .primary(accentHex: "#3380FF"), isEnabled: true) {})
        #expect(studioButtonOnClickyBlue.nearBlack > 20 && studioButtonOnClickyBlue.white == 0)
        let panelButtonOnShiratorizawa = try inkPixels(of: PanelButton(title: "Start Clicky", prominence: .primary, accentColor: Color(hex: "#A0457F")) {})
        #expect(panelButtonOnShiratorizawa.white > 20 && panelButtonOnShiratorizawa.nearBlack == 0)
    }

    /// Date Tech's file names white as its contrast color, and white reads at 3.05 on its teal where near-black reads at 6.42.
    @Test func aRosterFacesInitialsReadOnTheAccentWhateverTheThemesContrastColorIs() throws {
        let dateTech = bundledTheme("school-date-tech")
        guard case .roster(let players) = dateTech.agents.faces else {
            Issue.record("school-date-tech has no roster")
            return
        }
        // No portrait file in the idea's folder, so the face draws the initials.
        let player = try #require(players.first)
        let face = AgentRosterFace(player: player, of: dateTech.with(id: dateTech.id, origin: .idea))
        let initials = try inkPixels(of: RosterFaceView(rosterFace: face, size: 40), in: CGRect(x: 8, y: 8, width: 24, height: 24))
        #expect(initials.nearBlack > 20 && initials.white == 0)
    }

    private func dialView(theme: ClickyTheme) -> SettingsDialView {
        let viewModel = SettingsDialViewModel(
            snapshot: SettingsDialSnapshot(
                theme: theme,
                themePicture: nil,
                modelID: SettingsDialModelChoice.allCases[0].modelID,
                isClickyCursorEnabled: true,
                runningAgentCount: 0,
                fans: SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
            ),
            showsTheFirstRunHint: false,
            reduceMotion: true
        )
        viewModel.isPresented = true
        viewModel.selection = SettingsDialSelection(slice: .model, fanItemIndex: nil)
        return SettingsDialView(viewModel: viewModel)
    }

    /// The middle of the selected Model token, where its icon is drawn.
    private var selectedModelTokenIconPart: CGRect {
        let angle = SettingsDialSlice.model.angleDegrees * .pi / 180
        let center = CGPoint(
            x: SettingsDialPlacement.reachLeft + cos(angle) * SettingsDialGeometry.tokenRingRadius,
            y: SettingsDialPlacement.reachAbove + sin(angle) * SettingsDialGeometry.tokenRingRadius
        )
        return CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
    }

    @Test func theSettingsDialsSelectedTokenDrawsItsIconInTheAccentsInk() throws {
        // Clicky blue's contrast color is white, which reads worse on its blue than near-black does.
        let onClickyBlue = try inkPixels(of: dialView(theme: clickyBlueTheme), in: selectedModelTokenIconPart)
        #expect(onClickyBlue.nearBlack > 20 && onClickyBlue.white == 0)
        let onShiratorizawa = try inkPixels(of: dialView(theme: bundledTheme("school-shiratorizawa")), in: selectedModelTokenIconPart)
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
    }
}
