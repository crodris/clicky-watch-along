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
import Vision

// MARK: - The body's torso

/// One joint as the pose request reports it, with Vision's own coordinates: x and y from 0 to 1, y growing up.
nonisolated struct ShirtJointReading: Equatable, Sendable {
    let visionPoint: CGPoint
    let confidence: Float
}

/// The four joints the torso needs, each nil when the pose request did not report it. These are the person's own left and
/// right, which the torso sorts by where they land in the image.
nonisolated struct ShirtBodyJointReadings: Equatable, Sendable {
    let personLeftShoulder: ShirtJointReading?
    let personRightShoulder: ShirtJointReading?
    let personLeftHip: ShirtJointReading?
    let personRightHip: ShirtJointReading?
}

/// The shoulders and hips of the person in a camera frame, in camera pixels.
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

    var shoulderMidpoint: CGPoint { CGPoint(x: (imageLeftShoulder.x + imageRightShoulder.x) / 2, y: (imageLeftShoulder.y + imageRightShoulder.y) / 2) }
    var hipMidpoint: CGPoint { CGPoint(x: (imageLeftHip.x + imageRightHip.x) / 2, y: (imageLeftHip.y + imageRightHip.y) / 2) }
    var shoulderWidth: Double { hypot(imageRightShoulder.x - imageLeftShoulder.x, imageRightShoulder.y - imageLeftShoulder.y) }

    init(imageLeftShoulder: CGPoint, imageRightShoulder: CGPoint, imageLeftHip: CGPoint, imageRightHip: CGPoint, hipsWereEstimated: Bool, shouldersAreSeen: Bool) {
        self.imageLeftShoulder = imageLeftShoulder
        self.imageRightShoulder = imageRightShoulder
        self.imageLeftHip = imageLeftHip
        self.imageRightHip = imageRightHip
        self.hipsWereEstimated = hipsWereEstimated
        self.shouldersAreSeen = shouldersAreSeen
    }

    /// The torso of a pose request's observation, or nil when it has no shoulder joint at all.
    init?(observation: VNHumanBodyPoseObservation, frameSize: CGSize) {
        func reading(of jointName: VNHumanBodyPoseObservation.JointName) -> ShirtJointReading? {
            guard let recognizedPoint = try? observation.recognizedPoint(jointName) else { return nil }
            return ShirtJointReading(visionPoint: recognizedPoint.location, confidence: recognizedPoint.confidence)
        }
        let readings = ShirtBodyJointReadings(
            personLeftShoulder: reading(of: .leftShoulder), personRightShoulder: reading(of: .rightShoulder),
            personLeftHip: reading(of: .leftHip), personRightHip: reading(of: .rightHip)
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
        if isSeen(readings.personLeftHip), isSeen(readings.personRightHip), let personLeftHip = readings.personLeftHip, let personRightHip = readings.personRightHip {
            let hipsInImageOrder = [pixelPoint(personLeftHip), pixelPoint(personRightHip)].sorted { $0.x < $1.x }
            self.init(
                imageLeftShoulder: imageLeftShoulder, imageRightShoulder: imageRightShoulder,
                imageLeftHip: hipsInImageOrder[0], imageRightHip: hipsInImageOrder[1],
                hipsWereEstimated: false, shouldersAreSeen: shouldersAreSeen
            )
            return
        }
        // The body's down direction is across the shoulder line, toward the bottom of the image.
        var downDirection = CGPoint(x: -shoulderSpan.y / shoulderSpanLength, y: shoulderSpan.x / shoulderSpanLength)
        if downDirection.y < 0 { downDirection = CGPoint(x: -downDirection.x, y: -downDirection.y) }
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
            hipsWereEstimated: true, shouldersAreSeen: shouldersAreSeen
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
            hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: shouldersAreSeen
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

/// The garment as the renderer draws it: its cutout, the shirt's own geometry, and the two colors the renderer needs.
/// A garment never changes, so everything the renderer can work out once is worked out here.
nonisolated struct ShirtGarment: @unchecked Sendable {
    // @unchecked because CIImage is immutable, so sharing one across queues is safe.

    /// The longest side the working photo is scaled to. The garment is drawn about 400 to 900 camera pixels wide, so more
    /// than this would only slow the warp down.
    static let longestWorkingSide = 1024

    /// The garment's pixels with the background cut away: premultiplied RGBA, extent `(0, 0, size)`, Core Image's y up.
    let cutout: CIImage
    let size: CGSize
    /// Where the garment's torso sits in the cutout, top left origin, y down.
    let torsoCorners: RoomArtCorners
    /// The front of the neck hole, top left origin, y down.
    let frontNeckPoint: CGPoint
    let frontNeckWasFound: Bool
    /// The garment's base color, from a print-free band near the hem. It fills the learner's old shirt where the garment's
    /// outline does not reach, at the waist and under the arms.
    let baseColor: ShirtRGB
    /// The average of all three channels over the garment's pixels, from 0 to 1. The renderer matches the camera's exposure
    /// to it, since a product photo is lit flat and bright.
    let meanBrightness: Float

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

        // The hem band: from 12 to 3 percent of the garment's height above its bottom, inside the torso's columns. A print
        // rarely reaches the hem, so its median is the cloth's own color.
        let garmentHeight = Double(measurements.bottomRow - measurements.topRow)
        let bandTopRow = Int(Double(measurements.bottomRow) - 0.12 * garmentHeight), bandBottomRow = Int(Double(measurements.bottomRow) - 0.03 * garmentHeight)
        var bandChannels: [[UInt8]] = [[], [], []]
        for row in bandTopRow...max(bandTopRow, bandBottomRow) {
            for column in measurements.torsoLeftColumn...measurements.torsoRightColumn where cutoutMask.pixels[row * cutoutMask.width + column] != 0 {
                for channel in 0..<3 { bandChannels[channel].append(photoPixels[(row * cutoutMask.width + column) * 4 + channel]) }
            }
        }
        var garmentChannelSum = 0.0
        var premultipliedPixels = [UInt8](repeating: 0, count: photoPixels.count)
        for pixelIndex in cutoutMask.pixels.indices where cutoutMask.pixels[pixelIndex] != 0 {
            for channel in 0..<3 {
                premultipliedPixels[pixelIndex * 4 + channel] = photoPixels[pixelIndex * 4 + channel]
                garmentChannelSum += Double(photoPixels[pixelIndex * 4 + channel])
            }
            premultipliedPixels[pixelIndex * 4 + 3] = 255
        }
        let meanBrightness = Float(garmentChannelSum / (3 * 255 * Double(garmentPixelCount)))
        let baseChannels = bandChannels.map { channelValues -> Float in
            guard !channelValues.isEmpty else { return meanBrightness }
            return Float(channelValues.sorted()[channelValues.count / 2]) / 255
        }

        guard let cutoutImage = cgImage(fromRGBAPixels: premultipliedPixels, width: workingPhoto.width, height: workingPhoto.height) else { return nil }
        return ShirtGarment(
            cutout: CIImage(cgImage: cutoutImage), size: CGSize(width: workingPhoto.width, height: workingPhoto.height),
            torsoCorners: measurements.torsoCorners, frontNeckPoint: measurements.frontNeckPoint, frontNeckWasFound: measurements.frontNeckWasFound,
            baseColor: ShirtRGB(red: baseChannels[0], green: baseChannels[1], blue: baseChannels[2]), meanBrightness: meanBrightness
        )
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
