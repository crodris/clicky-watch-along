//
//  RoomArtPanelTests.swift
//  leanring-buddyTests
//
//  The room art panel's frame as the learner moves and resizes it, its open and close moves, the frames that stop at a close,
//  its status line's words, and its status pill and buttons drawn at 2x.
//

import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import Metal
import QuartzCore
import SwiftUI
import Testing
@testable import Clicky

struct RoomArtPanelFrameTests {
    private let screen = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let secondScreen = CGRect(x: 1512, y: 0, width: 1920, height: 1055)

    @Test func theFirstPanelOpensAtTheDefaultSizeInTheMiddleOfTheMousesScreen() {
        let frame = roomArtPanelFrameToShow(savedFrame: nil, visibleFrames: [screen], visibleFrameUnderTheMouse: screen)
        #expect(frame.size == roomArtPanelDefaultSize)
        #expect(frame.midX == screen.midX && frame.midY == screen.midY)
    }

    @Test func aSavedFrameOpensWhereTheLearnerLeftIt() {
        let saved = CGRect(x: 40, y: 60, width: 640, height: 360)
        #expect(roomArtPanelFrameToShow(savedFrame: saved, visibleFrames: [screen, secondScreen], visibleFrameUnderTheMouse: secondScreen) == saved)
    }

    @Test func aSavedFrameOffEveryScreenOpensOnTheMousesScreen() {
        // Its screen was unplugged.
        let saved = CGRect(x: 4000, y: 60, width: 640, height: 360)
        let frame = roomArtPanelFrameToShow(savedFrame: saved, visibleFrames: [screen], visibleFrameUnderTheMouse: screen)
        #expect(frame.midX == screen.midX && frame.size == roomArtPanelDefaultSize)
    }

    @Test func aSavedFrameIsKeptInsideItsScreenAtSixteenByNineAndNeverTooSmall() {
        // Half off the right edge, and smaller than the smallest size.
        let frame = roomArtPanelFrameToShow(savedFrame: CGRect(x: 1300, y: 100, width: 300, height: 100), visibleFrames: [screen], visibleFrameUnderTheMouse: screen)
        #expect(frame.size == roomArtPanelSmallestSize)
        #expect(frame.maxX <= screen.maxX && frame.minX >= screen.minX)
    }

    @Test func theGripResizesFromTheTopLeftAtSixteenByNine() {
        let start = CGRect(x: 100, y: 300, width: 960, height: 540)
        // Dragged left and up makes it smaller, keeping its top left corner.
        let smaller = roomArtPanelResizedFrame(startFrame: start, pointerMovedBy: CGSize(width: -320, height: 0), visibleFrame: screen)
        #expect(smaller.width == 640 && smaller.height == 360)
        #expect(smaller.minX == start.minX && smaller.maxY == start.maxY)
        // Dragged straight down makes it larger by the height, still 16:9.
        let larger = roomArtPanelResizedFrame(startFrame: CGRect(x: 100, y: 300, width: 640, height: 360), pointerMovedBy: CGSize(width: 0, height: -90), visibleFrame: screen)
        #expect(larger.height == 450 && larger.width == 800)
        #expect(larger.maxY == 660)
    }

    @Test func theGripStopsAtTheSmallestSizeAndAtTheScreensEdge() {
        let start = CGRect(x: 100, y: 300, width: 960, height: 540)
        let tiny = roomArtPanelResizedFrame(startFrame: start, pointerMovedBy: CGSize(width: -2000, height: 2000), visibleFrame: screen)
        #expect(tiny.size == roomArtPanelSmallestSize)
        let huge = roomArtPanelResizedFrame(startFrame: start, pointerMovedBy: CGSize(width: 3000, height: -3000), visibleFrame: screen)
        #expect(huge.maxX <= screen.maxX + 0.5 && huge.minY >= screen.minY - 0.5)
        #expect(abs(huge.width / huge.height - 16.0 / 9.0) < 0.001)
    }

    @Test(arguments: [roomArtPanelSmallestSize, roomArtPanelDefaultSize, CGSize(width: 1920, height: 1080)])
    func theCornerGripNeverOverlapsTheBottomRowsButtons(panelSize: CGSize) {
        let grip = roomArtPanelResizeGripFrame(panelSize: panelSize)
        // The tallest thing in the row, a status line of two lines, is about 48 points tall, so 56 leaves room.
        let bottomRow = roomArtPanelBottomRowFrame(panelSize: panelSize, rowHeight: 56)
        #expect(!grip.intersects(bottomRow), "grip \(grip), row \(bottomRow)")
        #expect(grip.minX - bottomRow.maxX >= 4)
        // The grip is in the corner and inside the panel, and the row still has room for its buttons at the smallest size.
        #expect(grip.maxX <= panelSize.width && grip.maxY <= panelSize.height && grip.maxX > panelSize.width - roomArtPanelContentInset)
        #expect(bottomRow.width >= 400)
    }
}

@MainActor
struct RoomArtStatusPillRenderTests {
    /// The failure line that showed with its first letters covered, at the smallest panel's width less its padding.
    private let failureLine = roomFurnitureNotDrawnStatusLineForTheTest
    private let rowWidth = roomArtPanelSmallestSize.width - 32

    /// The columns, in points from the pill's left edge, that hold the line's red letters.
    private func redLetterColumns(of view: some View, width: CGFloat) throws -> [Int] {
        let renderer = ImageRenderer(content: view.frame(width: width, alignment: .leading).background(Color.black))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        var columns = Set<Int>()
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = (row * image.width + column) * 4
                if bytes[offset] > 170 && bytes[offset + 1] < 130 && bytes[offset + 2] < 140 { columns.insert(column / 2) }
            }
        }
        return columns.sorted()
    }

    @Test func theLineStartsAtThePillsPaddingWithNothingOverItsFirstLetters() throws {
        let columns = try redLetterColumns(of: RoomArtStatusPill(text: failureLine, isAFailure: true), width: rowWidth)
        let firstColumn = try #require(columns.first)
        // The first letter starts at the padding, plus at most its own side bearing, so no icon or offset hides it.
        #expect(firstColumn >= Int(RoomArtStatusPill.horizontalPadding) - 1 && firstColumn <= Int(RoomArtStatusPill.horizontalPadding) + 3, "the first red column is \(firstColumn)")
        // The letters run on with no gap wider than a word space in the first 30 points. A 22 point disc over them would leave one.
        let firstLetters = columns.filter { $0 < firstColumn + 30 }
        #expect(zip(firstLetters, firstLetters.dropFirst()).allSatisfy { $1 - $0 <= 7 })
        // A line longer than the row stays inside the pill.
        let lastColumn = try #require(columns.last)
        #expect(lastColumn <= Int(rowWidth - RoomArtStatusPill.horizontalPadding) + 1)
    }
}

/// The furniture's could-not-draw status line, the one in the screenshot.
private let roomFurnitureNotDrawnStatusLineForTheTest = "I couldn't draw it this time. Click the floor to try again"

/// One view drawn at 2x, with its pixels as RGBA bytes. It draws in an `NSHostingView` in a window off every screen, which
/// is never shown, so the buttons' hover views draw as on screen. `ImageRenderer` draws them as a placeholder sign.
@MainActor
private struct RenderedPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ view: some View, dumpName: String? = nil) throws {
        let hostingView = NSHostingView(rootView: view)
        let fittingSize = hostingView.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(fittingSize.width * 2), pixelsHigh: Int(fittingSize.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )?.retagging(with: .sRGB))
        bitmap.size = fittingSize
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        if let dumpFolder = ProcessInfo.processInfo.environment["CLICKY_RENDER_DUMP_DIR"], let name = dumpName {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dumpFolder).appendingPathComponent("\(name).png"))
        }
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        width = image.width
        height = image.height
        bytes = Array(UnsafeBufferPointer(start: data, count: image.width * image.height * 4))
    }

    /// The color at a point of the view, from its top left.
    func color(atX x: CGFloat, y: CGFloat) -> [Int] {
        let offset = (Int(y * 2) * width + Int(x * 2)) * 4
        return (0..<3).map { channel in Int(bytes[offset + channel]) }
    }
}

private func channelsAreClose(_ first: [Int], _ second: [Int], within tolerance: Int = 3) -> Bool {
    zip(first, second).allSatisfy { firstChannel, secondChannel in abs(firstChannel - secondChannel) <= tolerance }
}

@MainActor
struct RoomArtBottomRowRenderTests {
    /// The row's width in the smallest panel.
    private let rowWidth = roomArtPanelBottomRowFrame(panelSize: roomArtPanelSmallestSize, rowHeight: 0).width

    private struct Row {
        var statusText: String
        var showsSavePhoto = false
        var showsPlace = false
        var shirtButtonTitle: String? = nil
    }

    private func bottomRow(of row: Row, statusMostLines: Int?) -> RoomArtPanelBottomRow {
        RoomArtPanelBottomRow(
            statusText: row.statusText, statusIsAFailure: false, showsSavePhoto: row.showsSavePhoto, showsPlace: row.showsPlace,
            shirtButtonTitle: row.shirtButtonTitle, accentColor: .orange, statusMostLines: statusMostLines
        )
    }

    private func view(of row: Row, statusMostLines: Int?) -> some View {
        bottomRow(of: row, statusMostLines: statusMostLines)
            .frame(width: rowWidth)
            .background(Color.black)
    }

    /// Whether the line draws the same with the panel's line limit as with none, so none of it is cut.
    private func showsWhole(_ row: Row, mostLines: Int) throws -> Bool {
        let limited = try RenderedPixels(view(of: row, statusMostLines: mostLines))
        let unlimited = try RenderedPixels(view(of: row, statusMostLines: nil))
        return limited.height == unlimited.height && limited.bytes == unlimited.bytes
    }

    /// Each of the panel's long status lines beside the buttons that show with it.
    private var longestRows: [Row] {
        let lostLines = [RoomArtSurfaceKind.wall.lostLine, RoomArtSurfaceKind.floor.lostLine, RoomArtStandsOn.tableOrShelf.lostLine, roomArtKeptRoomLostLine]
        let failures: [RoomArtFailure] = [
            .appSecretMissing, .pageNotHTTPS, .cameraAccessDenied, .noCamera, .notAPhysicalItem, .tooSmallToSee, .noClearPhoto,
            .notFlatForTheWall, .noPlaceClickyCanShow, .pageNotRead, .sizeNotOnThePage, .depthServiceUnavailable,
            .wallNotMeasured, .floorNotFound, .furnitureNotCutOut, .cannotBeDrawnOnYou, .workerUnreachable,
        ]
        let shirtCoachingLines = [ShirtFramingKind.noPerson, .standBack].compactMap(\.coachingLine)
        return (lostLines + failures.map(\.statusLine)).map { line in Row(statusText: line, showsSavePhoto: true) }
            + [RoomArtStandsOn.floor.notDrawnStatusLine, RoomArtStandsOn.tableOrShelf.notDrawnStatusLine, roomArtShirtReadyStatusLine]
                .map { line in Row(statusText: line, shirtButtonTitle: "Paint it") }
            + [roomArtShirtPaintedStatusLine, roomArtShirtPaintedOutOfReachLine]
                .map { line in Row(statusText: line, showsSavePhoto: true, shirtButtonTitle: "Back to live") }
            + (shirtCoachingLines + [roomArtShirtStepBackLine, roomArtShirtPaintingStatusLine])
                .map { line in Row(statusText: line, shirtButtonTitle: "Back to live") }
            + [roomFurnitureGhostStatusLine, roomFurnitureStepAsideLine, RoomArtSurfaceKind.floor.lostLine].map { line in Row(statusText: line, showsPlace: true) }
    }

    @Test func everyLongStatusLineShowsWholeInTwoLinesAtTheSmallestSize() throws {
        #expect(longestRows.count > 30)
        for row in longestRows {
            #expect(try showsWhole(row, mostLines: RoomArtStatusPill.mostLines), "cut: \(row.statusText)")
        }
    }

    @Test func oneLineWouldCutTheLostWallLineSoTheSecondLineIsNeeded() throws {
        #expect(try !showsWhole(Row(statusText: RoomArtSurfaceKind.wall.lostLine, showsSavePhoto: true), mostLines: 1))
    }

    @Test func theRowAndItsButtonsFitAtTheSmallestSize() throws {
        let rows = [
            ("room-art-row-lost-wall", Row(statusText: RoomArtSurfaceKind.wall.lostLine, showsSavePhoto: true)),
            ("room-art-row-painted-shirt", Row(statusText: roomArtShirtPaintedStatusLine, showsSavePhoto: true, shirtButtonTitle: "Back to live")),
            ("room-art-row-ghost", Row(statusText: roomFurnitureGhostStatusLine, showsPlace: true)),
        ]
        for (name, row) in rows {
            // With no fixed frame, a row whose content cannot shrink to the proposed width reports the wider size it takes.
            let widthTheRowTakes = NSHostingController(rootView: bottomRow(of: row, statusMostLines: RoomArtStatusPill.mostLines))
                .sizeThatFits(in: CGSize(width: rowWidth, height: 1000)).width
            #expect(widthTheRowTakes <= rowWidth, "\(name) takes \(widthTheRowTakes) points of \(rowWidth)")
            _ = try RenderedPixels(view(of: row, statusMostLines: RoomArtStatusPill.mostLines), dumpName: name)
        }
    }

    @Test func theStatusPillIsASolidCalloutSurfaceOverAWhitePage() throws {
        let pixels = try RenderedPixels(RoomArtStatusPill(text: "Reading the page…", isAFailure: false).background(Color.white))
        // Inside the left padding, clear of the letters and the edge. A translucent fill would let the white through.
        let fill = pixels.color(atX: 7, y: CGFloat(pixels.height) / 4)
        #expect(channelsAreClose(fill, [0x14, 0x17, 0x1e]), "the fill is \(fill)")
    }

    @Test func anAccentButtonIsFilledToItsEdgeWithNoStroke() throws {
        let accent = Color(hex: "#F97316")
        let pixels = try RenderedPixels(
            RoomArtPanelButton(title: "Paint it", accentColor: accent, accessibilityLabel: "Paint it") {}.background(Color.black)
        )
        // Half a point inside the capsule's left end, where a 1 point stroke would draw.
        let edge = pixels.color(atX: 0.5, y: RoomArtPanelButton.height / 2)
        #expect(channelsAreClose(edge, [0xF9, 0x73, 0x16], within: 10), "the edge is \(edge)")
    }

    @Test(arguments: ["#F97316", "#F4F4F5"])
    func aHoveredAccentFillStaysSolidAndChangesItsBrightness(accentHex: String) throws {
        func middle(isHovered: Bool, over page: Color) throws -> [Int] {
            let fill = RoomArtPanelButtonFill(accentColor: Color(hex: accentHex), isHovered: isHovered).frame(width: 80, height: 32)
            return try RenderedPixels(fill.background(page)).color(atX: 40, y: 16)
        }
        let hoveredOverBlack = try middle(isHovered: true, over: .black)
        let hoveredOverWhite = try middle(isHovered: true, over: .white)
        // A see-through fill would take on what is behind it.
        #expect(channelsAreClose(hoveredOverBlack, hoveredOverWhite), "over black \(hoveredOverBlack), over white \(hoveredOverWhite)")
        let resting = try middle(isHovered: false, over: .black)
        #expect(!channelsAreClose(hoveredOverBlack, resting, within: 6), "hovered \(hoveredOverBlack), resting \(resting)")
    }
}

struct RoomArtPanelStatusTextTests {
    private static var table: RoomArtPlacedItem {
        let cutout = CIContext().createCGImage(CIImage(color: .white), from: CGRect(x: 0, y: 0, width: 8, height: 8))!
        return .furniture(RoomFurniture(title: "Side table", widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55, cutoutImage: cutout, standsOn: .floor))
    }

    private static let floor = RoomArtSurface.floor(FloorPlane(
        center: SIMD3(0, 1, 2.5), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1),
        focalLengthPixels: 900, principalPoint: SIMD2(640, 360), distanceMeters: 2.7, floorTiltDegrees: 2, planeInlierShare: 0.9
    ))

    private let arranging = RoomArtPhase.arranging(id: RoomArtMeasurementID(number: 1), item: table, surface: floor)
    private let couldNotDraw = RoomArtPhase.couldNotDraw(id: RoomArtMeasurementID(number: 1), item: table, surface: floor)
    private let showing = RoomArtPhase.showing(item: table, surface: floor, moveFailure: nil)

    private func statusText(_ phase: RoomArtPhase, waiting: Bool, lost: Bool) -> String {
        roomArtPanelStatusText(phase: phase, waitingForTheLearnerToStepAside: waiting, theSurfaceIsLost: lost, shirtCoachingLine: nil, thePaintedTopIsOutOfReach: false)
    }

    @Test func theStepAsideRequestShowsWhileThePieceIsArranged() {
        #expect(statusText(arranging, waiting: true, lost: false) == roomFurnitureStepAsideLine)
        #expect(statusText(arranging, waiting: false, lost: false) == arranging.statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil, thePaintedTopIsOutOfReach: false))
    }

    @Test func aShowingPieceKeepsItsOwnLineWhileTheStepAsideFlagIsSet() {
        #expect(statusText(showing, waiting: true, lost: false) == showing.statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil, thePaintedTopIsOutOfReach: false))
        #expect(statusText(showing, waiting: true, lost: true) == RoomArtSurfaceKind.floor.lostLine)
    }

    @Test func aPhaseThePlacementMovedOnToShowsItsOwnLine() {
        #expect(statusText(couldNotDraw, waiting: true, lost: false) == RoomArtStandsOn.floor.notDrawnStatusLine)
    }

    @Test func aLostRoomWinsOverTheStepAsideRequest() {
        #expect(statusText(arranging, waiting: true, lost: true) == RoomArtSurfaceKind.floor.lostLine)
    }
}

/// Whether this session can get a drawable for a layer no window shows. CI's background login may not.
private func aDrawableCanBeMade() -> Bool {
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    layer.drawableSize = CGSize(width: 64, height: 36)
    return layer.device != nil && layer.nextDrawable() != nil
}

/// The real frame processor around a close.
struct RoomArtClosingFrameTests {
    private static func cameraFrame(_ color: CIColor) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let created = try #require(buffer)
        let bounds = CGRect(x: 0, y: 0, width: 64, height: 36)
        CIContext().render(CIImage(color: color).cropped(to: bounds), to: created, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return created
    }

    /// Delivers `frame` as the camera does, and waits until it is handled.
    private static func deliver(_ frame: CVPixelBuffer, to frameProcessor: RoomArtFrameProcessor) {
        nonisolated(unsafe) let frameToProcess = frame
        frameProcessor.processingQueue.sync { frameProcessor.process(frameToProcess) }
    }

    /// Runs `queueTheWork` while the processing queue is busy, ends the session with that work still waiting, and lets the
    /// queue run, as a close does while a frame is on its way.
    private static func endTheSessionBehindQueuedWork(of frameProcessor: RoomArtFrameProcessor, _ queueTheWork: () -> Void) {
        let theQueueIsHeld = DispatchSemaphore(value: 0)
        frameProcessor.processingQueue.async { theQueueIsHeld.wait() }
        queueTheWork()
        frameProcessor.endTheSession()
        theQueueIsHeld.signal()
        frameProcessor.processingQueue.sync {}
    }

    private static func isMostlyRed(_ image: CGImage) throws -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return pixel[0] > 180 && pixel[2] < 80
    }

    @Test(.enabled(if: aDrawableCanBeMade(), "This session gets no Metal drawable"))
    func aFrameOnItsWayAsTheSessionEndsIsNotShownAndTheNextSessionDraws() throws {
        let frameProcessor = RoomArtFrameProcessor()
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        Self.deliver(try Self.cameraFrame(.red), to: frameProcessor)
        #expect(try Self.isMostlyRed(try #require(frameProcessor.renderTheLastFrame())))
        let lateFrame = try Self.cameraFrame(.blue)
        Self.endTheSessionBehindQueuedWork(of: frameProcessor) {
            nonisolated(unsafe) let frame = lateFrame
            frameProcessor.processingQueue.async { frameProcessor.process(frame) }
        }
        #expect(try Self.isMostlyRed(try #require(frameProcessor.renderTheLastFrame())))
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        Self.deliver(try Self.cameraFrame(.blue), to: frameProcessor)
        #expect(try !Self.isMostlyRed(try #require(frameProcessor.renderTheLastFrame())))
    }

    @Test func theLoopStaysWhereItWasOnceTheSessionEndsAndMovesAgainInTheNext() {
        let frameProcessor = RoomArtFrameProcessor()
        func footprint(at x: CGFloat) -> RoomArtCorners {
            RoomArtCorners(clockwiseFromTopLeft: [CGPoint(x: x, y: 10), CGPoint(x: x + 20, y: 10), CGPoint(x: x + 20, y: 30), CGPoint(x: x, y: 30)])
        }
        func loopCornersNow() -> [CGPoint]? {
            frameProcessor.processingQueue.sync {}
            return frameProcessor.currentLoop()?.currentCorners.clockwiseFromTopLeft
        }
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        frameProcessor.outlineTheLoop(aroundKeyframeQuadrilateral: footprint(at: 0), inKeyframeNumber: 0)
        #expect(loopCornersNow() == footprint(at: 0).clockwiseFromTopLeft)
        Self.endTheSessionBehindQueuedWork(of: frameProcessor) {
            frameProcessor.outlineTheLoop(aroundKeyframeQuadrilateral: footprint(at: 30), inKeyframeNumber: 0)
        }
        #expect(loopCornersNow() == footprint(at: 0).clockwiseFromTopLeft)
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        frameProcessor.outlineTheLoop(aroundKeyframeQuadrilateral: footprint(at: 30), inKeyframeNumber: 0)
        #expect(loopCornersNow() == footprint(at: 30).clockwiseFromTopLeft)
    }
}

/// A panel that records being shown and hidden and never reaches the screen.
private final class RecordingPanel: NSPanel {
    private(set) var isShown = false
    override var isVisible: Bool { isShown }
    override func orderFrontRegardless() { isShown = true }
    override func orderOut(_ sender: Any?) { isShown = false }
}

@MainActor
struct RoomArtPanelMotionTests {
    /// The motion with fades the test ends by hand.
    @MainActor
    private final class Harness {
        var fades: [(alpha: CGFloat, seconds: Double, windowAlphaAtTheStart: CGFloat, end: @MainActor () -> Void)] = []
        let window = RecordingPanel(contentRect: CGRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        var reduceMotionIsOn = false
        lazy var motion = RoomArtPanelMotion(
            reduceMotionIsOn: { [unowned self] in reduceMotionIsOn },
            fadeTheWindow: { [unowned self] window, alpha, seconds, end in fades.append((alpha, seconds, window.alphaValue, end)) }
        )

        init() { content.wantsLayer = true }

        var grow: CAKeyframeAnimation? { content.layer?.animation(forKey: RoomArtPanelMotion.growAnimationKey) as? CAKeyframeAnimation }
    }

    @Test func thePanelGrowsOnTheGlideCurveAsItFadesIn() throws {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        #expect(harness.window.isShown)
        #expect(harness.fades.map(\.alpha) == [1])
        #expect(harness.fades.map(\.seconds) == [DS.Move.glide.curve.seconds()])
        let grow = try #require(harness.grow)
        #expect(grow.duration == DS.Move.glide.curve.seconds())
        let scales = try #require(grow.values as? [NSValue]).map(\.caTransform3DValue.m11)
        #expect(abs((scales.first ?? 0) - roomArtPanelOpeningStartScale) < 0.0001 && abs((scales.last ?? 0) - 1) < 0.0001)
    }

    @Test func aGrowingPanelTakesTheMouseOnlyOnceItHasGrown() {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        // The controls are drawn smaller than where they take clicks until the grow ends.
        #expect(harness.window.ignoresMouseEvents)
        harness.fades.last?.end()
        #expect(!harness.window.ignoresMouseEvents)
    }

    @Test func aPanelClosedWhileItGrowsNeverTakesTheMouse() {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        harness.motion.close(harness.window)
        harness.fades[0].end()
        #expect(harness.window.ignoresMouseEvents)
    }

    @Test func withReduceMotionThePanelOnlyFades() {
        let harness = Harness()
        harness.reduceMotionIsOn = true
        harness.motion.open(harness.window, growing: harness.content)
        #expect(harness.grow == nil)
        #expect(!harness.window.ignoresMouseEvents)
        #expect(harness.fades.map(\.seconds) == [DS.Move.fadeSeconds])
    }

    @Test func aClosingPanelTakesNoClicksAndLeavesWhenItsFadeEnds() {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        var timesReportedHidden = 0
        harness.motion.close(harness.window) { timesReportedHidden += 1 }
        #expect(harness.window.isShown && harness.window.ignoresMouseEvents)
        #expect(harness.fades.last?.alpha == 0 && harness.fades.last?.seconds == DS.Move.fadeSeconds)
        #expect(timesReportedHidden == 0)
        harness.fades.last?.end()
        #expect(!harness.window.isShown && timesReportedHidden == 1)
        // A window already off the screen is hidden at once.
        harness.motion.close(harness.window) { timesReportedHidden += 1 }
        #expect(timesReportedHidden == 2)
    }

    @Test func aPanelOpenedAgainDuringItsCloseStays() {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        var theCloseReportedHidden = false
        harness.motion.close(harness.window) { theCloseReportedHidden = true }
        harness.motion.open(harness.window, growing: harness.content)
        // The close's fade ends after the second open.
        harness.fades[1].end()
        #expect(harness.window.isShown && !theCloseReportedHidden)
        // The first open's grow still runs, so the mouse waits for the second open's fade.
        #expect(harness.window.ignoresMouseEvents)
        harness.fades[2].end()
        #expect(!harness.window.ignoresMouseEvents)
    }

    @Test func aPanelOpenedAgainDuringItsCloseFadesBackInWithNoSecondGrow() {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        harness.motion.close(harness.window)
        // The first open's grow has ended by now.
        harness.content.layer?.removeAllAnimations()
        harness.motion.open(harness.window, growing: harness.content)
        #expect(harness.grow == nil)
        #expect(!harness.window.ignoresMouseEvents)
        #expect(harness.fades.map(\.alpha) == [1, 0, 1])
    }

    @Test func aPanelOpenedAfterItsCloseHidItGrowsAndFadesInFromNothingAgain() throws {
        let harness = Harness()
        harness.motion.open(harness.window, growing: harness.content)
        harness.motion.close(harness.window)
        harness.fades.last?.end()
        #expect(!harness.window.isShown)
        // The first open's grow has ended by now, and the window is left opaque, so the second open has to start both itself.
        harness.content.layer?.removeAllAnimations()
        harness.window.alphaValue = 1
        harness.motion.open(harness.window, growing: harness.content)
        let scales = try #require(harness.grow?.values as? [NSValue]).map(\.caTransform3DValue.m11)
        #expect(abs((scales.first ?? 0) - roomArtPanelOpeningStartScale) < 0.0001)
        #expect(harness.fades.last?.alpha == 1 && harness.fades.last?.windowAlphaAtTheStart == 0)
    }

    @Test(arguments: [false, true])
    func openingThePanelEndsAHoverThePointerLeftWhileItClosed(reduceMotionIsOn: Bool) {
        let harness = Harness()
        harness.reduceMotionIsOn = reduceMotionIsOn
        let hoverView = HoverAndPointerNSView(frame: CGRect(x: 0, y: 0, width: 40, height: 40))
        hoverView.mouseLocationInTheWindow = { _ in CGPoint(x: 500, y: 300) }
        var reportedHovers: [Bool] = []
        hoverView.onHoverChange = { isNowHovered in reportedHovers.append(isNowHovered) }
        harness.content.addSubview(hoverView)
        harness.window.contentView?.addSubview(harness.content)
        // Hovered as the panel closed, and the closing window passed on no exit.
        hoverView.reportTheHover(true)
        harness.motion.open(harness.window, growing: harness.content)
        // A growing panel takes the mouse, and checks its hovers, as the grow ends. With no grow it does both at once.
        #expect(reportedHovers == (reduceMotionIsOn ? [true, false] : [true]))
        harness.fades.last?.end()
        #expect(reportedHovers == [true, false])
    }

    @Test func thePanelGrowsAboutTheMiddleOfItsTopEdge() {
        let size = CGSize(width: 960, height: 540)
        let transform = CATransform3DGetAffineTransform(RoomArtPanelMotion.transform(scalingBy: 0.5, aboutTheTopMiddleOf: size, anchorPoint: .zero))
        // With the anchor at the bottom left, the top middle stays put and the bottom left corner moves halfway to it.
        #expect(CGPoint(x: 480, y: 540).applying(transform) == CGPoint(x: 480, y: 540))
        #expect(CGPoint.zero.applying(transform) == CGPoint(x: 240, y: 270))
    }
}
