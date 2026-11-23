//
//  RoomFloor.swift
//  leanring-buddy
//
//  The furniture half of "try it in my room": furniture stands on the learner's floor at its real size, drawn by its
//  painted composite or its model's render. The flat cutout of the product photo is never drawn.
//
//  This file holds the pure parts: the Worker's `POST /room-floor` reply parsed at the boundary (`FloorPlane`), the
//  furniture's corners in camera pixels from that plane and the item's size (`FloorPlane.keyframeCorners`), the furniture
//  as the panel stands it (`RoomFurniture`), and the cutout of the product from its photo (`furnitureCutout`), which the
//  generation services work from. The client that asks the Worker is `RoomArtClient.measureTheFloor`, and the panel and the
//  tracker that keeps the piece still live in `RoomArtPreview.swift` and `RoomTracker.swift`.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import simd
import Vision

// MARK: - The floor

/// The floor under the spot where the furniture stands, in meters in the camera's frame (x right, y down, z forward), as the
/// depth service measures it. `center` is the floor point under the anchor pixel, `right` lies on the floor and is level with
/// the camera, `up` is the floor's normal pointing up, and `forward` (`up` x `right`) lies on the floor pointing away from the
/// camera.
nonisolated struct FloorPlane: Equatable, Sendable {
    let center: SIMD3<Double>
    let right: SIMD3<Double>
    let up: SIMD3<Double>
    let forward: SIMD3<Double>
    let focalLengthPixels: Double
    let principalPoint: SIMD2<Double>
    let distanceMeters: Double
    let floorTiltDegrees: Double
    let planeInlierShare: Double
    /// True for a floor the app inferred from the wall because the camera saw none (`FloorPlane.inferred`), so the item
    /// stands square to the wall with its back on it, instead of turning toward the camera.
    var inferredFromTheWall = false

    /// The piece's front corners in the keyframe, in camera pixels: an upright rectangle `widthMeters` wide and
    /// `heightMeters` tall, the front face of `RoomFurniturePlacement` with no depth. The panel draws nothing at these
    /// corners and uses them to check that the piece can stand on the measured floor. On a measured floor it faces the camera (its width runs along `up` x the level direction toward the
    /// camera, which is `right` when the anchor is straight ahead and turns with the anchor when it is off to the side, so a
    /// piece to the side is not seen at a slant the product photo never had), and on a floor inferred from the wall it is
    /// square to the wall. The width direction is image-right for any floor the camera sees from the front, so the face is
    /// never mirrored.
    ///
    /// Nil when a corner is not in front of the camera, when the camera is straight above `center` so no level direction
    /// toward it exists, or when the size is not a positive number.
    func keyframeCorners(widthMeters: Double, heightMeters: Double) -> RoomArtCorners? {
        guard let boxCorners = keyframeBoxCorners(widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: 0) else { return nil }
        return RoomArtCorners(clockwiseFromTopLeft: Array(boxCorners.prefix(4)))
    }
}

nonisolated private struct RoomFloorReply: Decodable {
    let center: [Double]
    let right: [Double]
    let up: [Double]
    let forward: [Double]
    let focalPx: Double
    let principal: [Double]
    let distanceMeters: Double
    let floorTiltDegrees: Double
    let planeInlierShare: Double
}

extension FloorPlane {
    /// Parses the Worker's reply. The floor must be in front of the camera, its normal must point up in the image, the focal
    /// length must be positive, and the three directions must be real directions, which are made unit length.
    nonisolated init(responseData: Data) throws {
        let reply: RoomFloorReply
        do {
            reply = try JSONDecoder().decode(RoomFloorReply.self, from: responseData)
        } catch {
            throw RoomArtReplyError(reason: "the reply is not the room-floor shape")
        }
        func vector3(_ values: [Double], named name: String) throws -> SIMD3<Double> {
            guard values.count == 3, values.allSatisfy(\.isFinite) else { throw RoomArtReplyError(reason: "\(name) must be 3 numbers") }
            return SIMD3(values[0], values[1], values[2])
        }
        let center = try vector3(reply.center, named: "center")
        let right = try vector3(reply.right, named: "right")
        let up = try vector3(reply.up, named: "up")
        let forward = try vector3(reply.forward, named: "forward")
        guard center.z > 0 else { throw RoomArtReplyError(reason: "the floor must be in front of the camera") }
        guard simd_length(right) > 1e-6, simd_length(up) > 1e-6, simd_length(forward) > 1e-6 else {
            throw RoomArtReplyError(reason: "right, up, and forward must be directions")
        }
        // The camera's y axis points down the image, so a floor's normal pointing up has a negative y. A positive y is a ceiling.
        guard up.y < 0 else { throw RoomArtReplyError(reason: "the floor's up must point up in the image") }
        guard reply.focalPx.isFinite, reply.focalPx > 0 else { throw RoomArtReplyError(reason: "focalPx must be positive") }
        guard reply.principal.count == 2, reply.principal.allSatisfy(\.isFinite) else { throw RoomArtReplyError(reason: "principal must be 2 numbers") }
        self.init(
            center: center,
            right: simd_normalize(right),
            up: simd_normalize(up),
            forward: simd_normalize(forward),
            focalLengthPixels: reply.focalPx,
            principalPoint: SIMD2(reply.principal[0], reply.principal[1]),
            distanceMeters: reply.distanceMeters,
            floorTiltDegrees: reply.floorTiltDegrees,
            planeInlierShare: reply.planeInlierShare
        )
    }
}

// MARK: - The furniture

/// A standing item as the panel stands it on its surface: its real size, from the page or measured from its cutout, and its
/// cutout. It keeps the name "furniture" for every standing item, a lamp, a rug, or a mug included, and `standsOn` says
/// whether the surface is the floor or a table or shelf.
nonisolated struct RoomFurniture: Equatable, @unchecked Sendable {
    // @unchecked because CGImage is immutable, so sharing one across queues is safe.
    let title: String
    /// Across the front, from the page, or from the cutout's shape at the page's height when the page states no width.
    let widthMeters: Double
    /// What it stands on to its top, from the page.
    let heightMeters: Double
    /// Front to back, from the page, or `roomFurnitureDepthWhenThePageStatesNone` when it states none, which the 3D box and
    /// a model's fit use. The flat cutout has no depth.
    let depthMeters: Double
    /// The product with a transparent background, trimmed to its own pixels, so its lowest pixel stands on its surface.
    let cutoutImage: CGImage
    /// True when the page stated no width and `widthMeters` was measured from the cutout's shape, so the spoken size and
    /// the ghost's size pill say "about".
    var widthIsMeasuredFromThePhoto = false

    var standsOn: RoomArtStandsOn = .floor

    /// The piece at the page's size. A page that states only the height, as a figurine's often does, gets the width of
    /// the cutout's own shape at that height. Nil when that measured width falls outside the sizes a page may state
    /// (`roomFurnitureMeasuredWidthRangeCentimeters`), such as for a cutout that holds the figure and its box side by side.
    static func standing(title: String, size: RoomArtFurnitureSize, cutoutImage: CGImage, standsOn: RoomArtStandsOn = .floor) -> RoomFurniture? {
        let heightMeters = size.heightCentimeters / 100
        let widthMeters: Double
        if let statedWidthCentimeters = size.widthCentimeters {
            widthMeters = statedWidthCentimeters / 100
        } else {
            let measuredWidthMeters = heightMeters * Double(cutoutImage.width) / Double(max(cutoutImage.height, 1))
            guard roomFurnitureMeasuredWidthRangeCentimeters.contains(measuredWidthMeters * 100) else { return nil }
            widthMeters = measuredWidthMeters
        }
        return RoomFurniture(
            title: title,
            widthMeters: widthMeters,
            heightMeters: heightMeters,
            depthMeters: size.depthCentimeters.map { $0 / 100 }
                ?? roomFurnitureDepthWhenThePageStatesNone(widthMeters: widthMeters, heightMeters: heightMeters),
            cutoutImage: cutoutImage,
            widthIsMeasuredFromThePhoto: size.widthCentimeters == nil,
            standsOn: standsOn
        )
    }

    /// The width of the piece's front face at its real height, from the photo's own shape, which the placement check uses.
    var drawnWidthMeters: Double {
        heightMeters * Double(cutoutImage.width) / Double(max(cutoutImage.height, 1))
    }

    /// The page's size in inches, such as "31.5 inches wide and 29.5 tall", from the measured centimeters and never the
    /// page's free-text label, with "about" in front when the width came from the photo.
    var sizeInWords: String {
        guard widthIsMeasuredFromThePhoto else {
            return roomFurnitureSizeInWords(widthCentimeters: widthMeters * 100, heightCentimeters: heightMeters * 100)
        }
        // The height is the page's, so "about" goes on the measured width alone.
        return "\(roomArtInchesInWords(centimeters: heightMeters * 100)) inches tall and about \(roomArtInchesInWords(centimeters: widthMeters * 100)) wide"
    }
}

/// The widths a measured width may have, the Worker's furniture range (`furnitureSizeRangeCentimeters`), so a cutout whose
/// shape is far off, such as a figure and its box side by side, is refused instead of placed meters wide.
nonisolated let roomFurnitureMeasuredWidthRangeCentimeters = 2.0...600.0

/// The depth of a piece whose page states none. The depth sets the ghost's footprint, the painting's area, how far a piece
/// on a floor inferred from the wall stands off it, the shadow's size, and whether a store model turns a quarter turn, so a
/// depth equal to the width would make a 180 cm TV stand 180 cm deep. Half the width, never more than the height, is close
/// for a figure (LEGO's 15 cm wide astronaut is about 8 deep) and keeps a wide, low piece shallow.
nonisolated func roomFurnitureDepthWhenThePageStatesNone(widthMeters: Double, heightMeters: Double) -> Double {
    min(widthMeters / 2, heightMeters)
}

/// "31.5 inches wide and 29.5 tall", each rounded to the nearest half inch.
nonisolated func roomFurnitureSizeInWords(widthCentimeters: Double, heightCentimeters: Double) -> String {
    "\(roomArtInchesInWords(centimeters: widthCentimeters)) inches wide and \(roomArtInchesInWords(centimeters: heightCentimeters)) tall"
}

// MARK: - The cutout

/// The product cut out of its photo: the photo cropped to the bounding box of `itemCorners` (clamped into the photo), with
/// everything but the product transparent. Vision's foreground instance mask finds the product, the way the pop-out lifts a
/// subject. When it finds several instances, such as a chair and its cushion, the one under the crop's center is kept, and
/// when the center is on the background, such as the hole of a ring-shaped stool, the largest instance is. Nil when the
/// corners leave under 8 pixels of the photo (`furnitureCropRectangle`), when Vision finds no subject, or when it fails.
nonisolated func furnitureCutout(picture: CGImage, itemCorners: RoomArtCorners, context: CIContext) -> CGImage? {
    guard let foreground = foregroundOfTheItem(picture: picture, itemCorners: itemCorners, context: context) else { return nil }
    // The corners are the model's guess, so the box around them can leave a margin of background under the legs. The
    // cutout is trimmed to its own pixels, so its lowest pixel is the one that stands on the floor.
    return opaqueBoundingBox(of: foreground.cutout).flatMap { foreground.cutout.cropping(to: $0) }
}

/// The item's own shape cut out of the whole product photo: the photo at its own size, with every pixel outside the item
/// transparent. A wall item that does not fill its four corners, such as a round clock, is flattened from this picture, so the
/// flattened art keeps transparent pixels where the photo's background was. The mask is Vision's, as in `furnitureCutout`,
/// but it keeps every instance Vision finds, since the corners already hold only the item, and Vision splits a clock into its
/// face and its hands: keeping the instance under the center kept only the hands of IKEA's BONDIS clock.
/// Nil when the corners leave under 8 pixels of the photo, when Vision finds no subject, or when it fails.
nonisolated func pictureWithOnlyTheItemOpaque(picture: CGImage, itemCorners: RoomArtCorners, context: CIContext) -> CGImage? {
    guard let foreground = foregroundOfTheItem(picture: picture, itemCorners: itemCorners, keepsEveryInstance: true, context: context) else { return nil }
    return pictureWithTheCutoutPlaced(foreground.cutout, at: foreground.cropRectangle, pictureWidth: picture.width, pictureHeight: picture.height)
}

/// `cutout` drawn into a clear picture of `pictureWidth` by `pictureHeight` at `cropRectangle` (top left origin), so each
/// cutout pixel keeps the place it had in the photo. Nil when Core Graphics cannot make the picture.
nonisolated func pictureWithTheCutoutPlaced(_ cutout: CGImage, at cropRectangle: CGRect, pictureWidth: Int, pictureHeight: Int) -> CGImage? {
    guard let drawingContext = CGContext(
        data: nil, width: pictureWidth, height: pictureHeight, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    // Core Graphics' y grows up from the bottom, and the crop rectangle's y grows down from the top.
    drawingContext.draw(cutout, in: CGRect(
        x: cropRectangle.minX, y: Double(pictureHeight) - cropRectangle.maxY, width: cropRectangle.width, height: cropRectangle.height
    ))
    return drawingContext.makeImage()
}

/// Vision's foreground instance mask applied to the crop of `itemCorners`: the crop with everything but the kept instance
/// transparent, and where the crop sits in the photo. Not trimmed. Nil as `furnitureCutout` is. `keepsEveryInstance` keeps all of
/// Vision's instances instead of the one `instanceIndexToKeep` picks.
nonisolated private func foregroundOfTheItem(
    picture: CGImage, itemCorners: RoomArtCorners, keepsEveryInstance: Bool = false, context: CIContext
) -> (cutout: CGImage, cropRectangle: CGRect)? {
    guard let cropRectangle = furnitureCropRectangle(for: itemCorners, inPictureOfWidth: picture.width, height: picture.height),
          let croppedPicture = picture.cropping(to: cropRectangle) else { return nil }

    let maskRequest = VNGenerateForegroundInstanceMaskRequest()
    let requestHandler = VNImageRequestHandler(cgImage: croppedPicture)
    do {
        try requestHandler.perform([maskRequest])
        guard let maskObservation = maskRequest.results?.first,
              let instancesToKeep = foregroundInstancesToKeep(
                  instanceLabels: maskObservation.instanceMask, allInstances: maskObservation.allInstances, keepsEveryInstance: keepsEveryInstance
              ) else { return nil }
        let maskedPixelBuffer = try maskObservation.generateMaskedImage(
            ofInstances: instancesToKeep,
            from: requestHandler,
            croppedToInstancesExtent: false
        )
        let maskedImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
        guard let cutout = context.createCGImage(maskedImage, from: maskedImage.extent) else { return nil }
        return (cutout, cropRectangle)
    } catch {
        print("Room floor: the furniture cutout failed: \(error)")
        return nil
    }
}

/// The part of the photo the cutout works on: the bounding box of the corners rounded out to whole pixels and clamped into the
/// photo. Nil when under 8 pixels of the photo are left on a side, since the product is then not in the photo.
nonisolated func furnitureCropRectangle(for itemCorners: RoomArtCorners, inPictureOfWidth pictureWidth: Int, height pictureHeight: Int) -> CGRect? {
    let corners = itemCorners.clockwiseFromTopLeft
    guard let left = corners.map(\.x).min(), let right = corners.map(\.x).max(),
          let top = corners.map(\.y).min(), let bottom = corners.map(\.y).max() else { return nil }
    let boundingBox = CGRect(x: left, y: top, width: right - left, height: bottom - top).integral
    let cropRectangle = boundingBox.intersection(CGRect(x: 0, y: 0, width: pictureWidth, height: pictureHeight))
    guard !cropRectangle.isNull, cropRectangle.width >= 8, cropRectangle.height >= 8 else { return nil }
    return cropRectangle
}

/// The instances a cutout keeps: every instance for a wall item (`keepsEveryInstance`), since its corners already hold only the
/// item and Vision can split one item into pieces, else the one `instanceIndexToKeep` picks. Nil when there is none.
nonisolated func foregroundInstancesToKeep(instanceLabels: CVPixelBuffer, allInstances: IndexSet, keepsEveryInstance: Bool) -> IndexSet? {
    if keepsEveryInstance { return allInstances.isEmpty ? nil : allInstances }
    return instanceIndexToKeep(in: instanceLabels).map { IndexSet(integer: $0) }
}

/// The instance label (1 or more) the cutout keeps, from Vision's label buffer, where each pixel holds its instance's index
/// and 0 is the background: the label at the buffer's center, else the label with the most pixels. Nil when every pixel is
/// background.
nonisolated func instanceIndexToKeep(in instanceLabels: CVPixelBuffer) -> Int? {
    CVPixelBufferLockBaseAddress(instanceLabels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(instanceLabels, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(instanceLabels) == kCVPixelFormatType_OneComponent8,
          let baseAddress = CVPixelBufferGetBaseAddress(instanceLabels) else { return nil }
    let width = CVPixelBufferGetWidth(instanceLabels), height = CVPixelBufferGetHeight(instanceLabels)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(instanceLabels)
    guard width > 0, height > 0 else { return nil }
    let labels = baseAddress.assumingMemoryBound(to: UInt8.self)

    var pixelCountByLabel: [UInt8: Int] = [:]
    for row in 0..<height {
        for column in 0..<width where labels[row * bytesPerRow + column] != 0 {
            pixelCountByLabel[labels[row * bytesPerRow + column], default: 0] += 1
        }
    }
    let labelAtTheCenter = labels[(height / 2) * bytesPerRow + width / 2]
    if labelAtTheCenter != 0 { return Int(labelAtTheCenter) }
    // A tie goes to the lower label, so the choice never depends on dictionary order.
    return pixelCountByLabel.max { ($0.value, -Int($0.key)) < ($1.value, -Int($1.key)) }.map { Int($0.key) }
}

/// The smallest rectangle holding every pixel of `image` whose alpha is over 10 percent, in the image's pixels with the
/// origin at the top left. Nil when no pixel is that opaque.
nonisolated func opaqueBoundingBox(of image: CGImage) -> CGRect? {
    let width = image.width, height = image.height
    guard width > 0, height > 0 else { return nil }
    var alphaValues = [UInt8](repeating: 0, count: width * height)
    let drewTheAlpha = alphaValues.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drewTheAlpha else { return nil }
    var left = width, right = -1, top = height, bottom = -1
    for row in 0..<height {
        for column in 0..<width where alphaValues[row * width + column] > 25 {
            left = min(left, column)
            right = max(right, column)
            top = min(top, row)
            bottom = max(bottom, row)
        }
    }
    guard right >= left, bottom >= top else { return nil }
    return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
}
