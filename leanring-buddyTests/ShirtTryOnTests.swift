//
//  ShirtTryOnTests.swift
//  leanring-buddyTests
//
//  The shirt try-on's parts: the torso from pose joints, where the learner must stand, the garment's own geometry, the
//  per-frame analysis, the pose smoothing, and the renderer on a generated frame. None of it needs Vision, so it runs in
//  CI's background session. The real photos are in ShirtTryOnPhotoCheckTests.swift.
//

import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Clicky

// MARK: - Generated images

/// An RGBA canvas drawn in top left pixels, first row at the top, so a test says where things are the way the code does.
struct ShirtTestCanvas {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, color: (UInt8, UInt8, UInt8)) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 255, count: width * height * 4)
        fill(columns: 0..<width, rows: 0..<height, color: color)
    }

    mutating func fill(columns: Range<Int>, rows: Range<Int>, color: (UInt8, UInt8, UInt8)) {
        for row in rows where row >= 0 && row < height {
            for column in columns where column >= 0 && column < width {
                let index = (row * width + column) * 4
                bytes[index] = color.0
                bytes[index + 1] = color.1
                bytes[index + 2] = color.2
            }
        }
    }

    mutating func fillCircle(centerColumn: Int, centerRow: Int, radius: Int, color: (UInt8, UInt8, UInt8)) {
        for row in (centerRow - radius)...(centerRow + radius) {
            for column in (centerColumn - radius)...(centerColumn + radius) where (column - centerColumn) * (column - centerColumn) + (row - centerRow) * (row - centerRow) <= radius * radius {
                fill(columns: column..<(column + 1), rows: row..<(row + 1), color: color)
            }
        }
    }

    var ciImage: CIImage {
        CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    var cgImage: CGImage {
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func pixel(column: Int, row: Int) -> (red: Int, green: Int, blue: Int) {
        let index = (row * width + column) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }
}

/// A person mask as a Core Image image whose values Core Image reads as they are.
private func personMaskImage(width: Int, height: Int, personColumns: Range<Int>, personRows: Range<Int>) -> CIImage {
    var canvas = ShirtTestCanvas(width: width, height: height, color: (0, 0, 0))
    canvas.fill(columns: personColumns, rows: personRows, color: (255, 255, 255))
    return CIImage(bitmapData: Data(canvas.bytes), bytesPerRow: width * 4, size: CGSize(width: width, height: height), format: .RGBA8, colorSpace: nil)
}

private func renderedCanvas(of image: CIImage, context: CIContext = CIContext()) -> ShirtTestCanvas {
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var canvas = ShirtTestCanvas(width: width, height: height, color: (0, 0, 0))
    canvas.bytes.withUnsafeMutableBytes { buffer in
        context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
    return canvas
}

/// A T-shirt cutout in a 400 by 500 photo: sleeves across the top 150 rows, a torso in columns 100 to 299, and a neck hole
/// below a thin back collar. The torso is red with a green band from 25 to 35 percent of the height.
private func tShirtPhotoAndMask(withNeckHole: Bool = true) -> (photo: CGImage, mask: ShirtCutoutMask) {
    var canvas = ShirtTestCanvas(width: 400, height: 500, color: (255, 255, 255))
    var maskPixels = [UInt8](repeating: 0, count: 400 * 500)
    func addGarment(columns: Range<Int>, rows: Range<Int>) {
        canvas.fill(columns: columns, rows: rows, color: (200, 40, 40))
        for row in rows { for column in columns { maskPixels[row * 400 + column] = 255 } }
    }
    addGarment(columns: 0..<400, rows: 0..<150)
    addGarment(columns: 100..<300, rows: 150..<500)
    if withNeckHole {
        canvas.fill(columns: 170..<230, rows: 8..<60, color: (255, 255, 255))
        for row in 8..<60 { for column in 170..<230 { maskPixels[row * 400 + column] = 0 } }
    }
    canvas.fill(columns: 100..<300, rows: 125..<175, color: (30, 200, 60))
    return (canvas.cgImage, ShirtCutoutMask(width: 400, height: 500, pixels: maskPixels))
}

private func readings(leftShoulder: (Double, Double, Float), rightShoulder: (Double, Double, Float), leftHip: (Double, Double, Float)? = nil, rightHip: (Double, Double, Float)? = nil) -> ShirtBodyJointReadings {
    func reading(_ joint: (Double, Double, Float)?) -> ShirtJointReading? {
        joint.map { ShirtJointReading(visionPoint: CGPoint(x: $0.0, y: $0.1), confidence: $0.2) }
    }
    return ShirtBodyJointReadings(personLeftShoulder: reading(leftShoulder), personRightShoulder: reading(rightShoulder), personLeftHip: reading(leftHip), personRightHip: reading(rightHip))
}

private let frameSize = CGSize(width: 1000, height: 500)

/// Whether two points are the same to a thousandth of a pixel, since Vision's 0 to 1 points and the shoulder line's 10 percent
/// do not land on exact binary fractions.
private func isNear(_ first: CGPoint, _ second: CGPoint) -> Bool {
    abs(first.x - second.x) < 0.001 && abs(first.y - second.y) < 0.001
}

private func torsoAt(shoulderY: Double, shoulderWidth: Double, hipsEstimated: Bool = true, shouldersSeen: Bool = true) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: CGPoint(x: 500 - shoulderWidth / 2, y: shoulderY), imageRightShoulder: CGPoint(x: 500 + shoulderWidth / 2, y: shoulderY),
        imageLeftHip: CGPoint(x: 500 - shoulderWidth / 2, y: shoulderY + 1.45 * shoulderWidth), imageRightHip: CGPoint(x: 500 + shoulderWidth / 2, y: shoulderY + 1.45 * shoulderWidth),
        hipsWereEstimated: hipsEstimated, shouldersAreSeen: shouldersSeen
    )
}

// MARK: - The torso

struct BodyTorsoTests {
    @Test func theTorsoTakesPixelsFromVisionPointsWithYFlippedAndImageLeftFirst() throws {
        // The person's left shoulder is image right here, as it is in an unmirrored camera.
        let torso = try #require(BodyTorso(
            readings: readings(leftShoulder: (0.65, 0.7, 0.9), rightShoulder: (0.35, 0.7, 0.9), leftHip: (0.62, 0.3, 0.9), rightHip: (0.38, 0.3, 0.9)), frameSize: frameSize))
        #expect(isNear(torso.imageLeftShoulder, CGPoint(x: 350, y: 150)))
        #expect(isNear(torso.imageRightShoulder, CGPoint(x: 650, y: 150)))
        #expect(isNear(torso.imageLeftHip, CGPoint(x: 380, y: 350)))
        #expect(isNear(torso.imageRightHip, CGPoint(x: 620, y: 350)))
        #expect(!torso.hipsWereEstimated)
        #expect(torso.shouldersAreSeen)

        // A mirrored camera swaps the person's sides, and the torso is the same.
        let mirrored = try #require(BodyTorso(
            readings: readings(leftShoulder: (0.35, 0.7, 0.9), rightShoulder: (0.65, 0.7, 0.9), leftHip: (0.38, 0.3, 0.9), rightHip: (0.62, 0.3, 0.9)), frameSize: frameSize))
        #expect(isNear(mirrored.imageLeftShoulder, torso.imageLeftShoulder) && isNear(mirrored.imageRightHip, torso.imageRightHip))
    }

    @Test func hipsThatAreNotSeenAreEstimatedFromTheShouldersAsTheSpikeDoes() throws {
        // Shoulders 300 pixels apart on a level line: the torso is 1.45 * 300 = 435 long, and each hip sits 8 percent of the
        // span toward the center.
        let noHips = try #require(BodyTorso(readings: readings(leftShoulder: (0.65, 0.7, 0.9), rightShoulder: (0.35, 0.7, 0.9)), frameSize: frameSize))
        #expect(noHips.hipsWereEstimated)
        #expect(isNear(noHips.imageLeftHip, CGPoint(x: 374, y: 585)))
        #expect(isNear(noHips.imageRightHip, CGPoint(x: 626, y: 585)))

        // A hip under the confidence floor is not seen, and neither is one the pose guessed outside the frame.
        let weakHip = try #require(BodyTorso(
            readings: readings(leftShoulder: (0.65, 0.7, 0.9), rightShoulder: (0.35, 0.7, 0.9), leftHip: (0.62, 0.3, 0.9), rightHip: (0.38, 0.3, 0.1)), frameSize: frameSize))
        #expect(weakHip.hipsWereEstimated)
        let hipBelowTheFrame = try #require(BodyTorso(
            readings: readings(leftShoulder: (0.65, 0.7, 0.9), rightShoulder: (0.35, 0.7, 0.9), leftHip: (0.62, -0.2, 0.9), rightHip: (0.38, -0.2, 0.9)), frameSize: frameSize))
        #expect(hipBelowTheFrame.hipsWereEstimated)
    }

    @Test func theEstimatedHipsFollowATiltedShoulderLineDownTheBody() throws {
        // The right shoulder is higher: the body's down direction is across the shoulder line, still toward the bottom.
        let tilted = try #require(BodyTorso(readings: readings(leftShoulder: (0.65, 0.72, 0.9), rightShoulder: (0.35, 0.68, 0.9)), frameSize: frameSize))
        #expect(tilted.imageLeftHip.y > tilted.imageLeftShoulder.y + 300)
        let torsoLength = hypot(tilted.hipMidpoint.x - tilted.shoulderMidpoint.x, tilted.hipMidpoint.y - tilted.shoulderMidpoint.y)
        #expect(abs(torsoLength - 1.45 * tilted.shoulderWidth) < 0.05 * tilted.shoulderWidth)
    }

    @Test func shouldersUnderTheConfidenceFloorOrOutsideTheFrameAreNotSeen() throws {
        let weakShoulder = try #require(BodyTorso(readings: readings(leftShoulder: (0.65, 0.7, 0.9), rightShoulder: (0.35, 0.7, 0.2)), frameSize: frameSize))
        #expect(!weakShoulder.shouldersAreSeen)
        let shoulderOutsideTheFrame = try #require(BodyTorso(readings: readings(leftShoulder: (1.1, 0.7, 0.9), rightShoulder: (0.5, 0.7, 0.9)), frameSize: frameSize))
        #expect(!shoulderOutsideTheFrame.shouldersAreSeen)
    }

    @Test func aMissingShoulderOrShouldersOnTopOfEachOtherGiveNoTorso() {
        #expect(BodyTorso(readings: ShirtBodyJointReadings(personLeftShoulder: ShirtJointReading(visionPoint: CGPoint(x: 0.5, y: 0.5), confidence: 0.9), personRightShoulder: nil, personLeftHip: nil, personRightHip: nil), frameSize: frameSize) == nil)
        #expect(BodyTorso(readings: readings(leftShoulder: (0.5, 0.5, 0.9), rightShoulder: (0.5, 0.5, 0.9)), frameSize: frameSize) == nil)
    }

    @Test func movingTheHipsKeepsTheShouldersAndTheDirectionOfTheBody() {
        let torso = torsoAt(shoulderY: 100, shoulderWidth: 200)
        let shorter = torso.withTorsoLength(250)
        #expect(shorter.imageLeftShoulder == torso.imageLeftShoulder)
        #expect(abs(shorter.hipMidpoint.y - 350) < 0.001)
        #expect(abs(shorter.hipMidpoint.x - torso.hipMidpoint.x) < 0.001)
    }
}

// MARK: - Where the learner stands

struct ShirtFramingTests {
    @Test func nobodyInViewIsNoPersonAndGetsAPlainCoachingLine() {
        let framing = ShirtFraming.assess(torso: nil, frameSize: frameSize)
        #expect(framing == .noPerson)
        #expect(framing.coachingLine == "I can't see you yet. Step in front of the camera.")
    }

    @Test func shouldersThatAreNotBothSeenSayToStandBack() {
        let framing = ShirtFraming.assess(torso: torsoAt(shoulderY: 150, shoulderWidth: 300, shouldersSeen: false), frameSize: frameSize)
        #expect(framing == .standBack(.shouldersAreNotBothSeen))
        #expect(framing.coachingLine == "Stand back so I can see your shoulders and chest.")
    }

    @Test func shouldersTooWideForTheFrameSayToStandBack() {
        // The limit is 62 percent of the 1000 pixel frame: 620 pixels. The chest is in view at this height.
        #expect(ShirtFraming.assess(torso: torsoAt(shoulderY: 50, shoulderWidth: 640), frameSize: frameSize) == .standBack(.tooCloseForTheChest))
        let justInside = torsoAt(shoulderY: 50, shoulderWidth: 600)
        #expect(ShirtFraming.assess(torso: justInside, frameSize: frameSize) == .ready(justInside))
    }

    @Test func aChestBelowTheBottomOfTheFrameSaysToStandBack() {
        // The chest reaches 0.6 shoulder widths below the shoulder line: 300 * 0.6 = 180, so a shoulder line at y 330 puts
        // it at 510 in a 500 pixel frame.
        #expect(ShirtFraming.assess(torso: torsoAt(shoulderY: 330, shoulderWidth: 300), frameSize: frameSize) == .standBack(.tooCloseForTheChest))
        let chestJustInside = torsoAt(shoulderY: 310, shoulderWidth: 300)
        #expect(ShirtFraming.assess(torso: chestJustInside, frameSize: frameSize) == .ready(chestJustInside))
    }

    @Test func aWellFramedTorsoIsReadyWithNoCoachingLine() {
        let torso = torsoAt(shoulderY: 150, shoulderWidth: 300)
        let framing = ShirtFraming.assess(torso: torso, frameSize: frameSize)
        #expect(framing == .ready(torso))
        #expect(framing.coachingLine == nil)
    }
}

// MARK: - Pose smoothing

struct ShirtTorsoSmootherTests {
    @Test func theFirstResultIsUsedAsItIs() {
        var smoother = ShirtTorsoSmoother()
        let torso = torsoAt(shoulderY: 150, shoulderWidth: 300)
        #expect(smoother.advance(toward: torso, at: 0) == torso)
    }

    @Test func eachStepMovesPartOfTheWayAndConvergesOnTheBody() throws {
        var smoother = ShirtTorsoSmoother()
        _ = smoother.advance(toward: torsoAt(shoulderY: 150, shoulderWidth: 300), at: 0)
        let target = torsoAt(shoulderY: 180, shoulderWidth: 300)
        let afterOneFrameResult = smoother.advance(toward: target, at: 0.033)
        let afterOneFrame = try #require(afterOneFrameResult)
        // 33 ms of a 60 ms time constant covers 1 - e^(-0.55) = 42 percent of the 30 pixels.
        #expect(afterOneFrame.imageLeftShoulder.y > 150 + 10 && afterOneFrame.imageLeftShoulder.y < 150 + 15)
        var time = 0.033
        var latest = afterOneFrame
        for _ in 0..<30 {
            time += 0.033
            let stepResult = smoother.advance(toward: target, at: time)
            latest = try #require(stepResult)
        }
        #expect(abs(latest.imageLeftShoulder.y - 180) < 0.5)
    }

    @Test func aJumpOfMoreThanHalfAShoulderWidthSnapsToTheNewBody() {
        var smoother = ShirtTorsoSmoother()
        _ = smoother.advance(toward: torsoAt(shoulderY: 150, shoulderWidth: 300), at: 0)
        let farAway = torsoAt(shoulderY: 150, shoulderWidth: 300)
        let moved = BodyTorso(
            imageLeftShoulder: CGPoint(x: farAway.imageLeftShoulder.x + 200, y: 150), imageRightShoulder: CGPoint(x: farAway.imageRightShoulder.x + 200, y: 150),
            imageLeftHip: CGPoint(x: farAway.imageLeftHip.x + 200, y: farAway.imageLeftHip.y), imageRightHip: CGPoint(x: farAway.imageRightHip.x + 200, y: farAway.imageRightHip.y),
            hipsWereEstimated: true, shouldersAreSeen: true
        )
        #expect(smoother.advance(toward: moved, at: 0.033) == moved)
    }

    @Test func aMissedRunKeepsTheTorsoAndALongAbsenceLosesIt() {
        var smoother = ShirtTorsoSmoother()
        let torso = torsoAt(shoulderY: 150, shoulderWidth: 300)
        _ = smoother.advance(toward: torso, at: 0)
        #expect(smoother.advance(toward: nil, at: 0.2) == torso)
        #expect(smoother.advance(toward: nil, at: 0.45) == nil)
    }
}

// MARK: - The garment

struct ShirtGarmentTests {
    @Test func theTorsoCornersAndTheNeckComeFromTheCutoutByTheSpikesRules() throws {
        let (_, mask) = tShirtPhotoAndMask()
        let measurements = try #require(ShirtGarmentMeasurements(mask: mask))
        // Rows 0 to 499, so the height is 499. At 60 percent, row 299, only the torso (columns 100 to 299) is garment. The
        // shoulder line is 10 percent down: row 49.9.
        #expect(isNear(measurements.torsoCorners.topLeft, CGPoint(x: 100, y: 49.9)))
        #expect(isNear(measurements.torsoCorners.topRight, CGPoint(x: 299, y: 49.9)))
        #expect(measurements.torsoCorners.bottomRight == CGPoint(x: 299, y: 499))
        #expect(measurements.torsoCorners.bottomLeft == CGPoint(x: 100, y: 499))
        // Down the center column 199: back collar at row 0, the hole from row 8, the front of the shirt from row 60.
        #expect(measurements.frontNeckWasFound)
        #expect(measurements.frontNeckPoint == CGPoint(x: 199, y: 60))
    }

    @Test func aCutoutWithNoNeckHoleFallsBackToTheShoulderLine() throws {
        let (_, mask) = tShirtPhotoAndMask(withNeckHole: false)
        let measurements = try #require(ShirtGarmentMeasurements(mask: mask))
        #expect(!measurements.frontNeckWasFound)
        #expect(isNear(measurements.frontNeckPoint, CGPoint(x: 199, y: 49.9)))
    }

    @Test func aGapLowerThanANeckIsAPrintNotANeck() throws {
        // A hole starting at 40 percent of the height is not a neck.
        var (_, mask) = tShirtPhotoAndMask(withNeckHole: false)
        var pixels = mask.pixels
        for row in 200..<230 { for column in 170..<230 { pixels[row * 400 + column] = 0 } }
        mask = ShirtCutoutMask(width: 400, height: 500, pixels: pixels)
        let measurements = try #require(ShirtGarmentMeasurements(mask: mask))
        #expect(!measurements.frontNeckWasFound)
    }

    @Test func anEmptyCutoutHasNoMeasurements() {
        #expect(ShirtGarmentMeasurements(mask: ShirtCutoutMask(width: 100, height: 100, pixels: [UInt8](repeating: 0, count: 10_000))) == nil)
    }

    @Test func onlyTheLargestPieceOfACutoutIsTheGarment() {
        var pixels = [UInt8](repeating: 0, count: 100 * 100)
        for row in 20..<80 { for column in 20..<80 { pixels[row * 100 + column] = 255 } }
        pixels[2 * 100 + 90] = 255
        let kept = ShirtCutoutMask(width: 100, height: 100, pixels: pixels).keepingTheLargestPiece()
        #expect(kept.pixels[2 * 100 + 90] == 0)
        #expect(kept.pixels[50 * 100 + 50] == 255)
    }

    @Test func theGarmentTakesItsBaseColorFromTheHemBandAndNotTheGreenPrint() throws {
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        #expect(abs(garment.baseColor.red - 200.0 / 255) < 0.01)
        #expect(abs(garment.baseColor.green - 40.0 / 255) < 0.01)
        #expect(abs(garment.baseColor.blue - 40.0 / 255) < 0.01)
        #expect(garment.size == CGSize(width: 400, height: 500))
        #expect(garment.meanBrightness > 0.2 && garment.meanBrightness < 0.4)
        #expect(garment.frontNeckPoint == CGPoint(x: 199, y: 60))
    }

    @Test func noGarmentWhenTheCutoutIsTinyOrTheSizesDiffer() {
        let (photo, mask) = tShirtPhotoAndMask()
        var tinyPixels = [UInt8](repeating: 0, count: 400 * 500)
        for row in 100..<110 { for column in 100..<110 { tinyPixels[row * 400 + column] = 255 } }
        #expect(ShirtGarment.make(workingPhoto: photo, cutoutMask: ShirtCutoutMask(width: 400, height: 500, pixels: tinyPixels)) == nil)
        #expect(ShirtGarment.make(workingPhoto: photo, cutoutMask: ShirtCutoutMask(width: 200, height: 250, pixels: [UInt8](repeating: 255, count: 50_000))) == nil)
        #expect(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask) != nil)
    }
}

// MARK: - The per-frame analysis

/// A 160 by 120 frame of a person: a gray room, skin for the head and neck, and a blue shirt from row 70 down to `shirtBottomRow`
/// with dark trousers under it. The shoulders are at row 72 and 40 pixels apart (columns 60 and 100).
private func smallFrameOfAPerson(shirtBottomRow: Int) -> ShirtSmallFrame {
    var canvas = ShirtTestCanvas(width: 160, height: 120, color: (128, 128, 128))
    canvas.fillCircle(centerColumn: 80, centerRow: 30, radius: 14, color: (200, 150, 120))
    canvas.fill(columns: 72..<88, rows: 40..<70, color: (200, 150, 120))
    canvas.fill(columns: 50..<110, rows: 70..<shirtBottomRow, color: (30, 60, 150))
    canvas.fill(columns: 50..<110, rows: shirtBottomRow..<120, color: (20, 20, 20))
    var person = [UInt8](repeating: 0, count: 160 * 120)
    for row in 16..<120 { for column in 50..<110 { person[row * 160 + column] = 255 } }
    let torso = BodyTorso(
        imageLeftShoulder: CGPoint(x: 60, y: 72), imageRightShoulder: CGPoint(x: 100, y: 72),
        imageLeftHip: CGPoint(x: 63, y: 130), imageRightHip: CGPoint(x: 97, y: 130), hipsWereEstimated: true, shouldersAreSeen: true
    )
    return ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person, torso: torso)
}

struct ShirtFrameAnalysisTests {
    @Test func theOldShirtsColorIsTheMedianOfThePatchBelowTheShoulders() throws {
        let color = try #require(smallFrameOfAPerson(shirtBottomRow: 110).measureOldShirtColor())
        #expect(color == SIMD3<Float>(30, 60, 150))
    }

    @Test func theNeckIsFoundWhereTheSkinGivesWayToTheOldShirt() throws {
        let frame = smallFrameOfAPerson(shirtBottomRow: 110)
        #expect(frame.bodyNeckRow(oldShirtColor: SIMD3(30, 60, 150)) == 70)
    }

    @Test func theNewShirtIsCutAtTheNeckAndAboveButNotAcrossTheOldShirt() {
        let frame = smallFrameOfAPerson(shirtBottomRow: 110)
        let analysis = ShirtFrameAnalysis(frame: frame, oldShirtColor: SIMD3(30, 60, 150))
        func isCut(column: Int, row: Int) -> Bool { analysis.maskPixels[(row * 160 + column) * 4] == 255 }
        // The head, the neck, and the room above the shoulders: cut. The shirt below the neck: not cut.
        #expect(isCut(column: 80, row: 30))
        #expect(isCut(column: 80, row: 55))
        #expect(isCut(column: 80, row: 20))
        #expect(!isCut(column: 80, row: 90))
        #expect(!isCut(column: 56, row: 80))
        // The old shirt's collar edge, just above the neck base, is the old shirt's color and so is not cut, so the new shirt
        // covers it. The neck base is 10 percent of the 40 pixel shoulder width above the midpoint: row 68.
        #expect(!isCut(column: 80, row: 70))
    }

    @Test func theOldShirtBeyondTheGarmentIsMarkedAsUncoveredButNotTheTrousers() {
        let frame = smallFrameOfAPerson(shirtBottomRow: 100)
        let analysis = ShirtFrameAnalysis(frame: frame, oldShirtColor: SIMD3(30, 60, 150))
        func isUncovered(column: Int, row: Int) -> Bool { analysis.maskPixels[(row * 160 + column) * 4 + 1] == 255 }
        #expect(isUncovered(column: 80, row: 90))
        #expect(isUncovered(column: 55, row: 85))
        #expect(!isUncovered(column: 80, row: 110))
        #expect(!isUncovered(column: 80, row: 30))
        #expect(!isUncovered(column: 20, row: 90))
    }

    @Test func aTwoPixelStripeOfTrimInsideTheOldShirtIsFilledToo() {
        let person = smallFrameOfAPerson(shirtBottomRow: 100)
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (0, 0, 0))
        canvas.bytes = person.rgba
        canvas.fill(columns: 56..<58, rows: 80..<96, color: (230, 110, 80))
        let withTrim = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person.personMask, torso: person.torso)
        let analysis = ShirtFrameAnalysis(frame: withTrim, oldShirtColor: SIMD3(30, 60, 150))
        #expect(analysis.maskPixels[(88 * 160 + 56) * 4 + 1] == 255)
        // A gap that wide as the trousers below the shirt is still not filled.
        #expect(analysis.maskPixels[(105 * 160 + 56) * 4 + 1] == 0)
    }

    @Test func somethingFarFromTheBodyThatSharesTheOldShirtsColorIsNotTheOldShirt() {
        // A chair back the old shirt's color, 60 pixels from the center. The old shirt's sleeves reach 0.9 * 40 = 36.
        let person = smallFrameOfAPerson(shirtBottomRow: 100)
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (0, 0, 0))
        canvas.bytes = person.rgba
        canvas.fill(columns: 130..<150, rows: 80..<110, color: (30, 60, 150))
        var personMask = person.personMask
        for row in 80..<110 { for column in 130..<150 { personMask[row * 160 + column] = 255 } }
        let withChair = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: personMask, torso: person.torso)
        let analysis = ShirtFrameAnalysis(frame: withChair, oldShirtColor: SIMD3(30, 60, 150))
        #expect(analysis.maskPixels[(95 * 160 + 140) * 4 + 1] == 0)
        #expect(analysis.maskPixels[(90 * 160 + 80) * 4 + 1] == 255)
    }

    @Test func theOldShirtsHemIsFoundBelowTheShouldersAlongTheBody() throws {
        // The shirt ends at row 112, 40 pixels below the shoulder midpoint at row 72, which is 1.0 shoulder widths.
        let analysis = ShirtFrameAnalysis(frame: smallFrameOfAPerson(shirtBottomRow: 112), oldShirtColor: SIMD3(30, 60, 150))
        let hemDistance = try #require(analysis.oldShirtHemDistance)
        #expect(abs(hemDistance - 40) < 3)
        // A shirt that runs to the bottom of the frame has no hem to find.
        #expect(ShirtFrameAnalysis(frame: smallFrameOfAPerson(shirtBottomRow: 120), oldShirtColor: SIMD3(30, 60, 150)).oldShirtHemDistance == nil)
    }

    @Test func aDarkShirtOverDarkTrousersHasItsHemFoundFromTheDropInLightness() throws {
        // Both look like the old shirt's color to the color test, which is why the hem needs the lightness profile too.
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (128, 128, 128))
        canvas.fill(columns: 50..<110, rows: 70..<112, color: (24, 38, 52))
        canvas.fill(columns: 50..<110, rows: 112..<120, color: (12, 14, 18))
        var person = [UInt8](repeating: 0, count: 160 * 120)
        for row in 16..<120 { for column in 50..<110 { person[row * 160 + column] = 255 } }
        let torso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 60, y: 72), imageRightShoulder: CGPoint(x: 100, y: 72),
            imageLeftHip: CGPoint(x: 63, y: 130), imageRightHip: CGPoint(x: 97, y: 130), hipsWereEstimated: true, shouldersAreSeen: true
        )
        let frame = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person, torso: torso)
        let hemDistance = try #require(ShirtFrameAnalysis(frame: frame, oldShirtColor: SIMD3(24, 38, 52)).oldShirtHemDistance)
        #expect(abs(hemDistance - 40) < 3)
    }

    @Test func aHemOutsideTheRangeOfATorsoIsAMisread() {
        let shoulderWidth = 40.0
        func profile(dropsAt dropStep: Int, count: Int = 90) -> [Double] { (0..<count).map { $0 < dropStep ? 1 : 0 } }
        let steadyLightness = [Double](repeating: 100, count: 90)
        // 1.0 shoulder widths is a hem. 0.5 is a seam in the shirt or a hand, and 2.2 is somewhere else on the body.
        #expect(ShirtFrameAnalysis.hemDistance(oldShirtShareOfTheBand: profile(dropsAt: 42), lightnessOfTheBand: steadyLightness, shoulderWidth: shoulderWidth) == 42)
        #expect(ShirtFrameAnalysis.hemDistance(oldShirtShareOfTheBand: profile(dropsAt: 20), lightnessOfTheBand: steadyLightness, shoulderWidth: shoulderWidth) == nil)
        #expect(ShirtFrameAnalysis.hemDistance(oldShirtShareOfTheBand: profile(dropsAt: 88), lightnessOfTheBand: steadyLightness, shoulderWidth: shoulderWidth) == nil)
        // A drop in lightness, with the old shirt's color still matching, is a hem in range and not outside it.
        let darkerFromStep50 = (0..<90).map { $0 < 50 ? 100.0 : 40.0 }
        let alwaysOldShirt = [Double](repeating: 1, count: 90)
        let lightnessHem = ShirtFrameAnalysis.hemDistance(oldShirtShareOfTheBand: alwaysOldShirt, lightnessOfTheBand: darkerFromStep50, shoulderWidth: shoulderWidth)
        #expect(lightnessHem.map { abs($0 - 49) <= 1 } == true)
        let darkerFromStep20 = (0..<90).map { $0 < 20 ? 100.0 : 40.0 }
        #expect(ShirtFrameAnalysis.hemDistance(oldShirtShareOfTheBand: alwaysOldShirt, lightnessOfTheBand: darkerFromStep20, shoulderWidth: shoulderWidth) == nil)
        // A small change in lightness is shading, not a hem.
        let slightlyDarker = (0..<90).map { $0 < 50 ? 100.0 : 90.0 }
        #expect(ShirtFrameAnalysis.hemDistance(oldShirtShareOfTheBand: alwaysOldShirt, lightnessOfTheBand: slightlyDarker, shoulderWidth: shoulderWidth) == nil)
    }

    @Test func theOldShirtsMeanLightnessComesFromItsOwnPixels() {
        let analysis = ShirtFrameAnalysis(frame: smallFrameOfAPerson(shirtBottomRow: 100), oldShirtColor: SIMD3(30, 60, 150))
        let expectedLuminance = Float(0.299 * 30 + 0.587 * 60 + 0.114 * 150) / 255
        #expect(abs(analysis.oldShirtMeanLuminance - expectedLuminance) < 0.01)
        #expect(abs(analysis.oldShirtMeanBrightness - Float(30 + 60 + 150) / (3 * 255)) < 0.01)
    }
}

// MARK: - The renderer

struct ShirtTryOnRendererTests {
    /// A 640 by 360 frame: a gray room, a head and neck of skin, a blue shirt from `shirtTopRow` to `shirtBottomRow` and from
    /// column 235 to 470, and dark trousers below it. The shoulders are at `shoulderRow`, at columns 230 and 410, so the
    /// shoulder width is 180. The person is the head, neck, shirt, and trousers.
    private func personFrame(shoulderRow: Int = 190, shirtTopRow: Int = 185, shirtBottomRow: Int = 360) -> (frame: ShirtTestCanvas, personMask: CIImage, torso: BodyTorso) {
        var canvas = ShirtTestCanvas(width: 640, height: 360, color: (128, 128, 128))
        var personCanvas = ShirtTestCanvas(width: 640, height: 360, color: (0, 0, 0))
        func draw(columns: Range<Int>, rows: Range<Int>, color: (UInt8, UInt8, UInt8)) {
            canvas.fill(columns: columns, rows: rows, color: color)
            personCanvas.fill(columns: columns, rows: rows, color: (255, 255, 255))
        }
        canvas.fillCircle(centerColumn: 320, centerRow: shoulderRow - 90, radius: 50, color: (200, 150, 120))
        personCanvas.fillCircle(centerColumn: 320, centerRow: shoulderRow - 90, radius: 50, color: (255, 255, 255))
        draw(columns: 300..<340, rows: (shoulderRow - 50)..<shirtTopRow, color: (200, 150, 120))
        draw(columns: 235..<470, rows: shirtTopRow..<shirtBottomRow, color: (30, 60, 150))
        draw(columns: 235..<470, rows: shirtBottomRow..<360, color: (20, 20, 20))
        let personMask = CIImage(bitmapData: Data(personCanvas.bytes), bytesPerRow: 640 * 4, size: CGSize(width: 640, height: 360), format: .RGBA8, colorSpace: nil)
        let torso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 230, y: shoulderRow), imageRightShoulder: CGPoint(x: 410, y: shoulderRow),
            imageLeftHip: CGPoint(x: 244, y: shoulderRow + 261), imageRightHip: CGPoint(x: 396, y: shoulderRow + 261), hipsWereEstimated: true, shouldersAreSeen: true
        )
        return (canvas, personMask, torso)
    }

    private func maxDifference(_ first: ShirtTestCanvas, _ second: ShirtTestCanvas, column: Int, row: Int) -> Int {
        let a = first.pixel(column: column, row: row), b = second.pixel(column: column, row: row)
        return max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    @Test func theGarmentDrawsOnlyInsideThePersonAndNeverOnTheHeadOrNeck() throws {
        let (frame, personMask, torso) = personFrame()
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let composite = ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment)
        #expect(composite.extent == frame.ciImage.extent)
        let result = renderedCanvas(of: composite, context: context)
        let untouched = renderedCanvas(of: frame.ciImage, context: context)

        // Outside the person the garment, which reaches from column 208 at the shoulders, leaves the room alone. The person's
        // shirt starts at column 235.
        #expect(maxDifference(result, untouched, column: 215, row: 260) <= 3)
        #expect(maxDifference(result, untouched, column: 225, row: 230) <= 3)
        #expect(maxDifference(result, untouched, column: 560, row: 300) <= 3)
        // The face, the neck, and the room above the shoulders are untouched.
        #expect(maxDifference(result, untouched, column: 320, row: 100) <= 3)
        #expect(maxDifference(result, untouched, column: 320, row: 160) <= 3)
        #expect(maxDifference(result, untouched, column: 250, row: 150) <= 3)
        // The old blue shirt under the garment is gone: it is red now, not blue.
        let chest = result.pixel(column: 320, row: 330)
        #expect(chest.red > chest.blue + 40)
    }

    @Test func theGarmentLandsTheRightWayUpWithItsPrintOnTheChest() throws {
        let (frame, personMask, torso) = personFrame()
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        // The garment's torso runs from its shoulder line (row 49.9) to its hem (row 499), and lands from about row 179.6 to
        // the hem at 1.08 torso lengths below the shoulders. The green band at 25 to 35 percent of the garment's height, rows
        // 125 to 175, is a third of the way down that run, about row 245. The neck shift and the hem fit move it a little.
        let printRow = 245
        let print = result.pixel(column: 320, row: printRow)
        #expect(print.green > print.red && print.green > print.blue, "the green print should be at row \(printRow), got \(print)")
        // Above the print, at the shoulders, and below it, near the bottom of the frame, the garment is red.
        let shoulder = result.pixel(column: 320, row: 205)
        let belowPrint = result.pixel(column: 320, row: 330)
        #expect(shoulder.red > shoulder.green + 20, "the shoulders should be red, got \(shoulder)")
        #expect(belowPrint.red > belowPrint.green + 20, "below the print should be red, got \(belowPrint)")
    }

    @Test func theOldShirtBeyondTheGarmentTakesTheGarmentsBaseColor() throws {
        let (frame, personMask, torso) = personFrame()
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        // The old shirt reaches column 470 and the garment's edge is near column 431, so column 455 is old shirt the garment
        // misses, which must not stay blue.
        let beside = result.pixel(column: 455, row: 300)
        #expect(beside.red > beside.blue + 40, "old shirt beside the garment should take its red base color, got \(beside)")
    }

    @Test func aPersonMaskOfAnotherSizeIsScaledToTheFrame() throws {
        let (frame, _, torso) = personFrame()
        // The same person at a quarter of the frame's size.
        var smallPerson = ShirtTestCanvas(width: 160, height: 90, color: (0, 0, 0))
        smallPerson.fill(columns: 59..<118, rows: 46..<90, color: (255, 255, 255))
        smallPerson.fillCircle(centerColumn: 80, centerRow: 25, radius: 12, color: (255, 255, 255))
        smallPerson.fill(columns: 75..<85, rows: 35..<46, color: (255, 255, 255))
        let smallMask = CIImage(bitmapData: Data(smallPerson.bytes), bytesPerRow: 160 * 4, size: CGSize(width: 160, height: 90), format: .RGBA8, colorSpace: nil)
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: smallMask, torso: torso, garment: garment), context: context)
        let untouched = renderedCanvas(of: frame.ciImage, context: context)
        #expect(maxDifference(result, untouched, column: 150, row: 300) <= 3)
        #expect(result.pixel(column: 320, row: 330).red > result.pixel(column: 320, row: 330).blue + 40)
    }

    @Test func theCompositeIsTheFrameWhenTheTorsoCannotBeMappedOntoTheGarment() throws {
        let (frame, personMask, _) = personFrame()
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        // Four corners on one line have no perspective map.
        let flatTorso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 100, y: 100), imageRightShoulder: CGPoint(x: 200, y: 100),
            imageLeftHip: CGPoint(x: 100, y: 100), imageRightHip: CGPoint(x: 200, y: 100), hipsWereEstimated: false, shouldersAreSeen: true
        )
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: personMask, torso: flatTorso, garment: garment), context: context)
        #expect(maxDifference(result, renderedCanvas(of: frame.ciImage, context: context), column: 320, row: 300) <= 3)
    }

    @Test func theGarmentEndsWhereTheOldShirtEndsSoItNeverDrawsOverTrousers() throws {
        // The shoulders are at row 100 and the old shirt ends at row 300, 200 below, which is 1.11 shoulder widths. The
        // estimated hips would put the garment's hem at row 382, over the trousers.
        let (frame, personMask, torso) = personFrame(shoulderRow: 100, shirtTopRow: 95, shirtBottomRow: 300)
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let trousers = result.pixel(column: 320, row: 335)
        #expect(trousers.red < 60 && trousers.blue < 60, "the trousers should stay dark, got \(trousers)")
        let aboveTheHem = result.pixel(column: 320, row: 280)
        #expect(aboveTheHem.red > aboveTheHem.blue + 40, "the garment should reach the old hem, got \(aboveTheHem)")
    }

    @Test func theNecklinesMeetSoALowerCollarPullsTheGarmentDown() throws {
        // The learner's shirt starts at row 205, not 185, so the garment's front neck, which would land near row 186, moves
        // down about 19 rows. The print, a band from row 231 to 260 without the move, covers rows 250 to 279 with it.
        let (frame, personMask, torso) = personFrame(shirtTopRow: 205)
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let print = result.pixel(column: 320, row: 272)
        #expect(print.green > print.red + 20, "the print should have moved down to row 272, got \(print)")
        let formerPrint = result.pixel(column: 320, row: 238)
        #expect(formerPrint.green < formerPrint.red, "the print should have left row 238, got \(formerPrint)")
    }

    @Test func theBodysTorsoCornersFollowTheSpikesOffsets() {
        let torso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 200, y: 100), imageRightShoulder: CGPoint(x: 400, y: 100),
            imageLeftHip: CGPoint(x: 220, y: 400), imageRightHip: CGPoint(x: 380, y: 400), hipsWereEstimated: false, shouldersAreSeen: true
        )
        let corners = ShirtTryOnRenderer.bodyTorsoCorners(of: torso)
        // Shoulder span 200: outward 24. Hem drop (0, 300): top corners 12 up, bottom corners 24 down.
        #expect(isNear(corners[0], CGPoint(x: 176, y: 88)))
        #expect(isNear(corners[1], CGPoint(x: 424, y: 88)))
        #expect(isNear(corners[2], CGPoint(x: 380 + 14.4, y: 424)))
        #expect(isNear(corners[3], CGPoint(x: 220 - 14.4, y: 424)))
    }
}
