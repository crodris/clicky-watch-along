//
//  PaperMaterialTests.swift
//  leanring-buddyTests
//
//  Paper, the material for what the learner keeps (`PaperMaterial.swift`): its colors and their contrast, the quiz recap Card
//  printed on it, the highlight that takes the accent, the colophon, and the Save photo receipt. The Card is drawn in an
//  `NSHostingView` in a window off every screen (an `ImageRenderer` draws its buttons' hover views as a sign), and the receipt
//  with an `ImageRenderer` at 2x. Both are read as raw bytes. Set `CLICKY_RENDER_DUMP_DIR` to save each render as a PNG.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

// MARK: - Reading a drawing

/// A drawing of a view, read in points from its top left corner.
private struct PaperRaster {
    let drawing: DrawingPixels

    var pointsWide: CGFloat { CGFloat(drawing.width) / drawing.pixelsPerPoint }
    var pointsHigh: CGFloat { CGFloat(drawing.height) / drawing.pixelsPerPoint }

    private func firstByte(column: Int, row: Int) -> Int { (row * drawing.width + column) * 4 }

    func color(atX x: CGFloat, y: CGFloat) -> [Int] {
        let column = min(max(Int(x * drawing.pixelsPerPoint), 0), drawing.width - 1)
        let row = min(max(Int(y * drawing.pixelsPerPoint), 0), drawing.height - 1)
        return (0..<3).map { Int(drawing.bytes[firstByte(column: column, row: row) + $0]) }
    }

    /// The box, in points, of the pixels in `region` that `matches` takes, or nil when none does.
    func boundingBox(of region: CGRect? = nil, where matches: (Int, Int, Int) -> Bool) -> CGRect? {
        let scale = drawing.pixelsPerPoint
        let columns = region.map { Int($0.minX * scale)..<min(Int($0.maxX * scale), drawing.width) } ?? 0..<drawing.width
        let rows = region.map { Int($0.minY * scale)..<min(Int($0.maxY * scale), drawing.height) } ?? 0..<drawing.height
        var box: (minColumn: Int, maxColumn: Int, minRow: Int, maxRow: Int)?
        drawing.bytes.withUnsafeBytes { bytes in
            for row in rows {
                for column in columns {
                    let first = firstByte(column: column, row: row)
                    guard matches(Int(bytes[first]), Int(bytes[first + 1]), Int(bytes[first + 2])) else { continue }
                    box = (min(box?.minColumn ?? column, column), max(box?.maxColumn ?? column, column), min(box?.minRow ?? row, row), max(box?.maxRow ?? row, row))
                }
            }
        }
        guard let box else { return nil }
        return CGRect(x: CGFloat(box.minColumn) / scale, y: CGFloat(box.minRow) / scale, width: CGFloat(box.maxColumn - box.minColumn + 1) / scale, height: CGFloat(box.maxRow - box.minRow + 1) / scale)
    }

    /// The first row, in points from the top, at or below `startY`, that has a pixel `matches` takes in `columns` (points).
    func firstRow(from startY: CGFloat = 0, inColumns columns: Range<CGFloat>, where matches: (Int, Int, Int) -> Bool) -> CGFloat? {
        let region = CGRect(x: columns.lowerBound, y: startY, width: columns.upperBound - columns.lowerBound, height: pointsHigh - startY)
        return boundingBox(of: region, where: matches)?.minY
    }

    /// The pixel in `region` farthest from `target`, as its channels.
    func pixelFarthest(from target: [Int], in region: CGRect) -> [Int] {
        let scale = drawing.pixelsPerPoint
        var farthest = (distance: -1, channels: [0, 0, 0])
        drawing.bytes.withUnsafeBytes { bytes in
            for row in Int(region.minY * scale)..<min(Int(region.maxY * scale), drawing.height) {
                for column in Int(region.minX * scale)..<min(Int(region.maxX * scale), drawing.width) {
                    let first = firstByte(column: column, row: row)
                    let channels = (0..<3).map { Int(bytes[first + $0]) }
                    let distance = zip(channels, target).map { abs($0 - $1) }.reduce(0, +)
                    if distance > farthest.distance { farthest = (distance, channels) }
                }
            }
        }
        return farthest.channels
    }

    /// The rows (points from the top) where at least 95% of the pixels across `columns` are within 4 of `color`, grouped so
    /// that rows next to each other count as one band, as the top row of each band.
    func bandsOfRows(near color: [Int], inColumns columns: Range<CGFloat>) -> [CGFloat] {
        let scale = drawing.pixelsPerPoint
        let firstColumn = Int(columns.lowerBound * scale), lastColumn = Int(columns.upperBound * scale)
        var bandTops: [CGFloat] = []
        var previousRowMatched = false
        drawing.bytes.withUnsafeBytes { bytes in
            for row in 0..<drawing.height {
                var matching = 0
                for column in firstColumn..<lastColumn {
                    let first = firstByte(column: column, row: row)
                    if (0..<3).allSatisfy({ abs(Int(bytes[first + $0]) - color[$0]) <= 4 }) { matching += 1 }
                }
                let rowMatches = Double(matching) >= 0.95 * Double(lastColumn - firstColumn)
                if rowMatches && !previousRowMatched { bandTops.append(CGFloat(row) / scale) }
                previousRowMatched = rowMatches
            }
        }
        return bandTops
    }
}

private func channels(of color: Color) -> [Int] {
    let srgbColor = NSColor(color).usingColorSpace(.sRGB) ?? .black
    return [srgbColor.redComponent, srgbColor.greenComponent, srgbColor.blueComponent].map { Int(($0 * 255).rounded()) }
}

private func contrast(_ foreground: [Int], _ background: [Int]) -> Double {
    func themeColor(_ channels: [Int]) -> ThemeRGBColor {
        ThemeRGBColor(red: Double(channels[0]) / 255, green: Double(channels[1]) / 255, blue: Double(channels[2]) / 255)
    }
    return themeColor(foreground).contrastRatio(against: themeColor(background))
}

private func isNear(_ target: [Int], within tolerance: Int) -> (Int, Int, Int) -> Bool {
    { red, green, blue in abs(red - target[0]) <= tolerance && abs(green - target[1]) <= tolerance && abs(blue - target[2]) <= tolerance }
}

private let darkPage = Color(hex: "#0B0C10")

private func dump(_ bitmap: NSBitmapImageRep, as name: String) throws {
    guard let dumpFolder = ProcessInfo.processInfo.environment["CLICKY_RENDER_DUMP_DIR"],
          let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
    try FileManager.default.createDirectory(atPath: dumpFolder, withIntermediateDirectories: true)
    try pngData.write(to: URL(fileURLWithPath: dumpFolder).appendingPathComponent("\(name).png"))
}

/// The Card in a window off every screen, on a page with a 30 point margin so its shadow shows.
@MainActor
private func renderTheCard(_ card: VideoQuizSummaryCardView, page: Color = darkPage, name: String) throws -> PaperRaster {
    let hostingView = NSHostingView(rootView: card.padding(30).background(page))
    let size = hostingView.fittingSize
    let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = hostingView
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    try dump(bitmap, as: name)
    return PaperRaster(drawing: try DrawingPixels(drawing: try #require(bitmap.cgImage), widthInPoints: size.width))
}

private func quizResult(_ question: String, at seconds: Double, _ outcome: StudyGuideQuizOutcome, explanation: String = "It explains the answer.") -> StudyGuideQuizResult {
    StudyGuideQuizResult(question: question, answerLabel: "turbine", explanation: explanation, askedAtSeconds: seconds, result: outcome)
}

private func studyGuideRecord(summary: String) throws -> StudyGuideRecord {
    StudyGuideRecord(
        pageHandle: "handle", pageURL: try #require(URL(string: "https://www.notion.so/guide")),
        guide: .object(["title": .string("How Jet Engines Work"), "summary": .string(summary)])
    )
}

// MARK: - The colors

@MainActor
struct PaperColorTests {
    private let paper = channels(of: DS.Colors.paperSurface)

    @Test func everyInkReadsAtFourPointFiveOrMoreOnPaper() {
        for (name, ink) in [("ink", DS.Colors.paperInk), ("secondary", DS.Colors.paperInkSecondary), ("tertiary", DS.Colors.paperInkTertiary)] {
            let ratio = contrast(channels(of: ink), paper)
            #expect(ratio >= 4.5, "\(name) ink reads at only \(ratio) on paper")
        }
    }

    @Test func aFilledButtonsLabelReadsAtFourPointFiveOrMoreOnTheInk() {
        #expect(contrast(channels(of: DS.Colors.paperInkButtonLabel), channels(of: DS.Colors.paperInk)) >= 4.5)
    }

    @Test func paperIsTheMocksWarmOffWhiteWithNearBlackInk() {
        #expect(paper == [0xF6, 0xF5, 0xF1])
        #expect(channels(of: DS.Colors.paperInk) == [0x15, 0x17, 0x1C])
    }

    @Test func clickyBlueIsNotBodyTextOnPaper() {
        // The reason paper keeps the accent for its one highlight: Clicky blue on paper is only 3.39 contrast.
        #expect(contrast(channels(of: DS.Colors.overlayCursorBlue), paper) < 4.5)
    }

    @Test func aPaleAccentNeedsAnEdgeOnPaperAndASaturatedOneDoesNot() {
        #expect(paperHighlightNeedsAnEdge(accent: Color(hex: "#F4F4F5")))
        #expect(!paperHighlightNeedsAnEdge(accent: Color(hex: "#3380FF")))
        #expect(!paperHighlightNeedsAnEdge(accent: Color(hex: "#A0457F")))
    }

    @Test func paperKeepsItsOwnCornerAndSerifSizes() {
        #expect(DS.CornerRadius.paper == 8)
        #expect(DS.PaperType.title.pointSize == 28)
        #expect(DS.PaperType.sectionLabel.isItalic)
        #expect(!DS.PaperType.title.isItalic)
    }
}

// MARK: - The colophon and the kicker

@MainActor
struct VideoRecapColophonTests {
    private let enUS = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents(year: 2026, month: 11, day: 28, hour: hour, minute: minute)
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test func theColophonNamesTheDayAndTheTimeTheCardWasMade() {
        #expect(videoRecapColophonText(madeAt: date(hour: 9, minute: 42), locale: enUS, timeZone: utc) == "Saved Nov 28 · 9:42 AM")
        #expect(videoRecapColophonText(madeAt: date(hour: 15, minute: 5), locale: enUS, timeZone: utc) == "Saved Nov 28 · 3:05 PM")
    }

    @Test func theColophonHasNoNarrowNoBreakSpace() {
        #expect(!videoRecapColophonText(madeAt: date(hour: 9, minute: 42), locale: enUS, timeZone: utc).contains("\u{202F}"))
    }

    @Test func theColophonFollowsTheTimeZone() throws {
        let eastern = try #require(TimeZone(identifier: "America/New_York"))
        #expect(videoRecapColophonText(madeAt: date(hour: 14, minute: 42), locale: enUS, timeZone: eastern) == "Saved Nov 28 · 9:42 AM")
    }

    @Test func theKickerFollowsTheTitle() throws {
        let quiz = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .missed)], studyGuideRecord: nil))
        #expect(quiz.title(when: .quizEnded) == "Quiz done")
        #expect(quiz.kicker(when: .quizEnded) == "Quiz recap")
        #expect(quiz.title(when: .videoEnded) == "Video done")
        #expect(quiz.kicker(when: .videoEnded) == "Video recap")
        let guideOnly = try #require(VideoRecap(quizResults: [], studyGuideRecord: try studyGuideRecord(summary: "It is about volcanoes.")))
        #expect(guideOnly.title(when: .quizEnded) == "Video done")
        #expect(guideOnly.kicker(when: .quizEnded) == "Video recap")
    }
}

// MARK: - The Card on paper

@MainActor
struct PaperRecapCardTests {
    private func fullRecap() throws -> VideoRecap {
        try #require(VideoRecap(
            quizResults: [
                quizResult("What does the turbine do?", at: 134, .missed),
                quizResult("What does the fan do?", at: 40, .gotIt, explanation: "The fan at the front moves the most air and makes most of the thrust."),
                quizResult("What squeezes the air?", at: 80, .gotIt, explanation: "The compressor squeezes the air so the fuel burns hotter in the combustor."),
                quizResult("Where does the air go?", at: 100, .gotIt, explanation: "A turbofan sends most of its air around the core, which makes it quieter."),
            ],
            studyGuideRecord: nil
        ))
    }

    private func card(_ recap: VideoRecap, accent: Color = Color(hex: "#3380FF"), moment: VideoRecapMoment = .quizEnded) -> VideoQuizSummaryCardView {
        VideoQuizSummaryCardView(recap: recap, moment: moment, accentColor: accent, goBackToTheMissedQuestion: { _ in }, openTheStudyGuide: {}, close: {})
    }

    @Test func theCardIsWarmPaperOnADarkPageAndThreeHundredSixtyPointsWide() throws {
        let raster = try renderTheCard(card(try fullRecap()), name: "recap-card-blue")
        #expect(raster.pointsWide == 30 + VideoQuizSummaryCardView.cardWidth + 30)
        #expect(raster.drawing.pixelsPerPoint >= 1)
        let pagePixel = raster.color(atX: 4, y: 4)
        #expect(isNear([0x0B, 0x0C, 0x10], within: 3)(pagePixel[0], pagePixel[1], pagePixel[2]), "page \(pagePixel)")
        // Just inside the Card's left and right edges, clear of its padding's content, the surface is paper.
        for x in [CGFloat(30 + 6), 30 + VideoQuizSummaryCardView.cardWidth - 6] {
            let surface = raster.color(atX: x, y: raster.pointsHigh / 2)
            #expect(isNear(channels(of: DS.Colors.paperSurface), within: 3)(surface[0], surface[1], surface[2]), "surface at \(x): \(surface)")
        }
        // The page ends at the Card's edge plus its shadow, so a long question wraps instead of widening it.
        let beyondTheCard = raster.color(atX: raster.pointsWide - 3, y: raster.pointsHigh / 2)
        #expect(beyondTheCard[0] < 0x30)
    }

    @Test func theCardPrintsInInkAndThePageStaysLightWhateverTheAppearance() throws {
        let raster = try renderTheCard(card(try fullRecap()), name: "recap-card-ink")
        let ink = channels(of: DS.Colors.paperInk)
        let cardBody = CGRect(x: 50, y: 30, width: VideoQuizSummaryCardView.cardWidth - 40, height: raster.pointsHigh - 60)
        // The darkest pixel of a card of ink on paper is the ink itself, whichever scheme the app is in.
        let darkest = raster.pixelFarthest(from: channels(of: DS.Colors.paperSurface), in: cardBody)
        #expect(isNear(ink, within: 14)(darkest[0], darkest[1], darkest[2]), "darkest pixel \(darkest)")
        #expect(contrast(darkest, channels(of: DS.Colors.paperSurface)) >= 4.5)
    }

    @Test func theScoreSitsOnOneFlatHighlightInTheAccentWithItsComputedInk() throws {
        // Magenta is on nothing else on paper, so every magenta pixel is the highlight.
        let magenta = Color(hex: "#FF00FF")
        let raster = try renderTheCard(card(try fullRecap(), accent: magenta), name: "recap-card-magenta")
        let highlight = try #require(raster.boundingBox(where: isNear([255, 0, 255], within: 6)))
        // One highlight behind "3 of 4 right", near the top of the Card, and no accent anywhere else.
        #expect(highlight.width < 130 && highlight.height < 24, "the accent spans \(highlight)")
        #expect(highlight.minY < 140)
        let expectedInk = channels(of: magenta.inkOnThisFill)
        let lettersInTheHighlight = raster.pixelFarthest(from: [255, 0, 255], in: highlight)
        #expect(isNear(expectedInk, within: 50)(lettersInTheHighlight[0], lettersInTheHighlight[1], lettersInTheHighlight[2]), "letters \(lettersInTheHighlight), expected ink \(expectedInk)")
        #expect(contrast(expectedInk, [255, 0, 255]) >= 4.5)
    }

    @Test func aDarkAccentTakesWhiteLettersOnItsHighlight() throws {
        let shira = Color(hex: "#A0457F")
        let raster = try renderTheCard(card(try fullRecap(), accent: shira), name: "recap-card-shira")
        let highlight = try #require(raster.boundingBox(where: isNear([0xA0, 0x45, 0x7F], within: 6)))
        let letters = raster.pixelFarthest(from: [0xA0, 0x45, 0x7F], in: highlight)
        #expect(letters.allSatisfy { $0 > 235 }, "letters \(letters)")
    }

    @Test func aPaleAccentHighlightShowsOnPaperBecauseItHasAHairlineEdge() throws {
        let pale = Color(hex: "#F4F4F5")
        let raster = try renderTheCard(card(try fullRecap(), accent: pale), name: "recap-card-pale")
        // The score's row is below the title: find the edge as the first row under the title with a pixel clearly darker than paper
        // that is not text, by drawing the highlight alone on paper, where its edge is the only thing around it.
        let highlightAlone = ImageRenderer(content: PaperHighlight(text: "3 of 4 right", accent: pale).padding(10).background(DS.Colors.paperSurface))
        highlightAlone.scale = 2
        let aloneRaster = PaperRaster(drawing: try DrawingPixels(drawing: try #require(highlightAlone.cgImage), widthInPoints: CGFloat(try #require(highlightAlone.cgImage).width) / 2))
        // The fill is within a few levels of paper, so only the edge sets the highlight apart.
        let paper = channels(of: DS.Colors.paperSurface)
        let insideTheFill = aloneRaster.color(atX: 12, y: aloneRaster.pointsHigh / 2)
        #expect(zip(insideTheFill, paper).allSatisfy { abs($0 - $1) <= 8 }, "fill \(insideTheFill)")
        let edge = aloneRaster.color(atX: 10.25, y: aloneRaster.pointsHigh / 2)
        #expect(contrast(edge, paper) >= 1.5, "edge \(edge)")
        #expect(raster.pointsWide > 0)
    }

    @Test func aSaturatedAccentHighlightDrawsNoEdge() throws {
        let edgeless = ImageRenderer(content: PaperHighlight(text: "3 of 4 right", accent: Color(hex: "#3380FF")).padding(10).background(DS.Colors.paperSurface))
        edgeless.scale = 2
        let raster = PaperRaster(drawing: try DrawingPixels(drawing: try #require(edgeless.cgImage), widthInPoints: CGFloat(try #require(edgeless.cgImage).width) / 2))
        // The first pixel of the highlight is already the accent's blue, with no darker ring before it.
        let firstPixel = raster.color(atX: 10.25, y: raster.pointsHigh / 2)
        #expect(isNear([0x33, 0x80, 0xFF], within: 14)(firstPixel[0], firstPixel[1], firstPixel[2]), "first pixel \(firstPixel)")
    }

    @Test func eachSectionOpensWithAHairlineRule() throws {
        let raster = try renderTheCard(card(try fullRecap()), name: "recap-card-rules")
        let paper = channels(of: DS.Colors.paperSurface)
        let ink = channels(of: DS.Colors.paperInk)
        // The hairline is the ink at 13% over paper.
        let hairline = (0..<3).map { Int((Double(paper[$0]) * 0.87 + Double(ink[$0]) * 0.13).rounded()) }
        // Review these first, What you learned, and the foot.
        let rules = raster.bandsOfRows(near: hairline, inColumns: 52..<350)
        #expect(rules.count == 3, "rules at \(rules)")
    }

    @Test func aQuizWithNoLearnedLinesOrMissesHasOnlyTheFootRule() throws {
        let allRight = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .gotIt, explanation: "")], studyGuideRecord: nil))
        let raster = try renderTheCard(card(allRight), name: "recap-card-all-right")
        let paper = channels(of: DS.Colors.paperSurface)
        let ink = channels(of: DS.Colors.paperInk)
        let hairline = (0..<3).map { Int((Double(paper[$0]) * 0.87 + Double(ink[$0]) * 0.13).rounded()) }
        #expect(raster.bandsOfRows(near: hairline, inColumns: 52..<350).count == 1)
    }

    @Test func theMissedQuestionsShowAboveWhatTheLearnerLearned() throws {
        let raster = try renderTheCard(card(try fullRecap()), name: "recap-card-order")
        let paper = channels(of: DS.Colors.paperSurface)
        let ink = channels(of: DS.Colors.paperInk)
        let hairline = (0..<3).map { Int((Double(paper[$0]) * 0.87 + Double(ink[$0]) * 0.13).rounded()) }
        let rules = raster.bandsOfRows(near: hairline, inColumns: 52..<350)
        let firstRule = try #require(rules.first)
        let secondRule = try #require(rules.dropFirst().first)
        // The timestamp is secondary ink in a column at the right, which only a missed question has, and a numeral is tertiary ink
        // at the left, which only a learned line has. The first section holds the missed question and the second the numerals.
        let timestampRow = try #require(raster.firstRow(from: firstRule, inColumns: 338..<372, where: isNear(channels(of: DS.Colors.paperInkSecondary), within: 10)))
        let numeralRow = try #require(raster.firstRow(from: secondRule, inColumns: 50..<60, where: isNear(channels(of: DS.Colors.paperInkTertiary), within: 10)))
        #expect(firstRule < timestampRow && timestampRow < secondRule)
        #expect(timestampRow < numeralRow)
    }

    @Test func theColophonShowsTheTimeTheCardWasMade() throws {
        // The text itself is pinned in `VideoRecapColophonTests`. Here the card carries the date it was given into its foot.
        let recap = try fullRecap()
        let madeAt = Date(timeIntervalSince1970: 1_795_000_000)
        var madeCard = card(recap)
        madeCard.madeAt = madeAt
        #expect(madeCard.madeAt == madeAt)
        #expect(videoRecapColophonText(madeAt: madeAt).hasPrefix("Saved "))
    }

    @Test func theStudyGuideButtonIsFilledWithInkAndCloseIsOutlinedInAHairline() throws {
        let guide = try studyGuideRecord(summary: "It is about volcanoes.")
        let recap = try #require(VideoRecap(quizResults: [quizResult("A?", at: 10, .missed)], studyGuideRecord: guide))
        let raster = try renderTheCard(card(recap), name: "recap-card-buttons")
        let ink = channels(of: DS.Colors.paperInk)
        // The filled button is the only big block of ink on the Card, in the bottom right, 32 points tall.
        let inkBlock = try #require(raster.boundingBox(of: CGRect(x: 200, y: raster.pointsHigh - 90, width: 190, height: 80), where: isNear(ink, within: 3)))
        #expect(inkBlock.height >= 30 && inkBlock.height <= 34, "the ink button is \(inkBlock)")
        #expect(inkBlock.maxX > 30 + VideoQuizSummaryCardView.cardWidth - 25)
        // The label on it is paper white, and nothing on it is the accent.
        let labelPixel = raster.pixelFarthest(from: ink, in: inkBlock)
        #expect(contrast(labelPixel, ink) >= 4.5, "label \(labelPixel)")
    }

    @Test func aRecapWithNoStudyGuideHasOnlyAnOutlinedClose() throws {
        let recap = try fullRecap()
        #expect(recap.studyGuideURL == nil)
        let raster = try renderTheCard(card(recap), name: "recap-card-no-guide")
        let ink = channels(of: DS.Colors.paperInk)
        let bigInkBlock = raster.boundingBox(of: CGRect(x: 200, y: raster.pointsHigh - 90, width: 190, height: 80)) { red, green, blue in
            isNear(ink, within: 3)(red, green, blue)
        }
        // With no study guide there is no filled button, so no run of ink wider than a letter sits in the foot.
        #expect(bigInkBlock == nil || bigInkBlock!.height < 20)
    }

    @Test func aLongListOfMissedQuestionsStillFitsTheCardsWidth() throws {
        let results = (1...7).map { quizResult("Question number \($0) with enough words to wrap around to a second line of text?", at: Double($0) * 20, .missed) }
        let recap = try #require(VideoRecap(quizResults: results, studyGuideRecord: nil))
        #expect(recap.summary?.missedQuestions.count == 7)
        let raster = try renderTheCard(card(recap), name: "recap-card-scrolling")
        #expect(raster.pointsWide == 30 + VideoQuizSummaryCardView.cardWidth + 30)
        // The list scrolls inside 300 points, so the Card stays under the height of a screen.
        #expect(raster.pointsHigh < 30 + 640 + 30)
    }

    @Test func aVideoRecapWithOnlyAGuideHasAKickerAndNoScore() throws {
        let recap = try #require(VideoRecap(quizResults: [], studyGuideRecord: try studyGuideRecord(summary: "It is about volcanoes.")))
        #expect(recap.summary == nil)
        let magenta = Color(hex: "#FF00FF")
        let raster = try renderTheCard(card(recap, accent: magenta, moment: .videoEnded), name: "recap-card-video-only")
        // No score, so no highlight and no accent anywhere.
        #expect(raster.boundingBox(where: isNear([255, 0, 255], within: 6)) == nil)
    }
}

// MARK: - The Save photo receipt

@MainActor
struct PaperPhotoReceiptTests {
    private let paper = channels(of: DS.Colors.paperSurface)

    private func thumbnail(_ color: [Int]) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 136, height: 104, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255, blue: CGFloat(color[2]) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 136, height: 104))
        return try #require(context.makeImage())
    }

    private func render(locationLine: String, accent: Color = Color(hex: "#3380FF"), name: String) throws -> PaperRaster {
        let receipt = PaperPhotoReceipt(thumbnail: try thumbnail([0xCD, 0xBF, 0xAE]), locationLine: locationLine, accent: accent)
        let renderer = ImageRenderer(content: receipt.padding(EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)).background(darkPage))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        try dump(NSBitmapImageRep(cgImage: image), as: name)
        return PaperRaster(drawing: try DrawingPixels(drawing: image, widthInPoints: CGFloat(image.width) / 2))
    }

    @Test func theReceiptIsAPaperCardWithTheThumbnailAndAnAccentCheck() throws {
        let raster = try render(locationLine: "Clicky folder · Clicky try-on KIVIK sofa 2026-11-28 09.14.03.jpg", name: "photo-receipt")
        // Between the thumbnail and the text, and at the right end, the receipt is paper.
        let gap = raster.color(atX: 20 + 8 + 34 + 4, y: 20 + 10)
        #expect(isNear(paper, within: 3)(gap[0], gap[1], gap[2]), "gap \(gap)")
        // The thumbnail's color is in the tile at the left, and the accent is on the check disc.
        let tile = raster.color(atX: 20 + 8 + 17, y: 20 + 8 + 13)
        #expect(isNear([0xCD, 0xBF, 0xAE], within: 6)(tile[0], tile[1], tile[2]), "tile \(tile)")
        let checkDisc = try #require(raster.boundingBox(where: isNear([0x33, 0x80, 0xFF], within: 6)))
        #expect(checkDisc.width >= 15 && checkDisc.width <= 17 && checkDisc.height >= 15 && checkDisc.height <= 17, "the accent spans \(checkDisc)")
        // The ink of the check is the near black that reads on Clicky blue.
        let checkMark = raster.pixelFarthest(from: [0x33, 0x80, 0xFF], in: checkDisc)
        #expect(contrast(checkMark, [0x33, 0x80, 0xFF]) >= 4.5, "check \(checkMark)")
    }

    @Test func aLongFileNameIsCutAtTheReceiptsMaximumWidth() throws {
        let raster = try render(locationLine: "Clicky folder · " + String(repeating: "A very long item title ", count: 8) + "2026-11-28 09.14.03.jpg", name: "photo-receipt-long")
        let receiptBox = try #require(raster.boundingBox(where: isNear(paper, within: 2)))
        #expect(receiptBox.width <= PaperPhotoReceipt.maxWidth + 1, "the receipt is \(receiptBox.width) points wide")
        #expect(receiptBox.width >= PaperPhotoReceipt.maxWidth - 2)
        #expect(receiptBox.height <= PaperPhotoReceipt.greatestHeight)
    }

    @Test func aShortFileNameLetsTheReceiptFitItsText() throws {
        let raster = try render(locationLine: "Clicky folder · a.jpg", name: "photo-receipt-short")
        let receiptBox = try #require(raster.boundingBox(where: isNear(paper, within: 2)))
        #expect(receiptBox.width < PaperPhotoReceipt.maxWidth - 40, "the receipt is \(receiptBox.width) points wide")
    }

    @Test func aPaleAccentCheckKeepsItsInkAndItsDiscStaysInsideTheReceipt() throws {
        let raster = try render(locationLine: "Clicky folder · a.jpg", accent: Color(hex: "#F4F4F5"), name: "photo-receipt-pale")
        let receiptBox = try #require(raster.boundingBox(where: isNear(paper, within: 2)))
        #expect(receiptBox.width > 100)
    }

    @Test func theReceiptHasTheCalloutsTailAtItsBottomLeft() throws {
        let raster = try render(locationLine: "Clicky folder · a.jpg", name: "photo-receipt-tail")
        let receiptBox = try #require(raster.boundingBox(where: isNear(paper, within: 2)))
        // The tail reaches below the body, so its lowest paper pixel is near the left, and the right end stops higher.
        let belowTheBody = CGRect(x: receiptBox.minX, y: receiptBox.maxY - 8, width: receiptBox.width, height: 8)
        let tail = try #require(raster.boundingBox(of: belowTheBody, where: isNear(paper, within: 2)))
        #expect(tail.maxX < receiptBox.minX + 45, "the tail spans \(tail)")
    }

    @Test func theReceiptsChipUsesTheThemeAccentAndItsPanelIsTallEnough() throws {
        let themeAccent = Color(hex: "#A0457F")
        #expect(VoiceToolCallChipSender.photoReceipt.accent(themeAccent: themeAccent) == themeAccent)
        #expect(!VoiceToolCallChipSender.photoReceipt.shakesOnAppearing)
        let receipt = NSHostingView(rootView: PaperPhotoReceipt(thumbnail: nil, locationLine: "Clicky folder · " + String(repeating: "x", count: 200), accent: themeAccent))
        #expect(receipt.fittingSize.height <= PaperPhotoReceipt.greatestHeight)
        #expect(receipt.fittingSize.width <= PaperPhotoReceipt.maxWidth + 0.5)
        #expect(VoiceToolCallChip.panelSize.height >= PaperPhotoReceipt.greatestHeight + 2 * tetherCalloutPanelMargin + VoiceToolCallChip.stackStepHeight)
        // The receipt and a failure never share an identity, so a failure after a save is a new chip and not an update.
        #expect(VoiceToolCallChipIdentity(chipText: roomArtPhotoSavedChip, sender: .photoReceipt) != VoiceToolCallChipIdentity(chipText: roomArtPhotoSavedChip, sender: .voiceToolCall))
    }
}

// MARK: - The receipt's thumbnail

@MainActor
struct RoomArtPhotoReceiptThumbnailTests {
    private func photo(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    private func color(of image: CGImage, x: Int, y: Int) throws -> [Int] {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return pixel.prefix(3).map(Int.init)
    }

    @Test func aWideFrameFillsTheTileAndLosesItsSidesEvenly() throws {
        // Red on the left third, green in the middle, blue on the right third, in a 3:1 frame.
        let wide = try photo(width: 300, height: 100) { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 200, y: 0, width: 100, height: 100))
        }
        let thumbnail = try #require(roomArtPhotoReceiptThumbnail(of: wide))
        #expect(thumbnail.width == 136 && thumbnail.height == 104)
        // The tile is 1.31:1, so the frame is scaled to its height and cut evenly at both sides, which
        // shows the middle 130 source pixels: a sliver of red at the left, green between, and a sliver of blue at the right.
        let middle = try color(of: thumbnail, x: 68, y: 52)
        #expect(middle[1] > 200 && middle[0] < 40 && middle[2] < 40, "middle \(middle)")
        let leftEdge = try color(of: thumbnail, x: 1, y: 52)
        #expect(leftEdge[0] > 200 && leftEdge[1] < 40, "left edge \(leftEdge)")
        let rightEdge = try color(of: thumbnail, x: 134, y: 52)
        #expect(rightEdge[2] > 200 && rightEdge[1] < 40, "right edge \(rightEdge)")
    }

    @Test func aTallFrameFillsTheTile() throws {
        let tall = try photo(width: 100, height: 300) { context in
            context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 300))
        }
        let thumbnail = try #require(roomArtPhotoReceiptThumbnail(of: tall))
        #expect(thumbnail.width == 136 && thumbnail.height == 104)
        for (x, y) in [(0, 0), (135, 0), (0, 103), (135, 103)] {
            let corner = try color(of: thumbnail, x: x, y: y)
            #expect(corner[2] > 200, "corner \(x),\(y): \(corner)")
        }
    }
}
