//
//  RoomArtLoopTests.swift
//  leanring-buddyTests
//
//  Clicky's loop around the wall spot while the room art panel measures the wall: when it shows and clears for each phase,
//  the window it outlines, how its corners follow the tracker's warp, how the camera fits the panel, the line bent onto the
//  mapped corners, the timing, and one render at 2x with its pixels read.
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

@MainActor
struct RoomArtLoopStateTests {
    private let measuring = RoomArtPhase.measuring(id: firstMeasurement, item: .wallArt(loopTestArtwork()))

    @Test func aMeasurementStartsTheLoopAtTheTimeTheKeyframeWasTaken() {
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: measuring, at: 10) == .drawing(beganAt: 10))
    }

    @Test func theLoopKeepsItsClockWhileTheShirtGoesFromPreparedToWaitingForTheLearner() {
        // The garment is ready before the learner stands in view, so the phase changes while the loop already traces them.
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .preparingTheShirt(title: "Tee"), at: 10) == .drawing(beganAt: 10))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .waitingToSeeTheLearner(title: "Tee"), at: 12) == .drawing(beganAt: 10))
    }

    @Test func aClickedMoveDrawsTheLoopAgain() {
        let moving = RoomArtPhase.moving(id: RoomArtMeasurementID(number: 2), item: loopTestItem(), surfaceBeforeTheMove: .wall(loopTestWall()))

        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: moving, at: 30) == .drawing(beganAt: 30))
        // A loop still fading from the item that showed before starts over instead of finishing its fade.
        #expect(RoomArtLoopState.fadingOut(beganAt: 10, tracesTheLine: true).after(phaseChangedTo: moving, at: 30) == .drawing(beganAt: 30))
    }

    @Test func theItemOrTheShirtShowingFadesTheLoopWhereItsClockWas() {
        let showing = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: nil)

        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: showing, at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .showingTheShirt(title: "Tee"), at: 24) == .fadingOut(beganAt: 10, tracesTheLine: true))
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
        // The ghost appearing fades a tracing loop whole and still, since its glyph leaves for the ghost, so one glyph shows.
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: placing, at: 41) == .fadingOut(beganAt: 10, tracesTheLine: false))
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
    private let cameraFrame = CGSize(width: 1280, height: 720)

    @Test func theWindowAroundASpotIsTheSizeBareWallSpotScored() {
        let corners = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 250), frameSize: cameraFrame, on: .wall)

        // 24 percent of the width and 30 percent of the height, centered on the spot.
        #expect(abs(corners.topLeft.x - (640 - 153.6)) < 1e-9 && abs(corners.topRight.x - (640 + 153.6)) < 1e-9)
        #expect(abs(corners.topLeft.y - (250 - 108)) < 1e-9 && abs(corners.bottomLeft.y - (250 + 108)) < 1e-9)
        // At the 320 by 180 track size, the scored window is 77 by 54 pixels, which is this window's size to the rounding.
        let trackPixelsPerCameraPixel = 320.0 / cameraFrame.width
        #expect(abs((corners.topRight.x - corners.topLeft.x) * trackPixelsPerCameraPixel - 77) < 1)
        #expect(abs((corners.bottomLeft.y - corners.topLeft.y) * trackPixelsPerCameraPixel - 54) < 1)
    }

    @Test func aClickNearAnEdgeShiftsTheWindowInsideTheFrameKeepingItsSize() {
        let nearTheTopLeft = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 10, y: 10), frameSize: cameraFrame, on: .wall)
        let nearTheBottomRight = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 1275, y: 715), frameSize: cameraFrame, on: .wall)

        #expect(nearTheTopLeft.topLeft == CGPoint(x: 0, y: 0))
        #expect(abs(nearTheTopLeft.bottomRight.x - 307.2) < 1e-9 && abs(nearTheTopLeft.bottomRight.y - 216) < 1e-9)
        #expect(abs(nearTheBottomRight.bottomRight.x - 1280) < 1e-9 && abs(nearTheBottomRight.bottomRight.y - 720) < 1e-9)
        #expect(abs((nearTheBottomRight.bottomRight.x - nearTheBottomRight.topLeft.x) - 307.2) < 1e-9)
    }

    @Test func theWindowAroundAFloorSpotIsTheWideLowOneBareFloorSpotScored() {
        let corners = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 560), frameSize: cameraFrame, on: .floor)

        // 30 percent of the width and 18 percent of the height, centered on the spot.
        #expect(abs((corners.topRight.x - corners.topLeft.x) - 384) < 1e-9)
        #expect(abs((corners.bottomLeft.y - corners.topLeft.y) - 129.6) < 1e-9)
        #expect(abs((corners.topLeft.y + corners.bottomLeft.y) / 2 - 560) < 1e-9)
    }

    @Test func theTorsoLoopOutlinesTheTorsosBoxAndBendsOntoWhereTheShirtLands() throws {
        let torso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 500, y: 200), imageRightShoulder: CGPoint(x: 780, y: 220),
            imageLeftHip: CGPoint(x: 520, y: 600), imageRightHip: CGPoint(x: 760, y: 610),
            hipsWereEstimated: false, shouldersAreSeen: true
        )
        let loop = try #require(RoomArtLoopGeometry.torsoLoop(of: torso))
        let landing = ShirtTryOnRenderer.bodyTorsoCorners(of: torso)

        #expect(loop.currentCorners.clockwiseFromTopLeft == landing)
        // The box holds every landing corner, and touches the outermost on each side.
        #expect(loop.keyframeCorners.topLeft.x == landing.map(\.x).min() && loop.keyframeCorners.bottomRight.x == landing.map(\.x).max())
        #expect(loop.keyframeCorners.topLeft.y == landing.map(\.y).min() && loop.keyframeCorners.bottomRight.y == landing.map(\.y).max())
        // A torso with no width outlines nothing.
        let flatTorso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 500, y: 200), imageRightShoulder: CGPoint(x: 500, y: 200),
            imageLeftHip: CGPoint(x: 500, y: 200), imageRightHip: CGPoint(x: 500, y: 200),
            hipsWereEstimated: false, shouldersAreSeen: true
        )
        #expect(RoomArtLoopGeometry.torsoLoop(of: flatTorso) == nil)
    }

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

    private var keyframeCorners: RoomArtCorners {
        RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 250), frameSize: cameraFrame, on: .wall)
    }

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
        let keyframe = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 250), frameSize: cameraFrame, on: .wall)
        let snapshot = RoomArtLoopSnapshot(keyframeCorners: keyframe, currentCorners: keyframe)
        return try #require(RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize)))
    }

    private static func renderedImage(tracerLook: CursorLoopTracerLook?, tracer: CursorLoopTimeline.TracerPlace, showsTheTracer: Bool) throws -> CGImage {
        let canvas = RoomArtLoopCanvas(
            outline: try loopPath(),
            frame: CursorLoopTimeline.Frame(drawnShare: 1, tracer: tracer),
            color: Color(hex: "#F97316"),
            tracerLook: tracerLook,
            showsTheTracer: showsTheTracer
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
