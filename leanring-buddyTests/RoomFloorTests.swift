//
//  RoomFloorTests.swift
//  leanring-buddyTests
//
//  Furniture on the floor: the `POST /room-floor` reply parsed at the boundary, the furniture's corners projected from the
//  floor plane, the request it sends, and the cutout of the product from its photo.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import simd
import Testing
@testable import Clicky

private func jsonData(_ text: String) -> Data { Data(text.utf8) }

/// A camera 1.5 m above a level floor, looking straight ahead: the floor's normal points up the image (-y), `right` is +x, and
/// `forward` = `up` x `right` is +z. Focal length 1000 px, principal point (640, 360).
private let levelFloor = FloorPlane(
    center: SIMD3(0, 1.5, 3), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1),
    focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 3.35, floorTiltDegrees: 0, planeInlierShare: 0.9
)

private let goodFloorReplyJSON = """
{"center": [0.1, 1.2, 3.4], "right": [1, 0, 0], "up": [0, -0.96593, -0.25882], "forward": [0, -0.25882, 0.96593],
 "focalPx": 1500.0, "principal": [960, 540], "distanceMeters": 3.6, "floorTiltDegrees": 15.0, "planeInlierShare": 0.97,
 "inferenceSeconds": 16.09, "seconds": 16.49}
"""

private func replyJSON(replacing key: String, with valueJSON: String) -> String {
    let pattern = "\"\(key)\": [^,}]*"
    // Arrays hold commas, so the three vector keys are replaced by their whole bracketed value.
    let arrayPattern = "\"\(key)\": \\[[^\\]]*\\]"
    let expression = try! NSRegularExpression(pattern: ["center", "right", "up", "forward", "principal"].contains(key) ? arrayPattern : pattern)
    let range = NSRange(goodFloorReplyJSON.startIndex..., in: goodFloorReplyJSON)
    return expression.stringByReplacingMatches(in: goodFloorReplyJSON, range: range, withTemplate: "\"\(key)\": \(valueJSON)")
}

private func solidImage(width: Int, height: Int, shapeInTheMiddle: Bool) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if shapeInTheMiddle {
        // A saturated red rounded block on white, like a product on a studio background.
        context.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1))
        let block = CGRect(x: Double(width) * 0.25, y: Double(height) * 0.2, width: Double(width) * 0.5, height: Double(height) * 0.6)
        context.addPath(CGPath(roundedRect: block, cornerWidth: 12, cornerHeight: 12, transform: nil))
        context.fillPath()
    }
    return context.makeImage()!
}

private func alphaOfThePixel(in image: CGImage, x: Int, y: Int) -> UInt8 {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Drawing the whole image shifted so the wanted pixel lands on the 1 x 1 context. CGContext's y grows up.
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return pixel[3]
}

private func labelBuffer(width: Int, height: Int, label: (Int, Int) -> UInt8) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_OneComponent8, nil, &buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let rows = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    for row in 0..<height {
        for column in 0..<width { rows[row * bytesPerRow + column] = label(column, row) }
    }
    return pixelBuffer
}

@Suite("Room floor")
struct RoomFloorTests {
    // MARK: Reply parsing

    @Test func aGoodReplyParsesWithUnitDirections() throws {
        let floor = try FloorPlane(responseData: jsonData(goodFloorReplyJSON))

        #expect(floor.center == SIMD3(0.1, 1.2, 3.4))
        #expect(floor.focalLengthPixels == 1500)
        #expect(floor.principalPoint == SIMD2(960, 540))
        #expect(floor.floorTiltDegrees == 15)
        #expect(abs(simd_length(floor.up) - 1) < 1e-9)
        #expect(abs(simd_length(floor.forward) - 1) < 1e-9)
    }

    @Test func aSlightlyShortDirectionIsMadeUnitLength() throws {
        let floor = try FloorPlane(responseData: jsonData(replyJSON(replacing: "right", with: "[0.5, 0, 0]")))

        #expect(floor.right == SIMD3(1, 0, 0))
    }

    @Test(arguments: [
        ("a center behind the camera", "center", "[0, 1.2, -1]"),
        ("a center on the camera plane", "center", "[0, 1.2, 0]"),
        ("a center with 2 numbers", "center", "[0, 1.2]"),
        ("a zero right", "right", "[0, 0, 0]"),
        ("a zero up", "up", "[0, 0, 0]"),
        ("a zero forward", "forward", "[0, 0, 0]"),
        ("an up that points down the image", "up", "[0, 0.96593, 0.25882]"),
        ("an up that is level in the image", "up", "[0, 0, -1]"),
        ("a focal length of 0", "focalPx", "0"),
        ("a negative focal length", "focalPx", "-5"),
        ("a principal point with 3 numbers", "principal", "[1, 2, 3]"),
    ])
    func aReplyThatCannotPlaceFurnitureIsRefused(description: String, key: String, valueJSON: String) {
        #expect(throws: RoomArtReplyError.self, "\(description)") {
            try FloorPlane(responseData: jsonData(replyJSON(replacing: key, with: valueJSON)))
        }
    }

    @Test func aReplyThatIsNotTheFloorShapeIsRefused() {
        // A /room-wall reply has a wall angle and no forward vector or tilt.
        let wallReply = #"{"center": [0, 0, 2], "right": [1, 0, 0], "up": [0, -1, 0], "focalPx": 1000, "principal": [640, 360], "distanceMeters": 2, "wallAngleDegrees": 0, "planeInlierShare": 0.9}"#

        #expect(throws: RoomArtReplyError(reason: "the reply is not the room-floor shape")) { try FloorPlane(responseData: jsonData(wallReply)) }
        #expect(throws: RoomArtReplyError(reason: "the reply is not the room-floor shape")) { try FloorPlane(responseData: jsonData("not json")) }
    }

    // MARK: Request

    @Test func theFloorRequestHasTheWallRequestsShape() throws {
        let request = RoomWallRequest(keyframeJPEGData: Data([1, 2, 3]), personMaskPNGData: Data([4]), anchor: CGPoint(x: 600.5, y: 700))
        let encoded = try JSONEncoder().encode(request.json)
        let body = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(body["jpegBase64"] as? String == Data([1, 2, 3]).base64EncodedString())
        #expect(body["maskPngBase64"] as? String == Data([4]).base64EncodedString())
        let anchor = try #require(body["anchor"] as? [String: Double])
        #expect(anchor == ["u": 600.5, "v": 700])
    }

    // MARK: Corners

    /// Worked by hand: a camera 1.5 m up, a 0.8 m wide, 0.6 m tall piece standing 3 m straight ahead.
    /// The floor point under the anchor is (0, 1.5, 3). The horizontal direction toward the camera is -center = (0, -1.5, -3)
    /// minus its part along up (up . -center = 1.5, so subtract 1.5 * (0, -1, 0) = (0, -1.5, 0)), which is (0, 0, -3), so the
    /// normal is (0, 0, -1) and the width direction up x normal = (0, -1, 0) x (0, 0, -1) = (1, 0, 0).
    /// The bottom corners are (+-0.4, 1.5, 3) and the top corners (+-0.4, 0.9, 3), since up is -y.
    /// Pixel x = X * 1000 / 3 + 640 = 640 +- 133.333, and pixel y = Y * 1000 / 3 + 360 = 860 at the bottom and 660 at the top.
    @Test func aPieceStraightAheadProjectsToAnUprightRectangleOnThePinholeImage() throws {
        let corners = try #require(levelFloor.keyframeCorners(widthMeters: 0.8, heightMeters: 0.6))

        #expect(abs(corners.topLeft.x - 506.6667) < 0.01 && abs(corners.topLeft.y - 660) < 0.01)
        #expect(abs(corners.topRight.x - 773.3333) < 0.01 && abs(corners.topRight.y - 660) < 0.01)
        #expect(abs(corners.bottomRight.x - 773.3333) < 0.01 && abs(corners.bottomRight.y - 860) < 0.01)
        #expect(abs(corners.bottomLeft.x - 506.6667) < 0.01 && abs(corners.bottomLeft.y - 860) < 0.01)
    }

    /// Worked by hand: the same piece 3 m to the right and 3 m ahead, center = (3, 1.5, 3).
    /// The horizontal direction toward the camera is (-3, 0, -3) / sqrt(18) = (-0.7071, 0, -0.7071), so the piece faces the
    /// camera and its width direction is up x normal = (0, -1, 0) x (-0.7071, 0, -0.7071) = (0.7071, 0, -0.7071).
    /// Half the width, 0.4 m, along it is (0.28284, 0, -0.28284), so the bottom left is (2.71716, 1.5, 3.28284), the bottom
    /// right (3.28284, 1.5, 2.71716), and the tops are 0.6 m higher, at y = 0.9.
    /// Bottom left: x = 2.71716 * 1000 / 3.28284 + 640 = 1467.68, y = 1.5 * 1000 / 3.28284 + 360 = 816.92.
    /// Bottom right: x = 3.28284 * 1000 / 2.71716 + 640 = 1848.19, y = 1.5 * 1000 / 2.71716 + 360 = 912.05.
    /// Top left: y = 0.9 * 1000 / 3.28284 + 360 = 634.15. Top right: y = 0.9 * 1000 / 2.71716 + 360 = 691.23.
    @Test func aPieceToTheSideTurnsToFaceTheCamera() throws {
        let floorToTheSide = FloorPlane(
            center: SIMD3(3, 1.5, 3), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1),
            focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 4.5, floorTiltDegrees: 0, planeInlierShare: 0.9
        )

        let corners = try #require(floorToTheSide.keyframeCorners(widthMeters: 0.8, heightMeters: 0.6))

        #expect(abs(corners.bottomLeft.x - 1467.68) < 0.05 && abs(corners.bottomLeft.y - 816.92) < 0.05)
        #expect(abs(corners.bottomRight.x - 1848.19) < 0.05 && abs(corners.bottomRight.y - 912.05) < 0.05)
        #expect(abs(corners.topLeft.y - 634.15) < 0.05)
        #expect(abs(corners.topRight.y - 691.23) < 0.05)
        // Not mirrored: the corner called left is left of the one called right.
        #expect(corners.topLeft.x < corners.topRight.x)
    }

    @Test func theCornersAreInTheOrderTopLeftTopRightBottomRightBottomLeft() throws {
        let corners = try #require(levelFloor.keyframeCorners(widthMeters: 0.8, heightMeters: 0.6))

        #expect(corners.topLeft.x < corners.topRight.x)
        #expect(corners.topLeft.y < corners.bottomLeft.y)
        #expect(corners.bottomLeft.x == corners.topLeft.x)
        #expect(corners.bottomRight.y == corners.bottomLeft.y)
    }

    /// A camera pitched 45 degrees down sees the floor with up = (0, -0.7071, -0.7071). A 2 m tall piece whose base is 0.5 m
    /// ahead has its top at z = 0.5 - 2 * 0.7071 = -0.91, behind the camera.
    @Test func aCornerBehindTheCameraGivesNoCorners() {
        let pitchedFloor = FloorPlane(
            center: SIMD3(0, 1, 0.5), right: SIMD3(1, 0, 0), up: SIMD3(0, -0.7071068, -0.7071068), forward: SIMD3(0, -0.7071068, 0.7071068),
            focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 1.1, floorTiltDegrees: 45, planeInlierShare: 0.9
        )

        #expect(pitchedFloor.keyframeCorners(widthMeters: 0.5, heightMeters: 2) == nil)
        #expect(pitchedFloor.keyframeCorners(widthMeters: 0.5, heightMeters: 0.3) != nil)
    }

    @Test func aDegenerateSizeGivesNoCorners() {
        #expect(levelFloor.keyframeCorners(widthMeters: 0, heightMeters: 0.6) == nil)
        #expect(levelFloor.keyframeCorners(widthMeters: 0.8, heightMeters: -1) == nil)
        #expect(levelFloor.keyframeCorners(widthMeters: .nan, heightMeters: 0.6) == nil)
        #expect(levelFloor.keyframeCorners(widthMeters: 0.8, heightMeters: .infinity) == nil)
    }

    /// A camera pitched 45 degrees down has up = (0, -0.7071, -0.7071). A floor point on the camera's vertical, 1.5 m below it,
    /// is 1.5 * (0, 0.7071, 0.7071) = (0, 1.0607, 1.0607), in front of the camera, with no horizontal direction toward it.
    @Test func aPieceDirectlyBelowTheCameraGivesNoCorners() {
        let directlyBelowTheCamera = FloorPlane(
            center: SIMD3(0, 1.0606602, 1.0606602), right: SIMD3(1, 0, 0), up: SIMD3(0, -0.7071068, -0.7071068), forward: SIMD3(0, -0.7071068, 0.7071068),
            focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 1.5, floorTiltDegrees: 45, planeInlierShare: 0.9
        )

        #expect(directlyBelowTheCamera.keyframeCorners(widthMeters: 0.8, heightMeters: 0.6) == nil)
    }

    /// The reply recorded from a live Depth Pro run on 2026-11-21 (the depth service's `POST /floor` on a 1440 x 960 frame of a
    /// person standing in a room, with the anchor at (1000, 930)). Its floor point projects back onto the anchor, and a
    /// 0.8 m x 0.6 m piece gets corners around it. The piece is turned to face the camera and 1.2 m away, so its near end projects wider than its far end, which moves the bottom edge's middle about 30 pixels from the anchor in x.
    @Test func aReplyRecordedFromALiveDepthProRunPlacesAPieceOnItsAnchor() throws {
        let recordedReply = """
        {"center": [0.2559, 0.4113, 1.198], "right": [0.99762, 0.06617, -0.0194], "up": [0.06896, -0.95732, 0.28069],
         "forward": [0.0, 0.28136, 0.9596], "focalPx": 1310.69, "principal": [720.0, 480.0], "distanceMeters": 1.292,
         "floorTiltDegrees": 16.8, "planeInlierShare": 0.467, "inferenceSeconds": 12.86, "seconds": 12.93}
        """

        let floor = try FloorPlane(responseData: jsonData(recordedReply))
        let corners = try #require(floor.keyframeCorners(widthMeters: 0.8, heightMeters: 0.6))

        let anchorOfThePlane = CGPoint(
            x: floor.center.x * floor.focalLengthPixels / floor.center.z + floor.principalPoint.x,
            y: floor.center.y * floor.focalLengthPixels / floor.center.z + floor.principalPoint.y
        )
        #expect(abs(anchorOfThePlane.x - 1000) < 1 && abs(anchorOfThePlane.y - 930) < 1)
        let bottomMiddle = CGPoint(x: (corners.bottomLeft.x + corners.bottomRight.x) / 2, y: (corners.bottomLeft.y + corners.bottomRight.y) / 2)
        #expect(abs(bottomMiddle.x - 1000) < 40 && abs(bottomMiddle.y - 930) < 20)
        #expect(corners.topLeft.y < corners.bottomLeft.y && corners.topLeft.x < corners.topRight.x)
    }

    // MARK: Which instance the cutout keeps

    @Test func theInstanceAtTheCenterIsKept() {
        let labels = labelBuffer(width: 10, height: 10) { column, row in
            if column == 5 && row == 5 { return 2 }
            return column < 4 ? 1 : 0
        }

        #expect(instanceIndexToKeep(in: labels) == 2)
    }

    @Test func whenTheCenterIsBackgroundTheLargestInstanceIsKept() {
        // A ring: instance 3 around the edge (36 pixels), instance 1 in two corner pixels, and the center is background.
        let labels = labelBuffer(width: 10, height: 10) { column, row in
            if (column == 0 || column == 9 || row == 0 || row == 9) { return 3 }
            if column == 1 && (row == 1 || row == 2) { return 1 }
            return 0
        }

        #expect(instanceIndexToKeep(in: labels) == 3)
    }

    @Test func aTieBetweenInstancesGoesToTheLowerLabel() {
        let labels = labelBuffer(width: 10, height: 10) { column, row in
            guard row == 0 else { return 0 }
            return column < 3 ? 2 : (column < 6 ? 1 : 0)
        }

        #expect(instanceIndexToKeep(in: labels) == 1)
    }

    @Test func aBufferOfOnlyBackgroundKeepsNothing() {
        #expect(instanceIndexToKeep(in: labelBuffer(width: 8, height: 8) { _, _ in 0 }) == nil)
    }

    // MARK: The crop

    private func corners(_ left: Double, _ top: Double, _ right: Double, _ bottom: Double) -> RoomArtCorners {
        RoomArtCorners(topLeft: CGPoint(x: left, y: top), topRight: CGPoint(x: right, y: top), bottomRight: CGPoint(x: right, y: bottom), bottomLeft: CGPoint(x: left, y: bottom))
    }

    @Test func theCropIsTheCornersBoundingBoxRoundedOutAndClampedIntoThePhoto() throws {
        // Tilted corners: the box spans their extremes.
        let tilted = RoomArtCorners(topLeft: CGPoint(x: 10.4, y: 20.6), topRight: CGPoint(x: 90.2, y: 15.1), bottomRight: CGPoint(x: 95.7, y: 80.3), bottomLeft: CGPoint(x: 5.5, y: 85.9))
        #expect(furnitureCropRectangle(for: tilted, inPictureOfWidth: 200, height: 200) == CGRect(x: 5, y: 15, width: 91, height: 71))
        // Corners that stick out of the photo are clamped to it.
        #expect(furnitureCropRectangle(for: corners(-30, -10, 120, 90), inPictureOfWidth: 100, height: 80) == CGRect(x: 0, y: 0, width: 100, height: 80))
    }

    @Test func aCropUnder8PixelsOnASideIsNotACrop() {
        #expect(furnitureCropRectangle(for: corners(50, 50, 58, 58), inPictureOfWidth: 200, height: 200) == CGRect(x: 50, y: 50, width: 8, height: 8))
        #expect(furnitureCropRectangle(for: corners(50, 50, 57, 80), inPictureOfWidth: 200, height: 200) == nil)
        #expect(furnitureCropRectangle(for: corners(50, 50, 80, 57), inPictureOfWidth: 200, height: 200) == nil)
        // Mostly outside the photo, so under 8 pixels of it are left.
        #expect(furnitureCropRectangle(for: corners(-100, 10, 5, 80), inPictureOfWidth: 200, height: 200) == nil)
        #expect(furnitureCropRectangle(for: corners(300, 300, 400, 400), inPictureOfWidth: 200, height: 200) == nil)
    }

    // MARK: The cutout

    @Test func cornersThatLeaveTooLittleOfThePhotoGiveNoCutout() {
        let picture = solidImage(width: 200, height: 200, shapeInTheMiddle: true)
        let tinyCorners = RoomArtCorners(
            topLeft: CGPoint(x: 50, y: 50), topRight: CGPoint(x: 56, y: 50), bottomRight: CGPoint(x: 56, y: 56), bottomLeft: CGPoint(x: 50, y: 56)
        )
        let cornersOutsideThePhoto = RoomArtCorners(
            topLeft: CGPoint(x: 300, y: 300), topRight: CGPoint(x: 400, y: 300), bottomRight: CGPoint(x: 400, y: 400), bottomLeft: CGPoint(x: 300, y: 400)
        )

        #expect(furnitureCutout(picture: picture, itemCorners: tinyCorners, context: CIContext()) == nil)
        #expect(furnitureCutout(picture: picture, itemCorners: cornersOutsideThePhoto, context: CIContext()) == nil)
    }

    @Test func aPhotoWithNothingInItGivesNoCutout() {
        let emptyPhoto = solidImage(width: 200, height: 200, shapeInTheMiddle: false)
        let corners = RoomArtCorners(
            topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 200, y: 0), bottomRight: CGPoint(x: 200, y: 200), bottomLeft: CGPoint(x: 0, y: 200)
        )

        #expect(furnitureCutout(picture: emptyPhoto, itemCorners: corners, context: CIContext()) == nil)
    }

    /// Vision's foreground mask on a generated image: when it finds the red block, the cutout is the block trimmed to its own
    /// pixels, opaque in its middle. When Vision finds no subject in a generated image, the cutout is nil, which is the same
    /// path a photo with no subject takes, and the test checks only that.
    @Test func theProductIsCutOutOfItsBackground() throws {
        let picture = solidImage(width: 240, height: 240, shapeInTheMiddle: true)
        // Corners a little larger than the block, so the white background is in the crop. Clamped into the photo, they crop 20 to 220.
        let corners = RoomArtCorners(
            topLeft: CGPoint(x: 20, y: 20), topRight: CGPoint(x: 220, y: 20), bottomRight: CGPoint(x: 220, y: 220), bottomLeft: CGPoint(x: 20, y: 220)
        )

        guard let cutout = furnitureCutout(picture: picture, itemCorners: corners, context: CIContext()) else {
            print("RoomFloorTests: Vision found no subject in the generated image, so only the nil path ran")
            return
        }

        print("RoomFloorTests: Vision found the generated block, so the opaque and transparent pixels were checked")
        // The block is 120 by 144, so the white around it inside the corners is trimmed away.
        #expect(abs(cutout.width - 120) <= 6 && abs(cutout.height - 144) <= 6, "the cutout is \(cutout.width) by \(cutout.height)")
        #expect(alphaOfThePixel(in: cutout, x: cutout.width / 2, y: cutout.height / 2) > 200)
    }

    @Test func theOpaqueBoxIsTheSmallestRectangleHoldingEveryOpaquePixel() throws {
        // A clear 50 by 40 image with an opaque patch from column 10 to 29 and row 5 to 34, top left origin.
        let context = CGContext(data: nil, width: 50, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        // CGContext's y grows up, so rows 5 to 34 from the top are 5 to 34 from the bottom in a 40 tall image.
        context.fill(CGRect(x: 10, y: 5, width: 20, height: 30))
        // A faint pixel, under the 10 percent alpha floor, which the box leaves out.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.05))
        context.fill(CGRect(x: 45, y: 1, width: 1, height: 1))
        let image = try #require(context.makeImage())

        #expect(opaqueBoundingBox(of: image) == CGRect(x: 10, y: 5, width: 20, height: 30))

        let clearContext = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        #expect(opaqueBoundingBox(of: try #require(clearContext.makeImage())) == nil)
    }
}

struct RoomFurnitureTests {
    @Test func theCutoutIsDrawnAtItsOwnShapeAtThePagesHeightAndTheSizeIsSaidFromThePage() throws {
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let furniture = RoomFurniture(title: "POÄNG", widthMeters: 0.68, heightMeters: 1.0, depthMeters: 0.82, cutoutImage: try #require(context.makeImage()))

        // A three quarter view photo is wider than the page's width says, and is drawn at its own shape, never squashed.
        #expect(abs(furniture.drawnWidthMeters - 1.5) < 1e-9)
        #expect(furniture.sizeInWords == "27 inches wide and 39.5 tall")
        #expect(roomFurnitureSizeInWords(widthCentimeters: 80, heightCentimeters: 75) == "31.5 inches wide and 29.5 tall")
    }
}
