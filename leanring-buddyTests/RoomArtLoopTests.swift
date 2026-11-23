//
//  RoomArtLoopTests.swift
//  leanring-buddyTests
//
//  Clicky's loop in the room art panel: when it shows and clears for each phase (never while a surface is measured), how
//  its corners follow the tracker's warp, how the camera fits the panel, the line bent onto the mapped corners, the timing,
//  and one render at 2x with its pixels read.
//

import CoreGraphics
import SwiftUI
import Testing
@testable import Clicky

private let firstMeasurement = RoomArtMeasurementID(number: 1)

private func loopTestWall() -> WallPlane {
    WallPlane(
        center: SIMD3(0, 0, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000,
        principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
    )
}

private func loopTestArtwork() -> RoomArtwork {
    let context = CGContext(data: nil, width: 4, height: 5, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return RoomArtwork(title: "Water Lilies", widthMeters: 0.4, heightMeters: 0.5, includesFrame: false, flattenedImage: context.makeImage()!)
}

private func loopTestItem() -> RoomArtPlacedItem { .wallArt(loopTestArtwork()) }

private func loopTestFurnitureItem(standsOn: RoomArtStandsOn = .floor) -> RoomArtPlacedItem {
    .furniture(RoomFurniture(title: "Side table", widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55, cutoutImage: loopTestArtwork().flattenedImage, standsOn: standsOn))
}

/// A window of the size `bareWallSpot` scores, centered at (640, 250) of a 1280 by 720 frame, which stands in for a
/// footprint's bounding box in the geometry tests.
private func loopTestWindow() -> RoomArtCorners {
    RoomArtCorners(rect: CGRect(x: 640 - 153.6, y: 250 - 108, width: 307.2, height: 216))
}

@MainActor
struct RoomArtLoopStateTests {
    private let measuring = RoomArtPhase.measuring(id: firstMeasurement, item: .wallArt(loopTestArtwork()))

    @Test func aSurfaceBeingMeasuredShowsNoLoopForAStandingItemOrAWallItem() {
        let floorItem = loopTestFurnitureItem()
        let tableItem = loopTestFurnitureItem(standsOn: .tableOrShelf)
        let phases: [RoomArtPhase] = [
            .measuring(id: firstMeasurement, item: floorItem),
            .measuring(id: firstMeasurement, item: tableItem),
            .measuring(id: firstMeasurement, item: loopTestItem()),
            .moving(id: RoomArtMeasurementID(number: 2), item: loopTestItem(), surfaceBeforeTheMove: .wall(loopTestWall())),
        ]
        for phase in phases {
            #expect(RoomArtLoopState.hidden.after(phaseChangedTo: phase, at: 10) == .hidden, "\(phase)")
        }
        // The panel waiting for the camera, or for a click on the floor or the table, shows none either.
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .waitingForTheCamera(floorItem), at: 10) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .waitingForAFloorClick(tableItem, aClickFoundNothing: true), at: 10) == .hidden)
    }

    @Test func aMeasurementTakesAwayALoopStillOnScreen() {
        // A loop from the piece that showed before, still fading or waiting for a click, leaves with the new measurement.
        let measuring = RoomArtPhase.measuring(id: firstMeasurement, item: loopTestItem())
        let moving = RoomArtPhase.moving(id: RoomArtMeasurementID(number: 2), item: loopTestItem(), surfaceBeforeTheMove: .wall(loopTestWall()))
        #expect(RoomArtLoopState.fadingOut(beganAt: 10, tracesTheLine: true).after(phaseChangedTo: moving, at: 30) == .hidden)
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: measuring, at: 30) == .hidden)
        #expect(RoomArtLoopState.waitingForAClick(beganAt: 10).after(phaseChangedTo: measuring, at: 30) == .hidden)
    }

    @Test func theLoopStartsAroundTheFootprintWhenFurnitureWaitsForItsPainting() {
        let arranging = RoomArtPhase.arranging(id: firstMeasurement, item: loopTestFurnitureItem(), surface: .wall(loopTestWall()))
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: arranging, at: 10) == .drawing(beganAt: 10))
    }

    @Test func theLoopKeepsItsClockWhileTheShirtGoesFromPreparedToWaitingForTheLearner() {
        // The garment is ready before the learner stands in view, so the phase changes while the loop already traces them.
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .preparingTheShirt(title: "Tee"), at: 10) == .drawing(beganAt: 10))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .waitingToSeeTheLearner(title: "Tee", preview: .liveGarment), at: 12) == .drawing(beganAt: 10))
    }

    @Test func theGhostOutlineStaysUpAsAStillFilledLineUntilThePaintingStarts() {
        let id = ShirtPaintingID(number: 1)
        // The learner's own top is traced while the preview is chosen, then the ghost holds the line instead of fading it.
        let drawing = RoomArtLoopState.hidden.after(phaseChangedTo: .preparingTheShirt(title: "Coat"), at: 10)
        let waiting = drawing.after(phaseChangedTo: .waitingToSeeTheLearner(title: "Coat", preview: .ghostOutline), at: 12)
        #expect(waiting == .holdingTheGhost(beganAt: 10))
        #expect(waiting.isHoldingTheGhost && !waiting.tracesTheLine && !waiting.isFadingOut && waiting.stillDrawnShare == 1)
        let showing = waiting.after(phaseChangedTo: .showingTheShirt(title: "Coat", preview: .ghostOutline), at: 14)
        #expect(showing == waiting)
        // The ghost stays up through the step-back countdown, and leaves for the painted area's loop when the painting starts.
        let armed = showing.after(phaseChangedTo: .waitingForTheLearnerToStepBack(title: "Coat", id: id, preview: .ghostOutline), at: 20)
        #expect(armed == waiting)
        let painting = armed.after(phaseChangedTo: .paintingTheShirt(title: "Coat", id: id, preview: .ghostOutline), at: 30)
        #expect(painting == .drawing(beganAt: 30) && !painting.isHoldingTheGhost)
        // The painted still fades the line with no glyph appearing on it, and going back holds the ghost again.
        let painted = painting.after(phaseChangedTo: .showingThePaintedShirt(title: "Coat", preview: .ghostOutline), at: 40)
        #expect(painted == .fadingOut(beganAt: 30, tracesTheLine: true))
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .showingTheShirt(title: "Coat", preview: .ghostOutline), at: 50) == .holdingTheGhost(beganAt: 50))
        // A ghost that is held fades still when the panel fails.
        #expect(waiting.after(phaseChangedTo: .failed(.noCamera), at: 60) == .fadingOut(beganAt: 10, tracesTheLine: false))
        #expect(waiting.after(phaseChangedTo: .closed, at: 60) == .hidden)
    }

    @Test func theLiveGarmentsLoopIsNotAGhostAndFadesWhenItShows() {
        let id = ShirtPaintingID(number: 1)
        for phase in [
            RoomArtPhase.showingTheShirt(title: "Tee", preview: .liveGarment),
            .waitingForTheLearnerToStepBack(title: "Tee", id: id, preview: .liveGarment),
        ] {
            let faded = RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: phase, at: 24)
            #expect(faded == .fadingOut(beganAt: 10, tracesTheLine: true) && !faded.isHoldingTheGhost)
        }
    }

    @Test func theItemOrTheShirtShowingFadesTheLoopWhereItsClockWas() {
        let showing = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: nil)

        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: showing, at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .showingTheShirt(title: "Tee", preview: .liveGarment), at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
    }

    @Test func aFailedMeasurementAFailedMoveAndAFloorNotFoundFadeTheLoop() {
        let failed = RoomArtPhase.failed(.wallNotMeasured)
        let showingAfterAFailedMove = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: .wallNotMeasured)

        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: failed, at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: showingAfterAFailedMove, at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .waitingForAFloorClick(loopTestItem()), at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
        // Furniture waiting for its painting keeps the loop and its clock around the footprint.
        let arrangingPhase = RoomArtPhase.arranging(id: RoomArtMeasurementID(number: 1), item: loopTestItem(), surface: .wall(loopTestWall()))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: arrangingPhase, at: 24) == .drawing(beganAt: 10))
    }

    @Test func aPieceThatCouldNotBeDrawnKeepsItsLineStillUntilAPickUpAndItsNextPlacementTracesItAgain() {
        let couldNotDraw = RoomArtPhase.couldNotDraw(id: RoomArtMeasurementID(number: 1), item: loopTestItem(), surface: .wall(loopTestWall()))
        let waiting = RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: couldNotDraw, at: 24)
        #expect(waiting == .waitingForAClick(beganAt: 10))
        #expect(!waiting.tracesTheLine)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: couldNotDraw, at: 24) == .waitingForAClick(beganAt: 24))
        let plan = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: 0.5, reduceMotionIsOn: false, tracesTheLine: waiting.tracesTheLine)
        #expect(!plan.showsTheTracer)
        #expect(plan.frame.drawnShare == 1)
        // A press picks the ghost back up: the still line fades with no glyph, and the next placement traces a fresh loop.
        let placing = RoomArtPhase.placingTheFurniture(id: RoomArtMeasurementID(number: 2), item: loopTestItem(), surface: .wall(loopTestWall()))
        let fadingStill = waiting.after(phaseChangedTo: placing, at: 40)
        #expect(fadingStill == .fadingOut(beganAt: 10, tracesTheLine: false))
        #expect(!fadingStill.tracesTheLine)
        let arranging = RoomArtPhase.arranging(id: RoomArtMeasurementID(number: 3), item: loopTestItem(), surface: .wall(loopTestWall()))
        #expect(fadingStill.after(phaseChangedTo: arranging, at: 44) == .drawing(beganAt: 44))
        // The ghost appearing after the first trace fades the whole line still, since its glyph leaves for the ghost, so one
        // glyph shows.
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: placing, at: 41) == .fadingOut(beganAt: 10, tracesTheLine: false))
        // A ghost that appears during the loop's first trace keeps only the part already drawn, with no glyph finishing it.
        let fadingMidTrace = RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: placing, at: 10.5)
        let drawnAtTheHandOff = CursorLoopTimeline.lappingFrame(secondsSinceTheLoopBegan: 0.5).drawnShare
        #expect(drawnAtTheHandOff < 1)
        #expect(fadingMidTrace == .fadingOut(beganAt: 10, tracesTheLine: false, stillDrawnShare: drawnAtTheHandOff))
        let midTracePlan = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: 0.8, reduceMotionIsOn: false, tracesTheLine: false, stillDrawnShare: fadingMidTrace.stillDrawnShare)
        #expect(midTracePlan.frame.drawnShare == drawnAtTheHandOff && !midTracePlan.showsTheTracer)
        // The piece showing fades a tracing loop with its glyph lapping, and a still line still.
        let showing = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: nil)
        #expect(waiting.after(phaseChangedTo: showing, at: 41) == .fadingOut(beganAt: 10, tracesTheLine: false))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: showing, at: 41).tracesTheLine)
    }

    @Test func aPhaseWithNoMeasurementShowsNoLoopAndStartsNone() {
        let showing = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: nil)

        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: showing, at: 5) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .failed(.noCamera), at: 5) == .hidden)
        #expect(RoomArtLoopState.fadingOut(beganAt: 1, tracesTheLine: true).after(phaseChangedTo: showing, at: 5) == .fadingOut(beganAt: 1, tracesTheLine: true))
    }

    @Test func closingThePanelOrReadingThePageRemovesTheLoopAtOnce() {
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .closed, at: 11) == .hidden)
        #expect(RoomArtLoopState.fadingOut(beganAt: 10, tracesTheLine: true).after(phaseChangedTo: .closed, at: 11) == .hidden)
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .readingThePage, at: 11) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .waitingForTheCamera(loopTestItem()), at: 11) == .hidden)
    }

    @Test func onlyAFadingLoopLeavesWhenTheFadeFinishes() {
        #expect(RoomArtLoopState.fadingOut(beganAt: 10, tracesTheLine: true).afterTheFadeFinished() == .hidden)
        #expect(RoomArtLoopState.drawing(beganAt: 10).afterTheFadeFinished() == .drawing(beganAt: 10))
        #expect(RoomArtLoopState.hidden.afterTheFadeFinished() == .hidden)
    }
}

struct RoomArtLoopGeometryTests {
    @Test func theCornersFollowTheTrackersWarp() {
        let keyframe = RoomArtCorners(rect: CGRect(x: 100, y: 50, width: 200, height: 100))
        // A quarter turn about the image origin, then a shift: (x, y) goes to (100 - y, x + 50).
        let turned = RoomArtLoopGeometry.corners(of: keyframe, after: EuclideanWarp(angleRadians: .pi / 2, translationX: 100, translationY: 50))

        func expectPoint(_ point: CGPoint, is expected: CGPoint) {
            #expect(abs(point.x - expected.x) < 1e-9 && abs(point.y - expected.y) < 1e-9, "\(point) is not \(expected)")
        }
        expectPoint(turned.topLeft, is: CGPoint(x: 50, y: 150))
        expectPoint(turned.topRight, is: CGPoint(x: 50, y: 350))
        expectPoint(turned.bottomRight, is: CGPoint(x: -50, y: 350))
        expectPoint(turned.bottomLeft, is: CGPoint(x: -50, y: 150))
        #expect(RoomArtLoopGeometry.corners(of: keyframe, after: .identity) == keyframe)
    }
}

@MainActor
struct RoomArtLoopOutlineTests {
    private let cameraFrame = CGSize(width: 1280, height: 720)
    private let panelSize = CGSize(width: 960, height: 540)

    private var keyframeCorners: RoomArtCorners { loopTestWindow() }

    private func outline(after warp: EuclideanWarp) throws -> Path {
        let snapshot = RoomArtLoopSnapshot(keyframeCorners: keyframeCorners, currentCorners: RoomArtLoopGeometry.corners(of: keyframeCorners, after: warp))
        return try #require(RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize)))
    }

    @Test func theCameraFitsThePanelKeepingItsShapeAndCentered() {
        let sameShape = RoomArtVideoFit(cameraSize: cameraFrame, viewSize: CGSize(width: 960, height: 540))
        let tallerPanel = RoomArtVideoFit(cameraSize: cameraFrame, viewSize: CGSize(width: 960, height: 600))

        #expect(sameShape.scale == 0.75 && sameShape.origin == .zero)
        #expect(tallerPanel.scale == 0.75 && tallerPanel.origin == CGPoint(x: 0, y: 30))
        #expect(tallerPanel.viewPoint(forCameraPixel: CGPoint(x: 1280, y: 720)) == CGPoint(x: 960, y: 570))
        #expect(!RoomArtVideoFit(cameraSize: .zero, viewSize: panelSize).isUsable)
    }

    @Test func withNoWarpTheLineRunsFourPointsOutsideTheWindowInPanelPoints() throws {
        let bounds = try outline(after: .identity).boundingRect

        // The window is 307.2 by 216 camera pixels, 230.4 by 162 panel points, outset 4 points. The wobble and the curved
        // corners keep the line within a couple of points of that.
        let expected = CGRect(x: 480 - 115.2, y: 187.5 - 81, width: 230.4, height: 162).insetBy(dx: -4, dy: -4)
        #expect(abs(bounds.minX - expected.minX) < 3 && abs(bounds.maxX - expected.maxX) < 3)
        #expect(abs(bounds.minY - expected.minY) < 3 && abs(bounds.maxY - expected.maxY) < 3)
    }

    @Test func theLineFollowsTheWallAsTheCameraTurns() throws {
        let straight = try outline(after: .identity).boundingRect
        // The wall moved 40 camera pixels right and 20 down, which is 30 and 15 panel points.
        let moved = try outline(after: EuclideanWarp(angleRadians: 0, translationX: 40, translationY: 20)).boundingRect

        #expect(abs(moved.minX - (straight.minX + 30)) < 1e-6 && abs(moved.minY - (straight.minY + 15)) < 1e-6)
        #expect(abs(moved.width - straight.width) < 1e-6 && abs(moved.height - straight.height) < 1e-6)
    }

    @Test func aWindowThatGrowsOnScreenBendsTheLineOntoItsNewCorners() throws {
        let straight = try outline(after: .identity).boundingRect
        let keyframe = keyframeCorners
        let center = CGPoint(x: (keyframe.topLeft.x + keyframe.bottomRight.x) / 2, y: (keyframe.topLeft.y + keyframe.bottomRight.y) / 2)
        // Twice as large about its own center, as when the learner walks toward the wall.
        let doubled = RoomArtCorners(clockwiseFromTopLeft: keyframe.clockwiseFromTopLeft.map { CGPoint(x: center.x + ($0.x - center.x) * 2, y: center.y + ($0.y - center.y) * 2) })
        let snapshot = RoomArtLoopSnapshot(keyframeCorners: keyframe, currentCorners: doubled)

        let grown = try #require(RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize))).boundingRect

        #expect(abs(grown.width - straight.width * 2) < 1e-6 && abs(grown.height - straight.height * 2) < 1e-6)
        // Growing about the window's center in the panel doubles each point's distance from it.
        let windowCenterInThePanel = RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize).viewPoint(forCameraPixel: center)
        #expect(abs(grown.midX - (windowCenterInThePanel.x + (straight.midX - windowCenterInThePanel.x) * 2)) < 1e-6)
        #expect(abs(grown.midY - (windowCenterInThePanel.y + (straight.midY - windowCenterInThePanel.y) * 2)) < 1e-6)
    }

    @Test func thereIsNoLineBeforeTheCameraHasAFrameOrForAWindowWithNoArea() {
        let snapshot = RoomArtLoopSnapshot(keyframeCorners: keyframeCorners, currentCorners: keyframeCorners)
        #expect(RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: .zero, viewSize: panelSize)) == nil)

        // A window with no width or height cannot be mapped onto the current corners.
        let noArea = RoomArtCorners(rect: CGRect(x: 300, y: 200, width: 0, height: 0))
        let degenerate = RoomArtLoopSnapshot(keyframeCorners: noArea, currentCorners: keyframeCorners)
        #expect(RoomArtLoopOutline.path(for: degenerate, fit: RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize)) == nil)
    }

    @Test func theGlyphTracesTheLineFromTheLoopsStartThenLapsItAndReduceMotionDrawsTheWholeLineWithNoGlyph() {
        let tracing = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: 0.5, reduceMotionIsOn: false, tracesTheLine: true)
        #expect(tracing.showsTheTracer)
        #expect(tracing.frame == CursorLoopTimeline.Frame(drawnShare: 0.5, tracer: .tracing(share: 0.5)))

        let lapping = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: 1 + 1.1, reduceMotionIsOn: false, tracesTheLine: true)
        #expect(lapping.showsTheTracer)
        #expect(lapping.frame.drawnShare == 1)
        guard case .lapping(let lapShare) = lapping.frame.tracer else {
            Issue.record("the glyph should lap the finished line")
            return
        }
        #expect(abs(lapShare - 0.5) < 1e-9)

        for seconds in [0.0, 0.65, 9] {
            let reduced = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: seconds, reduceMotionIsOn: true, tracesTheLine: true)
            #expect(!reduced.showsTheTracer)
            #expect(reduced.frame.drawnShare == 1)
        }
    }
}

/// The loop's renders at 2x. Only the render runs on the main actor, as `ImageRenderer` needs, and every scan of its 2 million
/// pixels runs on a detached task. A scan on the main actor held it for a minute on a loaded Mac, and every main actor test that
/// waited on it hit its time limit, the cursor loop suites among them.
@MainActor
struct RoomArtLoopRenderTests {
    private static let cameraFrame = CGSize(width: 1280, height: 720)
    private static let panelSize = CGSize(width: 960, height: 540)
    nonisolated private static let accentRGB: (red: Int, green: Int, blue: Int) = (249, 115, 22)

    /// One render as 8-bit RGBA bytes at 2x, drawn into a known layout so no pixel read depends on the renderer's.
    struct Render: Sendable {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let lineBoundsInPoints: CGRect
    }

    private static func loopPath() throws -> Path {
        let keyframe = loopTestWindow()
        let snapshot = RoomArtLoopSnapshot(keyframeCorners: keyframe, currentCorners: keyframe)
        return try #require(RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize)))
    }

    private static func renderedImage(tracerLook: CursorLoopTracerLook?, tracer: CursorLoopTimeline.TracerPlace, showsTheTracer: Bool, fillOpacity: Double = 0) throws -> CGImage {
        let canvas = RoomArtLoopCanvas(
            outline: try loopPath(),
            frame: CursorLoopTimeline.Frame(drawnShare: 1, tracer: tracer),
            color: Color(hex: "#F97316"),
            tracerLook: tracerLook,
            showsTheTracer: showsTheTracer,
            fillOpacity: fillOpacity
        )
        let renderer = ImageRenderer(content: canvas.frame(width: panelSize.width, height: panelSize.height))
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    private static func renderedLoop(tracerLook: CursorLoopTracerLook? = nil, tracer: CursorLoopTimeline.TracerPlace = .lapping(lapShare: 0.5), showsTheTracer: Bool = true) async throws -> Render {
        let image = try renderedImage(tracerLook: tracerLook, tracer: tracer, showsTheTracer: showsTheTracer)
        let lineBoundsInPoints = try loopPath().boundingRect
        // A CGImage never changes after the render, so the detached task may read it.
        nonisolated(unsafe) let imageToRead = image
        let bytes = try #require(await Task.detached { rgbaBytes(of: imageToRead) }.value)
        return Render(bytes: bytes, width: image.width, height: image.height, lineBoundsInPoints: lineBoundsInPoints)
    }

    /// The image's pixels as 8-bit RGBA, or nil when no context could be made to draw them.
    nonisolated private static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        // The context writes through the buffer's pointer, so the draw happens inside the closure that lends it.
        let didDraw: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return didDraw ? bytes : nil
    }

    nonisolated private static func isTheAccent(_ bytes: [UInt8], at offset: Int) -> Bool {
        let alpha = Int(bytes[offset + 3])
        guard alpha >= 250 else { return false }
        return abs(Int(bytes[offset]) - accentRGB.red) < 14 && abs(Int(bytes[offset + 1]) - accentRGB.green) < 14 && abs(Int(bytes[offset + 2]) - accentRGB.blue) < 14
    }

    /// What the line's render holds: where anything is drawn, how many pixels are the accent, and whether anything touches the
    /// panel's two outermost pixels.
    struct LineScan: Sendable {
        let drawnBounds: CGRect
        let accentPixelCount: Int
        let anythingDrawnAtTheEdge: Bool
    }

    nonisolated private static func scanTheLine(_ render: Render) async -> LineScan {
        await Task.detached {
            var accentPixelCount = 0
            var drawnBounds = CGRect.null
            var anythingDrawnAtTheEdge = false
            for row in 0..<render.height {
                for column in 0..<render.width {
                    let offset = (row * render.width + column) * 4
                    if render.bytes[offset + 3] > 0 {
                        if column < 2 || row < 2 || column >= render.width - 2 || row >= render.height - 2 { anythingDrawnAtTheEdge = true }
                        drawnBounds = drawnBounds.union(CGRect(x: column, y: row, width: 1, height: 1))
                    }
                    if isTheAccent(render.bytes, at: offset) { accentPixelCount += 1 }
                }
            }
            return LineScan(drawnBounds: drawnBounds, accentPixelCount: accentPixelCount, anythingDrawnAtTheEdge: anythingDrawnAtTheEdge)
        }.value
    }

    @Test func theGhostOutlineFillsTheInsideOfTheLineSoftlyAndAPlainLoopDoesNot() async throws {
        let center = try Self.loopPath().boundingRect
        // The center of the outline's box is well inside the line, 2 pixels per point.
        let centerPixel = (x: Int(center.midX * 2), y: Int(center.midY * 2))
        let plain = try Self.renderedImage(tracerLook: nil, tracer: .lapping(lapShare: 0.5), showsTheTracer: false)
        let filled = try Self.renderedImage(tracerLook: nil, tracer: .lapping(lapShare: 0.5), showsTheTracer: false, fillOpacity: RoomArtLoopView.ghostFillOpacity(secondsSinceTheLoopBegan: 0, reduceMotionIsOn: true))
        // A CGImage never changes after the render, so the detached task may read it.
        nonisolated(unsafe) let plainImage = plain, filledImage = filled
        let alphas = await Task.detached { () -> (plain: Int, filled: Int) in
            func alphaAtTheCenter(_ image: CGImage) -> Int {
                let bytes = Self.rgbaBytes(of: image) ?? []
                return Int(bytes[(centerPixel.y * image.width + centerPixel.x) * 4 + 3])
            }
            return (alphaAtTheCenter(plainImage), alphaAtTheCenter(filledImage))
        }.value
        #expect(alphas.plain == 0)
        // Soft: visible, and far from opaque, so the learner shows through their own ghost.
        #expect(alphas.filled > 15 && alphas.filled < 90, "the fill's alpha at the center was \(alphas.filled)")
    }

    @Test func theGhostsFillBreathesAndHoldsStillWithReduceMotion() {
        let resting = RoomArtLoopView.ghostFillOpacity(secondsSinceTheLoopBegan: 0, reduceMotionIsOn: false)
        let atAPeak = RoomArtLoopView.ghostFillOpacity(secondsSinceTheLoopBegan: RoomFurnitureGhostGlow.secondsPerBreath / 4, reduceMotionIsOn: false)
        #expect(atAPeak > resting)
        for seconds in [0.0, 0.6, 1.8, 5.0] {
            #expect(RoomArtLoopView.ghostFillOpacity(secondsSinceTheLoopBegan: seconds, reduceMotionIsOn: true) == RoomArtLoopView.ghostFillOpacity(secondsSinceTheLoopBegan: 0, reduceMotionIsOn: true))
        }
    }

    @Test func theLineIsDrawnInTheAccentColorAndStaysInsideThePanel() async throws {
        let render = try await Self.renderedLoop()
        #expect(render.width == 1920 && render.height == 1080)
        let scan = await Self.scanTheLine(render)
        // Nothing is drawn on the two outermost pixels of the panel.
        #expect(!scan.anythingDrawnAtTheEdge)
        // A 3 point line is 6 pixels wide at 2x and the line is over 700 points long.
        #expect(scan.accentPixelCount > 3_000)
        // The drawing covers the line's own box, with room for its width, and nothing beyond.
        let line = render.lineBoundsInPoints
        let pathBoundsInPixels = CGRect(x: line.minX * 2, y: line.minY * 2, width: line.width * 2, height: line.height * 2)
        #expect(scan.drawnBounds.minX >= pathBoundsInPixels.minX - 30 && scan.drawnBounds.maxX <= pathBoundsInPixels.maxX + 30)
        #expect(scan.drawnBounds.minY >= pathBoundsInPixels.minY - 30 && scan.drawnBounds.maxY <= pathBoundsInPixels.maxY + 30)
        #expect(scan.drawnBounds.minX <= pathBoundsInPixels.minX + 10 && scan.drawnBounds.maxX >= pathBoundsInPixels.maxX - 10)
    }

    /// What the tracer drew: the pixels that differ between a render with it and one without.
    struct TracerScan: Sendable {
        let bounds: CGRect
        let seamPixelCount: Int
        let accentBluePixelCount: Int
        let whitePixelCount: Int
    }

    nonisolated private static func scanTheTracer(in render: Render, comparedWith lineOnly: Render) async -> TracerScan {
        await Task.detached {
            var bounds = CGRect.null
            var seamPixelCount = 0
            var accentBluePixelCount = 0
            var whitePixelCount = 0
            for row in 0..<render.height {
                for column in 0..<render.width {
                    let offset = (row * render.width + column) * 4
                    let red = Int(render.bytes[offset]), green = Int(render.bytes[offset + 1]), blue = Int(render.bytes[offset + 2]), alpha = Int(render.bytes[offset + 3])
                    if red > 240 && green > 240 && blue > 240 && alpha > 240 { whitePixelCount += 1 }
                    var differs = false
                    for channel in 0..<4 where abs(Int(render.bytes[offset + channel]) - Int(lineOnly.bytes[offset + channel])) > 24 { differs = true }
                    guard differs else { continue }
                    bounds = bounds.union(CGRect(x: column, y: row, width: 1, height: 1))
                    // A school's volleyball has dark seams, opaque and near black, which no triangle has.
                    if alpha >= 250 && red < 60 && green < 60 && blue < 60 { seamPixelCount += 1 }
                    if alpha >= 250 && blue > red + 80 && blue > green + 30 { accentBluePixelCount += 1 }
                }
            }
            return TracerScan(bounds: bounds, seamPixelCount: seamPixelCount, accentBluePixelCount: accentBluePixelCount, whitePixelCount: whitePixelCount)
        }.value
    }

    @Test func theTracerIsTheThemesCursorGlyphOnTheLineAndThereIsNoWhiteSpark() async throws {
        let lineOnly = try await Self.renderedLoop(showsTheTracer: false)
        let line = CursorLoopLine(outline: try Self.loopPath())
        let tracerShare = 0.5

        // Under a school theme the tracer is its volleyball, centered on the ink, with the ball's dark seams.
        let karasuno = CursorLoopTracerLook(theme: bundledTheme("school-karasuno"), picture: nil)
        let volleyball = await Self.scanTheTracer(in: try await Self.renderedLoop(tracerLook: karasuno, tracer: .tracing(share: tracerShare)), comparedWith: lineOnly)
        let ballPlacement = CursorLoopTracerPlacement(on: line, atShare: tracerShare, cursorFacing: karasuno.theme.cursorFacing)
        #expect(abs(volleyball.bounds.midX / 2 - ballPlacement.glyphCenter.x) < 4)
        #expect(abs(volleyball.bounds.midY / 2 - ballPlacement.glyphCenter.y) < 6)
        // The 24 point ball with its glow and contact shadow, and nothing the size of a 9 point spark.
        #expect(volleyball.bounds.width / 2 > 22 && volleyball.bounds.width / 2 < 60)
        #expect(volleyball.seamPixelCount > 20)
        #expect(volleyball.whitePixelCount == 0)

        // Under Clicky blue it is the blue triangle, with no seams, beside the line with its tip on the ink.
        let clickyBlue = CursorLoopTracerLook(theme: clickyBlueTheme, picture: nil)
        let triangle = await Self.scanTheTracer(in: try await Self.renderedLoop(tracerLook: clickyBlue, tracer: .tracing(share: tracerShare)), comparedWith: lineOnly)
        let trianglePlacement = CursorLoopTracerPlacement(on: line, atShare: tracerShare, cursorFacing: clickyBlue.theme.cursorFacing)
        #expect(abs(triangle.bounds.midX / 2 - trianglePlacement.glyphCenter.x) < 4)
        #expect(abs(triangle.bounds.midY / 2 - trianglePlacement.glyphCenter.y) < 6)
        #expect(triangle.seamPixelCount == 0)
        #expect(triangle.accentBluePixelCount > 40)
        #expect(triangle.whitePixelCount == 0)
    }

    @Test func reduceMotionDrawsNoTracer() async throws {
        let lineOnly = try await Self.renderedLoop(showsTheTracer: false)
        let reduced = try await Self.renderedLoop(tracerLook: CursorLoopTracerLook(theme: bundledTheme("school-karasuno"), picture: nil), showsTheTracer: false)
        #expect(await Self.scanTheTracer(in: reduced, comparedWith: lineOnly).bounds.isNull)
    }
}
