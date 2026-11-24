//
//  RoomArtPhotoTests.swift
//  leanring-buddyTests
//
//  Save photo's pure rules: when the panel offers it, the file name, the phrase and its route, and the write.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import Clicky

struct RoomArtPhotoTests {
    @Test func onlyAResultIsOfferedForSaving() {
        #expect(RoomArtPhase.showingThePaintedShirt(title: "Pokémon UT").photoTitleToSave == "Pokémon UT")
        // A kept room still shows the items placed before the one that failed.
        #expect(RoomArtPhase.roomKeptAfterAFailedItem(.pageNotRead).photoTitleToSave == "room")
        // A shirt not yet painted, a painting still on its way, a page being read, or a closed panel shows no result yet.
        #expect(RoomArtPhase.readyToPaintTheShirt(title: "Tee").photoTitleToSave == nil)
        #expect(RoomArtPhase.paintingTheShirt(title: "Tee", id: ShirtPaintingID(number: 1)).photoTitleToSave == nil)
        #expect(RoomArtPhase.readingThePage.photoTitleToSave == nil)
        #expect(RoomArtPhase.failed(.pageNotRead).photoTitleToSave == nil)
        #expect(RoomArtPhase.closed.photoTitleToSave == nil)
    }

    private let savedAt = Date(timeIntervalSince1970: 1_795_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    @Test func theFileIsNamedForTheItemAndTheTime() {
        #expect(roomArtPhotoFileName(itemTitle: "Pokémon UT Short Sleeve", savedAt: savedAt, timeZone: utc) == "Clicky try-on Pokémon UT Short Sleeve 2026-11-18 11.06.40.jpg")
        // A slash or a colon would name a folder or break the Finder name, so each becomes a hyphen.
        #expect(roomArtPhotoFileName(itemTitle: "Tee 1/2: Navy", savedAt: savedAt, timeZone: utc) == "Clicky try-on Tee 1-2- Navy 2026-11-18 11.06.40.jpg")
        // A leading dot would hide the file, and a right-to-left override would make its name read backward.
        #expect(roomArtPhotoFileName(itemTitle: "..hidden\u{202E}gpj", savedAt: savedAt, timeZone: utc) == "Clicky try-on hidden-gpj 2026-11-18 11.06.40.jpg")
        // The Arabic letter mark is a bidirectional control too, though no hand-written list held it.
        #expect(roomArtPhotoFileName(itemTitle: "lamp\u{061C}gpj", savedAt: savedAt, timeZone: utc) == "Clicky try-on lamp-gpj 2026-11-18 11.06.40.jpg")
        #expect(roomArtPhotoFileName(itemTitle: "  ", savedAt: savedAt, timeZone: utc) == "Clicky try-on 2026-11-18 11.06.40.jpg")
        // A tab or a line break is a control character, while the zero-width joiner inside an emoji is kept.
        #expect(roomArtPhotoFileName(itemTitle: "Tee\tNavy\nSoft 👩‍💻", savedAt: savedAt, timeZone: utc) == "Clicky try-on Tee-Navy-Soft 👩‍💻 2026-11-18 11.06.40.jpg")
    }

    @Test func aLongTitleIsCutTo150BytesAtACharacterBoundary() {
        // "é" is 2 bytes, so 75 of them fit.
        let accented = roomArtPhotoFileName(itemTitle: String(repeating: "é", count: 120), savedAt: savedAt, timeZone: utc)
        #expect(accented == "Clicky try-on \(String(repeating: "é", count: 75)) 2026-11-18 11.06.40.jpg")
        // A family emoji is one character of 25 bytes, so after the 1 byte "A" 5 fit in 150 and the sixth is left out whole,
        // never split into its people.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.utf8.count == 25 && family.count == 1)
        let emojiTitle = "A" + String(repeating: family, count: 20)
        let emojiName = roomArtPhotoFileName(itemTitle: emojiTitle, savedAt: savedAt, timeZone: utc)
        #expect(emojiName == "Clicky try-on A\(String(repeating: family, count: 5)) 2026-11-18 11.06.40.jpg")
        // With a copy suffix the name stays under the 255 bytes a file name may have.
        #expect(emojiName.utf8.count + " 99".utf8.count <= 255)
        #expect(roomArtPhotoFileName(itemTitle: String(repeating: family, count: 40), savedAt: savedAt, timeZone: utc).utf8.count <= 200)
    }

    @Test func thePhraseIsTheWholeUtteranceAndNeverSaveIt() {
        for phrase in ["save this photo", "Save the photo.", "okay, save this picture please", "Hey Clicky, save that photo for me", "can you save the pic",
                       "Save photo", "save picture", "save pic please", "okay, save photo"] {
            #expect(asksToSaveTheRoomArtPhoto(phrase), "\(phrase)")
        }
        // "Save it" is the Theme Studio's, and a longer request goes to the router.
        for phrase in ["save it", "save", "save the theme", "save this", "photo", "save photo now later", "save my photo", "save this photo of the lamp to my desktop", "how do I save this photo"] {
            #expect(!asksToSaveTheRoomArtPhoto(phrase), "\(phrase)")
        }
    }

    private func context(canSave: Bool, quiz: Bool = false, studio: Bool = false) -> TranscriptRouteContext {
        TranscriptRouteContext(
            themeStudioIsOpen: studio, phaseIsWaitingForAQuizAnswer: quiz, liveSceneIsUpWithNoQuizQuestion: false, sceneIsBuilding: false,
            sceneIsOnScreen: false, brainTakesEveryRequest: false, backgroundSceneIsReady: false, taskAnswerIsReady: false, approvalIsWaiting: false,
            backgroundAgentIsRunning: false, backgroundAgentsArePaused: false, aRoomArtPhotoCanBeSaved: canSave
        )
    }

    @Test func thePhraseRunsAheadOfTheRouterOnlyWhileThereIsSomethingToSave() {
        #expect(transcriptRoute(for: "save this photo", in: context(canSave: true), videoIsInFront: { true }) == .saveTheRoomArtPhoto)
        #expect(transcriptRoute(for: "save this photo", in: context(canSave: false), videoIsInFront: { true }) == .voiceCommandRouter)
        #expect(transcriptRoute(for: "save this photo", in: context(canSave: true, quiz: true), videoIsInFront: { true }) != .saveTheRoomArtPhoto)
        // The Theme Studio card holds every spoken word.
        #expect(transcriptRoute(for: "save this photo", in: context(canSave: true, studio: true), videoIsInFront: { true }) == .voiceCommandRouter)
        #expect(transcriptRoute(for: "save it", in: context(canSave: true), videoIsInFront: { true }) != .saveTheRoomArtPhoto)
        // The button's own label, spoken.
        #expect(transcriptRoute(for: "save photo", in: context(canSave: true), videoIsInFront: { true }) == .saveTheRoomArtPhoto)
        #expect(transcriptRoute(for: "save photo", in: context(canSave: false), videoIsInFront: { true }) == .voiceCommandRouter)
    }

    /// The center pixel's red and blue, 0 to 255, of `image` rendered.
    private func centerRedAndBlue(of image: CIImage) throws -> (red: UInt8, blue: UInt8) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let center = CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 4, bounds: center, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (pixel[0], pixel[2])
    }

    @Test func aSaveDuringThePaintedStillsCrossfadeWritesTheFinishedStill() throws {
        let frameExtent = CGRect(x: 0, y: 0, width: 64, height: 36)
        let frozenPreview = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: frameExtent)
        let paintedStill = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: frameExtent.insetBy(dx: -8, dy: -8))
        // Halfway through the 0.5 s crossfade the panel drew a mix of the two.
        let halfwayFrame = frozenPreview.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: paintedStill, kCIInputTimeKey: 0.5])
            .cropped(to: frameExtent)
        #expect(try centerRedAndBlue(of: halfwayFrame).red > 60)

        let saved = try #require(RoomArtFrameProcessor.imageToSave(lastComposedImage: halfwayFrame, paintedStill: paintedStill))
        let savedColor = try centerRedAndBlue(of: saved)
        #expect(savedColor.red < 5 && savedColor.blue > 250, "\(savedColor)")
        // At the frame's own size, whatever the painted image's extent.
        #expect(saved.extent == frameExtent)
        // With no painted still, the frame as drawn is saved.
        #expect(RoomArtFrameProcessor.imageToSave(lastComposedImage: halfwayFrame, paintedStill: nil)?.extent == frameExtent)
        #expect(RoomArtFrameProcessor.imageToSave(lastComposedImage: nil, paintedStill: nil) == nil)
    }

    @Test func aSaveWritesAJPEGAndNeverReplacesAnEarlierOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-photo-test-\(UUID().uuidString)/Clicky", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let image = try #require(context.makeImage())

        let firstSave = try RoomArtPhotoSaving.save(image, itemTitle: "Tee", savedAt: savedAt, in: folder)
        let secondSave = try RoomArtPhotoSaving.save(image, itemTitle: "Tee", savedAt: savedAt, in: folder)

        #expect(firstSave.lastPathComponent.hasPrefix("Clicky try-on Tee ") && firstSave.pathExtension == "jpg")
        #expect(secondSave.lastPathComponent == firstSave.deletingPathExtension().lastPathComponent + " 2.jpg")
        let source = try #require(CGImageSourceCreateWithURL(firstSave as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
        let savedImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(savedImage.width == 40 && savedImage.height == 20)
    }
}
