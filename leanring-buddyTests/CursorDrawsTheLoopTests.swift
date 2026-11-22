//
//  CursorDrawsTheLoopTests.swift
//  leanring-buddyTests
//
//  Clicky's own cursor draws every loop: the trace's timing, the line as lengths, where the glyph sits and which way it
//  turns, one screen's draw through its steps and its land-at-once paths, the controller's record of the screen whose buddy
//  is away, and the overlay's line rendered at 2x with no white spark.
//

import AppKit
import SwiftUI
import Testing
@testable import Clicky

private let exampleLineRect = CGRect(x: 100, y: 80, width: 640, height: 360)
private let exampleLine = CursorLoopLine(outline: CursorLoopOutline.path(along: exampleLineRect, seed: 42))

private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
}

/// A T-shirt's outline, clockwise from the left side of the neck: the right shoulder and sleeve, the right side, the hem, and
/// back up the left side and sleeve.
private let tShirtOutline: [CGPoint] = [
    CGPoint(x: 80, y: 0), CGPoint(x: 120, y: 0), CGPoint(x: 200, y: 30), CGPoint(x: 180, y: 90), CGPoint(x: 160, y: 80),
    CGPoint(x: 160, y: 220), CGPoint(x: 40, y: 220), CGPoint(x: 40, y: 80), CGPoint(x: 20, y: 90), CGPoint(x: 0, y: 30),
]

struct CursorDrawsTheLoopTests {
    // MARK: - The trace's timing

    @Test func theTraceDrawsTheWholeLineInOneSecondEasingInAndOut() {
        #expect(CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: -0.2) == 0)
        #expect(CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: 0) == 0)
        #expect(abs(CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: 0.5) - 0.5) < 1e-9)
        #expect(CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: 1) == 1)
        #expect(CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: 5) == 1)
        // Smoothstep: slow at the ends, so a tenth of the time covers under a tenth of the line.
        #expect(CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: 0.1) < 0.05)
        var lastShare = 0.0
        for step in 0...100 {
            let share = CursorLoopTimeline.tracedShare(secondsSinceTheTraceBegan: Double(step) / 100)
            #expect(share >= lastShare)
            lastShare = share
        }
        #expect(!CursorLoopTimeline.traceIsDone(secondsSinceTheTraceBegan: 0.999))
        #expect(CursorLoopTimeline.traceIsDone(secondsSinceTheTraceBegan: 1))
    }

    @Test func theTracesSpeedIsZeroAtItsEndsAndFullAtItsMiddle() {
        #expect(CursorLoopTimeline.traceSpeedShare(secondsSinceTheTraceBegan: 0) == 0)
        #expect(CursorLoopTimeline.traceSpeedShare(secondsSinceTheTraceBegan: 0.5) == 1)
        #expect(CursorLoopTimeline.traceSpeedShare(secondsSinceTheTraceBegan: 1) == 0)
        #expect(CursorLoopTimeline.traceSpeedShare(secondsSinceTheTraceBegan: 3) == 0)
    }

    @Test func theCursorTurnsTowardTheLineTheShortestWayInATenthAndAHalfOfASecond() {
        #expect(CursorLoopTimeline.turnTowardTheLine(fromDegrees: 170, toDegrees: -170, secondsSinceTheTraceBegan: 0) == 170)
        // From 170 to -170 is 20 degrees clockwise, not 340 back.
        #expect(abs(CursorLoopTimeline.turnTowardTheLine(fromDegrees: 170, toDegrees: -170, secondsSinceTheTraceBegan: 0.075) - 180) < 1e-9)
        #expect(abs(CursorLoopTimeline.turnTowardTheLine(fromDegrees: -170, toDegrees: 170, secondsSinceTheTraceBegan: 0.075) + 180) < 1e-9)
        #expect(abs(CursorLoopTimeline.turnTowardTheLine(fromDegrees: 170, toDegrees: -170, secondsSinceTheTraceBegan: 0.15) - 190) < 1e-9)
        #expect(abs(CursorLoopTimeline.turnTowardTheLine(fromDegrees: 40, toDegrees: -35, secondsSinceTheTraceBegan: 2) + 35) < 1e-9)
    }

    @Test func aGlyphThatKeepsWorkingTracesTheLineThenLapsIt() {
        #expect(CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: 0) == CursorLoopTimeline.Frame(drawnShare: 0, tracer: .tracing(share: 0)))
        #expect(CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: 0.5) == CursorLoopTimeline.Frame(drawnShare: 0.5, tracer: .tracing(share: 0.5)))
        #expect(CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: 1) == CursorLoopTimeline.Frame(drawnShare: 1, tracer: .lapping(lapShare: 0)))
        #expect(CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: 1 + 2.2 * 1.25) == CursorLoopTimeline.Frame(drawnShare: 1, tracer: .lapping(lapShare: 0.25)))
    }

    // MARK: - The line as lengths

    @Test func theLineRunsFromTheOutlinesStartToItsEndAndItsInkEndsUnderTheTracer() throws {
        let outline = CursorLoopOutline.path(along: exampleLineRect, seed: 42)
        let pathStart = try #require(outline.trimmedPath(from: 0, to: 0.0001).currentPoint)
        let pathEnd = try #require(outline.currentPoint)
        #expect(distance(exampleLine.point(atShare: 0), pathStart) < 1)
        #expect(distance(exampleLine.point(atShare: 1), pathEnd) < 0.01)
        // Close to the path's own length, which a curve cut in 12 pieces reads a hair short.
        let perimeter = 2 * (exampleLineRect.width + exampleLineRect.height)
        #expect(exampleLine.totalLength > perimeter * 0.93 && exampleLine.totalLength < perimeter * 1.1)

        for share in [0.1, 0.37, 0.5, 0.82, 1.0] {
            let ink = exampleLine.inkPath(upToShare: share)
            #expect(distance(try #require(ink.currentPoint), exampleLine.point(atShare: share)) < 0.001)
        }
        #expect(exampleLine.inkPath(upToShare: 0).isEmpty)
    }

    @Test func theHeadingFollowsTheLineClockwise() {
        // The top edge runs right, the right edge down, the bottom edge left, and the left edge up.
        let topEdgeShare = Double(60 / exampleLine.totalLength)
        #expect(abs(exampleLine.headingDegrees(atShare: topEdgeShare) - 90) < 8)
        let rightEdgeShare = Double((exampleLineRect.width - 30 + exampleLineRect.height / 2) / exampleLine.totalLength)
        #expect(abs(exampleLine.headingDegrees(atShare: rightEdgeShare) - 180) < 8)
        let bottomEdgeShare = Double((exampleLineRect.width * 1.5 - 30 + exampleLineRect.height) / exampleLine.totalLength)
        let bottomHeading = exampleLine.headingDegrees(atShare: bottomEdgeShare)
        #expect(abs(bottomHeading - 270) < 8 || abs(bottomHeading + 90) < 8)
    }

    @Test func aLapGoesAroundTheClosedPartFromWhereTheOvershootEnded() {
        // The overshoot is left out of a lap, so a lap is shorter than the whole line.
        #expect(exampleLine.lapLength < exampleLine.totalLength - 10)
        #expect(exampleLine.lapLength > exampleLine.totalLength * 0.9)
        // The first lap starts beside where the trace ended, 2.8 points inside the line, so the glyph never jumps back to the start.
        let whereTheTraceEnded = exampleLine.point(atShare: 1)
        let whereTheFirstLapStarts = exampleLine.point(atShare: exampleLine.shareOfTheLine(atLapShare: 0))
        #expect(distance(whereTheTraceEnded, whereTheFirstLapStarts) < 4)
        #expect(distance(exampleLine.point(atShare: 0), whereTheFirstLapStarts) > 20)
        // A whole lap comes back to the same place.
        #expect(abs(exampleLine.shareOfTheLine(atLapShare: 0.999999) - exampleLine.shareOfTheLine(atLapShare: 0)) < 0.0001)
        // Every lap point is on the closed part.
        for step in 0..<50 {
            #expect(exampleLine.shareOfTheLine(atLapShare: Double(step) / 50) * Double(exampleLine.totalLength) < Double(exampleLine.lapLength) + 0.001)
        }
    }

    @Test func aClosedLineWithNoOvershootLapsFromItsStart() {
        var closedSquare = Path()
        closedSquare.move(to: CGPoint(x: 0, y: 0))
        closedSquare.addLine(to: CGPoint(x: 100, y: 0))
        closedSquare.addLine(to: CGPoint(x: 100, y: 100))
        closedSquare.addLine(to: CGPoint(x: 0, y: 100))
        closedSquare.closeSubpath()
        let line = CursorLoopLine(outline: closedSquare)
        #expect(line.totalLength == 400)
        #expect(line.lapLength == 400)
        #expect(line.firstLapStartLength == 0)
        #expect(line.point(atShare: line.shareOfTheLine(atLapShare: 0.25)) == CGPoint(x: 100, y: 0))
    }

    // MARK: - Where the glyph sits

    @Test func theTrianglesTipIsOnTheInkAndItKeepsItsPointerAngle() {
        let inkPoint = CGPoint(x: 300, y: 200)
        let placement = CursorLoopTracerPlacement(inkPoint: inkPoint, headingDegrees: 180, cursorFacing: .pointerAngle)
        #expect(placement.rotationDegrees == -35)
        // The tip is the top vertex of a 16 point triangle, turned by the pointer angle around the glyph's center.
        let tipDistance = Double(CustomCursorView.triangleSideLength) / sqrt(3)
        let angle = -35.0 * .pi / 180
        let tip = CGPoint(x: placement.glyphCenter.x + CGFloat(tipDistance * sin(angle)), y: placement.glyphCenter.y - CGFloat(tipDistance * cos(angle)))
        #expect(distance(tip, inkPoint) < 0.001)
        #expect(distance(placement.glyphCenter, inkPoint) > 9)
    }

    @Test func aCursorThatTurnsTowardMovementFacesAlongTheLineWithTheInkUnderIt() {
        let inkPoint = CGPoint(x: 300, y: 200)
        let ball = CursorLoopTracerPlacement(inkPoint: inkPoint, headingDegrees: 180, cursorFacing: .followsMouseMovement)
        #expect(ball.glyphCenter == inkPoint)
        #expect(ball.rotationDegrees == 180)
        let upright = CursorLoopTracerPlacement(inkPoint: inkPoint, headingDegrees: 180, cursorFacing: .upright)
        #expect(upright.glyphCenter == inkPoint)
        #expect(upright.rotationDegrees == 0)
        #expect(upright.headingDegrees == 180)

        let schoolTheme = bundledTheme("school-karasuno")
        #expect(schoolTheme.cursorFacing == .followsMouseMovement)
        let onTheLine = CursorLoopTracerPlacement(on: exampleLine, atShare: 0.3, cursorFacing: schoolTheme.cursorFacing)
        #expect(onTheLine.glyphCenter == exampleLine.point(atShare: 0.3))
        #expect(onTheLine.rotationDegrees == exampleLine.headingDegrees(atShare: 0.3))
    }

    // MARK: - One screen's draw

    @Test func aBuddyThatIsFreeTracesTheLoopAndReduceMotionOrABusyBuddyFadesItIn() {
        #expect(cursorLoopDrawWay(reduceMotionIsOn: false, theBuddyIsFree: true) == .theCursorTracesIt)
        #expect(cursorLoopDrawWay(reduceMotionIsOn: true, theBuddyIsFree: true) == .itFadesInWhole)
        #expect(cursorLoopDrawWay(reduceMotionIsOn: false, theBuddyIsFree: false) == .itFadesInWhole)
    }

    @Test func aTracedDrawShowsNothingUntilTheCursorArrivesThenTheInkBehindItThenTheWholeLine() {
        var draw = BuddyLoopDraw(loopBeganAt: 10, way: .theCursorTracesIt)
        #expect(draw.ink == .waitingForTheCursor)
        // The trace cannot finish before the cursor arrives.
        draw.theTraceFinished(at: 10.5)
        #expect(draw.ink == .waitingForTheCursor)

        // The ink cannot move before the cursor arrives.
        draw.theCursorTraced(toShare: 0.3)
        #expect(draw.ink == .waitingForTheCursor)

        draw.theCursorReachedTheStart()
        #expect(draw.ink == .tracing(share: 0))
        draw.theCursorTraced(toShare: 0.4)
        #expect(draw.ink == .tracing(share: 0.4))
        // A second arrival never restarts the ink, and a share past the line's end stops at it.
        draw.theCursorReachedTheStart()
        #expect(draw.ink == .tracing(share: 0.4))
        draw.theCursorTraced(toShare: 1.2)
        #expect(draw.ink == .tracing(share: 1))

        draw.theTraceFinished(at: 12)
        #expect(draw.ink == .whole(since: 12))
        // A whole line never goes back to tracing.
        draw.theCursorReachedTheStart()
        draw.theCursorTraced(toShare: 0.5)
        #expect(draw.ink == .whole(since: 12))
    }

    @Test func landingTheDrawAtOnceShowsTheWholeLineFromThatMoment() {
        var waiting = BuddyLoopDraw(loopBeganAt: 10, way: .theCursorTracesIt)
        waiting.landAtOnce(at: 10.4)
        #expect(waiting.ink == .whole(since: 10.4))

        var tracing = BuddyLoopDraw(loopBeganAt: 10, way: .theCursorTracesIt)
        tracing.theCursorReachedTheStart()
        tracing.landAtOnce(at: 11.3)
        #expect(tracing.ink == .whole(since: 11.3))

        // A line already whole keeps its shimmer's clock.
        var finished = BuddyLoopDraw(loopBeganAt: 10, way: .theCursorTracesIt)
        finished.theCursorReachedTheStart()
        finished.theTraceFinished(at: 12)
        finished.landAtOnce(at: 13)
        #expect(finished.ink == .whole(since: 12))
    }

    @Test func aLineThatFadesInIsWholeFromTheLoopsStart() {
        let draw = BuddyLoopDraw(loopBeganAt: 10, way: .itFadesInWhole)
        #expect(draw.ink == .whole(since: 10))
    }

    @Test func theInkForALoopFollowsItsDrawAndShowsWholeWhileTheLoopFades() {
        let loop = CursorLoopOnScreen(lineRect: exampleLineRect, seed: 42, beganAt: 10, shimmerSlowsAt: nil, isFadingOut: false)
        let fadingLoop = CursorLoopOnScreen(lineRect: exampleLineRect, seed: 42, beganAt: 10, shimmerSlowsAt: nil, isFadingOut: true)

        // The frame before the overlay picks a new loop up draws what its way starts with.
        #expect(BuddyLoopDraw.ink(for: loop, draw: nil, wayForANewLoop: .theCursorTracesIt) == .waitingForTheCursor)
        #expect(BuddyLoopDraw.ink(for: loop, draw: nil, wayForANewLoop: .itFadesInWhole) == .whole(since: 10))

        var draw = BuddyLoopDraw(loopBeganAt: 10, way: .theCursorTracesIt)
        draw.theCursorReachedTheStart()
        #expect(BuddyLoopDraw.ink(for: loop, draw: draw, wayForANewLoop: .itFadesInWhole) == .tracing(share: 0))
        // A draw of an older loop is not this loop's.
        let olderDraw = BuddyLoopDraw(loopBeganAt: 3, way: .itFadesInWhole)
        #expect(BuddyLoopDraw.ink(for: loop, draw: olderDraw, wayForANewLoop: .theCursorTracesIt) == .waitingForTheCursor)

        // A loop that fades out mid-trace shows whole.
        #expect(BuddyLoopDraw.ink(for: fadingLoop, draw: draw, wayForANewLoop: .theCursorTracesIt) == .whole(since: 10))
        draw.theTraceFinished(at: 12)
        #expect(BuddyLoopDraw.ink(for: fadingLoop, draw: draw, wayForANewLoop: .theCursorTracesIt) == .whole(since: 12))
    }

    @Test func theOverlaysLineShowsTheTracedShareAndShimmersOnlyOnceWhole() {
        #expect(CursorLoopView.inkedShare(of: .waitingForTheCursor) == 0)
        #expect(CursorLoopView.inkedShare(of: .tracing(share: 0.5)) == 0.5)
        #expect(CursorLoopView.inkedShare(of: .whole(since: 50)) == 1)

        #expect(CursorLoopView.shimmerLapShare(of: .waitingForTheCursor, shimmerSlowsAt: nil, at: 50) == nil)
        #expect(CursorLoopView.shimmerLapShare(of: .tracing(share: 0.5), shimmerSlowsAt: nil, at: 50.5) == nil)
        #expect(abs((CursorLoopView.shimmerLapShare(of: .whole(since: 50), shimmerSlowsAt: nil, at: 51.1) ?? -1) - 0.5) < 1e-9)
        // A build that started before the line was whole slows the shimmer from its start.
        #expect(abs((CursorLoopView.shimmerLapShare(of: .whole(since: 50), shimmerSlowsAt: 40, at: 51) ?? -1) - 0.25) < 1e-9)
    }

    // MARK: - The screen whose buddy is away

    @MainActor
    @Test func otherScreensKnowWhichScreensBuddyIsAwayDrawingTheLoop() {
        let controller = CursorLoopController(
            readTheMediaInTheFrontTab: { _ in nil },
            readTheFrontTabSample: { nil },
            waitBetweenFrontTabPolls: {},
            waitForAFinishingSparkLap: {},
            appActivationNotificationCenter: NotificationCenter()
        )
        let firstScreen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let secondScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(controller.screenFrameWhereTheBuddyDrawsTheLoop == nil)
        let olderToken = controller.theBuddyStartedDrawingTheLoop(onScreenWithFrame: firstScreen)
        let newerToken = controller.theBuddyStartedDrawingTheLoop(onScreenWithFrame: secondScreen)
        #expect(controller.screenFrameWhereTheBuddyDrawsTheLoop == secondScreen)
        // Only the newest draw's token ends it, so an older overlay's late close leaves the newer draw alone.
        controller.theBuddyFinishedDrawingTheLoop(token: olderToken)
        #expect(controller.screenFrameWhereTheBuddyDrawsTheLoop == secondScreen)
        controller.theBuddyFinishedDrawingTheLoop(token: newerToken)
        #expect(controller.screenFrameWhereTheBuddyDrawsTheLoop == nil)
    }

    @Test func aBuddyAwayForALoopComesBackOnlyWhenAnotherScreensBuddyLeavesForANewerOne() {
        let thisScreensToken = UUID()
        let anotherScreensToken = UUID()
        #expect(theLoopDrawLandsForAnotherDraw(heldToken: thisScreensToken, newRecordToken: anotherScreensToken))
        // The record naming this screen's own draw, as when it starts one, leaves it alone.
        #expect(!theLoopDrawLandsForAnotherDraw(heldToken: thisScreensToken, newRecordToken: thisScreensToken))
        // The record clearing, as when this screen releases its own draw, leaves it alone.
        #expect(!theLoopDrawLandsForAnotherDraw(heldToken: thisScreensToken, newRecordToken: nil))
        // A screen whose buddy is at the mouse has nothing to bring back.
        #expect(!theLoopDrawLandsForAnotherDraw(heldToken: nil, newRecordToken: anotherScreensToken))
    }

    // MARK: - The overlay's line at 2x

    @MainActor
    @Test func theOverlaysFinishedLineIsTheAccentWithNoWhiteSpark() throws {
        let loop = CursorLoopOnScreen(lineRect: CGRect(x: 20, y: 20, width: 400, height: 220), seed: 7, beganAt: 10, shimmerSlowsAt: nil, isFadingOut: false)
        let view = CursorLoopView(loop: loop, ink: .whole(since: ProcessInfo.processInfo.systemUptime), color: Color(hex: "#F26B1D"))
            .frame(width: 440, height: 260)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let didDraw: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(didDraw)
        var accentPixelCount = 0
        var whitePixelCount = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let red = Int(bytes[offset]), green = Int(bytes[offset + 1]), blue = Int(bytes[offset + 2]), alpha = Int(bytes[offset + 3])
            if alpha >= 250 && abs(red - 242) < 14 && abs(green - 107) < 14 && abs(blue - 29) < 14 { accentPixelCount += 1 }
            if alpha > 240 && red > 240 && green > 240 && blue > 240 { whitePixelCount += 1 }
        }
        // The 3 point line is 6 pixels wide at 2x and over 1,200 points long.
        #expect(accentPixelCount > 6_000)
        #expect(whitePixelCount == 0)
    }

    // MARK: - Any closed path

    @Test func aTracerGoesAroundAnyClosedPathAtAnEvenSpeed() throws {
        let line = CursorLoopLine(closedThrough: tShirtOutline)
        let edgeLengths = tShirtOutline.indices.map { index in distance(tShirtOutline[index], tShirtOutline[(index + 1) % tShirtOutline.count]) }
        let perimeter = edgeLengths.reduce(0, +)
        #expect(abs(line.totalLength - perimeter) < 0.001)
        // With no overshoot the lap is the whole outline, starting where it began.
        #expect(abs(line.lapLength - perimeter) < 0.001)
        #expect(line.point(atShare: 0) == tShirtOutline[0])
        #expect(distance(line.point(atShare: 1), tShirtOutline[0]) < 0.001)

        // Each corner sits at its own share of the length, so equal steps of share are equal steps of distance.
        var lengthToTheCorner: CGFloat = 0
        for (index, corner) in tShirtOutline.enumerated() {
            #expect(distance(line.point(atShare: Double(lengthToTheCorner / perimeter)), corner) < 0.001)
            lengthToTheCorner += edgeLengths[index]
        }
        for step in 0..<40 {
            let stepStart = line.point(atShare: Double(step) / 40)
            let stepEnd = line.point(atShare: Double(step + 1) / 40)
            // A step that rounds a corner cuts it, so it is never longer than an even step.
            #expect(distance(stepStart, stepEnd) <= perimeter / 40 + 0.001)
        }
        let middleOfTheHem = line.point(atShare: Double((edgeLengths[0..<5].reduce(0, +) + 60) / perimeter))
        #expect(distance(middleOfTheHem, CGPoint(x: 100, y: 220)) < 0.001)
    }

    @Test func aTracerTurnsWithTheShirtsOutline() {
        let line = CursorLoopLine(closedThrough: tShirtOutline)
        let edgeLengths = tShirtOutline.indices.map { index in distance(tShirtOutline[index], tShirtOutline[(index + 1) % tShirtOutline.count]) }
        let perimeter = edgeLengths.reduce(0, +)
        func headingInTheMiddleOfEdge(_ edgeIndex: Int) -> Double {
            let lengthToTheMiddle = edgeLengths[0..<edgeIndex].reduce(0, +) + edgeLengths[edgeIndex] / 2
            return line.headingDegrees(atShare: Double(lengthToTheMiddle / perimeter))
        }
        func expectedHeading(_ edgeIndex: Int) -> Double {
            let start = tShirtOutline[edgeIndex], end = tShirtOutline[(edgeIndex + 1) % tShirtOutline.count]
            return atan2(Double(end.y - start.y), Double(end.x - start.x)) * 180 / .pi + 90
        }
        for edgeIndex in tShirtOutline.indices {
            #expect(abs(headingInTheMiddleOfEdge(edgeIndex) - expectedHeading(edgeIndex)) < 0.001)
        }
        // Along the neck it runs right, down the right side it runs down, and along the hem it runs left.
        #expect(abs(headingInTheMiddleOfEdge(0) - 90) < 0.001)
        #expect(abs(headingInTheMiddleOfEdge(4) - 180) < 0.001)
        #expect(abs(headingInTheMiddleOfEdge(5) - 270) < 0.001)

        // A volleyball faces each way in turn, and the triangle keeps its pointer angle with its tip on the ink.
        let onTheSleeve = CursorLoopTracerPlacement(on: line, atShare: Double((edgeLengths[0] + edgeLengths[1] / 2) / perimeter), cursorFacing: .followsMouseMovement)
        #expect(abs(onTheSleeve.rotationDegrees - expectedHeading(1)) < 0.001)
        let triangleOnTheSleeve = CursorLoopTracerPlacement(on: line, atShare: 0.2, cursorFacing: .pointerAngle)
        #expect(triangleOnTheSleeve.rotationDegrees == CursorLoopTracerPlacement.pointerAngleDegrees)
    }

    @Test func fewerThanTwoPointsMakeALineWithNoLength() {
        let line = CursorLoopLine(closedThrough: [CGPoint(x: 5, y: 5)])
        #expect(line.totalLength == 0)
        #expect(line.lapLength == 0)
        #expect(line.inkPath(upToShare: 1).isEmpty)
    }
}
