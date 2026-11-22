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
import simd
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

// MARK: - The drawn edge

struct ShirtCutoutEdgeTests {
    @Test func theDrawnEdgeIsPulledInAndRampsUpToFullyOpaqueInside() {
        // A 40 by 40 cutout with a 20 by 20 garment square from column and row 10 to 29.
        var pixels = [UInt8](repeating: 0, count: 40 * 40)
        for row in 10..<30 { for column in 10..<30 { pixels[row * 40 + column] = 255 } }
        let alpha = ShirtCutoutMask(width: 40, height: 40, pixels: pixels).featheredEdgeAlpha()
        func alphaAt(column: Int, row: Int) -> UInt8 { alpha[row * 40 + column] }

        // The garment's outer two pixels, which carry the photo's background, are never drawn, and nothing outside is.
        #expect(alphaAt(column: 10, row: 20) == 0 && alphaAt(column: 11, row: 20) == 0)
        #expect(alphaAt(column: 5, row: 20) == 0)
        // The edge ramps up over a few pixels, and the middle is fully opaque.
        #expect(alphaAt(column: 12, row: 20) > 0 && alphaAt(column: 12, row: 20) < alphaAt(column: 14, row: 20))
        #expect(alphaAt(column: 20, row: 20) == 255)
        // The photo's own edge counts as background, so a garment touching it is pulled in there too.
        let touchingTheEdge = ShirtCutoutMask(width: 10, height: 10, pixels: [UInt8](repeating: 255, count: 100)).featheredEdgeAlpha()
        #expect(touchingTheEdge[0] == 0 && touchingTheEdge[5 * 10 + 1] == 0 && touchingTheEdge[5 * 10 + 5] > 0)
    }
}

// MARK: - Framing debounce

struct ShirtFramingDebouncerTests {
    @Test func aKindSettlesOnlyOnceItHasHeldForHalfASecond() {
        var debouncer = ShirtFramingDebouncer()
        #expect(debouncer.advance(to: .standBack, at: 0) == nil)
        #expect(debouncer.advance(to: .standBack, at: 0.49) == nil)
        #expect(debouncer.settledKind == nil)
        #expect(debouncer.advance(to: .standBack, at: 0.5) == .standBack)
        #expect(debouncer.settledKind == .standBack)
        // A settled kind is reported once.
        #expect(debouncer.advance(to: .standBack, at: 0.6) == nil)
    }

    @Test func aFlickerAcrossAThresholdNeverSettlesAndRestartsTheClock() {
        var debouncer = ShirtFramingDebouncer()
        _ = debouncer.advance(to: .standBack, at: 0)
        _ = debouncer.advance(to: .standBack, at: 0.5)
        // Ready for a moment, then back: the shirt does not appear and vanish with each frame.
        #expect(debouncer.advance(to: .ready, at: 1.0) == nil)
        #expect(debouncer.advance(to: .standBack, at: 1.2) == nil)
        #expect(debouncer.advance(to: .ready, at: 1.3) == nil)
        #expect(debouncer.advance(to: .ready, at: 1.79) == nil)
        #expect(debouncer.settledKind == .standBack)
        #expect(debouncer.advance(to: .ready, at: 1.8) == .ready)
    }

    @Test func aCandidateThatTurnsIntoAnotherUnsettledKindStartsItsClockAgain() {
        var debouncer = ShirtFramingDebouncer()
        _ = debouncer.advance(to: .ready, at: 0)
        _ = debouncer.advance(to: .ready, at: 0.5)
        // Nobody for a moment, then standing too close: the newer kind has its own half second to hold.
        #expect(debouncer.advance(to: .noPerson, at: 1.0) == nil)
        #expect(debouncer.advance(to: .standBack, at: 1.3) == nil)
        #expect(debouncer.advance(to: .standBack, at: 1.6) == nil)
        #expect(debouncer.advance(to: .standBack, at: 1.8) == .standBack)
    }

    @Test func eachKindTakesTheCoachingLineOfItsFraming() {
        #expect(ShirtFramingKind(.noPerson).coachingLine == "I can't see you yet. Step in front of the camera.")
        #expect(ShirtFramingKind(.standBack(.tooCloseForTheChest)) == .standBack)
        #expect(ShirtFramingKind.standBack.coachingLine == "Stand back so I can see your shoulders and chest.")
        #expect(ShirtFramingKind.ready.coachingLine == nil)
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
        #expect(garment.frontNeckPoint == CGPoint(x: 199, y: 60))
    }

    @Test func aStraySpeckInTheCutoutDoesNotStretchTheGarment() throws {
        // The torso ends at row 449 and a speck sits at row 499. Without dropping the speck the garment would be 50 rows taller.
        let (photo, mask) = tShirtPhotoAndMask()
        var pixels = mask.pixels
        for row in 450..<500 { for column in 0..<400 { pixels[row * 400 + column] = 0 } }
        pixels[499 * 400 + 10] = 255
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: ShirtCutoutMask(width: 400, height: 500, pixels: pixels)))
        #expect(garment.torsoCorners.bottomLeft.y == 449)
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

    @Test func everythingAboveTheShouldersIsCutWhateverItsColorAndWhicheverSideTheShouldersAreListedOn() {
        // Old shirt colored pixels 20 rows above the shoulder line, which is above 30 percent of the shoulder width over the
        // neck base, are cut even though they look like the old shirt. A room pixel to the side of the head, above the shoulder
        // line and outside the neck's width, is cut too.
        let person = smallFrameOfAPerson(shirtBottomRow: 100)
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (0, 0, 0))
        canvas.bytes = person.rgba
        canvas.fill(columns: 120..<140, rows: 40..<60, color: (30, 60, 150))
        let withBlueAbove = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person.personMask, torso: person.torso)
        let analysis = ShirtFrameAnalysis(frame: withBlueAbove, oldShirtColor: SIMD3(30, 60, 150))
        func isCut(_ analysis: ShirtFrameAnalysis, column: Int, row: Int) -> Bool { analysis.maskPixels[(row * 160 + column) * 4] == 255 }
        #expect(isCut(analysis, column: 130, row: 50))
        #expect(isCut(analysis, column: 58, row: 60))
        // The same torso with the shoulders listed the other way round cuts the same pixels.
        let swapped = BodyTorso(
            imageLeftShoulder: person.torso.imageRightShoulder, imageRightShoulder: person.torso.imageLeftShoulder,
            imageLeftHip: person.torso.imageRightHip, imageRightHip: person.torso.imageLeftHip, hipsWereEstimated: true, shouldersAreSeen: true
        )
        let swappedAnalysis = ShirtFrameAnalysis(frame: ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person.personMask, torso: swapped), oldShirtColor: SIMD3(30, 60, 150))
        #expect(isCut(swappedAnalysis, column: 58, row: 60))
        #expect(!isCut(swappedAnalysis, column: 80, row: 90))
    }

    @Test func oldShirtColoredClothBelowTheHipsIsNotTheOldShirt() {
        // The hips are at row 105, 33 below the shoulder midpoint, so the shirt's zone ends at 1.1 * 33 + 2 = 38 pixels down,
        // row 110. Trousers of the shirt's color at rows 112 to 119 are below it and must keep their own color.
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (128, 128, 128))
        canvas.fill(columns: 50..<110, rows: 70..<120, color: (30, 60, 150))
        var person = [UInt8](repeating: 0, count: 160 * 120)
        for row in 16..<120 { for column in 50..<110 { person[row * 160 + column] = 255 } }
        let torso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 60, y: 72), imageRightShoulder: CGPoint(x: 100, y: 72),
            imageLeftHip: CGPoint(x: 63, y: 105), imageRightHip: CGPoint(x: 97, y: 105), hipsWereEstimated: false, shouldersAreSeen: true
        )
        let analysis = ShirtFrameAnalysis(frame: ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person, torso: torso), oldShirtColor: SIMD3(30, 60, 150))
        #expect(analysis.maskPixels[(90 * 160 + 80) * 4 + 1] == 255)
        #expect(analysis.maskPixels[(116 * 160 + 80) * 4 + 1] == 0)
    }

    @Test func aLoneOldShirtColoredPixelInsideTheTrousersIsASpeckNotShirt() {
        let person = smallFrameOfAPerson(shirtBottomRow: 100)
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (0, 0, 0))
        canvas.bytes = person.rgba
        canvas.fill(columns: 80..<81, rows: 110..<111, color: (30, 60, 150))
        let withSpeck = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: person.personMask, torso: person.torso)
        let analysis = ShirtFrameAnalysis(frame: withSpeck, oldShirtColor: SIMD3(30, 60, 150))
        #expect(analysis.maskPixels[(110 * 160 + 80) * 4 + 1] == 0)
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

    @Test func theOldShirtsLightIsTheMedianOfItsPixelsAndNotItsBrightest() {
        // Two rows of the blue in three, then a fold lit at 1.5 times, which still passes the color rule.
        let frame = smallFrameOfAPerson(shirtBottomRow: 100)
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (0, 0, 0))
        canvas.bytes = frame.rgba
        canvas.fill(columns: 50..<110, rows: 90..<100, color: (38, 74, 180))
        let litFrame = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: frame.personMask, torso: frame.torso)
        let analysis = ShirtFrameAnalysis(frame: litFrame, oldShirtColor: SIMD3(30, 60, 150))
        let linear = ShirtColorMath.linearValueOfEachByte
        let blueLuminance = 0.2126 * linear[30] + 0.7152 * linear[60] + 0.0722 * linear[150]
        #expect(abs(analysis.oldShirtMedianLinearLuminance - blueLuminance) < 0.001)
    }

    @Test func theOldShirtsMedianLightComesFromItsOwnPixelsInLinearLight() {
        let analysis = ShirtFrameAnalysis(frame: smallFrameOfAPerson(shirtBottomRow: 100), oldShirtColor: SIMD3(30, 60, 150))
        let linear = ShirtColorMath.linearValueOfEachByte
        let expectedLuminance = 0.2126 * linear[30] + 0.7152 * linear[60] + 0.0722 * linear[150]
        // The histogram's steps are 1/2048 wide.
        #expect(abs(analysis.oldShirtMedianLinearLuminance - expectedLuminance) < 0.001)
    }
}

// MARK: - The renderer

struct ShirtTryOnRendererTests {
    /// A 640 by 360 frame: a gray room, a head and neck of skin, a blue shirt from `shirtTopRow` to `shirtBottomRow` and from
    /// column 235 to 470, and dark trousers below it. The shoulders are at `shoulderRow`, at columns 230 and 410, so the
    /// shoulder width is 180. The person is the head, neck, shirt, and trousers.
    private func personFrame(shoulderRow: Int = 190, shirtTopRow: Int = 185, shirtBottomRow: Int = 360, roomLevel: UInt8 = 128) -> (frame: ShirtTestCanvas, personMask: CIImage, torso: BodyTorso) {
        var canvas = ShirtTestCanvas(width: 640, height: 360, color: (roomLevel, roomLevel, roomLevel))
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
        let composite = ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment)
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
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        // The garment's torso runs from its shoulder line (row 49.9) to its hem (row 499), and lands from row 179.6 to the hem
        // at 1.08 torso lengths below the shoulders, row 471.9. The body's torso narrows toward the hips, so the perspective map
        // stretches the top of the garment: the green band at 25 to 35 percent of the garment's height, rows 125 to 175, lands
        // on rows 238 to 274, and its middle is row 256.
        let printRow = 256
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
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
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
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: smallMask, torso: torso, garment: garment), context: context)
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
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: flatTorso, garment: garment), context: context)
        #expect(maxDifference(result, renderedCanvas(of: frame.ciImage, context: context), column: 320, row: 300) <= 3)
    }

    @Test func theGarmentEndsWhereTheOldShirtEndsSoItNeverDrawsOverTrousers() throws {
        // The shoulders are at row 100 and the old shirt ends at row 300, 200 below, which is 1.11 shoulder widths. The
        // estimated hips would put the garment's hem at row 382, over the trousers.
        let (frame, personMask, torso) = personFrame(shoulderRow: 100, shirtTopRow: 95, shirtBottomRow: 300)
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let trousers = result.pixel(column: 320, row: 335)
        #expect(trousers.red < 60 && trousers.blue < 60, "the trousers should stay dark, got \(trousers)")
        let aboveTheHem = result.pixel(column: 320, row: 280)
        #expect(aboveTheHem.red > aboveTheHem.blue + 40, "the garment should reach the old hem, got \(aboveTheHem)")
    }

    @Test func theGarmentKeepsTheHipsTheyGaveWhenTheyWereSeen() throws {
        // The same frame as the hem test, but the hips were seen, so the garment reaches them and the old shirt's hem does not
        // move them.
        var (frame, personMask, torso) = personFrame(shoulderRow: 100, shirtTopRow: 95, shirtBottomRow: 300)
        torso = BodyTorso(
            imageLeftShoulder: torso.imageLeftShoulder, imageRightShoulder: torso.imageRightShoulder,
            imageLeftHip: torso.imageLeftHip, imageRightHip: torso.imageRightHip, hipsWereEstimated: false, shouldersAreSeen: true
        )
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let overTheTrousers = result.pixel(column: 320, row: 335)
        #expect(overTheTrousers.red > overTheTrousers.blue + 40, "the garment should reach the seen hips, got \(overTheTrousers)")
    }

    @Test func aNeckScanThatFindsSomethingFarFromTheGarmentsNeckIsIgnored() throws {
        // The learner's shirt starts at row 245, far under the shoulders, so the patch the old shirt's color comes from is
        // skin, and the scan finds the skin of the neck far above the garment's neck. Moving the garment that far is wrong, so
        // the print stays where it is, rows 238 to 274.
        let (frame, personMask, torso) = personFrame(shirtTopRow: 245)
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let print = result.pixel(column: 320, row: 244)
        #expect(print.green > print.red + 20, "the print should not have moved, got \(print)")
    }

    @Test func aGarmentWithNoNeckHoleIsNotMovedToMeetTheNecklines() throws {
        // The cutout has no neck hole, so its neck point is only a guess at the shoulder line. The learner's shirt starts at row
        // 205, which would move a garment that knew its neck, and this one stays: the print is still at rows 238 to 274.
        let (frame, personMask, torso) = personFrame(shirtTopRow: 205)
        let (photo, mask) = tShirtPhotoAndMask(withNeckHole: false)
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        #expect(!garment.frontNeckWasFound)
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let stillThere = result.pixel(column: 320, row: 244)
        #expect(stillThere.green > stillThere.red + 20, "the print should not have moved, got \(stillThere)")
        let notMoved = result.pixel(column: 320, row: 286)
        #expect(notMoved.green < notMoved.red, "the print should not reach row 286, got \(notMoved)")
    }

    @Test func theNecklinesMeetSoALowerCollarPullsTheGarmentDown() throws {
        // The learner's shirt starts at row 205, not 185, so the garment's front neck, which would land near row 186, moves
        // down about 19 rows. The print, a band from row 238 to 274 without the move, covers rows 257 to 293 with it.
        let (frame, personMask, torso) = personFrame(shirtTopRow: 205)
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let print = result.pixel(column: 320, row: 272)
        #expect(print.green > print.red + 20, "the print should have moved down to row 272, got \(print)")
        let formerPrint = result.pixel(column: 320, row: 238)
        #expect(formerPrint.green < formerPrint.red, "the print should have left row 238, got \(formerPrint)")
    }

    @Test func thePanelsRendererDrawsTheFrameAsItIsUntilItsFirstAnalysisIsIn() throws {
        let (frame, personMask, torso) = personFrame()
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let renderer = ShirtTryOnRenderer(ciContext: CIContext())
        // The first frame starts the analysis on its own queue and is not held up by it.
        #expect(renderer.composition(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment) == nil)
        let waitStartedAt = Date()
        var composition: ShirtTryOnComposition?
        while composition == nil, Date().timeIntervalSince(waitStartedAt) < 20 {
            Thread.sleep(forTimeInterval: 0.02)
            composition = renderer.composition(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment)
        }
        #expect(composition != nil, "a later frame draws the garment once the analysis is in, waited 20 seconds")
        // A reset forgets it, so the next session starts over.
        renderer.reset()
        #expect(renderer.composition(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment) == nil)
    }

    @Test func theGarmentIsLitByTheRoomSoABrighterRoomDrawsItBrighter() throws {
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        func chestRed(roomLevel: UInt8) -> Int {
            let (frame, personMask, torso) = personFrame(roomLevel: roomLevel)
            let composite = ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment)
            return renderedCanvas(of: composite, context: context).pixel(column: 320, row: 330).red
        }
        let dimRoom = chestRed(roomLevel: 90), brightRoom = chestRed(roomLevel: 200)
        #expect(brightRoom > dimRoom + 40, "dim room \(dimRoom), bright room \(brightRoom)")
        // The product photo's red (200 in sRGB) is lit at most as brightly as the room's white allows, not copied.
        #expect(dimRoom < 150)
    }

    @Test func aWhiteGarmentInABrightRoomRollsOffBelowWhiteInsteadOfClipping() throws {
        // A white T-shirt on a light gray photo, in a room as bright as a camera's white.
        var canvas = ShirtTestCanvas(width: 400, height: 500, color: (230, 230, 232))
        var maskPixels = [UInt8](repeating: 0, count: 400 * 500)
        for row in 0..<500 {
            for column in 0..<400 where row < 150 || (column >= 100 && column < 300) {
                maskPixels[row * 400 + column] = 255
                canvas.fill(columns: column..<(column + 1), rows: row..<(row + 1), color: (250, 250, 250))
            }
        }
        let garment = try #require(ShirtGarment.make(workingPhoto: canvas.cgImage, cutoutMask: ShirtCutoutMask(width: 400, height: 500, pixels: maskPixels)))
        let (frame, personMask, torso) = personFrame(roomLevel: 245)
        let context = CIContext()
        let result = renderedCanvas(of: ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composite(frame: frame.ciImage, personMask: personMask, torso: torso, garment: garment), context: context)
        let chest = result.pixel(column: 320, row: 300)
        #expect(chest.red < 250 && chest.red > 180, "the white chest should be bright but below clipping, got \(chest)")
    }

    @Test func theSleevesAreDrawnApartOnlyWhenBothElbowsAreSeen() throws {
        let (frame, personMask, torso) = personFrame()
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        let context = CIContext()
        // The arms held out to the sides, as wide as the flat sleeves lie.
        let armsOut = torso.withElbowsForTesting(imageLeft: CGPoint(x: 100, y: 230), imageRight: CGPoint(x: 540, y: 230))
        let withSleeves = try #require(ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composition(frame: frame.ciImage, personMask: personMask, torso: armsOut, garment: garment))
        #expect(withSleeves.sleeves.map(\.side) == [.imageLeft, .imageRight])
        let oneElbow = torso.withElbowsForTesting(imageLeft: CGPoint(x: 100, y: 230), imageRight: nil)
        let whole = try #require(ShirtTryOnRenderer(ciContext: context, analysisRunsInTheBackground: false).composition(frame: frame.ciImage, personMask: personMask, torso: oneElbow, garment: garment))
        #expect(whole.sleeves.isEmpty)
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

// MARK: - The elbows

struct ShirtElbowTests {
    @Test func eachElbowGoesWithTheShoulderOnItsOwnSideWhicheverWayTheCameraIsMirrored() throws {
        func elbowReadings(personLeftShoulderX: Double, personRightShoulderX: Double, personLeftElbowX: Double, personRightElbowX: Double, elbowConfidence: Float = 0.9, rightElbowConfidence: Float = 0.9) -> ShirtBodyJointReadings {
            ShirtBodyJointReadings(
                personLeftShoulder: ShirtJointReading(visionPoint: CGPoint(x: personLeftShoulderX, y: 0.7), confidence: 0.9),
                personRightShoulder: ShirtJointReading(visionPoint: CGPoint(x: personRightShoulderX, y: 0.7), confidence: 0.9),
                personLeftHip: nil, personRightHip: nil,
                personLeftElbow: ShirtJointReading(visionPoint: CGPoint(x: personLeftElbowX, y: 0.4), confidence: elbowConfidence),
                personRightElbow: ShirtJointReading(visionPoint: CGPoint(x: personRightElbowX, y: 0.4), confidence: rightElbowConfidence)
            )
        }
        // The person's left shoulder is image right, so their left elbow is the image right elbow.
        let unmirrored = try #require(BodyTorso(readings: elbowReadings(personLeftShoulderX: 0.65, personRightShoulderX: 0.35, personLeftElbowX: 0.7, personRightElbowX: 0.3), frameSize: frameSize))
        #expect(unmirrored.imageRightElbow.map { isNear($0, CGPoint(x: 700, y: 300)) } == true)
        #expect(unmirrored.imageLeftElbow.map { isNear($0, CGPoint(x: 300, y: 300)) } == true)
        let mirrored = try #require(BodyTorso(readings: elbowReadings(personLeftShoulderX: 0.35, personRightShoulderX: 0.65, personLeftElbowX: 0.3, personRightElbowX: 0.7), frameSize: frameSize))
        #expect(mirrored.imageLeftElbow == unmirrored.imageLeftElbow && mirrored.imageRightElbow == unmirrored.imageRightElbow)
        // An elbow under the confidence floor is not seen.
        let weakElbow = try #require(BodyTorso(readings: elbowReadings(personLeftShoulderX: 0.65, personRightShoulderX: 0.35, personLeftElbowX: 0.7, personRightElbowX: 0.3, elbowConfidence: 0.2), frameSize: frameSize))
        #expect(weakElbow.imageRightElbow == nil && weakElbow.imageLeftElbow != nil)
        let weakRightElbow = try #require(BodyTorso(readings: elbowReadings(personLeftShoulderX: 0.65, personRightShoulderX: 0.35, personLeftElbowX: 0.7, personRightElbowX: 0.3, rightElbowConfidence: 0.2), frameSize: frameSize))
        #expect(weakRightElbow.imageLeftElbow == nil && weakRightElbow.imageRightElbow != nil)
    }

    @Test func movingAndScalingTheTorsoCarriesItsElbows() {
        let torso = torsoAt(shoulderY: 150, shoulderWidth: 300).withElbowsForTesting(imageLeft: CGPoint(x: 330, y: 400), imageRight: CGPoint(x: 670, y: 400))
        #expect(torso.withTorsoLength(200).imageLeftElbow == CGPoint(x: 330, y: 400))
        #expect(torso.scaled(by: 0.5).imageRightElbow == CGPoint(x: 335, y: 200))
    }

    @Test func anElbowMissingFromAResultHoldsItsPlaceForAMomentThenGoes() {
        var smoother = ShirtTorsoSmoother()
        let withElbows = torsoAt(shoulderY: 150, shoulderWidth: 300).withElbowsForTesting(imageLeft: CGPoint(x: 330, y: 400), imageRight: CGPoint(x: 670, y: 400))
        let withoutElbows = torsoAt(shoulderY: 150, shoulderWidth: 300)
        _ = smoother.advance(toward: withElbows, at: 0)
        #expect(smoother.advance(toward: withoutElbows, at: 0.2)?.imageLeftElbow == CGPoint(x: 330, y: 400))
        #expect(smoother.advance(toward: withoutElbows, at: 0.45)?.imageLeftElbow == nil)
        // An elbow seen again appears where it was seen.
        #expect(smoother.advance(toward: withElbows, at: 0.5)?.imageRightElbow == CGPoint(x: 670, y: 400))
    }
}

extension BodyTorso {
    /// The same torso with these elbows.
    func withElbowsForTesting(imageLeft: CGPoint?, imageRight: CGPoint?) -> BodyTorso {
        BodyTorso(
            imageLeftShoulder: imageLeftShoulder, imageRightShoulder: imageRightShoulder, imageLeftHip: imageLeftHip, imageRightHip: imageRightHip,
            hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: shouldersAreSeen, imageLeftElbow: imageLeft, imageRightElbow: imageRight
        )
    }
}

// MARK: - The garment's sleeves, edge, and white

struct ShirtGarmentPartsTests {
    @Test func theTShirtsSleevesAreFoundApartFromItsTorso() throws {
        let (_, mask) = tShirtPhotoAndMask()
        let measurements = try #require(ShirtGarmentMeasurements(mask: mask))
        let left = try #require(measurements.imageLeftSleeve), right = try #require(measurements.imageRightSleeve)
        // The left sleeve is columns 0 to 99 and rows 0 to 149: its seam runs down the torso's edge column to the armpit, and
        // its opening is at its far end, across all 150 rows.
        #expect(left.seamTop == CGPoint(x: 100, y: 0) && left.seamBottom == CGPoint(x: 100, y: 149))
        #expect(isNear(left.openingCenter, CGPoint(x: 5, y: 74.5)))
        #expect(abs(left.openingWidth - 150) < 0.001)
        #expect(left.openingOuter.y < left.openingInner.y, "the outer edge is the one the shoulder end of the seam is on")
        #expect(right.seamTop == CGPoint(x: 299, y: 0) && isNear(right.openingCenter, CGPoint(x: 394, y: 74.5)))
        #expect(left.isSleevePixel[10 * 400 + 50] && !left.isSleevePixel[200 * 400 + 150] && !left.isSleevePixel[10 * 400 + 350])
    }

    @Test func aCutoutWhoseSidesRunStraightDownHasNoSleevesApart() throws {
        // A box with no gap under its sides, like a jacket whose sleeves hang beside its body.
        var pixels = [UInt8](repeating: 0, count: 400 * 500)
        for row in 0..<500 { for column in 0..<400 { pixels[row * 400 + column] = 255 } }
        let measurements = try #require(ShirtGarmentMeasurements(mask: ShirtCutoutMask(width: 400, height: 500, pixels: pixels)))
        #expect(measurements.imageLeftSleeve == nil && measurements.imageRightSleeve == nil)
    }

    @Test func theGarmentKeepsItsSleevesApartWhenItHasBoth() throws {
        let (photo, mask) = tShirtPhotoAndMask()
        let garment = try #require(ShirtGarment.make(workingPhoto: photo, cutoutMask: mask))
        #expect(garment.sleeves.map(\.geometry.side) == [.imageLeft, .imageRight])
        #expect(garment.torsoWithoutSleeves != nil)
        // The left sleeve's box holds its pixels and the strip tucked under the torso's edge.
        #expect(garment.sleeves[0].boundingBox.minX == 0 && garment.sleeves[0].boundingBox.maxX > 100)
    }

    @Test func theCutoutsOuterPixelsTakeTheCleanClothsColorsInsteadOfTheBackgrounds() {
        // A red square whose outer 2 pixels carry the photo's white background, as a lifted edge does.
        let size = 40
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for row in 5..<35 {
            for column in 5..<35 {
                pixels[row * size + column] = 255
                let isEdge = row < 7 || row >= 33 || column < 7 || column >= 33
                if !isEdge { rgba[(row * size + column) * 4 + 1] = 0; rgba[(row * size + column) * 4 + 2] = 0 }
            }
        }
        let cleaned = ShirtCutoutMask(width: size, height: size, pixels: pixels).colorsWithTheBackgroundBleedRemoved(from: rgba)
        let edgeIndex = (5 * size + 20) * 4
        #expect(cleaned[edgeIndex] == 255 && cleaned[edgeIndex + 1] == 0 && cleaned[edgeIndex + 2] == 0)
        // The background stays as it was.
        #expect(cleaned[(1 * size + 1) * 4 + 1] == 255)
    }

    @Test func thePhotosWhiteIsItsBackgroundRaisedToAGarmentBrighterThanIt() {
        let linear = ShirtColorMath.linearValueOfEachByte
        let grayBackground: [[UInt8]] = [[230, 230, 230], [231, 231, 231], [233, 233, 233]]
        let backgroundLuminance = 0.2126 * linear[230] + 0.7152 * linear[231] + 0.0722 * linear[233]
        // A cream shirt darker than its background: the white is the background, so the cream stays below 1.
        let creamWhite = ShirtGarment.photoWhite(backgroundChannels: grayBackground, garmentLuminances: [Float](repeating: 0.6, count: 100))
        #expect(abs(creamWhite.x - linear[230]) < 0.001 && abs(creamWhite.z - linear[233]) < 0.001)
        // A white shirt brighter than its background: the white rises to the shirt's own brightest cloth, keeping the
        // background's color.
        let whiteShirtWhite = ShirtGarment.photoWhite(backgroundChannels: grayBackground, garmentLuminances: [Float](repeating: 0.9, count: 100))
        let whiteLuminance = 0.2126 * whiteShirtWhite.x + 0.7152 * whiteShirtWhite.y + 0.0722 * whiteShirtWhite.z
        #expect(abs(whiteLuminance - 0.9) < 0.001)
        #expect(abs(whiteShirtWhite.z / whiteShirtWhite.x - linear[233] / linear[230]) < 0.001)
        #expect(backgroundLuminance < 0.9)
        // A cutout that fills its photo is its own white.
        #expect(ShirtGarment.photoWhite(backgroundChannels: [[], [], []], garmentLuminances: [Float](repeating: 0.7, count: 10)) == SIMD3(repeating: 0.7))
    }
}

// MARK: - The room's light and the shading's old shirt

struct ShirtRoomLightTests {
    /// A 100 by 100 frame: a gray wall at `wallLevel` across the top half, an orange wall below it, a person in the middle,
    /// and a blown lamp in a corner, a fifth of the gray wall, so counting it would move the white.
    private func roomFrame(wallLevel: UInt8) -> ShirtSmallFrame {
        var canvas = ShirtTestCanvas(width: 100, height: 100, color: (wallLevel, wallLevel, wallLevel))
        canvas.fill(columns: 0..<100, rows: 50..<100, color: (230, 120, 40))
        canvas.fill(columns: 0..<40, rows: 0..<20, color: (255, 255, 255))
        canvas.fill(columns: 40..<60, rows: 0..<100, color: (255, 240, 230))
        var person = [UInt8](repeating: 0, count: 100 * 100)
        for row in 0..<100 { for column in 40..<60 { person[row * 100 + column] = 255 } }
        let torso = BodyTorso(imageLeftShoulder: CGPoint(x: 42, y: 20), imageRightShoulder: CGPoint(x: 58, y: 20), imageLeftHip: CGPoint(x: 43, y: 60), imageRightHip: CGPoint(x: 57, y: 60), hipsWereEstimated: true, shouldersAreSeen: true)
        return ShirtSmallFrame(width: 100, height: 100, rgba: canvas.bytes, personMask: person, torso: torso)
    }

    @Test func theRoomsWhiteIsItsUnsaturatedUnclippedWallOffThePerson() throws {
        let light = try #require(ShirtRoomLight.measure(in: roomFrame(wallLevel: 160)))
        // Only the gray wall counts: the orange wall is colored, the lamp is clipped, and the bright person is the person.
        #expect(abs(light.whiteLuminance - ShirtColorMath.linearValueOfEachByte[160]) < 0.002)
        #expect(abs(light.illuminant.x - 1) < 0.001 && abs(light.illuminant.z - 1) < 0.001)
        // A brighter room has a brighter white.
        let brighterRoom = try #require(ShirtRoomLight.measure(in: roomFrame(wallLevel: 210)))
        #expect(brighterRoom.whiteLuminance > light.whiteLuminance * 1.5)
    }

    @Test func aWarmLightIsReadAsAWarmIlluminant() throws {
        var frame = roomFrame(wallLevel: 160)
        var bytes = frame.rgba
        // A warm wall still within the saturation limit.
        for row in 20..<50 { for column in 0..<40 { let index = (row * 100 + column) * 4; bytes[index] = 200; bytes[index + 1] = 180; bytes[index + 2] = 160 } }
        frame = ShirtSmallFrame(width: 100, height: 100, rgba: bytes, personMask: frame.personMask, torso: frame.torso)
        let light = try #require(ShirtRoomLight.measure(in: frame))
        #expect(light.illuminant.x > 1.1 && light.illuminant.z < 0.9)
    }

    @Test func aFrameWithNoUsableRoomHasNoLight() {
        let frame = roomFrame(wallLevel: 160)
        let everyoneIsPerson = ShirtSmallFrame(width: 100, height: 100, rgba: frame.rgba, personMask: [UInt8](repeating: 255, count: 100 * 100), torso: frame.torso)
        #expect(ShirtRoomLight.measure(in: everyoneIsPerson) == nil)
    }

    @Test func theShadingReadsTheOldShirtsOwnClothButNotAPanelOfAnotherFabric() {
        // The navy old shirt of the standing photo, with its gray side panel, which passes the color rule on its lightness, and
        // a fold of the navy at 0.6 of the light, which keeps the navy's chromaticity.
        let frame = smallFrameOfAPerson(shirtBottomRow: 110)
        var canvas = ShirtTestCanvas(width: 160, height: 120, color: (0, 0, 0))
        canvas.bytes = frame.rgba
        canvas.fill(columns: 50..<110, rows: 70..<110, color: (25, 36, 48))
        canvas.fill(columns: 52..<58, rows: 90..<100, color: (36, 34, 34))
        canvas.fill(columns: 80..<86, rows: 90..<100, color: (18, 26, 36))
        let navyFrame = ShirtSmallFrame(width: 160, height: 120, rgba: canvas.bytes, personMask: frame.personMask, torso: frame.torso)
        let navyLab = ShirtColorMath.lab(red: 25, green: 36, blue: 48)
        #expect(ShirtColorMath.distance(from: ShirtColorMath.lab(red: 36, green: 34, blue: 34), to: navyLab) < ShirtColorMath.oldShirtDistanceLimit)
        let analysis = ShirtFrameAnalysis(frame: navyFrame, oldShirtColor: SIMD3(25, 36, 48))
        func readsTheLight(column: Int, row: Int) -> Bool { analysis.maskPixels[(row * 160 + column) * 4 + 2] == 255 }
        #expect(readsTheLight(column: 70, row: 95))
        #expect(readsTheLight(column: 83, row: 95), "a fold of the old shirt's own cloth carries its light")
        #expect(!readsTheLight(column: 55, row: 95), "a panel of another fabric is not the old shirt's light")
        #expect(!readsTheLight(column: 80, row: 50), "the neck is not the old shirt")
    }

    @Test func theOldShirtsZoneEndsWhereTheGarmentsHemLands() {
        // The hips are 58 rows below the shoulders, so the garment's hem lands 1.08 * 58 = 62.6 rows below them, and the blue
        // further down is not the old shirt; the zone's old margin, 1.10 torso lengths and a few pixels, counted it.
        let frame = smallFrameOfAPerson(shirtBottomRow: 120)
        let torso = BodyTorso(imageLeftShoulder: CGPoint(x: 60, y: 40), imageRightShoulder: CGPoint(x: 100, y: 40), imageLeftHip: CGPoint(x: 60, y: 98), imageRightHip: CGPoint(x: 100, y: 98), hipsWereEstimated: true, shouldersAreSeen: true)
        let shifted = ShirtSmallFrame(width: 160, height: 120, rgba: frame.rgba, personMask: frame.personMask, torso: torso)
        let analysis = ShirtFrameAnalysis(frame: shifted, oldShirtColor: SIMD3(30, 60, 150))
        func isUncovered(row: Int) -> Bool { analysis.maskPixels[(row * 160 + 80) * 4 + 1] == 255 }
        // 1.08 * 58 = 62.6 rows below row 40 is row 102.6.
        #expect(isUncovered(row: 100))
        #expect(!isUncovered(row: 105))
    }
}

// MARK: - The renderer's light and geometry

struct ShirtTryOnLightTests {
    @Test func theHighlightRolloffPassesValuesUpToTheKneeThenEasesBelowTheCeiling() {
        #expect(ShirtTryOnRenderer.highlightRolloff(0.3) == 0.3)
        #expect(ShirtTryOnRenderer.highlightRolloff(ShirtTryOnRenderer.highlightKnee) == ShirtTryOnRenderer.highlightKnee)
        // Just past the knee the slope is still about 1, so the curve has no corner there.
        let step = 0.001
        let slopeAfterTheKnee = (ShirtTryOnRenderer.highlightRolloff(ShirtTryOnRenderer.highlightKnee + step) - ShirtTryOnRenderer.highlightKnee) / step
        #expect(abs(slopeAfterTheKnee - 1) < 0.01)
        // It keeps rising but never reaches the ceiling, so a lit highlight keeps its folds and never clips.
        var previous = ShirtTryOnRenderer.highlightKnee
        for value in stride(from: 0.65, through: ShirtTryOnRenderer.highlightRolloffDomainTop, by: 0.05) {
            let rolledOff = ShirtTryOnRenderer.highlightRolloff(value)
            #expect(rolledOff > previous && rolledOff < ShirtTryOnRenderer.highlightCeiling)
            previous = rolledOff
        }
    }

    @Test func anAffineTransformCarriesThreePointsOntoThreeOthers() throws {
        let source = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        let destination = [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 25), CGPoint(x: -15, y: 5)]
        let transform = try #require(ShirtTryOnRenderer.affineTransform(from: source, to: destination))
        for (point, expected) in zip(source, destination) { #expect(isNear(point.applying(transform), expected)) }
        #expect(ShirtTryOnRenderer.affineTransform(from: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)], to: destination) == nil)
    }

    @Test func theBodysMotionCarriesTheEarlierShouldersOntoTheLaterOnes() {
        let earlier = torsoAt(shoulderY: 150, shoulderWidth: 300)
        let later = BodyTorso(
            imageLeftShoulder: CGPoint(x: 420, y: 160), imageRightShoulder: CGPoint(x: 600, y: 260),
            imageLeftHip: .zero, imageRightHip: .zero, hipsWereEstimated: true, shouldersAreSeen: true
        )
        let motion = ShirtTryOnRenderer.motion(from: earlier, to: later)
        #expect(isNear(earlier.imageLeftShoulder.applying(motion), later.imageLeftShoulder))
        #expect(isNear(earlier.imageRightShoulder.applying(motion), later.imageRightShoulder))
    }

    @Test func aSleeveLandsAlongItsArmFromItsSeam() throws {
        // A sleeve shaped like the product photos': its seam runs down the torso's edge, longer than the sleeve, which reaches
        // out and a little down to an opening half as wide as the seam. Its middle is 65 pixels past the seam's middle.
        let leftSleeve = ShirtSleeveGeometry(
            side: .imageLeft, seamTop: CGPoint(x: 100, y: 0), seamBottom: CGPoint(x: 100, y: 100),
            openingOuter: CGPoint(x: 30, y: 25), openingInner: CGPoint(x: 40, y: 75), isSleevePixel: []
        )
        // The photo maps onto the frame as it is. The shoulder joint is inside the seam, and the arm hangs out from it.
        let shoulder = CGPoint(x: 130, y: 10), elbow = CGPoint(x: 40, y: 200), bodyCenter = CGPoint(x: 200, y: 250)
        let landingResult = ShirtTryOnRenderer.sleeveLanding(
            of: leftSleeve, torsoHomography: matrix_identity_double3x3, shoulder: shoulder, elbow: elbow, bodyCenter: bodyCenter, garmentToBodyScale: 1
        )
        let landing = try #require(landingResult)
        // The seam stays where the torso put it.
        #expect(landing[0] == leftSleeve.seamTop && landing[3] == leftSleeve.seamBottom)
        let armDirection = simd_normalize(SIMD2(elbow.x - shoulder.x, elbow.y - shoulder.y))
        let awayFromTheBody = SIMD2(-armDirection.y, armDirection.x) * (armDirection.y > 0 ? 1 : -1)
        let seamCenter = SIMD2(100.0, 50), shoulderPoint = SIMD2(Double(shoulder.x), Double(shoulder.y))
        let openingOuter = SIMD2(Double(landing[1].x), Double(landing[1].y)), openingInner = SIMD2(Double(landing[2].x), Double(landing[2].y))
        let openingCenter = (openingOuter + openingInner) / 2
        // The opening is the sleeve's length (65) past the seam's middle along the arm...
        #expect(abs(simd_dot(openingCenter - seamCenter, armDirection) - 65) < 0.001)
        // ...halfway from the seam middle's line to the arm's own line...
        let seamOffTheArmLine = simd_dot(seamCenter - shoulderPoint, awayFromTheBody)
        #expect(abs(simd_dot(openingCenter - shoulderPoint, awayFromTheBody) - seamOffTheArmLine / 2) < 0.001)
        // ...across the arm, 0.8 of its flat width, with its outer end away from the body.
        #expect(abs(simd_dot(openingOuter - openingInner, armDirection)) < 0.001)
        #expect(abs(simd_distance(openingOuter, openingInner) - leftSleeve.openingWidth * ShirtTryOnRenderer.sleeveOpeningShareOnTheArm) < 0.001)
        #expect(simd_dot(openingOuter - openingInner, awayFromTheBody) > 0)
        // An arm raised straight out from the shoulder would turn the sleeve inside out, so it does not land.
        let raisedResult = ShirtTryOnRenderer.sleeveLanding(
            of: leftSleeve, torsoHomography: matrix_identity_double3x3, shoulder: shoulder, elbow: CGPoint(x: 130, y: -300), bodyCenter: bodyCenter, garmentToBodyScale: 1
        )
        #expect(raisedResult == nil)
    }
}
