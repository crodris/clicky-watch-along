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
{"kind": "wallArt", "wallArt": {"sizeFoundOnPage": true,
 "size": {"label": "16x20 in", "widthCentimeters": 40.6, "heightCentimeters": 50.8, "includesFrame": true},
 "otherSizes": [{"label": "8x10 in", "widthCentimeters": 20.3, "heightCentimeters": 25.4}, {"label": "Huge", "widthCentimeters": 5000, "heightCentimeters": 25}]}}
"""

private let goodRoomArtReply = tryItReply(item: goodWallArtItem)

private let goodFurnitureItem = """
{"kind": "furniture", "furniture": {"sizeFoundOnPage": true,
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
    #"{"kind": "wallArt", "wallArt": {"sizeFoundOnPage": \#(sizeFound), "size": \#(size), "otherSizes": []}}"#
}

/// The fixture the Worker's tests read too: `POST /try-it-item` responses shaped as the Worker returns them, one for each
/// kind plus wall art and furniture whose page states no size.
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
    case "wall art with a stated size":
        return .wallArt(RoomArtWallArtReading(
            title: "Water Lilies print, framed",
            chosenSize: RoomArtSize(label: "16 x 20 in", widthCentimeters: 40.6, heightCentimeters: 50.8),
            chosenSizeIncludesFrame: true,
            whyThisSize: "The page's size menu shows 16 x 20 in selected.",
            otherSizes: [RoomArtSize(label: "8 x 10 in", widthCentimeters: 20.3, heightCentimeters: 25.4)],
            artworkCorners: pictureCorners(40, 50, 360, 450)
        ))
    case "wall art with no size on the page":
        return .sizeNotOnThePage(title: "Water Lilies print")
    case "furniture only 5 centimeters deep":
        return .furniture(RoomArtFurnitureReading(
            title: "Slim floor mirror",
            chosenSize: RoomArtFurnitureSize(label: "50 x 170 cm", widthCentimeters: 50, heightCentimeters: 170, depthCentimeters: 5),
            whyThisSize: "The page lists one size, 50 x 170 cm.",
            itemCorners: pictureCorners(120, 20, 280, 480)
        ))
    case "furniture with no size on the page":
        return .furniture(RoomArtFurnitureReading(
            title: "Slim floor mirror",
            chosenSize: nil,
            whyThisSize: "The page text states no size.",
            itemCorners: pictureCorners(120, 20, 280, 480)
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
    case "other":
        return .other(title: "Brass lamp")
    default:
        return nil
    }
}

struct RoomArtTryItReplyFixtureTests {
    @Test func everyWorkerReplyInTheSharedFixtureReadsAsItsExpectedReading() throws {
        let fixture = try TryItItemRepliesFixture.load()
        #expect(Set(fixture.cases.map(\.kind)) == ["wallArt", "furniture", "clothing", "other"])

        for fixtureCase in fixture.cases {
            let responseData = try JSONEncoder().encode(fixtureCase.response)
            let reading = try RoomArtPageReading(responseData: responseData, pictureWidth: fixture.picture.width, pictureHeight: fixture.picture.height)

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

    @Test func aFurnitureReplyBecomesItsSizeWithDepthAndCornersClampedIntoThePicture() throws {
        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: goodFurnitureItem, title: "Walnut table")), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .furniture(RoomArtFurnitureReading(
            title: "Walnut table",
            chosenSize: RoomArtFurnitureSize(label: "180 x 90 cm", widthCentimeters: 180, heightCentimeters: 75, depthCentimeters: 90),
            whyThisSize: "The page's size menu shows it selected.",
            itemCorners: RoomArtCorners(topLeft: CGPoint(x: 0, y: 10), topRight: CGPoint(x: 390, y: 12), bottomRight: CGPoint(x: 392, y: 500), bottomLeft: CGPoint(x: 8, y: 500))
        )))
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

    @Test func anOtherReplyNeedsOnlyItsKindAndTitle() throws {
        let reading = try RoomArtPageReading(responseData: jsonData(tryItReply(item: #"{"kind": "other"}"#, title: "Brass lamp")), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .other(title: "Brass lamp"))
    }

    @Test func wallArtWhosePageStatesNoSizeIsReadAsSoAndNeverHung() throws {
        let noSizeReply = goodRoomArtReply.replacingOccurrences(of: #""sizeFoundOnPage": true"#, with: #""sizeFoundOnPage": false"#)

        let reading = try RoomArtPageReading(responseData: jsonData(noSizeReply), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .sizeNotOnThePage(title: "Water Lilies print"))
        #expect(RoomArtFailure.sizeNotOnThePage.spokenLine == "I couldn't find the size on that page.")
    }

    @Test(arguments: [
        // No sizeFoundOnPage, so the reply cannot say whether the size came from the page.
        goodRoomArtReply.replacingOccurrences(of: #""sizeFoundOnPage": true,"#, with: ""),
        // No item.
        #"{"title": "A", "whyThisSize": "", "itemCorners": \#(fullCorners)}"#,
        // No corners.
        #"{"title": "A", "whyThisSize": "", "item": \#(wallArtItem())}"#,
        // A kind this app does not know.
        tryItReply(item: #"{"kind": "wallpaper"}"#, corners: fullCorners),
        // A kind named without its object.
        tryItReply(item: #"{"kind": "wallArt"}"#, corners: fullCorners),
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

private func furniture() -> RoomFurniture {
    RoomFurniture(title: "LACK side table", widthMeters: 0.55, heightMeters: 0.45, cutoutImage: sharedFurnitureImage)
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

private func clothing(garment: RoomArtGarment = .tshirt, photoShows: RoomArtGarmentPhoto = .flatLay) -> RoomArtClothingReading {
    RoomArtClothingReading(title: "Linen shirt", garment: garment, sleeves: .short, chosenSizeLabel: "M", photoShows: photoShows, printDescription: "", whyThisSize: "M is selected.", itemCorners: pictureCorners)
}

struct RoomArtReadingPlanTests {
    @Test func wallArtHangsAndFurnitureWithASizeStandsOnTheFloor() {
        let wallArtReading = RoomArtWallArtReading(
            title: "Print", chosenSize: RoomArtSize(label: "S", widthCentimeters: 20, heightCentimeters: 30), chosenSizeIncludesFrame: false,
            whyThisSize: "Selected.", otherSizes: [], artworkCorners: pictureCorners
        )
        #expect(roomArtReadingPlan(for: .wallArt(wallArtReading)) == .hangOnTheWall(wallArtReading))
        let tableSize = RoomArtFurnitureSize(label: "55x45 cm", widthCentimeters: 55, heightCentimeters: 45, depthCentimeters: 55)
        let table = RoomArtFurnitureReading(title: "LACK", chosenSize: tableSize, whyThisSize: "Only size.", itemCorners: pictureCorners)
        #expect(roomArtReadingPlan(for: .furniture(table)) == .standOnTheFloor(table, size: tableSize))
    }

    @Test func noSizeOnThePageFailsForWallArtAndFurnitureAlike() {
        #expect(roomArtReadingPlan(for: .sizeNotOnThePage(title: "Print")) == .fail(.sizeNotOnThePage))
        let unsizedTable = RoomArtFurnitureReading(title: "LACK", chosenSize: nil, whyThisSize: "No size.", itemCorners: pictureCorners)
        #expect(roomArtReadingPlan(for: .furniture(unsizedTable)) == .fail(.sizeNotOnThePage))
    }

    @Test func onlyATopPhotographedFlatIsTriedOn() {
        for garment in [RoomArtGarment.tshirt, .shirt, .sweater, .hoodie, .jacket] {
            #expect(roomArtReadingPlan(for: .clothing(clothing(garment: garment))) == .tryOnTheShirt(clothing(garment: garment)))
        }
        #expect(roomArtReadingPlan(for: .clothing(clothing(garment: .dress))) == .fail(.onlyTopsSoFar))
        #expect(roomArtReadingPlan(for: .clothing(clothing(garment: .other))) == .fail(.onlyTopsSoFar))
        // A photo on a model would bring the model's body into the cutout.
        #expect(roomArtReadingPlan(for: .clothing(clothing(photoShows: .onModel))) == .fail(.shirtPhotoOnAModel))
        #expect(roomArtReadingPlan(for: .clothing(clothing(photoShows: .onHanger))) == .fail(.shirtPhotoNotFlat))
        #expect(roomArtReadingPlan(for: .clothing(clothing(photoShows: .other))) == .fail(.shirtPhotoNotFlat))
    }

    @Test func anythingElseCannotBeTried() {
        #expect(roomArtReadingPlan(for: .other(title: "Brass lamp")) == .fail(.notSomethingToTry))
        #expect(RoomArtFailure.notSomethingToTry.spokenLine == "That doesn't look like wall art, furniture, or a shirt.")
        #expect(RoomArtFailure.shirtPhotoOnAModel.spokenLine == "I can only try on a shirt from a flat photo of it, and this photo shows it on a model.")
    }
}

struct RoomArtPhaseTests {
    private let firstMeasurement = RoomArtMeasurementID(number: 1)
    private let secondMeasurement = RoomArtMeasurementID(number: 2)

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
        let showing = measuring.withTheSurfaceMeasured(.floor(floor), measurementID: firstMeasurement)
        #expect(showing == .showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil))
        #expect(showing.statusLine == "On your floor, 21.5 inches wide and 17.5 tall")
        #expect(RoomArtPlacedItem.furniture(furniture()).hereItIsLine == "Here it is, 21.5 inches wide and 17.5 tall.")
        #expect(RoomArtPlacedItem.wallArt(artwork()).hereItIsLine == "Here it is at 16 by 20 inches.")
    }

    @Test func aFloorThatIsNotFoundWaitsForAClickAndTheClickMeasuresAgain() {
        let measuring = RoomArtPhase.waitingForTheCamera(.furniture(furniture())).startingAMeasurement(id: firstMeasurement)

        let waitingForAClick = measuring.afterTheMeasurementFailed(.floorNotFound, measurementID: firstMeasurement)
        #expect(waitingForAClick == .waitingForAFloorClick(.furniture(furniture())))
        #expect(waitingForAClick.statusLine == "Tilt the screen down so the floor shows, then click the floor")
        #expect(waitingForAClick.statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(waitingForAClick.aClickPlacesTheItem)
        // A floor that cannot stand the piece means the same as one not found.
        #expect(measuring.withTheSurfaceMeasured(.floor(floorBehindTheCamera), measurementID: firstMeasurement) == waitingForAClick)
        // The click measures again, and a floor found stands the piece on it.
        let measuringAgain = waitingForAClick.startingAMeasurement(id: secondMeasurement)
        #expect(measuringAgain == .measuring(id: secondMeasurement, item: .furniture(furniture())))
        #expect(measuringAgain.withTheSurfaceMeasured(.floor(floor), measurementID: secondMeasurement) == .showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil))
        // Any other failure of the first floor measurement ends the panel.
        #expect(measuring.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .failed(.depthServiceUnavailable))
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
        #expect(!RoomArtPhase.failed(.wallNotMeasured).aClickPlacesTheItem)
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
        // Furniture whose move finds no floor stays on the floor it stood on.
        let movingTheTable = RoomArtPhase.showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil).startingAMeasurement(id: secondMeasurement)
        #expect(movingTheTable.afterTheMeasurementFailed(.floorNotFound, measurementID: secondMeasurement) == .showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: .floorNotFound))
    }

    @Test func aLostSurfaceSaysSoWhileTheItemShowsAndTheSizeLineReturnsWhenFound() {
        let showing = RoomArtPhase.showing(item: .wallArt(artwork()), surface: .wall(wall), moveFailure: nil)

        #expect(showing.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the wall. Turn back, or click the wall to place it again.")
        #expect(showing.statusLine(theSurfaceIsLost: false, shirtCoachingLine: nil) == "On your wall at 16 by 20 inches")
        #expect(!showing.statusLineIsAFailure(theSurfaceIsLost: true))
        let showingTheTable = RoomArtPhase.showing(item: .furniture(furniture()), surface: .floor(floor), moveFailure: nil)
        #expect(showingTheTable.statusLine(theSurfaceIsLost: true, shirtCoachingLine: nil) == "Lost the floor. Turn back, or click the floor to place it again.")
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
        #expect(!showing.aClickPlacesTheItem)
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
        #expect(!measuring.aClickPlacesTheItem)
        #expect(RoomArtPhase.readingThePage.startingAMeasurement(id: firstMeasurement) == .readingThePage)
        #expect(RoomArtPhase.closed.startingAMeasurement(id: firstMeasurement) == .closed)
        #expect(RoomArtPhase.failed(.notSomethingToTry).startingAMeasurement(id: firstMeasurement) == .failed(.notSomethingToTry))
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
}

struct RoomCameraTests {
    @Test func theDebugFlagNamesTheVideoFileThatStandsInForTheCamera() {
        #expect(roomCameraFilePath(launchArguments: ["Clicky", "--room-camera-file", "/tmp/pan.mp4"]) == "/tmp/pan.mp4")
        #expect(roomCameraFilePath(launchArguments: ["Clicky", "--room-camera-file"]) == nil)
        #expect(roomCameraFilePath(launchArguments: ["Clicky"]) == nil)
    }
}
