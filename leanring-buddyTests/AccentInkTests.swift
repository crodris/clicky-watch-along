//
//  AccentInkTests.swift
//  leanring-buddyTests
//
//  Text and icons on an accent fill take whichever of near-black and white reads better on that fill. Each surface that
//  draws on an accent is drawn with a theme where one fixed color would be wrong, and its ink pixels are counted. A render
//  is at 2x, and a view drawn in a window is at that window's backing scale.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

/// How many pixels of a part of a drawing are the near-black ink and how many are white. Whatever is drawn in the ink
/// is the larger count, since the part holds only the accent fill and what is drawn on it.
private struct InkPixelCounts {
    let nearBlack: Int
    let white: Int
}

extension DrawingPixels {
    /// The ink pixels inside `partInPoints`, cut to the drawing, or in the whole drawing when nil. With `other`, a drawing
    /// of the same size, only pixels that differ from the same pixel there count, which leaves what was drawn since. The
    /// scan runs off the main actor.
    fileprivate func inkPixelCounts(in partInPoints: CGRect? = nil, thatDifferFrom other: DrawingPixels? = nil) async throws -> InkPixelCounts {
        if let other {
            try #require(
                other.width == width && other.height == height,
                "the drawings differ in size: \(width) by \(height) pixels and \(other.width) by \(other.height)"
            )
        }
        let wholeDrawing = CGRect(x: 0, y: 0, width: width, height: height)
        let part = partInPoints.map {
            CGRect(x: $0.minX * pixelsPerPoint, y: $0.minY * pixelsPerPoint, width: $0.width * pixelsPerPoint, height: $0.height * pixelsPerPoint)
                .intersection(wholeDrawing)
        } ?? wholeDrawing
        // A part wholly outside the drawing cuts to the null rectangle, whose edges are infinite.
        guard !part.isNull else { return InkPixelCounts(nearBlack: 0, white: 0) }
        let (ownBytes, otherBytes, bytesPerRow) = (bytes, other?.bytes, width * 4)
        return await Task.detached {
            var nearBlack = 0
            var white = 0
            for y in Int(part.minY)..<Int(part.maxY) {
                for x in Int(part.minX)..<Int(part.maxX) {
                    let offset = y * bytesPerRow + x * 4
                    // Two drawings of one state can round the Card's gradient and shadow a few levels apart, so a channel
                    // that close has not been drawn since.
                    if let otherBytes, (0..<3).allSatisfy({ abs(Int(ownBytes[offset + $0]) - Int(otherBytes[offset + $0])) <= 6 }) { continue }
                    // Only an opaque pixel counts, since a see-through one has no color of its own.
                    guard ownBytes[offset + 3] >= 253 else { continue }
                    let channels = ownBytes[offset..<offset + 3]
                    // Below 12% and above 92% of full brightness.
                    if channels.allSatisfy({ $0 <= 30 }) { nearBlack += 1 }
                    if channels.allSatisfy({ $0 >= 235 }) { white += 1 }
                }
            }
            return InkPixelCounts(nearBlack: nearBlack, white: white)
        }.value
    }
}

@MainActor
struct AccentInkTests {
    /// Renders `view` at 2x and counts the ink pixels inside `partInPoints`, or in the whole render when nil.
    private func inkPixels(of view: some View, in partInPoints: CGRect? = nil) async throws -> InkPixelCounts {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let pixels = try DrawingPixels(drawing: image, widthInPoints: CGFloat(image.width) / renderer.scale)
        return try await pixels.inkPixelCounts(in: partInPoints)
    }

    /// Draws a button in an `NSHostingView` in a window off every screen, since `ImageRenderer` draws the AppKit hover view
    /// every button has as a placeholder sign.
    private func inkPixels(ofButton button: some View) async throws -> InkPixelCounts {
        let hostingView = NSHostingView(rootView: button)
        let fittingSize = hostingView.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: fittingSize.width, height: fittingSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let pixels = try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: fittingSize.width)
        return try await pixels.inkPixelCounts()
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

    @Test func everyBundledThemeTakesTheInkWithTheHigherContrastOnItsAccent() throws {
        #expect(bundledThemesForTests.count == 11)
        let nearBlack = try #require(ThemeRGBColor(hex: "#0B0C0E"))
        let white = try #require(ThemeRGBColor(hex: "#FFFFFF"))
        for theme in bundledThemesForTests {
            let accent = try #require(ThemeRGBColor(hex: theme.accentHex))
            let higherContrastInkHex = accent.contrastRatio(against: nearBlack) > accent.contrastRatio(against: white) ? "#0B0C0E" : "#FFFFFF"
            #expect(theme.accentInkHex == higherContrastInkHex, "\(theme.id)")
            // A surface that holds the accent as a Color picks the same ink as one that holds its hex string.
            #expect(theme.cursorColor.inkOnThisFill == Color(hex: higherContrastInkHex), "\(theme.id)")
        }
        #expect(bundledTheme("school-shiratorizawa").accentInkHex == "#FFFFFF")
        #expect(clickyBlueTheme.accentInkHex == "#0B0C0E")
    }

    @Test func theSceneStylesheetCarriesTheInkOfItsAccent() {
        let shiratorizawaScript = sceneStyleUserScriptSource(styleSheet: "", accentHex: "#A0457F")
        #expect(shiratorizawaScript.contains(##"root.style.setProperty("--clicky-accent-ink", "#FFFFFF");"##))
        let clickyBlueScript = sceneStyleUserScriptSource(styleSheet: "", accentHex: "#3380FF")
        #expect(clickyBlueScript.contains(##"root.style.setProperty("--clicky-accent-ink", "#0B0C0E");"##))
    }

    @Test func theCalloutsIconsAreWhiteOnADarkAccentAndNearBlackOnABrightOne() async throws {
        let cursorIconOnShiratorizawa = try await inkPixels(of: callout(accentHex: "#A0457F") { TetherCalloutCursorIcon() }, in: calloutIconPart)
        #expect(cursorIconOnShiratorizawa.white > 20 && cursorIconOnShiratorizawa.nearBlack == 0)
        let crossIconOnShiratorizawa = try await inkPixels(of: callout(accentHex: "#A0457F") { TetherCalloutCrossIcon() }, in: calloutIconPart)
        #expect(crossIconOnShiratorizawa.white > 20 && crossIconOnShiratorizawa.nearBlack == 0)
        let symbolOnShiratorizawa = try await inkPixels(of: callout(accentHex: "#A0457F") { Image(systemName: "hand.point.up.left.fill") }, in: calloutIconPart)
        #expect(symbolOnShiratorizawa.white > 20 && symbolOnShiratorizawa.nearBlack == 0)
        let cursorIconOnClickyBlue = try await inkPixels(of: callout(accentHex: "#3380FF") { TetherCalloutCursorIcon() }, in: calloutIconPart)
        #expect(cursorIconOnClickyBlue.nearBlack > 20 && cursorIconOnClickyBlue.white == 0)
    }

    @Test func thePrimaryButtonsLettersReadOnTheirAccent() async throws {
        // Nekoma's red is the closest call: white reads at 4.49 and near-black at 4.35.
        let studioButtonOnNekoma = try await inkPixels(ofButton: ThemeStudioButton(title: "Save", style: .primary(accentHex: "#E0313B"), isEnabled: true) {})
        #expect(studioButtonOnNekoma.white > 20 && studioButtonOnNekoma.nearBlack == 0)
        let studioButtonOnClickyBlue = try await inkPixels(ofButton: ThemeStudioButton(title: "Save", style: .primary(accentHex: "#3380FF"), isEnabled: true) {})
        #expect(studioButtonOnClickyBlue.nearBlack > 20 && studioButtonOnClickyBlue.white == 0)
        let panelButtonOnShiratorizawa = try await inkPixels(ofButton: PanelButton(title: "Start Clicky", prominence: .primary, accentColor: Color(hex: "#A0457F")) {})
        #expect(panelButtonOnShiratorizawa.white > 20 && panelButtonOnShiratorizawa.nearBlack == 0)
    }

    /// A status line's Callout reads its ink 30 times a second. A different ink put in the cache shows in the drawing only
    /// if the Callout reads the kept ink and does not work it out again.
    @Test func aCalloutWorksOutAnAccentsInkOnceAndThenDrawsTheKeptOne() async throws {
        // No theme, agent color, or status line uses this color, so nothing else has asked for its ink.
        let accentHex = "#A1437D"
        let accent = Color(hex: accentHex)
        #expect(Color.inksByFill[accent] == nil)
        let firstDrawing = try await inkPixels(of: callout(accentHex: accentHex) { TetherCalloutCrossIcon() }, in: calloutIconPart)
        #expect(firstDrawing.white > 20 && firstDrawing.nearBlack == 0)
        #expect(Color.inksByFill[accent] == Color(hex: ThemeRGBColor.lightInkHex))

        Color.inksByFill[accent] = Color(hex: ThemeRGBColor.darkInkHex)
        let secondDrawing = try await inkPixels(of: callout(accentHex: accentHex) { TetherCalloutCrossIcon() }, in: calloutIconPart)
        #expect(secondDrawing.nearBlack > 20 && secondDrawing.white == 0)
    }

    private func whiteDrawing(sideInPoints: CGFloat) throws -> DrawingPixels {
        let renderer = ImageRenderer(content: Color.white.frame(width: sideInPoints, height: sideInPoints))
        renderer.scale = 2
        return try DrawingPixels(drawing: try #require(renderer.cgImage), widthInPoints: sideInPoints)
    }

    @Test func aPartPastTheDrawingCountsOnlyThePixelsInside() async throws {
        let drawing = try whiteDrawing(sideInPoints: 10)
        let partPastEveryEdge = try await drawing.inkPixelCounts(in: CGRect(x: -5, y: -5, width: 100, height: 100))
        #expect(partPastEveryEdge.white == 400)
        let partOutside = try await drawing.inkPixelCounts(in: CGRect(x: 50, y: 50, width: 5, height: 5))
        #expect(partOutside.white == 0 && partOutside.nearBlack == 0)
    }

    @Test func comparingDrawingsOfDifferentSizesFailsTheTest() async throws {
        let smaller = try whiteDrawing(sideInPoints: 10)
        let larger = try whiteDrawing(sideInPoints: 20)
        try await withKnownIssue {
            _ = try await smaller.inkPixelCounts(thatDifferFrom: larger)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("the drawings differ in size") }
        }
    }

    /// Date Tech's file names white as its contrast color, and white reads at 3.05 on its teal where near-black reads at 6.42.
    @Test func aRosterFacesInitialsReadOnTheAccentWhateverTheThemesContrastColorIs() async throws {
        let dateTech = bundledTheme("school-date-tech")
        guard case .roster(let players) = dateTech.agents.faces else {
            Issue.record("school-date-tech has no roster")
            return
        }
        // No portrait file in the idea's folder, so the face draws the initials.
        let player = try #require(players.first)
        let face = AgentRosterFace(player: player, of: dateTech.with(id: dateTech.id, origin: .idea))
        let initials = try await inkPixels(of: RosterFaceView(rosterFace: face, size: 40), in: CGRect(x: 8, y: 8, width: 24, height: 24))
        #expect(initials.nearBlack > 20 && initials.white == 0)
    }

    @Test func aStatusIconDrawsInTheInkOfItsDisc() {
        #expect(StatusLabelPalette(onDisc: Color(hex: "#A0457F")).iconColor == Color(hex: "#FFFFFF"))
        #expect(StatusLabelPalette(onDisc: Color(hex: "#3380FF")).iconColor == Color(hex: "#0B0C0E"))
    }

    @Test func theSavedIdeasCheckStampIsDrawnInTheAccentsInk() async throws {
        let onShiratorizawa = try await themeStudioCardDrawingsAroundASave(accentHex: "#A0457F")
        let whiteStamp = try await onShiratorizawa.stamped.inkPixelCounts(thatDifferFrom: onShiratorizawa.beforeTheSave)
        #expect(whiteStamp.white > 20 && whiteStamp.nearBlack == 0)
        let onClickyBlue = try await themeStudioCardDrawingsAroundASave(accentHex: "#3380FF")
        let nearBlackStamp = try await onClickyBlue.stamped.inkPixelCounts(thatDifferFrom: onClickyBlue.beforeTheSave)
        #expect(nearBlackStamp.nearBlack > 20 && nearBlackStamp.white == 0)
    }

    /// The replay control is private, so this shows its real panel on a frame far off every screen and draws it from there.
    /// A hidden panel can stay in the app's window list, so each call takes a frame of its own.
    private func replayButtonInkPixels(accentHex: String, offScreenX: CGFloat) async throws -> InkPixelCounts {
        let stage = InstantReplayStage(
            focusStop: { _ in }, endFocus: {}, showStopNumbers: { _, _ in }, hideStopNumbers: {},
            labelScreenPointOnceTheCameraSettles: { _ in nil }, pointTheCursor: { _, _ in 0 }, freezeTheCursor: {},
            releaseTheCursor: {}, clearTheFocus: {}, reduceMotionIsOn: { true }, sleep: { _ in }, showControl: { _ in },
            hideControl: {}
        )
        let offScreenFrame = CGRect(x: offScreenX, y: -20_000, width: 1_000, height: 1_000)
        let panelController = InstantReplayPanelController()
        defer { panelController.hide() }
        panelController.show(
            for: InstantReplayController(stage: stage),
            stopWhatClickyIsSaying: {},
            accentHex: accentHex,
            mediaRectOnScreen: offScreenFrame.insetBy(dx: 300, dy: 300),
            visibleFrame: offScreenFrame
        )
        let panel = try #require(NSApplication.shared.windows.first { $0 is NonKeyFloatingPanel && offScreenFrame.contains($0.frame) })
        let contentView = try #require(panel.contentView)
        contentView.layoutSubtreeIfNeeded()
        let bitmap = try #require(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        let pixels = try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: contentView.bounds.width)
        // The middle of the Replay capsule: past the window's 12 point shadow margin, the row's 4 points, and the capsule's
        // own padding.
        let replayButtonPart = CGRect(x: 12 + 4 + 11, y: 12 + 4 + 5, width: 40, height: 14)
        return try await pixels.inkPixelCounts(in: replayButtonPart)
    }

    @Test(.showsARealWindow)
    func theReplayControlsAccentButtonReadsOnItsAccent() async throws {
        let onShiratorizawa = try await replayButtonInkPixels(accentHex: "#A0457F", offScreenX: -20_000)
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
        let onClickyBlue = try await replayButtonInkPixels(accentHex: "#3380FF", offScreenX: -30_000)
        #expect(onClickyBlue.nearBlack > 20 && onClickyBlue.white == 0)
    }

    private func dialView(theme: ClickyTheme, selection: SettingsDialSelection = SettingsDialSelection(slice: .model, fanItemIndex: nil)) -> SettingsDialView {
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
        viewModel.selection = selection
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

    @Test func theSettingsDialsSelectedTokenDrawsItsIconInTheAccentsInk() async throws {
        // Clicky blue's contrast color is white, which reads worse on its blue than near-black does.
        let onClickyBlue = try await inkPixels(of: dialView(theme: clickyBlueTheme), in: selectedModelTokenIconPart)
        #expect(onClickyBlue.nearBlack > 20 && onClickyBlue.white == 0)
        let onShiratorizawa = try await inkPixels(of: dialView(theme: bundledTheme("school-shiratorizawa")), in: selectedModelTokenIconPart)
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
    }

    /// Date Tech's file names white as its contrast color, so the name on its accent pill shows which color the dial reads.
    @Test func theNameOfAHighlightedFanThemeReadsOnItsAccentPill() async throws {
        let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
        let itemIndex = try #require(bundledThemesForTests.firstIndex { $0.id == "school-date-tech" })
        let angle = try #require(fans.layout(of: .theme)).angleDegrees(ofItemAt: itemIndex) * .pi / 180
        let ballCenterOffset = CGPoint(x: cos(angle) * SettingsDialGeometry.fanRadius, y: sin(angle) * SettingsDialGeometry.fanRadius)
        let ballRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
        let labelText = SettingsDialLabel.fanLabelText(bundledThemesForTests[itemIndex].name, ballCenterOffset: ballCenterOffset, ballRadius: ballRadius)
        let pillSize = SettingsDialLabel.pillSize(forText: labelText)
        let pillCenterOffset = SettingsDialLabel.fanLabelCenterOffset(ballCenterOffset: ballCenterOffset, ballRadius: ballRadius, labelPillSize: pillSize)
        // The middle of the pill, inside its round ends.
        let pillPart = CGRect(
            x: SettingsDialPlacement.reachLeft + pillCenterOffset.x - pillSize.width / 2 + 8,
            y: SettingsDialPlacement.reachAbove + pillCenterOffset.y - pillSize.height / 2 + 2,
            width: pillSize.width - 16,
            height: pillSize.height - 4
        )
        let dial = dialView(theme: clickyBlueTheme, selection: SettingsDialSelection(slice: .theme, fanItemIndex: itemIndex))
        let nameOnThePill = try await inkPixels(of: dial, in: pillPart)
        #expect(nameOnThePill.nearBlack > 20 && nameOnThePill.white == 0)
    }
}
