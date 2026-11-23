//
//  RoomArt.swift
//  leanring-buddy
//
//  "Show me how this would look in my room": Clicky reads the item on Chrome's front tab and its size from the page, opens a
//  live camera panel, and shows the item in the learner's room at its real size: a flat item hung on the wall, a standing
//  item stood on the floor or on a table or shelf, or a shirt tried on the learner's own body. An item that cannot be shown
//  is told so right after the page read.
//
//  This file holds the pure parts: the Worker replies parsed into Swift types (`POST /try-it-item` reads the page and says
//  where the item goes and whether it can be shown, `POST /room-wall` measures the wall and `POST /room-floor` the floor or a
//  table top with Depth Pro), the art's corners projected from the wall plane and a standing item's from the floor plane, the bare wall or floor spot the item
//  goes to first, the wall's light, the phase state machine behind the panel, the clients, and the phrase that asks for it.
//  `RoomTracker` keeps the item in place, `RoomCamera` supplies the frames, `RoomArtLoop` draws Clicky's loop around the placed
//  furniture's footprint and the shirt (none while a surface is measured), `RoomArtPreview` runs and draws the panel, `RoomFloor` and the `RoomFurniture` files place and
//  draw the furniture, and `ShirtTryOn` overlays the shirt.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import simd

// MARK: - The picture and the page

/// A JPEG of the largest picture in Chrome's front tab, the page's image file or a screen capture of it
/// (`RoomArtPictureSource`). The page's corners are in its pixels, except a garment's, which are in the picture its front
/// is in (`RoomArtClothingReading.frontPictureIndex`).
nonisolated struct RoomArtPicture: Equatable, Sendable {
    /// The Worker reads at most this many other pictures besides the main one.
    static let mostOtherPictures = 3

    let jpegData: Data
    let width: Int
    let height: Int
    /// The page's other large product photos, in the page's order, which the page reader may find a garment's front in,
    /// since a gallery can show the back of a shirt as large as its front. Empty for a screen capture or a single photo.
    var otherPictures: [RoomArtPicture] = []

    /// The picture a reading's number names: 0 is this one, and 1 and up are `otherPictures`. Nil for a number past them.
    func picture(numbered pictureNumber: Int) -> RoomArtPicture? {
        if pictureNumber == 0 { return self }
        return otherPictures.indices.contains(pictureNumber - 1) ? otherPictures[pictureNumber - 1] : nil
    }
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
            "picture": Self.json(of: picture),
        ]
        if !picture.otherPictures.isEmpty {
            fields["otherPictures"] = .array(picture.otherPictures.prefix(RoomArtPicture.mostOtherPictures).map(Self.json(of:)))
        }
        if !learnerRequest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fields["learnerRequest"] = .string(learnerRequest)
        }
        return .object(fields)
    }

    private static func json(of picture: RoomArtPicture) -> JSONValue {
        .object([
            "jpegBase64": .string(picture.jpegData.base64EncodedString()),
            "width": .number(Double(picture.width)),
            "height": .number(Double(picture.height)),
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

/// What `POST /try-it-item` read from the page and its picture, by where the item goes. A flat item of any outline hangs on the
/// wall, a standing item stands on the floor or on a table or shelf, and a top is drawn over the learner
/// (`roomArtReadingPlan`). An item that cannot be shown carries the reason Clicky says right after the page read.
nonisolated enum RoomArtPageReading: Equatable, Sendable {
    /// An item that hangs flat on the wall, of any outline: a print, a poster, a framed photo, a mirror, a round clock, a
    /// wreath. `fillsItsCorners` says whether its outline is a rectangle that fills its four corners. The wire kind is `wall`.
    case wallArt(RoomArtWallArtReading)
    /// A wall item whose page text states no size, so Clicky says so instead of hanging a size the model guessed.
    case sizeNotOnThePage(title: String)
    /// Any standing item, not only furniture: a sofa, a lamp, a rug, a mug on a table. The wire kind is `standing`, and
    /// `RoomArtFurnitureReading.standsOn` says whether it stands on the floor or on a table or shelf.
    case furniture(RoomArtFurnitureReading)
    case clothing(RoomArtClothingReading)
    /// The item cannot be shown in the room, and `reason` says why.
    case cannotBeShown(title: String, reason: RoomArtCannotBeShownReason)
}

/// What a standing item stands on, from the page reader. The floor is found by a search for bare floor and measured, and
/// a table or shelf is found by the learner's click, since no search can tell a table top from the floor.
nonisolated enum RoomArtStandsOn: String, Decodable, Equatable, Sendable {
    case floor
    case tableOrShelf

    /// Whether the learner clicks the surface the item goes on, instead of a search for bare floor choosing it. Such an item
    /// waits for the click before any measurement, and no floor is ever inferred from the wall for it.
    var needsAClickOnItsSurface: Bool { self == .tableOrShelf }
}

/// Why the page reader says an item cannot be shown. Clicky says the line for each itself, and page text is never spoken.
nonisolated enum RoomArtCannotBeShownReason: String, Decodable, Equatable, Sendable {
    /// A gift card, a download, a subscription, or a service.
    case notAPhysicalItem
    /// Under about 3 cm on its longest side, such as a ring or a screw.
    case tooSmallToSee
    /// No photo on the page shows the item by itself.
    case noClearPhoto
    /// It hangs on a wall but sticks out of it more than about 5 cm, such as a wall shelf, a sconce, or a coat rack.
    case notFlatForTheWall
    /// It goes somewhere Clicky cannot measure, such as a ceiling light, curtains, a car, or anything larger than 6 m.
    case noPlaceClickyCanShow

    var failure: RoomArtFailure {
        switch self {
        case .notAPhysicalItem: return .notAPhysicalItem
        case .tooSmallToSee: return .tooSmallToSee
        case .noClearPhoto: return .noClearPhoto
        case .notFlatForTheWall: return .notFlatForTheWall
        case .noPlaceClickyCanShow: return .noPlaceClickyCanShow
        }
    }
}

nonisolated struct RoomArtWallArtReading: Equatable, Sendable {
    let title: String
    let chosenSize: RoomArtSize
    let chosenSizeIncludesFrame: Bool
    /// True when the item's outline is a rectangle that fills its four corners, so flattening the quadrilateral between the
    /// corners gives exactly the item. False for any other outline, such as a round clock: the item is then cut out of its
    /// photo by its own shape before it is flattened, so the flattened art keeps transparent pixels outside the item.
    let fillsItsCorners: Bool
    let whyThisSize: String
    let otherSizes: [RoomArtSize]
    /// Where the art itself sits in the picture, so a photo of it in a room can be flattened to the art alone.
    let artworkCorners: RoomArtCorners
}

/// A size a store sells a standing item in: across the front, from what it stands on to its top, and front to back. A rug is
/// about 1 cm tall. A toy or figurine page often states only the height, so the width and the depth are nil when the page
/// does not state them, and the panel measures the width from the cutout's own shape (`RoomFurniture.standing`).
nonisolated struct RoomArtFurnitureSize: Equatable, Sendable {
    let label: String
    let widthCentimeters: Double?
    let heightCentimeters: Double
    let depthCentimeters: Double?
}

/// A standing item as the page reader read it: furniture, a lamp, a rug, a mug. It keeps the name "furniture" for every
/// standing item.
nonisolated struct RoomArtFurnitureReading: Equatable, Sendable {
    let title: String
    /// Nil when the page text states no size.
    let chosenSize: RoomArtFurnitureSize?
    let whyThisSize: String
    /// Where the item sits in the picture, clamped into it.
    let itemCorners: RoomArtCorners
    var standsOn: RoomArtStandsOn = .floor
}

/// What the page reader calls the garment. It only names the garment for the painting's prompt: no kind is refused for being
/// that kind (`RoomArtClothingReading.canBeDrawnOnTheLearner` is the reader's verdict).
nonisolated enum RoomArtGarment: String, Decodable, Equatable, Sendable {
    case tshirt, shirt, sweater, hoodie, jacket, coat, vest, dress, jumpsuit, other
}

/// Where the garment's hem ends on a standing person.
nonisolated enum RoomArtGarmentLength: String, Decodable, Equatable, Sendable {
    case waist, hip, thigh, knee, ankle
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
    /// Where the hem ends on a standing person.
    let length: RoomArtGarmentLength
    /// The reader's verdict: true when the item is worn over the upper body (it covers the shoulders or chest), which a top, a
    /// jacket, a coat, a vest, a dress, and a jumpsuit are, and false for clothing worn only below the waist, on the head,
    /// hands, or feet, or carried. The camera shows the learner from about the thighs up, so those cannot be drawn.
    let canBeDrawnOnTheLearner: Bool
    /// The size the page shows as selected, as the page writes it, such as "M". Page text, so it is only logged.
    let chosenSizeLabel: String
    let photoShows: RoomArtGarmentPhoto
    /// What the print on the garment looks like, empty for a plain garment. Page-derived text, so it is logged and goes
    /// into the shirt painting's prompt only inside a tag the Worker marks as untrusted data.
    let printDescription: String
    /// The garment's main cloth color in the picture its front is in, as "#RRGGBB" in sRGB and uppercase, named by the page
    /// reader and checked at the boundary. It goes to the shirt painting as the cloth color.
    let mainColorHex: String
    let whyThisSize: String
    /// Where the garment sits in the picture its front is in, clamped into it.
    let itemCorners: RoomArtCorners
    /// Which picture shows the garment's front, the one the try-on cuts it out of: 0 is the main picture, and 1 and up are
    /// its `otherPictures`.
    var frontPictureIndex = 0

    /// `hex` in uppercase when it is `#` and six hex digits, else nil.
    static func uppercasedColorHex(_ hex: String) -> String? {
        let digits = hex.dropFirst()
        guard hex.hasPrefix("#"), digits.count == 6, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isHexDigit) else { return nil }
        return hex.uppercased()
    }
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
    /// Null when the page does not state it.
    let widthCentimeters: Double?
    let heightCentimeters: Double
    /// Null when the page does not state it.
    let depthCentimeters: Double?
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
    /// True when the item's outline is a rectangle that fills its four corners in the photo. A round clock, a round or arched
    /// mirror, a wreath, a decal, or a neon sign is false, and the app cuts it out of its photo by its own shape.
    let fillsItsCorners: Bool
    let sizeFoundOnPage: Bool
    let size: RoomArtChosenSizeReply
    let otherSizes: [RoomArtSizeReply]
}

nonisolated private struct RoomArtStandingReply: Decodable {
    let standsOn: RoomArtStandsOn
    let sizeFoundOnPage: Bool
    let size: RoomArtFurnitureSizeReply
}

nonisolated private struct RoomArtCannotBeShownReply: Decodable {
    let reason: RoomArtCannotBeShownReason
}

nonisolated private struct RoomArtClothingReply: Decodable {
    let garment: RoomArtGarment
    let sleeves: RoomArtSleeves
    let length: RoomArtGarmentLength
    let canBeDrawnOnTheLearner: Bool
    let chosenSizeLabel: String
    let photoShows: RoomArtGarmentPhoto
    let printDescription: String
    let mainColorHex: String
    /// Absent from a Worker that predates it, which read the main picture only.
    let frontPictureIndex: Int?
}

/// The reply's `item`: its kind and the one object that kind names. A kind this app does not know fails to decode.
nonisolated private enum RoomArtItemReply: Decodable {
    case wall(RoomArtWallArtReply)
    case standing(RoomArtStandingReply)
    case clothing(RoomArtClothingReply)
    case cannotBeShown(RoomArtCannotBeShownReply)

    private enum CodingKeys: String, CodingKey {
        case kind, wall, standing, clothing, cannotBeShown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "wall": self = .wall(try container.decode(RoomArtWallArtReply.self, forKey: .wall))
        case "standing": self = .standing(try container.decode(RoomArtStandingReply.self, forKey: .standing))
        case "clothing": self = .clothing(try container.decode(RoomArtClothingReply.self, forKey: .clothing))
        case "cannotBeShown": self = .cannotBeShown(try container.decode(RoomArtCannotBeShownReply.self, forKey: .cannotBeShown))
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
    /// Parses the Worker's reply, whose `item` names a kind and holds that kind's own object. A wall item whose page states
    /// its size needs a sensible size and corners that enclose part of the picture, which are clamped into it, since a model's
    /// corner can land a pixel or two outside. Sizes that are not sensible are dropped from the other sizes. A wall item whose
    /// page states no size needs neither, since nothing is hung. A standing item and clothing keep what was read, with their
    /// corners clamped into the picture, since a later step places them. An item that cannot be shown keeps its title and
    /// reason and no corners, since nothing is placed.
    /// `otherPictureSizes` are the sizes of the other pictures the request sent, in order. A garment's front must be in one of
    /// the pictures sent, and its corners are clamped into that picture.
    nonisolated init(responseData: Data, pictureWidth: Int, pictureHeight: Int, otherPictureSizes: [(width: Int, height: Int)] = []) throws {
        let reply: RoomArtTryItReply
        do {
            reply = try JSONDecoder().decode(RoomArtTryItReply.self, from: responseData)
        } catch {
            throw RoomArtReplyError(reason: "the reply is not the try-it-item shape")
        }
        func itemCornersInThePicture(width: Int = pictureWidth, height: Int = pictureHeight) throws -> RoomArtCorners {
            func pointInThePicture(_ pointReply: RoomArtPointReply) throws -> CGPoint {
                guard pointReply.x.isFinite, pointReply.y.isFinite else { throw RoomArtReplyError(reason: "a corner is not a number") }
                return CGPoint(x: min(max(pointReply.x, 0), Double(width)), y: min(max(pointReply.y, 0), Double(height)))
            }
            return RoomArtCorners(
                topLeft: try pointInThePicture(reply.itemCorners.topLeft),
                topRight: try pointInThePicture(reply.itemCorners.topRight),
                bottomRight: try pointInThePicture(reply.itemCorners.bottomRight),
                bottomLeft: try pointInThePicture(reply.itemCorners.bottomLeft)
            )
        }

        switch reply.item {
        case .cannotBeShown(let cannotBeShownReply):
            self = .cannotBeShown(title: reply.title, reason: cannotBeShownReply.reason)
        case .clothing(let clothingReply):
            var frontPictureIndex = clothingReply.frontPictureIndex ?? 0
            if frontPictureIndex < 0 || frontPictureIndex > otherPictureSizes.count {
                // A garment that cannot be drawn on the learner never uses its front picture, so a bad index there is read as the
                // main picture and the verdict still reaches the learner. A drawable garment needs a picture that was sent.
                guard !clothingReply.canBeDrawnOnTheLearner else {
                    throw RoomArtReplyError(reason: "clothing.frontPictureIndex names a picture that was not sent")
                }
                frontPictureIndex = 0
            }
            guard let mainColorHex = RoomArtClothingReading.uppercasedColorHex(clothingReply.mainColorHex) else {
                throw RoomArtReplyError(reason: "clothing.mainColorHex is not # and six hex digits")
            }
            let frontPictureSize = frontPictureIndex == 0 ? (width: pictureWidth, height: pictureHeight) : otherPictureSizes[frontPictureIndex - 1]
            self = .clothing(RoomArtClothingReading(
                title: reply.title,
                garment: clothingReply.garment,
                sleeves: clothingReply.sleeves,
                length: clothingReply.length,
                canBeDrawnOnTheLearner: clothingReply.canBeDrawnOnTheLearner,
                chosenSizeLabel: clothingReply.chosenSizeLabel,
                photoShows: clothingReply.photoShows,
                printDescription: clothingReply.printDescription,
                mainColorHex: mainColorHex,
                whyThisSize: reply.whyThisSize,
                itemCorners: try itemCornersInThePicture(width: frontPictureSize.width, height: frontPictureSize.height),
                frontPictureIndex: frontPictureIndex
            ))
        case .standing(let standingReply):
            let sizeReply = standingReply.size
            let chosenSize: RoomArtFurnitureSize?
            if standingReply.sizeFoundOnPage {
                let statedSides = [sizeReply.widthCentimeters, sizeReply.heightCentimeters, sizeReply.depthCentimeters].compactMap { $0 }
                guard statedSides.allSatisfy({ sensibleArtCentimeters.contains($0) }),
                      !sizeReply.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RoomArtReplyError(reason: "standing.size needs a label, a height, and any width and depth it states, each from 1 to 1000 cm")
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
            self = .furniture(RoomArtFurnitureReading(
                title: reply.title, chosenSize: chosenSize, whyThisSize: reply.whyThisSize, itemCorners: try itemCornersInThePicture(), standsOn: standingReply.standsOn
            ))
        case .wall(let wallArtReply):
            guard wallArtReply.sizeFoundOnPage else {
                self = .sizeNotOnThePage(title: reply.title)
                return
            }
            let chosenSize = wallArtReply.size
            guard sensibleArtCentimeters.contains(chosenSize.widthCentimeters),
                  sensibleArtCentimeters.contains(chosenSize.heightCentimeters),
                  !chosenSize.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RoomArtReplyError(reason: "wall.size needs a label and a width and height from 1 to 1000 cm")
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
                fillsItsCorners: wallArtReply.fillsItsCorners,
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

/// The wall art's shadow in the flattened art's pixels: the art's own alpha as 35 percent black, 2 percent of the art's height
/// below it and spread 1.5 percent of the height, so a round item casts a round shadow and a rectangle that fills its picture
/// casts the rectangular one. The image's extent holds the shadow with 3 spreads of margin around it.
nonisolated func wallArtShadow(of flattenedArt: CGImage) -> CIImage {
    let artHeight = Double(flattenedArt.height)
    let artExtent = CGRect(x: 0, y: 0, width: Double(flattenedArt.width), height: artHeight)
    let shadowSpread = artHeight * 0.015
    let shadowOffset = -artHeight * 0.02
    let shadowExtent = artExtent.offsetBy(dx: 0, dy: shadowOffset)
    return CIImage(cgImage: flattenedArt)
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
        ])
        .transformed(by: CGAffineTransform(translationX: 0, y: shadowOffset))
        .applyingGaussianBlur(sigma: shadowSpread)
        .cropped(to: shadowExtent.insetBy(dx: -3 * shadowSpread, dy: -3 * shadowSpread))
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

/// What Clicky sends `POST /room-wall`: the keyframe, the person in it, and the spot on the wall the art centers on. A floor
/// measurement (`POST /room-floor`) sends the same body, with the anchor where the item stands.
nonisolated struct RoomWallRequest: Equatable, Sendable {
    let keyframeJPEGData: Data
    let personMaskPNGData: Data
    /// In keyframe pixels.
    let anchor: CGPoint
    /// What a floor measurement is for, which `/room-floor` fits its plane to: a table or shelf top is level and small, so
    /// the depth service looks only at level planes in a small window around the anchor. Only a table or shelf is sent,
    /// since an absent field means the floor, and a wall request never carries it.
    var standsOn: RoomArtStandsOn = .floor

    var json: JSONValue {
        var fields: [String: JSONValue] = [
            "jpegBase64": .string(keyframeJPEGData.base64EncodedString()),
            "maskPngBase64": .string(personMaskPNGData.base64EncodedString()),
            "anchor": .object(["u": .number(anchor.x), "v": .number(anchor.y)]),
        ]
        if standsOn == .tableOrShelf { fields["standsOn"] = .string(standsOn.rawValue) }
        return .object(fields)
    }
}

// MARK: - Where the item goes first

/// The window `bareWallSpot` scores around each candidate spot, as shares of the frame.
nonisolated enum RoomArtBareWallWindow {
    static let widthShareOfTheFrame = 0.24
    static let heightShareOfTheFrame = 0.3
    /// The rows a spot's center may sit on, as shares of the frame's height: the upper middle, where art hangs.
    static let centerRowShares = 0.25...0.55
}

/// The window `bareFloorSpot` scores, as shares of the frame: wide and low, the shape of floor seen at a slant.
nonisolated enum RoomArtBareFloorWindow {
    static let widthShareOfTheFrame = 0.3
    static let heightShareOfTheFrame = 0.18
    /// The lower part of the frame, where the floor shows when the screen is tilted down. The depth service fits the floor
    /// in a window around and below the anchor, so the lowest rows are left for it.
    static let centerRowShares = 0.62...0.80
    /// How much more a spot at the frame's side edge costs than one in the middle, as a share of its texture: furniture
    /// standing at the edge is cut off by the frame, and the darkest, plainest floor is often a far corner. At 1.0 the
    /// plain dark corner of room-floor.mp4's wood floor still won, while the piece then
    /// stood in the middle (`roomFurnitureSpotWhereTheWholePieceFits`); at 2.0 the spot is the lower middle there.
    static let costOfTheSideEdges = 2.0
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
    /// The page reader says the item cannot be shown (`RoomArtCannotBeShownReason`), each reason with its own line. They come
    /// right after the page read, before any camera measurement.
    case notAPhysicalItem
    case tooSmallToSee
    case noClearPhoto
    case notFlatForTheWall
    case noPlaceClickyCanShow
    /// The page text could not be read or was empty, or `POST /try-it-item` failed.
    case pageNotRead
    /// The page is a wall item or a standing item, but its text states no size, so nothing is placed at a size the model guessed.
    case sizeNotOnThePage
    /// A measurement route answered 503 (no depth service configured) or 502 (the depth service is down).
    case depthServiceUnavailable
    /// `POST /room-wall` answered 422 (no bare wall there, or a wall too near, too far, or not flat), or its reply could
    /// not place the art.
    case wallNotMeasured
    /// `POST /room-floor` answered 422 (no floor in view there, or one too tilted, near, or far), or its reply could not
    /// stand the furniture on it. The panel stays open and a click on the floor measures again.
    case floorNotFound
    /// Vision found no standing item in the product photo, so nothing can stand on its surface.
    case furnitureNotCutOut
    /// The page reader says the clothing cannot be drawn on the learner: it is worn only below the waist, on the head,
    /// hands, or feet, or carried, such as trousers, a hat, or a bag (`RoomArtClothingReading.canBeDrawnOnTheLearner`).
    case cannotBeDrawnOnYou
    /// A request to the Worker never got an answer: the Worker is not running, the connection failed, or it timed out.
    case workerUnreachable

    /// What Clicky says.
    var spokenLine: String {
        switch self {
        case .appSecretMissing: return "Clicky needs its app secret for this. See the README's Worker setup."
        case .pageNotHTTPS: return "I can only read store pages served over https."
        case .cameraAccessDenied: return "I need camera access for that. You can turn it on in System Settings."
        case .noCamera: return "I couldn't find a camera to show your room."
        case .notAPhysicalItem: return "That isn't something I can show in your room."
        case .tooSmallToSee: return "That's too small to see in your room."
        case .noClearPhoto: return "I couldn't find a clear photo of it on that page."
        case .notFlatForTheWall: return "I can only hang flat things on your wall so far."
        case .noPlaceClickyCanShow: return "I can show things on your wall, your floor, or a table so far."
        case .pageNotRead: return "I couldn't read that page."
        case .sizeNotOnThePage: return "I couldn't find the size on that page."
        case .depthServiceUnavailable: return "I couldn't measure your room. Is the depth service running?"
        case .wallNotMeasured: return "I couldn't measure your wall. Try pointing the camera at a bare wall."
        case .floorNotFound: return "I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor."
        case .furnitureNotCutOut: return "I couldn't cut it out of its photo."
        case .cannotBeDrawnOnYou: return "I can't draw that item on you."
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
        case .notAPhysicalItem: return "Not something I can show in your room"
        case .tooSmallToSee: return "Too small to see in your room"
        case .noClearPhoto: return "No clear photo of it on the page"
        case .notFlatForTheWall: return "Only flat things hang on the wall so far"
        case .noPlaceClickyCanShow: return "Only walls, floors, and tables so far"
        case .pageNotRead: return "Couldn't read the page"
        case .sizeNotOnThePage: return "Couldn't find the size on the page"
        case .depthServiceUnavailable: return "Couldn't measure the room. Is the depth service running?"
        case .wallNotMeasured: return "Couldn't measure the wall"
        case .floorNotFound: return "Tilt the screen down so the floor shows, then click the floor"
        case .furnitureNotCutOut: return "Couldn't cut it out of its photo"
        case .cannotBeDrawnOnYou: return "Can't draw that item on you"
        case .workerUnreachable: return "Couldn't reach Clicky's Worker"
        }
    }
}

// MARK: - What the reading asks for

/// What the panel does with the page's reading. Only a wall item and a standing item whose page states a size are placed, so
/// a size the model guessed never reaches the room, and clothing is tried on whenever the page reader says it can be drawn
/// on the learner (`RoomArtClothingReading.canBeDrawnOnTheLearner`), whatever its kind, length, or photo. How the try-on
/// previews it is a separate rule (`shirtPreviewKind`). An item the page reader says cannot be shown fails with that
/// reason's line before any measurement.
nonisolated enum RoomArtReadingPlan: Equatable, Sendable {
    case hangOnTheWall(RoomArtWallArtReading)
    /// A standing item stands on the floor or on a table or shelf, as `RoomArtFurnitureReading.standsOn` says.
    case standOnTheFloor(RoomArtFurnitureReading, size: RoomArtFurnitureSize)
    case tryOnTheShirt(RoomArtClothingReading)
    case fail(RoomArtFailure)
}

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
        return clothingReading.canBeDrawnOnTheLearner ? .tryOnTheShirt(clothingReading) : .fail(.cannotBeDrawnOnYou)
    case .cannotBeShown(_, let reason):
        return .fail(reason.failure)
    }
}

// MARK: - Surfaces and what stands on them

/// The two surfaces an item is measured on: wall art hangs on a wall, and a standing item stands on a floor or on a table or
/// shelf, which the depth service measures as a floor too.
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

/// What is placed on a surface: the art flattened from its photo, or a standing item cut out of its photo. The standing item
/// keeps the name "furniture", and its `standsOn` says whether the surface is a floor or a table or shelf.
nonisolated enum RoomArtPlacedItem: Equatable, Sendable {
    case wallArt(RoomArtwork)
    case furniture(RoomFurniture)

    var surfaceKind: RoomArtSurfaceKind {
        switch self {
        case .wallArt: return .wall
        case .furniture: return .floor
        }
    }

    /// What a standing item stands on, nil for wall art.
    var standsOn: RoomArtStandsOn? {
        if case .furniture(let furniture) = self { return furniture.standsOn }
        return nil
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
        case .furniture(let furniture): return furniture.standsOn.showingStatusLine(sizeInWords: furniture.sizeInWords)
        }
    }

    /// The status line while this item's surface is measured.
    var measuringStatusLine: String {
        standsOn?.measuringStatusLine ?? RoomArtSurfaceKind.wall.measuringStatusLine
    }

    /// The status line while the tracker has lost the room and the item is hidden.
    var lostLine: String {
        standsOn?.lostLine ?? RoomArtSurfaceKind.wall.lostLine
    }

    /// What Clicky says when no look could be drawn for a standing item, and the status line that says the same.
    var notDrawnLine: String {
        (standsOn ?? .floor).notDrawnLine
    }

    var notDrawnStatusLine: String {
        (standsOn ?? .floor).notDrawnStatusLine
    }

    /// What the panel says while it waits for a click on this item's surface (`RoomArtPhase.waitingForAFloorClick`).
    /// `aClickFoundNothing` says the learner's click found no flat surface, which only an item that needs a click on its
    /// surface tells apart from the first invitation. A floor item says the floor line either way, as it always has.
    func surfaceClickPrompt(afterAClickFoundNothing aClickFoundNothing: Bool) -> RoomArtSurfaceClickPrompt {
        guard standsOn?.needsAClickOnItsSurface == true else { return .noFloorWasFound }
        return aClickFoundNothing ? .noFlatSurfaceThere : .whereTheItemShouldGo
    }
}

nonisolated extension RoomArtStandsOn {
    /// The status line while the surface is measured: the floor's line is the wall's twin, and a table or shelf is "the
    /// surface" since a click chose it.
    var measuringStatusLine: String {
        switch self {
        case .floor: return RoomArtSurfaceKind.floor.measuringStatusLine
        case .tableOrShelf: return "Measuring the surface…"
        }
    }

    var lostLine: String {
        switch self {
        case .floor: return RoomArtSurfaceKind.floor.lostLine
        case .tableOrShelf: return "Lost the table. Turn back to where it stands."
        }
    }

    func showingStatusLine(sizeInWords: String) -> String {
        switch self {
        case .floor: return "On your floor, \(sizeInWords)"
        case .tableOrShelf: return "On the table, \(sizeInWords)"
        }
    }

    /// Said as a failure when no painting and no render could be drawn.
    var notDrawnLine: String {
        switch self {
        case .floor: return roomFurnitureNotDrawnLine
        case .tableOrShelf: return roomFurnitureNotDrawnOnATableLine
        }
    }

    var notDrawnStatusLine: String {
        switch self {
        case .floor: return "I couldn't draw it this time. Click the floor to try again"
        case .tableOrShelf: return "I couldn't draw it this time. Click the table or shelf to try again"
        }
    }
}

/// What the panel says while it waits for the learner to click a surface. Each prompt is said once per panel, since a later
/// failed click only shows in the status line.
nonisolated enum RoomArtSurfaceClickPrompt: Hashable, Sendable {
    /// A floor item's first floor measurement found none: tilt the screen down, then click the floor.
    case noFloorWasFound
    /// A table or shelf item is ready, and the learner clicks where it should go.
    case whereTheItemShouldGo
    /// The learner's click on a table or shelf found no flat surface, so they click the top of one.
    case noFlatSurfaceThere

    var spokenLine: String {
        switch self {
        case .noFloorWasFound: return RoomArtFailure.floorNotFound.spokenLine
        case .whereTheItemShouldGo: return "Click the table or shelf where it should go."
        case .noFlatSurfaceThere: return "I couldn't find a flat surface there. Click the top of a table or shelf."
        }
    }

    var statusLine: String {
        switch self {
        case .noFloorWasFound: return RoomArtFailure.floorNotFound.statusLine
        case .whereTheItemShouldGo: return "Click the table or shelf where it should go"
        case .noFlatSurfaceThere: return "Click the top of a table or shelf"
        }
    }

    /// Whether the line says something went wrong, so the cursor shakes as Clicky says it and the status line is red. The
    /// first invitation for a table or shelf is not a failure.
    var isAFailure: Bool {
        switch self {
        case .noFloorWasFound, .noFlatSurfaceThere: return true
        case .whereTheItemShouldGo: return false
        }
    }
}

nonisolated extension RoomArtSurfaceKind {
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
        // A standing item never moves by a click on its surface, so its line only asks the learner to turn back.
        case .floor: return "Lost the floor. Turn back to where the piece stands."
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

/// Names one painting of the shirt, so a reply for a painting the learner left changes nothing.
nonisolated struct ShirtPaintingID: Equatable, Sendable {
    let number: Int
}

/// What the panel is doing. The page is read as the panel opens, and its kind picks the rest: wall art and standing items are
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
    /// Furniture's floor is measured and its true-size ghost shows on it (`RoomFurnitureGhost`), which the learner drags,
    /// turns, and nudges until they say "right there" or press Place. Nothing is painted yet. `id` names this placement, so
    /// a painting for an earlier one changes nothing.
    case placingTheFurniture(id: RoomArtMeasurementID, item: RoomArtPlacedItem, surface: RoomArtSurface)
    /// The learner placed the furniture, and its first real look is still on its way: the render of the store's model
    /// or the painted composite. Nothing is drawn meanwhile, since the flat cutout floats above the floor and reads as a
    /// sticker, so the ghost stays at half opacity, Clicky's loop goes around its footprint, and the status line says the
    /// piece is being arranged. When no painting can come, or none came within `roomFurnitureSecondsToWaitForALook`, the
    /// model's render shows, else the phase becomes `couldNotDraw`. `id` is the placement's, so a look or a deadline for an
    /// older one changes nothing.
    case arranging(id: RoomArtMeasurementID, item: RoomArtPlacedItem, surface: RoomArtSurface)
    /// No painting came for the arranged furniture and its model has no render, so nothing is drawn: the loop stays, Clicky
    /// says so as a failure, and a click on the floor picks the ghost back up there, on the floor already measured, to be
    /// placed again. A painting that still arrives for this placement shows it.
    case couldNotDraw(id: RoomArtMeasurementID, item: RoomArtPlacedItem, surface: RoomArtSurface)
    /// A click moves the item: a new keyframe and a new measurement. The surface it stood on comes back if the new one is
    /// not measured.
    case moving(id: RoomArtMeasurementID, item: RoomArtPlacedItem, surfaceBeforeTheMove: RoomArtSurface)
    /// The camera keeps running and a click on the surface measures it, for a floor item whose first measurement found no
    /// floor, and for a table or shelf item from the start, since only a click chooses a table top
    /// (`RoomArtStandsOn.needsAClickOnItsSurface`). `aClickFoundNothing` says the learner's click on a table or shelf found no
    /// flat surface, which changes its prompt (`RoomArtPlacedItem.surfaceClickPrompt`). A floor item never records it.
    case waitingForAFloorClick(RoomArtPlacedItem, aClickFoundNothing: Bool = false)
    /// Clothing the page reader says can be drawn on the learner: the picture is being prepared while the camera looks for
    /// the learner. Which preview shows is decided once the garment's cutout was tried (`shirtPreviewKind`), and every phase
    /// after this one records it, so going back from a painting returns to the same preview.
    case preparingTheShirt(title: String)
    /// The preview is ready, and the learner is not yet standing where it can be drawn.
    case waitingToSeeTheLearner(title: String, preview: ShirtPreviewKind)
    /// The preview shows over the learner every frame they stand in view: the live 2D garment, or the ghost outline of the
    /// area that will be painted.
    case showingTheShirt(title: String, preview: ShirtPreviewKind)
    /// The learner said "right there" or clicked Paint it, and the capture waits for them to step back and hold still
    /// (`ShirtStepBackCapture`), with a 3-2-1 countdown while they do. `id` names this capture, so an event from one the
    /// learner restarted or left changes nothing.
    case waitingForTheLearnerToStepBack(title: String, id: ShirtPaintingID, preview: ShirtPreviewKind)
    /// The capture froze the frame and the shirt is painted into it. `id` names this painting, so a reply for one the
    /// learner left by going back changes nothing.
    case paintingTheShirt(title: String, id: ShirtPaintingID, preview: ShirtPreviewKind)
    /// The painted still shows until the learner goes back to the preview.
    case showingThePaintedShirt(title: String, preview: ShirtPreviewKind)
    case failed(RoomArtFailure)

    var isOpen: Bool { self != .closed }

    // MARK: Transitions

    /// The learner asked to try the item. A panel already open starts over, or, while an item shows, reads the new page in the
    /// same room (`keepsTheRoomForANewItem`).
    func opening() -> RoomArtPhase {
        .readingThePage
    }

    /// A wall item, or a standing item whose painting or render shows. A new request then keeps the room: the item stays in
    /// it, and the new item is placed into the same keyframe beside or on it, as a lamp on a painted table. Every other open
    /// phase, a ghost the learner still moves or a shirt included, starts over.
    var keepsTheRoomForANewItem: Bool {
        if case .showing = self { return true }
        return false
    }

    /// A wall item or a standing item was read and its picture prepared, so its surface can be measured once the camera has a frame.
    func withTheItemReady(_ item: RoomArtPlacedItem) -> RoomArtPhase {
        guard case .readingThePage = self else { return self }
        return .waitingForTheCamera(item)
    }

    /// Clothing the reader says can be drawn on the learner was read, so its picture is prepared while the camera looks for
    /// the learner.
    func startingTheShirt(title: String) -> RoomArtPhase {
        guard case .readingThePage = self else { return self }
        return .preparingTheShirt(title: title)
    }

    /// The page could not be read, or what it shows cannot be tried, so the panel says why.
    func afterThePageFailed(_ failure: RoomArtFailure) -> RoomArtPhase {
        guard case .readingThePage = self else { return self }
        return .failed(failure)
    }

    /// The item is ready and the camera has its first frame. Wall art and a floor item measure at once, where a search for
    /// bare wall or floor puts them (`startingAMeasurement`). A table or shelf item asks for a click instead, since no search
    /// can tell a table top from the floor, so nothing is measured until the learner clicks.
    func askingForAClickIfTheItemNeedsOne() -> RoomArtPhase {
        guard case .waitingForTheCamera(let item) = self, item.standsOn?.needsAClickOnItsSurface == true else { return self }
        return .waitingForAFloorClick(item, aClickFoundNothing: false)
    }

    /// A keyframe was taken: the first one once the item is ready and the camera runs, a click that moves the item, or a
    /// click on the surface after none was found or asked for. One measurement runs at a time, so a click during one changes
    /// nothing.
    func startingAMeasurement(id: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .waitingForTheCamera(let item), .waitingForAFloorClick(let item, _):
            return .measuring(id: id, item: item)
        // Furniture stands on a floor already measured, so it never measures again: a press on the piece picks its ghost
        // back up, and after it could not be drawn a press anywhere does (`aPressPicksTheFurnitureUp`).
        case .showing(.furniture, _, _):
            return self
        case .showing(let item, let surface, _):
            return .moving(id: id, item: item, surfaceBeforeTheMove: surface)
        case .closed, .readingThePage, .measuring, .placingTheFurniture, .arranging, .couldNotDraw, .moving, .preparingTheShirt, .waitingToSeeTheLearner,
             .showingTheShirt, .waitingForTheLearnerToStepBack, .paintingTheShirt, .showingThePaintedShirt, .failed:
            return self
        }
    }

    func withTheSurfaceMeasured(_ surface: RoomArtSurface, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .measuring(let measuringID, let item) where measuringID == measurementID && surface.kind == item.surfaceKind:
            guard surface.keyframeCorners(of: item) != nil else { return Self.afterTheFirstMeasurementFailed(item.surfaceKind.cannotPlaceFailure, item: item) }
            return Self.placed(item, on: surface, measurementID: measurementID)
        case .moving(let movingID, let item, let surfaceBeforeTheMove) where movingID == measurementID && surface.kind == item.surfaceKind:
            guard surface.keyframeCorners(of: item) != nil else {
                return .showing(item: item, surface: surfaceBeforeTheMove, moveFailure: item.surfaceKind.cannotPlaceFailure)
            }
            return Self.placed(item, on: surface, measurementID: measurementID)
        default:
            return self
        }
    }

    /// Wall art shows as soon as its wall is measured. Furniture shows its ghost, and waits for the learner to place it.
    private static func placed(_ item: RoomArtPlacedItem, on surface: RoomArtSurface, measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch item {
        case .wallArt: return .showing(item: item, surface: surface, moveFailure: nil)
        case .furniture: return .placingTheFurniture(id: measurementID, item: item, surface: surface)
        }
    }

    /// The learner said "right there" or pressed Place, so the piece is painted where its ghost stands. `placementID` is new
    /// for each placement, so a painting for an earlier one is dropped.
    func placingTheFurnitureWhereItsGhostStands(placementID: RoomArtMeasurementID) -> RoomArtPhase {
        guard case .placingTheFurniture(_, let item, let surface) = self else { return self }
        return .arranging(id: placementID, item: item, surface: surface)
    }

    /// Placed furniture picked back up as a ghost, whether its look shows, is still on its way, or could not be drawn. The
    /// controller decides which press does it (`aPressPicksTheFurnitureUp`): one on the piece, or any after it could not be
    /// drawn.
    func pickingTheFurnitureBackUp(placementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .showing(let item, let surface, nil) where item.surfaceKind == .floor,
             .arranging(_, let item, let surface),
             .couldNotDraw(_, let item, let surface):
            return .placingTheFurniture(id: placementID, item: item, surface: surface)
        default:
            return self
        }
    }

    /// No ghost can stand on the measured surface, such as a floor seen too steeply for the piece's box to project, so
    /// nothing could move or place it: the panel asks for a click on the surface, which measures it again there.
    func afterTheGhostCouldNotStand() -> RoomArtPhase {
        guard case .placingTheFurniture(_, let item, _) = self else { return self }
        return Self.waitingForAClickOnTheSurface(item, afterAClickFoundNothing: true)
    }

    /// The ghost shows, so a drag moves it and "right there" places it.
    var furnitureGhostShows: Bool {
        if case .placingTheFurniture = self { return true }
        return false
    }

    /// Furniture's first look is drawn: the painted composite, or the model's render as its fallback, or a painting that
    /// arrived after the piece could not be drawn. Clicky says "Here it is" as the panel enters `showing`, so the line comes
    /// with the piece.
    func withTheFurnitureShowing(measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        switch self {
        case .arranging(let placementID, let item, let surface) where placementID == measurementID,
             .couldNotDraw(let placementID, let item, let surface) where placementID == measurementID:
            return .showing(item: item, surface: surface, moveFailure: nil)
        default:
            return self
        }
    }

    /// No painting can come for the arranged furniture, or none came in time, and its model has no render.
    func afterTheFurnitureCouldNotBeDrawn(measurementID: RoomArtMeasurementID) -> RoomArtPhase {
        guard case .arranging(let arrangingID, let item, let surface) = self, arrangingID == measurementID else { return self }
        return .couldNotDraw(id: measurementID, item: item, surface: surface)
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
        if failure == .floorNotFound, case .furniture = item { return waitingForAClickOnTheSurface(item, afterAClickFoundNothing: true) }
        return .failed(failure)
    }

    /// A standing item waits for a click on its surface. A floor item says the floor line whether or not a click failed, so
    /// its phase is the same value either way, and only a table or shelf item records that a click found nothing.
    private static func waitingForAClickOnTheSurface(_ item: RoomArtPlacedItem, afterAClickFoundNothing aClickFoundNothing: Bool) -> RoomArtPhase {
        .waitingForAFloorClick(item, aClickFoundNothing: aClickFoundNothing && item.standsOn?.needsAClickOnItsSurface == true)
    }

    /// The preview is chosen (`shirtPreviewKind`) and ready. `learnerIsInFrame` says the framing already settled on ready, so
    /// the preview shows at once.
    func withTheShirtPreviewReady(_ preview: ShirtPreviewKind, learnerIsInFrame: Bool) -> RoomArtPhase {
        guard case .preparingTheShirt(let title) = self else { return self }
        return learnerIsInFrame ? .showingTheShirt(title: title, preview: preview) : .waitingToSeeTheLearner(title: title, preview: preview)
    }

    /// The picture that shows the garment's front could not be read, so there is nothing to preview or paint from.
    func afterTheShirtsPictureCouldNotBeRead() -> RoomArtPhase {
        guard case .preparingTheShirt = self else { return self }
        return .failed(.pageNotRead)
    }

    /// The framing settled on ready for the first time since the preview was ready.
    func afterTheLearnerStoodInFrame() -> RoomArtPhase {
        guard case .waitingToSeeTheLearner(let title, let preview) = self else { return self }
        return .showingTheShirt(title: title, preview: preview)
    }

    /// The learner asked for the painted look while the live preview shows, or asked again while the capture waits, which
    /// restarts it. One painting runs at a time, so a request during one, or before the shirt shows, changes nothing.
    func armingTheShirtCapture(id: ShirtPaintingID) -> RoomArtPhase {
        switch self {
        case .showingTheShirt(let title, let preview), .waitingForTheLearnerToStepBack(let title, _, let preview):
            return .waitingForTheLearnerToStepBack(title: title, id: id, preview: preview)
        default: return self
        }
    }

    /// The learner held still in the ready framing, and the capture for `id` froze that frame.
    func afterTheLearnerHeldStill(id: ShirtPaintingID) -> RoomArtPhase {
        guard case .waitingForTheLearnerToStepBack(let title, let armedID, let preview) = self, armedID == id else { return self }
        return .paintingTheShirt(title: title, id: id, preview: preview)
    }

    /// The capture for `id` found no still frame in time, so the preview comes back.
    func afterTheStepBackTimedOut(id: ShirtPaintingID) -> RoomArtPhase {
        guard case .waitingForTheLearnerToStepBack(let title, let armedID, let preview) = self, armedID == id else { return self }
        return .showingTheShirt(title: title, preview: preview)
    }

    /// The painting for `id` is pasted into the frozen frame and shows.
    func withThePaintedShirt(id: ShirtPaintingID) -> RoomArtPhase {
        guard case .paintingTheShirt(let title, let paintingID, let preview) = self, paintingID == id else { return self }
        return .showingThePaintedShirt(title: title, preview: preview)
    }

    /// The painting for `id` failed, so the preview comes back and a line says why.
    func afterThePaintingFailed(id: ShirtPaintingID) -> RoomArtPhase {
        guard case .paintingTheShirt(let title, let paintingID, let preview) = self, paintingID == id else { return self }
        return .showingTheShirt(title: title, preview: preview)
    }

    /// "Go back" or Back to live: the preview comes back, the same one the shirt had, from the painted still, from a painting
    /// still on its way, or from a capture still waiting for the learner to step back.
    func backToTheLiveShirt() -> RoomArtPhase {
        switch self {
        case .waitingForTheLearnerToStepBack(let title, _, let preview), .paintingTheShirt(let title, _, let preview), .showingThePaintedShirt(let title, let preview):
            return .showingTheShirt(title: title, preview: preview)
        default: return self
        }
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
    /// only matters while the item shows, or while furniture's ghost shows or its painting comes, and `shirtCoachingLine` is the settled framing's advice while the shirt cannot be drawn.
    func statusLine(theSurfaceIsLost: Bool, shirtCoachingLine: String?) -> String {
        switch self {
        case .closed: return ""
        case .readingThePage: return "Reading the page…"
        case .waitingForTheCamera: return "Starting the camera…"
        case .measuring(_, let item): return item.measuringStatusLine
        case .moving(_, let item, _): return item.measuringStatusLine
        case .placingTheFurniture(_, let item, _): return theSurfaceIsLost ? item.lostLine : roomFurnitureGhostStatusLine
        case .arranging(_, let item, _): return theSurfaceIsLost ? item.lostLine : "Arranging it in your room…"
        case .couldNotDraw(_, let item, _): return item.notDrawnStatusLine
        case .showing(let item, _, let moveFailure):
            if theSurfaceIsLost { return item.lostLine }
            return moveFailure?.statusLine ?? item.showingStatusLine
        case .waitingForAFloorClick(let item, let aClickFoundNothing): return item.surfaceClickPrompt(afterAClickFoundNothing: aClickFoundNothing).statusLine
        case .preparingTheShirt: return shirtCoachingLine ?? "Getting it ready…"
        case .waitingToSeeTheLearner: return shirtCoachingLine ?? "Looking for you…"
        case .showingTheShirt(_, let preview): return shirtCoachingLine ?? preview.statusLine
        case .waitingForTheLearnerToStepBack: return roomArtShirtStepBackLine
        // The frame is frozen, so the learner moving out of view changes nothing on screen and no coaching shows.
        case .paintingTheShirt: return roomArtShirtPaintingStatusLine
        case .showingThePaintedShirt: return roomArtShirtPaintedStatusLine
        case .failed(let failure): return failure.statusLine
        }
    }

    /// Whether the status line says what went wrong, so the panel draws it in the failure color.
    func statusLineIsAFailure(theSurfaceIsLost: Bool) -> Bool {
        switch self {
        case .failed, .couldNotDraw: return true
        case .waitingForAFloorClick(let item, let aClickFoundNothing): return item.surfaceClickPrompt(afterAClickFoundNothing: aClickFoundNothing).isAFailure
        case .showing(_, _, let moveFailure): return moveFailure != nil && !theSurfaceIsLost
        case .closed, .readingThePage, .waitingForTheCamera, .measuring, .placingTheFurniture, .arranging, .moving, .preparingTheShirt, .waitingToSeeTheLearner,
             .showingTheShirt, .waitingForTheLearnerToStepBack, .paintingTheShirt, .showingThePaintedShirt:
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

/// What CompanionManager keeps about the newest room art request: the push-to-talk press count when it started, so only a
/// later press counts as the learner's next request, and whether it still reads the page and its picture, which holds the
/// thinking state until the panel opens.
nonisolated struct RoomArtRequestRecord: Equatable, Sendable {
    private(set) var pushToTalkPressCountWhenItStarted = 0
    private(set) var isOpeningThePanel = false

    /// The press that asked was counted before the request starts, so the request starts at the current count.
    mutating func start(atPushToTalkPressCount pushToTalkPressCount: Int) {
        pushToTalkPressCountWhenItStarted = pushToTalkPressCount
        isOpeningThePanel = true
    }

    /// The learner asked the open panel for something by voice or by a click, such as "right there" or Place for the
    /// furniture's ghost, "move it left", or the shirt's "right there" or its button, so a line about it that lands after
    /// this press, such as "Step aside for a second." or "Here it is", is still theirs. The panel is already open, so the
    /// opening flag is left as it is.
    mutating func continued(atPushToTalkPressCount pushToTalkPressCount: Int) {
        pushToTalkPressCountWhenItStarted = pushToTalkPressCount
    }

    /// The panel's opening returned, and the result says whether this request still owns the voice state. A push-to-talk
    /// press that cancelled the request started a newer request, which owns the voice state and, when it is another room
    /// art request, the opening flag too, so a cancelled request leaves both and returns false.
    mutating func openingReturned(requestWasCancelled: Bool) -> Bool {
        guard !requestWasCancelled else { return false }
        isOpeningThePanel = false
        return true
    }

    /// `roomArtLineStep` for this request.
    func lineStep(dictationIsInProgress: Bool, clickyIsThinking: Bool, audioIsPlaying: Bool, pushToTalkPressCount: Int) -> RoomArtLineStep {
        roomArtLineStep(
            dictationIsInProgress: dictationIsInProgress,
            clickyIsThinking: clickyIsThinking,
            audioIsPlaying: audioIsPlaying,
            roomArtIsOpeningThePanel: isOpeningThePanel,
            pushToTalkPressCount: pushToTalkPressCount,
            pushToTalkPressCountWhenTheRoomArtStarted: pushToTalkPressCountWhenItStarted
        )
    }
}

// MARK: - The phrase that asks for it

/// Whether the learner asks to see this item placed in their own room or on themselves: a room phrase ("in my room", "on my
/// wall", "on my desk", "on the table", "on that shelf", "on the wall behind me", "on me", ...) right after either a placing verb and the item ("show this", "put it",
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
    // A table or shelf item sits on a surface the learner clicks: "how would this mug look on my desk", or, on a table Clicky
    // already painted into the room, "how would this lamp look on the table" or "put this vase on that shelf".
    let surfacePhrases = ["my", "the", "that", "this"].flatMap { owner in
        ["table", "desk", "shelf", "counter", "dresser", "nightstand"].map { surface in ["on", owner, surface] }
    }
    let roomPhrases: [[String]] = [
        ["in", "my", "room"], ["on", "my", "wall"], ["in", "my", "living", "room"], ["in", "my", "bedroom"],
        ["in", "my", "office"], ["in", "my", "house"], ["in", "my", "home"], ["in", "my", "apartment"],
        ["in", "my", "space"], ["on", "the", "wall", "behind", "me"], ["on", "me"], ["on", "my", "floor"],
    ] + surfacePhrases
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
        return try RoomArtPageReading(
            responseData: responseData, pictureWidth: pageRequest.picture.width, pictureHeight: pageRequest.picture.height,
            otherPictureSizes: pageRequest.picture.otherPictures.prefix(RoomArtPicture.mostOtherPictures).map { ($0.width, $0.height) }
        )
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

    /// `floorRequest.anchor` is the keyframe pixel the item's front-bottom center stands on, and `floorRequest.standsOn` says
    /// whether that is the floor or a table or shelf top. The body is the wall's.
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
