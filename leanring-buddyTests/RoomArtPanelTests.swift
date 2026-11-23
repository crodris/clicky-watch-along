//
//  RoomArtPanelTests.swift
//  leanring-buddyTests
//
//  The room art panel's frame as the learner moves and resizes it, and its status line drawn at 2x.
//

import AppKit
import CoreGraphics
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
        // The tallest button in the row, Paint it or Save photo, is about 34 points tall, so 44 leaves room.
        let bottomRow = roomArtPanelBottomRowFrame(panelSize: panelSize, rowHeight: 44)
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
        // A line longer than the row is cut at its end, inside the pill.
        let lastColumn = try #require(columns.last)
        #expect(lastColumn <= Int(rowWidth - RoomArtStatusPill.horizontalPadding) + 1)
    }
}

/// The furniture's could-not-draw status line, the one in the screenshot.
private let roomFurnitureNotDrawnStatusLineForTheTest = "I couldn't draw it this time. Click the floor to try again"
