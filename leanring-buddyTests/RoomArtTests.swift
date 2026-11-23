//
//  RoomArtTests.swift
//  leanring-buddyTests
//
//  "Show me how this would look in my room" and "could I see this shirt on me": the Worker replies parsed at the boundary,
//  what each reading asks for, the art's corners from the wall plane, the bare wall and floor spots, the wall's light, the
//  phrase and the tool that ask for it, and the panel's phases for wall art, furniture, and a shirt.
//

import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Clicky

private func jsonData(_ text: String) -> Data { Data(text.utf8) }

/// A solid image, enough to stand for a flattened artwork.
private func solidImage(width: Int, height: Int, red: CGFloat = 0.2) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// One image for every artwork and piece of furniture here, since a CGImage compares by identity and the phases compare
/// their items.
private let sharedItemImage = solidImage(width: 4, height: 5)
private let sharedFurnitureImage = solidImage(width: 4, height: 3)

private func artwork() -> RoomArtwork {
    RoomArtwork(title: "Water Lilies", widthMeters: 0.406, heightMeters: 0.508, includesFrame: false, flattenedImage: sharedItemImage)
}

private let wall = WallPlane(
    center: SIMD3(0, 0, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000,
    principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
)

/// The reply `POST /try-it-item` writes: the shared fields and an `item` that names its kind and holds that kind's object.
private func tryItReply(item itemJSON: String, title: String = "Water Lilies print", corners cornersJSON: String? = nil) -> String {
    let corners = cornersJSON ?? #"{"topLeft": {"x": -3, "y": 10}, "topRight": {"x": 390, "y": 12}, "bottomRight": {"x": 392, "y": 505}, "bottomLeft": {"x": 8, "y": 503}}"#
    return #"{"title": "\#(title)", "whyThisSize": "The page's size menu shows it selected.", "itemCorners": \#(corners), "item": \#(itemJSON)}"#
}

private let goodWallArtItem = """
{"kind": "wall", "wall": {"fillsItsCorners": true, "sizeFoundOnPage": true,
 "size": {"label": "16x20 in", "widthCentimeters": 40.6, "heightCentimeters": 50.8, "includesFrame": true},
 "otherSizes": [{"label": "8x10 in", "widthCentimeters": 20.3, "heightCentimeters": 25.4}, {"label": "Huge", "widthCentimeters": 5000, "heightCentimeters": 25}]}}
"""

private let goodRoomArtReply = tryItReply(item: goodWallArtItem)

private let goodFurnitureItem = """
{"kind": "standing", "standing": {"standsOn": "floor", "sizeFoundOnPage": true,
 "size": {"label": "180 x 90 cm", "widthCentimeters": 180, "heightCentimeters": 75, "depthCentimeters": 90}, "otherSizes": []}}
"""

private let goodClothingItem = """
{"kind": "clothing", "clothing": {"garment": "tshirt", "sleeves": "short", "chosenSizeLabel": "M", "photoShows": "flatLay",
 "printDescription": "large wave across the chest"}}
"""

private let goodRoomWallReply = """
{"center": [0.1, -0.2, 2.5], "right": [2, 0, 0], "up": [0, -1, 0], "focalPx": 980, "principal": [640, 360],
 "distanceMeters": 2.5, "wallAngleDegrees": 4, "planeInlierShare": 0.91, "inferenceSeconds": 12.1, "seconds": 13.9}
"""

private let sliverCorners = #"{"topLeft": {"x": 0, "y": 0}, "topRight": {"x": 400, "y": 0}, "bottomRight": {"x": 400, "y": 2}, "bottomLeft": {"x": 0, "y": 2}}"#
private let fullCorners = #"{"topLeft": {"x": 0, "y": 0}, "topRight": {"x": 400, "y": 0}, "bottomRight": {"x": 400, "y": 500}, "bottomLeft": {"x": 0, "y": 500}}"#

private func wallArtItem(sizeFound: String = "true", size: String = #"{"label": "S", "widthCentimeters": 20, "heightCentimeters": 30, "includesFrame": false}"#) -> String {
    #"{"kind": "wall", "wall": {"fillsItsCorners": true, "sizeFoundOnPage": \#(sizeFound), "size": \#(size), "otherSizes": []}}"#
}

/// The fixture the Worker's tests read too: `POST /try-it-item` responses shaped as the Worker returns them, one for each
/// kind plus a wall item and a standing item whose page states no size, a standing item for the floor and one for a table or
/// shelf, a round wall item that does not fill its corners, a wall shelf that cannot be shown, and a garment whose front is the second picture.
private struct TryItItemRepliesFixture: Decodable {
    struct PictureSize: Decodable {
        let width: Int
        let height: Int
    }

    struct Case: Decodable {
        let name: String
        let kind: String
        let response: JSONValue
    }

    let picture: PictureSize
    /// The one other picture each request carries, which a garment's front may be in.
    let otherPicture: PictureSize
    let cases: [Case]

    static func load() throws -> TryItItemRepliesFixture {
        let fixtureData = try Data(contentsOf: repositoryRootURL.appendingPathComponent("worker/src/testdata/try-it-item-replies.json"))
        return try JSONDecoder().decode(TryItItemRepliesFixture.self, from: fixtureData)
    }
}

/// What each case of the shared fixture must read as, written next to the case's name. A case with no expectation here fails.
private func expectedReading(ofFixtureCaseNamed caseName: String) -> RoomArtPageReading? {
    let pictureCorners = { (left: Double, top: Double, right: Double, bottom: Double) in
        RoomArtCorners(topLeft: CGPoint(x: left, y: top), topRight: CGPoint(x: right, y: top), bottomRight: CGPoint(x: right, y: bottom), bottomLeft: CGPoint(x: left, y: bottom))
    }
    switch caseName {
    case "a wall item with a stated size":
        return .wallArt(RoomArtWallArtReading(
            title: "Water Lilies print, framed",
            chosenSize: RoomArtSize(label: "16 x 20 in", widthCentimeters: 40.6, heightCentimeters: 50.8),
            chosenSizeIncludesFrame: true,
            fillsItsCorners: true,
            whyThisSize: "The page's size menu shows 16 x 20 in selected.",
            otherSizes: [RoomArtSize(label: "8 x 10 in", widthCentimeters: 20.3, heightCentimeters: 25.4)],
            artworkCorners: pictureCorners(40, 50, 360, 450)
        ))
    case "a wall item with no size on the page":
        return .sizeNotOnThePage(title: "Water Lilies print")
    case "a floor item only 5 centimeters deep":
        return .furniture(RoomArtFurnitureReading(
            title: "Slim floor mirror",
            chosenSize: RoomArtFurnitureSize(label: "50 x 170 cm", widthCentimeters: 50, heightCentimeters: 170, depthCentimeters: 5),
            whyThisSize: "The page lists one size, 50 x 170 cm.",
            itemCorners: pictureCorners(120, 20, 280, 480),
            standsOn: .floor
        ))
    case "a figure whose page states only its height":
        return .furniture(RoomArtFurnitureReading(
            title: "Up-Scaled Blue Astronaut Minifigure",
            chosenSize: RoomArtFurnitureSize(label: "over 10 in. (26 cm) tall", widthCentimeters: nil, heightCentimeters: 26, depthCentimeters: nil),
            whyThisSize: "The page says the figure stands over 10 in. (26 cm) tall and states no width or depth.",
            itemCorners: pictureCorners(120, 20, 280, 480)
        ))
    case "a rug 1 centimeter tall":
        return .furniture(RoomArtFurnitureReading(
            title: "Wool area rug",
            chosenSize: RoomArtFurnitureSize(label: "5 x 8 ft", widthCentimeters: 152.4, heightCentimeters: 1, depthCentimeters: 243.8),
            whyThisSize: "The page has 5 x 8 ft selected.",
            itemCorners: pictureCorners(20, 150, 380, 350),
            standsOn: .floor
        ))
    case "a mug on a table or shelf":
        return .furniture(RoomArtFurnitureReading(
            title: "Stoneware mug",
            chosenSize: RoomArtFurnitureSize(label: "9 x 10 cm", widthCentimeters: 12, heightCentimeters: 10, depthCentimeters: 9),
            whyThisSize: "The page lists one size, 9 cm wide and 10 cm tall.",
            itemCorners: pictureCorners(100, 120, 300, 380),
            standsOn: .tableOrShelf
        ))
    case "a standing item with no size on the page":
        return .furniture(RoomArtFurnitureReading(
            title: "Slim floor mirror",
            chosenSize: nil,
            whyThisSize: "The page text states no size.",
            itemCorners: pictureCorners(120, 20, 280, 480),
            standsOn: .floor
        ))
    case "clothing":
        return .clothing(RoomArtClothingReading(
            title: "Great Wave tee",
            garment: .tshirt,
            sleeves: .short,
            chosenSizeLabel: "M",
            photoShows: .flatLay,
            printDescription: "large wave print across the chest",
            whyThisSize: "The page has size M selected.",
            itemCorners: pictureCorners(30, 60, 370, 440)
        ))
    case "clothing whose front is the second picture":
        return .clothing(RoomArtClothingReading(
            title: "Sasquatch tee",
            garment: .tshirt,
            sleeves: .short,
            chosenSizeLabel: "M",
            photoShows: .onModel,
            printDescription: "large sasquatch graphic across the chest",
            whyThisSize: "The page has size M selected.",
            itemCorners: pictureCorners(20, 80, 280, 560),
            frontPictureIndex: 1
        ))
    case "a round wall clock that does not fill its corners":
        return .wallArt(RoomArtWallArtReading(
            title: "Round wall clock",
            chosenSize: RoomArtSize(label: "30 cm", widthCentimeters: 30, heightCentimeters: 30),
            chosenSizeIncludesFrame: true,
            fillsItsCorners: false,
            whyThisSize: "The page states a 30 cm diameter.",
            otherSizes: [],
            artworkCorners: pictureCorners(60, 110, 340, 390)
        ))
    case "a wall shelf that cannot be shown":
        return .cannotBeShown(title: "Floating wall shelf", reason: .notFlatForTheWall)
    default:
        return nil
    }
}

struct RoomArtTryItReplyFixtureTests {
    @Test func everyWorkerReplyInTheSharedFixtureReadsAsItsExpectedReading() throws {
        let fixture = try TryItItemRepliesFixture.load()
        #expect(Set(fixture.cases.map(\.kind)) == ["wall", "standing", "clothing", "cannotBeShown"])

        for fixtureCase in fixture.cases {
            let responseData = try JSONEncoder().encode(fixtureCase.response)
            let reading = try RoomArtPageReading(
                responseData: responseData, pictureWidth: fixture.picture.width, pictureHeight: fixture.picture.height,
                otherPictureSizes: [(fixture.otherPicture.width, fixture.otherPicture.height)]
            )

            #expect(reading == expectedReading(ofFixtureCaseNamed: fixtureCase.name), "the \(fixtureCase.name) reply read as \(reading)")
        }
    }
}

struct RoomArtReplyTests {
    @Test func aWallArtReplyBecomesItsSizeAndCornersClampedIntoThePicture() throws {
        let reading = try RoomArtPageReading(responseData: jsonData(goodRoomArtReply), pictureWidth: 400, pictureHeight: 500)

        guard case .wallArt(let wallArt) = reading else {
            Issue.record("Expected wall art, got \(reading)")
            return
        }
        #expect(wallArt.chosenSize == RoomArtSize(label: "16x20 in", widthCentimeters: 40.6, heightCentimeters: 50.8))
        #expect(wallArt.chosenSizeIncludesFrame)
        // A corner a few pixels outside the picture lands on its edge.
        #expect(wallArt.artworkCorners.topLeft == CGPoint(x: 0, y: 10))
        #expect(wallArt.artworkCorners.bottomRight == CGPoint(x: 392, y: 500))
        // A size of 50 meters is a misread and is dropped.
        #expect(wallArt.otherSizes.map(\.label) == ["8x10 in"])
    }

    @Test func aWallItemKeepsWhetherItFillsItsCorners() throws {
        let round = goodRoomArtReply.replacingOccurrences(of: #""fillsItsCorners": true"#, with: #""fillsItsCorners": false"#)

        let roundReading = try RoomArtPageReading(responseData: jsonData(round), pictureWidth: 400, pictureHeight: 500)
        let rectangleReading = try RoomArtPageReading(responseData: jsonData(goodRoomArtReply), pictureWidth: 400, pictureHeight: 500)

        guard case .wallArt(let roundWallItem) = roundReading, case .wallArt(let rectangularWallItem) = rectangleReading else {
            Issue.record("Expected wall items, got \(roundReading) and \(rectangleReading)")
            return
        }
        #expect(!roundWallItem.fillsItsCorners)
        #expect(rectangularWallItem.fillsItsCorners)
    }

    @Test func aFurnitureReplyBecomesItsSizeWithDepthAndCornersClampedIntoThePicture() throws {
        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: goodFurnitureItem, title: "Walnut table")), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .furniture(RoomArtFurnitureReading(
            title: "Walnut table",
            chosenSize: RoomArtFurnitureSize(label: "180 x 90 cm", widthCentimeters: 180, heightCentimeters: 75, depthCentimeters: 90),
            whyThisSize: "The page's size menu shows it selected.",
            itemCorners: RoomArtCorners(topLeft: CGPoint(x: 0, y: 10), topRight: CGPoint(x: 390, y: 12), bottomRight: CGPoint(x: 392, y: 500), bottomLeft: CGPoint(x: 8, y: 500)),
            standsOn: .floor
        )))
    }

    @Test func aStandingItemKeepsWhatItStandsOn() throws {
        let mugItem = goodFurnitureItem.replacingOccurrences(of: #""standsOn": "floor""#, with: #""standsOn": "tableOrShelf""#)

        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: mugItem, title: "Stoneware mug")), pictureWidth: 400, pictureHeight: 500)

        guard case .furniture(let standingItem) = reading else {
            Issue.record("Expected a standing item, got \(reading)")
            return
        }
        #expect(standingItem.standsOn == .tableOrShelf)
    }

    @Test func furnitureWhosePageStatesNoSizeStillReadsAsFurnitureWithNoSize() throws {
        let noSizeItem = goodFurnitureItem.replacingOccurrences(of: #""sizeFoundOnPage": true"#, with: #""sizeFoundOnPage": false"#)
            .replacingOccurrences(of: #""widthCentimeters": 180"#, with: #""widthCentimeters": 0"#)

        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: noSizeItem)), pictureWidth: 400, pictureHeight: 500)

        guard case .furniture(let furniture) = reading else {
            Issue.record("Expected furniture, got \(reading)")
            return
        }
        #expect(furniture.chosenSize == nil)
    }

    @Test func aClothingReplyBecomesItsGarmentDetailsAndCorners() throws {
        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: goodClothingItem, title: "Wave tee")), pictureWidth: 400, pictureHeight: 500)

        guard case .clothing(let clothing) = reading else {
            Issue.record("Expected clothing, got \(reading)")
            return
        }
        #expect(clothing.title == "Wave tee")
        #expect(clothing.garment == .tshirt && clothing.sleeves == .short && clothing.photoShows == .flatLay)
        #expect(clothing.chosenSizeLabel == "M" && clothing.printDescription == "large wave across the chest")
        #expect(clothing.itemCorners.bottomRight == CGPoint(x: 392, y: 500))
    }

    @Test(arguments: [
        ("notAPhysicalItem", RoomArtCannotBeShownReason.notAPhysicalItem),
        ("tooSmallToSee", RoomArtCannotBeShownReason.tooSmallToSee),
        ("noClearPhoto", RoomArtCannotBeShownReason.noClearPhoto),
        ("notFlatForTheWall", RoomArtCannotBeShownReason.notFlatForTheWall),
        ("noPlaceClickyCanShow", RoomArtCannotBeShownReason.noPlaceClickyCanShow),
    ])
    func aCannotBeShownReplyNeedsOnlyItsReasonAndTitle(wireReason: String, expectedReason: RoomArtCannotBeShownReason) throws {
        let item = #"{"kind": "cannotBeShown", "cannotBeShown": {"reason": "\#(wireReason)"}}"#
        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: item, title: "Brass lamp")), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .cannotBeShown(title: "Brass lamp", reason: expectedReason))
    }

    @Test func wallArtWhosePageStatesNoSizeIsReadAsSoAndNeverHung() throws {
        let noSizeReply = goodRoomArtReply.replacingOccurrences(of: #""sizeFoundOnPage": true"#, with: #""sizeFoundOnPage": false"#)

        let reading = try RoomArtPageReading(responseData: jsonData(noSizeReply), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .sizeNotOnThePage(title: "Water Lilies print"))
        #expect(RoomArtFailure.sizeNotOnThePage.spokenLine == "I couldn't find the size on that page.")
    }

    @Test(arguments: [
        // No fillsItsCorners, so the reply cannot say whether the photo needs cutting out by its shape.
        goodRoomArtReply.replacingOccurrences(of: #""fillsItsCorners": true,"#, with: ""),
        // No sizeFoundOnPage, so the reply cannot say whether the size came from the page.
        goodRoomArtReply.replacingOccurrences(of: #""sizeFoundOnPage": true,"#, with: ""),
        // No item.
        #"{"title": "A", "whyThisSize": "", "itemCorners": \#(fullCorners)}"#,
        // No corners.
        #"{"title": "A", "whyThisSize": "", "item": \#(wallArtItem())}"#,
        // A kind this app does not know.
        tryItReply(item: #"{"kind": "wallpaper"}"#, corners: fullCorners),
        // A kind named without its object.
        tryItReply(item: #"{"kind": "wall"}"#, corners: fullCorners),
        tryItReply(item: #"{"kind": "cannotBeShown"}"#, corners: fullCorners),
        // The kinds the page reader used before it said where the item goes.
        tryItReply(item: goodWallArtItem.replacingOccurrences(of: #""wall""#, with: #""wallArt""#), corners: fullCorners),
        tryItReply(item: #"{"kind": "other"}"#, corners: fullCorners),
        // A standing item that does not say what it stands on, or says somewhere this app does not know.
        tryItReply(item: goodFurnitureItem.replacingOccurrences(of: #""standsOn": "floor","#, with: ""), corners: fullCorners),
        tryItReply(item: goodFurnitureItem.replacingOccurrences(of: #""floor""#, with: #""ceiling""#), corners: fullCorners),
        // A reason this app has no line for.
        tryItReply(item: #"{"kind": "cannotBeShown", "cannotBeShown": {"reason": "tooExpensive"}}"#, corners: fullCorners),
        // A width of zero.
        tryItReply(item: wallArtItem(size: #"{"label": "S", "widthCentimeters": 0, "heightCentimeters": 30, "includesFrame": false}"#), corners: fullCorners),
        // An empty label, which the Worker refuses too.
        tryItReply(item: wallArtItem(size: #"{"label": " ", "widthCentimeters": 20, "heightCentimeters": 30, "includesFrame": false}"#), corners: fullCorners),
        // Corners that enclose a sliver.
        tryItReply(item: wallArtItem(), corners: sliverCorners),
        // A furniture size outside any real size.
        tryItReply(item: goodFurnitureItem.replacingOccurrences(of: #""depthCentimeters": 90"#, with: #""depthCentimeters": 0"#), corners: fullCorners),
        // A garment this app does not know.
        tryItReply(item: goodClothingItem.replacingOccurrences(of: #""tshirt""#, with: #""cape""#), corners: fullCorners),
        // An error body.
        #"{"error": "The page has no picture"}"#,
        "not json",
    ])
    func aTryItReplyThatCannotBeReadIsRefused(replyText: String) {
        #expect(throws: RoomArtReplyError.self) {
            try RoomArtPageReading(responseData: jsonData(replyText), pictureWidth: 400, pictureHeight: 500)
        }
    }

    @Test func aWallReplyBecomesAPlaneWithUnitDirections() throws {
        let plane = try WallPlane(responseData: jsonData(goodRoomWallReply))

        #expect(plane.center == SIMD3(0.1, -0.2, 2.5))
        #expect(plane.right == SIMD3(1, 0, 0))
        #expect(plane.focalLengthPixels == 980)
        #expect(plane.principalPoint == SIMD2(640, 360))
    }

    @Test(arguments: [
        goodRoomWallReply.replacingOccurrences(of: "[0.1, -0.2, 2.5]", with: "[0.1, -0.2, -1]"),
        goodRoomWallReply.replacingOccurrences(of: #""focalPx": 980"#, with: #""focalPx": 0"#),
        goodRoomWallReply.replacingOccurrences(of: "[2, 0, 0]", with: "[0, 0, 0]"),
        goodRoomWallReply.replacingOccurrences(of: "[640, 360]", with: "[640]"),
        #"{"error": "Depth Pro is not running"}"#,
    ])
    func aWallReplyThatCannotPlaceTheArtIsRefused(replyText: String) {
        #expect(throws: RoomArtReplyError.self) {
            try WallPlane(responseData: jsonData(replyText))
        }
    }

    @Test(arguments: [RoomArtSurfaceKind.wall, .floor])
    func aDepthServiceThatIsMissingOrDownAsksWhetherItRuns(surfaceKind: RoomArtSurfaceKind) {
        #expect(roomArtFailure(forAFailedMeasurementOf: surfaceKind, error: RoomArtWorkerError.workerReturned(statusCode: 503, body: "")) == .depthServiceUnavailable)
        #expect(roomArtFailure(forAFailedMeasurementOf: surfaceKind, error: RoomArtWorkerError.workerReturned(statusCode: 502, body: "")) == .depthServiceUnavailable)
    }

    @Test func a422IsTheWallOrTheFloorNotFoundForTheSurfaceThatWasMeasured() {
        // A 422 is the service or the Worker finding no surface it can place on, which a bare wall or a floor in view fixes.
        let noSurface = RoomArtWorkerError.workerReturned(statusCode: 422, body: "")
        #expect(roomArtFailure(forAFailedMeasurementOf: .wall, error: noSurface) == .wallNotMeasured)
        #expect(roomArtFailure(forAFailedMeasurementOf: .floor, error: noSurface) == .floorNotFound)
        // A reply that is not a plane means the same.
        #expect(roomArtFailure(forAFailedMeasurementOf: .floor, error: RoomArtReplyError(reason: "the floor's up must point up in the image")) == .floorNotFound)
        #expect(RoomArtFailure.floorNotFound.spokenLine == "I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor.")
    }

    @Test func aWorkerThatGivesNoAnswerSaysItCouldNotBeReached() {
        // The Worker is not running, or the request timed out, on either route.
        #expect(roomArtFailure(forAFailedMeasurementOf: .wall, error: URLError(.cannotConnectToHost)) == .workerUnreachable)
        #expect(roomArtFailure(forAFailedMeasurementOf: .floor, error: URLError(.timedOut)) == .workerUnreachable)
        #expect(roomArtFailure(forAFailedPageRead: URLError(.cannotConnectToHost)) == .workerUnreachable)
        #expect(roomArtFailure(forAFailedPageRead: URLError(.timedOut)) == .workerUnreachable)
        #expect(RoomArtFailure.workerUnreachable.spokenLine == "I couldn't reach Clicky's Worker.")
        #expect(RoomArtFailure.workerUnreachable.statusLine == "Couldn't reach Clicky's Worker")
    }

    @Test func a401OnEitherRouteSaysTheAppSecretIsMissing() {
        let refused = RoomArtWorkerError.workerReturned(statusCode: 401, body: #"{"error":"Missing or wrong x-clicky-app-secret"}"#)

        #expect(roomArtFailure(forAFailedMeasurementOf: .wall, error: refused) == .appSecretMissing)
        #expect(roomArtFailure(forAFailedMeasurementOf: .floor, error: refused) == .appSecretMissing)
        #expect(roomArtFailure(forAFailedPageRead: refused) == .appSecretMissing)
        #expect(roomArtFailure(forAFailedPageRead: RoomArtWorkerError.workerReturned(statusCode: 422, body: "")) == .pageNotRead)
        #expect(RoomArtFailure.appSecretMissing.spokenLine == "Clicky needs its app secret for this. See the README's Worker setup.")
    }

    @Test func thePageTextTitleAndLearnerWordsAreCutToTheWorkersLimitsInUTF16Units() {
        let picture = RoomArtPicture(jpegData: Data([1, 2, 3]), width: 10, height: 10)
        // Each emoji is 2 UTF-16 units, so 15,001 of them is 30,002 units and one must go.
        let pageRequest = RoomArtPageRequest(
            pageURL: "https://shop.example/print",
            pageTitle: String(repeating: "🖼", count: 251),
            pageText: String(repeating: "🖼", count: 15_001),
            learnerRequest: String(repeating: "🖼", count: 251),
            picture: picture
        )

        #expect(pageRequest.pageText.utf16.count == 30_000)
        #expect(pageRequest.pageTitle.utf16.count == 500)
        #expect(pageRequest.learnerRequest.utf16.count == 500)
        // One character past the Worker's 500 is cut, with plain text where no emoji's pair of units can hide an off by one.
        let plainWords = RoomArtPageRequest(pageURL: "https://shop.example/print", pageTitle: "Print", pageText: "A print", learnerRequest: String(repeating: "a", count: 501), picture: picture)
        #expect(plainWords.learnerRequest.utf16.count == 500)
        #expect(pageRequest.json["picture"]?["jpegBase64"]?.stringValue == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func aFloorMeasurementRequestSaysTableOrShelfOnlyForAnItemThatStandsOnOne() {
        func body(standsOn: RoomArtStandsOn) -> JSONValue {
            RoomWallRequest(keyframeJPEGData: Data([1]), personMaskPNGData: Data([2]), anchor: CGPoint(x: 10, y: 20), standsOn: standsOn).json
        }

        #expect(body(standsOn: .tableOrShelf)["standsOn"]?.stringValue == "tableOrShelf")
        // The field is absent for the floor, and for every wall request, so the depth service fits the floor as before.
        #expect(body(standsOn: .floor)["standsOn"] == nil)
        #expect(RoomWallRequest(keyframeJPEGData: Data([1]), personMaskPNGData: Data([2]), anchor: CGPoint(x: 10, y: 20)).json["standsOn"] == nil)
        // The rest of the body is the same for both.
        #expect(body(standsOn: .tableOrShelf)["anchor"] == body(standsOn: .floor)["anchor"])
    }

    @Test func theLearnersWordsGoToTheWorkerOnlyWhenTheyHoldAnything() {
        let picture = RoomArtPicture(jpegData: Data([1]), width: 10, height: 10)
        func json(forLearnerRequest learnerRequest: String) -> JSONValue {
            RoomArtPageRequest(pageURL: "https://shop.example/print", pageTitle: "Print", pageText: "A print", learnerRequest: learnerRequest, picture: picture).json
        }

        #expect(json(forLearnerRequest: "how would this chair look in my room")["learnerRequest"]?.stringValue == "how would this chair look in my room")
        #expect(json(forLearnerRequest: "")["learnerRequest"] == nil)
        #expect(json(forLearnerRequest: " \n ")["learnerRequest"] == nil)
    }
}

struct RoomArtGeometryTests {
    @Test func theArtsCornersProjectFromTheWallPlane() throws {
        // 50 by 40 cm, 2 m away, facing the camera: each corner is 0.25 m and 0.2 m from the center, which a focal length
        // of 1000 pixels at 2 m turns into 125 and 100 pixels from the principal point.
        let corners = try #require(wall.keyframeCorners(widthMeters: 0.5, heightMeters: 0.4))

        #expect(corners.topLeft == CGPoint(x: 515, y: 260))
        #expect(corners.topRight == CGPoint(x: 765, y: 260))
        #expect(corners.bottomRight == CGPoint(x: 765, y: 460))
        #expect(corners.bottomLeft == CGPoint(x: 515, y: 460))
    }

    @Test func aWallBehindTheCameraPlacesNothing() {
        let wallBehind = WallPlane(center: SIMD3(0, 0, -1), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 1, wallAngleDegrees: 0, planeInlierShare: 1)

        #expect(wallBehind.keyframeCorners(widthMeters: 0.5, heightMeters: 0.4) == nil)
    }

    @Test func aPerspectiveTransformMapsEachCornerOntoItsTarget() throws {
        let sourceCorners = [CGPoint(x: 0, y: 100), CGPoint(x: 80, y: 100), CGPoint(x: 80, y: 0), CGPoint(x: 0, y: 0)]
        let targetCorners = [CGPoint(x: 510, y: 300), CGPoint(x: 700, y: 320), CGPoint(x: 690, y: 90), CGPoint(x: 505, y: 120)]

        let transform = try #require(perspectiveTransform(from: sourceCorners, to: targetCorners))

        for (sourceCorner, targetCorner) in zip(sourceCorners, targetCorners) {
            let mapped = applyingPerspective(transform, to: sourceCorner)
            #expect(abs(mapped.x - targetCorner.x) < 1e-6 && abs(mapped.y - targetCorner.y) < 1e-6)
        }
    }

    @Test func theWallsLightGivesTheArtItsWhiteBalanceAndBrightness() {
        let warmDimWall = RoomArtWallLight(wallRed: 0.8, wallGreen: 0.7, wallBlue: 0.6)
        // The brightest channel, 0.8, times 1.08 is 0.864, and each channel keeps its share of it.
        #expect(abs(warmDimWall.redGain - 0.864) < 1e-9)
        #expect(abs(warmDimWall.greenGain - 0.756) < 1e-9)
        #expect(abs(warmDimWall.blueGain - 0.648) < 1e-9)

        // A white wall in strong light stops at 1.05, and a dark one at 0.5.
        #expect(RoomArtWallLight(wallRed: 1, wallGreen: 1, wallBlue: 1).redGain == 1.05)
        #expect(RoomArtWallLight(wallRed: 0.2, wallGreen: 0.2, wallBlue: 0.2).greenGain == 0.5)
    }

    @Test func theBareWallSpotIsTheBlankRegionAwayFromTextureAndThePerson() {
        let width = 320, height = 180
        var pixels = [Float](repeating: 200, count: width * height)
        var roomMask = [Float](repeating: 1, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                // The learner on the left, plain like the wall, which only the mask tells apart. The search meets them first.
                if column < 105 { roomMask[row * width + column] = 0 }
                // A bookshelf on the right: stripes.
                if column >= 215 { pixels[row * width + column] = (column / 3) % 2 == 0 ? 40 : 230 }
            }
        }
        let spot = bareWallSpot(grayscale: RoomGrayscaleImage(width: width, height: height, pixels: pixels), roomMask: roomMask)

        // The window is 77 pixels wide, so its center keeps 38 from the shelf, and the person's 15 pixel margin plus 38 from
        // the person.
        #expect(spot.x >= 105 + 15 + 38 && spot.x <= 215 - 38)
        // Art hangs in the upper part of the frame.
        #expect(spot.y >= 45 && spot.y <= 99)
    }

    @Test func theBareFloorSpotIsTheOpenFloorLowInTheFrameAwayFromThePerson() {
        let width = 320, height = 180
        var pixels = [Float](repeating: 200, count: width * height)
        var roomMask = [Float](repeating: 1, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                // The learner in the middle, standing on the floor.
                if column >= 130 && column < 190 { roomMask[row * width + column] = 0 }
                // A rug on the left: stripes.
                if column < 110 && row >= 100 { pixels[row * width + column] = (column / 3) % 2 == 0 ? 40 : 230 }
                // The upper part is a busy wall, so a spot there would be wrong even though it is plain elsewhere.
                if row < 90 { pixels[row * width + column] = (row / 2) % 2 == 0 ? 60 : 210 }
            }
        }
        let spot = bareFloorSpot(grayscale: RoomGrayscaleImage(width: width, height: height, pixels: pixels), roomMask: roomMask)

        // The window is 96 pixels wide, so its center keeps 48 from the person's 15 pixel margin on the right.
        #expect(spot.x >= 190 + 15 + 48)
        // Furniture stands low in the frame, from 62 to 86 percent of its height.
        #expect(spot.y >= 111 && spot.y <= 155)
    }

    @Test func onAnEvenFloorTheFurnitureStandsInTheMiddleNotInACorner() {
        let width = 320, height = 180
        // Plain floor everywhere, a little plainer at the right edge, as a dark corner of a wood floor is.
        var pixels = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width where column < 260 { pixels[row * width + column] = (row + column) % 2 == 0 ? 120 : 124 }
        }
        let spot = bareFloorSpot(grayscale: RoomGrayscaleImage(width: width, height: height, pixels: pixels), roomMask: [Float](repeating: 1, count: width * height))

        // A blank corner alone does not pull the piece to the edge, where the frame would cut it off.
        #expect(abs(spot.x - 160) <= 40, "the spot is at \(spot)")
    }

    @Test func aPlainCornerDoesNotOutweighTheMiddleOfAGrainedWoodFloor() {
        let width = 320, height = 180
        // Faint wood grain, a 0.8 step every 4 rows, about 1.6 of texture a pixel, and a plain corner on the right from
        // column 240, as room-floor.mp4's floor is. At a side cost of 1 the corner wins this floor.
        var pixels = [Float](repeating: 100, count: width * height)
        for row in 0..<height where (row / 4) % 2 == 1 {
            for column in 0..<240 { pixels[row * width + column] = 100.8 }
        }
        let spot = bareFloorSpot(grayscale: RoomGrayscaleImage(width: width, height: height, pixels: pixels), roomMask: [Float](repeating: 1, count: width * height))

        // The piece stands where the whole of it shows, near the middle, so the loop outlines the middle while the floor
        // is measured.
        #expect(abs(spot.x - 160) <= 40, "the spot is at \(spot)")
    }

    @Test func theFloorWindowStaysAboveTheStatusLine() {
        let width = 320, height = 180
        // Grain everywhere but a plain band along the bottom, so the lowest window the search allows wins.
        var pixels = [Float](repeating: 100, count: width * height)
        for row in 0..<150 where (row / 2) % 2 == 1 {
            for column in 0..<width { pixels[row * width + column] = 105 }
        }
        let spot = bareFloorSpot(grayscale: RoomGrayscaleImage(width: width, height: height, pixels: pixels), roomMask: [Float](repeating: 1, count: width * height))

        let windowBottom = spot.y + Double(height) * RoomArtBareFloorWindow.heightShareOfTheFrame / 2
        #expect(spot.y >= Double(height) * 0.75, "the plainest rows are low in the frame: \(spot)")
        #expect(windowBottom <= Double(height) * RoomArtBareFloorWindow.statusLineTopShareOfThePanel, "the window reaches \(windowBottom)")
    }

    @Test func flatteningCutsTheArtOutOfItsPhotoAtTheSizesShape() throws {
        // A 200 by 200 photo, white, with a red square from (50, 40) to (150, 140): the art.
        let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // CGContext's y grows up, so the square's top at y 40 from the top is 160 from the bottom.
        context.fill(CGRect(x: 50, y: 60, width: 100, height: 100))
        let photo = try #require(context.makeImage())
        let corners = RoomArtCorners(topLeft: CGPoint(x: 50, y: 40), topRight: CGPoint(x: 150, y: 40), bottomRight: CGPoint(x: 150, y: 140), bottomLeft: CGPoint(x: 50, y: 140))

        let flattened = try #require(flattenedArtwork(picture: photo, corners: corners, size: RoomArtSize(label: "8x10 in", widthCentimeters: 20.3, heightCentimeters: 25.4), context: CIContext()))

        // Portrait at the size's shape, 1200 on the long side.
        #expect(flattened.height == 1200)
        #expect(flattened.width == 959)
        // Every corner of the flattened art is the art's red, not the white around it.
        let bitmap = CGContext(data: nil, width: flattened.width, height: flattened.height, bitsPerComponent: 8, bytesPerRow: flattened.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.draw(flattened, in: CGRect(x: 0, y: 0, width: flattened.width, height: flattened.height))
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        for (column, row) in [(5, 5), (flattened.width - 6, 5), (5, flattened.height - 6), (flattened.width - 6, flattened.height - 6)] {
            let pixelStart = (row * flattened.width + column) * 4
            #expect(bytes[pixelStart] > 200 && bytes[pixelStart + 1] < 60, "pixel (\(column), \(row)) should be red")
        }
    }

    /// A square photo that holds only a disc of an item (red, opaque) with everything else clear, as the cutout by the item's
    /// own shape gives, so the corners of the box around the disc are clear.
    private func photoOfARoundItemOnClear(side: Int = 200) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fillEllipse(in: CGRect(x: 40, y: 40, width: side - 80, height: side - 80))
        return try #require(context.makeImage())
    }

    /// The alpha byte (0 to 255) of the pixel at `column`, `row` from the top left of `image`.
    private func alphaByte(of image: CGImage, column: Int, row: Int) throws -> UInt8 {
        let bitmap = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(bitmap.data).assumingMemoryBound(to: UInt8.self)
        return bytes[(row * image.width + column) * 4 + 3]
    }

    @Test func flatteningARoundItemOnAClearPhotoKeepsItsCornersTransparent() throws {
        let photo = try photoOfARoundItemOnClear()
        // The corners of the box around the disc, as the page reader gives them for a round item.
        let corners = RoomArtCorners(topLeft: CGPoint(x: 40, y: 40), topRight: CGPoint(x: 160, y: 40), bottomRight: CGPoint(x: 160, y: 160), bottomLeft: CGPoint(x: 40, y: 160))

        let flattened = try #require(flattenedArtwork(picture: photo, corners: corners, size: RoomArtSize(label: "30 cm", widthCentimeters: 30, heightCentimeters: 30), context: CIContext()))

        #expect(flattened.width == 1200 && flattened.height == 1200)
        for (column, row) in [(10, 10), (flattened.width - 11, 10), (10, flattened.height - 11), (flattened.width - 11, flattened.height - 11)] {
            #expect(try alphaByte(of: flattened, column: column, row: row) < 10, "pixel (\(column), \(row)) is the photo's background and should be clear")
        }
        #expect(try alphaByte(of: flattened, column: 600, row: 600) > 245, "the middle is the item")
    }

    /// The shadow image rendered over its own extent, with the extent so a test can find a pixel from art coordinates.
    private func renderedShadow(of art: CGImage) throws -> (image: CGImage, extent: CGRect) {
        let shadow = wallArtShadow(of: art)
        let image = try #require(CIContext().createCGImage(shadow, from: shadow.extent))
        return (image, shadow.extent)
    }

    @Test func aRoundItemCastsARoundShadowWhereARectangleCastsADarkCorner() throws {
        let round = try photoOfARoundItemOnClear(side: 400)
        let squareContext = try #require(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        squareContext.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        squareContext.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        let square = try #require(squareContext.makeImage())
        let roundShadow = try renderedShadow(of: round)
        let squareShadow = try renderedShadow(of: square)

        // A point 12 pixels inside the art's top left corner, in Core Image's y-up art coordinates.
        func alphaInsideTheTopLeftCorner(of shadow: (image: CGImage, extent: CGRect)) throws -> UInt8 {
            try alphaByte(of: shadow.image, column: Int(12 - shadow.extent.minX), row: Int(shadow.extent.maxY - (400 - 12)))
        }
        func alphaAtTheMiddle(of shadow: (image: CGImage, extent: CGRect)) throws -> UInt8 {
            try alphaByte(of: shadow.image, column: Int(200 - shadow.extent.minX), row: Int(shadow.extent.maxY - 190))
        }
        // 35 percent of 255 is 89. A rectangle's corner is mostly inside its shadow, and a disc's corner is clear of it.
        #expect(try alphaAtTheMiddle(of: roundShadow) > 80 && alphaAtTheMiddle(of: roundShadow) <= 92)
        #expect(try alphaInsideTheTopLeftCorner(of: roundShadow) < 6, "the round item's shadow leaves the corner of its box clear")
        #expect(try alphaInsideTheTopLeftCorner(of: squareShadow) > 40, "a rectangle's shadow is dark at its corner")
    }

    @Test func theShadowOfARectangleThatFillsItsPictureIsTheSameAsBefore() throws {
        let squareContext = try #require(CGContext(data: nil, width: 400, height: 500, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        squareContext.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        squareContext.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        let art = try #require(squareContext.makeImage())

        // The shadow as it was drawn before it followed the art's alpha: a solid 35 percent black box, offset and blurred.
        let artExtent = CGRect(x: 0, y: 0, width: 400, height: 500)
        let spread = 500 * 0.015, offset = -500 * 0.02
        let oldShadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
            .cropped(to: artExtent.offsetBy(dx: 0, dy: offset))
            .applyingGaussianBlur(sigma: spread)
            .cropped(to: artExtent.offsetBy(dx: 0, dy: offset).insetBy(dx: -3 * spread, dy: -3 * spread))
        let newShadow = wallArtShadow(of: art)

        #expect(newShadow.extent == oldShadow.extent)
        let context = CIContext()
        let oldImage = try #require(context.createCGImage(oldShadow, from: oldShadow.extent))
        let newImage = try #require(context.createCGImage(newShadow, from: newShadow.extent))
        for (column, row) in [(5, 5), (60, 300), (200, 250), (330, 480), (20, 520), (200, 40)] {
            let oldAlpha = Int(try alphaByte(of: oldImage, column: column, row: row)), newAlpha = Int(try alphaByte(of: newImage, column: column, row: row))
            #expect(abs(oldAlpha - newAlpha) <= 2, "pixel (\(column), \(row)) was \(oldAlpha) and is \(newAlpha)")
        }
    }
}

struct RoomArtPhraseTests {
    @Test(arguments: [
        "show me how this would look in my room",
        "How would this look on my wall?",
        "how would this poster look in my bedroom",
        "what would that print look like in my living room",
        "show this on my wall",
        "show me this on my wall",
        "put it on my wall",
        "can I see this in my living room",
        "try this in my room",
        "try this in my living room",
        "preview this on my wall",
        "preview this in my bedroom",
        "can you hang it on the wall behind me",
        "hang that print in my office",
        "put this in my office",
        "I want to see it in my apartment",
        // Up to two words from a closed list may sit between the look and the room phrase.
        "would this look good in my room",
        "how would this look hanging in my living room",
        // Furniture stands on the floor in the same panel.
        "how would this chair look in my room",
        // A table or shelf item sits on the surface the learner clicks.
        "how would this mug look on my table",
        "put this lamp on my desk",
        "what would this vase look like on my shelf",
        // A table or shelf already in the room, such as a table Clicky painted there.
        "how would this lamp look on the table",
        "put this vase on the shelf",
        "how would this lamp look on that table",
        "can I see this plant on the desk",
        // A shirt is drawn on the learner.
        "could I see this shirt on me",
        "how would this look on me",
        "what would this hoodie look like on me",
        "would this look good on me",
        "show me this on me",
        "can I try this on",
        "can I try this shirt on please",
        "try it on",
        "let me try on this jacket",
    ])
    func aPlacingVerbOrALookOnTheItemBeforeARoomPhraseAsksForIt(transcript: String) {
        #expect(asksToSeeArtInMyRoom(transcript))
    }

    @Test(arguments: [
        "what's on my wall",
        "clean my room",
        "show me this in 3D",
        "how would this look",
        "my room is a mess",
        "what's the wall made of",
        // A room phrase with a look word that governs no item to place.
        "how does the router in my house work",
        "what would look good in my room",
        "I put a poster in my room, who painted it",
        "what is the painting in my room called",
        "is there a window in my office",
        // A look with no item before it: the learner asks about themselves.
        "how do I look in my room",
        "how do I look good in my room",
        // Words outside the closed list between the look and the room phrase.
        "how would this look next to the lamp in my room",
        "what's on my desk",
        "clean my table",
        "what's on the table",
        "what is on that shelf",
        "clean the table",
        // "On me" or "try on" with no item to place, or "on" that starts another phrase.
        "what's on me",
        "is there something on me",
        "turn it on",
        "let me try this on the next video",
        "can you put the captions on for me",
        "how do I look on camera",
        "try on",
    ])
    func anythingElseAsksNothing(transcript: String) {
        #expect(!asksToSeeArtInMyRoom(transcript))
    }

    private func branch(_ transcript: String, brain: Bool = false, quizAnswerIsWaiting: Bool = false, themeStudioIsOpen: Bool = false) -> KeywordBranchAheadOfTheRouter? {
        keywordBranchAheadOfTheRouter(
            for: transcript,
            brainTakesEveryRequest: brain,
            sceneIsOnScreen: false,
            phaseIsWaitingForAQuizAnswer: quizAnswerIsWaiting,
            sceneIsBuilding: false,
            themeStudioIsOpen: themeStudioIsOpen
        )
    }

    @Test func theRoomPhraseRunsAheadOfTheRouterAndAheadOfShowMe() {
        // "Show me" alone would build a 3D scene on the keyword path.
        #expect(branch("show me how this would look in my room") == .showArtInMyRoom)
    }

    @Test func theBrainFlagAQuizQuestionOrTheOpenStudioLeaveItToTheRouterOrTheJudge() {
        #expect(branch("show me how this would look in my room", brain: true) == nil)
        #expect(branch("show me how this would look in my room", quizAnswerIsWaiting: true) == nil)
        #expect(branch("show me how this would look in my room", themeStudioIsOpen: true) == nil)
    }

    @Test func aFailedRouterHangsTheArtInsteadOfBuildingAScene() {
        #expect(routerFailureFallback(for: "show me how this would look in my room", sceneIsOnScreen: false) == .showArtInMyRoom)
    }
}

struct RoomArtToolTests {
    private func context(quizQuestionIsOpen: Bool) -> AppVoiceTool.Context {
        AppVoiceTool.Context(
            sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false,
            videoQuizIsRunning: false, quizQuestionIsOpen: quizQuestionIsOpen
        )
    }

    @Test func theToolIsOfferedWithNothingOnScreenAndHeldBackDuringAQuizQuestion() {
        #expect(AppVoiceTool.available(in: context(quizQuestionIsOpen: false)).contains(.showArtInMyRoom))
        #expect(!AppVoiceTool.available(in: context(quizQuestionIsOpen: true)).contains(.showArtInMyRoom))
    }

    @Test func theToolHandsOffToALookAtThePictureWithNoInputAndNoChip() {
        let descriptor = AppVoiceTool.showArtInMyRoom.descriptor
        #expect(descriptor.name == "show_art_in_my_room")
        #expect(descriptor.inputSchema["required"] == .array([]))
        #expect(AppVoiceTool.showArtInMyRoom.handsOffToALookAtTheMedia)
        #expect(VoiceToolCall(id: "a", name: "show_art_in_my_room", input: [:]).chipPhrase == nil)
    }
}

private func furniture(standsOn: RoomArtStandsOn = .floor) -> RoomFurniture {
    RoomFurniture(title: "LACK side table", widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55, cutoutImage: sharedFurnitureImage, standsOn: standsOn)
}

/// A floor 2 m ahead and 1 m below a camera with a 1000 pixel focal length.
private let floor = FloorPlane(
    center: SIMD3(0, 1, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1), focalLengthPixels: 1000,
    principalPoint: SIMD2(640, 360), distanceMeters: 2.2, floorTiltDegrees: 3, planeInlierShare: 0.9
)

/// A floor whose anchor is behind the camera, where nothing can stand.
private let floorBehindTheCamera = FloorPlane(
    center: SIMD3(0, 1, -2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), forward: SIMD3(0, 0, 1), focalLengthPixels: 1000,
    principalPoint: SIMD2(640, 360), distanceMeters: 2.2, floorTiltDegrees: 3, planeInlierShare: 0.9
)

private let pictureCorners = RoomArtCorners(topLeft: CGPoint(x: 20, y: 25), topRight: CGPoint(x: 380, y: 25), bottomRight: CGPoint(x: 380, y: 475), bottomLeft: CGPoint(x: 20, y: 475))

private func clothing(garment: RoomArtGarment = .tshirt, sleeves: RoomArtSleeves = .short, photoShows: RoomArtGarmentPhoto = .flatLay) -> RoomArtClothingReading {
    RoomArtClothingReading(title: "Linen shirt", garment: garment, sleeves: sleeves, chosenSizeLabel: "M", photoShows: photoShows, printDescription: "", whyThisSize: "M is selected.", itemCorners: pictureCorners)
}

struct RoomArtReadingPlanTests {
    @Test func aWallItemHangsAndAStandingItemWithASizeStandsOnItsSurface() {
        let wallArtReading = RoomArtWallArtReading(
            title: "Print", chosenSize: RoomArtSize(label: "S", widthCentimeters: 20, heightCentimeters: 30), chosenSizeIncludesFrame: false,
            fillsItsCorners: true, whyThisSize: "Selected.", otherSizes: [], artworkCorners: pictureCorners
        )
        #expect(roomArtReadingPlan(for: .wallArt(wallArtReading)) == .hangOnTheWall(wallArtReading))
        let tableSize = RoomArtFurnitureSize(label: "55x45 cm", widthCentimeters: 55, heightCentimeters: 45, depthCentimeters: 55)
        let table = RoomArtFurnitureReading(title: "LACK", chosenSize: tableSize, whyThisSize: "Only size.", itemCorners: pictureCorners)
        #expect(roomArtReadingPlan(for: .furniture(table)) == .standOnTheFloor(table, size: tableSize))
        // A mug on a table or shelf is placed the same way, and keeps what it stands on for the panel to ask for a click.
        let mugSize = RoomArtFurnitureSize(label: "9 x 10 cm", widthCentimeters: 12, heightCentimeters: 10, depthCentimeters: 9)
        let mug = RoomArtFurnitureReading(title: "Mug", chosenSize: mugSize, whyThisSize: "Only size.", itemCorners: pictureCorners, standsOn: .tableOrShelf)
        #expect(roomArtReadingPlan(for: .furniture(mug)) == .standOnTheFloor(mug, size: mugSize))
    }

    @Test func noSizeOnThePageFailsForAWallItemAndAStandingItemAlike() {
        #expect(roomArtReadingPlan(for: .sizeNotOnThePage(title: "Print")) == .fail(.sizeNotOnThePage))
        for standsOn in [RoomArtStandsOn.floor, .tableOrShelf] {
            let unsizedItem = RoomArtFurnitureReading(title: "LACK", chosenSize: nil, whyThisSize: "No size.", itemCorners: pictureCorners, standsOn: standsOn)
            #expect(roomArtReadingPlan(for: .furniture(unsizedItem)) == .fail(.sizeNotOnThePage))
        }
    }

    @Test func onlyATopPhotographedFlatOrOnAModelIsTriedOn() {
        for garment in [RoomArtGarment.tshirt, .shirt, .sweater, .hoodie, .jacket] {
            #expect(roomArtReadingPlan(for: .clothing(clothing(garment: garment))) == .tryOnTheShirt(clothing(garment: garment)))
        }
        #expect(roomArtReadingPlan(for: .clothing(clothing(garment: .dress))) == .fail(.onlyTopsSoFar))
        #expect(roomArtReadingPlan(for: .clothing(clothing(garment: .other))) == .fail(.onlyTopsSoFar))
        // A photo on a model is cut out around the model's body (ShirtOnModel.swift).
        #expect(roomArtReadingPlan(for: .clothing(clothing(photoShows: .onModel))) == .tryOnTheShirt(clothing(photoShows: .onModel)))
        #expect(roomArtReadingPlan(for: .clothing(clothing(sleeves: .none, photoShows: .onModel))) == .tryOnTheShirt(clothing(sleeves: .none, photoShows: .onModel)))
        // The model's forearms are cut away with the arms, so a long sleeve on a model would end at the upper arm. Laid flat,
        // a long sleeve is whole.
        #expect(roomArtReadingPlan(for: .clothing(clothing(garment: .hoodie, sleeves: .long, photoShows: .onModel))) == .fail(.longSleevesOnAModel))
        #expect(roomArtReadingPlan(for: .clothing(clothing(garment: .hoodie, sleeves: .long))) == .tryOnTheShirt(clothing(garment: .hoodie, sleeves: .long)))
        #expect(RoomArtFailure.longSleevesOnAModel.spokenLine == "I can only try on long sleeves from a photo of the top laid flat.")
        #expect(roomArtReadingPlan(for: .clothing(clothing(photoShows: .onHanger))) == .fail(.shirtPhotoNeitherFlatNorOnAModel))
        #expect(roomArtReadingPlan(for: .clothing(clothing(photoShows: .other))) == .fail(.shirtPhotoNeitherFlatNorOnAModel))
    }

    @Test(arguments: [
        (RoomArtCannotBeShownReason.notAPhysicalItem, RoomArtFailure.notAPhysicalItem, "That isn't something I can show in your room.", "Not something I can show in your room"),
        (RoomArtCannotBeShownReason.tooSmallToSee, RoomArtFailure.tooSmallToSee, "That's too small to see in your room.", "Too small to see in your room"),
        (RoomArtCannotBeShownReason.noClearPhoto, RoomArtFailure.noClearPhoto, "I couldn't find a clear photo of it on that page.", "No clear photo of it on the page"),
        (RoomArtCannotBeShownReason.notFlatForTheWall, RoomArtFailure.notFlatForTheWall, "I can only hang flat things on your wall so far.", "Only flat things hang on the wall so far"),
        (RoomArtCannotBeShownReason.noPlaceClickyCanShow, RoomArtFailure.noPlaceClickyCanShow, "I can show things on your wall, your floor, or a table so far.", "Only walls, floors, and tables so far"),
    ])
    func anItemThatCannotBeShownFailsWithItsReasonsOwnLines(reason: RoomArtCannotBeShownReason, failure: RoomArtFailure, spokenLine: String, statusLine: String) {
        #expect(roomArtReadingPlan(for: .cannotBeShown(title: "Round wall clock", reason: reason)) == .fail(failure))
        #expect(failure.spokenLine == spokenLine)
        #expect(failure.statusLine == statusLine)
        // The panel fails in the status line's own failure color, and the page's own words are never spoken.
        #expect(RoomArtPhase.readingThePage.afterThePageFailed(failure).statusLineIsAFailure(theSurfaceIsLost: false))
    }

    @Test func aShirtPhotoFailureLineIsStillItsOwn() {
        #expect(RoomArtFailure.shirtPhotoNeitherFlatNorOnAModel.spokenLine == "I can only try on a shirt from a photo of it laid flat or worn by a model.")
    }

    @Test func aStandingItemThatCannotBeCutOutSaysSoWithNoWordForFurniture() {
        #expect(RoomArtFailure.furnitureNotCutOut.spokenLine == "I couldn't cut it out of its photo.")
        #expect(RoomArtFailure.furnitureNotCutOut.statusLine == "Couldn't cut it out of its photo")
    }
}

struct RoomArtPhaseTests {
    private let firstMeasurement = RoomArtMeasurementID(number: 1)
    private let secondMeasurement = RoomArtMeasurementID(number: 2)

    @Test func onlyAnItemThatShowsKeepsTheRoomForANewItem() {
        #expect(RoomArtPhase.showing(item: .wallArt(artwork()), surface: .wall(wall), moveFailure: nil).keepsTheRoomForANewItem)
        #expect(RoomArtPhase.showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil).keepsTheRoomForANewItem)
        // A ghost the learner still moves, a piece still being arranged, and a shirt start over.
        let notShowing: [RoomArtPhase] = [
            .closed, .readingThePage, .waitingForTheCamera(.furniture(furniture())),
            .placingTheFurniture(id: firstMeasurement, item: .furniture(furniture()), surface: .floor(floor)),
            .arranging(id: firstMeasurement, item: .furniture(furniture()), surface: .floor(floor)),
            .couldNotDraw(id: firstMeasurement, item: .furniture(furniture()), surface: .floor(floor)),
            .waitingForAFloorClick(.furniture(furniture(standsOn: .tableOrShelf))),
            .showingTheShirt(title: "Linen shirt"), .showingThePaintedShirt(title: "Linen shirt"), .failed(.pageNotRead),
        ]
        for phase in notShowing {
            #expect(!phase.keepsTheRoomForANewItem, "\(phase)")
        }
    }

    @Test func thePageIsReadFirstThenTheItemWaitsForTheCameraThenItsSurfaceIsMeasured() {
        let reading = RoomArtPhase.closed.opening()
        #expect(reading == .readingThePage)
        #expect(reading.statusLine == "Reading the page…")
        let waiting = reading.withTheItemReady(.wallArt(artwork()))
        #expect(waiting == .waitingForTheCamera(.wallArt(artwork())))
        #expect(waiting.statusLine == "Starting the camera…")
        let measuring = waiting.startingAMeasurement(id: firstMeasurement)
        #expect(measuring == .measuring(id: firstMeasurement, item: .wallArt(artwork())))
        #expect(measuring.statusLine == "Measuring your wall…")
        let showing = measuring.withTheSurfaceMeasured(.wall(wall), measurementID: firstMeasurement)
        #expect(showing == .showing(item: .wallArt(artwork()), surface: .wall(wall), moveFailure: nil))
        // The size Clicky shows comes from the measured centimeters, never the page's own label.
        #expect(showing.statusLine == "On your wall at 16 by 20 inches")
    }

    @Test func furnitureIsMeasuredOnTheFloorAndSaysItsSizeWideAndTall() {
        let measuring = RoomArtPhase.readingThePage.withTheItemReady(.furniture(furniture())).startingAMeasurement(id: firstMeasurement)
        #expect(measuring.statusLine == "Measuring your floor…")
        // A wall reply never places furniture, so a mixed-up reply changes nothing.
        #expect(measuring.withTheSurfaceMeasured(.wall(wall), measurementID: firstMeasurement) == measuring)
        // Furniture shows its ghost first, which the learner moves until they place it.
        let placing = measuring.withTheSurfaceMeasured(.floor(floor), measurementID: firstMeasurement)
        #expect(placing == .placingTheFurniture(id: firstMeasurement, item: .furniture(furniture()), surface: .floor(floor)))
        #expect(placing.furnitureGhostShows)
        #expect(placing.statusLine == "Drag to move · say \u{201C}right there\u{201D}")
        #expect(placing.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the floor. Turn back to where the piece stands.")
        #expect(!placing.statusLineIsAFailure(theSurfaceIsLost: false))
        // Placed, it is arranged with no look until its painting or its fallback shows, under a placement number of its own.
        let arranging = placing.placingTheFurnitureWhereItsGhostStands(placementID: secondMeasurement)
        #expect(arranging == .arranging(id: secondMeasurement, item: .furniture(furniture()), surface: .floor(floor)))
        #expect(!arranging.furnitureGhostShows)
        #expect(arranging.statusLine == "Arranging it in your room…")
        #expect(arranging.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the floor. Turn back to where the piece stands.")
        #expect(!arranging.statusLineIsAFailure(theSurfaceIsLost: false))
        // Only a ghost can be placed.
        #expect(arranging.placingTheFurnitureWhereItsGhostStands(placementID: RoomArtMeasurementID(number: 3)) == arranging)
        let showing = arranging.withTheFurnitureShowing(measurementID: secondMeasurement)
        #expect(showing == .showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil))
        #expect(showing.statusLine == "On your floor, 21.5 inches wide and 17.5 tall")
        #expect(RoomArtPlacedItem.furniture(furniture()).hereItIsLine == "Here it is, 21.5 inches wide and 17.5 tall.")
        #expect(RoomArtPlacedItem.wallArt(artwork()).hereItIsLine == "Here it is at 16 by 20 inches.")
    }

    @Test func furnitureBeingArrangedWaitsForItsOwnLookAndIgnoresClicksAndOlderReplies() {
        let arranging = RoomArtPhase.arranging(id: secondMeasurement, item: .furniture(furniture()), surface: .floor(floor))
        // A look or a wait that ran out for an older placement changes nothing.
        #expect(arranging.withTheFurnitureShowing(measurementID: firstMeasurement) == arranging)
        // A click, a late measurement reply, and a late failure all wait, as during a measurement.
        #expect(arranging.startingAMeasurement(id: RoomArtMeasurementID(number: 3)) == arranging)
        #expect(arranging.withTheSurfaceMeasured(.floor(floor), measurementID: secondMeasurement) == arranging)
        #expect(arranging.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: secondMeasurement) == arranging)
        // Only a press on the piece picks it up, so the video shows no crosshair beside it.
        #expect(!arranging.theItemIsPlacedByClicking)
        // Only an arranged piece takes a look: a piece already showing keeps its phase, so "Here it is" is said once.
        let showing = arranging.withTheFurnitureShowing(measurementID: secondMeasurement)
        #expect(showing.withTheFurnitureShowing(measurementID: secondMeasurement) == showing)
        #expect(RoomArtPhase.measuring(id: secondMeasurement, item: .furniture(furniture())).withTheFurnitureShowing(measurementID: secondMeasurement) == .measuring(id: secondMeasurement, item: .furniture(furniture())))
        // A click on placed furniture measures nothing: a press picks it back up as its ghost on the floor already measured,
        // whether its look shows or is still on its way, and the camera failing ends it.
        let thirdPlacement = RoomArtMeasurementID(number: 3)
        #expect(showing.startingAMeasurement(id: thirdPlacement) == showing)
        #expect(!showing.theItemIsPlacedByClicking)
        #expect(showing.pickingTheFurnitureBackUp(placementID: thirdPlacement) == .placingTheFurniture(id: thirdPlacement, item: .furniture(furniture()), surface: .floor(floor)))
        #expect(arranging.pickingTheFurnitureBackUp(placementID: thirdPlacement) == .placingTheFurniture(id: thirdPlacement, item: .furniture(furniture()), surface: .floor(floor)))
        // Wall art is never picked up, and a ghost waits for its own placement: a click or a late reply changes nothing.
        let showingTheArt = RoomArtPhase.showing(item: .wallArt(artwork()), surface: .wall(wall), moveFailure: nil)
        #expect(showingTheArt.pickingTheFurnitureBackUp(placementID: thirdPlacement) == showingTheArt)
        let placing = RoomArtPhase.placingTheFurniture(id: secondMeasurement, item: .furniture(furniture()), surface: .floor(floor))
        #expect(placing.startingAMeasurement(id: thirdPlacement) == placing)
        #expect(placing.withTheSurfaceMeasured(.floor(floor), measurementID: secondMeasurement) == placing)
        #expect(placing.withTheFurnitureShowing(measurementID: secondMeasurement) == placing)
        #expect(placing.pickingTheFurnitureBackUp(placementID: thirdPlacement) == placing)
        #expect(placing.theItemIsPlacedByClicking)
        #expect(showingTheArt.theItemIsPlacedByClicking)
        // A floor no ghost can stand on asks for a click on the floor, and only a ghost waiting to be placed takes that.
        #expect(placing.afterTheGhostCouldNotStand() == .waitingForAFloorClick(.furniture(furniture())))
        #expect(arranging.afterTheGhostCouldNotStand() == arranging)
        #expect(arranging.afterTheCameraFailed(.noCamera) == .failed(.noCamera))
        #expect(arranging.closing() == .closed)
    }

    @Test func furnitureThatCouldNotBeDrawnKeepsItsLoopAndAPressPicksItsGhostBackUp() {
        let arranging = RoomArtPhase.arranging(id: secondMeasurement, item: .furniture(furniture()), surface: .floor(floor))
        #expect(arranging.afterTheFurnitureCouldNotBeDrawn(measurementID: firstMeasurement) == arranging)
        let couldNotDraw = arranging.afterTheFurnitureCouldNotBeDrawn(measurementID: secondMeasurement)
        #expect(couldNotDraw == .couldNotDraw(id: secondMeasurement, item: .furniture(furniture()), surface: .floor(floor)))
        #expect(couldNotDraw.statusLine == "I couldn't draw it this time. Click the floor to try again")
        #expect(couldNotDraw.statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(couldNotDraw.theItemIsPlacedByClicking)
        // The loop stays on its clock with its whole line still, since nothing runs until the learner clicks.
        #expect(RoomArtLoopState.drawing(beganAt: 3).after(phaseChangedTo: couldNotDraw, at: 9) == .waitingForAClick(beganAt: 3))
        // A painting that still arrives for this placement shows the piece, and one for another does nothing.
        #expect(couldNotDraw.withTheFurnitureShowing(measurementID: secondMeasurement) == .showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil))
        #expect(couldNotDraw.withTheFurnitureShowing(measurementID: firstMeasurement) == couldNotDraw)
        // A click measures nothing: a press picks the ghost back up on the floor already measured, to be placed again.
        let third = RoomArtMeasurementID(number: 3)
        #expect(couldNotDraw.startingAMeasurement(id: third) == couldNotDraw)
        #expect(couldNotDraw.pickingTheFurnitureBackUp(placementID: third) == .placingTheFurniture(id: third, item: .furniture(furniture()), surface: .floor(floor)))
        #expect(roomFurnitureNotDrawnLine == "I couldn't draw it this time. Click the floor to try again.")
    }

    @Test func furnituresFallbackWaitsForThePaintingAndPrefersTheRender() {
        // While the painting may still come, nothing but the loop shows.
        for render in [RoomFurnitureRenderState.coming, .ready, .none] {
            #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: render) == .keepWaiting)
            #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: true, render: render) == .keepWaiting)
        }
        // No painting can come: the render, else no piece and the line that says so, and a render still being made is
        // waited for.
        #expect(roomFurnitureFallbackStep(paintingCannotCome: true, theWaitRanOut: false, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: .ready) == .showTheRender)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: true, theWaitRanOut: false, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: .none) == .sayItCouldNotBeDrawn)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: true, theWaitRanOut: false, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: .coming) == .keepWaiting)
        // The 45 second wait ran out with no request in flight: whatever is ready now.
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: true, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: .ready) == .showTheRender)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: true, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: .none) == .sayItCouldNotBeDrawn)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: true, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: .coming) == .sayItCouldNotBeDrawn)
        #expect(roomFurnitureSecondsToWaitForALook == 45)
    }

    @Test func aWaitThatRanOutNeverGivesUpOnAPaintingRequestStillInFlight() {
        // A ready render shows, and a later painting crossfades over it.
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: true, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: true, render: .ready) == .showTheRender)
        // With no render or one still being made, the request's own timeout decides, and not a line that sent the learner to
        // click the floor, which cancelled the painting about to arrive.
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: true, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: true, render: .none) == .keepWaiting)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: true, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: true, render: .coming) == .keepWaiting)
    }

    @Test func thePlacementWaitShowsAReadyRenderAndSaysItCouldNotBeDrawnOnlyWithNoRequestOutAndNoModelComing() {
        // The 45 seconds since the placement are up, and no painting request is out, as while the learner covers the box.
        // A ready render shows, and the line that the piece could not be drawn waits for the model search to end.
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: true, aPaintingRequestIsInFlight: false, render: .ready) == .showTheRender)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: true, aPaintingRequestIsInFlight: false, render: .none) == .sayItCouldNotBeDrawn)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: true, aPaintingRequestIsInFlight: false, render: .coming) == .keepWaiting)
        // With a request out, only a ready render may show: the request has its own wait and its own timeout.
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: true, aPaintingRequestIsInFlight: true, render: .ready) == .showTheRender)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: true, aPaintingRequestIsInFlight: true, render: .none) == .keepWaiting)
        #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: true, aPaintingRequestIsInFlight: true, render: .coming) == .keepWaiting)
        // Before the 45 seconds are up, nothing shows for a painting that may still come.
        for render in [RoomFurnitureRenderState.coming, .ready, .none] {
            #expect(roomFurnitureFallbackStep(paintingCannotCome: false, theWaitRanOut: false, thePlacementWaitRanOut: false, aPaintingRequestIsInFlight: false, render: render) == .keepWaiting)
        }
    }

    @Test func aFloorThatIsNotFoundWaitsForAClickAndTheClickMeasuresAgain() {
        let measuring = RoomArtPhase.waitingForTheCamera(.furniture(furniture())).startingAMeasurement(id: firstMeasurement)

        let waitingForAClick = measuring.afterTheMeasurementFailed(.floorNotFound, measurementID: firstMeasurement)
        #expect(waitingForAClick == .waitingForAFloorClick(.furniture(furniture())))
        #expect(waitingForAClick.statusLine == "Tilt the screen down so the floor shows, then click the floor")
        #expect(waitingForAClick.statusLineIsAFailure(theSurfaceIsLost: false))
        // A floor that cannot stand the piece means the same as one not found.
        #expect(measuring.withTheSurfaceMeasured(.floor(floorBehindTheCamera), measurementID: firstMeasurement) == waitingForAClick)
        // The click measures again, and a floor found stands the piece on it.
        let measuringAgain = waitingForAClick.startingAMeasurement(id: secondMeasurement)
        #expect(measuringAgain == .measuring(id: secondMeasurement, item: .furniture(furniture())))
        #expect(measuringAgain.withTheSurfaceMeasured(.floor(floor), measurementID: secondMeasurement) == .placingTheFurniture(id: secondMeasurement, item: .furniture(furniture()), surface: .floor(floor)))
        // Any other failure of the first floor measurement ends the panel.
        #expect(measuring.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .failed(.depthServiceUnavailable))
    }

    @Test func aTableOrShelfItemWaitsForAClickInsteadOfAnAutomaticMeasurement() {
        let mug = RoomArtPlacedItem.furniture(furniture(standsOn: .tableOrShelf))
        let waitingForTheCamera = RoomArtPhase.readingThePage.withTheItemReady(mug)

        // With the camera ready, the panel asks for a click and measures nothing.
        let waitingForAClick = waitingForTheCamera.askingForAClickIfTheItemNeedsOne()
        #expect(waitingForAClick == .waitingForAFloorClick(mug, aClickFoundNothing: false))
        #expect(waitingForAClick.statusLine == "Click the table or shelf where it should go")
        // The invitation is not a failure, so the status line is not red and the cursor does not shake.
        #expect(!waitingForAClick.statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(RoomArtSurfaceClickPrompt.whereTheItemShouldGo.spokenLine == "Click the table or shelf where it should go.")
        #expect(!RoomArtSurfaceClickPrompt.whereTheItemShouldGo.isAFailure)
        #expect(waitingForAClick.theItemIsPlacedByClicking)

        // Wall art and a floor item still measure at once, and only a phase that waits for the camera asks.
        #expect(RoomArtPhase.waitingForTheCamera(.wallArt(artwork())).askingForAClickIfTheItemNeedsOne() == .waitingForTheCamera(.wallArt(artwork())))
        #expect(RoomArtPhase.waitingForTheCamera(.furniture(furniture())).askingForAClickIfTheItemNeedsOne() == .waitingForTheCamera(.furniture(furniture())))
        #expect(RoomArtPhase.readingThePage.askingForAClickIfTheItemNeedsOne() == .readingThePage)
        #expect(waitingForAClick.askingForAClickIfTheItemNeedsOne() == waitingForAClick)

        // The click measures the surface, which the status line calls the surface and not the floor.
        let measuring = waitingForAClick.startingAMeasurement(id: firstMeasurement)
        #expect(measuring == .measuring(id: firstMeasurement, item: mug))
        #expect(measuring.statusLine == "Measuring the surface…")
        // A click that finds no flat surface asks for the top of a table or shelf, as a failure, and waits for another click.
        let afterAFailedClick = measuring.afterTheMeasurementFailed(.floorNotFound, measurementID: firstMeasurement)
        #expect(afterAFailedClick == .waitingForAFloorClick(mug, aClickFoundNothing: true))
        #expect(afterAFailedClick.statusLine == "Click the top of a table or shelf")
        #expect(afterAFailedClick.statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(RoomArtSurfaceClickPrompt.noFlatSurfaceThere.spokenLine == "I couldn't find a flat surface there. Click the top of a table or shelf.")
        #expect(RoomArtSurfaceClickPrompt.noFlatSurfaceThere.isAFailure)
        // A surface the piece cannot stand on means the same, and so does a ghost that cannot stand on it.
        #expect(measuring.withTheSurfaceMeasured(.floor(floorBehindTheCamera), measurementID: firstMeasurement) == afterAFailedClick)
        let placing = RoomArtPhase.placingTheFurniture(id: firstMeasurement, item: mug, surface: .floor(floor))
        #expect(placing.afterTheGhostCouldNotStand() == afterAFailedClick)
        // Any other failure ends the panel, as for a floor.
        #expect(measuring.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .failed(.depthServiceUnavailable))
        // The next click measures again and places the ghost.
        let measuringAgain = afterAFailedClick.startingAMeasurement(id: secondMeasurement)
        #expect(measuringAgain.withTheSurfaceMeasured(.floor(floor), measurementID: secondMeasurement) == .placingTheFurniture(id: secondMeasurement, item: mug, surface: .floor(floor)))
    }

    @Test func aTableOrShelfItemSaysTheTableInEveryLineThatSaysFloor() {
        let mug = RoomArtPlacedItem.furniture(furniture(standsOn: .tableOrShelf))
        let tableSurface = RoomArtSurface.floor(floor)
        let placing = RoomArtPhase.placingTheFurniture(id: firstMeasurement, item: mug, surface: tableSurface)
        #expect(placing.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the table. Turn back to where it stands.")
        // The ghost's own status line has no floor in it, so it is the same for both.
        #expect(placing.statusLine == "Drag to move · say \u{201C}right there\u{201D}")
        let arranging = placing.placingTheFurnitureWhereItsGhostStands(placementID: secondMeasurement)
        #expect(arranging.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the table. Turn back to where it stands.")
        #expect(arranging.statusLine == "Arranging it in your room…")
        let showing = arranging.withTheFurnitureShowing(measurementID: secondMeasurement)
        #expect(showing.statusLine == "On the table, 21.5 inches wide and 17.5 tall")
        #expect(showing.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the table. Turn back to where it stands.")
        // "Here it is" has no floor in it.
        #expect(mug.hereItIsLine == "Here it is, 21.5 inches wide and 17.5 tall.")
        let couldNotDraw = arranging.afterTheFurnitureCouldNotBeDrawn(measurementID: secondMeasurement)
        #expect(couldNotDraw.statusLine == "I couldn't draw it this time. Click the table or shelf to try again")
        #expect(mug.notDrawnLine == "I couldn't draw it this time. Click the table or shelf to try again.")
        #expect(roomFurnitureNotDrawnOnATableLine == mug.notDrawnLine)
    }

    @Test func aFloorItemKeepsEveryFloorLineByteForByte() {
        let sofa = RoomArtPlacedItem.furniture(furniture())
        // A floor item's phase is the same value whether or not a click failed, and it says the floor line either way.
        let measuring = RoomArtPhase.waitingForTheCamera(sofa).startingAMeasurement(id: firstMeasurement)
        #expect(measuring.afterTheMeasurementFailed(.floorNotFound, measurementID: firstMeasurement) == .waitingForAFloorClick(sofa, aClickFoundNothing: false))
        #expect(sofa.surfaceClickPrompt(afterAClickFoundNothing: true) == .noFloorWasFound)
        #expect(sofa.surfaceClickPrompt(afterAClickFoundNothing: false) == .noFloorWasFound)
        #expect(RoomArtSurfaceClickPrompt.noFloorWasFound.spokenLine == "I couldn't find your floor. Tilt the screen down so the floor shows, then click the floor.")
        #expect(RoomArtSurfaceClickPrompt.noFloorWasFound.statusLine == "Tilt the screen down so the floor shows, then click the floor")
        #expect(measuring.statusLine == "Measuring your floor…")
        let placing = RoomArtPhase.placingTheFurniture(id: firstMeasurement, item: sofa, surface: .floor(floor))
        #expect(placing.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the floor. Turn back to where the piece stands.")
        #expect(placing.afterTheGhostCouldNotStand() == .waitingForAFloorClick(sofa))
        let couldNotDraw = RoomArtPhase.couldNotDraw(id: secondMeasurement, item: sofa, surface: .floor(floor))
        #expect(couldNotDraw.statusLine == "I couldn't draw it this time. Click the floor to try again")
        #expect(sofa.notDrawnLine == roomFurnitureNotDrawnLine)
    }

    @Test func aWallThatPlacesNothingOnTheFirstMeasurementFailsAndNeverWaitsForAClick() {
        let measuring = RoomArtPhase.waitingForTheCamera(.wallArt(artwork())).startingAMeasurement(id: firstMeasurement)
        let wallBehindTheCamera = WallPlane(
            center: SIMD3(0, 0, -2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000,
            principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
        )

        #expect(measuring.withTheSurfaceMeasured(.wall(wallBehindTheCamera), measurementID: firstMeasurement) == .failed(.wallNotMeasured))
        // Only furniture waits for a click, so a floor failure for wall art could only end the panel.
        #expect(measuring.afterTheMeasurementFailed(.floorNotFound, measurementID: firstMeasurement) == .failed(.floorNotFound))
        #expect(RoomArtPhase.failed(.wallNotMeasured).startingAMeasurement(id: secondMeasurement) == .failed(.wallNotMeasured))
    }

    @Test func theSizeIsSaidInInchesToTheNearestHalfInch() {
        #expect(roomArtSizeInInches(widthCentimeters: 40.6, heightCentimeters: 50.8) == "16 by 20 inches")
        #expect(roomArtSizeInInches(widthCentimeters: 21.59, heightCentimeters: 27.94) == "8.5 by 11 inches")
        // 50 by 70 cm is 19.69 by 27.56 inches.
        #expect(roomArtSizeInInches(widthCentimeters: 50, heightCentimeters: 70) == "19.5 by 27.5 inches")
    }

    @Test func aFailedMovePutsTheItemBackOnItsSurfaceAndSaysWhyInTheStatusLineOnly() {
        let theArt = RoomArtPlacedItem.wallArt(artwork())
        let movedWall = WallPlane(
            center: SIMD3(0.5, 0, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000,
            principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
        )
        let moving = RoomArtPhase.showing(item: theArt, surface: .wall(wall), moveFailure: nil).startingAMeasurement(id: secondMeasurement)

        let afterAFailedMove = moving.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: secondMeasurement)
        #expect(afterAFailedMove == .showing(item: theArt, surface: .wall(wall), moveFailure: .depthServiceUnavailable))
        #expect(afterAFailedMove.statusLine == "Couldn't measure the room. Is the depth service running?")
        #expect(afterAFailedMove.statusLineIsAFailure(theSurfaceIsLost: false))
        // A wall behind the camera places nothing, so the art stays on the wall it hung on.
        let wallBehindTheCamera = WallPlane(
            center: SIMD3(0, 0, -2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000,
            principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
        )
        #expect(moving.withTheSurfaceMeasured(.wall(wallBehindTheCamera), measurementID: secondMeasurement) == .showing(item: theArt, surface: .wall(wall), moveFailure: .wallNotMeasured))
        // A click after the failure tries again, and a measured wall moves the art and clears the failure.
        let movingAgain = afterAFailedMove.startingAMeasurement(id: RoomArtMeasurementID(number: 3))
        #expect(movingAgain == .moving(id: RoomArtMeasurementID(number: 3), item: theArt, surfaceBeforeTheMove: .wall(wall)))
        #expect(movingAgain.withTheSurfaceMeasured(.wall(movedWall), measurementID: RoomArtMeasurementID(number: 3)) == .showing(item: theArt, surface: .wall(movedWall), moveFailure: nil))
        // Furniture never moves by a new measurement, since its ghost moves on the floor already measured.
        let showingTheTable = RoomArtPhase.showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil)
        #expect(showingTheTable.startingAMeasurement(id: secondMeasurement) == showingTheTable)
    }

    @Test func aLostSurfaceSaysSoWhileTheItemShowsAndTheSizeLineReturnsWhenFound() {
        let showing = RoomArtPhase.showing(item: .wallArt(artwork()), surface: .wall(wall), moveFailure: nil)

        #expect(showing.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the wall. Turn back, or click the wall to place it again.")
        #expect(showing.statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil) == "On your wall at 16 by 20 inches")
        #expect(!showing.statusLineIsAFailure(theSurfaceIsLost: true))
        let showingTheTable = RoomArtPhase.showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil)
        #expect(showingTheTable.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the floor. Turn back to where the piece stands.")
        // Before the item shows, a lost room hides nothing, so the line keeps its own words.
        #expect(RoomArtPhase.readingThePage.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Reading the page…")
    }

    @Test func theShirtIsPreparedThenWaitsForTheLearnerThenShows() {
        let preparing = RoomArtPhase.readingThePage.startingTheShirt(title: "Linen shirt")
        #expect(preparing == .preparingTheShirt(title: "Linen shirt"))
        #expect(preparing.statusLine == "Getting the shirt ready…")
        // The coaching takes the status line while the learner is not where the shirt can be drawn.
        #expect(preparing.statusLine(theSurfaceIsLost: false, shirtCoachingLine: "Stand back so I can see your shoulders and chest.") == "Stand back so I can see your shoulders and chest.")
        let waiting = preparing.withTheGarmentReady(learnerIsInFrame: false)
        #expect(waiting == .waitingToSeeTheLearner(title: "Linen shirt"))
        let showing = waiting.afterTheLearnerStoodInFrame()
        #expect(showing == .showingTheShirt(title: "Linen shirt"))
        #expect(showing.statusLine == "On you")
        // A learner already in view when the garment is ready sees the shirt at once.
        #expect(preparing.withTheGarmentReady(learnerIsInFrame: true) == .showingTheShirt(title: "Linen shirt"))
        // The learner standing in view before the garment is ready changes nothing until it is.
        #expect(preparing.afterTheLearnerStoodInFrame() == preparing)
        // A click does nothing on a shirt, and a garment that cannot be cut out ends the panel.
        #expect(showing.startingAMeasurement(id: firstMeasurement) == showing)
        #expect(preparing.afterTheGarmentFailed() == .failed(.garmentNotCutOut))
        #expect(waiting.afterTheGarmentFailed() == waiting)
    }

    @Test func aReplyAfterThePanelClosedChangesNothing() {
        let closed = RoomArtPhase.waitingForTheCamera(.wallArt(artwork())).startingAMeasurement(id: firstMeasurement).closing()

        #expect(closed.withTheSurfaceMeasured(.wall(wall), measurementID: firstMeasurement) == .closed)
        #expect(closed.withTheItemReady(.wallArt(artwork())) == .closed)
        #expect(closed.startingTheShirt(title: "Tee") == .closed)
        #expect(closed.afterThePageFailed(.pageNotRead) == .closed)
        #expect(closed.withTheGarmentReady(learnerIsInFrame: true) == .closed)
        #expect(closed.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .closed)
        #expect(closed.afterTheCameraFailed(.noCamera) == .closed)
    }

    @Test func aReplyFromAnEarlierMeasurementChangesNothing() {
        let theArt = RoomArtPlacedItem.wallArt(artwork())
        // The learner clicked to move the art, which started a second measurement that keeps the art.
        let movingTheArt = RoomArtPhase.showing(item: theArt, surface: .wall(wall), moveFailure: nil).startingAMeasurement(id: secondMeasurement)
        #expect(movingTheArt == .moving(id: secondMeasurement, item: theArt, surfaceBeforeTheMove: .wall(wall)))

        #expect(movingTheArt.withTheSurfaceMeasured(.wall(wall), measurementID: firstMeasurement) == movingTheArt)
        #expect(movingTheArt.afterTheMeasurementFailed(.wallNotMeasured, measurementID: firstMeasurement) == movingTheArt)
    }

    @Test func aClickDuringAMeasurementOrBeforeTheItemIsReadIsIgnored() {
        let measuring = RoomArtPhase.waitingForTheCamera(.wallArt(artwork())).startingAMeasurement(id: firstMeasurement)

        #expect(measuring.startingAMeasurement(id: secondMeasurement) == measuring)
        #expect(RoomArtPhase.readingThePage.startingAMeasurement(id: firstMeasurement) == .readingThePage)
        #expect(RoomArtPhase.closed.startingAMeasurement(id: firstMeasurement) == .closed)
        #expect(RoomArtPhase.failed(.noPlaceClickyCanShow).startingAMeasurement(id: firstMeasurement) == .failed(.noPlaceClickyCanShow))
    }

    @Test func aFailureSaysWhatWentWrong() {
        let measuring = RoomArtPhase.waitingForTheCamera(.wallArt(artwork())).startingAMeasurement(id: firstMeasurement)

        #expect(measuring.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .failed(.depthServiceUnavailable))
        #expect(RoomArtPhase.readingThePage.afterThePageFailed(.sizeNotOnThePage) == .failed(.sizeNotOnThePage))
        // The camera starts while the page is read, so its failure counts in every open phase but a failed one.
        #expect(RoomArtPhase.readingThePage.afterTheCameraFailed(.cameraAccessDenied) == .failed(.cameraAccessDenied))
        #expect(RoomArtPhase.preparingTheShirt(title: "Tee").afterTheCameraFailed(.noCamera) == .failed(.noCamera))
        #expect(RoomArtPhase.failed(.sizeNotOnThePage).afterTheCameraFailed(.noCamera) == .failed(.sizeNotOnThePage))
        // A page failure counts only while the page is read.
        #expect(measuring.afterThePageFailed(.pageNotRead) == measuring)
        #expect(RoomArtFailure.cameraAccessDenied.spokenLine == "I need camera access for that. You can turn it on in System Settings.")
        #expect(RoomArtFailure.depthServiceUnavailable.spokenLine == "I couldn't measure your room. Is the depth service running?")
    }
}

struct RoomArtLineTests {
    private func step(
        dictation: Bool = false, thinking: Bool = false, audio: Bool = false, opening: Bool = false,
        presses: Int = 4, pressesAtTheRequest: Int = 4
    ) -> RoomArtLineStep {
        roomArtLineStep(
            dictationIsInProgress: dictation,
            clickyIsThinking: thinking,
            audioIsPlaying: audio,
            roomArtIsOpeningThePanel: opening,
            pushToTalkPressCount: presses,
            pushToTalkPressCountWhenTheRoomArtStarted: pressesAtTheRequest
        )
    }

    @Test func aLineSpeaksWhenNothingElseIsHappening() {
        #expect(step() == .speakNow)
        // The room art's own opening holds the thinking state, so its "no picture" line does not wait on itself.
        #expect(step(thinking: true, opening: true) == .speakNow)
    }

    @Test func aLineWaitsForANewerAnswerInsteadOfCuttingItOff() {
        #expect(step(audio: true) == .waitForQuiet)
        #expect(step(thinking: true) == .waitForQuiet)
        #expect(step(dictation: true) == .waitForQuiet)
    }

    @Test func closingAPanelResetsTheSpeakingStateOnlyWhenItStoppedThePanelsOwnLine() {
        #expect(voiceStateAfterAPanelStoppedItsLine(.responding, theStopReachedThePanelsLine: true) == .idle)
        // The audio playing is another answer, which keeps its state.
        #expect(voiceStateAfterAPanelStoppedItsLine(.responding, theStopReachedThePanelsLine: false) == .responding)
        // A newer request already moved the state on, so the close leaves it alone.
        #expect(voiceStateAfterAPanelStoppedItsLine(.processing, theStopReachedThePanelsLine: true) == .processing)
        #expect(voiceStateAfterAPanelStoppedItsLine(.listening, theStopReachedThePanelsLine: true) == .listening)
    }

    @Test func aLineIsDroppedOnceTheLearnerPressedPushToTalkSinceAsking() {
        #expect(step(presses: 5) == .drop)
        #expect(step(dictation: true, presses: 5) == .drop)
        #expect(step(thinking: true, opening: true, presses: 5) == .drop)
    }

    @Test func aRequestStartsAtThePressThatAskedSoOnlyALaterPressDropsItsLine() {
        var request = RoomArtRequestRecord()
        request.start(atPushToTalkPressCount: 7)
        func lineStep(presses: Int, thinking: Bool = false) -> RoomArtLineStep {
            request.lineStep(dictationIsInProgress: false, clickyIsThinking: thinking, audioIsPlaying: false, pushToTalkPressCount: presses)
        }
        #expect(lineStep(presses: 7) == .speakNow)
        // While the page is read, the request's own thinking state does not hold its line back.
        #expect(lineStep(presses: 7, thinking: true) == .speakNow)
        #expect(lineStep(presses: 8) == .drop)
    }

    @Test func speakingToTheOpenPanelKeepsItsLaterLines() {
        var request = RoomArtRequestRecord()
        request.start(atPushToTalkPressCount: 7)
        // "Right there" is a press, and the panel answers it with "Here it is" seconds later, which must not be dropped.
        request.continued(atPushToTalkPressCount: 8)
        #expect(request.lineStep(dictationIsInProgress: false, clickyIsThinking: false, audioIsPlaying: false, pushToTalkPressCount: 8) == .speakNow)
        #expect(request.lineStep(dictationIsInProgress: false, clickyIsThinking: false, audioIsPlaying: false, pushToTalkPressCount: 9) == .drop)
    }

    @Test func aCancelledRequestLeavesTheOpeningToTheNewerRequest() {
        var request = RoomArtRequestRecord()
        request.start(atPushToTalkPressCount: 2)
        let cancelledRequestOwnsTheVoiceState = request.openingReturned(requestWasCancelled: true)
        #expect(!cancelledRequestOwnsTheVoiceState)
        #expect(request.isOpeningThePanel)
        // Thinking still means the room art's own opening, so a line still speaks over it.
        #expect(request.lineStep(dictationIsInProgress: false, clickyIsThinking: true, audioIsPlaying: false, pushToTalkPressCount: 2) == .speakNow)

        let finishedRequestOwnsTheVoiceState = request.openingReturned(requestWasCancelled: false)
        #expect(finishedRequestOwnsTheVoiceState)
        #expect(!request.isOpeningThePanel)
        // The opening is over, so thinking now is a newer request's, and the line waits for it.
        #expect(request.lineStep(dictationIsInProgress: false, clickyIsThinking: true, audioIsPlaying: false, pushToTalkPressCount: 2) == .waitForQuiet)
    }
}

struct RoomCameraTests {
    @Test func theDebugFlagNamesTheVideoFileThatStandsInForTheCamera() {
        #expect(roomCameraFilePath(launchArguments: ["Clicky", "--room-camera-file", "/tmp/pan.mp4"]) == "/tmp/pan.mp4")
        #expect(roomCameraFilePath(launchArguments: ["Clicky", "--room-camera-file"]) == nil)
        #expect(roomCameraFilePath(launchArguments: ["Clicky"]) == nil)
    }
}
