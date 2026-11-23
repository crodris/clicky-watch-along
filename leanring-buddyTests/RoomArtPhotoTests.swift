//
//  RoomArtPhotoTests.swift
//  leanring-buddyTests
//
//  Save photo's pure rules: when the panel offers it, the file name, the phrase and its route, and the write.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Clicky

struct RoomArtPhotoTests {
    @Test func onlyAResultIsOfferedForSaving() {
        #expect(RoomArtPhase.showingThePaintedShirt(title: "Pokémon UT", preview: .liveGarment).photoTitleToSave == "Pokémon UT")
        // A kept room still shows the items placed before the one that failed.
        #expect(RoomArtPhase.roomKeptAfterAFailedItem(.pageNotRead).photoTitleToSave == "room")
        // A live preview, a painting still on its way, a page being read, or a closed panel shows no result yet.
        #expect(RoomArtPhase.showingTheShirt(title: "Tee", preview: .liveGarment).photoTitleToSave == nil)
        #expect(RoomArtPhase.paintingTheShirt(title: "Tee", id: ShirtPaintingID(number: 1), preview: .liveGarment).photoTitleToSave == nil)
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
        #expect(roomArtPhotoFileName(itemTitle: "  ", savedAt: savedAt, timeZone: utc) == "Clicky try-on 2026-11-18 11.06.40.jpg")
    }

    @Test func aLongTitleIsCutToSixtyCharacters() {
        let longTitle = String(repeating: "é", count: 80)
        let fileName = roomArtPhotoFileName(itemTitle: longTitle, savedAt: savedAt, timeZone: utc)
        #expect(fileName == "Clicky try-on \(String(repeating: "é", count: 60)) 2026-11-18 11.06.40.jpg")
    }

    @Test func thePhraseIsTheWholeUtteranceAndNeverSaveIt() {
        for phrase in ["save this photo", "Save the photo.", "okay, save this picture please", "Hey Clicky, save that photo for me", "can you save the pic"] {
            #expect(asksToSaveTheRoomArtPhoto(phrase), "\(phrase)")
        }
        // "Save it" is the Theme Studio's, and a longer request goes to the router.
        for phrase in ["save it", "save", "save the theme", "save this photo of the lamp to my desktop", "how do I save this photo"] {
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
