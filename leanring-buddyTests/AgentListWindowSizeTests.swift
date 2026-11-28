//
//  AgentListWindowSizeTests.swift
//  leanring-buddyTests
//
//  The agent list's window follows its Card's height both ways, and a list taller than its maximum keeps the Card's bottom
//  padding when it is scrolled to the end. Every window here sits far off every screen, at frames no other test uses.
//

import AppKit
import SwiftUI
import Testing
@testable import Clicky

/// The off-screen frame these tests place the list in. No other test uses it.
private let agentListOffScreenVisibleFrame = CGRect(x: -56_000, y: -56_000, width: 1440, height: 900)

@MainActor
struct AgentListWindowSizeTests {
    private func makeController(store: BackgroundAgentStore, themeSettings: CompanionThemeSettings) -> AgentListPanelController {
        AgentListPanelController(
            store: store,
            themeSettings: themeSettings,
            approvalDesk: HarnessApprovalDesk { _, _, _ in },
            actions: AgentListActions(cancelAgent: { _ in }, showReadyScene: {}, hearTaskAnswer: {}, tryAgain: { _ in }, answerApproval: { _, _, _ in })
        )
    }

    private func open(_ controller: AgentListPanelController, expanding agentID: UUID?) -> NonKeyFloatingPanel? {
        controller.open(
            anchorTopLeft: CGPoint(x: agentListOffScreenVisibleFrame.minX + 100, y: agentListOffScreenVisibleFrame.maxY - 100),
            visibleFrame: agentListOffScreenVisibleFrame, initiallyExpandedAgentID: agentID, glideOriginPoint: .zero, screen: nil
        )
        return controller.panel
    }

    /// Polls until `condition` holds, or fails the test after 10 seconds.
    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Waits until the window is as tall as the Card asks it to be and `isTheExpectedHeight` accepts that height.
    private func waitForTheWindowToFollowTheCard(_ panel: NSPanel, _ description: String, isTheExpectedHeight: (CGFloat) -> Bool) async throws {
        try await waitFor(description) {
            guard let contentView = panel.contentView else { return false }
            return panel.frame.height == contentView.fittingSize.height && isTheExpectedHeight(panel.frame.height)
        }
    }

    /// An agent that has finished, with an answer waiting to be heard, so its row has a "Hear answer" button.
    private func finishedAgent(in store: BackgroundAgentStore, subject: String) {
        let agentID = store.start(kind: .task)
        store.setSubject(subject, for: agentID)
        store.finish(agentID, with: .answer(spokenSummary: "It landed.", pageURL: nil))
    }

    // MARK: - The window follows the Card

    @Test(.showsARealWindow) func theWindowFollowsTheCardDownWhenARowCollapsesAndBackUpWhenItExpands() async throws {
        let themeSettings = makeThemeSettings()
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        let runningAgentID = store.start(kind: .task)
        store.setSubject("Compare the two booster catches", for: runningAgentID)
        finishedAgent(in: store, subject: "Find the first landing")
        let controller = makeController(store: store, themeSettings: themeSettings)
        let panel = try #require(open(controller, expanding: runningAgentID))
        defer { controller.close() }
        #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) }, "the list at \(panel.frame) must sit off every screen")
        // Two rows, one of them expanded, with a button on the finished one.
        try await waitForTheWindowToFollowTheCard(panel, "the open list's height") { $0 > 300 }
        let expandedHeight = panel.frame.height

        // The same animation a click on the row plays. A size preference only ever grew the window, so it stayed tall.
        for _ in 1...2 {
            withAnimation(DS.Move.glide.animation(reduceMotionIsOn: false)) { controller.uiState.expandedAgentID = nil }
            // The window kept its height after a row collapsed, since a size preference only ever grew it.
            try await waitForTheWindowToFollowTheCard(panel, "the window to shrink with the collapsed row") { $0 < expandedHeight }
            withAnimation(DS.Move.glide.animation(reduceMotionIsOn: false)) { controller.uiState.expandedAgentID = runningAgentID }
            try await waitForTheWindowToFollowTheCard(panel, "the window to grow with the expanded row") { $0 == expandedHeight }
        }
    }

    @Test(.showsARealWindow) func theWindowGrowsWhenARunningRowFinishesAndGainsItsButton() async throws {
        let themeSettings = makeThemeSettings()
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        let finishingAgentID = store.start(kind: .task)
        store.setSubject("Find the first landing", for: finishingAgentID)
        let expandedAgentID = store.start(kind: .task)
        store.setSubject("Compare the two booster catches", for: expandedAgentID)
        let controller = makeController(store: store, themeSettings: themeSettings)
        let panel = try #require(open(controller, expanding: expandedAgentID))
        defer { controller.close() }
        try await waitForTheWindowToFollowTheCard(panel, "the open list's height") { $0 > 200 }
        let heightBefore = panel.frame.height
        store.finish(finishingAgentID, with: .answer(spokenSummary: "It landed.", pageURL: nil))
        try await waitForTheWindowToFollowTheCard(panel, "the finished row's Hear answer button to grow the window") { $0 > heightBefore }
    }

    // MARK: - A list taller than its maximum

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { subview -> [NSScrollView] in
            ((subview as? NSScrollView).map { [$0] } ?? []) + scrollViews(in: subview)
        }
    }

    /// The channels of one pixel of a render, at a point measured in points from its top left.
    private func channels(of bitmap: NSBitmapImageRep, atX x: CGFloat, y: CGFloat) -> [Int] {
        let scale = CGFloat(bitmap.pixelsWide) / bitmap.size.width
        let color = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .black
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    /// The largest difference in any channel between the Card's surface and any pixel of a row of the render. The surface is read
    /// from the Card's left padding, 12 points in, past the Card's rounded corner and left of the rows' 14 point padding, where no row draws.
    private func largestDifferenceFromTheCardsBottomColor(in bitmap: NSBitmapImageRep, rowAtY y: CGFloat, fromX firstX: CGFloat, toX lastX: CGFloat) -> Int {
        let cardBottomColor = channels(of: bitmap, atX: AgentListWindowMargins.leading + 12, y: y)
        var largestDifference = 0
        var x = firstX
        while x < lastX {
            let pixel = channels(of: bitmap, atX: x, y: y)
            largestDifference = max(largestDifference, zip(pixel, cardBottomColor).map { abs($0 - $1) }.max() ?? 0)
            x += 0.5
        }
        return largestDifference
    }

    /// A list of one running row, expanded, and three finished ones: taller than the maximum, so its rows scroll.
    private func overflowingList() async throws -> (controller: AgentListPanelController, panel: NonKeyFloatingPanel, scrollView: NSScrollView) {
        let themeSettings = makeThemeSettings()
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        for index in 0..<3 { finishedAgent(in: store, subject: "Find the first landing \(index)") }
        let runningAgentID = store.start(kind: .task)
        store.setSubject("Compare the two booster catches", for: runningAgentID)
        let controller = makeController(store: store, themeSettings: themeSettings)
        let panel = try #require(open(controller, expanding: runningAgentID))
        let contentView = try #require(panel.contentView)
        try await waitFor("the rows' scroll view and a window as tall as the list's maximum") {
            !scrollViews(in: contentView).isEmpty && panel.frame.height == contentView.fittingSize.height && panel.frame.height > 400
        }
        let scrollView = try #require(scrollViews(in: contentView).first)
        return (controller, panel, scrollView)
    }

    private func render(_ view: NSView) throws -> NSBitmapImageRep {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// The brightest channel of any pixel in a box of the render, from its top left in points.
    private func brightestChannel(in bitmap: NSBitmapImageRep, fromX firstX: CGFloat, toX lastX: CGFloat, fromY firstY: CGFloat, toY lastY: CGFloat) -> Int {
        var brightest = 0
        var y = firstY
        while y < lastY {
            var x = firstX
            while x < lastX {
                brightest = max(brightest, channels(of: bitmap, atX: x, y: y).max() ?? 0)
                x += 0.5
            }
            y += 0.5
        }
        return brightest
    }

    @Test(.showsARealWindow) func aListScrolledToItsEndKeepsTheCardsBottomPaddingUnderTheLastButton() async throws {
        let (controller, panel, scrollView) = try await overflowingList()
        defer { controller.close() }
        let documentView = try #require(scrollView.documentView)
        try #require(documentView.frame.height > scrollView.contentView.bounds.height, "the list should overflow")
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentView.frame.height - scrollView.contentView.bounds.height))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(200))
        let contentView = try #require(panel.contentView)
        let bitmap = try render(contentView)
        // The last row's Hear answer button sits under its title, 52 points in from the Card's left edge, and must end at least
        // 8 points above the Card's bottom edge, so the 5 points from 7 to 3 above the edge hold only the Card's surface.
        let cardBottomY = contentView.bounds.height - AgentListWindowMargins.bottom
        let buttonColumnsFirstX = AgentListWindowMargins.leading + 52
        for pointsAboveTheEdge in stride(from: 7.0, through: 3.0, by: -1.0) {
            let difference = largestDifferenceFromTheCardsBottomColor(
                in: bitmap, rowAtY: cardBottomY - pointsAboveTheEdge, fromX: buttonColumnsFirstX, toX: buttonColumnsFirstX + 130
            )
            #expect(difference <= 12, "\(pointsAboveTheEdge) points above the Card's bottom edge, a pixel differs from the surface by \(difference)")
        }
        // The button is 24 points tall and ends 10 points above the edge, so its white label sits 12 to 24 points above it. The
        // bottom fade must leave that label whole.
        let labelBrightness = brightestChannel(
            in: bitmap, fromX: buttonColumnsFirstX + 20, toX: buttonColumnsFirstX + 100, fromY: cardBottomY - 24, toY: cardBottomY - 14
        )
        #expect(labelBrightness > 200, "the last button's label is faded to \(labelBrightness)")
    }

    @Test(.showsARealWindow) func aListTallerThanItsMaximumFadesItsLastVisibleRowInsteadOfCuttingItAtTheCardsEdge() async throws {
        let (controller, panel, scrollView) = try await overflowingList()
        defer { controller.close() }
        // Scrolled to the top, the last visible row runs under the Card's bottom edge, where its green progress line would
        // otherwise be a bright hard cut.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        try await Task.sleep(for: .milliseconds(200))
        let contentView = try #require(panel.contentView)
        let bitmap = try render(contentView)
        let cardBottomY = contentView.bounds.height - AgentListWindowMargins.bottom
        for pointsAboveTheEdge in stride(from: 6.0, through: 1.0, by: -1.0) {
            let difference = largestDifferenceFromTheCardsBottomColor(
                in: bitmap, rowAtY: cardBottomY - pointsAboveTheEdge, fromX: AgentListWindowMargins.leading + 40, toX: AgentListWindowMargins.leading + 260
            )
            #expect(difference <= 40, "\(pointsAboveTheEdge) points above the edge, the last visible row is cut hard, differing from the surface by \(difference)")
        }
    }
}
