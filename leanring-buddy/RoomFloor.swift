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

/// Furniture as the panel stands it on the floor: its real size from the page and its cutout.
nonisolated struct RoomFurniture: Equatable, @unchecked Sendable {
    // @unchecked because CGImage is immutable, so sharing one across queues is safe.
    let title: String
    /// Across the front, from the page.
    let widthMeters: Double
    /// Floor to top, from the page.
    let heightMeters: Double
    /// Front to back, from the page, which the 3D box and a model's fit use. The flat cutout has no depth.
    let depthMeters: Double
    /// The product with a transparent background, trimmed to its own pixels, so its lowest pixel stands on the floor.
    let cutoutImage: CGImage

    /// The width of the piece's front face at its real height, from the photo's own shape, which the placement check uses.
    var drawnWidthMeters: Double {
        heightMeters * Double(cutoutImage.width) / Double(max(cutoutImage.height, 1))
    }

    /// The page's size in inches, such as "31.5 inches wide and 29.5 tall", from the measured centimeters and never the
    /// page's free-text label.
    var sizeInWords: String {
        roomFurnitureSizeInWords(widthCentimeters: widthMeters * 100, heightCentimeters: heightMeters * 100)
    }
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
    guard let cropRectangle = furnitureCropRectangle(for: itemCorners, inPictureOfWidth: picture.width, height: picture.height),
          let croppedPicture = picture.cropping(to: cropRectangle) else { return nil }

    let maskRequest = VNGenerateForegroundInstanceMaskRequest()
    let requestHandler = VNImageRequestHandler(cgImage: croppedPicture)
    do {
        try requestHandler.perform([maskRequest])
        guard let maskObservation = maskRequest.results?.first,
              let instanceToKeep = instanceIndexToKeep(in: maskObservation.instanceMask) else { return nil }
        let maskedPixelBuffer = try maskObservation.generateMaskedImage(
            ofInstances: IndexSet(integer: instanceToKeep),
            from: requestHandler,
            croppedToInstancesExtent: false
        )
        let maskedImage = CIImage(cvPixelBuffer: maskedPixelBuffer)
        guard let cutout = context.createCGImage(maskedImage, from: maskedImage.extent) else { return nil }
        // The corners are the model's guess, so the box around them can leave a margin of background under the legs. The
        // cutout is trimmed to its own pixels, so its lowest pixel is the one that stands on the floor.
        return opaqueBoundingBox(of: cutout).flatMap { cutout.cropping(to: $0) }
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
