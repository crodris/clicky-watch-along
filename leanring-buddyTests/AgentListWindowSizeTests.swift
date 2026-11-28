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

    /// The largest `largestDifferenceFromTheCardsBottomColor` over rows measured in points above the Card's bottom edge.
    private func largestDifferenceAboveTheCardsBottomEdge(
        in bitmap: NSBitmapImageRep, contentView: NSView, pointsAboveTheEdge: [CGFloat], fromX firstX: CGFloat, toX lastX: CGFloat
    ) -> Int {
        let cardBottomY = contentView.bounds.height - AgentListWindowMargins.bottom
        return pointsAboveTheEdge.map {
            largestDifferenceFromTheCardsBottomColor(in: bitmap, rowAtY: cardBottomY - $0, fromX: firstX, toX: lastX)
        }.max() ?? 0
    }

    /// Renders the view again and again, for up to 10 seconds, until `isSettled` accepts a render, and returns the last one. The
    /// scroll view and the fade's mask follow a scroll on a later pass of the run loop, which no property of the view reports.
    private func render(_ view: NSView, untilSettled description: String, _ isSettled: (NSBitmapImageRep) -> Bool) async throws -> NSBitmapImageRep {
        var bitmap = try render(view)
        try await waitFor(description) {
            guard let nextBitmap = try? render(view) else { return false }
            bitmap = nextBitmap
            return isSettled(nextBitmap)
        }
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
        let contentView = try #require(panel.contentView)
        let cardBottomY = contentView.bounds.height - AgentListWindowMargins.bottom
        let buttonColumnsFirstX = AgentListWindowMargins.leading + 52
        // The last row's Hear answer button sits under its title, 52 points in from the Card's left edge, and must end at least
        // as high above the Card's bottom edge as the fade is tall, so the 5 points from 7 to 3 above the edge hold only the
        // Card's surface. The render is taken once the scroll to the end has reached the screen, which is when those rows are bare.
        let bitmap = try await render(contentView, untilSettled: "the list scrolled to its end to be drawn") {
            largestDifferenceAboveTheCardsBottomEdge(
                in: $0, contentView: contentView, pointsAboveTheEdge: [7, 6, 5, 4, 3], fromX: buttonColumnsFirstX, toX: buttonColumnsFirstX + 130
            ) <= 12
        }
        for pointsAboveTheEdge in stride(from: 7.0, through: 3.0, by: -1.0) {
            let difference = largestDifferenceFromTheCardsBottomColor(
                in: bitmap, rowAtY: cardBottomY - pointsAboveTheEdge, fromX: buttonColumnsFirstX, toX: buttonColumnsFirstX + 130
            )
            #expect(difference <= 12, "\(pointsAboveTheEdge) points above the Card's bottom edge, a pixel differs from the surface by \(difference)")
        }
        // The button is 24 points tall and ends at least 12 points above the edge, so its white label sits well above the fade.
        // The bottom fade must leave that label whole.
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
        let contentView = try #require(panel.contentView)
        // The render is taken once the fade has softened the rows under the Card's bottom edge, which is the state asserted below.
        let bitmap = try await render(contentView, untilSettled: "the scrolled list's bottom rows to be faded") {
            largestDifferenceAboveTheCardsBottomEdge(
                in: $0, contentView: contentView, pointsAboveTheEdge: [6, 5, 4, 3, 2, 1], fromX: AgentListWindowMargins.leading + 40, toX: AgentListWindowMargins.leading + 260
            ) <= 40
        }
        let cardBottomY = contentView.bounds.height - AgentListWindowMargins.bottom
        for pointsAboveTheEdge in stride(from: 6.0, through: 1.0, by: -1.0) {
            let difference = largestDifferenceFromTheCardsBottomColor(
                in: bitmap, rowAtY: cardBottomY - pointsAboveTheEdge, fromX: AgentListWindowMargins.leading + 40, toX: AgentListWindowMargins.leading + 260
            )
            #expect(difference <= 40, "\(pointsAboveTheEdge) points above the edge, the last visible row is cut hard, differing from the surface by \(difference)")
        }
    }

    // MARK: - The bottom fade only where a list scrolls

    /// Where the bottom edge of the last row's Hear answer button sits, and how bright its 1 point edge draws there and 23 points
    /// higher, where the button's top edge is. The button is 24 points tall and its edge has one color, so the two match unless
    /// the fade softens the bottom one. A bottom edge more than 20 points above the Card's bottom edge is not found.
    private func lastButtonsEdge(
        in bitmap: NSBitmapImageRep, contentView: NSView
    ) -> (bottomEdgePointsAboveTheCardsEdge: CGFloat, bottomEdgeBrightness: Int, topEdgeBrightness: Int)? {
        let cardBottomY = contentView.bounds.height - AgentListWindowMargins.bottom
        let buttonColumnsFirstX = AgentListWindowMargins.leading + 52 + 20
        let buttonColumnsLastX = buttonColumnsFirstX + 80
        // The Card's own bottom edge draws in the first 2 points, so the search starts above it.
        var pointsAboveTheEdge: CGFloat = 3
        while pointsAboveTheEdge <= 20 {
            let difference = largestDifferenceFromTheCardsBottomColor(
                in: bitmap, rowAtY: cardBottomY - pointsAboveTheEdge, fromX: buttonColumnsFirstX, toX: buttonColumnsLastX
            )
            if difference > 12 {
                return (
                    pointsAboveTheEdge,
                    brightestChannel(in: bitmap, fromX: buttonColumnsFirstX, toX: buttonColumnsLastX, fromY: cardBottomY - pointsAboveTheEdge - 0.5, toY: cardBottomY - pointsAboveTheEdge + 0.5),
                    brightestChannel(in: bitmap, fromX: buttonColumnsFirstX, toX: buttonColumnsLastX, fromY: cardBottomY - pointsAboveTheEdge - 24, toY: cardBottomY - pointsAboveTheEdge - 22)
                )
            }
            pointsAboveTheEdge += 0.5
        }
        return nil
    }

    @Test(.showsARealWindow) func aScrolledListKeepsItsLastButtonAboveTheFadeAndDrawsItsEdgeWhole() async throws {
        let (controller, panel, scrollView) = try await overflowingList()
        defer { controller.close() }
        let documentView = try #require(scrollView.documentView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: documentView.frame.height - scrollView.contentView.bounds.height))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let contentView = try #require(panel.contentView)
        // A row met on the way to the end can sit in the search's window too, so the drawing counts as settled only once the
        // last button sits where the scrolled end puts it. A list that never gets there times out and records its issue.
        let bitmap = try await render(contentView, untilSettled: "the list scrolled to its end to be drawn") {
            guard let settledEdge = lastButtonsEdge(in: $0, contentView: contentView) else { return false }
            return settledEdge.bottomEdgePointsAboveTheCardsEdge >= AgentListScrollFade.height - 0.5
        }
        let edge = try #require(lastButtonsEdge(in: bitmap, contentView: contentView))
        #expect(edge.bottomEdgePointsAboveTheCardsEdge >= AgentListScrollFade.height - 0.5, "the last button ends \(edge.bottomEdgePointsAboveTheCardsEdge) points above the Card's edge, inside the \(AgentListScrollFade.height) point fade")
        #expect(edge.bottomEdgeBrightness >= edge.topEdgeBrightness - 2, "the last button's bottom edge draws at \(edge.bottomEdgeBrightness) and its top edge at \(edge.topEdgeBrightness)")
    }

    @Test(.showsARealWindow) func aListThatDoesNotScrollHasNoFadeOverItsLastButton() async throws {
        let themeSettings = makeThemeSettings()
        let store = BackgroundAgentStore(themeSettings: themeSettings)
        finishedAgent(in: store, subject: "Find the first landing")
        let controller = makeController(store: store, themeSettings: themeSettings)
        let panel = try #require(open(controller, expanding: nil))
        defer { controller.close() }
        let contentView = try #require(panel.contentView)
        try await waitFor("a window as tall as the short list") { panel.frame.height == contentView.fittingSize.height }
        let bitmap = try await render(contentView, untilSettled: "the short list to be drawn") {
            lastButtonsEdge(in: $0, contentView: contentView) != nil
        }
        let edge = try #require(lastButtonsEdge(in: bitmap, contentView: contentView))
        // The button ends 10 points above the Card's edge, inside the 12 point strip a fade would cover.
        #expect(edge.bottomEdgePointsAboveTheCardsEdge < AgentListScrollFade.height, "the short list's last button ends \(edge.bottomEdgePointsAboveTheCardsEdge) points above the Card's edge")
        #expect(edge.bottomEdgeBrightness >= edge.topEdgeBrightness - 2, "the last button's bottom edge draws at \(edge.bottomEdgeBrightness) and its top edge at \(edge.topEdgeBrightness), so a fade softens it")
    }

    @Test func rowsOverflowTheirScrollAreaOnlyPastHalfAPointOfRounding() {
        #expect(agentListRowsOverflow(contentHeight: 520, scrollAreaHeight: 480))
        #expect(!agentListRowsOverflow(contentHeight: 480, scrollAreaHeight: 480))
        #expect(!agentListRowsOverflow(contentHeight: 480.4, scrollAreaHeight: 480))
        #expect(agentListRowsOverflow(contentHeight: 480.6, scrollAreaHeight: 480))
    }
}
