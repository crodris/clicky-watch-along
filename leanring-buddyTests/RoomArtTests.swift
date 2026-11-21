//
//  RoomArtTests.swift
//  leanring-buddyTests
//
//  "Show me how this would look in my room": the Worker replies parsed at the boundary, the art's corners from the wall
//  plane, the bare wall spot, the wall's light, the phrase and the tool that ask for it, and the panel's phases.
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

private func artwork(sizeLabel: String = "16x20 in") -> RoomArtwork {
    RoomArtwork(title: "Water Lilies", sizeLabel: sizeLabel, widthMeters: 0.406, heightMeters: 0.508, includesFrame: false, flattenedImage: solidImage(width: 4, height: 5))
}

private let wall = WallPlane(
    center: SIMD3(0, 0, 2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1000,
    principalPoint: SIMD2(640, 360), distanceMeters: 2, wallAngleDegrees: 0, planeInlierShare: 0.9
)

private let goodRoomArtReply = """
{"title": "Water Lilies print", "isWallArt": true,
 "chosenSize": {"label": "16x20 in", "widthCentimeters": 40.6, "heightCentimeters": 50.8, "includesFrame": true},
 "whyThisSize": "The page's size menu shows 16x20 in selected.",
 "otherSizes": [{"label": "8x10 in", "widthCentimeters": 20.3, "heightCentimeters": 25.4}, {"label": "Huge", "widthCentimeters": 5000, "heightCentimeters": 25}],
 "artworkCorners": {"topLeft": {"x": -3, "y": 10}, "topRight": {"x": 390, "y": 12}, "bottomRight": {"x": 392, "y": 505}, "bottomLeft": {"x": 8, "y": 503}}}
"""

private let goodRoomWallReply = """
{"center": [0.1, -0.2, 2.5], "right": [2, 0, 0], "up": [0, -1, 0], "focalPx": 980, "principal": [640, 360],
 "distanceMeters": 2.5, "wallAngleDegrees": 4, "planeInlierShare": 0.91, "inferenceSeconds": 12.1, "seconds": 13.9}
"""

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

    @Test func aReplyThatIsNotWallArtNeedsNoSizeOrCorners() throws {
        let reading = try RoomArtPageReading(responseData: jsonData(#"{"title": "Blue sofa", "isWallArt": false}"#), pictureWidth: 400, pictureHeight: 500)

        #expect(reading == .notWallArt(title: "Blue sofa"))
    }

    @Test(arguments: [
        // No corners.
        #"{"title": "A", "isWallArt": true, "chosenSize": {"label": "S", "widthCentimeters": 20, "heightCentimeters": 30, "includesFrame": false}}"#,
        // No size.
        #"{"title": "A", "isWallArt": true, "artworkCorners": {"topLeft": {"x": 0, "y": 0}, "topRight": {"x": 400, "y": 0}, "bottomRight": {"x": 400, "y": 500}, "bottomLeft": {"x": 0, "y": 500}}}"#,
        // A width of zero.
        #"{"title": "A", "isWallArt": true, "chosenSize": {"label": "S", "widthCentimeters": 0, "heightCentimeters": 30, "includesFrame": false}, "artworkCorners": {"topLeft": {"x": 0, "y": 0}, "topRight": {"x": 400, "y": 0}, "bottomRight": {"x": 400, "y": 500}, "bottomLeft": {"x": 0, "y": 500}}}"#,
        // Corners that enclose a sliver.
        #"{"title": "A", "isWallArt": true, "chosenSize": {"label": "S", "widthCentimeters": 20, "heightCentimeters": 30, "includesFrame": false}, "artworkCorners": {"topLeft": {"x": 0, "y": 0}, "topRight": {"x": 400, "y": 0}, "bottomRight": {"x": 400, "y": 2}, "bottomLeft": {"x": 0, "y": 2}}}"#,
        // An error body.
        #"{"error": "The page has no picture"}"#,
        "not json",
    ])
    func aRoomArtReplyThatCannotHangTheArtIsRefused(replyText: String) {
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

    @Test func aDepthServiceThatIsMissingOrDownAsksWhetherItRuns() {
        #expect(roomArtFailure(forAFailedWallMeasurement: RoomArtWorkerError.workerReturned(statusCode: 503, body: "")) == .depthServiceUnavailable)
        #expect(roomArtFailure(forAFailedWallMeasurement: RoomArtWorkerError.workerReturned(statusCode: 502, body: "")) == .depthServiceUnavailable)
        #expect(roomArtFailure(forAFailedWallMeasurement: RoomArtWorkerError.workerReturned(statusCode: 422, body: "")) == .wallNotMeasured)
        #expect(roomArtFailure(forAFailedWallMeasurement: URLError(.timedOut)) == .wallNotMeasured)
    }

    @Test func thePageTextIsCutToTheWorkersLimitInUTF16Units() {
        let picture = RoomArtPicture(jpegData: Data([1, 2, 3]), width: 10, height: 10)
        // Each emoji is 2 UTF-16 units, so 15,001 of them is 30,002 units and one must go.
        let pageRequest = RoomArtPageRequest(pageURL: "https://shop.example/print", pageTitle: "Print", pageText: String(repeating: "🖼", count: 15_001), picture: picture)

        #expect(pageRequest.pageText.utf16.count == 30_000)
        #expect(pageRequest.json["picture"]?["jpegBase64"]?.stringValue == Data([1, 2, 3]).base64EncodedString())
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
        "try this in my living room",
        "can you hang it on the wall behind me",
        "preview this in my bedroom",
        "put this in my office",
        "I want to see it in my apartment",
    ])
    func aRoomPhraseWithALookOrTryWordAsksForIt(transcript: String) {
        #expect(asksToSeeArtInMyRoom(transcript))
    }

    @Test(arguments: [
        "what's on my wall",
        "clean my room",
        "show me this in 3D",
        "how would this look",
        "my room is a mess",
        "what's the wall made of",
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

struct RoomArtPhaseTests {
    private let firstMeasurement = RoomArtMeasurementID(number: 1)
    private let secondMeasurement = RoomArtMeasurementID(number: 2)

    @Test func theArtShowsOnceThePageAndTheWallAreBothInWhicheverComesFirst() {
        let measuring = RoomArtPhase.closed.opening().startingAMeasurement(id: firstMeasurement)
        let theArt = artwork()

        let wallFirst = measuring.withWallMeasured(wall, measurementID: firstMeasurement)
        #expect(wallFirst == .measuring(id: firstMeasurement, artwork: nil, wall: wall))
        #expect(wallFirst.withArtworkRead(theArt, measurementID: firstMeasurement) == .showing(artwork: theArt, wall: wall))

        let pageFirst = measuring.withArtworkRead(theArt, measurementID: firstMeasurement)
        #expect(pageFirst.statusLine == "Measuring your wall…")
        #expect(pageFirst.withWallMeasured(wall, measurementID: firstMeasurement) == .showing(artwork: theArt, wall: wall))
        #expect(RoomArtPhase.showing(artwork: theArt, wall: wall).statusLine == "On your wall at 16x20 in")
    }

    @Test func aReplyAfterThePanelClosedChangesNothing() {
        let closed = RoomArtPhase.startingCamera.startingAMeasurement(id: firstMeasurement).closing()

        #expect(closed.withWallMeasured(wall, measurementID: firstMeasurement) == .closed)
        #expect(closed.withArtworkRead(artwork(), measurementID: firstMeasurement) == .closed)
        #expect(closed.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .closed)
    }

    @Test func aReplyFromAnEarlierMeasurementChangesNothing() {
        let theArt = artwork()
        // The learner clicked to move the art, which started a second measurement that keeps the art.
        let movingTheArt = RoomArtPhase.showing(artwork: theArt, wall: wall).startingAMeasurement(id: secondMeasurement)
        #expect(movingTheArt == .measuring(id: secondMeasurement, artwork: theArt, wall: nil))

        #expect(movingTheArt.withWallMeasured(wall, measurementID: firstMeasurement) == movingTheArt)
        #expect(movingTheArt.afterTheMeasurementFailed(.wallNotMeasured, measurementID: firstMeasurement) == movingTheArt)
    }

    @Test func aClickDuringAMeasurementOrBeforeTheCameraRunsIsIgnored() {
        let measuring = RoomArtPhase.startingCamera.startingAMeasurement(id: firstMeasurement)

        #expect(measuring.startingAMeasurement(id: secondMeasurement) == measuring)
        #expect(RoomArtPhase.closed.startingAMeasurement(id: firstMeasurement) == .closed)
        #expect(RoomArtPhase.failed(.notWallArt).startingAMeasurement(id: firstMeasurement) == .failed(.notWallArt))
    }

    @Test func aFailureSaysWhatWentWrong() {
        let measuring = RoomArtPhase.startingCamera.startingAMeasurement(id: firstMeasurement)

        #expect(measuring.afterTheMeasurementFailed(.depthServiceUnavailable, measurementID: firstMeasurement) == .failed(.depthServiceUnavailable))
        #expect(RoomArtPhase.startingCamera.afterTheCameraFailed(.cameraAccessDenied) == .failed(.cameraAccessDenied))
        // A camera failure counts only while the camera is starting.
        #expect(measuring.afterTheCameraFailed(.cameraAccessDenied) == measuring)
        #expect(RoomArtFailure.cameraAccessDenied.spokenLine == "I need camera access for that. You can turn it on in System Settings.")
        #expect(RoomArtFailure.depthServiceUnavailable.spokenLine == "I couldn't measure your wall. Is the depth service running?")
        #expect(RoomArtFailure.notWallArt.spokenLine == "That doesn't look like something that hangs on a wall.")
    }
}

struct RoomCameraTests {
    @Test func theDebugFlagNamesTheVideoFileThatStandsInForTheCamera() {
        #expect(roomCameraFilePath(launchArguments: ["Clicky", "--room-camera-file", "/tmp/pan.mp4"]) == "/tmp/pan.mp4")
        #expect(roomCameraFilePath(launchArguments: ["Clicky", "--room-camera-file"]) == nil)
        #expect(roomCameraFilePath(launchArguments: ["Clicky"]) == nil)
    }
}
