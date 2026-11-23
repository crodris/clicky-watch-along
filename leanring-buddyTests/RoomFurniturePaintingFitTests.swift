//
//  RoomFurniturePaintingFitTests.swift
//  leanring-buddyTests
//
//  A painting the service drew too big, shrunk back into its box before the judge (`furniturePaintingFit`), on made-up
//  geometry with the numbers of the plush astronaut placed on 2026-11-23: a 1920 by 1080 keyframe, its box's outline from
//  row 588 to 822 and its front face from 606 to 822, and the plush painted from row 488 to 845, 1.6 times the box.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import Clicky

extension CPUHeavyTests {
    struct RoomFurniturePaintingFitTests {
        /// The plush's box as the app projected it: the front face's corners, then the back face's, in y-down keyframe pixels.
        static let plushBox = [
            CGPoint(x: 846.0, y: 640.2), CGPoint(x: 944.6, y: 605.7), CGPoint(x: 946.1, y: 776.4), CGPoint(x: 849.3, y: 821.9),
            CGPoint(x: 719.9, y: 619.9), CGPoint(x: 822.6, y: 587.9), CGPoint(x: 826.0, y: 752.6), CGPoint(x: 725.3, y: 794.7),
        ]
        static let frameWidth = 1920, frameHeight = 1080
        /// The painted plush's columns, and the rows of its contact shadow under it.
        static let plushColumns = 700..<986
        static let shadowRows = 845..<866

        /// The test keyframe with the painter's reply drawn over it: a green piece from `topRow` to row 845 in
        /// `plushColumns`, with a row gap from `gapRows` when given, its contact shadow 35 levels darker under it, and the
        /// room around it relit 17 levels brighter, as the plush's painter relit the carpet and the door frame beside it. With
        /// `strayPatch`, a 40 by 40 patch of room 40 pixels left of the piece changes 30 levels, which is no part of it.
        private func reply(topRow: Int, gapRows: Range<Int>? = nil, strayPatch: Bool = false, over keyframe: CGImage) throws -> CGImage {
            let width = keyframe.width, height = keyframe.height
            var pixels = try #require(rgbaBytes(of: keyframe, width: width, height: height))
            func set(_ column: Int, _ row: Int, _ change: (Int) -> Int) {
                for channel in 0..<3 {
                    let byteIndex = (row * width + column) * 4 + channel
                    pixels[byteIndex] = UInt8(max(0, min(255, change(Int(pixels[byteIndex])))))
                }
            }
            for row in 400..<900 {
                for column in 600..<1080 { set(column, row) { $0 + 17 } }
            }
            for row in Self.shadowRows {
                for column in Self.plushColumns { set(column, row) { $0 - 52 } }
            }
            if strayPatch {
                for row in 420..<460 {
                    for column in 620..<660 { set(column, row) { $0 + 13 } }
                }
            }
            for row in topRow..<845 where !(gapRows?.contains(row) ?? false) {
                for column in Self.plushColumns {
                    let byteIndex = (row * width + column) * 4
                    pixels[byteIndex] = 20
                    pixels[byteIndex + 1] = 230
                    pixels[byteIndex + 2] = 40
                }
            }
            return try #require(rgbaImage(pixels, width: width, height: height))
        }

        private func keyframe() throws -> CGImage {
            try #require(roomFurnitureTestKeyframe(width: Self.frameWidth, height: Self.frameHeight))
        }

        private func fit(of reply: CGImage, over keyframe: CGImage, box: [CGPoint] = plushBox) throws -> FurniturePaintingFit? {
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: keyframe.width, height: keyframe.height))
            let replyPixels = try #require(rgbaBytes(of: reply, width: keyframe.width, height: keyframe.height))
            return furniturePaintingFit(keyframePixels: keyframePixels, correctedReplyPixels: replyPixels, width: keyframe.width, height: keyframe.height, projectedBox: box)
        }

        @Test func aPlushPaintedOneAndAHalfTimesItsBoxIsShrunkToTheMiddleOfItsFrontAndItsOutline() throws {
            let keyframe = try keyframe()
            let fit = try #require(try fit(of: reply(topRow: 488, over: keyframe), over: keyframe))
            #expect(fit.paintedTopRow == 488)
            // The front face is 216.2 rows and the outline 234.0, so the piece goes to 225.1 of its 333.9 painted rows.
            #expect(abs(fit.scale - 225.1 / 333.9) < 0.005)
            #expect(abs(fit.anchor.y - 821.9) < 0.01)
            #expect(abs(fit.anchor.x - (946.1 + 849.3 + 826.0 + 725.3) / 4) < 0.01)
        }

        @Test func aPieceThatFitsItsBoxIsLeftAsThePainterDrewIt() throws {
            let keyframe = try keyframe()
            // 222 rows, under both the paste's 24 rows above the box (258) and the judge's 15 percent (269).
            #expect(try fit(of: reply(topRow: 600, over: keyframe), over: keyframe) == nil)
            // 259 rows rises 1 row past what the paste takes above the box, which would cut it off, so it is fitted.
            #expect(try fit(of: reply(topRow: 563, over: keyframe), over: keyframe) != nil)
        }

        @Test func aPieceOverTwiceItsBoxIsNotFitted() throws {
            let keyframe = try keyframe()
            // 472 painted rows would take a scale of 0.48, under the least of 0.5.
            #expect(try fit(of: reply(topRow: 350, over: keyframe), over: keyframe) == nil)
            // 440 rows takes 0.51.
            #expect(try fit(of: reply(topRow: 382, over: keyframe), over: keyframe) != nil)
        }

        @Test func aGapInThePieceShorterThanTheGapRowsDoesNotEndIt() throws {
            let keyframe = try keyframe()
            // A pale band 8 rows tall between a helmet and a collar is inside the piece.
            let shortGap = try #require(try fit(of: reply(topRow: 488, gapRows: 540..<548, over: keyframe), over: keyframe))
            #expect(shortGap.paintedTopRow == 488)
            // A band 9 rows tall ends the piece there: the top is the row under it.
            let longGap = try #require(try fit(of: reply(topRow: 488, gapRows: 540..<549, over: keyframe), over: keyframe))
            #expect(longGap.paintedTopRow == 549)
        }

        @Test func aPieceTheFramesTopCutsOffIsNotFitted() throws {
            let keyframe = try keyframe()
            // The box 500 rows higher, from row 88 to 322: a piece painted from the frame's top row has a top the frame cut off,
            // though its 322 rows would take a scale of 0.7.
            let boxNearTheTop = Self.plushBox.map { CGPoint(x: $0.x, y: $0.y - 500) }
            #expect(try fit(of: reply(topRow: 0, over: keyframe), over: keyframe, box: boxNearTheTop) == nil)
            #expect(try fit(of: reply(topRow: 20, over: keyframe), over: keyframe, box: boxNearTheTop) != nil)
        }

        @Test func aBoxTheFrameCutsOffIsNotFitted() throws {
            let keyframe = try keyframe()
            let boxPastTheBottom = Self.plushBox.map { CGPoint(x: $0.x, y: $0.y + 300) }
            #expect(try fit(of: reply(topRow: 488, over: keyframe), over: keyframe, box: boxPastTheBottom) == nil)
        }

        /// The keyframe, the plush's mask, and the reply pasted with and without the box.
        private func pastedPlush(strayPatch: Bool = false) throws -> (keyframe: CGImage, maskPNG: Data, fitted: CGImage, unfitted: CGImage) {
            let keyframe = try keyframe()
            let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: Self.plushBox, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight, shadowMarginPixels: 24))
            let maskSource = try #require(CGImageSourceCreateWithData(maskPNG as CFData, nil))
            let mask = try #require(CGImageSourceCreateImageAtIndex(maskSource, 0, nil))
            let reply = try reply(topRow: 488, strayPatch: strayPatch, over: keyframe)
            let fitted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: reply, mask: mask, projectedBox: Self.plushBox, context: CIContext()))
            let unfitted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: reply, mask: mask, context: CIContext()))
            return (keyframe, maskPNG, fitted, unfitted)
        }

        @Test func theFittedPlushStandsInItsBoxAndIsKeptWhereTheUnfittedOneIsRefusedAsCutOff() throws {
            let (keyframe, maskPNG, fitted, unfitted) = try pastedPlush()
            let unfittedJudgement = RoomFurniturePaintedComposite.itemLayers(painted: unfitted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox)
            guard case .cutOffAlongTheRegionsTop = unfittedJudgement.refusal else {
                Issue.record("the unfitted plush was \(String(describing: unfittedJudgement.refusal))")
                return
            }
            let fittedJudgement = RoomFurniturePaintedComposite.itemLayers(painted: fitted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox)
            #expect(fittedJudgement.refusal == nil)
            #expect(fittedJudgement.layers != nil)
            // Shrunk to 0.674 about row 821.9, the piece's top lands at row 597, less the few rows its softened edge adds.
            let paintedRows = try #require(fittedJudgement.paintedRows)
            #expect((590...599).contains(paintedRows.lowerBound), "painted rows \(paintedRows)")
        }

        @Test func theFitLeavesTheRoomTheOversizedPieceCoveredAndTheRelitRoomAsFilmed() throws {
            let (keyframe, _, fitted, _) = try pastedPlush(strayPatch: true)
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: Self.frameWidth, height: Self.frameHeight))
            let fittedPixels = try #require(rgbaBytes(of: fitted, width: Self.frameWidth, height: Self.frameHeight))
            func pixel(_ pixels: [UInt8], _ column: Int, _ row: Int) -> [UInt8] {
                Array(pixels[((row * Self.frameWidth + column) * 4)..<((row * Self.frameWidth + column) * 4 + 3)])
            }
            // Where the painter drew the plush's head, above the shrunk plush, and where it relit the room 17 levels, the
            // keyframe shows.
            // (702, 564) is where the shrink would carry the stray patch, which is no part of the piece.
            for (column, row) in [(840, 520), (760, 560), (640, 700), (1040, 700), (840, 880), (702, 564)] {
                #expect(pixel(fittedPixels, column, row) == pixel(keyframePixels, column, row), "(\(column), \(row))")
            }
            // The shrunk plush, within the few levels the tone fit moves it, and its shadow.
            #expect(zip(pixel(fittedPixels, 840, 700), [20, 230, 40]).allSatisfy { abs(Int($0) - Int($1)) <= 6 })
            let shadowRow = Int(821.9 + (855 - 821.9) * 225.1 / 333.9)
            #expect(Int(pixel(fittedPixels, 840, shadowRow)[0]) < Int(pixel(keyframePixels, 840, shadowRow)[0]) - 20)
        }
    }
}

struct RoomFurniturePaintingRefusalTests {
    /// A box spanning rows 400 to 500 in front and 300 to 460 behind, as `RoomFurniturePaintedCompositeTests`'s chair.
    private let chairBox = [
        CGPoint(x: 500, y: 400), CGPoint(x: 700, y: 400), CGPoint(x: 700, y: 500), CGPoint(x: 500, y: 500),
        CGPoint(x: 520, y: 300), CGPoint(x: 680, y: 300), CGPoint(x: 680, y: 460), CGPoint(x: 520, y: 460),
    ]

    private func judgement(paintedColumns: Range<Int>, rows: Range<Int>) throws -> RoomFurniturePaintingJudgement {
        let keyframe = try #require(roomFurnitureTestKeyframe())
        let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: chairBox, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24))
        let context = try #require(CGContext(data: nil, width: keyframe.width, height: keyframe.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(keyframe, in: CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: paintedColumns.lowerBound, y: keyframe.height - rows.upperBound, width: paintedColumns.count, height: rows.count))
        return RoomFurniturePaintedComposite.itemLayers(painted: try #require(context.makeImage()), keyframe: keyframe, maskPNG: maskPNG, projectedBox: chairBox)
    }

    @Test func eachRefusalNamesItsRuleWithItsNumbers() throws {
        #expect(try judgement(paintedColumns: 540..<660, rows: 360..<500).refusal == nil)
        let short = try judgement(paintedColumns: 540..<660, rows: 420..<500).refusal
        #expect(short == .shorterThanTheFront(paintedRows: 80, leastRows: 85))
        guard case .floorContactOffTheFootprint(let contact, _) = try judgement(paintedColumns: 540..<660, rows: 300..<440).refusal else {
            Issue.record("a piece floating above its footprint was not refused for its floor contact")
            return
        }
        #expect(contact.y == 439)
        guard case .cutOffAlongTheRegionsTop = try judgement(paintedColumns: 520..<680, rows: 200..<500).refusal else {
            Issue.record("a piece painted past the region's top was not refused as cut off")
            return
        }
    }
}
