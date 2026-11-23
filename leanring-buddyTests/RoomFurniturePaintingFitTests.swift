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
        /// Its top row is 587.9, its lowest 821.9, and its footprint runs from row 752.6 to 821.9.
        static let plushBox = [
            CGPoint(x: 846.0, y: 640.2), CGPoint(x: 944.6, y: 605.7), CGPoint(x: 946.1, y: 776.4), CGPoint(x: 849.3, y: 821.9),
            CGPoint(x: 719.9, y: 619.9), CGPoint(x: 822.6, y: 587.9), CGPoint(x: 826.0, y: 752.6), CGPoint(x: 725.3, y: 794.7),
        ]
        static let plushBoxTop = 587.9
        static let frameWidth = 1920, frameHeight = 1080
        /// The painted plush's columns, and the rows of its contact shadow under it.
        static let plushColumns = 700..<986
        static let shadowRows = 845..<866

        /// A solid green rectangle of the reply, in keyframe columns and rows.
        struct PaintedPart {
            let columns: Range<Int>
            let rows: Range<Int>
        }

        /// The test keyframe with the painter's reply drawn over it: each of `parts` in solid green, the plush's contact
        /// shadow 35 levels darker under it when `drawsTheShadow`, and the room around it relit 17 levels brighter, as the
        /// plush's painter relit the carpet and the door frame beside it. With `strayPatch`, a 40 by 40 patch of room 40
        /// pixels left of the piece changes 30 levels, which is no part of it. Each of `relitParts`, inside the relit room,
        /// changes 30 levels in all, more than the fit's 21 but under the 42 of strong change.
        private func reply(parts: [PaintedPart], relitParts: [PaintedPart] = [], drawsTheShadow: Bool = true, strayPatch: Bool = false, over keyframe: CGImage) throws -> CGImage {
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
            if drawsTheShadow {
                for row in Self.shadowRows {
                    for column in Self.plushColumns { set(column, row) { $0 - 52 } }
                }
            }
            if strayPatch {
                for row in 420..<460 {
                    for column in 620..<660 { set(column, row) { $0 + 13 } }
                }
            }
            for part in relitParts {
                for row in part.rows {
                    for column in part.columns { set(column, row) { $0 + 13 } }
                }
            }
            for part in parts {
                for row in part.rows {
                    for column in part.columns {
                        let byteIndex = (row * width + column) * 4
                        pixels[byteIndex] = 20
                        pixels[byteIndex + 1] = 230
                        pixels[byteIndex + 2] = 40
                    }
                }
            }
            return try #require(rgbaImage(pixels, width: width, height: height))
        }

        /// The plush from `topRow` down to row 845 in `plushColumns`, with its shadow.
        private func reply(topRow: Int, strayPatch: Bool = false, over keyframe: CGImage) throws -> CGImage {
            try reply(parts: [PaintedPart(columns: Self.plushColumns, rows: topRow..<845)], strayPatch: strayPatch, over: keyframe)
        }

        private func maskImage(_ maskPNG: Data) throws -> CGImage {
            let maskSource = try #require(CGImageSourceCreateWithData(maskPNG as CFData, nil))
            return try #require(CGImageSourceCreateImageAtIndex(maskSource, 0, nil))
        }

        private func keyframe() throws -> CGImage {
            try #require(roomFurnitureTestKeyframe(width: Self.frameWidth, height: Self.frameHeight))
        }

        private func fit(of reply: CGImage, over keyframe: CGImage, box: [CGPoint] = plushBox) throws -> FurniturePaintingFit? {
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: keyframe.width, height: keyframe.height))
            let replyPixels = try #require(rgbaBytes(of: reply, width: keyframe.width, height: keyframe.height))
            return furniturePaintingFit(keyframePixels: keyframePixels, replyPixels: replyPixels, width: keyframe.width, height: keyframe.height, projectedBox: box)
        }

        /// Where the fit puts a reply row: shrunk toward the anchor's row.
        private func rowAfterThe(_ fit: FurniturePaintingFit, _ row: Double) -> Double {
            fit.anchor.y + (row - fit.anchor.y) * fit.scale
        }

        @Test func aPlushPaintedOneAndAHalfTimesItsBoxIsShrunkUntilItsTopMeetsTheBoxsTop() throws {
            let keyframe = try keyframe()
            let fit = try #require(try fit(of: reply(topRow: 488, over: keyframe), over: keyframe))
            #expect(fit.paintedTopRow == 488)
            // The plush runs below the box, so it stands on the box's lowest row as the judge counts it, 822.
            #expect(fit.paintedLowestRow == 822)
            // Its 334 rows go to the box's 234.1, from row 822 up to the box's top.
            #expect(abs(fit.scale - 234.1 / 334) < 0.001)
            #expect(abs(rowAfterThe(fit, 488) - Self.plushBoxTop) < 0.01)
            #expect(fit.anchor.y == 822)
            #expect(abs(fit.anchor.x - (946.1 + 849.3 + 826.0 + 725.3) / 4) < 0.01)
        }

        @Test func aPieceThatFitsItsBoxIsLeftAsThePainterDrewIt() throws {
            let keyframe = try keyframe()
            // 222 rows, under both the paste's 24 rows above the box (from row 564) and the judge's 15 percent (269).
            #expect(try fit(of: reply(topRow: 600, over: keyframe), over: keyframe) == nil)
            // Row 563 rises 1 row past what the paste takes above the box, which would cut it off, so it is fitted.
            #expect(try fit(of: reply(topRow: 563, over: keyframe), over: keyframe) != nil)
            // From row 570 the paste and the judge keep it, even with a change beside the box that reaches higher.
            let besideTheBox = PaintedPart(columns: 610..<670, rows: 440..<840)
            let keptWithAChangeBeside = try reply(parts: [PaintedPart(columns: Self.plushColumns, rows: 570..<845), besideTheBox], over: keyframe)
            #expect(try fit(of: keptWithAChangeBeside, over: keyframe) == nil)
        }

        @Test func aPieceOverTwiceItsBoxIsNotFitted() throws {
            let keyframe = try keyframe()
            // 472 painted rows would take a scale of 234.1 / 472 = 0.496, under the least of 0.5.
            #expect(try fit(of: reply(topRow: 350, over: keyframe), over: keyframe) == nil)
            // 440 rows takes 0.53.
            #expect(try fit(of: reply(topRow: 382, over: keyframe), over: keyframe) != nil)
        }

        @Test func aPieceTheFramesTopCutsOffIsNotFitted() throws {
            let keyframe = try keyframe()
            // The box 500 rows higher, from row 88 to 322: a piece painted from the frame's top row has a top the frame cut off,
            // though from row 20 its 302 rows would take a scale of 0.78.
            let boxNearTheTop = Self.plushBox.map { CGPoint(x: $0.x, y: $0.y - 500) }
            #expect(try fit(of: reply(topRow: 0, over: keyframe), over: keyframe, box: boxNearTheTop) == nil)
            #expect(try fit(of: reply(topRow: 20, over: keyframe), over: keyframe, box: boxNearTheTop) != nil)
        }

        @Test func aBoxTheFrameCutsOffIsNotFitted() throws {
            let keyframe = try keyframe()
            let boxPastTheBottom = Self.plushBox.map { CGPoint(x: $0.x, y: $0.y + 300) }
            #expect(try fit(of: reply(topRow: 488, over: keyframe), over: keyframe, box: boxPastTheBottom) == nil)
        }

        @Test func aRightSizedPieceFloatingAboveItsFootprintIsNotFittedAndTheJudgeRefusesIt() throws {
            let keyframe = try keyframe()
            // The plush at its box's height, 234 rows, but standing on row 721, 100 rows above the box's lowest row and 21
            // above the footprint's top less its slack (752.6 - 10.4). Measured from the box's lowest row it reads as 334 rows,
            // and shrinking it to 0.57 would set it down on the footprint.
            let floating = try reply(parts: [PaintedPart(columns: Self.plushColumns, rows: 488..<722)], drawsTheShadow: false, over: keyframe)
            #expect(try fit(of: floating, over: keyframe) == nil)
            let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: Self.plushBox, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight, shadowMarginPixels: 24))
            let mask = try maskImage(maskPNG)
            let pasted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: floating, mask: mask, projectedBox: Self.plushBox, context: CIContext()))
            let judgement = RoomFurniturePaintedComposite.itemLayers(painted: pasted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox)
            #expect(judgement.refusal != nil)
        }

        @Test func aPieceStandingOnTheBackOfItsFootprintKeepsItsRowAndIsShrunkOnlyToTheBoxsTop() throws {
            let keyframe = try keyframe()
            // The plush stands on row 769, near the back of its footprint, and rises 320 rows to row 450.
            let standingAtTheBack = try reply(parts: [PaintedPart(columns: Self.plushColumns, rows: 450..<770)], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: standingAtTheBack, over: keyframe))
            #expect(fit.paintedLowestRow == 769)
            #expect(fit.anchor.y == 769)
            // It keeps row 769 and its top lands on the box's top: 181.1 of its 319 rows, as tall as the box allows there.
            // Measured from the box's lowest row it read as 372 rows and was shrunk to 0.605 about row 821.9.
            #expect(abs(fit.scale - (769 - Self.plushBoxTop) / 319) < 0.001)
            #expect(abs(rowAfterThe(fit, 450) - Self.plushBoxTop) < 0.01)
        }

        @Test func aDeepBoxDrawnTooTallIsShrunkOnlyToItsOutline() throws {
            let keyframe = try keyframe()
            // A sofa seen from a laptop camera: its front face 100 rows tall (500 to 600), its outline 220 (380 to 600).
            let sofaBox = [
                CGPoint(x: 300, y: 500), CGPoint(x: 700, y: 500), CGPoint(x: 700, y: 600), CGPoint(x: 300, y: 600),
                CGPoint(x: 350, y: 380), CGPoint(x: 650, y: 380), CGPoint(x: 650, y: 520), CGPoint(x: 350, y: 520),
            ]
            // Painted 260 rows tall, 118 percent of the outline: past the judge's 115 and 24 rows past the paste.
            let sofa = try reply(parts: [PaintedPart(columns: 300..<700, rows: 340..<600)], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: sofa, over: keyframe, box: sofaBox))
            #expect(fit.paintedTopRow == 340)
            #expect(fit.paintedLowestRow == 599)
            // Shrunk to 0.846, so its top lands on the outline's top. The middle of the front face and the outline, 160 rows,
            // took 0.615 and drew the sofa about 27 percent too short and too narrow.
            #expect(abs(fit.scale - 219.0 / 259) < 0.001)
            #expect(abs(rowAfterThe(fit, 340) - 380) < 0.01)
        }

        /// The keyframe, the plush's mask, and the reply pasted with the box, through the client's own paste.
        private func pasted(_ reply: CGImage, over keyframe: CGImage) throws -> (maskPNG: Data, fitted: CGImage) {
            let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: Self.plushBox, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight, shadowMarginPixels: 24))
            let mask = try maskImage(maskPNG)
            let fitted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: reply, mask: mask, projectedBox: Self.plushBox, context: CIContext()))
            return (maskPNG, fitted)
        }

        private func pixel(_ image: CGImage, _ column: Int, _ row: Int) throws -> [UInt8] {
            let pixels = try #require(rgbaBytes(of: image, width: image.width, height: image.height))
            return Array(pixels[((row * image.width + column) * 4)..<((row * image.width + column) * 4 + 3)])
        }

        private func isThePiecesGreen(_ color: [UInt8]) -> Bool {
            zip(color, [20, 230, 40]).allSatisfy { abs(Int($0) - Int($1)) <= 8 }
        }

        @Test func anItemInTwoSeparatePartsKeepsBothParts() throws {
            let keyframe = try keyframe()
            // A lamp whose stem matches the wall: a base on the footprint (rows 720 to 845) and a shade (rows 440 to 620)
            // with 100 bare rows between them. Both are kept, and the piece runs from the shade's top.
            let base = PaintedPart(columns: 810..<890, rows: 720..<845)
            let shade = PaintedPart(columns: 760..<940, rows: 440..<620)
            let lamp = try reply(parts: [base, shade], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: lamp, over: keyframe))
            #expect(fit.paintedTopRow == 440)
            let (_, fitted) = try pasted(lamp, over: keyframe)
            // The shade's and the base's middles, where the fit takes them.
            let shadeRow = Int(rowAfterThe(fit, 530).rounded()), baseRow = Int(rowAfterThe(fit, 780).rounded())
            let middleColumn = Int((fit.anchor.x + (850 - fit.anchor.x) * fit.scale).rounded())
            #expect(isThePiecesGreen(try pixel(fitted, middleColumn, shadeRow)), "shade at (\(middleColumn), \(shadeRow))")
            #expect(isThePiecesGreen(try pixel(fitted, middleColumn, baseRow)), "base at (\(middleColumn), \(baseRow))")
        }

        @Test func aStrongerChangeBesideTheBoxIsNoPartOfThePiece() throws {
            let keyframe = try keyframe()
            // A narrow plush in the box's columns (820 to 880) and, left of the box, a larger patch the edit re-rendered (a
            // learner, say), stronger than the plush and taller, from row 440. Inside the box, apart from the plush, a patch of
            // carpet the painter relit 30 levels, which reaches the box but never changes strongly.
            let plush = PaintedPart(columns: 820..<880, rows: 488..<845)
            let learner = PaintedPart(columns: 610..<690, rows: 440..<840)
            let relitCarpet = PaintedPart(columns: 735..<790, rows: 720..<790)
            let painting = try reply(parts: [plush, learner], relitParts: [relitCarpet], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: painting, over: keyframe))
            #expect(fit.paintedTopRow == 488)
            #expect(abs(fit.scale - (822 - Self.plushBoxTop) / 334) < 0.001)
            let (_, fitted) = try pasted(painting, over: keyframe)
            // The plush is shrunk into its box, and where the shrink would carry the learner the keyframe shows.
            let plushColumn = Int((fit.anchor.x + (850 - fit.anchor.x) * fit.scale).rounded())
            #expect(isThePiecesGreen(try pixel(fitted, plushColumn, Int(rowAfterThe(fit, 700).rounded()))))
            let learnerColumn = Int((fit.anchor.x + (650 - fit.anchor.x) * fit.scale).rounded()), learnerRow = Int(rowAfterThe(fit, 640).rounded())
            #expect(try pixel(fitted, learnerColumn, learnerRow) == pixel(keyframe, learnerColumn, learnerRow))
            let carpetColumn = Int((fit.anchor.x + (762 - fit.anchor.x) * fit.scale).rounded()), carpetRow = Int(rowAfterThe(fit, 755).rounded())
            #expect(try pixel(fitted, carpetColumn, carpetRow) == pixel(keyframe, carpetColumn, carpetRow), "relit carpet at (\(carpetColumn), \(carpetRow))")
        }

        /// The keyframe, the plush's mask, and the reply pasted with and without the box.
        private func pastedPlush(strayPatch: Bool = false) throws -> (keyframe: CGImage, maskPNG: Data, fitted: CGImage, unfitted: CGImage) {
            let keyframe = try keyframe()
            let reply = try reply(topRow: 488, strayPatch: strayPatch, over: keyframe)
            let (maskPNG, fitted) = try pasted(reply, over: keyframe)
            let mask = try maskImage(maskPNG)
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
            // Shrunk to 0.701 about row 822, the piece's top lands on the box's top, row 588, less the few rows its softened
            // edge adds.
            let paintedRows = try #require(fittedJudgement.paintedRows)
            #expect((580...590).contains(paintedRows.lowerBound), "painted rows \(paintedRows)")
        }

        @Test func theFitLeavesTheRoomTheOversizedPieceCoveredAndTheRelitRoomAsFilmed() throws {
            let (keyframe, _, fitted, _) = try pastedPlush(strayPatch: true)
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: Self.frameWidth, height: Self.frameHeight))
            let fittedPixels = try #require(rgbaBytes(of: fitted, width: Self.frameWidth, height: Self.frameHeight))
            func pixel(_ pixels: [UInt8], _ column: Int, _ row: Int) -> [UInt8] {
                Array(pixels[((row * Self.frameWidth + column) * 4)..<((row * Self.frameWidth + column) * 4 + 3)])
            }
            let scale = (822 - Self.plushBoxTop) / 334
            // Where the painter drew the plush's head, above the shrunk plush, and where it relit the room 17 levels, the
            // keyframe shows. (699, 554) is where the shrink would carry the stray patch, which is no part of the piece.
            for (column, row) in [(840, 520), (760, 560), (640, 700), (1040, 700), (840, 880), (699, 554)] {
                #expect(pixel(fittedPixels, column, row) == pixel(keyframePixels, column, row), "(\(column), \(row))")
            }
            // The shrunk plush, within the few levels the tone fit moves it, and its shadow.
            #expect(zip(pixel(fittedPixels, 840, 700), [20, 230, 40]).allSatisfy { abs(Int($0) - Int($1)) <= 6 })
            let shadowRow = Int(822 + (855 - 822) * scale)
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
