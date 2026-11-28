//
//  ShadowMarginMousePassThroughTests.swift
//  leanring-buddyTests
//
//  The shared mechanism that lets a Card's window pass the mouse through its transparent shadow margin, and that each of the
//  five Card panels uses. Every window here sits far off every screen, at frames no other test uses, so no one sees it.
//

import AppKit
import SwiftUI
import Testing
@testable import Clicky

/// Where the test's pointer stands relative to a window.
private enum PointerSpot {
    case farAway
    case inTheShadowMargin
    case inTheCard
}

@MainActor
private final class TestPointer {
    var spot = PointerSpot.farAway

    /// The pointer's place on screen for `spot`, given the window it is measured against.
    func location(relativeTo windowFrame: CGRect?) -> CGPoint {
        guard let windowFrame else { return Self.farAwayPoint }
        let cardFrame = AgentListWindowMargins.cardFrame(inWindowFrame: windowFrame)
        switch spot {
        case .farAway: return Self.farAwayPoint
        case .inTheShadowMargin: return CGPoint(x: cardFrame.midX, y: cardFrame.minY - 20)
        case .inTheCard: return CGPoint(x: cardFrame.midX, y: cardFrame.midY)
        }
    }

    static let farAwayPoint = CGPoint(x: -60_000, y: -60_000)
}

/// The off-screen frame every panel test places its window in. No other test uses it.
private let offScreenVisibleFrame = CGRect(x: -45_000, y: -45_000, width: 1440, height: 900)

@MainActor
struct ShadowMarginMousePassThroughTests {
    // MARK: - The helper on a bare panel

    /// A panel with a plain content view, far off every screen.
    private func makePanel(size: CGSize) -> NonKeyFloatingPanel {
        let panel = NonKeyFloatingPanel(
            contentRect: CGRect(origin: CGPoint(x: -46_000, y: -46_000), size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: CGRect(origin: .zero, size: size))
        return panel
    }

    @Test func aStartUnderAPointerInTheMarginPassesTheMouseAtOnce() throws {
        let panel = makePanel(size: CGSize(width: 300, height: 300))
        defer { panel.close() }
        let pointer = TestPointer()
        pointer.spot = .inTheShadowMargin
        let helper = ShadowMarginMousePassThrough(panel: panel, mouseLocationOnScreen: { pointer.location(relativeTo: panel.frame) })
        defer { helper.stop() }
        // No timer tick and no wait: a click right after the window appears must already reach the page.
        helper.start()
        #expect(panel.ignoresMouseEvents)
        pointer.spot = .inTheCard
        helper.update()
        #expect(!panel.ignoresMouseEvents)
    }

    @Test func aResizeUnderAPointerInTheNewMarginPassesTheMouseAtOnce() throws {
        let panel = makePanel(size: CGSize(width: 300, height: 300))
        defer { panel.close() }
        let firstFrame = panel.frame
        // A point in the margin of the taller window, too far below the shorter one for the timer to be reading the mouse.
        let tallerFrame = CGRect(x: firstFrame.minX, y: firstFrame.minY - 200, width: 300, height: 500)
        let pointInTheNewMargin = CGPoint(x: tallerFrame.midX, y: tallerFrame.minY + 10)
        #expect(!firstFrame.insetBy(dx: -ShadowMarginMousePassThrough.pointerNearDistance, dy: -ShadowMarginMousePassThrough.pointerNearDistance).contains(pointInTheNewMargin))
        let helper = ShadowMarginMousePassThrough(panel: panel, mouseLocationOnScreen: { pointInTheNewMargin })
        defer { helper.stop() }
        helper.start()
        #expect(!panel.ignoresMouseEvents)
        #expect(helper.clickThroughTimer == nil)
        panel.setFrame(tallerFrame, display: true)
        #expect(panel.ignoresMouseEvents)
    }

    @Test func theTimerReadsTheMouseOnlyWhileThePointerIsNearTheWindow() throws {
        let panel = makePanel(size: CGSize(width: 300, height: 300))
        defer { panel.close() }
        let pointer = TestPointer()
        let helper = ShadowMarginMousePassThrough(panel: panel, mouseLocationOnScreen: { pointer.location(relativeTo: panel.frame) })
        defer { helper.stop() }
        helper.start()
        #expect(helper.clickThroughTimer == nil)
        pointer.spot = .inTheCard
        helper.update()
        #expect(helper.clickThroughTimer != nil)
        pointer.spot = .farAway
        helper.update()
        #expect(helper.clickThroughTimer == nil)
        #expect(!panel.ignoresMouseEvents)
    }

    @Test func aStoppedHelperWatchesNothing() throws {
        let panel = makePanel(size: CGSize(width: 300, height: 300))
        defer { panel.close() }
        let pointer = TestPointer()
        pointer.spot = .inTheCard
        let helper = ShadowMarginMousePassThrough(panel: panel, mouseLocationOnScreen: { pointer.location(relativeTo: panel.frame) })
        helper.start()
        #expect(helper.clickThroughTimer != nil)
        #expect(helper.pointerEntryView?.superview === panel.contentView)
        helper.stop()
        #expect(helper.clickThroughTimer == nil)
        #expect(helper.pointerEntryView == nil)
        #expect(panel.contentView?.subviews.isEmpty == true)
        // A resize after the stop decides nothing.
        pointer.spot = .inTheShadowMargin
        panel.setFrame(panel.frame.insetBy(dx: -10, dy: -10), display: true)
        #expect(!panel.ignoresMouseEvents)
    }

    // MARK: - Each of the five panels

    /// The panel's window frame, read by the pointer closure each panel's helper is given.
    private func thePointerFollowsTheWindow(_ pointer: TestPointer, _ windowFrame: @escaping () -> CGRect?) -> () -> CGPoint {
        { pointer.location(relativeTo: windowFrame()) }
    }

    private func requireOffEveryScreen(_ panel: NSPanel) {
        #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) }, "the panel at \(panel.frame) must sit off every screen")
    }

    @Test(.showsARealWindow) func theQuizSummaryCardPassesTheMouseThroughItsShadowMargin() throws {
        let controller = VideoQuizSummaryPanelController()
        controller.visibleFrameForTests = offScreenVisibleFrame
        let pointer = TestPointer()
        pointer.spot = .inTheShadowMargin
        controller.mouseLocationOnScreen = thePointerFollowsTheWindow(pointer) { controller.panel?.frame }
        let recap = try #require(VideoRecap(
            quizResults: [StudyGuideQuizResult(question: "What does the vent do?", answerLabel: "vent", explanation: "Lava rises through it.", askedAtSeconds: 134, result: .missed)],
            studyGuideRecord: nil
        ))
        controller.show(recap: recap, moment: .quizEnded, videoRect: nil, accentColor: Color(hex: "#3380FF"), goBackToTheMissedQuestion: { _ in }, openTheStudyGuide: {})
        defer { controller.close(animated: false) }
        let panel = try #require(controller.panel)
        requireOffEveryScreen(panel)
        #expect(panel.ignoresMouseEvents, "a click in the shadow margin must reach the page under it")
        pointer.spot = .inTheCard
        panel.setFrame(panel.frame.offsetBy(dx: 0, dy: 1), display: true)
        #expect(!panel.ignoresMouseEvents, "a click on the Card is the Card's")
        controller.close(animated: false)
        #expect(controller.panel == nil)
    }

    @Test(.showsARealWindow) func theInstallCardPassesTheMouseThroughItsShadowMargin() throws {
        let controller = ThemeInstallCardPanelController()
        controller.visibleFrameForTests = offScreenVisibleFrame
        let pointer = TestPointer()
        pointer.spot = .inTheShadowMargin
        controller.mouseLocationOnScreen = thePointerFollowsTheWindow(pointer) { controller.panel?.frame }
        let theme = try ClickyTheme.parse(themeJSON: goodVersion2ThemeJSON, id: "installing", origin: .idea, pictureIsAvailable: false)
        controller.show(PendingThemeInstall(packageURL: URL(fileURLWithPath: "/tmp/Moonlit.clickytheme"), theme: theme, pictureJPEG: nil), decide: { _ in })
        defer { controller.hide() }
        let panel = try #require(controller.panel)
        requireOffEveryScreen(panel)
        #expect(panel.ignoresMouseEvents, "a click in the shadow margin must reach the app under it")
        pointer.spot = .inTheCard
        panel.setFrame(panel.frame.offsetBy(dx: 0, dy: 1), display: true)
        #expect(!panel.ignoresMouseEvents, "a click on the Card is the Card's")
    }

    @Test(.showsARealWindow) func theAgentListPassesTheMouseThroughItsMarginAndReadsThePointerOnlyWhileItIsNear() throws {
        let themeSettings = makeThemeSettings()
        let controller = AgentListPanelController(
            store: BackgroundAgentStore(themeSettings: themeSettings),
            themeSettings: themeSettings,
            approvalDesk: HarnessApprovalDesk { _, _, _ in },
            actions: AgentListActions(cancelAgent: { _ in }, showReadyScene: {}, hearTaskAnswer: {}, tryAgain: { _ in }, answerApproval: { _, _, _ in })
        )
        let pointer = TestPointer()
        controller.mouseLocationOnScreen = thePointerFollowsTheWindow(pointer) { controller.panel?.frame }
        controller.open(
            anchorTopLeft: CGPoint(x: offScreenVisibleFrame.minX + 100, y: offScreenVisibleFrame.maxY - 100),
            visibleFrame: offScreenVisibleFrame, initiallyExpandedAgentID: nil, glideOriginPoint: .zero, screen: nil
        )
        defer { controller.close() }
        let panel = try #require(controller.panel)
        requireOffEveryScreen(panel)
        // The list used to read the mouse 60 times a second for as long as it was open.
        #expect(controller.clickThroughTimer == nil, "no timer runs while the pointer is far from the window")
        #expect(!panel.ignoresMouseEvents)
        pointer.spot = .inTheShadowMargin
        panel.setFrame(panel.frame.offsetBy(dx: 0, dy: 1), display: true)
        #expect(panel.ignoresMouseEvents)
        #expect(controller.clickThroughTimer != nil)
        controller.close()
        #expect(controller.clickThroughTimer == nil)
    }
}
