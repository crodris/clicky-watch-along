//
//  CircledRegionTests.swift
//  leanring-buddyTests
//
//  Circle to select: which mouse paths close a loop around a region, the loop the cursor draws around it, and the
//  rehearsal step that circles a region with the real mouse.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Clicky

/// A hand drawn circle's path: `turns` of a full turn around `center`, starting at its top and running clockwise.
private func circlePath(center: CGPoint, radius: CGFloat, turns: Double = 1, pointCount: Int = 72) -> [CGPoint] {
    (0...pointCount).map { index in
        let angle = Double(index) / Double(pointCount) * turns * 2 * Double.pi
        return CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }
}

// MARK: - Which paths close a loop

@Test func aCircleAroundAPictureClosesALoopAroundItsBox() throws {
    let circledRegion = try #require(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 100)))
    let box = circledRegion.boundingRect
    // Smoothing pulls the line a little inside the drawn path, never far.
    #expect(abs(box.rectX - 400) < 8)
    #expect(abs(box.rectY - 200) < 8)
    #expect(abs(box.rectWidth - 200) < 16)
    #expect(abs(box.rectHeight - 200) < 16)
    #expect(circledRegion.outline.count <= ShirtOutline.mostPoints)
}

@Test func aCircleThatOvershootsItsStartStillClosesAndDropsTheOvershoot() throws {
    let circledRegion = try #require(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 100, turns: 1.15)))
    #expect(abs(circledRegion.boundingRect.rectWidth - 200) < 16)
}

@Test func aMoveToThePictureFirstAndAWanderOffAfterAreLeftOutOfTheLoop() throws {
    let approach = (0..<30).map { CGPoint(x: 100 + CGFloat($0) * 13, y: 600 - CGFloat($0) * 10) }
    let circle = circlePath(center: CGPoint(x: 500, y: 300), radius: 100)
    let wander = (1...20).map { CGPoint(x: 500 + CGFloat($0) * 15, y: 200) }
    let circledRegion = try #require(CircledRegion.closedLoop(fromMousePath: approach + circle + wander))
    let box = circledRegion.boundingRect
    #expect(abs(box.rectX - 400) < 8 && abs(box.rectWidth - 200) < 16)
    #expect(abs(box.rectY - 200) < 8 && abs(box.rectHeight - 200) < 16)
}

@Test func aCircleThatStopsAlittleShortOfItsStartStillCloses() {
    #expect(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 100, turns: 0.95)) != nil)
}

/// An ellipse drawn around a box of this size, as the rehearsal draws it, without its 12 point margin.
private func ellipsePath(width: CGFloat, height: CGFloat) -> [CGPoint] {
    rehearsalCirclePath(around: CGRect(x: 300, y: 300, width: width, height: height), pointCount: 72)
        .map { CGPoint(x: 300 + width / 2 + ($0.x - 300 - width / 2) * width / (width + 24), y: 300 + height / 2 + ($0.y - 300 - height / 2) * height / (height + 24)) }
}

@Test func aLoopAroundOneLineOfTextClosesButASliverDoesNot() {
    #expect(CircledRegion.closedLoop(fromMousePath: ellipsePath(width: 160, height: 30)) != nil)
    #expect(CircledRegion.closedLoop(fromMousePath: ellipsePath(width: 200, height: 12)) == nil)
}

@Test func anOpenArcClosesNoLoop() {
    #expect(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 100, turns: 0.7)) == nil)
}

@Test func aLineDrawnOutAndBackEnclosesNothing() {
    let out = (0...30).map { CGPoint(x: 100 + CGFloat($0) * 10, y: 200 + CGFloat($0) * 4) }
    let back = out.reversed().map { CGPoint(x: $0.x, y: $0.y + 2) }
    #expect(CircledRegion.closedLoop(fromMousePath: out + back) == nil)
}

@Test func aJiggleOrAStillMouseClosesNoLoop() {
    let jiggle = (0..<40).map { CGPoint(x: 300 + CGFloat($0 % 2) * 6, y: 300 + CGFloat($0 % 3) * 4) }
    #expect(CircledRegion.closedLoop(fromMousePath: jiggle) == nil)
    #expect(CircledRegion.closedLoop(fromMousePath: [CGPoint(x: 10, y: 10)]) == nil)
}

@Test func aCircleTooSmallToFrameAPictureClosesNoLoop() {
    #expect(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 15)) == nil)
}

@Test func theEnclosedAreaIsTheSameWhicheverWayTheLoopWasDrawn() {
    let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
    #expect(CircledRegion.enclosedArea(of: square) == 100)
    #expect(CircledRegion.enclosedArea(of: square.reversed()) == 100)
}

@Test func theOutlineMovesIntoTheOverlayCoordinatesOfASecondScreen() {
    let circledRegion = CircledRegion(outline: [CGPoint(x: 1600, y: 100), CGPoint(x: 1700, y: 200), CGPoint(x: 1600, y: 300)])
    // A second screen to the right of a 1440x900 main screen, with its top 100 points above the main screen's top.
    let secondScreenFrameInAppKit = CGRect(x: 1440, y: 0, width: 1920, height: 1000)
    let overlayOutline = circledRegion.outlineInOverlayCoordinates(overlayScreenFrame: secondScreenFrameInAppKit, mainDisplayHeight: 900)
    #expect(overlayOutline == [CGPoint(x: 160, y: 200), CGPoint(x: 260, y: 300), CGPoint(x: 160, y: 400)])
}

// MARK: - The loop around a circled region

@Test func aRequestThatLooksAtACircledRegionShowsItsLoopAtOnceAndNoPollWatchesIt() throws {
    let circledRegion = try #require(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 100)))
    var state = CursorLoopState()
    state.pushToTalkWasReleased()
    state.requestBecameALookAtTheCircledRegion(circledRegion, at: 10)
    #expect(state.loop == .showing(.circledRegion(circledRegion), since: 10, shimmerSlowsAt: nil))
    // A region in any app has no front tab to compare, and no agent's spark joins it.
    #expect(state.mediaTheLoopIsAround == nil)
    #expect(state.mediaThePollWatches == nil)
    // The front tab's media read for the same release comes back later and changes nothing.
    let media = MediaOnTheFrontTab(
        screenRect: ScreenRectInChromeCoordinates(rectX: 0, rectY: 0, rectWidth: 300, rectHeight: 200),
        sample: FrontTabSample(
            windowID: 1, tabID: 1, tabURL: "https://example.com",
            pageGeometry: ChromePageGeometry(
                screenX: 0, screenY: 0, outerWidth: 1400, outerHeight: 900, innerWidth: 1400, innerHeight: 800,
                devicePixelRatio: 2, left: 0, top: 0, width: 300, height: 200, imageSourceURL: nil
            )
        )
    )
    state.mediaRectArrived(media, at: 10.1, agentsMayJoinTheLine: true)
    #expect(state.loopOnTheMedia?.target == .circledRegion(circledRegion))
    state.end(because: .newPushToTalk)
    #expect(state.loop == .fadingOut(.circledRegion(circledRegion), since: 10, shimmerSlowsAt: nil))
}

@Test func anotherFrontAppLeavesTheLoopAroundACircledRegionWhileAScrollEndsIt() throws {
    let circledRegion = try #require(CircledRegion.closedLoop(fromMousePath: circlePath(center: CGPoint(x: 500, y: 300), radius: 100)))
    var state = CursorLoopState()
    state.requestBecameALookAtTheCircledRegion(circledRegion, at: 10)
    state.end(because: .appSwitched)
    state.end(because: .tabOrMediaChanged)
    #expect(state.loopIsShowing)
    state.end(because: .scrolled)
    #expect(!state.loopIsShowing)
}

@Test func theLoopOnScreenFollowsTheLearnersOwnLineInsteadOfTheRoundedRectangle() {
    let learnersOutline = circlePath(center: CGPoint(x: 300, y: 200), radius: 80, pointCount: 40).dropLast().map { $0 }
    let loop = CursorLoopOnScreen(
        lineRect: CGRect(x: 216, y: 116, width: 168, height: 168),
        seed: 1,
        learnersOutline: learnersOutline,
        beganAt: 10,
        shimmerSlowsAt: nil,
        isFadingOut: false
    )
    let line = CursorLoopLine(outline: loop.outline)
    // The line starts where the learner started, at the circle's top, and stays on the circle.
    #expect(abs(line.points[0].x - 300) < 0.5 && abs(line.points[0].y - 120) < 0.5)
    for point in line.points {
        #expect(abs(hypot(point.x - 300, point.y - 200) - 80) < 2)
    }
}

// MARK: - The rehearsal's circle

@Test func aRehearsalCircleStepReadsItsRectAndWords() throws {
    let (prefix, afterThePrefix) = rehearsalStepPrefix("@820,90,180,60 make my theme from this picture")
    #expect(prefix == .circlesARegionFirst)
    let (rect, words) = try #require(rehearsalCircledRect(afterThePrefix))
    #expect(rect == CGRect(x: 820, y: 90, width: 180, height: 60))
    #expect(words == "make my theme from this picture")
    #expect(rehearsalCircledRect("make my theme") == nil)
    #expect(rehearsalCircledRect("1,2,0,4 words") == nil)
}

@Test func theRehearsalsMousePathClosesALoopAroundItsRect() throws {
    let rect = CGRect(x: 820, y: 90, width: 180, height: 60)
    let circledRegion = try #require(CircledRegion.closedLoop(fromMousePath: rehearsalCirclePath(around: rect, pointCount: 72)))
    let box = circledRegion.boundingRect
    #expect(box.rectX < rect.minX && box.rectX + box.rectWidth > rect.maxX)
    #expect(box.rectY < rect.minY && box.rectY + box.rectHeight > rect.maxY)
}
