//
//  TetherSurfaceRenderTests.swift
//  leanring-buddyTests
//
//  The restyled dial plate and the "Add theme?" card rendered at 2x on a white page, with their pixels read: the plate is
//  opaque (a blurred plate would let the page through), its accent rim is strongest at the top, and the card's words sit
//  inside its surface. Set CLICKY_RENDER_DUMP_DIR to a folder to also write each render there as a PNG for a look.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct TetherSurfaceRenderTests {
    private func render(_ view: some View, named name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.background(Color.white))
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        if let dumpFolder = ProcessInfo.processInfo.environment["CLICKY_RENDER_DUMP_DIR"],
           let pngData = bitmap.representation(using: .png, properties: [:]) {
            try pngData.write(to: URL(fileURLWithPath: dumpFolder).appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    private func dialView(selection: SettingsDialSelection = SettingsDialSelection(slice: nil, fanItemIndex: nil)) -> SettingsDialView {
        let theme = bundledThemesForTests.first { $0.id == "school-karasuno" } ?? clickyBlueTheme
        let viewModel = SettingsDialViewModel(
            snapshot: SettingsDialSnapshot(
                theme: theme,
                themePicture: nil,
                modelID: "claude-sonnet-5-5",
                isClickyCursorEnabled: true,
                runningAgentCount: 2,
                fans: SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
            ),
            showsTheFirstRunHint: false,
            reduceMotion: true
        )
        viewModel.isPresented = true
        viewModel.selection = selection
        return SettingsDialView(viewModel: viewModel)
    }

    /// The plate's pixel at an offset from the dial's center, in points (y grows down), in the 2x render of the dial's window.
    private func pixel(in bitmap: NSBitmapImageRep, offsetFromTheCenter offset: CGPoint) -> NSColor? {
        let centerInPixels = CGPoint(x: SettingsDialPlacement.reachLeft * 2, y: SettingsDialPlacement.reachAbove * 2)
        return bitmap.colorAt(x: Int(centerInPixels.x + offset.x * 2), y: Int(centerInPixels.y + offset.y * 2))
    }

    @Test func theDialPlateIsOpaqueSoNoPageShowsThroughIt() throws {
        let bitmap = try render(dialView(), named: "dial-open")
        // Between two tokens, away from every token and the center glyph: a point on the plate at 100 points, 126 degrees
        // from Team's angle falls between Show and More. A white page behind a translucent plate would read near white.
        let plateColor = try #require(pixel(in: bitmap, offsetFromTheCenter: CGPoint(x: 0, y: 98)))
        #expect(plateColor.alphaComponent > 0.99)
        #expect(plateColor.redComponent < 0.2 && plateColor.greenComponent < 0.2 && plateColor.blueComponent < 0.2)
    }

    @Test func theAccentRimIsStrongestAtTheTopOfThePlate() throws {
        let bitmap = try render(dialView(), named: "dial-rim")
        let rimRadius = SettingsDialGeometry.plateRadius - 0.75
        // Off to the side of Team's label at the top, and in the gap between the two bottom labels, where nothing covers the rim.
        let topOffsetX: CGFloat = -45
        let rimAtTheTop = try #require(pixel(in: bitmap, offsetFromTheCenter: CGPoint(x: topOffsetX, y: -(rimRadius * rimRadius - topOffsetX * topOffsetX).squareRoot())))
        let rimAtTheBottom = try #require(pixel(in: bitmap, offsetFromTheCenter: CGPoint(x: 0, y: rimRadius)))
        func accentShare(_ color: NSColor) -> CGFloat { color.redComponent - color.blueComponent }
        // Karasuno's accent is orange (#F97316), so red leads blue, and more at the top than at the bottom.
        #expect(accentShare(rimAtTheTop) > accentShare(rimAtTheBottom) + 0.2)
    }

    @Test func theTeamFanShowsAndNamesTheHighlightedThemeOnAPillInItsOwnAccent() throws {
        let bitmap = try render(dialView(selection: SettingsDialSelection(slice: .team, fanItemIndex: 1)), named: "dial-team-fan")
        #expect(bitmap.pixelsWide == Int(SettingsDialPlacement.panelSize.width * 2))
    }

    @Test func theAddThemeCardIsOpaqueAndKeepsItsWordsInsideItsSurface() throws {
        let theme = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "installing", origin: .idea, pictureIsAvailable: false)
        let card = ThemeInstallCardView(pendingInstall: PendingThemeInstall(packageURL: URL(fileURLWithPath: "/tmp/Moonlit.clickytheme"), theme: theme, pictureJPEG: nil), decide: { _ in })
        let bitmap = try render(card, named: "add-theme-card")
        // The card is 340 points wide plus its margins, so its center column is opaque dark and the margin's corner shows white.
        let centerPixel = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(centerPixel.redComponent < 0.25)
        let cornerPixel = try #require(bitmap.colorAt(x: 2, y: 2))
        #expect(cornerPixel.redComponent > 0.95)
    }
}
