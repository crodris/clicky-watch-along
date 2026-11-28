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
                runStep: { _, _ in }
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

    /// How many pixels of a render are this sRGB color, give or take a few levels per channel.
    private func pixelCount(in bitmap: NSBitmapImageRep, near color: (red: Int, green: Int, blue: Int)) throws -> Int {
        let pixels = try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: bitmap.size.width)
        let tolerance = 8
        return stride(from: 0, to: pixels.bytes.count, by: 4).count { byteOffset in
            abs(Int(pixels.bytes[byteOffset]) - color.red) <= tolerance
                && abs(Int(pixels.bytes[byteOffset + 1]) - color.green) <= tolerance
                && abs(Int(pixels.bytes[byteOffset + 2]) - color.blue) <= tolerance
        }
    }

    @Test func theStartButtonStaysInViewWhenTheSetupPageIsTallerThanItsCap() throws {
        let everyStepDone = SetupFacts(
            microphoneStatus: .authorized,
            speechRecognitionStatus: .authorized,
            hasScreenRecording: true,
            screenTestPassed: true,
            screenTestFailed: false,
            hasAccessibility: true,
            chromeControlStatus: .granted,
            stepsAskedForThisLaunch: []
        )
        // A cap well under the page's natural height, as on a short screen or with "What gets sent" open, and one that fits it.
        for cap in [CGFloat(420), 520, 2_000] {
            let setupPage = PanelSetupPage(
                stepStates: setupStepStates(for: everyStepDone),
                setupIsFinished: false,
                isRequestingTheScreenTest: false,
                shownTheme: clickyBlueTheme,
                tallestPageHeight: cap,
                hasGlidedIn: true,
                back: {},
                runStep: { _, _ in },
                start: {},
                quit: {}
            )
            let bitmap = try render(setupPage.frame(width: CompanionPanelView.contentWidth).tetherCard(), named: "setup-page-done-cap-\(Int(cap))")
            // The page keeps to its cap, and the primary Start Clicky button (Clicky blue's #3380FF fill) is drawn in full: a
            // button cut off at the scroll area's bottom edge draws too few of those pixels, so the count must reach 95
            // percent of the same button drawn alone.
            let renderPadding: CGFloat = 48
            #expect(bitmap.size.height <= cap + renderPadding + 1, "cap \(cap)")
            let startButtonPixels = try pixelCount(in: bitmap, near: (red: 0x33, green: 0x80, blue: 0xFF))
            let fullButton = TetherButton("Start Clicky", role: .primary(accent: clickyBlueTheme.cursorColor), size: .compact) {}
            let fullButtonBitmap = try render(fullButton, named: "start-button-alone")
            let pixelsInAFullButton = try pixelCount(in: fullButtonBitmap, near: (red: 0x33, green: 0x80, blue: 0xFF))
            try #require(pixelsInAFullButton > 500, "the button alone drew \(pixelsInAFullButton) blue pixels")
            #expect(startButtonPixels >= pixelsInAFullButton * 95 / 100, "cap \(cap): \(startButtonPixels) blue pixels, a full button has \(pixelsInAFullButton)")
        }
    }

    // MARK: - Keyboard focus

    /// `DS.CornerRadius.pill` is infinite, which SwiftUI clamps to half the shorter side. The switch's ring takes it, so it
    /// must still draw a ring that follows the pill and not a blank or a square one.
    @Test func aPillFocusRingFollowsTheShapeOfTheControlItRings() throws {
        let control = Color.clear.frame(width: 30, height: 16)
            .panelKeyboardFocusRing(isShowing: true, cornerRadius: DS.CornerRadius.pill)
        let bitmap = try render(control, named: "pill-focus-ring", background: .black)
        let pixelsPerPoint = scale(of: bitmap)
        func color(atX x: CGFloat, y: CGFloat) -> NSColor {
            bitmap.colorAt(x: Int(x * pixelsPerPoint), y: Int(y * pixelsPerPoint)) ?? .clear
        }
        // The render pads the control by 24 points. The ring sits 3 points outside the control and is 2 points wide.
        let ringTopMiddle = color(atX: 24 + 15, y: 24 - 3 + 1)
        let ringColor = NSColor(DS.Colors.keyboardFocusRing).usingColorSpace(.sRGB) ?? .white
        #expect(abs(ringTopMiddle.redComponent - ringColor.redComponent) < 0.05, "the ring's top middle is \(ringTopMiddle)")
        // A square ring would fill this corner. A pill leaves it as the page.
        let outerCorner = color(atX: 24 - 3 + 0.5, y: 24 - 3 + 0.5)
        #expect(luminance(outerCorner) < 0.05, "the ring's outer corner is \(outerCorner)")
    }

    @Test func onlyTheKeyboardShowsTheFocusRing() {
        #expect(theKeyboardMovedTheFocus(currentEventType: .keyDown))
        #expect(!theKeyboardMovedTheFocus(currentEventType: .leftMouseDown))
        #expect(!theKeyboardMovedTheFocus(currentEventType: nil))
    }

    // MARK: - A saved card's buttons and its cursor

    /// The Amber Paper Plane theme as the Theme Studio saved it: a shapes cursor whose tip reaches up near the middle of the
    /// card's top, where a pencil beside the trash can used to cover it.
    private static let amberPaperPlaneThemeJSON = """
    {"version": 2, "accent": "#FFA94D", "contrast": "#2B1200", "name": "Amber Paper Plane",
     "agents": {"ring": "perAgent", "colors": ["#FFB36B", "#FFD27A", "#F08FB0"], "faces": {"kind": "triangle"}},
     "cursor": {"kind": "shapes", "picture": null, "shapes": [
       {"d": "M12 2 L21 21 L12 17 L3 21 Z", "fill": "#FFA94D", "stroke": "#FFF1D6", "strokeWidth": 1.5},
       {"d": "M12 2 L12 17", "fill": null, "stroke": "#B8541A", "strokeWidth": 1.5}]},
     "motion": {"trailStreaks": 2, "turnsTowardMovement": true, "whileListening": "pulse", "whileThinking": "wobble"},
     "sounds": {"correct": "Glass", "done": "Hero", "needsYourOK": "Tink"}}
    """

    private func amberPaperPlane(origin: ThemeOrigin) throws -> ClickyTheme {
        let themeJSON = try JSONDecoder().decode(JSONValue.self, from: Data(Self.amberPaperPlaneThemeJSON.utf8))
        return try ClickyTheme.parse(themeJSON: themeJSON, id: "amber-paper-plane-test", origin: origin, pictureIsAvailable: false)
    }

    /// One theme card as the panel's grid draws it, in the hover state, as raw RGB bytes. A hover makes the pencil and trash can
    /// show on a saved card. The cursor holds still, since the panel counts as closed. Animations are off, so the hover lands
    /// in one draw and no wait depends on how long a fade takes on a loaded Mac. The window sits off every screen.
    private func hoveredCardPixels(of theme: ClickyTheme) async throws -> (width: Int, height: Int, pixelsPerPoint: CGFloat, bytes: [UInt8]) {
        let cardWidth = (CompanionPanelView.contentWidth - 32 - CGFloat(ThemeCardGrid.columnCount - 1) * ThemeCardGrid.spacing) / CGFloat(ThemeCardGrid.columnCount)
        let grid = ThemeCardGrid(
            themes: [theme], selectedTheme: clickyBlueTheme, designATheme: nil,
            pick: { _ in }, rename: { _, _ in }, delete: { _ in }
        )
        let hostingView = NSHostingView(rootView: grid.frame(width: cardWidth * 3 + 2 * ThemeCardGrid.spacing).background(Color(hex: "#0b0c10")).environment(\.menuPanelIsOpen, false).transaction { $0.disablesAnimations = true })
        let fittingSize = hostingView.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -90_000, y: -90_000, width: fittingSize.width, height: fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        // The card's own hover view is the largest one, since each button inside it has a smaller one.
        let cardHoverView = try #require(hoverAndPointerViews(in: hostingView).max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height })

        func draw() throws -> (width: Int, height: Int, pixelsPerPoint: CGFloat, bytes: [UInt8]) {
            let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
            let context = try #require(CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            return (image.width, image.height, CGFloat(image.width) / hostingView.bounds.width, Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4)))
        }
        let atRest = try draw()
        cardHoverView.reportTheHover(true)
        var previousDraw = atRest
        // The hover is a state change that SwiftUI applies on a later turn of the run loop, so draw until the card differs from
        // its resting look and then once more to see that it holds. The bound counts draws and not seconds, since a loaded Mac
        // makes each draw slow and a clock would run out while the card is still on its way.
        for _ in 1...600 {
            try await Task.sleep(for: .milliseconds(20))
            let nextDraw = try draw()
            if nextDraw.bytes == previousDraw.bytes, nextDraw.bytes != atRest.bytes { return nextDraw }
            previousDraw = nextDraw
        }
        Issue.record("the hovered card never settled")
        return previousDraw
    }

    @Test func aSavedCardsPencilAndTrashCanNeverCoverItsCursor() async throws {
        let savedTheme = try amberPaperPlane(origin: .saved(folderURL: URL(fileURLWithPath: "/nonexistent-saved-theme")))
        // The same theme as a bundled one has no buttons, so its hovered card shows the cursor alone.
        let cursorOnly = try amberPaperPlane(origin: .bundled(imagesFolderURL: URL(fileURLWithPath: "/nonexistent-images")))
        let withButtons = try await hoveredCardPixels(of: savedTheme)
        let withoutButtons = try await hoveredCardPixels(of: cursorOnly)
        #expect(withButtons.width == withoutButtons.width && withButtons.height == withoutButtons.height)

        func channels(of draw: (width: Int, height: Int, pixelsPerPoint: CGFloat, bytes: [UInt8]), column: Int, row: Int) -> [Int] {
            let firstByte = (row * draw.width + column) * 4
            return (0..<3).map { Int(draw.bytes[firstByte + $0]) }
        }
        func differ(_ first: [Int], _ second: [Int], by tolerance: Int) -> Bool {
            zip(first, second).contains { abs($0 - $1) > tolerance }
        }
        let scale = withButtons.pixelsPerPoint
        // The cursor's frame: the card's top 66 points, between its 20 point margins. The card's own color sits at 20 points in.
        let cardBackground = channels(of: withoutButtons, column: Int(20 * scale), row: Int(40 * scale))
        var cursorPixels = 0
        var buttonPixels = 0
        var coveredCursorPixels = 0
        for row in 0..<Int(66 * scale) {
            for column in Int(2 * scale)..<(withButtons.width - Int(2 * scale)) {
                let cursorOnlyColor = channels(of: withoutButtons, column: column, row: row)
                let withButtonsColor = channels(of: withButtons, column: column, row: row)
                let isTheCursor = differ(cursorOnlyColor, cardBackground, by: 24) && column > Int(20 * scale) && column < Int(77 * scale)
                let isAButton = differ(withButtonsColor, cursorOnlyColor, by: 6)
                if isTheCursor { cursorPixels += 1 }
                if isAButton { buttonPixels += 1 }
                if isTheCursor && isAButton { coveredCursorPixels += 1 }
            }
        }
        #expect(cursorPixels > 200, "the cursor drew \(cursorPixels) pixels")
        #expect(buttonPixels > 400, "the buttons drew \(buttonPixels) pixels")
        #expect(coveredCursorPixels == 0, "the buttons cover \(coveredCursorPixels) of the cursor's pixels")
    }

    // MARK: - A saved card's rename field

    /// A saved card already in its renaming state, as the panel's grid draws it, at the width a card has there.
    private struct RenamingCardHost: View {
        let theme: ClickyTheme
        let cardWidth: CGFloat
        var startsRenaming = true
        @FocusState private var focus: ThemeGridFocus?

        var body: some View {
            ThemeCard(
                theme: theme, isSelected: false, focus: $focus, pick: {}, rename: { _ in }, delete: { },
                moveTheFocus: { _ in }, startsRenaming: startsRenaming
            )
            .frame(width: cardWidth)
            .background(Color(hex: "#0b0c10"))
            .environment(\.menuPanelIsOpen, false)
        }
    }

    /// Draws a renaming card and returns the card's drawn size, the name field's text view, and the card's bitmap.
    private func renamingCard(of theme: ClickyTheme, named fileName: String, startsRenaming: Bool = true) async throws -> (cardSize: CGSize, textField: NSTextField?, bitmap: NSBitmapImageRep) {
        let cardWidth = (CompanionPanelView.contentWidth - 32 - CGFloat(ThemeCardGrid.columnCount - 1) * ThemeCardGrid.spacing) / CGFloat(ThemeCardGrid.columnCount)
        let hostingView = NSHostingView(rootView: RenamingCardHost(theme: theme, cardWidth: cardWidth, startsRenaming: startsRenaming))
        let fittingSize = hostingView.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -93_000, y: -93_000, width: fittingSize.width, height: fittingSize.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        // The field's text lays out on the pass after the first.
        try await Task.sleep(for: .milliseconds(300))
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        if let renderDirectory = ProcessInfo.processInfo.environment["CLICKY_RENDER_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: renderDirectory).appendingPathComponent("\(fileName).png"))
        }
        func textFields(in view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] + view.subviews.flatMap(textFields) } ?? view.subviews.flatMap(textFields)
        }
        return (fittingSize, textFields(in: hostingView).first, bitmap)
    }

    /// The width a text field's cell keeps for its own padding, 2 points on each side, which its text cannot use.
    private static let textFieldCellInsets: CGFloat = 4

    /// Whether a text field shows all of its text: wrapped at the field's own width, the text needs no more lines than the
    /// field may draw and no more height than the field has, so nothing is cut off at its right edge or its bottom.
    private func textShowsWhole(in textField: NSTextField) -> Bool {
        let font = textField.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let wrappedSize = (textField.stringValue as NSString).boundingRect(
            with: CGSize(width: textField.bounds.width - Self.textFieldCellInsets, height: 10_000), options: .usesLineFragmentOrigin, attributes: [.font: font]
        )
        let linesNeeded = Int((wrappedSize.height / font.boundingRectForFont.height).rounded())
        let linesTheFieldMayDraw = textField.maximumNumberOfLines == 0 ? Int.max : textField.maximumNumberOfLines
        return linesNeeded <= linesTheFieldMayDraw && wrappedSize.height <= textField.bounds.height + 3 // a line is 13 points, so the slack hides none
    }

    @Test func aRenamingCardShowsTheWholeNameItHolds() async throws {
        let savedOrigin = ThemeOrigin.saved(folderURL: URL(fileURLWithPath: "/nonexistent-saved-theme"))
        let amber = try amberPaperPlane(origin: savedOrigin)
        // The longest name a theme can have is 24 characters.
        let longestName = amber.renamed(to: "Midnight Harbor Lanterns")
        #expect(longestName.name.count == ClickyTheme.longestName)
        // Wide letters, so each line holds fewer of them.
        let widestName = amber.renamed(to: "Wild Wonder Waves Within")
        for (theme, fileName) in [(amber, "renaming-card"), (longestName, "renaming-card-longest-name"), (widestName, "renaming-card-wide-letters")] {
            let renaming = try await renamingCard(of: theme, named: fileName)
            let textField = try #require(renaming.textField)
            #expect(textShowsWhole(in: textField), "the field clips \(theme.name)")
            // The field stays inside the card, and the card keeps the size it has while it shows the name.
            let notRenaming = try await renamingCard(of: theme, named: "\(fileName)-not-renaming", startsRenaming: false)
            #expect(notRenaming.textField == nil)
            #expect(renaming.cardSize == notRenaming.cardSize, "the card is \(renaming.cardSize) while renaming and \(notRenaming.cardSize) otherwise")
        }
    }

    // MARK: - The pointing hand on entry

    @Test func enteringAControlSetsThePointingHandAndLeavingSetsTheArrow() {
        // A tracking area that is `.activeAlways` gets no cursorUpdate, so moving from one control to the next in an open
        // panel must set the hand on entry, or the arrow the first control's exit set stays. The overrides only call these.
        let hoverView = HoverAndPointerNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        var cursorsSet: [NSCursor] = []
        hoverView.setTheCursor = { cursorsSet.append($0) }
        hoverView.thePointerEntered()
        #expect(cursorsSet.count == 1 && cursorsSet[0] === NSCursor.pointingHand)
        #expect(hoverView.reportedHover)
        hoverView.thePointerLeft()
        #expect(cursorsSet.count == 2 && cursorsSet[1] !== NSCursor.pointingHand)
        #expect(!hoverView.reportedHover)
    }

    @Test func movingBetweenTwoAdjacentControlsLeavesTheHandInEitherEventOrder() {
        // AppKit may deliver the new control's entry before the old control's exit, so the exit must look at where the pointer is
        // instead of assuming it left every control. Both views sit in one window, with the pointer over the second.
        func cursorsSetAfter(pointerAt pointerLocation: CGPoint, _ events: (_ firstView: HoverAndPointerNSView, _ secondView: HoverAndPointerNSView) -> Void) -> [String] {
            let window = NSWindow(contentRect: NSRect(x: -92_000, y: -92_000, width: 160, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
            let firstView = HoverAndPointerNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
            let secondView = HoverAndPointerNSView(frame: NSRect(x: 80, y: 0, width: 80, height: 40))
            contentView.addSubview(firstView)
            contentView.addSubview(secondView)
            window.contentView = contentView
            var cursorsSet: [String] = []
            for (name, hoverView) in [("first", firstView), ("second", secondView)] {
                hoverView.mouseLocationInTheWindow = { _ in pointerLocation }
                hoverView.setTheCursor = { cursorsSet.append("\(name) \($0 === NSCursor.pointingHand ? "hand" : "arrow")") }
            }
            events(firstView, secondView)
            return cursorsSet
        }
        let pointerOverTheSecondView = CGPoint(x: 120, y: 20)
        let enterThenExit = cursorsSetAfter(pointerAt: pointerOverTheSecondView) { firstView, secondView in
            secondView.thePointerEntered()
            firstView.thePointerLeft()
        }
        #expect(enterThenExit.last?.hasSuffix("hand") == true, "the new control's entry came first, and the old control's exit left \(enterThenExit)")
        let exitThenEnter = cursorsSetAfter(pointerAt: pointerOverTheSecondView) { firstView, secondView in
            firstView.thePointerLeft()
            secondView.thePointerEntered()
        }
        #expect(exitThenEnter.last?.hasSuffix("hand") == true, "the old control's exit came first, and the new control's entry left \(exitThenEnter)")
        // With the pointer over neither control, the exit still sets the arrow.
        let exitOverNothing = cursorsSetAfter(pointerAt: CGPoint(x: 400, y: 20)) { firstView, _ in
            firstView.thePointerLeft()
        }
        #expect(exitOverNothing == ["first arrow"], "the pointer was over no control, and the exit left \(exitOverNothing)")
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

    @Test func onlyTheViewUnderAStillPointerReportsAHoverAfterARelayout() {
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

    @Test func theAgentListsFlipsRefreshEachRowsHoverFromWhereThePointerIs() {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 80, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 80, height: 80))
        let rowHoverView = HoverAndPointerNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        contentView.addSubview(rowHoverView)
        var mouseLocationInTheWindow = CGPoint(x: 200, y: 200)
        rowHoverView.mouseLocationInTheWindow = { _ in mouseLocationInTheWindow }
        var reportedHovers: [Bool] = []
        rowHoverView.onHoverChange = { reportedHovers.append($0) }
        window.contentView = contentView
        window.orderFrontRegardless()
        defer { window.close() }
        // The pointer crossed into the row while the window ignored the mouse, so no entry arrived; the flip to taking the
        // mouse finds it there.
        mouseLocationInTheWindow = CGPoint(x: 40, y: 20)
        refreshTheRowHovers(in: contentView, windowPassesTheMouseThrough: false)
        #expect(reportedHovers == [true])
        // The pointer left the row for the shadow margin, and the flip to passing the mouse through clears the hover.
        mouseLocationInTheWindow = CGPoint(x: 200, y: 200)
        refreshTheRowHovers(in: contentView, windowPassesTheMouseThrough: true)
        #expect(reportedHovers == [true, false])
    }

    // MARK: - The approval badge on a light menu bar

    @Test func theSettledMarksAndAPausedChipKeepTheirShapesInsideTheDisc() throws {
        let startedAt = Date(timeIntervalSinceNow: -30)
        var agent = BackgroundAgent(
            id: UUID(), kind: .task, subject: "Booster", studyGuideVideoKey: nil, startedAt: startedAt,
            currentStepStartedAt: startedAt, endedAt: nil, phase: .running(completedStepCount: 0)
        )
        let allowedDisc = AgentTokenDiscView(agent: agent, approvalSettledMark: .allowed)
        let notAllowedDisc = AgentTokenDiscView(agent: agent, approvalSettledMark: .notAllowed)
        agent.pausedAt = Date()
        let pausedChip = AgentTokenDiscView(agent: agent).grayscale(1)
        let bitmap = try render(HStack(spacing: 12) { allowedDisc; notAllowedDisc; pausedChip }, named: "disc-settled-marks-and-paused-chip")
        // Three 22 point discs, 12 points apart, inside the 24 point padding.
        #expect(bitmap.size.width == 24 * 2 + 3 * AgentTokenMetrics.discDiameter + 2 * 12)
    }

    @Test func theProblemBadgeKeepsItsDarkRimAndIsRedOnALightAndADarkMenuBar() throws {
        for (menuBarHex, foreground, fileName) in [("#F2F2F2", NSColor.black, "menu-icon-problem-light-bar"), ("#1E1E1E", NSColor.white, "menu-icon-problem-dark-bar")] {
            let problemIcon = MenuBarIconArt.image(for: .idle, cursor: .triangle, badge: .problem, foreground: foreground)
            let iconView = Image(nsImage: problemIcon).frame(width: MenuBarIconArt.size.width, height: MenuBarIconArt.size.height)
            let bitmap = try render(iconView, named: fileName, background: Color(hex: menuBarHex))
            let padding: CGFloat = 24
            let pixelsPerPoint = scale(of: bitmap)
            let badgeCenterX = Int((padding + MenuBarIconArt.badgeCenter.x) * pixelsPerPoint)
            let badgeCenterY = Int((padding + MenuBarIconArt.badgeCenter.y) * pixelsPerPoint)
            let badgePixel = try #require(bitmap.colorAt(x: badgeCenterX, y: badgeCenterY)?.usingColorSpace(.sRGB))
            #expect(badgePixel.redComponent > 0.8 && badgePixel.greenComponent < 0.45 && badgePixel.blueComponent < 0.45)
            let rimOffset = Int((MenuBarIconArt.badgeDiameter / 2 + 0.5) * pixelsPerPoint)
            let rimPixel = try #require(bitmap.colorAt(x: badgeCenterX + rimOffset, y: badgeCenterY)?.usingColorSpace(.sRGB))
            #expect(luminance(rimPixel) < 0.35)
        }
    }

    @Test func theApprovalBadgeKeepsItsDarkRimOnALightAndADarkMenuBar() throws {
        for (menuBarHex, foreground, fileName) in [("#F2F2F2", NSColor.black, "menu-icon-badge-light-bar"), ("#1E1E1E", NSColor.white, "menu-icon-badge-dark-bar")] {
            let badgedIcon = MenuBarIconArt.image(for: .idle, cursor: .triangle, badge: .needsYourOK, foreground: foreground)
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
