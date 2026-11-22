//
//  RoomArt.swift
//  leanring-buddy
//
//  "Show me how this would look in my room": Clicky reads the wall art on Chrome's front tab and its size from the page,
//  opens a live camera panel, and hangs the art on the learner's wall at its real size.
//
//  This file holds the pure parts: the Worker replies parsed into Swift types (`POST /room-art` reads the page, `POST
//  /room-wall` measures the wall with Depth Pro), the art's corners projected from the wall plane, the bare wall spot the
//  art goes to first, the wall's light, the phase state machine behind the panel, the clients, and the phrase that asks for
//  it. `RoomTracker` keeps the art on the wall, `RoomCamera` supplies the frames, and `RoomArtPreview` runs and draws it.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - The picture and the page

/// A JPEG of the largest picture in Chrome's front tab, captured from the screen. The page's corners are in its pixels.
nonisolated struct RoomArtPicture: Equatable, Sendable {
    let jpegData: Data
    let width: Int
    let height: Int
}

/// What Clicky sends `POST /room-art`: the page and its picture.
nonisolated struct RoomArtPageRequest: Equatable, Sendable {
    /// The Worker refuses a page title and page text over these many UTF-16 code units, so the app cuts them first.
    static let longestPageTitle = 500
    static let longestPageText = 30_000

    let pageURL: String
    let pageTitle: String
    let pageText: String
    let picture: RoomArtPicture

    init(pageURL: String, pageTitle: String, pageText: String, picture: RoomArtPicture) {
        self.pageURL = pageURL
        self.pageTitle = textCutToUTF16Count(pageTitle, longestUTF16Count: Self.longestPageTitle)
        self.pageText = textCutToUTF16Count(pageText, longestUTF16Count: Self.longestPageText)
        self.picture = picture
    }

    var json: JSONValue {
        .object([
            "pageURL": .string(pageURL),
            "pageTitle": .string(pageTitle),
            "pageText": .string(pageText),
            "picture": .object([
                "jpegBase64": .string(picture.jpegData.base64EncodedString()),
                "width": .number(Double(picture.width)),
                "height": .number(Double(picture.height)),
            ]),
        ])
    }
}

// MARK: - The page's reading

/// Four corners of a quadrilateral, in pixels with y growing down.
nonisolated struct RoomArtCorners: Equatable, Sendable {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    /// Top left, top right, bottom right, bottom left: the order every corner list in this feature uses.
    var clockwiseFromTopLeft: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    init(clockwiseFromTopLeft corners: [CGPoint]) {
        precondition(corners.count == 4, "A quadrilateral has four corners")
        self.init(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
    }

    /// The shoelace area, positive for any non-crossing quadrilateral in either winding.
    var area: Double {
        let points = clockwiseFromTopLeft
        let twiceSignedArea = points.indices.reduce(0.0) { total, index in
            let point = points[index], nextPoint = points[(index + 1) % points.count]
            return total + point.x * nextPoint.y - nextPoint.x * point.y
        }
        return abs(twiceSignedArea) / 2
    }
}

/// A size the store sells the art in.
nonisolated struct RoomArtSize: Equatable, Sendable {
    let label: String
    let widthCentimeters: Double
    let heightCentimeters: Double
}

/// What `POST /room-art` read from the page and its picture.
nonisolated enum RoomArtPageReading: Equatable, Sendable {
    case notWallArt(title: String)
    /// Wall art whose page text states no size, so Clicky says so instead of hanging a size the model guessed.
    case sizeNotOnThePage(title: String)
    case wallArt(RoomArtWallArtReading)
}

nonisolated struct RoomArtWallArtReading: Equatable, Sendable {
    let title: String
    let chosenSize: RoomArtSize
    let chosenSizeIncludesFrame: Bool
    let whyThisSize: String
    let otherSizes: [RoomArtSize]
    /// Where the art itself sits in the picture, so a photo of it in a room can be flattened to the art alone.
    let artworkCorners: RoomArtCorners
}

nonisolated struct RoomArtReplyError: Error, Equatable {
    let reason: String
}

/// Art under 1 cm or over 10 m on a side is a misread, not a size anyone hangs.
nonisolated private let sensibleArtCentimeters = 1.0...1_000.0

nonisolated private struct RoomArtSizeReply: Decodable {
    let label: String
    let widthCentimeters: Double
    let heightCentimeters: Double
}

nonisolated private struct RoomArtChosenSizeReply: Decodable {
    let label: String
    let widthCentimeters: Double
    let heightCentimeters: Double
    let includesFrame: Bool
}

nonisolated private struct RoomArtPointReply: Decodable {
    let x: Double
    let y: Double
}

nonisolated private struct RoomArtCornersReply: Decodable {
    let topLeft: RoomArtPointReply
    let topRight: RoomArtPointReply
    let bottomRight: RoomArtPointReply
    let bottomLeft: RoomArtPointReply
}

nonisolated private struct RoomArtReply: Decodable {
    let title: String
    let isWallArt: Bool
    let sizeFoundOnPage: Bool?
    let chosenSize: RoomArtChosenSizeReply?
    let whyThisSize: String?
    let otherSizes: [RoomArtSizeReply]?
    let artworkCorners: RoomArtCornersReply?
}

extension RoomArtPageReading {
    /// Parses the Worker's reply. A reply for wall art says whether the page states its size, and when it does, it needs a
    /// sensible size and corners that enclose part of the picture, which are clamped into it, since a model's corner can
    /// land a pixel or two outside. Sizes that are not sensible are dropped from the other sizes.
    nonisolated init(responseData: Data, pictureWidth: Int, pictureHeight: Int) throws {
        let reply: RoomArtReply
        do {
            reply = try JSONDecoder().decode(RoomArtReply.self, from: responseData)
        } catch {
            throw RoomArtReplyError(reason: "the reply is not the room-art shape")
        }
        guard reply.isWallArt else {
            self = .notWallArt(title: reply.title)
            return
        }
        guard let sizeFoundOnPage = reply.sizeFoundOnPage else {
            throw RoomArtReplyError(reason: "sizeFoundOnPage is missing")
        }
        guard sizeFoundOnPage else {
            self = .sizeNotOnThePage(title: reply.title)
            return
        }
        guard let chosenSize = reply.chosenSize,
              sensibleArtCentimeters.contains(chosenSize.widthCentimeters),
              sensibleArtCentimeters.contains(chosenSize.heightCentimeters),
              !chosenSize.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomArtReplyError(reason: "chosenSize needs a label and a width and height from 1 to 1000 cm")
        }
        guard let cornersReply = reply.artworkCorners else {
            throw RoomArtReplyError(reason: "artworkCorners is missing")
        }
        func pointInThePicture(_ pointReply: RoomArtPointReply) throws -> CGPoint {
            guard pointReply.x.isFinite, pointReply.y.isFinite else { throw RoomArtReplyError(reason: "a corner is not a number") }
            return CGPoint(x: min(max(pointReply.x, 0), Double(pictureWidth)), y: min(max(pointReply.y, 0), Double(pictureHeight)))
        }
        let corners = RoomArtCorners(
            topLeft: try pointInThePicture(cornersReply.topLeft),
            topRight: try pointInThePicture(cornersReply.topRight),
            bottomRight: try pointInThePicture(cornersReply.bottomRight),
            bottomLeft: try pointInThePicture(cornersReply.bottomLeft)
        )
        // A sliver is a misread: real art covers at least a hundredth of its own product photo.
        guard corners.area >= Double(pictureWidth * pictureHeight) / 100 else {
            throw RoomArtReplyError(reason: "artworkCorners enclose almost none of the picture")
        }
        self = .wallArt(RoomArtWallArtReading(
            title: reply.title,
            chosenSize: RoomArtSize(label: chosenSize.label, widthCentimeters: chosenSize.widthCentimeters, heightCentimeters: chosenSize.heightCentimeters),
            chosenSizeIncludesFrame: chosenSize.includesFrame,
            whyThisSize: reply.whyThisSize ?? "",
            otherSizes: (reply.otherSizes ?? [])
                .filter { sensibleArtCentimeters.contains($0.widthCentimeters) && sensibleArtCentimeters.contains($0.heightCentimeters) }
                .map { RoomArtSize(label: $0.label, widthCentimeters: $0.widthCentimeters, heightCentimeters: $0.heightCentimeters) },
            artworkCorners: corners
        ))
    }
}

// MARK: - The artwork

/// The art as Clicky hangs it: its real size and the picture flattened to the art alone.
nonisolated struct RoomArtwork: Equatable, @unchecked Sendable {
    let title: String
    let widthMeters: Double
    let heightMeters: Double
    let includesFrame: Bool
    /// Front on, cropped to the art, with the size's shape.
    let flattenedImage: CGImage

    /// The size Clicky says and shows, such as "16 by 20 inches", from the measured numbers. The page's own label is free
    /// text a page wrote, so it stays in the log.
    var sizeInWords: String {
        roomArtSizeInInches(widthCentimeters: widthMeters * 100, heightCentimeters: heightMeters * 100)
    }
}

/// A size in inches rounded to the nearest half inch, width first: "16 by 20 inches", or "8.5 by 11 inches".
nonisolated func roomArtSizeInInches(widthCentimeters: Double, heightCentimeters: Double) -> String {
    func inchesInWords(_ centimeters: Double) -> String {
        let halfInches = (centimeters / 2.54 * 2).rounded()
        return halfInches.truncatingRemainder(dividingBy: 2) == 0 ? String(Int(halfInches / 2)) : String(format: "%.1f", halfInches / 2)
    }
    return "\(inchesInWords(widthCentimeters)) by \(inchesInWords(heightCentimeters)) inches"
}

/// The longer side of a flattened artwork, in pixels: sharp at any size it lands on the wall in a 1280 by 720 frame.
nonisolated let flattenedArtworkLongestSide = 1200

/// Cuts the art out of its product photo along its four corners and straightens it front on, at the chosen size's shape.
/// Nil when Core Image cannot render it.
nonisolated func flattenedArtwork(picture: CGImage, corners: RoomArtCorners, size: RoomArtSize, context: CIContext) -> CGImage? {
    let pictureHeight = Double(picture.height)
    // Core Image's y grows up from the bottom, so each corner's y is measured from the bottom.
    func vector(_ point: CGPoint) -> CIVector { CIVector(x: point.x, y: pictureHeight - point.y) }
    guard let perspectiveCorrection = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
    perspectiveCorrection.setValue(CIImage(cgImage: picture), forKey: kCIInputImageKey)
    perspectiveCorrection.setValue(vector(corners.topLeft), forKey: "inputTopLeft")
    perspectiveCorrection.setValue(vector(corners.topRight), forKey: "inputTopRight")
    perspectiveCorrection.setValue(vector(corners.bottomRight), forKey: "inputBottomRight")
    perspectiveCorrection.setValue(vector(corners.bottomLeft), forKey: "inputBottomLeft")
    guard let straightened = perspectiveCorrection.outputImage, straightened.extent.width >= 1, straightened.extent.height >= 1 else { return nil }

    let aspectRatio = size.widthCentimeters / size.heightCentimeters
    let longestSide = Double(flattenedArtworkLongestSide)
    let targetWidth = aspectRatio >= 1 ? longestSide : (longestSide * aspectRatio).rounded()
    let targetHeight = aspectRatio >= 1 ? (longestSide / aspectRatio).rounded() : longestSide
    let scaled = straightened
        .transformed(by: CGAffineTransform(translationX: -straightened.extent.minX, y: -straightened.extent.minY))
        .transformed(by: CGAffineTransform(scaleX: targetWidth / straightened.extent.width, y: targetHeight / straightened.extent.height))
    return context.createCGImage(scaled, from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
}

// MARK: - The wall

/// The wall plane where the art hangs, from `POST /room-wall`, in the keyframe camera's space (meters, x right, y down, z
/// forward). `right` runs along the wall toward the image's right and `up` along the wall toward the image's top.
nonisolated struct WallPlane: Equatable, Sendable {
    let center: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let focalLengthPixels: Double
    let principalPoint: SIMD2<Double>
    let distanceMeters: Double
    let wallAngleDegrees: Double
    let planeInlierShare: Double

    /// The art's corners in the keyframe, in camera pixels: the art centered on `center`, `widthMeters` along `right` and
    /// `heightMeters` along `up`, projected through the pinhole. Nil when a corner is not in front of the camera.
    func keyframeCorners(widthMeters: Double, heightMeters: Double) -> RoomArtCorners? {
        let halfWidth = widthMeters / 2, halfHeight = heightMeters / 2
        let cornerDirections: [(alongRight: Double, alongUp: Double)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]
        var projectedCorners: [CGPoint] = []
        for direction in cornerDirections {
            let point = center + right * (halfWidth * direction.alongRight) + up * (halfHeight * direction.alongUp)
            guard point.z > 0.01 else { return nil }
            projectedCorners.append(CGPoint(
                x: point.x * focalLengthPixels / point.z + principalPoint.x,
                y: point.y * focalLengthPixels / point.z + principalPoint.y
            ))
        }
        return RoomArtCorners(clockwiseFromTopLeft: projectedCorners)
    }
}

nonisolated private struct RoomWallReply: Decodable {
    let center: [Double]
    let right: [Double]
    let up: [Double]
    let focalPx: Double
    let principal: [Double]
    let distanceMeters: Double
    let wallAngleDegrees: Double
    let planeInlierShare: Double
}

extension WallPlane {
    /// Parses the Worker's reply. The wall must be in front of the camera, the focal length positive, and `right` and `up`
    /// real directions, which are made unit length, so a slightly off reply still hangs the art at its true size.
    nonisolated init(responseData: Data) throws {
        let reply: RoomWallReply
        do {
            reply = try JSONDecoder().decode(RoomWallReply.self, from: responseData)
        } catch {
            throw RoomArtReplyError(reason: "the reply is not the room-wall shape")
        }
        func vector3(_ values: [Double], named name: String) throws -> SIMD3<Double> {
            guard values.count == 3, values.allSatisfy(\.isFinite) else { throw RoomArtReplyError(reason: "\(name) must be 3 numbers") }
            return SIMD3(values[0], values[1], values[2])
        }
        let center = try vector3(reply.center, named: "center")
        let right = try vector3(reply.right, named: "right")
        let up = try vector3(reply.up, named: "up")
        guard center.z > 0 else { throw RoomArtReplyError(reason: "the wall must be in front of the camera") }
        guard simd_length(right) > 1e-6, simd_length(up) > 1e-6 else { throw RoomArtReplyError(reason: "right and up must be directions") }
        guard reply.focalPx.isFinite, reply.focalPx > 0 else { throw RoomArtReplyError(reason: "focalPx must be positive") }
        guard reply.principal.count == 2, reply.principal.allSatisfy(\.isFinite) else { throw RoomArtReplyError(reason: "principal must be 2 numbers") }
        self.init(
            center: center,
            right: simd_normalize(right),
            up: simd_normalize(up),
            focalLengthPixels: reply.focalPx,
            principalPoint: SIMD2(reply.principal[0], reply.principal[1]),
            distanceMeters: reply.distanceMeters,
            wallAngleDegrees: reply.wallAngleDegrees,
            planeInlierShare: reply.planeInlierShare
        )
    }
}

/// What Clicky sends `POST /room-wall`: the keyframe, the person in it, and the spot on the wall the art centers on.
nonisolated struct RoomWallRequest: Equatable, Sendable {
    let keyframeJPEGData: Data
    let personMaskPNGData: Data
    /// In keyframe pixels.
    let anchor: CGPoint

    var json: JSONValue {
        .object([
            "jpegBase64": .string(keyframeJPEGData.base64EncodedString()),
            "maskPngBase64": .string(personMaskPNGData.base64EncodedString()),
            "anchor": .object(["u": .number(anchor.x), "v": .number(anchor.y)]),
        ])
    }
}

// MARK: - Where the art goes first

/// The spot of the frame with the least texture, away from the person, in the upper part of the frame where art hangs, and
/// far enough from the edges for the art to fit, in the image's pixels. `grayscale` is the frame at the track size and
/// `roomMask` is 0 on the person and 1 on the room, at the same size.
nonisolated func bareWallSpot(grayscale: RoomGrayscaleImage, roomMask: [Float]) -> CGPoint {
    let width = grayscale.width, height = grayscale.height
    let pixels = grayscale.pixels
    // The Sobel gradient's size at each pixel.
    var texture = [Float](repeating: 0, count: width * height)
    if width >= 3 && height >= 3 {
        for row in 1..<(height - 1) {
            for column in 1..<(width - 1) {
                let index = row * width + column
                let alongX = (pixels[index - width + 1] + 2 * pixels[index + 1] + pixels[index + width + 1])
                    - (pixels[index - width - 1] + 2 * pixels[index - 1] + pixels[index + width - 1])
                let alongY = (pixels[index + width - 1] + 2 * pixels[index + width] + pixels[index + width + 1])
                    - (pixels[index - width - 1] + 2 * pixels[index - width] + pixels[index - width + 1])
                texture[index] = (alongX * alongX + alongY * alongY).squareRoot()
            }
        }
    }
    // A pixel within 15 of the person counts as the most texture there is, so the spot stays off them.
    let personNearby = grownSquare(roomMask.map { $0 < 0.5 }, width: width, height: height, reach: 15)
    for index in texture.indices where personNearby[index] {
        texture[index] = 1_000
    }

    // A summed table, so each window's total is four lookups.
    var summed = [Double](repeating: 0, count: (width + 1) * (height + 1))
    for row in 0..<height {
        var rowTotal = 0.0
        for column in 0..<width {
            rowTotal += Double(texture[row * width + column])
            summed[(row + 1) * (width + 1) + column + 1] = summed[row * (width + 1) + column + 1] + rowTotal
        }
    }
    func windowTotal(left: Int, top: Int, right: Int, bottom: Int) -> Double {
        let left = max(0, left), top = max(0, top), right = min(width, right), bottom = min(height, bottom)
        return summed[bottom * (width + 1) + right] - summed[top * (width + 1) + right]
            - summed[bottom * (width + 1) + left] + summed[top * (width + 1) + left]
    }

    let windowWidth = Int((Double(width) * 0.24).rounded()), windowHeight = Int((Double(height) * 0.3).rounded())
    var bestSpot = CGPoint(x: Double(width) / 2, y: Double(height) / 3)
    var bestScore = Double.infinity
    let firstRow = Int((Double(height) * 0.25).rounded()), lastRow = Int((Double(height) * 0.55).rounded())
    let firstColumn = (windowWidth + 1) / 2 + 4, lastColumn = width - windowWidth / 2 - 4
    guard firstColumn <= lastColumn else { return bestSpot }
    for row in stride(from: firstRow, through: lastRow, by: 4) {
        for column in stride(from: firstColumn, through: lastColumn, by: 4) {
            let score = windowTotal(left: column - windowWidth / 2, top: row - windowHeight / 2, right: column + (windowWidth + 1) / 2, bottom: row + (windowHeight + 1) / 2)
            if score < bestScore {
                bestScore = score
                bestSpot = CGPoint(x: column, y: row)
            }
        }
    }
    return bestSpot
}

/// Whether each pixel is within `reach` pixels (a square) of a marked pixel, by a row pass and a column pass.
nonisolated private func grownSquare(_ marked: [Bool], width: Int, height: Int, reach: Int) -> [Bool] {
    var grownAlongRows = [Bool](repeating: false, count: width * height)
    for row in 0..<height {
        var lastMarkedColumn = -Int.max / 2
        for column in 0..<width {
            if marked[row * width + column] { lastMarkedColumn = column }
            if column - lastMarkedColumn <= reach { grownAlongRows[row * width + column] = true }
        }
        lastMarkedColumn = Int.max / 2
        for column in stride(from: width - 1, through: 0, by: -1) {
            if marked[row * width + column] { lastMarkedColumn = column }
            if lastMarkedColumn - column <= reach { grownAlongRows[row * width + column] = true }
        }
    }
    var grown = [Bool](repeating: false, count: width * height)
    for column in 0..<width {
        var lastMarkedRow = -Int.max / 2
        for row in 0..<height {
            if grownAlongRows[row * width + column] { lastMarkedRow = row }
            if row - lastMarkedRow <= reach { grown[row * width + column] = true }
        }
        lastMarkedRow = Int.max / 2
        for row in stride(from: height - 1, through: 0, by: -1) {
            if grownAlongRows[row * width + column] { lastMarkedRow = row }
            if lastMarkedRow - row <= reach { grown[row * width + column] = true }
        }
    }
    return grown
}

// MARK: - The wall's light

/// The gains that give the art the wall's light: its white balance and its brightness, from the wall's average color around
/// the spot (each channel 0 to 1). The brightest channel sets the brightness, a little over it and kept from 0.5 to 1.05,
/// and each channel keeps its share of the brightest.
nonisolated struct RoomArtWallLight: Equatable, Sendable {
    let redGain: Double
    let greenGain: Double
    let blueGain: Double

    static let neutral = RoomArtWallLight(redGain: 1, greenGain: 1, blueGain: 1)

    init(redGain: Double, greenGain: Double, blueGain: Double) {
        self.redGain = redGain
        self.greenGain = greenGain
        self.blueGain = blueGain
    }

    init(wallRed: Double, wallGreen: Double, wallBlue: Double) {
        let brightestChannel = max(wallRed, wallGreen, wallBlue)
        guard brightestChannel > 0 else {
            self = .neutral
            return
        }
        let brightness = min(1.05, max(0.5, brightestChannel * 1.08))
        self.init(
            redGain: wallRed / brightestChannel * brightness,
            greenGain: wallGreen / brightestChannel * brightness,
            blueGain: wallBlue / brightestChannel * brightness
        )
    }
}

// MARK: - Perspective

/// The perspective transform that maps four points onto four others, as OpenCV's getPerspectiveTransform. Nil when three of
/// the points are on one line.
nonisolated func perspectiveTransform(from sourcePoints: [CGPoint], to destinationPoints: [CGPoint]) -> simd_double3x3? {
    guard sourcePoints.count == 4, destinationPoints.count == 4 else { return nil }
    // Eight equations in the eight unknowns h11...h32, with h33 = 1.
    var equations = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for index in 0..<4 {
        let source = sourcePoints[index], destination = destinationPoints[index]
        equations[2 * index] = [source.x, source.y, 1, 0, 0, 0, -destination.x * source.x, -destination.x * source.y, destination.x]
        equations[2 * index + 1] = [0, 0, 0, source.x, source.y, 1, -destination.y * source.x, -destination.y * source.y, destination.y]
    }
    // Gaussian elimination with partial pivoting.
    for pivotColumn in 0..<8 {
        guard let pivotRow = (pivotColumn..<8).max(by: { abs(equations[$0][pivotColumn]) < abs(equations[$1][pivotColumn]) }),
              abs(equations[pivotRow][pivotColumn]) > 1e-12 else { return nil }
        equations.swapAt(pivotColumn, pivotRow)
        for row in 0..<8 where row != pivotColumn {
            let factor = equations[row][pivotColumn] / equations[pivotColumn][pivotColumn]
            guard factor != 0 else { continue }
            for column in pivotColumn..<9 {
                equations[row][column] -= factor * equations[pivotColumn][column]
            }
        }
    }
    let unknowns = (0..<8).map { equations[$0][8] / equations[$0][$0] }
    return simd_double3x3(rows: [
        SIMD3(unknowns[0], unknowns[1], unknowns[2]),
        SIMD3(unknowns[3], unknowns[4], unknowns[5]),
        SIMD3(unknowns[6], unknowns[7], 1),
    ])
}

nonisolated func applyingPerspective(_ transform: simd_double3x3, to point: CGPoint) -> CGPoint {
    let mapped = transform * SIMD3(point.x, point.y, 1)
    return CGPoint(x: mapped.x / mapped.z, y: mapped.y / mapped.z)
}

// MARK: - Failures

nonisolated enum RoomArtFailure: Equatable, Sendable {
    /// No app secret is set, or a route answered 401. Checked before the camera opens, and mapped from a 401 after.
    case appSecretMissing
    /// The front tab is not an https page, which the Worker refuses. Checked before the camera opens.
    case pageNotHTTPS
    case cameraAccessDenied
    case noCamera
    case notWallArt
    /// The page text could not be read or was empty, or `POST /room-art` failed.
    case pageNotRead
    /// The page is wall art, but its text states no size.
    case sizeNotOnThePage
    /// `POST /room-wall` answered 503 (no depth service configured) or 502 (the depth service is down).
    case depthServiceUnavailable
    /// `POST /room-wall` answered 422 (no bare wall there, or a wall too near, too far, or not flat), or its reply could
    /// not place the art.
    case wallNotMeasured
    /// A request to the Worker never got an answer: the Worker is not running, the connection failed, or it timed out.
    case workerUnreachable

    /// What Clicky says.
    var spokenLine: String {
        switch self {
        case .appSecretMissing: return "Clicky needs its app secret for this. See the README's Worker setup."
        case .pageNotHTTPS: return "I can only read store pages served over https."
        case .cameraAccessDenied: return "I need camera access for that. You can turn it on in System Settings."
        case .noCamera: return "I couldn't find a camera to show your room."
        case .notWallArt: return "That doesn't look like something that hangs on a wall."
        case .pageNotRead: return "I couldn't read the size from that page."
        case .sizeNotOnThePage: return "I couldn't find the size on that page."
        case .depthServiceUnavailable: return "I couldn't measure your wall. Is the depth service running?"
        case .wallNotMeasured: return "I couldn't measure your wall. Try pointing the camera at a bare wall."
        case .workerUnreachable: return "I couldn't reach Clicky's Worker."
        }
    }

    /// What the panel's status line says.
    var statusLine: String {
        switch self {
        case .appSecretMissing: return "Clicky needs its app secret. See the README's Worker setup."
        case .pageNotHTTPS: return "The page is not served over https"
        case .cameraAccessDenied: return "Camera access is off. Turn it on in System Settings, Privacy & Security, Camera."
        case .noCamera: return "No camera found"
        case .notWallArt: return "That doesn't look like wall art"
        case .pageNotRead: return "Couldn't read the size from the page"
        case .sizeNotOnThePage: return "Couldn't find the size on the page"
        case .depthServiceUnavailable: return "Couldn't measure the wall. Is the depth service running?"
        case .wallNotMeasured: return "Couldn't measure the wall"
        case .workerUnreachable: return "Couldn't reach Clicky's Worker"
        }
    }
}

// MARK: - Phase

/// One measurement: a keyframe, the wall measured on it, and the page read if it was not read before. A reply carries the
/// measurement it belongs to, so a reply from an earlier measurement or an earlier panel changes nothing.
nonisolated struct RoomArtMeasurementID: Hashable, Sendable {
    let number: Int
}

/// What the panel is doing.
nonisolated enum RoomArtPhase: Equatable, Sendable {
    case closed
    /// The panel is open and waits for the camera's first frame with a person mask.
    case startingCamera
    /// The first keyframe is taken, and the page and the wall are being read at once.
    case measuring(id: RoomArtMeasurementID, artwork: RoomArtwork?, wall: WallPlane?)
    /// The art is on the wall. `moveFailure` is why the last click could not move it, shown in the status line until the
    /// next move, with the art back where it was.
    case showing(artwork: RoomArtwork, wall: WallPlane, moveFailure: RoomArtFailure?)
    /// A click moves the art: a new keyframe and a new wall measurement. The art is read once, so moving it keeps it, and
    /// the wall it hung on comes back if the new one is not measured.
    case moving(id: RoomArtMeasurementID, artwork: RoomArtwork, wallBeforeTheMove: WallPlane)
    case failed(RoomArtFailure)

    var isOpen: Bool { self != .closed }

    // MARK: Transitions

    /// The learner asked to see the art. A panel already open starts over.
    func opening() -> RoomArtPhase {
        .startingCamera
    }

    /// A keyframe was taken: the first one once the camera runs, or a click that moves the art. One measurement runs at a
    /// time, so a click during one, or with nothing on the wall yet, changes nothing.
    func startingAMeasurement(id: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .startingCamera:
            return .measuring(id: id, artwork: nil, wall: nil)
        case .showing(let artwork, let wall, _):
            return .moving(id: id, artwork: artwork, wallBeforeTheMove: wall)
        case .closed, .measuring, .moving, .failed:
            return self
        }
    }

    func withArtworkRead(_ artwork: RoomArtwork, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        guard case .measuring(let measuringID, _, let wall) = self, measuringID == measurementID else { return self }
        if let wall { return Self.showingOrFailed(artwork: artwork, wall: wall) }
        return .measuring(id: measuringID, artwork: artwork, wall: nil)
    }

    func withWallMeasured(_ wall: WallPlane, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .measuring(let measuringID, let artwork, _) where measuringID == measurementID:
            if let artwork { return Self.showingOrFailed(artwork: artwork, wall: wall) }
            return .measuring(id: measuringID, artwork: nil, wall: wall)
        case .moving(let movingID, let artwork, let wallBeforeTheMove) where movingID == measurementID:
            guard Self.artCanHang(artwork, on: wall) else {
                return .showing(artwork: artwork, wall: wallBeforeTheMove, moveFailure: .wallNotMeasured)
            }
            return .showing(artwork: artwork, wall: wall, moveFailure: nil)
        default:
            return self
        }
    }

    /// A reply of this measurement failed. The first measurement's failure ends the panel, and a move's failure puts the
    /// art back on the wall it hung on.
    func afterTheMeasurementFailed(_ failure: RoomArtFailure, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .measuring(let measuringID, _, _) where measuringID == measurementID:
            return .failed(failure)
        case .moving(let movingID, let artwork, let wallBeforeTheMove) where movingID == measurementID:
            return .showing(artwork: artwork, wall: wallBeforeTheMove, moveFailure: failure)
        default:
            return self
        }
    }

    /// Whether every corner of the art lands in front of the camera on this wall.
    private static func artCanHang(_ artwork: RoomArtwork, on wall: WallPlane) -> Bool {
        wall.keyframeCorners(widthMeters: artwork.widthMeters, heightMeters: artwork.heightMeters) != nil
    }

    /// The first measurement's art on its wall, or a failure when no corner placement exists there.
    private static func showingOrFailed(artwork: RoomArtwork, wall: WallPlane) -> RoomArtPhase {
        guard artCanHang(artwork, on: wall) else { return .failed(.wallNotMeasured) }
        return .showing(artwork: artwork, wall: wall, moveFailure: nil)
    }

    /// The camera could not start.
    func afterTheCameraFailed(_ failure: RoomArtFailure) -> RoomArtPhase {
        guard case .startingCamera = self else { return self }
        return .failed(failure)
    }

    func closing() -> RoomArtPhase {
        .closed
    }

    /// The panel's one-line status.
    var statusLine: String {
        switch self {
        case .closed: return ""
        case .startingCamera: return "Starting the camera…"
        case .measuring(_, let artwork, _):
            return artwork == nil ? "Reading the page and measuring your wall…" : "Measuring your wall…"
        case .moving: return "Measuring your wall…"
        case .showing(let artwork, _, let moveFailure): return moveFailure?.statusLine ?? "On your wall at \(artwork.sizeInWords)"
        case .failed(let failure): return failure.statusLine
        }
    }

    /// The status line while the tracker has lost the room and the art is hidden, which only happens while it shows.
    func statusLine(theWallIsLost: Bool) -> String {
        guard theWallIsLost, case .showing = self else { return statusLine }
        return roomArtLostTheWallLine
    }

    /// Whether the status line says what went wrong, so the panel draws it in the failure color.
    func statusLineIsAFailure(theWallIsLost: Bool) -> Bool {
        switch self {
        case .failed: return true
        case .showing(_, _, let moveFailure): return moveFailure != nil && !theWallIsLost
        case .closed, .startingCamera, .measuring, .moving: return false
        }
    }
}

/// What the status line says while the tracker has lost the room, so the hidden art does not vanish without a word.
nonisolated let roomArtLostTheWallLine = "Lost the wall. Turn back, or click the wall to place it again."

// MARK: - When a line may play

/// What a room art line does now.
nonisolated enum RoomArtLineStep: Equatable, Sendable {
    case speakNow
    case waitForQuiet
    /// The learner pressed push-to-talk since asking, so the line belongs to a request they moved on from.
    case drop
}

/// The rule `themeStudioLineMayStart` holds for the studio, for a room art line that can land 14 seconds after the request:
/// it waits while push-to-talk is held, while audio plays, and while Clicky thinks about a request that is not the room
/// art's own opening, so it never cuts off a newer answer. A press after the room art request means the learner moved on,
/// so the line is dropped instead of waiting for them.
nonisolated func roomArtLineStep(
    dictationIsInProgress: Bool,
    clickyIsThinking: Bool,
    audioIsPlaying: Bool,
    roomArtIsOpeningThePanel: Bool,
    pushToTalkPressCount: Int,
    pushToTalkPressCountWhenTheRoomArtStarted: Int
) -> RoomArtLineStep {
    guard pushToTalkPressCount == pushToTalkPressCountWhenTheRoomArtStarted else { return .drop }
    let mayStart = themeStudioLineMayStart(
        dictationIsInProgress: dictationIsInProgress,
        clickyIsThinking: clickyIsThinking,
        audioIsPlaying: audioIsPlaying,
        themeStudioIsDesigning: roomArtIsOpeningThePanel,
        pushToTalkPressCount: pushToTalkPressCount,
        pushToTalkPressCountWhenTheDesignStarted: pushToTalkPressCountWhenTheRoomArtStarted
    )
    return mayStart ? .speakNow : .waitForQuiet
}

// MARK: - The phrase that asks for it

/// Whether the learner asks to see this item placed in their own room: a room phrase ("in my room", "on my wall", "on the
/// wall behind me", ...) right after either a placing verb and the item ("show this", "put it", "can I see this", "hang
/// that print") or the item and a look ("how would this look", "what would that poster look like", "would this look good",
/// "how would this look hanging"). The item is "this",
/// "it", or "that", or "this", "that", or "the" and one noun. So "how does the router in my house work", "what would look
/// good in my room", and "I put a poster in my room" name no item to place, and none of them asks.
nonisolated func asksToSeeArtInMyRoom(_ transcript: String) -> Bool {
    let apostrophes = CharacterSet(charactersIn: "'\u{2019}")
    let words = transcript.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(apostrophes).inverted)
        .map { $0.trimmingCharacters(in: apostrophes) }
        .filter { !$0.isEmpty }
    let roomPhrases: [[String]] = [
        ["in", "my", "room"], ["on", "my", "wall"], ["in", "my", "living", "room"], ["in", "my", "bedroom"],
        ["in", "my", "office"], ["in", "my", "house"], ["in", "my", "home"], ["in", "my", "apartment"],
        ["in", "my", "space"], ["on", "the", "wall", "behind", "me"],
    ]
    let placingVerbs: Set<String> = [
        "show", "see", "try", "put", "hang", "place", "preview", "picture", "visualize", "imagine",
    ]
    let itemWords: Set<String> = ["this", "it", "that"]
    let itemDeterminers: Set<String> = ["this", "that", "the"]
    let modalWords: Set<String> = ["would", "will", "could", "might", "does", "do"]
    /// Words that may sit between the look and the room phrase: "would this look good in my room", "how would this look
    /// hanging in my living room". A closed list, so a look that runs into other words still asks nothing.
    let wordsBetweenTheLookAndTheRoom: Set<String> = ["good", "nice", "great", "okay", "ok", "hanging", "framed", "up", "there"]

    /// The first index of each way the item can end at `lastIndex`: one word ("this"), or a determiner and a noun ("this print").
    func itemStarts(endingAt lastIndex: Int) -> [Int] {
        guard lastIndex >= 0 else { return [] }
        var starts: [Int] = []
        if itemWords.contains(words[lastIndex]) { starts.append(lastIndex) }
        if lastIndex >= 1, itemDeterminers.contains(words[lastIndex - 1]), !itemDeterminers.contains(words[lastIndex]), !modalWords.contains(words[lastIndex]) {
            starts.append(lastIndex - 1)
        }
        return starts
    }
    /// A placing verb right before the item, or with "me" between them: "show this", "show me this".
    func aPlacingVerbComesBefore(itemStart: Int) -> Bool {
        if itemStart >= 1, placingVerbs.contains(words[itemStart - 1]) { return true }
        return itemStart >= 2 && words[itemStart - 1] == "me" && placingVerbs.contains(words[itemStart - 2])
    }
    /// The item, an optional modal, "look" or "looks", an optional "like", and up to two words from
    /// `wordsBetweenTheLookAndTheRoom`, ending right before the room phrase.
    func theItemLooksRightBefore(roomPhraseStart: Int) -> Bool {
        var lookIndex = roomPhraseStart - 1
        var wordsSkippedBetween = 0
        while wordsSkippedBetween < 2, lookIndex >= 0, wordsBetweenTheLookAndTheRoom.contains(words[lookIndex]) {
            lookIndex -= 1
            wordsSkippedBetween += 1
        }
        if lookIndex >= 0, words[lookIndex] == "like" { lookIndex -= 1 }
        guard lookIndex >= 1, words[lookIndex] == "look" || words[lookIndex] == "looks" else { return false }
        // "how this would look" has the modal after the item, and "how would this look" before it.
        var itemEnd = lookIndex - 1
        if modalWords.contains(words[itemEnd]) { itemEnd -= 1 }
        return !itemStarts(endingAt: itemEnd).isEmpty
    }

    for roomPhrase in roomPhrases where words.count >= roomPhrase.count {
        for roomPhraseStart in 0...(words.count - roomPhrase.count) where Array(words[roomPhraseStart..<(roomPhraseStart + roomPhrase.count)]) == roomPhrase {
            if itemStarts(endingAt: roomPhraseStart - 1).contains(where: aPlacingVerbComesBefore(itemStart:)) { return true }
            if theItemLooksRightBefore(roomPhraseStart: roomPhraseStart) { return true }
        }
    }
    return false
}

// MARK: - Clients

nonisolated enum RoomArtWorkerError: Error, Equatable {
    case workerReturned(statusCode: Int, body: String)
}

/// The two Worker routes behind the panel.
@MainActor
final class RoomArtClient {
    private let roomArtURL: URL
    private let roomWallURL: URL
    private let session: URLSession

    /// Depth Pro takes about 14 seconds on the wall, and Sonnet several on the page. Past this the panel says it failed.
    private static let timeoutSeconds: TimeInterval = 90

    init(workerBaseURL: String) {
        guard let roomArtURL = URL(string: "\(workerBaseURL)/room-art"), let roomWallURL = URL(string: "\(workerBaseURL)/room-wall") else {
            preconditionFailure("Worker base URL did not form the room art URLs: \(workerBaseURL)")
        }
        self.roomArtURL = roomArtURL
        self.roomWallURL = roomWallURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: configuration)
    }

    func readThePage(_ pageRequest: RoomArtPageRequest) async throws -> RoomArtPageReading {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(pageRequest.json),
            to: roomArtURL,
            using: session,
            sendsAppSecret: true
        )
        guard statusCode == 200 else {
            throw RoomArtWorkerError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        return try RoomArtPageReading(responseData: responseData, pictureWidth: pageRequest.picture.width, pictureHeight: pageRequest.picture.height)
    }

    func measureTheWall(_ wallRequest: RoomWallRequest) async throws -> WallPlane {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(wallRequest.json),
            to: roomWallURL,
            using: session,
            sendsAppSecret: true
        )
        guard statusCode == 200 else {
            throw RoomArtWorkerError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        return try WallPlane(responseData: responseData)
    }
}

/// What a failed wall measurement means to the learner: a transport error says the Worker could not be reached, 401 says
/// the app secret is missing, 503 (no depth service configured) and 502 (it is down) ask whether it runs, and anything
/// else, a 422 included, says the wall could not be measured.
nonisolated func roomArtFailure(forAFailedWallMeasurement error: Error) -> RoomArtFailure {
    if error is URLError { return .workerUnreachable }
    guard case RoomArtWorkerError.workerReturned(let statusCode, _) = error else { return .wallNotMeasured }
    switch statusCode {
    case 401: return .appSecretMissing
    case 502, 503: return .depthServiceUnavailable
    default: return .wallNotMeasured
    }
}

/// What a failed page read means to the learner: a transport error says the Worker could not be reached, 401 says the app
/// secret is missing, and anything else that the page could not be read.
nonisolated func roomArtFailure(forAFailedPageRead error: Error) -> RoomArtFailure {
    if error is URLError { return .workerUnreachable }
    if case RoomArtWorkerError.workerReturned(statusCode: 401, _) = error { return .appSecretMissing }
    return .pageNotRead
}
