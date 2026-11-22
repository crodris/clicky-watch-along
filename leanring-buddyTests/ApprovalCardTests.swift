//
//  ApprovalCardTests.swift
//  leanring-buddyTests
//
//  When the approval card counts a summary as read: only once the ranges of it that have been inside the scroll area
//  cover it from top to bottom, so dragging straight to the end does not count. The desk's 1 second clock is tested
//  in AgentHarnessTests. The card's words for each phase, its rail's share, its rows, and its rendered height are here.
//

import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Clicky

@MainActor
struct ApprovalCardTests {
    @Test func theTopAndTheBottomAloneLeaveTheMiddleUnseenAndTheMiddleCompletesIt() {
        let summaryHeight: CGFloat = 480
        let topOfTheSummary: ClosedRange<CGFloat> = 0...200
        let bottomOfTheSummary: ClosedRange<CGFloat> = 280...480
        #expect(!approvalSummaryWasShownWhole(seenRanges: [topOfTheSummary, bottomOfTheSummary], summaryHeight: summaryHeight), "the middle never showed")
        #expect(!approvalSummaryWasShownWhole(seenRanges: [bottomOfTheSummary], summaryHeight: summaryHeight), "a jump straight to the end saw only the end")
        #expect(!approvalSummaryWasShownWhole(seenRanges: [], summaryHeight: summaryHeight))

        let middleOfTheSummary: ClosedRange<CGFloat> = 190...290
        #expect(approvalSummaryWasShownWhole(seenRanges: [bottomOfTheSummary, middleOfTheSummary, topOfTheSummary], summaryHeight: summaryHeight), "overlapping ranges in any order cover it")
        #expect(approvalSummaryWasShownWhole(seenRanges: [0...120], summaryHeight: 120), "a summary that fits is shown at once")
        #expect(approvalSummaryWasShownWhole(seenRanges: [0...300, 50...100], summaryHeight: 300), "a range inside another adds nothing and takes nothing away")
    }

    @Test func aSliverOfLayoutRoundingCountsAsCoveredButARealGapDoesNot() {
        #expect(approvalSummaryWasShownWhole(seenRanges: [0...200, 200.5...400], summaryHeight: 400), "half a point between ranges is rounding")
        #expect(approvalSummaryWasShownWhole(seenRanges: [0.5...399.5], summaryHeight: 400), "half a point short at either end is rounding")
        #expect(!approvalSummaryWasShownWhole(seenRanges: [0...200, 201.5...400], summaryHeight: 400), "a gap of 1.5 points is past the 1 point tolerance")
        #expect(!approvalSummaryWasShownWhole(seenRanges: [0...200, 203...400], summaryHeight: 400), "three points is a line's top or bottom edge unseen")
        #expect(!approvalSummaryWasShownWhole(seenRanges: [3...400], summaryHeight: 400), "the first lines never showed")
        #expect(!approvalSummaryWasShownWhole(seenRanges: [0...397], summaryHeight: 400), "the last lines never showed")
    }

    @Test func theRangeInViewFollowsTheScrollOffsetAndStaysInsideTheSummary() {
        #expect(approvalSummaryRangeInView(summaryMinY: 0, summaryHeight: 480, scrollAreaHeight: 200) == 0...200, "at the top")
        #expect(approvalSummaryRangeInView(summaryMinY: -150, summaryHeight: 480, scrollAreaHeight: 200) == 150...350, "scrolled down 150 points")
        #expect(approvalSummaryRangeInView(summaryMinY: -280, summaryHeight: 480, scrollAreaHeight: 200) == 280...480, "at the end")
        #expect(approvalSummaryRangeInView(summaryMinY: 20, summaryHeight: 480, scrollAreaHeight: 200) == 0...180, "pulled past the top")
        #expect(approvalSummaryRangeInView(summaryMinY: -300, summaryHeight: 480, scrollAreaHeight: 200) == 300...480, "bounced past the end")
        #expect(approvalSummaryRangeInView(summaryMinY: -500, summaryHeight: 480, scrollAreaHeight: 200) == nil, "nothing of it is in view")
    }

    @Test func aCardForAnotherRequestStartsWithNoSeenRanges() {
        var seenRanges = ApprovalSummarySeenRanges()
        seenRanges.record(0...200, forApprovalID: "approval-A")
        seenRanges.record(180...480, forApprovalID: "approval-A")
        #expect(seenRanges.ranges == [0...480], "ranges for one request merge")
        #expect(approvalSummaryWasShownWhole(seenRanges: seenRanges.ranges, summaryHeight: 480))

        // Request B becomes the oldest, and its first report must not inherit what A's summary showed.
        seenRanges.record(280...480, forApprovalID: "approval-B")
        #expect(seenRanges.ranges == [280...480])
        #expect(!approvalSummaryWasShownWhole(seenRanges: seenRanges.ranges, summaryHeight: 480))
    }

    @Test func theRailShareCountsOnlyThePartsSeenAndNeverPassesTheWhole() {
        #expect(approvalSummaryShareSeen(seenRanges: [], summaryHeight: 400) == 0)
        #expect(approvalSummaryShareSeen(seenRanges: [0...100, 300...400], summaryHeight: 400) == 0.5, "a gap in the middle is not read")
        #expect(approvalSummaryShareSeen(seenRanges: [0...250, 200...400], summaryHeight: 400) == 1, "overlapping ranges count once")
        #expect(approvalSummaryShareSeen(seenRanges: [0...100], summaryHeight: 0) == 0, "a summary not laid out yet")
    }

    @Test func theSummarySplitsIntoOneRowPerLineAndKeepsItsText() {
        #expect(approvalSummaryRows("Open this link in your browser.\nHost: example.com\nLink: https://example.com/a") == [
            "Open this link in your browser.", "Host: example.com", "Link: https://example.com/a",
        ])
        // The harness writes a line break inside a value as ⏎, which stays inside its row, and an empty line keeps its height.
        #expect(approvalSummaryRows("text: one⏎two\n\nend") == ["text: one⏎two", " ", "end"])
    }

    @Test func eachPhaseHasItsOwnStatusLine() {
        let phases: [ApprovalCardPhase] = [
            .waiting(.summaryNotYetSeen), .waiting(.readyInAMoment), .waiting(.ready), .sending,
            .ended(.allowed(.once)), .ended(.allowed(.always)), .ended(.declined), .ended(.timedOut), .ended(.noReply),
        ]
        let statusLines = phases.map { approvalCardStatusText(phase: $0, reduceMotionIsOn: false) }
        #expect(Set(statusLines).count == phases.count, "no two phases read the same")
        #expect(approvalCardStatusText(phase: .waiting(.readyInAMoment), reduceMotionIsOn: true) == "Ready in 1 s")
    }

    // MARK: - Rendered

    /// The summary the card shows when it is long enough to scroll.
    private static let longSummary = "Replace your clipboard with this text (420 characters):\n" + String(repeating: "Flight 5 caught the booster with the tower arms. ", count: 9)

    /// The clock start that gives a waiting card its readiness now, since the card reads its readiness on its own clock.
    private func wholeSummaryShownSince(for phase: ApprovalCardPhase) -> Date? {
        switch phase {
        case .waiting(.ready): return Date(timeIntervalSince1970: 0)
        case .waiting(.readyInAMoment): return Date().addingTimeInterval(-0.4)
        default: return nil
        }
    }

    private func renderedCard(phase: ApprovalCardPhase, summary: String = longSummary, reduceMotionIsOn: Bool = false) throws -> NSBitmapImageRep {
        let card = ApprovalCardView(
            shownCard: ShownApprovalCard(
                request: HarnessApprovalRequest(taskID: UUID(), approvalID: "approval-1", capability: .sends, summary: summary),
                phase: phase
            ),
            agentName: "Hinata",
            learnerWords: "compare this catch to the first booster catch and copy what you find to my clipboard",
            wholeSummaryShownSince: wholeSummaryShownSince(for: phase),
            answerApproval: { _, _, _ in },
            summaryWasShownWhole: { _ in },
            reduceMotionOverride: reduceMotionIsOn
        )
        // A hosting view in a 2x window, since ImageRenderer draws neither a scroll view nor a focusable button.
        let hostingView = NSHostingView(rootView: card.frame(width: AgentListPanelController.panelWidth).background(DS.Colors.background))
        let cardSize = hostingView.fittingSize
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: cardSize), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.frame = CGRect(origin: .zero, size: cardSize)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        // Set CLICKY_APPROVAL_CARD_SHOTS_DIR to look at each state.
        if let shotsDirectory = ProcessInfo.processInfo.environment["CLICKY_APPROVAL_CARD_SHOTS_DIR"] {
            let fileName = "\(phase)".replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression) + (reduceMotionIsOn ? "-reduce-motion" : "")
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shotsDirectory).appendingPathComponent("\(fileName).png"))
        }
        return bitmap
    }

    /// The panel's tallest frame is worked out from the card's height outside its summary, so a card that grows past it
    /// would push the agent rows off the screen.
    @Test func theTallestCardFitsTheHeightThePanelLeavesForIt() throws {
        let phasesToRender: [ApprovalCardPhase] = [.waiting(.summaryNotYetSeen), .waiting(.readyInAMoment), .waiting(.ready), .sending, .ended(.timedOut)]
        for phase in phasesToRender {
            let bitmap = try renderedCard(phase: phase)
            let cardHeightInPoints = bitmap.size.height
            #expect(cardHeightInPoints <= AgentListPanelController.maximumApprovalSummaryHeight + AgentListPanelController.approvalCardHeightOutsideTheSummary, "\(phase) is \(cardHeightInPoints) points tall")
            #expect(bitmap.size.width == AgentListPanelController.panelWidth)
        }
        _ = try renderedCard(phase: .waiting(.readyInAMoment), reduceMotionIsOn: true)
    }
}
