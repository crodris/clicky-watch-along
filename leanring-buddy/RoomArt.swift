//
//  RoomArt.swift
//  leanring-buddy
//
//  "Show me how this would look in my room": Clicky reads the wall art on Chrome's front tab and its size from the page,
//  opens a live camera panel, and hangs the art on the learner's wall at its real size.
//
//  This file holds the pure parts: the Worker replies parsed into Swift types (`POST /try-it-item` reads the page and says
//  what kind of item it shows, `POST /room-wall` measures the wall with Depth Pro), the art's corners projected from the wall
//  plane, the bare wall spot the art goes to first, the wall's light, the phase state machine behind the panel, the clients,
//  and the phrase that asks for it. `RoomTracker` keeps the art on the wall, `RoomCamera` supplies the frames, `RoomArtLoop`
//  draws Clicky's loop around the spot while it is measured, and `RoomArtPreview` runs and draws the panel.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - The picture and the page

/// A JPEG of the largest picture in Chrome's front tab, the page's image file or a screen capture of it
/// (`RoomArtPictureSource`). The page's corners are in its pixels.
nonisolated struct RoomArtPicture: Equatable, Sendable {
    let jpegData: Data
    let width: Int
    let height: Int
}

/// What Clicky sends `POST /try-it-item`: the page, its picture, and the learner's words.
nonisolated struct RoomArtPageRequest: Equatable, Sendable {
    /// The Worker refuses a page title, page text, and learner request over these many UTF-16 code units, so the app cuts
    /// them first.
    static let longestPageTitle = 500
    static let longestPageText = 30_000
    static let longestLearnerRequest = 500

    let pageURL: String
    let pageTitle: String
    let pageText: String
    /// What the learner said, which tells the Worker which item they mean when the page shows several. Empty says nothing.
    let learnerRequest: String
    let picture: RoomArtPicture

    init(pageURL: String, pageTitle: String, pageText: String, learnerRequest: String, picture: RoomArtPicture) {
        self.pageURL = pageURL
        self.pageTitle = textCutToUTF16Count(pageTitle, longestUTF16Count: Self.longestPageTitle)
        self.pageText = textCutToUTF16Count(pageText, longestUTF16Count: Self.longestPageText)
        self.learnerRequest = textCutToUTF16Count(learnerRequest, longestUTF16Count: Self.longestLearnerRequest)
        self.picture = picture
    }

    var json: JSONValue {
        var fields: [String: JSONValue] = [
            "pageURL": .string(pageURL),
            "pageTitle": .string(pageTitle),
            "pageText": .string(pageText),
            "picture": .object([
                "jpegBase64": .string(picture.jpegData.base64EncodedString()),
                "width": .number(Double(picture.width)),
                "height": .number(Double(picture.height)),
            ]),
        ]
        if !learnerRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields["learnerRequest"] = .string(learnerRequest)
        }
        return .object(fields)
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

/// What `POST /try-it-item` read from the page and its picture, by the kind of item the learner wants to try. Wall art hangs
/// on the wall, furniture stands on the floor, and a top is drawn over the learner (`roomArtReadingPlan`).
nonisolated enum RoomArtPageReading: Equatable, Sendable {
    case wallArt(RoomArtWallArtReading)
    /// Wall art whose page text states no size, so Clicky says so instead of hanging a size the model guessed.
    case sizeNotOnThePage(title: String)
    case furniture(RoomArtFurnitureReading)
    case clothing(RoomArtClothingReading)
    /// Anything else, such as a lamp or a rug.
    case other(title: String)
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

/// A size a store sells furniture in: across the front, floor to top, and front to back.
nonisolated struct RoomArtFurnitureSize: Equatable, Sendable {
    let label: String
    let widthCentimeters: Double
    let heightCentimeters: Double
    let depthCentimeters: Double
}

nonisolated struct RoomArtFurnitureReading: Equatable, Sendable {
    let title: String
    /// Nil when the page text states no size.
    let chosenSize: RoomArtFurnitureSize?
    let whyThisSize: String
    /// Where the furniture sits in the picture, clamped into it.
    let itemCorners: RoomArtCorners
}

nonisolated enum RoomArtGarment: String, Decodable, Equatable, Sendable {
    case tshirt, shirt, sweater, hoodie, jacket, dress, other
}

nonisolated enum RoomArtSleeves: String, Decodable, Equatable, Sendable {
    case none, short, long
}

/// How the product photo shows the garment.
nonisolated enum RoomArtGarmentPhoto: String, Decodable, Equatable, Sendable {
    case flatLay, onModel, onHanger, other
}

nonisolated struct RoomArtClothingReading: Equatable, Sendable {
    let title: String
    let garment: RoomArtGarment
    let sleeves: RoomArtSleeves
    /// The size the page shows as selected, as the page writes it, such as "M". Page text, so it is only logged.
    let chosenSizeLabel: String
    let photoShows: RoomArtGarmentPhoto
    /// What the print on the garment looks like, empty for a plain garment. Page-derived text, so it is only logged.
    let printDescription: String
    let whyThisSize: String
    /// Where the garment sits in the picture, clamped into it.
    let itemCorners: RoomArtCorners
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

nonisolated private struct RoomArtFurnitureSizeReply: Decodable {
    let label: String
    let widthCentimeters: Double
    let heightCentimeters: Double
    let depthCentimeters: Double
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

nonisolated private struct RoomArtWallArtReply: Decodable {
    let sizeFoundOnPage: Bool
    let size: RoomArtChosenSizeReply
    let otherSizes: [RoomArtSizeReply]
}

nonisolated private struct RoomArtFurnitureReply: Decodable {
    let sizeFoundOnPage: Bool
    let size: RoomArtFurnitureSizeReply
}

nonisolated private struct RoomArtClothingReply: Decodable {
    let garment: RoomArtGarment
    let sleeves: RoomArtSleeves
    let chosenSizeLabel: String
    let photoShows: RoomArtGarmentPhoto
    let printDescription: String
}

/// The reply's `item`: its kind and the one object that kind names. A kind this app does not know fails to decode.
nonisolated private enum RoomArtItemReply: Decodable {
    case wallArt(RoomArtWallArtReply)
    case furniture(RoomArtFurnitureReply)
    case clothing(RoomArtClothingReply)
    case other

    private enum CodingKeys: String, CodingKey {
        case kind, wallArt, furniture, clothing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "wallArt": self = .wallArt(try container.decode(RoomArtWallArtReply.self, forKey: .wallArt))
        case "furniture": self = .furniture(try container.decode(RoomArtFurnitureReply.self, forKey: .furniture))
        case "clothing": self = .clothing(try container.decode(RoomArtClothingReply.self, forKey: .clothing))
        case "other": self = .other
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "an item kind this app does not know")
        }
    }
}

nonisolated private struct RoomArtTryItReply: Decodable {
    let title: String
    let whyThisSize: String
    let itemCorners: RoomArtCornersReply
    let item: RoomArtItemReply
}

extension RoomArtPageReading {
    /// Parses the Worker's reply, whose `item` names a kind and holds that kind's own object. Wall art whose page states its
    /// size needs a sensible size and corners that enclose part of the picture, which are clamped into it, since a model's
    /// corner can land a pixel or two outside. Sizes that are not sensible are dropped from the other sizes. Wall art whose
    /// page states no size needs neither, since nothing is hung. Furniture and clothing keep what was read, with their
    /// corners clamped into the picture, since a later PR places them.
    nonisolated init(responseData: Data, pictureWidth: Int, pictureHeight: Int) throws {
        let reply: RoomArtTryItReply
        do {
            reply = try JSONDecoder().decode(RoomArtTryItReply.self, from: responseData)
        } catch {
            throw RoomArtReplyError(reason: "the reply is not the try-it-item shape")
        }
        func pointInThePicture(_ pointReply: RoomArtPointReply) throws -> CGPoint {
            guard pointReply.x.isFinite, pointReply.y.isFinite else { throw RoomArtReplyError(reason: "a corner is not a number") }
            return CGPoint(x: min(max(pointReply.x, 0), Double(pictureWidth)), y: min(max(pointReply.y, 0), Double(pictureHeight)))
        }
        func itemCornersInThePicture() throws -> RoomArtCorners {
            RoomArtCorners(
                topLeft: try pointInThePicture(reply.itemCorners.topLeft),
                topRight: try pointInThePicture(reply.itemCorners.topRight),
                bottomRight: try pointInThePicture(reply.itemCorners.bottomRight),
                bottomLeft: try pointInThePicture(reply.itemCorners.bottomLeft)
            )
        }

        switch reply.item {
        case .other:
            self = .other(title: reply.title)
        case .clothing(let clothingReply):
            self = .clothing(RoomArtClothingReading(
                title: reply.title,
                garment: clothingReply.garment,
                sleeves: clothingReply.sleeves,
                chosenSizeLabel: clothingReply.chosenSizeLabel,
                photoShows: clothingReply.photoShows,
                printDescription: clothingReply.printDescription,
                whyThisSize: reply.whyThisSize,
                itemCorners: try itemCornersInThePicture()
            ))
        case .furniture(let furnitureReply):
            let sizeReply = furnitureReply.size
            let chosenSize: RoomArtFurnitureSize?
            if furnitureReply.sizeFoundOnPage {
                guard [sizeReply.widthCentimeters, sizeReply.heightCentimeters, sizeReply.depthCentimeters].allSatisfy({ sensibleArtCentimeters.contains($0) }),
                      !sizeReply.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RoomArtReplyError(reason: "furniture.size needs a label and a width, height, and depth from 1 to 1000 cm")
                }
                chosenSize = RoomArtFurnitureSize(
                    label: sizeReply.label,
                    widthCentimeters: sizeReply.widthCentimeters,
                    heightCentimeters: sizeReply.heightCentimeters,
                    depthCentimeters: sizeReply.depthCentimeters
                )
            } else {
                chosenSize = nil
            }
            self = .furniture(RoomArtFurnitureReading(title: reply.title, chosenSize: chosenSize, whyThisSize: reply.whyThisSize, itemCorners: try itemCornersInThePicture()))
        case .wallArt(let wallArtReply):
            guard wallArtReply.sizeFoundOnPage else {
                self = .sizeNotOnThePage(title: reply.title)
                return
            }
            let chosenSize = wallArtReply.size
            guard sensibleArtCentimeters.contains(chosenSize.widthCentimeters),
                  sensibleArtCentimeters.contains(chosenSize.heightCentimeters),
                  !chosenSize.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RoomArtReplyError(reason: "wallArt.size needs a label and a width and height from 1 to 1000 cm")
            }
            let corners = try itemCornersInThePicture()
            // A sliver is a misread: real art covers at least a hundredth of its own product photo.
            guard corners.area >= Double(pictureWidth * pictureHeight) / 100 else {
                throw RoomArtReplyError(reason: "itemCorners enclose almost none of the picture")
            }
            self = .wallArt(RoomArtWallArtReading(
                title: reply.title,
                chosenSize: RoomArtSize(label: chosenSize.label, widthCentimeters: chosenSize.widthCentimeters, heightCentimeters: chosenSize.heightCentimeters),
                chosenSizeIncludesFrame: chosenSize.includesFrame,
                whyThisSize: reply.whyThisSize,
                otherSizes: wallArtReply.otherSizes
                    .filter { sensibleArtCentimeters.contains($0.widthCentimeters) && sensibleArtCentimeters.contains($0.heightCentimeters) }
                    .map { RoomArtSize(label: $0.label, widthCentimeters: $0.widthCentimeters, heightCentimeters: $0.heightCentimeters) },
                artworkCorners: corners
            ))
        }
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

/// A length in inches rounded to the nearest half inch, with no unit: "16", or "8.5".
nonisolated func roomArtInchesInWords(centimeters: Double) -> String {
    let halfInches = (centimeters / 2.54 * 2).rounded()
    return halfInches.truncatingRemainder(dividingBy: 2) == 0 ? String(Int(halfInches / 2)) : String(format: "%.1f", halfInches / 2)
}

/// A size in inches rounded to the nearest half inch, width first: "16 by 20 inches", or "8.5 by 11 inches".
nonisolated func roomArtSizeInInches(widthCentimeters: Double, heightCentimeters: Double) -> String {
    "\(roomArtInchesInWords(centimeters: widthCentimeters)) by \(roomArtInchesInWords(centimeters: heightCentimeters)) inches"
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

// MARK: - Where the item goes first

/// The window `bareWallSpot` scores around each candidate spot, as shares of the frame. The loop drawn while the wall is
/// measured is sized to the same window, so it outlines the wall the spot was chosen for.
nonisolated enum RoomArtBareWallWindow {
    static let widthShareOfTheFrame = 0.24
    static let heightShareOfTheFrame = 0.3
    /// The rows a spot's center may sit on, as shares of the frame's height: the upper middle, where art hangs.
    static let centerRowShares = 0.25...0.55
}

/// The window `bareFloorSpot` scores, as shares of the frame: wide and low, the shape of floor seen at a slant. The loop
/// drawn while the floor is measured is sized to it.
nonisolated enum RoomArtBareFloorWindow {
    static let widthShareOfTheFrame = 0.3
    static let heightShareOfTheFrame = 0.18
    /// The lower part of the frame, where the floor shows when the screen is tilted down. The depth service fits the floor
    /// in a window around and below the anchor, so the lowest rows are left for it.
    static let centerRowShares = 0.62...0.86
    /// How much more a spot at the frame's side edge costs than one in the middle, as a share of its texture: furniture
    /// standing at the edge is cut off by the frame, and the darkest, plainest floor is often a far corner.
    static let costOfTheSideEdges = 1.0
}

/// The spot of the frame with the least texture, away from the person, in the upper part of the frame where art hangs, and
/// far enough from the edges for the art to fit, in the image's pixels. `grayscale` is the frame at the track size and
/// `roomMask` is 0 on the person and 1 on the room, at the same size.
nonisolated func bareWallSpot(grayscale: RoomGrayscaleImage, roomMask: [Float]) -> CGPoint {
    quietestSpot(
        grayscale: grayscale, roomMask: roomMask,
        windowWidthShare: RoomArtBareWallWindow.widthShareOfTheFrame, windowHeightShare: RoomArtBareWallWindow.heightShareOfTheFrame,
        centerRowShares: RoomArtBareWallWindow.centerRowShares,
        spotWhenNothingFits: CGPoint(x: Double(grayscale.width) / 2, y: Double(grayscale.height) / 3)
    )
}

/// Where furniture stands first: the open floor with the least texture, away from the person, in the lower part of the
/// frame, leaning toward the middle so the whole piece stays in view, in the image's pixels. The spot is the furniture's
/// front-bottom center, the anchor `POST /room-floor` takes. An open patch of floor has less texture than the edge of a rug
/// or another piece of furniture, so the piece lands in the open.
nonisolated func bareFloorSpot(grayscale: RoomGrayscaleImage, roomMask: [Float]) -> CGPoint {
    quietestSpot(
        grayscale: grayscale, roomMask: roomMask,
        windowWidthShare: RoomArtBareFloorWindow.widthShareOfTheFrame, windowHeightShare: RoomArtBareFloorWindow.heightShareOfTheFrame,
        centerRowShares: RoomArtBareFloorWindow.centerRowShares,
        costOfTheSideEdges: RoomArtBareFloorWindow.costOfTheSideEdges,
        spotWhenNothingFits: CGPoint(x: Double(grayscale.width) / 2, y: Double(grayscale.height) * 0.8)
    )
}

/// The center of the window of the given shape with the least texture, with every pixel within 15 of the person counted as
/// the most texture there is, so the spot stays off them. Centers run along `centerRowShares` of the height, and far
/// enough from the side edges for the window to fit. `costOfTheSideEdges` raises a window's score in step with its
/// distance from the middle column, up to that share more at the edge, with each pixel counted as at least 1 so a blank
/// window still prefers the middle; 0 leaves the score as the texture alone.
nonisolated private func quietestSpot(
    grayscale: RoomGrayscaleImage,
    roomMask: [Float],
    windowWidthShare: Double,
    windowHeightShare: Double,
    centerRowShares: ClosedRange<Double>,
    costOfTheSideEdges: Double = 0,
    spotWhenNothingFits: CGPoint
) -> CGPoint {
    let width = grayscale.width, height = grayscale.height
    let texture = textureWithThePersonMarked(grayscale: grayscale, roomMask: roomMask)

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

    let windowWidth = Int((Double(width) * windowWidthShare).rounded())
    let windowHeight = Int((Double(height) * windowHeightShare).rounded())
    var bestSpot = spotWhenNothingFits
    var bestScore = Double.infinity
    let firstRow = Int((Double(height) * centerRowShares.lowerBound).rounded()), lastRow = Int((Double(height) * centerRowShares.upperBound).rounded())
    let firstColumn = (windowWidth + 1) / 2 + 4, lastColumn = width - windowWidth / 2 - 4
    guard firstColumn <= lastColumn, firstRow <= lastRow else { return bestSpot }
    for row in stride(from: firstRow, through: lastRow, by: 4) {
        for column in stride(from: firstColumn, through: lastColumn, by: 4) {
            let texture = windowTotal(left: column - windowWidth / 2, top: row - windowHeight / 2, right: column + (windowWidth + 1) / 2, bottom: row + (windowHeight + 1) / 2)
            let shareOfTheWayToTheSideEdge = abs(Double(column) - Double(width) / 2) / (Double(width) / 2)
            let score = costOfTheSideEdges == 0
                ? texture
                : (texture + Double(windowWidth * windowHeight)) * (1 + costOfTheSideEdges * shareOfTheWayToTheSideEdge)
            if score < bestScore {
                bestScore = score
                bestSpot = CGPoint(x: column, y: row)
            }
        }
    }
    return bestSpot
}

/// The Sobel gradient's size at each pixel of `grayscale`, with every pixel within 15 of the person set to 1,000, the most
/// texture there is, so a spot search stays off them.
nonisolated func textureWithThePersonMarked(grayscale: RoomGrayscaleImage, roomMask: [Float]) -> [Float] {
    let width = grayscale.width, height = grayscale.height
    let pixels = grayscale.pixels
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
    let personNearby = grownSquare(roomMask.map { $0 < 0.5 }, width: width, height: height, reach: 15)
    for index in texture.indices where personNearby[index] {
        texture[index] = 1_000
    }
    return texture
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
    /// The item is neither wall art, furniture, nor clothing, such as a lamp.
    case notSomethingToTry
    /// The page text could not be read or was empty, or `POST /try-it-item` failed.
    case pageNotRead
    /// The page is wall art or furniture, but its text states no size, so nothing is placed at a size the model guessed.
    case sizeNotOnThePage
    /// A measurement route answered 503 (no depth service configured) or 502 (the depth service is down).
    case depthServiceUnavailable
    /// `POST /room-wall` answered 422 (no bare wall there, or a wall too near, too far, or not flat), or its reply could
    /// not place the art.
    case wallNotMeasured
    /// `POST /room-floor` answered 422 (no floor in view there, or one too tilted, near, or far), or its reply could not
    /// stand the furniture on it. The panel stays open and a click on the floor measures again.
    case floorNotFound
    /// Vision found no furniture in the product photo, so nothing can stand on the floor.
    case furnitureNotCutOut
    /// The clothing is not a top, such as a dress, which the shirt overlay cannot draw.
    case onlyTopsSoFar
    /// The product photo shows the shirt on a model, whose body would come along with the cutout.
    case shirtPhotoOnAModel
    /// The product photo shows the shirt on a hanger or some other way that is not a flat lay.
    case shirtPhotoNotFlat
    /// Vision found no garment in the flat lay photo.
    case garmentNotCutOut
    /// A request to the Worker never got an answer: the Worker is not running, the connection failed, or it timed out.
    case workerUnreachable

    /// What Clicky says.
    var spokenLine: String {
        switch self {
        case .appSecretMissing: return "Clicky needs its app secret for this. See the README's Worker setup."
        case .pageNotHTTPS: return "I can only read store pages served over https."
        case .cameraAccessDenied: return "I need camera access for that. You can turn it on in System Settings."
        case .noCamera: return "I couldn't find a camera to show your room."
        case .notSomethingToTry: return "That doesn't look like wall art, furniture, or a shirt."
        case .pageNotRead: return "I couldn't read that page."
        case .sizeNotOnThePage: return "I couldn't find the size on that page."
        case .depthServiceUnavailable: return "I couldn't measure your room. Is the depth service running?"
        case .wallNotMeasured: return "I couldn't measure your wall. Try pointing the camera at a bare wall."
        case .floorNotFound: return "I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor."
        case .furnitureNotCutOut: return "I couldn't cut the furniture out of its photo."
        case .onlyTopsSoFar: return "I can try on shirts, sweaters, and jackets so far."
        case .shirtPhotoOnAModel: return "I can only try on a shirt from a flat photo of it, and this photo shows it on a model."
        case .shirtPhotoNotFlat: return "I can only try on a shirt from a flat photo of it."
        case .garmentNotCutOut: return "I couldn't lift the shirt out of its photo."
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
        case .notSomethingToTry: return "That doesn't look like wall art, furniture, or a shirt"
        case .pageNotRead: return "Couldn't read the page"
        case .sizeNotOnThePage: return "Couldn't find the size on the page"
        case .depthServiceUnavailable: return "Couldn't measure the room. Is the depth service running?"
        case .wallNotMeasured: return "Couldn't measure the wall"
        case .floorNotFound: return "Tilt the screen down so the floor shows, then click the floor"
        case .furnitureNotCutOut: return "Couldn't cut the furniture out of its photo"
        case .onlyTopsSoFar: return "Only shirts, sweaters, and jackets so far"
        case .shirtPhotoOnAModel: return "The photo shows the shirt on a model, not laid flat"
        case .shirtPhotoNotFlat: return "The photo is not a flat photo of the shirt"
        case .garmentNotCutOut: return "Couldn't lift the shirt out of its photo"
        case .workerUnreachable: return "Couldn't reach Clicky's Worker"
        }
    }
}

// MARK: - What the reading asks for

/// What the panel does with the page's reading. Only wall art and furniture whose page states a size are placed, so a size
/// the model guessed never reaches the room, and only a top photographed flat is tried on, since a photo on a model would
/// bring the model's body into the cutout.
nonisolated enum RoomArtReadingPlan: Equatable, Sendable {
    case hangOnTheWall(RoomArtWallArtReading)
    case standOnTheFloor(RoomArtFurnitureReading, size: RoomArtFurnitureSize)
    case tryOnTheShirt(RoomArtClothingReading)
    case fail(RoomArtFailure)
}

/// The garments the shirt overlay can draw: tops, whose body is the learner's torso. A dress reaches past the hips, so its
/// hem would land on the wrong place.
nonisolated let roomArtGarmentsThatCanBeTriedOn: Set<RoomArtGarment> = [.tshirt, .shirt, .sweater, .hoodie, .jacket]

nonisolated func roomArtReadingPlan(for pageReading: RoomArtPageReading) -> RoomArtReadingPlan {
    switch pageReading {
    case .wallArt(let wallArtReading):
        return .hangOnTheWall(wallArtReading)
    case .sizeNotOnThePage:
        return .fail(.sizeNotOnThePage)
    case .furniture(let furnitureReading):
        guard let chosenSize = furnitureReading.chosenSize else { return .fail(.sizeNotOnThePage) }
        return .standOnTheFloor(furnitureReading, size: chosenSize)
    case .clothing(let clothingReading):
        guard roomArtGarmentsThatCanBeTriedOn.contains(clothingReading.garment) else { return .fail(.onlyTopsSoFar) }
        switch clothingReading.photoShows {
        case .flatLay: return .tryOnTheShirt(clothingReading)
        case .onModel: return .fail(.shirtPhotoOnAModel)
        case .onHanger, .other: return .fail(.shirtPhotoNotFlat)
        }
    case .other:
        return .fail(.notSomethingToTry)
    }
}

// MARK: - Surfaces and what stands on them

/// The two surfaces an item is measured on: wall art hangs on a wall and furniture stands on a floor.
nonisolated enum RoomArtSurfaceKind: Equatable, Sendable {
    case wall
    case floor
}

/// A measured surface in the keyframe camera's space.
nonisolated enum RoomArtSurface: Equatable, Sendable {
    case wall(WallPlane)
    case floor(FloorPlane)

    var kind: RoomArtSurfaceKind {
        switch self {
        case .wall: return .wall
        case .floor: return .floor
        }
    }

    /// Where `item` lands in the keyframe on this surface, or nil when a corner is not in front of the camera or the item
    /// belongs on the other surface.
    func keyframeCorners(of item: RoomArtPlacedItem) -> RoomArtCorners? {
        switch (self, item) {
        case (.wall(let wall), .wallArt(let artwork)):
            return wall.keyframeCorners(widthMeters: artwork.widthMeters, heightMeters: artwork.heightMeters)
        case (.floor(let floor), .furniture(let furniture)):
            return floor.keyframeCorners(widthMeters: furniture.drawnWidthMeters, heightMeters: furniture.heightMeters)
        case (.wall, .furniture), (.floor, .wallArt):
            return nil
        }
    }
}

/// What is placed on a surface: the art flattened from its photo, or the furniture cut out of its photo.
nonisolated enum RoomArtPlacedItem: Equatable, Sendable {
    case wallArt(RoomArtwork)
    case furniture(RoomFurniture)

    var surfaceKind: RoomArtSurfaceKind {
        switch self {
        case .wallArt: return .wall
        case .furniture: return .floor
        }
    }

    /// The picture drawn on the surface.
    var image: CGImage {
        switch self {
        case .wallArt(let artwork): return artwork.flattenedImage
        case .furniture(let furniture): return furniture.cutoutImage
        }
    }

    /// What Clicky says once it shows, with the size from the measured centimeters.
    var hereItIsLine: String {
        switch self {
        case .wallArt(let artwork): return "Here it is at \(artwork.sizeInWords)."
        case .furniture(let furniture): return "Here it is, \(furniture.sizeInWords)."
        }
    }

    var showingStatusLine: String {
        switch self {
        case .wallArt(let artwork): return "On your wall at \(artwork.sizeInWords)"
        case .furniture(let furniture): return "On your floor, \(furniture.sizeInWords)"
        }
    }
}

extension RoomArtSurfaceKind {
    var measuringStatusLine: String {
        switch self {
        case .wall: return "Measuring your wall…"
        case .floor: return "Measuring your floor…"
        }
    }

    /// The status line while the tracker has lost the room and the item is hidden.
    var lostLine: String {
        switch self {
        case .wall: return "Lost the wall. Turn back, or click the wall to place it again."
        case .floor: return "Lost the floor. Turn back, or click the floor to place it again."
        }
    }

    /// Why a measured surface that cannot place the item failed.
    var cannotPlaceFailure: RoomArtFailure {
        switch self {
        case .wall: return .wallNotMeasured
        case .floor: return .floorNotFound
        }
    }
}

// MARK: - Phase

/// One measurement: a keyframe and the surface measured on it. A reply carries the measurement it belongs to, so a reply
/// from an earlier measurement or an earlier panel changes nothing.
nonisolated struct RoomArtMeasurementID: Hashable, Sendable {
    let number: Int
}

/// What the panel is doing. The page is read as the panel opens, and its kind picks the rest: wall art and furniture are
/// measured on their surface and tracked, and a shirt is drawn over the learner with no measurement at all.
nonisolated enum RoomArtPhase: Equatable, Sendable {
    case closed
    /// The panel is open: the camera starts and the page is read at once.
    case readingThePage
    /// The item is read and ready, and the keyframe waits for the camera's first frame with a person mask.
    case waitingForTheCamera(RoomArtPlacedItem)
    /// The keyframe is taken and its surface is being measured.
    case measuring(id: RoomArtMeasurementID, item: RoomArtPlacedItem)
    /// The item is on its surface. `moveFailure` is why the last click could not move it, shown in the status line until
    /// the next move, with the item back where it was.
    case showing(item: RoomArtPlacedItem, surface: RoomArtSurface, moveFailure: RoomArtFailure?)
    /// A click moves the item: a new keyframe and a new measurement. The surface it stood on comes back if the new one is
    /// not measured.
    case moving(id: RoomArtMeasurementID, item: RoomArtPlacedItem, surfaceBeforeTheMove: RoomArtSurface)
    /// The first floor measurement found no floor, so the camera keeps running and a click on the floor measures again.
    case waitingForAFloorClick(RoomArtPlacedItem)
    /// A flat lay top: the garment is being cut out of its photo while the camera looks for the learner.
    case preparingTheShirt(title: String)
    /// The garment is ready, and the learner is not yet standing where the shirt can be drawn.
    case waitingToSeeTheLearner(title: String)
    /// The shirt is drawn over the learner every frame they stand in view.
    case showingTheShirt(title: String)
    case failed(RoomArtFailure)

    var isOpen: Bool { self != .closed }

    // MARK: Transitions

    /// The learner asked to try the item. A panel already open starts over.
    func opening() -> RoomArtPhase {
        .readingThePage
    }

    /// Wall art or furniture was read and its picture prepared, so its surface can be measured once the camera has a frame.
    func withTheItemReady(_ item: RoomArtPlacedItem) -> RoomArtPhase {
        guard case .readingThePage = self else { return self }
        return .waitingForTheCamera(item)
    }

    /// A flat lay top was read, so the garment is cut out while the camera looks for the learner.
    func startingTheShirt(title: String) -> RoomArtPhase {
        guard case .readingThePage = self else { return self }
        return .preparingTheShirt(title: title)
    }

    /// The page could not be read, or what it shows cannot be tried, so the panel says why.
    func afterThePageFailed(_ failure: RoomArtFailure) -> RoomArtPhase {
        guard case .readingThePage = self else { return self }
        return .failed(failure)
    }

    /// A keyframe was taken: the first one once the item is ready and the camera runs, a click that moves the item, or a
    /// click on the floor after none was found. One measurement runs at a time, so a click during one changes nothing.
    func startingAMeasurement(id: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .waitingForTheCamera(let item), .waitingForAFloorClick(let item):
            return .measuring(id: id, item: item)
        case .showing(let item, let surface, _):
            return .moving(id: id, item: item, surfaceBeforeTheMove: surface)
        case .closed, .readingThePage, .measuring, .moving, .preparingTheShirt, .waitingToSeeTheLearner, .showingTheShirt, .failed:
            return self
        }
    }

    func withTheSurfaceMeasured(_ surface: RoomArtSurface, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .measuring(let measuringID, let item) where measuringID == measurementID && surface.kind == item.surfaceKind:
            guard surface.keyframeCorners(of: item) != nil else { return Self.afterTheFirstMeasurementFailed(item.surfaceKind.cannotPlaceFailure, item: item) }
            return .showing(item: item, surface: surface, moveFailure: nil)
        case .moving(let movingID, let item, let surfaceBeforeTheMove) where movingID == measurementID && surface.kind == item.surfaceKind:
            guard surface.keyframeCorners(of: item) != nil else {
                return .showing(item: item, surface: surfaceBeforeTheMove, moveFailure: item.surfaceKind.cannotPlaceFailure)
            }
            return .showing(item: item, surface: surface, moveFailure: nil)
        default:
            return self
        }
    }

    /// A measurement failed. A first measurement's failure ends the panel, except a floor that was not found, which waits
    /// for a click on the floor. A move's failure puts the item back where it stood.
    func afterTheMeasurementFailed(_ failure: RoomArtFailure, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .measuring(let measuringID, let item) where measuringID == measurementID:
            return Self.afterTheFirstMeasurementFailed(failure, item: item)
        case .moving(let movingID, let item, let surfaceBeforeTheMove) where movingID == measurementID:
            return .showing(item: item, surface: surfaceBeforeTheMove, moveFailure: failure)
        default:
            return self
        }
    }

    private static func afterTheFirstMeasurementFailed(_ failure: RoomArtFailure, item: RoomArtPlacedItem) -> RoomArtPhase {
        if failure == .floorNotFound, case .furniture = item { return .waitingForAFloorClick(item) }
        return .failed(failure)
    }

    /// The garment is cut out. `learnerIsInFrame` says the framing already settled on ready, so the shirt shows at once.
    func withTheGarmentReady(learnerIsInFrame: Bool) -> RoomArtPhase {
        guard case .preparingTheShirt(let title) = self else { return self }
        return learnerIsInFrame ? .showingTheShirt(title: title) : .waitingToSeeTheLearner(title: title)
    }

    func afterTheGarmentFailed() -> RoomArtPhase {
        guard case .preparingTheShirt = self else { return self }
        return .failed(.garmentNotCutOut)
    }

    /// The framing settled on ready for the first time since the garment was ready.
    func afterTheLearnerStoodInFrame() -> RoomArtPhase {
        guard case .waitingToSeeTheLearner(let title) = self else { return self }
        return .showingTheShirt(title: title)
    }

    /// The camera could not start. It starts while the page is read, so this can come in any open phase before a frame.
    func afterTheCameraFailed(_ failure: RoomArtFailure) -> RoomArtPhase {
        switch self {
        case .closed, .failed: return self
        default: return .failed(failure)
        }
    }

    func closing() -> RoomArtPhase {
        .closed
    }

    /// The panel's one-line status with nothing lost and no coaching.
    var statusLine: String {
        statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil)
    }

    /// The panel's one-line status. `theSurfaceIsLost` says the tracker lost the room long enough to hide the item, which
    /// only matters while it shows, and `shirtCoachingLine` is the settled framing's advice while the shirt cannot be drawn.
    func statusLine(theSurfaceIsLost: Bool, shirtCoachingLine: String?) -> String {
        switch self {
        case .closed: return ""
        case .readingThePage: return "Reading the page…"
        case .waitingForTheCamera: return "Starting the camera…"
        case .measuring(_, let item): return item.surfaceKind.measuringStatusLine
        case .moving(_, let item, _): return item.surfaceKind.measuringStatusLine
        case .showing(let item, _, let moveFailure):
            if theSurfaceIsLost { return item.surfaceKind.lostLine }
            return moveFailure?.statusLine ?? item.showingStatusLine
        case .waitingForAFloorClick: return RoomArtFailure.floorNotFound.statusLine
        case .preparingTheShirt: return shirtCoachingLine ?? "Getting the shirt ready…"
        case .waitingToSeeTheLearner: return shirtCoachingLine ?? "Looking for you…"
        case .showingTheShirt: return shirtCoachingLine ?? "On you"
        case .failed(let failure): return failure.statusLine
        }
    }

    /// Whether the status line says what went wrong, so the panel draws it in the failure color.
    func statusLineIsAFailure(theSurfaceIsLost: Bool) -> Bool {
        switch self {
        case .failed, .waitingForAFloorClick: return true
        case .showing(_, _, let moveFailure): return moveFailure != nil && !theSurfaceIsLost
        case .closed, .readingThePage, .waitingForTheCamera, .measuring, .moving, .preparingTheShirt, .waitingToSeeTheLearner, .showingTheShirt:
            return false
        }
    }
}

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

/// Whether the learner asks to see this item placed in their own room or on themselves: a room phrase ("in my room", "on my
/// wall", "on the wall behind me", "on me", ...) right after either a placing verb and the item ("show this", "put it",
/// "can I see this", "hang that print", "could I see this shirt") or the item and a look ("how would this look", "what
/// would that poster look like", "would this look good", "how would this look hanging"), or "try" with the item and "on"
/// ending the request ("can I try this on", "try on that shirt"). The item is "this", "it", or "that", or "this", "that",
/// or "the" and one noun. So "how does the router in my house work", "what would look good in my room", "I put a poster in
/// my room", "what's on me", and "let me try this on the next video" name no item to place, and none of them asks.
nonisolated func asksToSeeArtInMyRoom(_ transcript: String) -> Bool {
    let apostrophes = CharacterSet(charactersIn: "'\u{2019}")
    let words = transcript.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.union(apostrophes).inverted)
        .map { $0.trimmingCharacters(in: apostrophes) }
        .filter { !$0.isEmpty }
    let roomPhrases: [[String]] = [
        ["in", "my", "room"], ["on", "my", "wall"], ["in", "my", "living", "room"], ["in", "my", "bedroom"],
        ["in", "my", "office"], ["in", "my", "house"], ["in", "my", "home"], ["in", "my", "apartment"],
        ["in", "my", "space"], ["on", "the", "wall", "behind", "me"], ["on", "me"],
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

    /// "try this on", "try that shirt on", or "try on this shirt", ending the request but for a "please" or "now", so "let
    /// me try this on the next video" asks nothing.
    func asksToTryTheItemOn() -> Bool {
        var lastIndex = words.count - 1
        while lastIndex >= 0, ["please", "now"].contains(words[lastIndex]) { lastIndex -= 1 }
        guard lastIndex >= 2 else { return false }
        if words[lastIndex] == "on" {
            return itemStarts(endingAt: lastIndex - 1).contains { itemStart in itemStart >= 1 && words[itemStart - 1] == "try" }
        }
        return itemStarts(endingAt: lastIndex).contains { itemStart in
            itemStart >= 2 && words[itemStart - 1] == "on" && words[itemStart - 2] == "try"
        }
    }
    if asksToTryTheItemOn() { return true }

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

/// The three Worker routes behind the panel: the page reader and the two depth service measurements.
@MainActor
final class RoomArtClient {
    private let tryItItemURL: URL
    private let roomWallURL: URL
    private let roomFloorURL: URL
    private let session: URLSession

    /// Depth Pro takes about 14 seconds on a frame, and Sonnet several on the page. Past this the panel says it failed.
    private static let timeoutSeconds: TimeInterval = 90

    init(workerBaseURL: String) {
        guard let tryItItemURL = URL(string: "\(workerBaseURL)/try-it-item"),
              let roomWallURL = URL(string: "\(workerBaseURL)/room-wall"),
              let roomFloorURL = URL(string: "\(workerBaseURL)/room-floor") else {
            preconditionFailure("Worker base URL did not form the room art URLs: \(workerBaseURL)")
        }
        self.tryItItemURL = tryItItemURL
        self.roomWallURL = roomWallURL
        self.roomFloorURL = roomFloorURL
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.timeoutSeconds
        configuration.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: configuration)
    }

    func readThePage(_ pageRequest: RoomArtPageRequest) async throws -> RoomArtPageReading {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(pageRequest.json),
            to: tryItItemURL,
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

    /// `floorRequest.anchor` is the keyframe pixel the furniture's front-bottom center stands on. The body is the wall's.
    func measureTheFloor(_ floorRequest: RoomWallRequest) async throws -> FloorPlane {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONEncoder().encode(floorRequest.json),
            to: roomFloorURL,
            using: session,
            sendsAppSecret: true
        )
        guard statusCode == 200 else {
            throw RoomArtWorkerError.workerReturned(statusCode: statusCode, body: String(decoding: responseData, as: UTF8.self))
        }
        return try FloorPlane(responseData: responseData)
    }
}

/// What a failed wall or floor measurement means to the learner: a transport error says the Worker could not be reached,
/// 401 says the app secret is missing, 503 (no depth service configured) and 502 (it is down) ask whether it runs, and
/// anything else, a 422 or a reply that is not a plane included, says the surface could not be measured.
nonisolated func roomArtFailure(forAFailedMeasurementOf surfaceKind: RoomArtSurfaceKind, error: Error) -> RoomArtFailure {
    if error is URLError { return .workerUnreachable }
    guard case RoomArtWorkerError.workerReturned(let statusCode, _) = error else { return surfaceKind.cannotPlaceFailure }
    switch statusCode {
    case 401: return .appSecretMissing
    case 502, 503: return .depthServiceUnavailable
    default: return surfaceKind.cannotPlaceFailure
    }
}

/// What a failed page read means to the learner: a transport error says the Worker could not be reached, 401 says the app
/// secret is missing, and anything else that the page could not be read.
nonisolated func roomArtFailure(forAFailedPageRead error: Error) -> RoomArtFailure {
    if error is URLError { return .workerUnreachable }
    if case RoomArtWorkerError.workerReturned(statusCode: 401, _) = error { return .appSecretMissing }
    return .pageNotRead
}
