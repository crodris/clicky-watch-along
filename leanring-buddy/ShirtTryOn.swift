//
//  ShirtTryOn.swift
//  leanring-buddy
//
//  The data and pure rules of the shirt try-on: "could I see this shirt on me" draws the shirt from a store's product
//  photo over the shirt the learner wears, as a 2D overlay to judge the print and the color. Fit and size are not measured.
//  This file holds the body's torso from Vision's pose joints (`BodyTorso`), whether the learner stands where the overlay can
//  work (`ShirtFraming`), and the garment cut out of the product photo (`ShirtGarment`). The drawing is in
//  ShirtTryOnRenderer.swift and the pose tracking in ShirtPoseTracker.swift.
//
//  Every point here is in camera or garment pixels with the origin at the top left and y growing down, the same as
//  `RoomArtCorners`. Core Image's y grows up, so only the renderer flips it.
//

import CoreGraphics
import CoreImage
import Foundation
import simd
import Vision

// MARK: - The body's torso

/// One joint as the pose request reports it, with Vision's own coordinates: x and y from 0 to 1, y growing up.
nonisolated struct ShirtJointReading: Equatable, Sendable {
    let visionPoint: CGPoint
    let confidence: Float
}

/// The joints the torso needs, each nil when the pose request did not report it, and the elbows the sleeves follow. These are
/// the person's own left and right, which the torso sorts by where they land in the image.
nonisolated struct ShirtBodyJointReadings: Equatable, Sendable {
    let personLeftShoulder: ShirtJointReading?
    let personRightShoulder: ShirtJointReading?
    let personLeftHip: ShirtJointReading?
    let personRightHip: ShirtJointReading?
    let personLeftElbow: ShirtJointReading?
    let personRightElbow: ShirtJointReading?

    init(
        personLeftShoulder: ShirtJointReading?, personRightShoulder: ShirtJointReading?, personLeftHip: ShirtJointReading?, personRightHip: ShirtJointReading?,
        personLeftElbow: ShirtJointReading? = nil, personRightElbow: ShirtJointReading? = nil
    ) {
        self.personLeftShoulder = personLeftShoulder
        self.personRightShoulder = personRightShoulder
        self.personLeftHip = personLeftHip
        self.personRightHip = personRightHip
        self.personLeftElbow = personLeftElbow
        self.personRightElbow = personRightElbow
    }
}

/// The shoulders and hips of the person in a camera frame, and the elbows when they are seen, in camera pixels.
nonisolated struct BodyTorso: Equatable, Sendable {
    /// A joint under this confidence counts as not seen. Vision reports about 0.5 to 1 for a joint it can see, and under 0.3
    /// for one it is guessing at from the rest of the body.
    static let jointConfidenceFloor: Float = 0.3
    /// A torso, shoulder to hip, is about 1.45 shoulder widths long, the spike's figure for putting hips that are out of the
    /// frame back in place.
    static let torsoLengthInShoulderWidths = 1.45
    /// Estimated hips sit this share of the shoulder width toward the center, since hips are narrower than shoulders.
    static let estimatedHipInsetShare = 0.08

    /// "Image left" and "image right" are where the joints land in the frame, so the torso is the same whichever way the
    /// camera is mirrored. Image left is the smaller x.
    let imageLeftShoulder: CGPoint
    let imageRightShoulder: CGPoint
    let imageLeftHip: CGPoint
    let imageRightHip: CGPoint
    /// The hips were not seen, so they were put 1.45 shoulder widths below the shoulders.
    let hipsWereEstimated: Bool
    /// Both shoulders have a confidence over the floor and lie inside the frame.
    let shouldersAreSeen: Bool
    /// The elbow on the image left shoulder's arm and the one on the image right's, each nil when it is not seen. The sleeves
    /// follow the line from each shoulder to its elbow, so the shirt is drawn without them apart when either is missing.
    let imageLeftElbow: CGPoint?
    let imageRightElbow: CGPoint?

    var shoulderMidpoint: CGPoint { CGPoint(x: (imageLeftShoulder.x + imageRightShoulder.x) / 2, y: (imageLeftShoulder.y + imageRightShoulder.y) / 2) }
    var hipMidpoint: CGPoint { CGPoint(x: (imageLeftHip.x + imageRightHip.x) / 2, y: (imageLeftHip.y + imageRightHip.y) / 2) }
    var shoulderWidth: Double { hypot(imageRightShoulder.x - imageLeftShoulder.x, imageRightShoulder.y - imageLeftShoulder.y) }

    init(
        imageLeftShoulder: CGPoint, imageRightShoulder: CGPoint, imageLeftHip: CGPoint, imageRightHip: CGPoint, hipsWereEstimated: Bool, shouldersAreSeen: Bool,
        imageLeftElbow: CGPoint? = nil, imageRightElbow: CGPoint? = nil
    ) {
        self.imageLeftShoulder = imageLeftShoulder
        self.imageRightShoulder = imageRightShoulder
        self.imageLeftHip = imageLeftHip
        self.imageRightHip = imageRightHip
        self.hipsWereEstimated = hipsWereEstimated
        self.shouldersAreSeen = shouldersAreSeen
        self.imageLeftElbow = imageLeftElbow
        self.imageRightElbow = imageRightElbow
    }



    /// The torso of a pose request's observation, or nil when it has no shoulder joint at all.
    init?(observation: VNHumanBodyPoseObservation, frameSize: CGSize) {
        func reading(of jointName: VNHumanBodyPoseObservation.JointName) -> ShirtJointReading? {
            guard let recognizedPoint = try? observation.recognizedPoint(jointName) else { return nil }
            return ShirtJointReading(visionPoint: recognizedPoint.location, confidence: recognizedPoint.confidence)
        }
        let readings = ShirtBodyJointReadings(
            personLeftShoulder: reading(of: .leftShoulder), personRightShoulder: reading(of: .rightShoulder),
            personLeftHip: reading(of: .leftHip), personRightHip: reading(of: .rightHip),
            personLeftElbow: reading(of: .leftElbow), personRightElbow: reading(of: .rightElbow)
        )
        guard let torso = BodyTorso(readings: readings, frameSize: frameSize) else { return nil }
        self = torso
    }

    /// The torso of four joint readings in a frame of `frameSize` pixels, or nil when a shoulder is missing or the two
    /// shoulders are on top of each other, since nothing can be placed from them. A hip that is missing, under the confidence
    /// floor, or outside the frame is not seen, and then both hips are estimated from the shoulders.
    init?(readings: ShirtBodyJointReadings, frameSize: CGSize) {
        guard let personLeftShoulder = readings.personLeftShoulder, let personRightShoulder = readings.personRightShoulder else { return nil }
        func pixelPoint(_ reading: ShirtJointReading) -> CGPoint {
            CGPoint(x: reading.visionPoint.x * frameSize.width, y: (1 - reading.visionPoint.y) * frameSize.height)
        }
        func isSeen(_ reading: ShirtJointReading?) -> Bool {
            guard let reading, reading.confidence >= Self.jointConfidenceFloor else { return false }
            let point = pixelPoint(reading)
            return point.x >= 0 && point.x <= frameSize.width && point.y >= 0 && point.y <= frameSize.height
        }
        let shouldersInImageOrder = [pixelPoint(personLeftShoulder), pixelPoint(personRightShoulder)].sorted { $0.x < $1.x }
        let imageLeftShoulder = shouldersInImageOrder[0], imageRightShoulder = shouldersInImageOrder[1]
        let shoulderSpan = CGPoint(x: imageRightShoulder.x - imageLeftShoulder.x, y: imageRightShoulder.y - imageLeftShoulder.y)
        let shoulderSpanLength = hypot(shoulderSpan.x, shoulderSpan.y)
        guard shoulderSpanLength > 1 else { return nil }

        let shouldersAreSeen = isSeen(personLeftShoulder) && isSeen(personRightShoulder)
        // Each elbow belongs to the shoulder on its own side of the person, wherever that shoulder landed in the image.
        let personLeftIsImageLeft = pixelPoint(personLeftShoulder).x <= pixelPoint(personRightShoulder).x
        let seenPersonLeftElbow = isSeen(readings.personLeftElbow) ? readings.personLeftElbow.map(pixelPoint) : nil
        let seenPersonRightElbow = isSeen(readings.personRightElbow) ? readings.personRightElbow.map(pixelPoint) : nil
        let imageLeftElbow = personLeftIsImageLeft ? seenPersonLeftElbow : seenPersonRightElbow
        let imageRightElbow = personLeftIsImageLeft ? seenPersonRightElbow : seenPersonLeftElbow
        if isSeen(readings.personLeftHip), isSeen(readings.personRightHip), let personLeftHip = readings.personLeftHip, let personRightHip = readings.personRightHip {
            let hipsInImageOrder = [pixelPoint(personLeftHip), pixelPoint(personRightHip)].sorted { $0.x < $1.x }
            self.init(
                imageLeftShoulder: imageLeftShoulder, imageRightShoulder: imageRightShoulder,
                imageLeftHip: hipsInImageOrder[0], imageRightHip: hipsInImageOrder[1],
                hipsWereEstimated: false, shouldersAreSeen: shouldersAreSeen, imageLeftElbow: imageLeftElbow, imageRightElbow: imageRightElbow
            )
            return
        }
        // The body's down direction is across the shoulder line, toward the bottom of the image. The shoulders are sorted by x,
        // so the span points right and this perpendicular always points down.
        let downDirection = CGPoint(x: -shoulderSpan.y / shoulderSpanLength, y: shoulderSpan.x / shoulderSpanLength)
        let torsoLength = Self.torsoLengthInShoulderWidths * shoulderSpanLength
        let hipInset = Self.estimatedHipInsetShare
        self.init(
            imageLeftShoulder: imageLeftShoulder, imageRightShoulder: imageRightShoulder,
            imageLeftHip: CGPoint(
                x: imageLeftShoulder.x + downDirection.x * torsoLength + shoulderSpan.x * hipInset,
                y: imageLeftShoulder.y + downDirection.y * torsoLength + shoulderSpan.y * hipInset
            ),
            imageRightHip: CGPoint(
                x: imageRightShoulder.x + downDirection.x * torsoLength - shoulderSpan.x * hipInset,
                y: imageRightShoulder.y + downDirection.y * torsoLength - shoulderSpan.y * hipInset
            ),
            hipsWereEstimated: true, shouldersAreSeen: shouldersAreSeen, imageLeftElbow: imageLeftElbow, imageRightElbow: imageRightElbow
        )
    }

    /// The same torso with its hips moved so the shoulder-to-hip distance is `torsoLength`, along the body's current down
    /// direction. The renderer uses it when the old shirt's own hem shows where the body really ends.
    func withTorsoLength(_ torsoLength: Double) -> BodyTorso {
        let currentLength = hypot(hipMidpoint.x - shoulderMidpoint.x, hipMidpoint.y - shoulderMidpoint.y)
        guard currentLength > 1, torsoLength > 0 else { return self }
        let scale = torsoLength / currentLength
        func moved(hip: CGPoint, shoulder: CGPoint) -> CGPoint {
            CGPoint(x: shoulder.x + (hip.x - shoulder.x) * scale, y: shoulder.y + (hip.y - shoulder.y) * scale)
        }
        return BodyTorso(
            imageLeftShoulder: imageLeftShoulder, imageRightShoulder: imageRightShoulder,
            imageLeftHip: moved(hip: imageLeftHip, shoulder: imageLeftShoulder), imageRightHip: moved(hip: imageRightHip, shoulder: imageRightShoulder),
            hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: shouldersAreSeen, imageLeftElbow: imageLeftElbow, imageRightElbow: imageRightElbow
        )
    }
}

// MARK: - Where the learner stands

/// Whether the learner stands where the overlay can work, and if not, what to tell them.
nonisolated enum ShirtFraming: Equatable, Sendable {
    /// Why the learner should stand back.
    enum StandBackReason: Equatable, Sendable {
        /// A shoulder is outside the frame or not confidently found, so the shirt's top edge cannot be placed.
        case shouldersAreNotBothSeen
        /// The shoulders are wider than the frame can hold with the chest below them, so the print would be cut off.
        case tooCloseForTheChest
    }

    case noPerson
    case standBack(StandBackReason)
    case ready(BodyTorso)

    /// The shoulders must span less than this share of the frame width. A person at a laptop with the shoulders filling the
    /// frame is under 0.6 on a webcam that sees about 70 degrees, and the standing sample in the tests is at 0.36.
    static let widestShoulderShareOfFrameWidth = 0.62
    /// The print sits on the chest, which reaches this many shoulder widths below the shoulder line. All of it must be in the
    /// frame, or the learner cannot judge the print. A person seated close to the webcam fails this first.
    static let chestDepthInShoulderWidths = 0.6

    /// What `assess` tells the learner, or nil when the overlay can draw.
    var coachingLine: String? {
        switch self {
        case .noPerson: "I can't see you yet. Step in front of the camera."
        case .standBack: "Stand back so I can see your shoulders and chest."
        case .ready: nil
        }
    }

    /// `torso` is nil when the pose request found nobody.
    static func assess(torso: BodyTorso?, frameSize: CGSize) -> ShirtFraming {
        guard let torso else { return .noPerson }
        guard torso.shouldersAreSeen else { return .standBack(.shouldersAreNotBothSeen) }
        let shoulderWidth = torso.shoulderWidth
        let chestBottomY = max(torso.imageLeftShoulder.y, torso.imageRightShoulder.y) + chestDepthInShoulderWidths * shoulderWidth
        if shoulderWidth > widestShoulderShareOfFrameWidth * frameSize.width || chestBottomY > frameSize.height {
            return .standBack(.tooCloseForTheChest)
        }
        return .ready(torso)
    }
}

/// The framing without the torso, which is all the panel's status line and spoken line need.
nonisolated enum ShirtFramingKind: Equatable, Sendable {
    case noPerson
    case standBack
    case ready

    init(_ framing: ShirtFraming) {
        switch framing {
        case .noPerson: self = .noPerson
        case .standBack: self = .standBack
        case .ready: self = .ready
        }
    }

    /// The same words `ShirtFraming.coachingLine` says, nil when ready.
    var coachingLine: String? {
        switch self {
        case .noPerson: ShirtFraming.noPerson.coachingLine
        case .standBack: ShirtFraming.standBack(.shouldersAreNotBothSeen).coachingLine
        case .ready: nil
        }
    }
}

/// Holds back a change of framing until it has lasted a moment. `ShirtFraming.assess` has no hysteresis, so a learner
/// standing at the edge of a threshold flips between two kinds from frame to frame, and the status line and the shirt
/// would flicker with it. Pure, so a test steps it by hand.
nonisolated struct ShirtFramingDebouncer: Equatable, Sendable {
    /// A new kind must hold this long before it settles. Long enough to ride out a pose run that misjudges one frame, short
    /// enough that the shirt appears about as soon as the learner steps into place.
    static let secondsAKindMustHold = 0.5

    /// The kind that last settled, nil until one has.
    private(set) var settledKind: ShirtFramingKind?
    private var candidateKind: ShirtFramingKind?
    private var candidateSince: TimeInterval = 0

    /// Takes this frame's kind at `time` and returns the newly settled kind when it changed, else nil.
    mutating func advance(to kind: ShirtFramingKind, at time: TimeInterval) -> ShirtFramingKind? {
        guard kind != settledKind else {
            candidateKind = nil
            return nil
        }
        if kind != candidateKind {
            candidateKind = kind
            candidateSince = time
        }
        guard time - candidateSince >= Self.secondsAKindMustHold else { return nil }
        settledKind = kind
        candidateKind = nil
        return kind
    }
}

// MARK: - The garment

/// A color with each channel from 0 to 1, in sRGB.
nonisolated struct ShirtRGB: Equatable, Sendable {
    let red: Float
    let green: Float
    let blue: Float
}

/// A cutout of a garment: a pixel is garment when it is not 0. Sized like the working photo it came from.
nonisolated struct ShirtCutoutMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    /// The garment's foreground cutout from Apple's subject lifting, the largest instance only, at the image's own size. Nil
    /// when Vision finds nothing. This is the slow step of making a garment (about 100 to 200 ms), so call it off the main actor.
    static func lifted(from image: CGImage) -> ShirtCutoutMask? {
        let handler = VNImageRequestHandler(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { return nil }

        // The instance mask labels each pixel with its instance number, 0 for the background. The garment is the instance
        // with the most pixels, so a hanger or a second item in the photo does not become the shirt.
        var largestInstance: Int?
        if let instanceCounts = instancePixelCounts(of: observation.instanceMask) {
            largestInstance = observation.allInstances.max { instanceCounts[$0, default: 0] < instanceCounts[$1, default: 0] }
        }
        let chosenInstances = largestInstance.map { IndexSet(integer: $0) } ?? observation.allInstances
        guard let maskBuffer = try? observation.generateScaledMaskForImage(forInstances: chosenInstances, from: handler) else { return nil }
        return ShirtCutoutMask(maskBuffer: maskBuffer)
    }

    private static func instancePixelCounts(of instanceMask: CVPixelBuffer) -> [Int: Int]? {
        guard CVPixelBufferGetPixelFormatType(instanceMask) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(instanceMask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(instanceMask, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(instanceMask) else { return nil }
        let width = CVPixelBufferGetWidth(instanceMask), height = CVPixelBufferGetHeight(instanceMask)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(instanceMask)
        var counts: [Int: Int] = [:]
        for row in 0..<height {
            let rowPixels = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width where rowPixels[column] != 0 { counts[Int(rowPixels[column]), default: 0] += 1 }
        }
        return counts
    }

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "A mask holds one value per pixel")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// Vision's scaled mask comes as 32 bit floats from 0 to 1, or as bytes.
    private init?(maskBuffer: CVPixelBuffer) {
        let format = CVPixelBufferGetPixelFormatType(maskBuffer)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(maskBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(maskBuffer), height = CVPixelBufferGetHeight(maskBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let rowAddress = baseAddress.advanced(by: row * bytesPerRow)
            if format == kCVPixelFormatType_OneComponent32Float {
                let rowValues = rowAddress.assumingMemoryBound(to: Float.self)
                for column in 0..<width where rowValues[column] > 0.5 { pixels[row * width + column] = 255 }
            } else {
                let rowValues = rowAddress.assumingMemoryBound(to: UInt8.self)
                for column in 0..<width where rowValues[column] > 127 { pixels[row * width + column] = 255 }
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }

    /// How far the drawn edge is pulled in from the cutout's edge, in working photo pixels. Subject lifting marks a pixel as
    /// garment when it is at least half garment, so the outermost pixel or two still carry the photo's white or gray
    /// background, which would show as a light fringe around the shirt.
    static let edgePullInPixels = 2
    /// How many 3 by 3 box blurs soften the pulled-in edge: two make a ramp about 4 pixels wide, which lands as 1 to 3
    /// camera pixels, a camera's own edge softness.
    static let edgeSofteningPasses = 2

    /// The garment's alpha for drawing: the cutout pulled in by `edgePullInPixels` and softened by `edgeSofteningPasses`
    /// box blurs, 0 to 255 per pixel. Outside the pulled-in cutout it is 0, so the softening only ever fades the garment's
    /// own pixels and never brings background back in.
    func featheredEdgeAlpha() -> [UInt8] {
        let pulledIn = pulledIn(by: Self.edgePullInPixels).map { $0 ? Float(1) : 0 }
        // Each pass is a 3 pixel box along the rows, then along the columns.
        var softened = pulledIn
        for _ in 0..<Self.edgeSofteningPasses {
            var alongTheRows = [Float](repeating: 0, count: softened.count)
            for row in 0..<height {
                for column in 0..<width {
                    let index = row * width + column
                    let left = column > 0 ? softened[index - 1] : 0, right = column < width - 1 ? softened[index + 1] : 0
                    alongTheRows[index] = (left + softened[index] + right) / 3
                }
            }
            for row in 0..<height {
                for column in 0..<width {
                    let index = row * width + column
                    let above = row > 0 ? alongTheRows[index - width] : 0, below = row < height - 1 ? alongTheRows[index + width] : 0
                    softened[index] = (above + alongTheRows[index] + below) / 3
                }
            }
        }
        return zip(softened, pulledIn).map { softenedValue, pulledInValue in
            pulledInValue == 0 ? 0 : UInt8((min(max(softenedValue, 0), 1) * 255).rounded())
        }
    }

    /// Which pixels stay garment when the cutout is pulled in by `reach` pixels: every pixel within `reach` of them (a square)
    /// is garment, and the photo's edge counts as background, so a garment touching the edge is pulled in there too.
    func pulledIn(by reach: Int) -> [Bool] {
        // The distance from each pixel to the nearest background pixel along its row, then along its column.
        var distanceAlongTheRow = [Int](repeating: 0, count: pixels.count)
        for row in 0..<height {
            var lastBackgroundColumn = -1
            for column in 0..<width {
                if pixels[row * width + column] == 0 { lastBackgroundColumn = column }
                distanceAlongTheRow[row * width + column] = column - lastBackgroundColumn
            }
            var nextBackgroundColumn = width
            for column in stride(from: width - 1, through: 0, by: -1) {
                if pixels[row * width + column] == 0 { nextBackgroundColumn = column }
                distanceAlongTheRow[row * width + column] = min(distanceAlongTheRow[row * width + column], nextBackgroundColumn - column)
            }
        }
        // A pixel stays when it is far enough from the side edges, and so is every pixel within `reach` above and below it.
        let farFromTheSideEdges = distanceAlongTheRow.map { $0 > reach }
        var pulledIn = [Bool](repeating: false, count: pixels.count)
        var distanceAlongTheColumn = [Int](repeating: 0, count: height)
        for column in 0..<width {
            var lastNearRow = -1
            for row in 0..<height {
                if !farFromTheSideEdges[row * width + column] { lastNearRow = row }
                distanceAlongTheColumn[row] = row - lastNearRow
            }
            var nextNearRow = height
            for row in stride(from: height - 1, through: 0, by: -1) {
                if !farFromTheSideEdges[row * width + column] { nextNearRow = row }
                if min(distanceAlongTheColumn[row], nextNearRow - row) > reach { pulledIn[row * width + column] = true }
            }
        }
        return pulledIn
    }

    /// How deep the photo's background can reach into the cutout's colors. Subject lifting's edge, a JPEG's ringing, and the
    /// photo's own blur mix the light background into the garment's outer few pixels, which a light garment hides and a dark
    /// trim or a navy stripe shows as a pale outline.
    static let backgroundBleedPixels = 5

    /// The photo's colors with the cutout's outer `backgroundBleedPixels` replaced by the mean of the clean garment within a
    /// few pixels inside them, so no background color is left in the drawn edge. `rgba` is the photo's bytes, as tight RGBA
    /// rows; the alpha bytes are left as they are.
    func colorsWithTheBackgroundBleedRemoved(from rgba: [UInt8]) -> [UInt8] {
        precondition(rgba.count == pixels.count * 4, "The photo and the cutout must be the same size")
        let clean = pulledIn(by: Self.backgroundBleedPixels)
        let reach = Self.backgroundBleedPixels + 2
        // Summed area tables of the clean pixels' colors and of their count, so each edge pixel's mean costs four lookups.
        let tableWidth = width + 1
        var colorSums = [SIMD3<Double>](repeating: .zero, count: tableWidth * (height + 1))
        var countSums = [Double](repeating: 0, count: tableWidth * (height + 1))
        for row in 0..<height {
            var rowColor = SIMD3<Double>.zero, rowCount = 0.0
            for column in 0..<width {
                let index = row * width + column
                if clean[index] {
                    rowColor += SIMD3(Double(rgba[index * 4]), Double(rgba[index * 4 + 1]), Double(rgba[index * 4 + 2]))
                    rowCount += 1
                }
                colorSums[(row + 1) * tableWidth + column + 1] = colorSums[row * tableWidth + column + 1] + rowColor
                countSums[(row + 1) * tableWidth + column + 1] = countSums[row * tableWidth + column + 1] + rowCount
            }
        }
        var cleaned = rgba
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                guard pixels[index] != 0, !clean[index] else { continue }
                let top = max(0, row - reach), bottom = min(height, row + reach + 1), left = max(0, column - reach), right = min(width, column + reach + 1)
                let count = countSums[bottom * tableWidth + right] - countSums[top * tableWidth + right] - countSums[bottom * tableWidth + left] + countSums[top * tableWidth + left]
                // A sliver thinner than the bleed has no clean pixels near it and keeps its own colors.
                guard count > 0 else { continue }
                let colorSum = colorSums[bottom * tableWidth + right] - colorSums[top * tableWidth + right] - colorSums[bottom * tableWidth + left] + colorSums[top * tableWidth + left]
                let mean = colorSum / count
                cleaned[index * 4] = UInt8(mean.x.rounded())
                cleaned[index * 4 + 1] = UInt8(mean.y.rounded())
                cleaned[index * 4 + 2] = UInt8(mean.z.rounded())
            }
        }
        return cleaned
    }

    /// The mask keeping only its largest 4-connected piece, so a stray speck that lifting kept cannot stretch the garment's
    /// top or bottom edge.
    func keepingTheLargestPiece() -> ShirtCutoutMask {
        var pieceLabels = [Int32](repeating: 0, count: pixels.count)
        var nextLabel: Int32 = 0
        var largestLabel: Int32 = 0
        var largestSize = 0
        var pendingPixels: [Int] = []
        for startIndex in pixels.indices where pixels[startIndex] != 0 && pieceLabels[startIndex] == 0 {
            nextLabel += 1
            pieceLabels[startIndex] = nextLabel
            pendingPixels.append(startIndex)
            var pieceSize = 0
            while let index = pendingPixels.popLast() {
                pieceSize += 1
                let column = index % width, row = index / width
                for neighbor in [column > 0 ? index - 1 : -1, column < width - 1 ? index + 1 : -1, row > 0 ? index - width : -1, row < height - 1 ? index + width : -1]
                where neighbor >= 0 && pixels[neighbor] != 0 && pieceLabels[neighbor] == 0 {
                    pieceLabels[neighbor] = nextLabel
                    pendingPixels.append(neighbor)
                }
            }
            if pieceSize > largestSize { largestSize = pieceSize; largestLabel = nextLabel }
        }
        return ShirtCutoutMask(width: width, height: height, pixels: pieceLabels.map { $0 == largestLabel && largestLabel != 0 ? 255 : 0 })
    }
}

/// Which side of the garment a sleeve is on, as it lies in the photo and as it lands in the frame: image left or image right.
nonisolated enum ShirtSleeveSide: Equatable, Sendable {
    case imageLeft
    case imageRight
}

/// One sleeve of a flat lay garment, in the working photo's pixels, top left origin, y down. The sleeve is what lies beyond
/// the torso's edge column above the armpit; its quadrilateral runs from the seam's top (the shoulder) out along the sleeve's
/// top edge to the opening, across it, and back along the underside to the armpit.
nonisolated struct ShirtSleeveGeometry: Equatable, Sendable {
    let side: ShirtSleeveSide
    /// Where the sleeve meets the torso: the top of the shoulder and the armpit, both on the torso's edge column.
    let seamTop: CGPoint
    let seamBottom: CGPoint
    /// The two ends of the sleeve's opening: on the edge that starts at the shoulder, and on the underside.
    let openingOuter: CGPoint
    let openingInner: CGPoint
    /// The sleeve's own pixels, one per photo pixel.
    let isSleevePixel: [Bool]

    var seamCenter: CGPoint { CGPoint(x: (seamTop.x + seamBottom.x) / 2, y: (seamTop.y + seamBottom.y) / 2) }
    var openingCenter: CGPoint { CGPoint(x: (openingOuter.x + openingInner.x) / 2, y: (openingOuter.y + openingInner.y) / 2) }
    /// From the seam's middle to the opening's middle.
    var length: Double { hypot(openingCenter.x - seamCenter.x, openingCenter.y - seamCenter.y) }
    var openingWidth: Double { hypot(openingOuter.x - openingInner.x, openingOuter.y - openingInner.y) }
    /// Seam top, opening outer, opening inner, seam bottom: the quadrilateral the renderer maps onto the arm.
    var quadrilateral: [CGPoint] { [seamTop, openingOuter, openingInner, seamBottom] }

    /// The sleeve beyond `edgeColumn` (the torso's left edge for `imageLeft`, its right edge for `imageRight`), or nil when
    /// the cutout has none there or it is not separate from the torso below the armpit, such as a jacket whose sleeves hang
    /// beside its body. The armpit is where a column just outside the torso turns from cloth to background, going down from
    /// the shoulder, and the sleeve is the cloth connected to that column on the outer side of the edge.
    static func detect(side: ShirtSleeveSide, mask: ShirtCutoutMask, edgeColumn: Int, torsoWidth: Int, topRow: Int, lowestArmpitRow: Int) -> ShirtSleeveGeometry? {
        let outward = side == .imageLeft ? -1 : 1
        let probeColumn = edgeColumn + outward * max(2, Int(0.03 * Double(torsoWidth)))
        guard probeColumn >= 0, probeColumn < mask.width, topRow < lowestArmpitRow else { return nil }
        let isGarment = { (column: Int, row: Int) in mask.pixels[row * mask.width + column] != 0 }
        guard let seamTopRow = (topRow..<lowestArmpitRow).first(where: { isGarment(probeColumn, $0) }),
              let firstGapRow = ((seamTopRow + 1)..<lowestArmpitRow).first(where: { !isGarment(probeColumn, $0) }) else { return nil }
        let armpitRow = firstGapRow - 1
        guard armpitRow - seamTopRow >= 4 else { return nil }

        // The sleeve's cloth: everything connected to the probe on the outer side of the edge column.
        let isOutside = { (column: Int) in side == .imageLeft ? column < edgeColumn : column > edgeColumn }
        var isSleevePixel = [Bool](repeating: false, count: mask.pixels.count)
        var pending = [((seamTopRow + armpitRow) / 2) * mask.width + probeColumn]
        isSleevePixel[pending[0]] = true
        var sleevePixelCount = 0
        var pointSum = SIMD2<Double>(0, 0)
        while let index = pending.popLast() {
            sleevePixelCount += 1
            let column = index % mask.width, row = index / mask.width
            pointSum += SIMD2(Double(column), Double(row))
            for (neighborColumn, neighborRow) in [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
            where neighborColumn >= 0 && neighborColumn < mask.width && neighborRow >= 0 && neighborRow < mask.height && isOutside(neighborColumn) {
                let neighbor = neighborRow * mask.width + neighborColumn
                if !isSleevePixel[neighbor] && mask.pixels[neighbor] != 0 {
                    isSleevePixel[neighbor] = true
                    pending.append(neighbor)
                }
            }
        }
        guard sleevePixelCount >= 50 else { return nil }

        // The sleeve's axis runs from the seam's middle through its middle, and its opening is the far end along that axis.
        let seamTop = CGPoint(x: Double(edgeColumn), y: Double(seamTopRow)), seamBottom = CGPoint(x: Double(edgeColumn), y: Double(armpitRow))
        let seamCenter = SIMD2(Double(edgeColumn), Double(seamTopRow + armpitRow) / 2)
        let toTheMiddle = pointSum / Double(sleevePixelCount) - seamCenter
        guard simd_length(toTheMiddle) > 1 else { return nil }
        let axis = simd_normalize(toTheMiddle), across = SIMD2(-axis.y, axis.x)
        var farthest = 0.0
        for index in isSleevePixel.indices where isSleevePixel[index] {
            farthest = max(farthest, simd_dot(SIMD2(Double(index % mask.width), Double(index / mask.width)) - seamCenter, axis))
        }
        guard farthest > 2 else { return nil }
        // The opening's width is the sleeve's width over its last quarter, where a flat sleeve is about as wide as its cuff.
        var smallestAcross = Double.infinity, largestAcross = -Double.infinity
        for index in isSleevePixel.indices where isSleevePixel[index] {
            let offset = SIMD2(Double(index % mask.width), Double(index / mask.width)) - seamCenter
            guard simd_dot(offset, axis) >= 0.75 * farthest else { continue }
            smallestAcross = min(smallestAcross, simd_dot(offset, across))
            largestAcross = max(largestAcross, simd_dot(offset, across))
        }
        let openingCenter = seamCenter + axis * 0.95 * farthest + across * (smallestAcross + largestAcross) / 2
        let halfOpening = (largestAcross - smallestAcross + 1) / 2
        // The outer edge is the one the shoulder end of the seam lies on.
        let outerSide = simd_dot(SIMD2(Double(seamTop.x), Double(seamTop.y)) - seamCenter, across) >= 0 ? across : -across
        let openingOuter = openingCenter + outerSide * halfOpening, openingInner = openingCenter - outerSide * halfOpening
        return ShirtSleeveGeometry(
            side: side, seamTop: seamTop, seamBottom: seamBottom,
            openingOuter: CGPoint(x: openingOuter.x, y: openingOuter.y), openingInner: CGPoint(x: openingInner.x, y: openingInner.y),
            isSleevePixel: isSleevePixel
        )
    }
}

/// What the garment's cutout says about its own shape, from the rules the spike found on flat-lay photos.
nonisolated struct ShirtGarmentMeasurements: Equatable, Sendable {
    /// Where the garment's body (the torso without its sleeves) sits: top left, top right, bottom right, bottom left.
    let torsoCorners: RoomArtCorners
    /// The front of the neck hole on the center line, where the garment's neckline meets the learner's own.
    let frontNeckPoint: CGPoint
    /// False when the cutout shows no neck hole, such as a photo that shows the shirt's back collar as cloth. The point is
    /// then the shoulder line's center, and the renderer does not use it to line up the necklines.
    let frontNeckWasFound: Bool
    /// The first and last row of the garment, and the torso's left and right columns, for the hem band.
    let topRow: Int
    let bottomRow: Int
    let torsoLeftColumn: Int
    let torsoRightColumn: Int
    /// The sleeves, image left first, each nil when the cutout has no sleeve on that side apart from its torso.
    let imageLeftSleeve: ShirtSleeveGeometry?
    let imageRightSleeve: ShirtSleeveGeometry?

    /// Below the sleeves, 60 percent of the way down, the cutout is only the torso, so its width there is the torso's.
    static let torsoWidthRowShare = 0.6
    /// The shoulder line sits 10 percent of the garment's height below its top.
    static let shoulderLineRowShare = 0.10
    /// A neck hole starts above this share of the garment's height. A gap lower down is a print or a pocket, not a neck.
    static let lowestNeckHoleRowShare = 0.35

    /// Nil when the mask is empty or its torso row has no garment.
    init?(mask: ShirtCutoutMask) {
        let rowHasGarment = { (row: Int) in (0..<mask.width).contains { mask.pixels[row * mask.width + $0] != 0 } }
        guard let topRow = (0..<mask.height).first(where: rowHasGarment), let bottomRow = (0..<mask.height).last(where: rowHasGarment) else { return nil }
        let garmentHeight = Double(bottomRow - topRow)
        guard garmentHeight > 8 else { return nil }
        let torsoRow = Int(Double(topRow) + Self.torsoWidthRowShare * garmentHeight)
        let torsoColumns = (0..<mask.width).filter { mask.pixels[torsoRow * mask.width + $0] != 0 }
        guard let torsoLeftColumn = torsoColumns.first, let torsoRightColumn = torsoColumns.last, torsoRightColumn - torsoLeftColumn >= 8 else { return nil }
        let shoulderRow = Double(topRow) + Self.shoulderLineRowShare * garmentHeight
        let left = Double(torsoLeftColumn), right = Double(torsoRightColumn), bottom = Double(bottomRow)
        torsoCorners = RoomArtCorners(
            topLeft: CGPoint(x: left, y: shoulderRow), topRight: CGPoint(x: right, y: shoulderRow),
            bottomRight: CGPoint(x: right, y: bottom), bottomLeft: CGPoint(x: left, y: bottom)
        )
        self.topRow = topRow
        self.bottomRow = bottomRow
        self.torsoLeftColumn = torsoLeftColumn
        self.torsoRightColumn = torsoRightColumn
        let torsoWidth = torsoRightColumn - torsoLeftColumn
        imageLeftSleeve = ShirtSleeveGeometry.detect(side: .imageLeft, mask: mask, edgeColumn: torsoLeftColumn, torsoWidth: torsoWidth, topRow: topRow, lowestArmpitRow: torsoRow)
        imageRightSleeve = ShirtSleeveGeometry.detect(side: .imageRight, mask: mask, edgeColumn: torsoRightColumn, torsoWidth: torsoWidth, topRow: topRow, lowestArmpitRow: torsoRow)

        // Down the center line: the back of the collar, then the neck hole, then the front of the shirt, where the hole ends.
        let centerColumn = (torsoLeftColumn + torsoRightColumn) / 2
        let isGarment = { (row: Int) in mask.pixels[row * mask.width + centerColumn] != 0 }
        let firstClothRow = (topRow...bottomRow).first(where: isGarment)
        let holeStartRow = firstClothRow.flatMap { first in (first...bottomRow).first { !isGarment($0) } }
        let frontNeckRow = holeStartRow.flatMap { holeStart in (holeStart...bottomRow).first(where: isGarment) }
        if let frontNeckRow, Double(frontNeckRow - topRow) <= Self.lowestNeckHoleRowShare * garmentHeight {
            frontNeckPoint = CGPoint(x: Double(centerColumn), y: Double(frontNeckRow))
            frontNeckWasFound = true
        } else {
            frontNeckPoint = CGPoint(x: Double(centerColumn), y: shoulderRow)
            frontNeckWasFound = false
        }
    }
}

/// One sleeve of the garment as the renderer draws it on its own: its pixels and where they lie in the working photo.
///
/// On a hanging arm a sleeve's seam runs down the arm while its opening runs across it, where on the flat lay the two are
/// nearly parallel, so no single map from the photo to the arm keeps both. The sleeve is split along the diagonal from the
/// seam's top to the underside of the opening, and the renderer maps each half with its own affine transform: the outer half
/// by its triangle (seam top, opening outer, opening inner) and the inner half by its own (seam top, opening inner, seam
/// bottom). The two maps agree on the diagonal, so the halves meet with no seam of their own.
nonisolated struct ShirtGarmentSleeve: @unchecked Sendable {
    // @unchecked because CIImage is immutable, so sharing one across queues is safe.

    /// The outer half reaches this many photo pixels past the diagonal, under the inner half, so no hairline gap shows.
    static let halvesOverlapPixels = 1.5

    let geometry: ShirtSleeveGeometry
    /// The sleeve's outer and inner halves, each premultiplied RGBA with everything else clear, cropped to `boundingBox` and
    /// moved to the origin.
    let outerHalf: CIImage
    let innerHalf: CIImage
    /// Where the halves lie in the working photo, top left origin, y down.
    let boundingBox: CGRect
}

/// The garment as the renderer draws it: its cutout, the shirt's own geometry, and the colors the renderer needs.
/// A garment never changes, so everything the renderer can work out once is worked out here.
nonisolated struct ShirtGarment: @unchecked Sendable {
    // @unchecked because CIImage is immutable, so sharing one across queues is safe.

    /// The longest side the working photo is scaled to. The garment is drawn about 400 to 900 camera pixels wide, so more
    /// than this would only slow the warp down.
    static let longestWorkingSide = 1024
    /// A sleeve's cloth reaches this share of the torso's width inside the torso's edge, under the torso, so the two never
    /// show a gap where they meet on the body.
    static let sleeveTuckShareOfTheTorsoWidth = 0.03

    /// The garment's pixels with the background cut away: premultiplied RGBA, extent `(0, 0, size)`, Core Image's y up.
    let cutout: CIImage
    let size: CGSize
    /// Where the garment's torso sits in the cutout, top left origin, y down.
    let torsoCorners: RoomArtCorners
    /// The front of the neck hole, top left origin, y down.
    let frontNeckPoint: CGPoint
    let frontNeckWasFound: Bool
    /// The garment's base color, the mean in linear light of a print-free band near the hem. It fills the learner's old
    /// shirt where the garment's outline does not reach, at the waist, under the arms, and on the tops of the shoulders.
    let baseColor: ShirtRGB
    /// The product photo's white in linear light, per channel: its background, raised to the garment's own 98th percentile
    /// of luminance when the garment is brighter (a white shirt on a light gray sweep). The photo over this is the garment's
    /// albedo, so a cream shirt stays cream and is not turned white, and the photo's lighting does not come along.
    let photoWhite: SIMD3<Float>
    /// The cutout without its sleeves, and the two sleeves apart, image left first, so the renderer can lay each sleeve along
    /// its arm. Nil when the cutout does not have both sleeves apart from its torso; the whole cutout is drawn then.
    let torsoWithoutSleeves: CIImage?
    let sleeves: [ShirtGarmentSleeve]

    /// The garment from a product photo and where the item sits in it (`itemCorners`, the page reader's answer, in the
    /// photo's pixels): the photo is cropped to the corners with a margin, scaled down, and cut out with subject lifting.
    /// Nil when no garment is found. Slow (about 200 ms to 2 seconds, mostly Vision), so call it off the main actor. It is
    /// meant for flat lay photos: a photo of the shirt on a model has the model in the cutout.
    static func make(productPhoto: CGImage, itemCorners: RoomArtCorners) -> ShirtGarment? {
        let corners = itemCorners.clockwiseFromTopLeft
        let photoBounds = CGRect(x: 0, y: 0, width: productPhoto.width, height: productPhoto.height)
        let cornersBox = CGRect(
            x: corners.map(\.x).min() ?? 0, y: corners.map(\.y).min() ?? 0,
            width: (corners.map(\.x).max() ?? 0) - (corners.map(\.x).min() ?? 0), height: (corners.map(\.y).max() ?? 0) - (corners.map(\.y).min() ?? 0)
        )
        let cropBox = cornersBox.insetBy(dx: -cornersBox.width * 0.05, dy: -cornersBox.height * 0.05).intersection(photoBounds).integral
        guard cropBox.width >= 32, cropBox.height >= 32, let croppedPhoto = productPhoto.cropping(to: cropBox) else { return nil }
        guard let workingPhoto = scaledDown(croppedPhoto, toLongestSide: longestWorkingSide), let cutoutMask = ShirtCutoutMask.lifted(from: workingPhoto) else { return nil }
        return make(workingPhoto: workingPhoto, cutoutMask: cutoutMask)
    }

    /// The garment from a working photo and its cutout, which must be the same size. Nil when the cutout is under 4 percent
    /// of the photo, or has no torso.
    static func make(workingPhoto: CGImage, cutoutMask suppliedMask: ShirtCutoutMask) -> ShirtGarment? {
        guard suppliedMask.width == workingPhoto.width, suppliedMask.height == workingPhoto.height else { return nil }
        let cutoutMask = suppliedMask.keepingTheLargestPiece()
        let garmentPixelCount = cutoutMask.pixels.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        guard Double(garmentPixelCount) >= 0.04 * Double(cutoutMask.pixels.count), let measurements = ShirtGarmentMeasurements(mask: cutoutMask),
              let photoPixels = rgbaPixels(of: workingPhoto) else { return nil }
        let width = workingPhoto.width, height = workingPhoto.height

        // The hem band: from 12 to 3 percent of the garment's height above its bottom, inside the torso's columns. A print
        // rarely reaches the hem, so its median is the cloth's own color.
        let garmentHeight = Double(measurements.bottomRow - measurements.topRow)
        let bandTopRow = Int(Double(measurements.bottomRow) - 0.12 * garmentHeight), bandBottomRow = Int(Double(measurements.bottomRow) - 0.03 * garmentHeight)
        var bandChannels: [[UInt8]] = [[], [], []]
        for row in bandTopRow...max(bandTopRow, bandBottomRow) {
            for column in measurements.torsoLeftColumn...measurements.torsoRightColumn where cutoutMask.pixels[row * width + column] != 0 {
                for channel in 0..<3 { bandChannels[channel].append(photoPixels[(row * width + column) * 4 + channel]) }
            }
        }
        var garmentChannelSum = 0.0
        var garmentLuminances: [Float] = []
        var backgroundChannels: [[UInt8]] = [[], [], []]
        for pixelIndex in cutoutMask.pixels.indices {
            if cutoutMask.pixels[pixelIndex] != 0 {
                for channel in 0..<3 { garmentChannelSum += Double(photoPixels[pixelIndex * 4 + channel]) }
                garmentLuminances.append(linearLuminance(of: photoPixels, at: pixelIndex))
            } else {
                for channel in 0..<3 { backgroundChannels[channel].append(photoPixels[pixelIndex * 4 + channel]) }
            }
        }
        // A hem band with no cloth in it (a cutout cut off above its hem) takes the garment's mean color instead.
        let meanBrightness = Float(garmentChannelSum / (3 * 255 * Double(garmentPixelCount)))
        // The band's mean in linear light, encoded back: fine stripes or a heather seen from a step away blend to the
        // mean of their light, where a median would pick one of the stripes.
        let baseChannels = bandChannels.map { channelValues -> Float in
            guard !channelValues.isEmpty else { return meanBrightness }
            let meanLinearValue = channelValues.reduce(Float(0)) { $0 + ShirtColorMath.linearValueOfEachByte[Int($1)] } / Float(channelValues.count)
            return meanLinearValue <= 0.0031308 ? meanLinearValue * 12.92 : 1.055 * pow(meanLinearValue, 1 / 2.4) - 0.055
        }
        let photoWhite = photoWhite(backgroundChannels: backgroundChannels, garmentLuminances: garmentLuminances)

        // The drawn garment's edge is the cutout pulled in and softened (`featheredEdgeAlpha`), and its outer pixels take the
        // colors of the clean cloth just inside them, so the photo's background never shows as a light fringe.
        let edgeAlpha = cutoutMask.featheredEdgeAlpha()
        let cleanedPixels = cutoutMask.colorsWithTheBackgroundBleedRemoved(from: photoPixels)
        guard let cutoutImage = premultipliedImage(colors: cleanedPixels, alpha: edgeAlpha, width: width, height: height) else { return nil }

        // The sleeves apart from the torso, when the cutout has both. Each sleeve keeps a narrow strip of the torso along its
        // seam, which the torso covers, and the torso fades out over 3 pixels at the seam, so the two overlap with no gap.
        var torsoWithoutSleeves: CIImage?
        var sleeves: [ShirtGarmentSleeve] = []
        if let imageLeftSleeve = measurements.imageLeftSleeve, let imageRightSleeve = measurements.imageRightSleeve {
            let tuckColumns = max(2, Int(sleeveTuckShareOfTheTorsoWidth * Double(measurements.torsoRightColumn - measurements.torsoLeftColumn)))
            var torsoAlpha = edgeAlpha
            for geometry in [imageLeftSleeve, imageRightSleeve] {
                let edgeColumn = Int(geometry.seamTop.x), inward = geometry.side == .imageLeft ? 1 : -1
                var sleeveAlpha = [UInt8](repeating: 0, count: edgeAlpha.count)
                var boxLeft = width, boxRight = -1, boxTop = height, boxBottom = -1
                func include(column: Int, row: Int) {
                    boxLeft = min(boxLeft, column); boxRight = max(boxRight, column); boxTop = min(boxTop, row); boxBottom = max(boxBottom, row)
                }
                for index in geometry.isSleevePixel.indices where geometry.isSleevePixel[index] {
                    sleeveAlpha[index] = edgeAlpha[index]
                    torsoAlpha[index] = 0
                    include(column: index % width, row: index / width)
                }
                for row in Int(geometry.seamTop.y)...Int(geometry.seamBottom.y) {
                    for step in 0...tuckColumns {
                        let column = edgeColumn + inward * step
                        guard column >= 0, column < width else { continue }
                        let index = row * width + column
                        sleeveAlpha[index] = edgeAlpha[index]
                        include(column: column, row: row)
                        if step < 3 { torsoAlpha[index] = UInt8(Int(torsoAlpha[index]) * (step + 1) / 4) }
                    }
                }
                // The halves, split along the diagonal from the seam's top to the opening's underside. Each pixel's distance from
                // the diagonal is positive on the outer side.
                let diagonalStart = SIMD2(Double(geometry.seamTop.x), Double(geometry.seamTop.y))
                let diagonal = SIMD2(Double(geometry.openingInner.x), Double(geometry.openingInner.y)) - diagonalStart
                guard simd_length(diagonal) > 1 else { continue }
                var acrossTheDiagonal = SIMD2(-diagonal.y, diagonal.x) / simd_length(diagonal)
                if simd_dot(SIMD2(Double(geometry.openingOuter.x), Double(geometry.openingOuter.y)) - diagonalStart, acrossTheDiagonal) < 0 { acrossTheDiagonal = -acrossTheDiagonal }
                var outerAlpha = [UInt8](repeating: 0, count: sleeveAlpha.count), innerAlpha = [UInt8](repeating: 0, count: sleeveAlpha.count)
                for index in sleeveAlpha.indices where sleeveAlpha[index] != 0 {
                    let distance = simd_dot(SIMD2(Double(index % width), Double(index / width)) - diagonalStart, acrossTheDiagonal)
                    if distance >= -ShirtGarmentSleeve.halvesOverlapPixels { outerAlpha[index] = sleeveAlpha[index] }
                    if distance <= 0 { innerAlpha[index] = sleeveAlpha[index] }
                }
                guard boxRight >= boxLeft, boxBottom >= boxTop,
                      let outerImage = premultipliedImage(colors: cleanedPixels, alpha: outerAlpha, width: width, height: height),
                      let innerImage = premultipliedImage(colors: cleanedPixels, alpha: innerAlpha, width: width, height: height) else { continue }
                let boundingBox = CGRect(x: boxLeft, y: boxTop, width: boxRight - boxLeft + 1, height: boxBottom - boxTop + 1)
                // Core Image's y grows up, so the box's top row is the image's top edge.
                let boxInCoreImage = CGRect(x: boundingBox.minX, y: Double(height) - boundingBox.maxY, width: boundingBox.width, height: boundingBox.height)
                func croppedToTheBox(_ image: CIImage) -> CIImage {
                    image.cropped(to: boxInCoreImage).transformed(by: CGAffineTransform(translationX: -boxInCoreImage.minX, y: -boxInCoreImage.minY))
                }
                sleeves.append(ShirtGarmentSleeve(geometry: geometry, outerHalf: croppedToTheBox(outerImage), innerHalf: croppedToTheBox(innerImage), boundingBox: boundingBox))
            }
            if sleeves.count == 2 {
                torsoWithoutSleeves = premultipliedImage(colors: cleanedPixels, alpha: torsoAlpha, width: width, height: height)
            } else {
                sleeves = []
            }
        }

        return ShirtGarment(
            cutout: cutoutImage, size: CGSize(width: width, height: height),
            torsoCorners: measurements.torsoCorners, frontNeckPoint: measurements.frontNeckPoint, frontNeckWasFound: measurements.frontNeckWasFound,
            baseColor: ShirtRGB(red: baseChannels[0], green: baseChannels[1], blue: baseChannels[2]),
            photoWhite: photoWhite, torsoWithoutSleeves: torsoWithoutSleeves, sleeves: torsoWithoutSleeves == nil ? [] : sleeves
        )
    }

    /// The photo's white from its background's median color and the garment's luminances, both as described on `photoWhite`.
    /// A cutout that fills the whole photo has no background, and then the garment's own brightest cloth is the white.
    static func photoWhite(backgroundChannels: [[UInt8]], garmentLuminances: [Float]) -> SIMD3<Float> {
        let brightestGarmentLuminance = garmentLuminances.isEmpty ? 1 : max(garmentLuminances.sorted()[min(garmentLuminances.count - 1, Int(0.98 * Double(garmentLuminances.count)))], 0.05)
        guard backgroundChannels.allSatisfy({ !$0.isEmpty }) else { return SIMD3(repeating: brightestGarmentLuminance) }
        let background = SIMD3(
            linearValueOfEachByte[Int(backgroundChannels[0].sorted()[backgroundChannels[0].count / 2])],
            linearValueOfEachByte[Int(backgroundChannels[1].sorted()[backgroundChannels[1].count / 2])],
            linearValueOfEachByte[Int(backgroundChannels[2].sorted()[backgroundChannels[2].count / 2])]
        )
        let backgroundLuminance = max(0.2126 * background.x + 0.7152 * background.y + 0.0722 * background.z, 0.05)
        return background / backgroundLuminance * max(backgroundLuminance, brightestGarmentLuminance)
    }

    private static let linearValueOfEachByte: [Float] = (0..<256).map { byte in
        let encoded = Float(byte) / 255
        return encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    private static func linearLuminance(of rgba: [UInt8], at pixelIndex: Int) -> Float {
        0.2126 * linearValueOfEachByte[Int(rgba[pixelIndex * 4])] + 0.7152 * linearValueOfEachByte[Int(rgba[pixelIndex * 4 + 1])] + 0.0722 * linearValueOfEachByte[Int(rgba[pixelIndex * 4 + 2])]
    }

    /// `colors` (tight RGBA rows) premultiplied by `alpha` as a Core Image image in sRGB.
    private static func premultipliedImage(colors: [UInt8], alpha: [UInt8], width: Int, height: Int) -> CIImage? {
        var premultipliedPixels = [UInt8](repeating: 0, count: colors.count)
        for pixelIndex in alpha.indices where alpha[pixelIndex] != 0 {
            let pixelAlpha = UInt16(alpha[pixelIndex])
            for channel in 0..<3 {
                premultipliedPixels[pixelIndex * 4 + channel] = UInt8((UInt16(colors[pixelIndex * 4 + channel]) * pixelAlpha + 127) / 255)
            }
            premultipliedPixels[pixelIndex * 4 + 3] = alpha[pixelIndex]
        }
        return cgImage(fromRGBAPixels: premultipliedPixels, width: width, height: height).map { CIImage(cgImage: $0) }
    }

    private static func scaledDown(_ image: CGImage, toLongestSide longestSide: Int) -> CGImage? {
        let scale = min(1, Double(longestSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded())), height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The image's pixels as tightly packed RGBA bytes in sRGB, the first row at the top.
    private static func rgbaPixels(of image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drewTheImage = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drewTheImage ? pixels : nil
    }

    private static func cgImage(fromRGBAPixels pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
