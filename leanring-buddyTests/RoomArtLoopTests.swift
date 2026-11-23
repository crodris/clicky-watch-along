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
        #expect(RoomArtLoopState.fadingOut(beganAt: 10).after(phaseChangedTo: moving, at: 30) == .drawing(beganAt: 30))
    }

    @Test func theItemOrTheShirtShowingFadesTheLoopWhereItsClockWas() {
        let showing = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: nil)

        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: showing, at: 24) == .fadingOut(beganAt: 10))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .showingTheShirt(title: "Tee"), at: 24) == .fadingOut(beganAt: 10))
    }

    @Test func aFailedMeasurementAFailedMoveAndAFloorNotFoundFadeTheLoop() {
        let failed = RoomArtPhase.failed(.wallNotMeasured)
        let showingAfterAFailedMove = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: .wallNotMeasured)

        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: failed, at: 24) == .fadingOut(beganAt: 10))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: showingAfterAFailedMove, at: 24) == .fadingOut(beganAt: 10))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .waitingForAFloorClick(loopTestItem()), at: 24) == .fadingOut(beganAt: 10))
        // Furniture waiting for its painting keeps the loop and its clock around the footprint.
        let arrangingPhase = RoomArtPhase.arranging(id: RoomArtMeasurementID(number: 1), item: loopTestItem(), surface: .wall(loopTestWall()))
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: arrangingPhase, at: 24) == .drawing(beganAt: 10))
    }

    @Test func aPhaseWithNoMeasurementShowsNoLoopAndStartsNone() {
        let showing = RoomArtPhase.showing(item: loopTestItem(), surface: .wall(loopTestWall()), moveFailure: nil)

        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: showing, at: 5) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .failed(.noCamera), at: 5) == .hidden)
        #expect(RoomArtLoopState.fadingOut(beganAt: 1).after(phaseChangedTo: showing, at: 5) == .fadingOut(beganAt: 1))
    }

    @Test func closingThePanelOrReadingThePageRemovesTheLoopAtOnce() {
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .closed, at: 11) == .hidden)
        #expect(RoomArtLoopState.fadingOut(beganAt: 10).after(phaseChangedTo: .closed, at: 11) == .hidden)
        #expect(RoomArtLoopState.drawing(beganAt: 10).after(phaseChangedTo: .readingThePage, at: 11) == .hidden)
        #expect(RoomArtLoopState.hidden.after(phaseChangedTo: .waitingForTheCamera(loopTestItem()), at: 11) == .hidden)
    }

    @Test func onlyAFadingLoopLeavesWhenTheFadeFinishes() {
        #expect(RoomArtLoopState.fadingOut(beganAt: 10).afterTheFadeFinished() == .hidden)
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

    @Test func theLoopUsesTheCursorLoopsTimelineAndReduceMotionDrawsTheWholeLineWithNoSpark() {
        let normal = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: 0.65, reduceMotionIsOn: false)
        #expect(normal.showsTheSpark)
        #expect(abs(normal.frame.drawnShare - 0.35) < 1e-9)

        for seconds in [0.0, 0.65, 9] {
            let reduced = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: seconds, reduceMotionIsOn: true)
            #expect(!reduced.showsTheSpark)
            #expect(reduced.frame.drawnShare == 1)
        }
    }
}

/// The loop's renders at 2x. Only the render runs on the main actor, as `ImageRenderer` needs. Every scan of its 2 million
/// pixels runs on a detached task, since a scan on the main actor holds every other main actor test back on a loaded Mac.
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

    private static func renderedLoop(showsTheSpark: Bool) async throws -> Render {
        let keyframe = RoomArtLoopGeometry.keyframeCorners(around: CGPoint(x: 640, y: 250), frameSize: cameraFrame, on: .wall)
        let snapshot = RoomArtLoopSnapshot(keyframeCorners: keyframe, currentCorners: keyframe)
        let path = try #require(RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraFrame, viewSize: panelSize)))
        let canvas = RoomArtLoopCanvas(
            outline: path,
            frame: CursorLoopTimeline.Frame(drawnShare: 1, spark: .onTheLoop(share: 0.5)),
            color: Color(hex: "#F97316"),
            showsTheSpark: showsTheSpark
        )
        let renderer = ImageRenderer(content: canvas.frame(width: panelSize.width, height: panelSize.height))
        renderer.scale = 2
        // A CGImage never changes after the render, so the detached task may read it.
        nonisolated(unsafe) let image = try #require(renderer.cgImage)
        let lineBoundsInPoints = path.boundingRect
        let bytes = try #require(await Task.detached { rgbaBytes(of: image) }.value)
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

    /// What a render holds: where anything is drawn, how many pixels are the accent or white, and whether anything touches the
    /// panel's two outermost pixels.
    struct Scan: Sendable {
        let drawnBounds: CGRect
        let accentPixelCount: Int
        let whitePixelCount: Int
        let anythingDrawnAtTheEdge: Bool
    }

    nonisolated private static func scan(_ render: Render) async -> Scan {
        await Task.detached {
            var accentPixelCount = 0
            var whitePixelCount = 0
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
                    if render.bytes[offset] > 240 && render.bytes[offset + 1] > 240 && render.bytes[offset + 2] > 240 && render.bytes[offset + 3] > 240 {
                        whitePixelCount += 1
                    }
                }
            }
            return Scan(drawnBounds: drawnBounds, accentPixelCount: accentPixelCount, whitePixelCount: whitePixelCount, anythingDrawnAtTheEdge: anythingDrawnAtTheEdge)
        }.value
    }

    @Test func theLineIsDrawnInTheAccentColorAndStaysInsideThePanel() async throws {
        let render = try await Self.renderedLoop(showsTheSpark: true)
        #expect(render.width == 1920 && render.height == 1080)
        let scan = await Self.scan(render)
        // Nothing is drawn on the two outermost pixels of the panel.
        #expect(!scan.anythingDrawnAtTheEdge)
        // A 3 point line is 6 pixels wide at 2x and the line is over 700 points long.
        #expect(scan.accentPixelCount > 3_000)
        // The drawing covers the line's own box, with room for its width and the spark's glow, and nothing beyond.
        let line = render.lineBoundsInPoints
        let pathBoundsInPixels = CGRect(x: line.minX * 2, y: line.minY * 2, width: line.width * 2, height: line.height * 2)
        #expect(scan.drawnBounds.minX >= pathBoundsInPixels.minX - 30 && scan.drawnBounds.maxX <= pathBoundsInPixels.maxX + 30)
        #expect(scan.drawnBounds.minY >= pathBoundsInPixels.minY - 30 && scan.drawnBounds.maxY <= pathBoundsInPixels.maxY + 30)
        #expect(scan.drawnBounds.minX <= pathBoundsInPixels.minX + 10 && scan.drawnBounds.maxX >= pathBoundsInPixels.maxX - 10)
    }

    @Test func theSparkIsAWhiteDotWithAnAccentOutlineAndReduceMotionDrawsNone() async throws {
        #expect(await Self.scan(try await Self.renderedLoop(showsTheSpark: true)).whitePixelCount > 50)
        #expect(await Self.scan(try await Self.renderedLoop(showsTheSpark: false)).whitePixelCount == 0)
    }
}
