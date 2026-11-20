//
//  ApprovalCardTests.swift
//  leanring-buddyTests
//
//  When the approval card counts a summary as read: only once the ranges of it that have been inside the scroll area
//  cover it from top to bottom, so dragging straight to the end does not count. The desk's 1 second clock is tested
//  in AgentHarnessTests.
//

import CoreGraphics
import Testing
@testable import Clicky

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
}
