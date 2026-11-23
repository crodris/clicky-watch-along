//
//  RoomArtGalleryTests.swift
//  leanring-buddyTests
//
//  A store gallery can show the back of a shirt as large as its front, and the largest picture on the page was the back
//  on tentree's Sasquatch Sends It T-Shirt, so the try-on drew a plain back on the learner. Room art now sends the page's
//  other large product photos with the main one, and the page reader says which one shows the garment's front
//  (`RoomArtClothingReading.frontPictureIndex`). These tests cover the page script's gallery, the request, and the reading.
//

import CoreGraphics
import Foundation
import JavaScriptCore
import Testing
@testable import Clicky

/// Runs the media script against a page of images, each `[left, top, width, height]` with a file name, in a viewport 1680
/// by 969, and returns its reply as JSON.
private func mediaScriptReply(images: [(name: String, rect: [Double])]) throws -> [String: Any] {
    let javaScriptContext = try #require(JSContext())
    let imageLiterals = images.map { image in
        let rect = image.rect
        return "fakeImage('https://shop.example/\(image.name).jpg', \(rect[0]), \(rect[1]), \(rect[2]), \(rect[3]))"
    }
    javaScriptContext.evaluateScript("""
    function fakeImage(source, left, top, width, height) {
        return { tagName: 'IMG', complete: true, naturalWidth: 800, currentSrc: source,
            getBoundingClientRect: function () { return { left: left, top: top, width: width, height: height, right: left + width, bottom: top + height }; } };
    }
    var images = [\(imageLiterals.joined(separator: ", "))];
    var document = { querySelectorAll: function () { return images; } };
    var window = { innerWidth: 1680, innerHeight: 969, screenX: 0, screenY: 30, outerWidth: 1680, outerHeight: 1050, devicePixelRatio: 1,
        getComputedStyle: function () { return { visibility: 'visible', opacity: '1', objectFit: 'cover' }; } };
    """)
    let reply = try #require(javaScriptContext.evaluateScript(ChromeVideoTab.largestVisibleMediaJavaScript)?.toString())
    return try #require(try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
}

struct RoomArtGalleryScriptTests {
    @Test func aGalleryWhoseBackIsAsLargeAsItsFrontOffersBothInThePagesOrder() throws {
        // tentree's gallery: the back first and the front beside it, the same size, then a small swatch and a half-size photo.
        let reply = try mediaScriptReply(images: [
            ("back", [100, 100, 500, 600]),
            ("front", [620, 100, 500, 600]),
            ("swatch", [100, 720, 60, 60]),
            ("detail", [1140, 100, 360, 420]),
        ])
        // The first of two equally large photos is the largest, as before.
        #expect(reply["imageFileURL"] as? String == "https://shop.example/back.jpg")
        // Photos under half the largest one's area, such as a swatch, are left out.
        #expect(reply["imageCandidateFileURLs"] as? [String] == ["https://shop.example/back.jpg", "https://shop.example/front.jpg", "https://shop.example/detail.jpg"])
    }

    @Test func theGalleryHoldsAtMostFourPhotosAndEachOnlyOnce() throws {
        let reply = try mediaScriptReply(images: [
            ("one", [0, 0, 300, 300]), ("one", [310, 0, 300, 300]), ("two", [620, 0, 300, 300]),
            ("three", [930, 0, 300, 300]), ("four", [1240, 0, 300, 300]), ("five", [0, 310, 300, 300]),
        ])
        #expect(reply["imageCandidateFileURLs"] as? [String] == ["one", "two", "three", "four"].map { "https://shop.example/\($0).jpg" })
    }

    @Test func theLargestPicturesOtherPhotosLeaveOutItsOwnFile() throws {
        let geometryJSON = """
        {"screenX": 0, "screenY": 0, "outerWidth": 1, "outerHeight": 1, "innerWidth": 1, "innerHeight": 1, "devicePixelRatio": 1,
         "left": 0, "top": 0, "width": 1, "height": 1, "imageSourceURL": null, "imageFileURL": "https://shop.example/back.jpg",
         "imageCandidateFileURLs": ["https://shop.example/back.jpg", "https://shop.example/front.jpg"]}
        """
        let pageGeometry = try JSONDecoder().decode(ChromePageGeometry.self, from: Data(geometryJSON.utf8))
        let media = LargestVisibleMediaInFrontTab(
            screenRect: ScreenRectInChromeCoordinates(rectX: 0, rectY: 0, rectWidth: 1, rectHeight: 1), pageGeometry: pageGeometry, imageSourceURL: nil
        )
        #expect(media.otherImageFileURLs == [URL(string: "https://shop.example/front.jpg")])
    }
}

private func smallPicture(width: Int, height: Int) -> RoomArtPicture {
    RoomArtPicture(jpegData: Data([0xFF, 0xD8, 0xFF]), width: width, height: height)
}

/// A clothing reply from the Worker with the front in `frontPictureIndex` (left out when nil, as an older Worker sends it).
private func clothingReplyData(
    frontPictureIndex: Int?, canBeDrawnOnTheLearner: Bool = true, corners: (left: Double, top: Double, right: Double, bottom: Double)
) throws -> Data {
    var clothing: [String: JSONValue] = [
        "garment": .string("tshirt"), "sleeves": .string("short"), "length": .string("hip"), "canBeDrawnOnTheLearner": .bool(canBeDrawnOnTheLearner), "chosenSizeLabel": .string("M"),
        "photoShows": .string("onModel"), "printDescription": .string("sasquatch on the chest"),
    ]
    if let frontPictureIndex { clothing["frontPictureIndex"] = .number(Double(frontPictureIndex)) }
    func point(_ pixelX: Double, _ pixelY: Double) -> JSONValue { .object(["x": .number(pixelX), "y": .number(pixelY)]) }
    let reply: JSONValue = .object([
        "title": .string("Sasquatch tee"), "whyThisSize": .string("M is selected."),
        "itemCorners": .object([
            "topLeft": point(corners.left, corners.top), "topRight": point(corners.right, corners.top),
            "bottomRight": point(corners.right, corners.bottom), "bottomLeft": point(corners.left, corners.bottom),
        ]),
        "item": .object(["kind": .string("clothing"), "clothing": .object(clothing)]),
    ])
    return try JSONEncoder().encode(reply)
}

struct RoomArtGalleryReadingTests {
    @Test func theRequestSendsAtMostThreeOtherPhotosAndNoneWhenThereAreNone() throws {
        var picture = smallPicture(width: 400, height: 500)
        let single = RoomArtPageRequest(pageURL: "https://shop.example/tee", pageTitle: "Tee", pageText: "", learnerRequest: "", picture: picture)
        guard case .object(let singleFields) = single.json else { Issue.record("the request is not an object"); return }
        #expect(singleFields["otherPictures"] == nil)

        picture.otherPictures = (1...4).map { smallPicture(width: 100 * $0, height: 600) }
        let gallery = RoomArtPageRequest(pageURL: "https://shop.example/tee", pageTitle: "Tee", pageText: "", learnerRequest: "", picture: picture)
        guard case .object(let galleryFields) = gallery.json, case .array(let otherPictures)? = galleryFields["otherPictures"] else {
            Issue.record("the request has no other pictures")
            return
        }
        #expect(otherPictures.count == 3)
        guard case .object(let firstOther) = otherPictures[0] else { Issue.record("an other picture is not an object"); return }
        #expect(firstOther["width"] == .number(100))
    }

    @Test func aGarmentsCornersAreClampedIntoThePictureItsFrontIsIn() throws {
        let reading = try RoomArtPageReading(
            responseData: clothingReplyData(frontPictureIndex: 1, corners: (20, 30, 380, 650)),
            pictureWidth: 400, pictureHeight: 500, otherPictureSizes: [(300, 600)]
        )
        guard case .clothing(let clothing) = reading else { Issue.record("expected clothing, got \(reading)"); return }
        #expect(clothing.frontPictureIndex == 1)
        #expect(clothing.itemCorners.bottomRight == CGPoint(x: 300, y: 600))
    }

    @Test func aFrontPictureThatWasNotSentIsRefused() throws {
        for frontPictureIndex in [-1, 2] {
            #expect(throws: RoomArtReplyError.self) {
                try RoomArtPageReading(
                    responseData: clothingReplyData(frontPictureIndex: frontPictureIndex, corners: (20, 30, 280, 450)),
                    pictureWidth: 400, pictureHeight: 500, otherPictureSizes: [(300, 600)]
                )
            }
        }
    }

    @Test func aGarmentThatCannotBeDrawnOnYouReadsABadFrontPictureAsTheMainPicture() throws {
        let reading = try RoomArtPageReading(
            responseData: clothingReplyData(frontPictureIndex: 5, canBeDrawnOnTheLearner: false, corners: (20, 30, 380, 450)),
            pictureWidth: 400, pictureHeight: 500, otherPictureSizes: [(300, 600)]
        )
        guard case .clothing(let clothing) = reading else { Issue.record("expected clothing, got \(reading)"); return }
        #expect(clothing.frontPictureIndex == 0)
        #expect(!clothing.canBeDrawnOnTheLearner)
    }

    @Test func aReplyFromAnOlderWorkerHasItsFrontInTheMainPicture() throws {
        let reading = try RoomArtPageReading(responseData: clothingReplyData(frontPictureIndex: nil, corners: (20, 30, 380, 450)), pictureWidth: 400, pictureHeight: 500)
        guard case .clothing(let clothing) = reading else { Issue.record("expected clothing, got \(reading)"); return }
        #expect(clothing.frontPictureIndex == 0)
    }
}
