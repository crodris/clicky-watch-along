//
//  AccentInkTests.swift
//  leanring-buddyTests
//
//  Text and icons on an accent fill take whichever of near-black and white reads better on that fill. Each surface that
//  draws on an accent is drawn with a theme where one fixed color would be wrong, and its ink pixels are counted. A render
//  is at 2x, and a view drawn in a window is at that window's backing scale. A hovered button must keep its fill, since
//  the ink was chosen for the fill as it rests.
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
        if let other { try requireTheSameSize(as: other) }
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

    /// How many channels inside `partInPoints` differ from those of `other`, a drawing of the same size. The scan runs off
    /// the main actor.
    fileprivate func channelsThatDiffer(from other: DrawingPixels, inside partInPoints: CGRect) async throws -> Int {
        try requireTheSameSize(as: other)
        let columns = Int(partInPoints.minX * pixelsPerPoint)..<Int(partInPoints.maxX * pixelsPerPoint)
        let rows = Int(partInPoints.minY * pixelsPerPoint)..<Int(partInPoints.maxY * pixelsPerPoint)
        let (ownBytes, otherBytes, bytesPerRow) = (bytes, other.bytes, width * 4)
        return await Task.detached {
            rows.reduce(0) { count, y in
                let rowPart = (y * bytesPerRow + columns.lowerBound * 4)..<(y * bytesPerRow + columns.upperBound * 4)
                return count + rowPart.count { abs(Int(ownBytes[$0]) - Int(otherBytes[$0])) > 6 }
            }
        }.value
    }
}

/// A button in an `NSHostingView` in a window off every screen, since `ImageRenderer` draws the AppKit hover view every
/// button has as a placeholder sign.
@MainActor
private struct OffscreenButton {
    private let window: NSWindow
    let hostingView: NSView
    let size: CGSize

    init(_ button: some View) {
        let hostingView = NSHostingView(rootView: button)
        size = hostingView.fittingSize
        window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: size)
        self.hostingView = hostingView
    }

    func draw() throws -> DrawingPixels {
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: size.width)
    }

    func close() {
        window.close()
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

    private func inkPixels(ofButton button: some View) async throws -> InkPixelCounts {
        let offscreenButton = OffscreenButton(button)
        defer { offscreenButton.close() }
        return try await offscreenButton.draw().inkPixelCounts()
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

    /// Nekoma's red is the closest call: white reads at 4.49 and near-black at 4.35. The label's ink must be the one that
    /// reads on the fill, in every size the button comes in.
    @Test(arguments: [TetherButtonSize.compact, .standard, .prominent])
    func thePrimaryButtonsLettersReadOnTheirAccent(size: TetherButtonSize) async throws {
        let onNekoma = try await inkPixels(ofButton: TetherButton("Save", role: .primary(accent: Color(hex: "#E0313B")), size: size) {})
        #expect(onNekoma.white > 20 && onNekoma.nearBlack == 0)
        let onShiratorizawa = try await inkPixels(ofButton: TetherButton("Start Clicky", role: .primary(accent: Color(hex: "#A0457F")), size: size) {})
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
        let onClickyBlue = try await inkPixels(ofButton: TetherButton("Start Clicky", role: .primary(accent: Color(hex: "#3380FF")), size: size) {})
        #expect(onClickyBlue.nearBlack > 20 && onClickyBlue.white == 0)
    }

    /// Hovers a button as the mouse does, through its hover view, and compares it with the button at rest: nothing inside
    /// the ring's 4 point edge may change, and the edge must, or the button shows no hover at all.
    private func expectHoverToRingTheButtonAndKeepItsFill(_ button: some View) async throws {
        let offscreenButton = OffscreenButton(button)
        defer { offscreenButton.close() }
        let atRest = try offscreenButton.draw()
        try #require(hoverAndPointerViews(in: offscreenButton.hostingView).first).reportTheHover(true)
        var hovered = try offscreenButton.draw()
        // SwiftUI may apply the hover on a later turn.
        let deadline = ContinuousClock.now + .seconds(10)
        while try await hovered.channelsThatDiffer(from: atRest) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            hovered = try offscreenButton.draw()
        }
        let insideTheRing = CGRect(origin: .zero, size: offscreenButton.size).insetBy(dx: 4, dy: 4)
        #expect(try await hovered.channelsThatDiffer(from: atRest, inside: insideTheRing) == 0)
        #expect(try await hovered.channelsThatDiffer(from: atRest) > 0)
    }

    @Test(arguments: ["#E0313B", "#3380FF", "#A0457F"], [TetherButtonSize.compact, .standard, .prominent])
    func aHoveredPrimaryButtonKeepsItsFill(accentHex: String, size: TetherButtonSize) async throws {
        try await expectHoverToRingTheButtonAndKeepItsFill(TetherButton("Save", role: .primary(accent: Color(hex: accentHex)), size: size) {})
    }

    /// A status line's Callout reads its ink 30 times a second. A different ink put in the cache shows in the drawing only
    /// if the Callout reads the kept ink and does not work it out again. `accentHex` must be a color nothing else draws on,
    /// since this changes its entry in the app-wide cache, which it removes before and after.
    private func expectACalloutToKeepItsAccentsInk(accentHex: String) async throws {
        let accent = Color(hex: accentHex)
        Color.inksByFill[accent] = nil
        defer { Color.inksByFill[accent] = nil }
        let firstDrawing = try await inkPixels(of: callout(accentHex: accentHex) { TetherCalloutCrossIcon() }, in: calloutIconPart)
        #expect(firstDrawing.white > 20 && firstDrawing.nearBlack == 0)
        #expect(Color.inksByFill[accent] == Color(hex: ThemeRGBColor.lightInkHex))

        Color.inksByFill[accent] = Color(hex: ThemeRGBColor.darkInkHex)
        let secondDrawing = try await inkPixels(of: callout(accentHex: accentHex) { TetherCalloutCrossIcon() }, in: calloutIconPart)
        #expect(secondDrawing.nearBlack > 20 && secondDrawing.white == 0)
    }

    /// The experiment panel's Run button is the stylesheet's one accent-filled button. A page draws it, so this reads the rules.
    @Test func hoveringTheExperimentPanelsRunButtonKeepsItsFill() throws {
        let styleSheetURL = repositoryRootURL.appending(path: "leanring-buddy/LiveSceneAssets/scene-style.css")
        let styleSheet = try String(contentsOf: styleSheetURL, encoding: .utf8).replacing(#/\/\*[\s\S]*?\*\//#, with: "")
        // Each match is one rule's selectors and its declarations, an `@media` block's rules included.
        let hoverRules = styleSheet.matches(of: #/([^{}]+)\{([^{}]*)\}/#).filter {
            $0.output.1.contains(".clicky-run-button") && $0.output.1.contains(":hover")
        }
        // A renamed button must fail here and not pass with no rule to check.
        try #require(!hoverRules.isEmpty)
        for declaration in hoverRules.flatMap({ $0.output.2.split(separator: ";") }) {
            let declaration = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            // A new background, an opacity, a filter, or a blend mode would each draw the fill differently from the one its
            // ink was chosen for: an opacity lets the panel show through the fill and the label.
            let property = declaration.split(separator: ":").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let changesTheFill = property.hasPrefix("background") || ["opacity", "filter", "mix-blend-mode"].contains(property)
            #expect(!changesTheFill, "\(declaration)")
        }
    }

    @Test func aCalloutWorksOutAnAccentsInkOnceAndThenDrawsTheKeptOne() async throws {
        // No theme, agent color, or status line uses this color.
        let accentHex = "#A1437D"
        let accent = Color(hex: accentHex)
        // The wrong ink an earlier run in the same process could have left.
        Color.inksByFill[accent] = Color(hex: ThemeRGBColor.darkInkHex)
        try await expectACalloutToKeepItsAccentsInk(accentHex: accentHex)
        #expect(Color.inksByFill[accent] == nil)
    }

    private func squareDrawing(of color: Color, sideInPoints: CGFloat) throws -> DrawingPixels {
        let renderer = ImageRenderer(content: color.frame(width: sideInPoints, height: sideInPoints))
        renderer.scale = 2
        return try DrawingPixels(drawing: try #require(renderer.cgImage), widthInPoints: sideInPoints)
    }

    @Test func aPartPastTheDrawingCountsOnlyThePixelsInside() async throws {
        let drawing = try squareDrawing(of: .white, sideInPoints: 10)
        let partPastEveryEdge = try await drawing.inkPixelCounts(in: CGRect(x: -5, y: -5, width: 100, height: 100))
        #expect(partPastEveryEdge.white == 400)
        let partOutside = try await drawing.inkPixelCounts(in: CGRect(x: 50, y: 50, width: 5, height: 5))
        #expect(partOutside.white == 0 && partOutside.nearBlack == 0)
    }

    @Test func comparingDrawingsOfDifferentSizesFailsTheTest() async throws {
        let smaller = try squareDrawing(of: .white, sideInPoints: 10)
        let larger = try squareDrawing(of: .white, sideInPoints: 20)
        try await withKnownIssue {
            _ = try await smaller.inkPixelCounts(thatDifferFrom: larger)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("the drawings differ in size") }
        }
    }

    @Test func comparingChannelsOfDrawingsOfDifferentSizesFailsTheTest() async throws {
        let smaller = try squareDrawing(of: .white, sideInPoints: 10)
        let larger = try squareDrawing(of: .white, sideInPoints: 20)
        try await withKnownIssue {
            _ = try await smaller.channelsThatDiffer(from: larger)
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("the drawings differ in size") }
        }
    }

    @Test func comparingChannelsDownToAPointAboveTheDrawingComparesNone() async throws {
        let white = try squareDrawing(of: .white, sideInPoints: 10)
        let black = try squareDrawing(of: .black, sideInPoints: 10)
        #expect(try await white.channelsThatDiffer(from: black, downTo: -1) == 0)
    }

    /// The ink pixels of the initials on the face of a theme's first roster player.
    private func initialsInkPixels(themeID: String) async throws -> InkPixelCounts {
        let theme = bundledTheme(themeID)
        var rosterPlayers: [ThemeRosterPlayer] = []
        if case .roster(let players) = theme.agents.faces { rosterPlayers = players }
        // No portrait file in the idea's folder, so the face draws the initials.
        let player = try #require(rosterPlayers.first, "\(themeID) has no roster")
        let face = AgentRosterFace(player: player, of: theme.with(id: theme.id, origin: .idea))
        return try await inkPixels(of: RosterFaceView(rosterFace: face, size: 40), in: CGRect(x: 8, y: 8, width: 24, height: 24))
    }

    /// Date Tech's file names white as its contrast color, and white reads at 3.05 on its teal where near-black reads at 6.42.
    @Test func aRosterFacesInitialsReadOnTheAccentWhateverTheThemesContrastColorIs() async throws {
        let onDateTech = try await initialsInkPixels(themeID: "school-date-tech")
        #expect(onDateTech.nearBlack > 20 && onDateTech.white == 0)
        let onShiratorizawa = try await initialsInkPixels(themeID: "school-shiratorizawa")
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
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
    /// A hidden panel can stay in the app's window list, so each call takes a frame of its own and reads only the panel its
    /// own show made. `InstantReplayTests` shows Clicky blue replay panels around (-20,000, -20,000) at the same time, and
    /// on 2026-11-28 a search by frame alone picked one of them and read near-black ink on Shiratorizawa.
    private func replayButtonInkPixels(accentHex: String, offScreenX: CGFloat) async throws -> InkPixelCounts {
        let stage = InstantReplayStage(
            focusStop: { _ in }, endFocus: {}, showStopNumbers: { _, _ in }, hideStopNumbers: {},
            labelScreenPointOnceTheCameraSettles: { _ in nil }, pointTheCursor: { _, _ in 0 }, freezeTheCursor: {},
            releaseTheCursor: {}, clearTheFocus: {}, reduceMotionIsOn: { true }, sleep: { _ in }, showControl: { _ in },
            hideControl: {}
        )
        let offScreenFrame = CGRect(x: offScreenX, y: -60_000, width: 1_000, height: 1_000)
        let panelController = InstantReplayPanelController()
        defer { panelController.hide() }
        let windowsBeforeTheShow = Set(NSApplication.shared.windows.map(ObjectIdentifier.init))
        panelController.show(
            for: InstantReplayController(stage: stage),
            stopWhatClickyIsSaying: {},
            accentHex: accentHex,
            mediaRectOnScreen: offScreenFrame.insetBy(dx: 300, dy: 300),
            visibleFrame: offScreenFrame
        )
        let panel = try #require(NSApplication.shared.windows.first {
            $0 is NonKeyFloatingPanel && offScreenFrame.contains($0.frame) && !windowsBeforeTheShow.contains(ObjectIdentifier($0))
        })
        let contentView = try #require(panel.contentView)
        // The middle of the Replay capsule: past the window's shadow margin, the row's 4 points, and the capsule's own
        // padding.
        let replayButtonPart = CGRect(
            x: AgentListWindowMargins.leading + 4 + 11, y: AgentListWindowMargins.top + 4 + 5, width: 40, height: 14
        )
        // The control fades and grows in on the Glide move, and a pixel drawn see-through counts as no ink, so it is drawn
        // until the ink shows or 10 seconds pass.
        let deadline = Date().addingTimeInterval(10)
        while true {
            contentView.layoutSubtreeIfNeeded()
            let bitmap = try #require(contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds))
            contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
            let pixels = try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: contentView.bounds.width)
            let counts = try await pixels.inkPixelCounts(in: replayButtonPart)
            if counts.white + counts.nearBlack > 20 || Date() >= deadline { return counts }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test(.showsARealWindow)
    func theReplayControlsAccentButtonReadsOnItsAccent() async throws {
        let onShiratorizawa = try await replayButtonInkPixels(accentHex: "#A0457F", offScreenX: -60_000)
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
        let onClickyBlue = try await replayButtonInkPixels(accentHex: "#3380FF", offScreenX: -70_000)
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

    /// The ink pixels of a theme's name on its pill while the dial's Theme fan highlights it.
    private func fanNamePillInkPixels(themeID: String) async throws -> InkPixelCounts {
        let fans = SettingsDialFans(bundledThemes: bundledThemesForTests, savedCustomThemes: [])
        let itemIndex = try #require(bundledThemesForTests.firstIndex { $0.id == themeID })
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
        return try await inkPixels(of: dial, in: pillPart)
    }

    /// Date Tech's file names white as its contrast color, so the name on its accent pill shows which color the dial reads.
    @Test func theNameOfAHighlightedFanThemeReadsOnItsAccentPill() async throws {
        let onDateTech = try await fanNamePillInkPixels(themeID: "school-date-tech")
        #expect(onDateTech.nearBlack > 20 && onDateTech.white == 0)
        let onShiratorizawa = try await fanNamePillInkPixels(themeID: "school-shiratorizawa")
        #expect(onShiratorizawa.white > 20 && onShiratorizawa.nearBlack == 0)
    }
}
