//
//  PanelRenderTests.swift
//  leanring-buddyTests
//
//  The menu bar panel drawn at 2x, the keyboard focus ring rule, the hover that shows under a still pointer, and the
//  approval badge of the menu bar icon on a light and a dark menu bar. With `CLICKY_RENDER_DIR` set, each render is also
//  written there as a PNG, so a person can check every state by eye.
//

import AppKit
import AVFoundation
import Speech
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct PanelRenderTests {
    // MARK: - Rendering

    /// Draws the view the way the panel does, in an `NSHostingView` in a window, so the AppKit views inside it (the hover
    /// tracker every control has) draw as they do on screen. `ImageRenderer` draws those as a placeholder sign. The window
    /// sits off every screen and takes the backing scale of the main screen, 2 on a Retina Mac.
    private func render(_ view: some View, named fileName: String, background: Color = Color(hex: "#0b0c10")) throws -> NSBitmapImageRep {
        let hostingView = NSHostingView(rootView: view.padding(24).background(background))
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
        if let renderDirectory = ProcessInfo.processInfo.environment["CLICKY_RENDER_DIR"] {
            let fileURL = URL(fileURLWithPath: renderDirectory).appendingPathComponent("\(fileName).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: fileURL)
        }
        return bitmap
    }

    /// Pixels per point of a render, so the checks hold on a 1x screen too.
    private func scale(of bitmap: NSBitmapImageRep) -> CGFloat {
        CGFloat(bitmap.pixelsWide) / bitmap.size.width
    }

    private func luminance(_ color: NSColor) -> CGFloat {
        let rgbColor = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * rgbColor.redComponent + 0.7152 * rgbColor.greenComponent + 0.0722 * rgbColor.blueComponent
    }

    private let inarizaki = bundledTheme("school-inarizaki")

    @Test func theHeaderShowsTheShownCursorAndTheStateLine() throws {
        for (status, fileName) in [(PanelHeaderStatus.ready, "header-ready"), (.offline, "header-offline"), (.quizQuestion, "header-quiz")] {
            let bitmap = try render(PanelHeaderView(shownTheme: clickyBlueTheme, status: status, close: {}).frame(width: CompanionPanelView.contentWidth).tetherCard(), named: fileName)
            #expect(bitmap.size.width == CompanionPanelView.contentWidth + 48)
        }
        _ = try render(PanelHeaderView(shownTheme: inarizaki, status: .ready, close: {}).frame(width: CompanionPanelView.contentWidth).tetherCard(), named: "header-light-accent")
    }

    @Test func eachBannerFitsTheCardAtTwoX() throws {
        let banners: [(PanelBanner, String)] = [
            (.permissionOff(.accessibility), "banner-permission-off"),
            (.workerUnreachable, "banner-offline"),
        ]
        for (banner, fileName) in banners {
            let words = try #require(panelProblemBannerWords(for: banner))
            let bitmap = try render(PanelBannerView(words: words, run: {}).frame(width: CompanionPanelView.contentWidth - 24), named: fileName)
            // The banner keeps the panel's width: its text wraps inside it instead of widening it.
            #expect(bitmap.size.width == CompanionPanelView.contentWidth - 24 + 48)
        }
    }

    @Test func theSetupChecklistDrawsEachState() throws {
        let inProgress = SetupFacts(
            microphoneStatus: .authorized,
            speechRecognitionStatus: .authorized,
            hasScreenRecording: false,
            screenTestPassed: false,
            screenTestFailed: false,
            hasAccessibility: false,
            chromeControlStatus: .chromeIsNotRunning,
            stepsAskedForThisLaunch: []
        )
        var turnedOff = inProgress
        turnedOff.stepsAskedForThisLaunch = [.screenRecording]
        var done = inProgress
        done.hasScreenRecording = true
        done.screenTestPassed = true
        done.hasAccessibility = true
        for (facts, fileName, theme) in [(inProgress, "setup-in-progress", clickyBlueTheme), (turnedOff, "setup-turned-off", clickyBlueTheme), (done, "setup-done", inarizaki)] {
            let checklist = SetupChecklistView(
                stepStates: setupStepStates(for: facts),
                isAFirstRun: true,
                isRequestingTheScreenTest: false,
                shownTheme: theme,
                runStep: { _, _ in },
                start: {}
            )
            let bitmap = try render(checklist.padding(16).frame(width: CompanionPanelView.contentWidth).tetherCard(), named: fileName)
            #expect(bitmap.size.height > 400)
        }
    }

    @Test func theThemeCardsDrawEveryBundledTheme() throws {
        let grid = ThemeCardGrid(
            themes: bundledThemesForTests,
            selectedTheme: clickyBlueTheme,
            designATheme: {},
            pick: { _ in },
            rename: { _, _ in },
            delete: { _ in }
        )
        let bitmap = try render(grid.padding(16).frame(width: CompanionPanelView.contentWidth).tetherCard(), named: "theme-cards")
        let rowCount = (bundledThemesForTests.count + 1 + ThemeCardGrid.columnCount - 1) / ThemeCardGrid.columnCount
        // Every row of cards has the same height, so a long name never makes one card taller than the others.
        #expect(bitmap.size.height > CGFloat(rowCount * 120))
    }

    @Test func aLongNamesFullNamePillWrapsInsideItsCard() throws {
        // The width a card in the panel's grid gives its pill: the card's width less the pill's 4 point inset on each side.
        let cardWidth = (CompanionPanelView.contentWidth - 32 - CGFloat(ThemeCardGrid.columnCount - 1) * ThemeCardGrid.spacing) / CGFloat(ThemeCardGrid.columnCount)
        let pillWidth = cardWidth - 8
        // The widest name a theme can have: 24 characters, each a wide letter.
        let widestName = String(repeating: "W", count: 24)
        let widestPillSize = NSHostingController(rootView: ThemeCardFullNamePill(name: widestName)).sizeThatFits(in: CGSize(width: pillWidth, height: 1_000))
        #expect(widestPillSize.width <= pillWidth)
        #expect(widestPillSize.height > ThemeCardFullNamePill.oneLineHeight)
        // A short name keeps the one-line pill.
        let shortPillSize = NSHostingController(rootView: ThemeCardFullNamePill(name: "Ember")).sizeThatFits(in: CGSize(width: pillWidth, height: 1_000))
        #expect(abs(shortPillSize.height - ThemeCardFullNamePill.oneLineHeight) < 1)
        _ = try render(
            VStack(spacing: 12) {
                ThemeCardFullNamePill(name: widestName)
                ThemeCardFullNamePill(name: "Moonlit Harbor at Night")
                ThemeCardFullNamePill(name: "Ember")
            }
            .frame(width: pillWidth),
            named: "theme-card-full-name-pills"
        )
    }

    @Test func aTallPageScrollsUnderTheHeaderInsteadOfGrowingTheCard() throws {
        let companionManager = CompanionManager()
        let presentation = PanelPresentation()
        // The setup page, which shows no banner, so the height does not depend on this Mac's permissions or approvals.
        presentation.page = .setup
        presentation.isOpen = true
        presentation.tallestPageHeight = 250
        let panelView = CompanionPanelView(
            companionManager: companionManager,
            themeSettings: companionManager.themeSettings,
            backgroundAgentStore: companionManager.backgroundAgentStore,
            presentation: presentation,
            workerReachability: WorkerReachability(workerBaseURL: "http://127.0.0.1:9"),
            approvalDesk: companionManager.approvalDesk
        )
        let bitmap = try render(panelView.frame(width: CompanionPanelView.contentWidth + 56), named: "panel-setup-capped")
        // The card is the header and 250 points of page, plus its shadow margin and the render's padding. The setup page is
        // taller than 250 points, so a page that scrolls fills the cap exactly, and one that collapsed would come out shorter.
        let margin = CompanionPanelView.shadowMargin
        let cappedHeight = panelHeaderHeight + 250 + margin.top + margin.bottom + 48
        #expect(abs(bitmap.size.height - cappedHeight) <= 2)
    }

    // MARK: - Keyboard focus

    @Test func onlyTheKeyboardShowsTheFocusRing() {
        #expect(theKeyboardMovedTheFocus(currentEventType: .keyDown))
        #expect(!theKeyboardMovedTheFocus(currentEventType: .leftMouseDown))
        #expect(!theKeyboardMovedTheFocus(currentEventType: nil))
    }

    // MARK: - Hover under a still pointer

    @Test func aViewThatAppearsUnderAStillPointerReportsItsHoverAtOnce() {
        // The window sits off every screen, and the mouse location is a fixed point, so the test never reads the real
        // mouse, which a CI runner's background session does not have.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 80, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hoverView = HoverAndPointerNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        var mouseLocationInTheWindow = CGPoint(x: 40, y: 40)
        hoverView.mouseLocationInTheWindow = { _ in mouseLocationInTheWindow }
        var reportedHovers: [Bool] = []
        hoverView.onHoverChange = { reportedHovers.append($0) }
        window.contentView = hoverView
        window.orderFrontRegardless()
        defer { window.close() }
        // No mouse event arrives: laying out the tracking area finds the mouse already inside and reports the hover.
        hoverView.updateTrackingAreas()
        #expect(reportedHovers == [true])
        // The same hover is never reported twice, and leaving reports once.
        hoverView.updateTrackingAreas()
        #expect(reportedHovers == [true])
        mouseLocationInTheWindow = CGPoint(x: 200, y: 200)
        hoverView.updateTrackingAreas()
        #expect(reportedHovers == [true, false])
    }

    @Test func aViewThatMovesAwayFromAStillPointerInsideTheWindowReportsNoHover() {
        // Three cards in a row, as the theme grid lays them out. Each view keeps AppKit's default of not clipping to its
        // bounds, as SwiftUI's hosted views do, so its visible rect reaches across the whole window.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 300, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        window.contentView = contentView
        var reportedHoversByCard: [[Bool]] = [[], [], []]
        let cardViews = (0..<3).map { cardIndex in
            let cardView = HoverAndPointerNSView(frame: NSRect(x: CGFloat(cardIndex) * 100, y: 0, width: 100, height: 80))
            cardView.clipsToBounds = false
            cardView.mouseLocationInTheWindow = { _ in CGPoint(x: 150, y: 40) }
            cardView.onHoverChange = { reportedHoversByCard[cardIndex].append($0) }
            contentView.addSubview(cardView)
            return cardView
        }
        window.orderFrontRegardless()
        defer { window.close() }
        // The still pointer sits over the middle card only, so a re-layout marks only that card as hovered.
        cardViews.forEach { $0.updateTrackingAreas() }
        #expect(reportedHoversByCard == [[], [true], []])
        // The middle card is deleted and the last card slides into its place: the hover moves with the pointer's card.
        cardViews[1].removeFromSuperview()
        cardViews[2].frame.origin.x = 100
        cardViews[2].updateTrackingAreas()
        #expect(reportedHoversByCard == [[], [true], [true]])
    }

    // MARK: - The approval badge on a light menu bar

    @Test func theApprovalBadgeKeepsItsDarkRimOnALightAndADarkMenuBar() throws {
        for (menuBarHex, foreground, fileName) in [("#F2F2F2", NSColor.black, "menu-icon-badge-light-bar"), ("#1E1E1E", NSColor.white, "menu-icon-badge-dark-bar")] {
            let badgedIcon = MenuBarIconArt.image(for: .idle, cursor: .triangle, badgeOnAForeground: foreground)
            let iconView = Image(nsImage: badgedIcon).frame(width: MenuBarIconArt.size.width, height: MenuBarIconArt.size.height)
            let bitmap = try render(iconView, named: fileName, background: Color(hex: menuBarHex))
            let padding: CGFloat = 24
            let pixelsPerPoint = scale(of: bitmap)
            let badgeCenterX = Int((padding + MenuBarIconArt.badgeCenter.x) * pixelsPerPoint)
            let badgeCenterY = Int((padding + MenuBarIconArt.badgeCenter.y) * pixelsPerPoint)
            let badgePixel = try #require(bitmap.colorAt(x: badgeCenterX, y: badgeCenterY)?.usingColorSpace(.sRGB))
            // Amber at the center: red above green above blue. The color space conversion lifts its blue to about 0.35.
            #expect(badgePixel.redComponent > 0.9 && badgePixel.greenComponent > 0.6 && badgePixel.blueComponent < 0.45)
            #expect(badgePixel.redComponent > badgePixel.greenComponent && badgePixel.greenComponent > badgePixel.blueComponent)
            // The rim, half a point outside the amber, is dark on either bar, so the badge has an edge on a light bar too.
            let rimOffset = Int((MenuBarIconArt.badgeDiameter / 2 + 0.5) * pixelsPerPoint)
            let rimPixel = try #require(bitmap.colorAt(x: badgeCenterX + rimOffset, y: badgeCenterY)?.usingColorSpace(.sRGB))
            #expect(luminance(rimPixel) < 0.35)
        }
    }
}
