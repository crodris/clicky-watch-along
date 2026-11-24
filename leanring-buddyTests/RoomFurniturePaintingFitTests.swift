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
        /// changes 30 levels in all, more than the fit's 21 but under the 42 of strong change. Each of `castShadows` is a
        /// contact shadow as a painter casts one, the room at 0.3 of its light with its color kept.
        private func reply(
            parts: [PaintedPart], relitParts: [PaintedPart] = [], castShadows: [PaintedPart] = [], drawsTheShadow: Bool = true,
            strayPatch: Bool = false, over keyframe: CGImage
        ) throws -> CGImage {
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
            for shadow in castShadows {
                for row in shadow.rows {
                    for column in shadow.columns { set(column, row) { Int((Double($0) * 0.3).rounded()) } }
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

        /// The test keyframe with a light beige carpet in place of its dark floor, as in the plush's room, where a painted
        /// shadow changes the floor by far more than the judge's 0.2 of luminance. `carpetColor` gives another carpet.
        private func keyframeWithALightCarpet(carpetColor: [UInt8] = [200, 180, 150]) throws -> CGImage {
            let keyframe = try keyframe()
            var pixels = try #require(rgbaBytes(of: keyframe, width: keyframe.width, height: keyframe.height))
            for row in Int(Double(keyframe.height) * 0.6)..<keyframe.height {
                for column in 0..<keyframe.width {
                    let byteIndex = (row * keyframe.width + column) * 4
                    pixels[byteIndex] = carpetColor[0]
                    pixels[byteIndex + 1] = carpetColor[1]
                    pixels[byteIndex + 2] = carpetColor[2]
                }
            }
            return try #require(rgbaImage(pixels, width: keyframe.width, height: keyframe.height))
        }

        /// The fit as the paste asks for it, with the paste's region: the box's mask grown and feathered as the paste grows it.
        private func fit(of reply: CGImage, over keyframe: CGImage, box: [CGPoint] = plushBox) throws -> FurniturePaintingFit? {
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: keyframe.width, height: keyframe.height))
            let replyPixels = try #require(rgbaBytes(of: reply, width: keyframe.width, height: keyframe.height))
            let frameExtent = CGRect(x: 0, y: 0, width: keyframe.width, height: keyframe.height)
            let pasteRegion = roomFurnitureCompositeMaskPNG(projectedBox: box, frameWidth: keyframe.width, frameHeight: keyframe.height, shadowMarginPixels: 24)
                .flatMap { maskPNG in try? maskImage(maskPNG) }
                .flatMap { mask in
                    grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: furnitureCompositePasteSlackPixels, blurPixels: furnitureCompositePasteFeatherPixels, context: CIContext())
                }
                .flatMap { grownMask in grayBytes(of: grownMask, width: keyframe.width, height: keyframe.height) }
            return furniturePaintingFit(
                keyframePixels: keyframePixels, replyPixels: replyPixels, width: keyframe.width, height: keyframe.height, projectedBox: box, pasteRegion: pasteRegion
            )
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

        @Test func aFloatingPieceIsNotFittedOntoTheShadowPaintedUnderIt() throws {
            let keyframe = try keyframeWithALightCarpet()
            // The same floating plush, with a contact shadow painted on the footprint under it, from row 790 to the box's
            // lowest row. The shadow reaches the box but only got darker, so the plush does not stand on it.
            let floating = try reply(
                parts: [PaintedPart(columns: Self.plushColumns, rows: 488..<722)], castShadows: [PaintedPart(columns: 760..<930, rows: 790..<822)],
                drawsTheShadow: false, over: keyframe
            )
            let floatingFit = try fit(of: floating, over: keyframe)
            #expect(floatingFit == nil, "top \(floatingFit?.paintedTopRow ?? -1), lowest \(floatingFit?.paintedLowestRow ?? -1)")
            let (maskPNG, pasted) = try pasted(floating, over: keyframe)
            let judgement = RoomFurniturePaintedComposite.itemLayers(painted: pasted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox)
            #expect(judgement.refusal != nil)
        }

        @Test func aBlackPieceThatOnlyDarkensTheRoomIsStillFitted() throws {
            let keyframe = try keyframeWithALightCarpet(carpetColor: [190, 190, 190])
            // A charcoal plush, (30, 30, 32), drawn 1.4 times its box over the near-white wall and light gray floor: no pixel of it
            // brightened or changed color, as none of a shadow's do, so it stands on its own lowest row.
            var pixels = try #require(rgbaBytes(of: keyframe, width: keyframe.width, height: keyframe.height))
            for row in 495..<822 {
                for column in Self.plushColumns {
                    let byteIndex = (row * keyframe.width + column) * 4
                    pixels[byteIndex] = 30
                    pixels[byteIndex + 1] = 30
                    pixels[byteIndex + 2] = 32
                }
            }
            let charcoal = try #require(rgbaImage(pixels, width: keyframe.width, height: keyframe.height))
            let fit = try #require(try fit(of: charcoal, over: keyframe))
            #expect(fit.paintedTopRow == 495)
            #expect(fit.paintedLowestRow == 821)
            let (maskPNG, pasted) = try pasted(charcoal, over: keyframe)
            let judgement = RoomFurniturePaintedComposite.itemLayers(painted: pasted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox)
            #expect(judgement.refusal == nil, "\(String(describing: judgement.refusal)), painted rows \(String(describing: judgement.paintedRows))")
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
            // The judge's front-face minimum is 0.85 of 216.2 rows, 183.8, and the fitted piece measures from the box's top to
            // row 769 with its softened edge.
            let (maskPNG, pasted) = try pasted(standingAtTheBack, over: keyframe)
            let judgement = RoomFurniturePaintedComposite.itemLayers(painted: pasted, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox)
            print("Back of the footprint: the judge says \(judgement.refusal.map(String.init(describing:)) ?? "kept"), painted rows \(judgement.paintedRows.map(String.init(describing:)) ?? "none")")
            #expect(judgement.refusal == nil)
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

        @Test func aThinTopCountsForTheFitAsItDoesForTheJudge() throws {
            let keyframe = try keyframe()
            // A sofa 600 columns wide, with its front face from row 500 to 600 and its outline from row 380.
            let wideSofaBox = [
                CGPoint(x: 200, y: 500), CGPoint(x: 800, y: 500), CGPoint(x: 800, y: 600), CGPoint(x: 200, y: 600),
                CGPoint(x: 260, y: 380), CGPoint(x: 740, y: 380), CGPoint(x: 740, y: 520), CGPoint(x: 260, y: 520),
            ]
            // Its body is kept by the paste and the judge, but a finial 16 columns wide rises from row 300, above the
            // paste's top at row 356. The judge counts a row of 6 changed pixels there, while 2 percent of the search's 1200
            // columns would need 24, so the fit must count it as the judge does and shrink the piece.
            let body = PaintedPart(columns: 200..<800, rows: 400..<600)
            let finial = PaintedPart(columns: 492..<508, rows: 300..<400)
            let sofa = try reply(parts: [body, finial], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: sofa, over: keyframe, box: wideSofaBox))
            // The piece's softened edge leaves the finial's top 2 rows, at row 302, which still lands on the box's top.
            #expect((300...304).contains(fit.paintedTopRow), "top \(fit.paintedTopRow)")
            #expect(abs(rowAfterThe(fit, Double(fit.paintedTopRow)) - 380) < 0.01)
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
            // A lamp whose stem matches the wall: a base on the footprint (rows 720 to 845) and a shade (rows 440 to 570)
            // wholly above the box's top at row 588, with 150 bare rows between them. Both are kept, since the shade stands
            // straight above the box, and the piece runs from the shade's top.
            let base = PaintedPart(columns: 810..<890, rows: 720..<845)
            let shade = PaintedPart(columns: 760..<940, rows: 440..<570)
            let lamp = try reply(parts: [base, shade], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: lamp, over: keyframe))
            #expect(fit.paintedTopRow == 440)
            let (_, fitted) = try pasted(lamp, over: keyframe)
            // The shade's and the base's middles, where the fit takes them.
            let shadeRow = Int(rowAfterThe(fit, 505).rounded()), baseRow = Int(rowAfterThe(fit, 780).rounded())
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
            // A door's edge the edit moved, above the box and reaching over a quarter of it from the side.
            let doorEdge = PaintedPart(columns: 600..<760, rows: 340..<370)
            let relitCarpet = PaintedPart(columns: 735..<790, rows: 720..<790)
            let painting = try reply(parts: [plush, learner, doorEdge], relitParts: [relitCarpet], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: painting, over: keyframe))
            #expect(fit.paintedTopRow == 488)
            #expect(abs(fit.scale - (822 - Self.plushBoxTop) / 334) < 0.001)
            let (_, fitted) = try pasted(painting, over: keyframe)
            // The plush is shrunk into its box, and where the shrink would carry the learner the keyframe shows.
            let plushColumn = Int((fit.anchor.x + (850 - fit.anchor.x) * fit.scale).rounded())
            #expect(isThePiecesGreen(try pixel(fitted, plushColumn, Int(rowAfterThe(fit, 700).rounded()))))
            let learnerColumn = Int((fit.anchor.x + (650 - fit.anchor.x) * fit.scale).rounded()), learnerRow = Int(rowAfterThe(fit, 640).rounded())
            #expect(try pixel(fitted, learnerColumn, learnerRow) == pixel(keyframe, learnerColumn, learnerRow))
            let doorColumn = Int((fit.anchor.x + (680 - fit.anchor.x) * fit.scale).rounded()), doorRow = Int(rowAfterThe(fit, 355).rounded())
            #expect(try pixel(fitted, doorColumn, doorRow) == pixel(keyframe, doorColumn, doorRow), "door edge at (\(doorColumn), \(doorRow))")
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

        @Test func aFootPaintedPastTheGrownMaskIsPastedAndDrawnWhole() throws {
            let keyframe = try keyframe()
            // The box's mask reaches column 970 beside its front-right foot (946.1 plus the 24 pixel shadow margin), and the paste
            // grows it 24 more, to about 994. The painter drew a foot from the plush's side out to column 1034, 40 pixels past
            // that, as it drew the seated plush astronaut's feet on 2026-11-23. A strong patch at columns 1030 to 1060, no part
            // of the plush, changed past the mask too, inside the columns the piece is looked for in (to 1059).
            let plush = PaintedPart(columns: Self.plushColumns, rows: 600..<845)
            let foot = PaintedPart(columns: 986..<1034, rows: 780..<820)
            let strayPatch = PaintedPart(columns: 1030..<1060, rows: 620..<660)
            let painting = try reply(parts: [plush, foot, strayPatch], over: keyframe)
            #expect(try fit(of: painting, over: keyframe) == nil)
            let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: Self.plushBox, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight, shadowMarginPixels: 24))
            let pasted = try #require(furnitureCompositePastedWithItsRegion(
                keyframe: keyframe, generated: painting, mask: try maskImage(maskPNG), projectedBox: Self.plushBox, context: CIContext()
            ))
            // The foot's tip is pasted as the plush's body inside the mask is, with the same tone fit, and the room past it, the
            // stray patch, and the relit room beyond the mask stay as filmed.
            let footTip = try pixel(pasted.image, 1030, 800), plushBody = try pixel(pasted.image, 900, 700)
            #expect(footTip == plushBody, "foot \(footTip), body \(plushBody)")
            #expect(footTip != (try pixel(keyframe, 1030, 800)))
            for (column, row) in [(1060, 800), (1045, 640), (1050, 500), (1070, 880)] {
                #expect(try pixel(pasted.image, column, row) == pixel(keyframe, column, row), "(\(column), \(row))")
            }
            // The panel draws the item layer, the piece alone, and the foot is part of it.
            let judgement = RoomFurniturePaintedComposite.itemLayers(
                painted: pasted.image, pastedRegion: pasted.pastedRegion, pieceLayer: pasted.pieceLayer, keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox
            )
            #expect(judgement.refusal == nil, "\(String(describing: judgement.refusal))")
            let itemLayer = try #require(judgement.layers?.itemLayer)
            let layerPixels = try #require(rgbaBytes(of: itemLayer, width: Self.frameWidth, height: Self.frameHeight))
            func layerAlpha(_ column: Int, _ row: Int) -> UInt8 { layerPixels[(row * Self.frameWidth + column) * 4 + 3] }
            #expect(layerAlpha(1030, 800) == 255)
            #expect(layerAlpha(1060, 800) == 0)
            #expect(layerAlpha(1045, 640) == 0)
        }

        /// The item layer drawn over a live frame whose light moved since the keyframe, by the panel's own composition, as
        /// RGBA bytes. `change` gives each live pixel's channel from the keyframe's value and the channel's index.
        private func itemLayerOverALiveFrame(_ itemLayer: CGImage, keyframe: CGImage, change: (Int, Int) -> Int) throws -> (composed: [UInt8], live: [UInt8]) {
            var live = try #require(rgbaBytes(of: keyframe, width: Self.frameWidth, height: Self.frameHeight))
            for byteIndex in 0..<live.count where byteIndex % 4 != 3 {
                live[byteIndex] = UInt8(max(0, min(255, change(Int(live[byteIndex]), byteIndex % 4))))
            }
            let liveFrame = try #require(rgbaImage(live, width: Self.frameWidth, height: Self.frameHeight))
            let composed = RoomFurnitureComposition.frameWithTheFurniture(
                frame: CIImage(cgImage: liveFrame), itemLayer: CIImage(cgImage: itemLayer), shadowLayer: nil,
                keyframeToCurrent: .identity, grainStandardDeviation: 0, grainOffset: .zero
            )
            let frameRectangle = CGRect(x: 0, y: 0, width: Self.frameWidth, height: Self.frameHeight)
            let composedImage = try #require(CIContext().createCGImage(composed, from: frameRectangle, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
            return (try #require(rgbaBytes(of: composedImage, width: Self.frameWidth, height: Self.frameHeight)), live)
        }

        /// A lamp turned on after the placement makes the live room 40 levels brighter, and the camera's exposure and white
        /// balance drift a few levels with the light steady. The plush from row 600 fits its box, and from row 488 it is drawn
        /// too tall and the fit shrinks it, so both of the paste's ways of making the piece layer are drawn.
        @Test(arguments: ["a light came on", "a small drift"], [600, 488])
        func theLiveRoomShowsAroundThePieceWhenTheLightChangesSinceTheKeyframe(_ lightChange: String, plushTopRow: Int) throws {
            let keyframe = try keyframe()
            let plush = PaintedPart(columns: Self.plushColumns, rows: plushTopRow..<845)
            let foot = PaintedPart(columns: 986..<1034, rows: 780..<820)
            #expect(try (fit(of: try reply(parts: [plush, foot], over: keyframe), over: keyframe) != nil) == (plushTopRow == 488))
            let painting = try reply(parts: [plush, foot], over: keyframe)
            let (pasted, maskPNG, region) = try pastedWithItsRegion(painting, over: keyframe)
            let judgement = RoomFurniturePaintedComposite.itemLayers(
                painted: pasted.image, pastedRegion: pasted.pastedRegion, pieceLayer: pasted.pieceLayer,
                keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox
            )
            #expect(judgement.refusal == nil, "\(String(describing: judgement.refusal))")
            let itemLayer = try #require(judgement.layers?.itemLayer)
            let (composed, live) = try itemLayerOverALiveFrame(itemLayer, keyframe: keyframe) { value, channel in
                lightChange == "a light came on" ? value + 40 : value + [4, 2, -2][channel]
            }
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: Self.frameWidth, height: Self.frameHeight))
            let pastedPixels = try #require(rgbaBytes(of: pasted.image, width: Self.frameWidth, height: Self.frameHeight))
            func color(_ pixels: [UInt8], _ pixelIndex: Int) -> [Int] { (0..<3).map { Int(pixels[pixelIndex * 4 + $0]) } }
            func near(_ first: [Int], _ second: [Int]) -> Bool { zip(first, second).allSatisfy { abs($0 - $1) <= 2 } }
            // Inside the pasted region, the room the paste kept as filmed shows the live frame, not the keyframe.
            var unchangedRoomInTheRegion = 0, unchangedRoomDrawnOver = 0
            for pixelIndex in 0..<(Self.frameWidth * Self.frameHeight) where region[pixelIndex] > 0 && color(pastedPixels, pixelIndex) == color(keyframePixels, pixelIndex) {
                unchangedRoomInTheRegion += 1
                if !near(color(composed, pixelIndex), color(live, pixelIndex)) { unchangedRoomDrawnOver += 1 }
            }
            #expect(unchangedRoomInTheRegion > 5_000, "\(unchangedRoomInTheRegion) pixels of unchanged room in the region")
            #expect(unchangedRoomDrawnOver == 0, "\(unchangedRoomDrawnOver) of \(unchangedRoomInTheRegion) pixels of unchanged room drawn over")
            // Every pixel the paste changed strongly and took wholly from the reply, the piece, its foot past the grown mask,
            // and its contact shadow, is drawn as pasted. Along the piece's softened edge the paste took only a share of the
            // reply, and the live room shows through by the rest.
            let layerPixels = try #require(rgbaBytes(of: itemLayer, width: Self.frameWidth, height: Self.frameHeight))
            var paintedPixels = 0, paintedPixelsNotDrawn = 0
            for pixelIndex in 0..<(Self.frameWidth * Self.frameHeight) where layerPixels[pixelIndex * 4 + 3] == 255
                && zip(color(pastedPixels, pixelIndex), color(keyframePixels, pixelIndex)).contains(where: { abs($0 - $1) > 30 }) {
                paintedPixels += 1
                if !near(color(composed, pixelIndex), color(pastedPixels, pixelIndex)) { paintedPixelsNotDrawn += 1 }
            }
            #expect(paintedPixels > 30_000, "\(paintedPixels) painted pixels")
            #expect(paintedPixelsNotDrawn == 0, "\(paintedPixelsNotDrawn) of \(paintedPixels) painted pixels not drawn as pasted")
            if plushTopRow == 600 {
                // The foot's tip, past the grown mask.
                #expect(near(color(composed, 800 * Self.frameWidth + 1030), color(pastedPixels, 800 * Self.frameWidth + 1030)))
                #expect(!near(color(composed, 800 * Self.frameWidth + 1030), color(live, 800 * Self.frameWidth + 1030)))
            }
        }

        /// The room's light changed since the painting by a gain per channel in linear light: a lamp turned on (1.35 times
        /// brighter, which clips the test's wall) or a drift of white balance and exposure of a few percent. Relit by the
        /// gains measured on the two frames, the item layer over the live frame draws every pixel the paste took wholly from
        /// the reply as the paste brightened by the same gains, its margin of repainted room included, so no band of the old
        /// light shows. Drawn as it was made, the margin and the piece keep the old light.
        @Test(arguments: [SIMD3<Double>(1.35, 1.35, 1.35), SIMD3<Double>(1.04, 1.02, 0.97)], [600, 488])
        func theRelitLayerTakesTheRoomsNewLight(_ lightChange: SIMD3<Double>, plushTopRow: Int) throws {
            let keyframe = try keyframe()
            let plush = PaintedPart(columns: Self.plushColumns, rows: plushTopRow..<845)
            let foot = PaintedPart(columns: 986..<1034, rows: 780..<820)
            let painting = try reply(parts: [plush, foot], over: keyframe)
            let (pasted, maskPNG, _) = try pastedWithItsRegion(painting, over: keyframe)
            let judgement = RoomFurniturePaintedComposite.itemLayers(
                painted: pasted.image, pastedRegion: pasted.pastedRegion, pieceLayer: pasted.pieceLayer,
                keyframe: keyframe, maskPNG: maskPNG, projectedBox: Self.plushBox
            )
            let itemLayer = try #require(judgement.layers?.itemLayer)
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: Self.frameWidth, height: Self.frameHeight))
            let pastedPixels = try #require(rgbaBytes(of: pasted.image, width: Self.frameWidth, height: Self.frameHeight))
            let layerPixels = try #require(rgbaBytes(of: itemLayer, width: Self.frameWidth, height: Self.frameHeight))
            func relit(_ pixels: [UInt8]) -> [UInt8] {
                var relitPixels = pixels
                for byteIndex in 0..<pixels.count where byteIndex % 4 != 3 {
                    relitPixels[byteIndex] = sRGBByte(ofLinearLight: RoomArtLightReference.linearLight(ofSRGBByte: pixels[byteIndex]) * lightChange[byteIndex % 4])
                }
                return relitPixels
            }
            let livePixels = relit(keyframePixels)
            let liveFrame = try #require(rgbaImage(livePixels, width: Self.frameWidth, height: Self.frameHeight))
            func lightReference(_ pixels: [UInt8]) -> RoomArtLightReference {
                RoomArtLightReference(width: Self.frameWidth, height: Self.frameHeight, rgbaBytes: pixels, personConfidence: nil, keyframeToThisFrame: .identity)
            }
            let measuredGains = try #require(RoomArtLightReference.gains(from: lightReference(keyframePixels), to: lightReference(livePixels)))
            let expectedPixels = relit(pastedPixels)
            let frameRectangle = CGRect(x: 0, y: 0, width: Self.frameWidth, height: Self.frameHeight)
            func pixelsOffTheNewLight(lightGains: SIMD3<Double>) throws -> (off: Int, covered: Int) {
                let composed = RoomFurnitureComposition.frameWithTheFurniture(
                    frame: CIImage(cgImage: liveFrame), itemLayer: CIImage(cgImage: itemLayer), shadowLayer: nil,
                    keyframeToCurrent: .identity, grainStandardDeviation: 0, grainOffset: .zero, lightGains: lightGains
                )
                let composedImage = try #require(CIContext().createCGImage(composed, from: frameRectangle, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)))
                let composedPixels = try #require(rgbaBytes(of: composedImage, width: Self.frameWidth, height: Self.frameHeight))
                var off = 0, covered = 0
                // Where the layer is partly clear, Core Image blends it with the live room in linear light, while the paste
                // blended the reply with the keyframe in sRGB, so only the pixels the paste took wholly from the reply are compared.
                for pixelIndex in 0..<(Self.frameWidth * Self.frameHeight) where layerPixels[pixelIndex * 4 + 3] == 255 {
                    covered += 1
                    if (0..<3).contains(where: { abs(Int(composedPixels[pixelIndex * 4 + $0]) - Int(expectedPixels[pixelIndex * 4 + $0])) > 3 }) { off += 1 }
                }
                return (off, covered)
            }
            let relitResult = try pixelsOffTheNewLight(lightGains: measuredGains)
            #expect(relitResult.covered > 30_000)
            #expect(relitResult.off == 0, "\(relitResult.off) of \(relitResult.covered) pixels the layer covers are off the room's new light")
            if lightChange.x > 1.2 {
                let unrelitResult = try pixelsOffTheNewLight(lightGains: RoomArtLightReference.unchangedGains)
                #expect(unrelitResult.off > relitResult.covered / 2, "only \(unrelitResult.off) pixels kept the old light")
            }
        }

        /// The reply pasted with the box and its region, and the region's gray bytes.
        private func pastedWithItsRegion(_ painting: CGImage, over keyframe: CGImage, box: [CGPoint] = plushBox) throws -> (pasted: RoomFurniturePaintedKeyframe, maskPNG: Data, region: [UInt8]) {
            let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: box, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight, shadowMarginPixels: 24))
            let pasted = try #require(furnitureCompositePastedWithItsRegion(
                keyframe: keyframe, generated: painting, mask: try maskImage(maskPNG), projectedBox: box, context: CIContext()
            ))
            let region = try #require(grayBytes(of: pasted.pastedRegion, width: Self.frameWidth, height: Self.frameHeight))
            return (pasted, maskPNG, region)
        }

        @Test func feetPaintedDownTheFrameOnABoxThatFacesTheCameraArePasted() throws {
            let keyframe = try keyframe()
            // A box whose front faces the camera, so its front edge and the grown mask's bottom are level rows: the box ends at
            // row 800, its mask at 824, and the grown mask at about 848. The feet run down the frame to row 880, 32 rows past it.
            let facingTheCamera = [
                CGPoint(x: 900, y: 600), CGPoint(x: 1100, y: 600), CGPoint(x: 1100, y: 800), CGPoint(x: 900, y: 800),
                CGPoint(x: 920, y: 520), CGPoint(x: 1080, y: 520), CGPoint(x: 1080, y: 760), CGPoint(x: 920, y: 760),
            ]
            let plush = PaintedPart(columns: 920..<1080, rows: 560..<800)
            let feet = PaintedPart(columns: 950..<1050, rows: 800..<880)
            let painting = try reply(parts: [plush, feet], drawsTheShadow: false, over: keyframe)
            let (pasted, _, region) = try pastedWithItsRegion(painting, over: keyframe, box: facingTheCamera)
            let sole = try pixel(pasted.image, 1000, 870), plushBody = try pixel(pasted.image, 1000, 700)
            #expect(sole == plushBody, "sole \(sole), body \(plushBody)")
            #expect(region[870 * Self.frameWidth + 1000] == 255)
            #expect(try pixel(pasted.image, 1000, 915) == pixel(keyframe, 1000, 915))
        }

        @Test func aPieceThatStaysInsideTheGrownMaskAddsNothingPastIt() throws {
            let keyframe = try keyframe()
            // The plush's right edge stops 6 pixels inside the grown mask on the row where the mask is narrowest, so the margin
            // around it would reach past the grown mask while no pixel of it does.
            let maskPNG = try #require(roomFurnitureCompositeMaskPNG(projectedBox: Self.plushBox, frameWidth: Self.frameWidth, frameHeight: Self.frameHeight, shadowMarginPixels: 24))
            let grownMask = try #require(grownMaskImage(
                try maskImage(maskPNG), frameExtent: CGRect(x: 0, y: 0, width: Self.frameWidth, height: Self.frameHeight),
                radiusPixels: furnitureCompositePasteSlackPixels, blurPixels: furnitureCompositePasteFeatherPixels, context: CIContext()
            ))
            let grownMaskBytes = try #require(grayBytes(of: grownMask, width: Self.frameWidth, height: Self.frameHeight))
            let rows = 640..<760
            let firstColumnPastTheMask = try rows.map { row in
                try #require((900..<Self.frameWidth).first { grownMaskBytes[row * Self.frameWidth + $0] == 0 })
            }
            let narrowestColumn = try #require(firstColumnPastTheMask.min())
            let narrowestRow = rows.lowerBound + (firstColumnPastTheMask.firstIndex(of: narrowestColumn) ?? 0)
            let painting = try reply(parts: [PaintedPart(columns: 760..<(narrowestColumn - 6), rows: rows)], drawsTheShadow: false, over: keyframe)
            let (_, _, region) = try pastedWithItsRegion(painting, over: keyframe)
            #expect(region[narrowestRow * Self.frameWidth + narrowestColumn + 2] == 0)
        }

        @Test func everyPixelAFittedPasteChangedIsInItsRegion() throws {
            let keyframe = try keyframe()
            // The plush drawn 1.6 times its box, with an arm out to column 1058. The fit shrinks it to 0.70 about column 836.7,
            // which carries the arm's end to about column 992 at rows 666 to 694, past the grown mask there (about 973).
            let plush = PaintedPart(columns: Self.plushColumns, rows: 488..<845)
            let arm = PaintedPart(columns: 986..<1058, rows: 600..<640)
            let painting = try reply(parts: [plush, arm], over: keyframe)
            #expect(try fit(of: painting, over: keyframe) != nil)
            let (pasted, _, region) = try pastedWithItsRegion(painting, over: keyframe)
            let pastedPixels = try #require(rgbaBytes(of: pasted.image, width: Self.frameWidth, height: Self.frameHeight))
            let keyframePixels = try #require(rgbaBytes(of: keyframe, width: Self.frameWidth, height: Self.frameHeight))
            let changedPixelsOutsideTheRegion = (0..<(Self.frameWidth * Self.frameHeight)).filter { pixelIndex in
                region[pixelIndex] == 0 && (0..<3).contains { pastedPixels[pixelIndex * 4 + $0] != keyframePixels[pixelIndex * 4 + $0] }
            }
            #expect(changedPixelsOutsideTheRegion.isEmpty, "\(changedPixelsOutsideTheRegion.count) changed pixels outside the region")
            // The shrunk arm is pasted past the grown mask.
            let armEnd = try pixel(pasted.image, 985, 680)
            #expect(armEnd != (try pixel(keyframe, 985, 680)), "\(armEnd)")
        }

        @Test func aLearnerOverlappingTheBoxIsPastedNoLowerThanTheBoxIsTall() throws {
            let keyframe = try keyframe()
            // A learner the edit re-rendered overlaps the box's lower left and runs to the frame's bottom. The box is 234 rows
            // tall and ends at row 822, so the piece is looked for down to row 1056 and no lower.
            let plush = PaintedPart(columns: 760..<940, rows: 600..<800)
            let learner = PaintedPart(columns: 690..<780, rows: 760..<1080)
            let painting = try reply(parts: [plush, learner], drawsTheShadow: false, over: keyframe)
            let (pasted, _, region) = try pastedWithItsRegion(painting, over: keyframe)
            #expect(region[1070 * Self.frameWidth + 730] == 0)
            #expect(try pixel(pasted.image, 730, 1070) == pixel(keyframe, 730, 1070))
        }

        @Test func aFittedPiecesFeetBelowTheBoxArePasted() throws {
            let keyframe = try keyframe()
            // The plush drawn 1.6 times its box, with feet drawn down the frame to row 920, 98 rows below the box. The fit stands it
            // on row 822 and shrinks it to 0.70, so its feet end at about row 891.
            let plush = PaintedPart(columns: Self.plushColumns, rows: 488..<822)
            let feet = PaintedPart(columns: 800..<880, rows: 822..<920)
            let painting = try reply(parts: [plush, feet], drawsTheShadow: false, over: keyframe)
            let fit = try #require(try fit(of: painting, over: keyframe))
            let soleRow = Int(rowAfterThe(fit, 900).rounded()), soleColumn = Int((fit.anchor.x + (840 - fit.anchor.x) * fit.scale).rounded())
            let (pasted, _, region) = try pastedWithItsRegion(painting, over: keyframe)
            #expect(try pixel(pasted.image, soleColumn, soleRow) != pixel(keyframe, soleColumn, soleRow), "sole at (\(soleColumn), \(soleRow))")
            #expect(region[soleRow * Self.frameWidth + soleColumn] > 200)
        }

        @Test func aLearnerBesideTheBoxStaysAsFilmedPastTheGrownMask() throws {
            let keyframe = try keyframe()
            // A narrow plush with a foot drawn out to column 1034, past the grown mask, and the learner the edit re-rendered
            // left of the box, inside the columns the piece is looked for in (from 607) and past the grown mask there (about 696).
            let plush = PaintedPart(columns: 820..<880, rows: 600..<845)
            let foot = PaintedPart(columns: 880..<1034, rows: 780..<820)
            let learner = PaintedPart(columns: 610..<690, rows: 440..<840)
            let painting = try reply(parts: [plush, foot, learner], drawsTheShadow: false, over: keyframe)
            let (pasted, _, region) = try pastedWithItsRegion(painting, over: keyframe)
            #expect(region[800 * Self.frameWidth + 1025] == 255)
            #expect(try pixel(pasted.image, 615, 640) == pixel(keyframe, 615, 640))
            #expect(region[640 * Self.frameWidth + 615] == 0)
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
