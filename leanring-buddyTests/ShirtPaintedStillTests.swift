//
//  ShirtPaintedStillTests.swift
//  leanring-buddyTests
//
//  The shirt's painted still: the phases and their status lines and loop, the phrases and their route, the mask a painting
//  may draw in on a made-up frame (the whole old top, never the face, neck, hands, or bare arms), the paste that keeps the
//  hands exactly as filmed, what the Worker is sent, and the client against a stubbed Worker.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import Clicky

// MARK: - Phases

struct ShirtPaintedStillPhaseTests {
    private let paintingID = ShirtPaintingID(number: 3)
    private let live = RoomArtPhase.showingTheShirt(title: "Tee", preview: .liveGarment)

    @Test func paintingStartsOnlyFromTheLivePreviewOrAWaitingCapture() {
        #expect(live.armingTheShirtCapture(id: paintingID) == .waitingForTheLearnerToStepBack(title: "Tee", id: paintingID, preview: .liveGarment))
        for otherPhase: RoomArtPhase in [
            .closed, .readingThePage, .preparingTheShirt(title: "Tee"), .waitingToSeeTheLearner(title: "Tee", preview: .liveGarment),
            .paintingTheShirt(title: "Tee", id: ShirtPaintingID(number: 1), preview: .liveGarment), .showingThePaintedShirt(title: "Tee", preview: .liveGarment), .failed(.cannotBeDrawnOnYou),
        ] {
            #expect(otherPhase.armingTheShirtCapture(id: paintingID) == otherPhase)
        }
    }

    @Test func onlyThisPaintingsReplyShowsTheStillOrGoesBackOnAFailure() {
        let painting = RoomArtPhase.paintingTheShirt(title: "Tee", id: paintingID, preview: .liveGarment)
        #expect(painting.withThePaintedShirt(id: paintingID) == .showingThePaintedShirt(title: "Tee", preview: .liveGarment))
        #expect(painting.withThePaintedShirt(id: ShirtPaintingID(number: 2)) == painting)
        #expect(painting.afterThePaintingFailed(id: paintingID) == live)
        #expect(painting.afterThePaintingFailed(id: ShirtPaintingID(number: 2)) == painting)
        // A reply after the learner went back changes nothing.
        #expect(live.withThePaintedShirt(id: paintingID) == live)
        #expect(live.afterThePaintingFailed(id: paintingID) == live)
    }

    @Test func goingBackReturnsToTheLivePreviewFromAPaintingOrTheStill() {
        #expect(RoomArtPhase.paintingTheShirt(title: "Tee", id: paintingID, preview: .liveGarment).backToTheLiveShirt() == live)
        #expect(RoomArtPhase.showingThePaintedShirt(title: "Tee", preview: .liveGarment).backToTheLiveShirt() == live)
        #expect(live.backToTheLiveShirt() == live)
        #expect(RoomArtPhase.closed.backToTheLiveShirt() == .closed)
    }

    @Test func theStatusLinesSayWhatIsHappeningAndIgnoreCoaching() {
        let painting = RoomArtPhase.paintingTheShirt(title: "Tee", id: paintingID, preview: .liveGarment)
        let still = RoomArtPhase.showingThePaintedShirt(title: "Tee", preview: .liveGarment)
        #expect(painting.statusLine(theSurfaceIsLost: false, shirtCoachingLine: "Stand back") == "Putting it on you…")
        #expect(still.statusLine(theSurfaceIsLost: false, shirtCoachingLine: "Stand back") == "On you · say go back for the live view")
        #expect(!painting.statusLineIsAFailure(theSurfaceIsLost: false) && !still.statusLineIsAFailure(theSurfaceIsLost: false))
        #expect(!painting.theItemIsPlacedByClicking && !still.theItemIsPlacedByClicking)
    }

    @Test func theLoopTracesTheTorsoWhilePaintingAndFadesWhenTheStillShows() {
        let drawing = RoomArtLoopState.hidden.after(phaseChangedTo: .paintingTheShirt(title: "Tee", id: paintingID, preview: .liveGarment), at: 10)
        #expect(drawing == .drawing(beganAt: 10))
        #expect(drawing.after(phaseChangedTo: .showingThePaintedShirt(title: "Tee", preview: .liveGarment), at: 20) == .fadingOut(beganAt: 10, tracesTheLine: true))
        // A failed or abandoned painting fades it too, as the live preview showing does.
        #expect(drawing.after(phaseChangedTo: live, at: 20) == .fadingOut(beganAt: 10, tracesTheLine: true))
    }

    @Test func aLineAfterTheLearnersRightThereIsStillTheirs() {
        var request = RoomArtRequestRecord()
        request.start(atPushToTalkPressCount: 4)
        _ = request.openingReturned(requestWasCancelled: false)
        let step = { (presses: Int) in request.lineStep(dictationIsInProgress: false, clickyIsThinking: false, audioIsPlaying: false, pushToTalkPressCount: presses) }
        #expect(step(5) == .drop)
        request.continued(atPushToTalkPressCount: 5)
        #expect(step(5) == .speakNow)
        #expect(!request.isOpeningThePanel)
    }
}

// MARK: - The voice

struct ShirtPaintedStillVoiceTests {
    @Test func thePaintPhrasesAsTheWholeUtterance() {
        for transcript in ["Right there.", "okay, right there please", "That's good", "that’s good", "take it", "Paint it.", "paint it on me", "yeah put it on me", "Perfect, right here"] {
            #expect(shirtStillVoiceRequest(for: transcript) == .paintIt, "\(transcript)")
        }
    }

    @Test func theBackPhrasesAsTheWholeUtterance() {
        for transcript in ["Go back.", "back to live", "Go back to live, please", "go live", "show me live"] {
            #expect(shirtStillVoiceRequest(for: transcript) == .backToLive, "\(transcript)")
        }
    }

    @Test func longerRequestsGoToTheRouter() {
        for transcript in ["right there is a window", "go back to the last video", "take it off", "paint it blue", "what's right there", "is that good", ""] {
            #expect(shirtStillVoiceRequest(for: transcript) == nil, "\(transcript)")
        }
    }

    @Test func eachPhraseRunsAheadOfTheRouterOnlyWhenThePanelCanTakeIt() {
        func runs(_ request: ShirtStillVoiceRequest?, _ targets: ShirtStillVoiceTargets, quiz: Bool = false, studio: Bool = false) -> Bool {
            shirtStillPhraseRunsAheadOfTheRouter(request: request, targets: targets, quizQuestionIsOpen: quiz, themeStudioIsOpen: studio)
        }
        #expect(runs(.paintIt, .livePreview))
        #expect(runs(.backToLive, .paintedStill))
        // While the capture waits for the learner to step back, "right there" restarts it and "go back" cancels it.
        #expect(runs(.paintIt, .stepBack) && runs(.backToLive, .stepBack))
        #expect(!runs(.paintIt, .stepBack, quiz: true))
        #expect(!runs(.paintIt, .paintedStill))
        #expect(!runs(.backToLive, .livePreview))
        #expect(!runs(.paintIt, .none) && !runs(.backToLive, .none))
        #expect(!runs(nil, .livePreview))
        #expect(!runs(.paintIt, .livePreview, quiz: true))
        #expect(!runs(.paintIt, .livePreview, studio: true))
    }

    private func context(_ targets: ShirtStillVoiceTargets) -> TranscriptRouteContext {
        TranscriptRouteContext(
            themeStudioIsOpen: false, phaseIsWaitingForAQuizAnswer: false, liveSceneIsUpWithNoQuizQuestion: false, sceneIsBuilding: false,
            sceneIsOnScreen: false, brainTakesEveryRequest: false, backgroundSceneIsReady: false, taskAnswerIsReady: false, approvalIsWaiting: false,
            backgroundAgentIsRunning: false, backgroundAgentsArePaused: false, shirtStillVoiceTargets: targets
        )
    }

    @Test func theRouteTakesThePhrasesAheadOfTheRouterWhileTheShirtShows() {
        #expect(transcriptRoute(for: "right there", in: context(.livePreview), videoIsInFront: { true }) == .shirtPaintedStill(.paintIt))
        #expect(transcriptRoute(for: "go back", in: context(.paintedStill), videoIsInFront: { true }) == .shirtPaintedStill(.backToLive))
        #expect(transcriptRoute(for: "right there", in: context(.stepBack), videoIsInFront: { true }) == .shirtPaintedStill(.paintIt))
        #expect(transcriptRoute(for: "go back", in: context(.stepBack), videoIsInFront: { true }) == .shirtPaintedStill(.backToLive))
        // With no shirt, "right there" and "go back" reach the router or the keyword path as before.
        #expect(transcriptRoute(for: "right there", in: context(.none), videoIsInFront: { true }) == .voiceCommandRouter)
        #expect(transcriptRoute(for: "go back", in: context(.livePreview), videoIsInFront: { false }) == .keywordPath)
    }
}

// MARK: - The mask

/// A made-up 320 by 240 frame: a person in an oversized navy top, wider and longer than the new top and with sleeve stubs,
/// a white print on its chest, a bare head, neck, arms, and hands, and gray shorts, against a gray wall.
private struct MadeUpPerson {
    static let width = 320, height = 240
    static let torso = BodyTorso(
        imageLeftShoulder: CGPoint(x: 120, y: 80), imageRightShoulder: CGPoint(x: 200, y: 80),
        imageLeftHip: CGPoint(x: 125, y: 190), imageRightHip: CGPoint(x: 195, y: 190),
        hipsWereEstimated: false, shouldersAreSeen: true,
        imageLeftElbow: CGPoint(x: 82, y: 140), imageRightElbow: CGPoint(x: 238, y: 140)
    )
    static let faceBox = CGRect(x: 140, y: 12, width: 40, height: 44)
    static let leftHand = [CGPoint(x: 76, y: 204), CGPoint(x: 88, y: 204), CGPoint(x: 82, y: 213)]
    static let rightHand = [CGPoint(x: 232, y: 204), CGPoint(x: 244, y: 204), CGPoint(x: 238, y: 213)]

    enum Region { case wall, skin, oldTop, print, shorts }

    static func region(column: Int, row: Int) -> Region {
        let columnPosition = Double(column), rowPosition = Double(row)
        if pow((columnPosition - 160) / 22, 2) + pow((rowPosition - 35) / 25, 2) < 1 { return .skin }
        if (148..<172).contains(column), (55..<74).contains(row) { return .skin }
        if (140..<180).contains(column), (100..<130).contains(row) { return .print }
        if (90..<230).contains(column), (72..<215).contains(row) { return .oldTop }
        if (68..<95).contains(column) || (225..<252).contains(column), (75..<125).contains(row) { return .oldTop }
        if (72..<92).contains(column) || (228..<248).contains(column), (125..<216).contains(row) { return .skin }
        if (100..<220).contains(column), (215..<240).contains(row) { return .shorts }
        return .wall
    }

    /// The same torso with each wrist, at the top of the hand, so a long sleeve has a forearm to follow.
    static let torsoWithWrists = BodyTorso(
        imageLeftShoulder: torso.imageLeftShoulder, imageRightShoulder: torso.imageRightShoulder, imageLeftHip: torso.imageLeftHip, imageRightHip: torso.imageRightHip,
        hipsWereEstimated: false, shouldersAreSeen: true, imageLeftElbow: torso.imageLeftElbow, imageRightElbow: torso.imageRightElbow,
        imageLeftWrist: CGPoint(x: 82, y: 203), imageRightWrist: CGPoint(x: 238, y: 203)
    )

    /// A bare forearm lying across the belly, over the old top and away from both sleeves.
    static func isTheBellyForearm(column: Int, row: Int) -> Bool { (135..<185).contains(column) && (150..<162).contains(row) }

    /// `previewCoversTheTorso` false leaves the preview's garment coverage empty, as a ghost outline does, so only the new
    /// garment's own area (`ShirtCoverage`) decides what the painting may cover.
    static func frame(
        oldTopColor: (UInt8, UInt8, UInt8) = (30, 40, 80), hasABeard: Bool = false, torso: BodyTorso = torso,
        hasABareForearmAcrossTheBelly: Bool = false, previewCoversTheTorso: Bool = true
    ) -> ShirtFrozenFrame {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var person = [UInt8](repeating: 0, count: width * height)
        var coverage = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let index = row * width + column
                let color: (UInt8, UInt8, UInt8)
                switch hasABareForearmAcrossTheBelly && isTheBellyForearm(column: column, row: row) ? Region.skin : region(column: column, row: row) {
                case .wall: color = (150, 150, 150)
                case .skin: color = (200, 150, 120)
                case .oldTop: color = oldTopColor
                case .print: color = (240, 240, 240)
                case .shorts: color = (70, 70, 70)
                }
                // A dark beard down the front of the neck, which is not skin, just above the collar.
                let colorHere = hasABeard && (150..<170).contains(column) && (60..<71).contains(row) ? (25, 25, 25) : color
                rgba[index * 4] = colorHere.0; rgba[index * 4 + 1] = colorHere.1; rgba[index * 4 + 2] = colorHere.2
                if region(column: column, row: row) != .wall { person[index] = 255 }
                // The new top is narrower and shorter than the old one, with no sleeves past the torso.
                if previewCoversTheTorso, (110..<210).contains(column), (76..<196).contains(row) { coverage[index] = 255 }
            }
        }
        let image = rgbImage(bytes: rgba, width: width, height: height)!
        return ShirtFrozenFrame(cameraImage: image, previewImage: image, personMask: person, previewGarmentCoverage: coverage, torso: torso)
    }

    static var bodyParts: ShirtPaintBodyParts {
        ShirtPaintBodyParts(faceBoxes: [faceBox], hands: [leftHand, rightHand])
    }
}

// The mask and the paste spend seconds of CPU per test, so they run in the CPU-heavy lane.
extension CPUHeavyTests {
    struct ShirtPaintMaskTests {
        /// What the made-up frame's new top covers by default: a short-sleeved top to the hip.
        private let shortTopToTheHip = ShirtCoverage(sleeves: .short, length: .hip)
        private let masks = ShirtPaintMask.make(frame: MadeUpPerson.frame(), bodyParts: MadeUpPerson.bodyParts, coverage: ShirtCoverage(sleeves: .short, length: .hip))

        private func paintable(_ column: Int, _ row: Int) -> Bool { (masks?.paintable[row * MadeUpPerson.width + column] ?? 0) > 127 }
        private func protectedWeight(_ column: Int, _ row: Int) -> UInt8 { masks?.protected[row * MadeUpPerson.width + column] ?? 0 }

        @Test func theMaskCoversTheWholeOldTopPastTheNewOne() throws {
            let masks = try #require(masks)
            #expect(masks.width == MadeUpPerson.width && masks.height == MadeUpPerson.height)
            // Where the new top lands.
            #expect(paintable(160, 150))
            // The old top's hem below where the new one ends, and its sides past the new one's.
            #expect(paintable(160, 208))
            #expect(paintable(96, 150) && paintable(224, 150))
            // Its sleeve stubs, past the torso.
            #expect(paintable(74, 100) && paintable(246, 100))
            // The old top's print, whose colors are not the old top's, is a hole the mask fills.
            #expect(paintable(160, 115))
            // Every pixel of the old top is in it.
            var oldTopPixels = 0, oldTopPixelsLeftOut = 0
            for row in 0..<MadeUpPerson.height {
                for column in 0..<MadeUpPerson.width where MadeUpPerson.region(column: column, row: row) == .oldTop || MadeUpPerson.region(column: column, row: row) == .print {
                    oldTopPixels += 1
                    if !paintable(column, row) { oldTopPixelsLeftOut += 1 }
                }
            }
            // The collar band next to the neck is left to the neck cut, so a few pixels at the top stay out.
            #expect(Double(oldTopPixelsLeftOut) / Double(oldTopPixels) < 0.01, "\(oldTopPixelsLeftOut) of \(oldTopPixels) old top pixels left out")
        }

        @Test func theMaskNeverTouchesTheFaceNeckHandsBareArmsOrTheRoom() throws {
            _ = try #require(masks)
            #expect(!paintable(160, 35))
            #expect(!paintable(160, 62))
            #expect(!paintable(82, 208) && !paintable(238, 208))
            #expect(!paintable(82, 170) && !paintable(238, 170))
            #expect(!paintable(20, 20) && !paintable(300, 150) && !paintable(160, 232))
        }

        @Test func theHandsTheFaceAndTheNeckAreProtectedFromThePaste() throws {
            _ = try #require(masks)
            #expect(protectedWeight(82, 208) == 255 && protectedWeight(238, 208) == 255)
            #expect(protectedWeight(160, 35) == 255)
            #expect(protectedWeight(160, 62) == 255)
            #expect(protectedWeight(160, 150) == 0)
        }

        @Test func longSleevesPaintTheBareForearmsAndShortSleevesLeaveThemAsFilmed() throws {
            let frame = MadeUpPerson.frame(torso: MadeUpPerson.torsoWithWrists)
            // With short sleeves the forearms are bare skin the new top does not cover, so they stay as filmed.
            let shortSleeves = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: shortTopToTheHip))
            #expect(shortSleeves.paintable[170 * MadeUpPerson.width + 82] == 0 && shortSleeves.paintable[170 * MadeUpPerson.width + 238] == 0)

            // With long sleeves the forearms are covered, from the elbow down to the wrist.
            let longSleeves = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: ShirtCoverage(sleeves: .long, length: .hip)))
            func paintsLong(_ column: Int, _ row: Int) -> Bool { longSleeves.paintable[row * MadeUpPerson.width + column] > 127 }
            #expect(paintsLong(82, 150) && paintsLong(82, 175) && paintsLong(82, 195))
            #expect(paintsLong(238, 150) && paintsLong(238, 175) && paintsLong(238, 195))
            // The hands stay out of the painting and are put back exactly as filmed, and so do the face and the neck.
            #expect(!paintsLong(82, 208) && !paintsLong(238, 208))
            #expect(longSleeves.protected[208 * MadeUpPerson.width + 82] == 255 && longSleeves.protected[208 * MadeUpPerson.width + 238] == 255)
            #expect(!paintsLong(160, 35) && !paintsLong(160, 62))
            #expect(longSleeves.protected[35 * MadeUpPerson.width + 160] == 255 && longSleeves.protected[62 * MadeUpPerson.width + 160] == 255)
            // The room beside the arm stays the room.
            #expect(!paintsLong(20, 170) && !paintsLong(300, 170))
        }

        @Test func aBareForearmAcrossTheBellyStaysAsFilmedWhateverTheSleevesAndForearmsUnderLongSleevesArePainted() throws {
            // A ghost outline preview (no preview coverage), so only the new garment's own area is in play.
            let frame = MadeUpPerson.frame(torso: MadeUpPerson.torsoWithWrists, hasABareForearmAcrossTheBelly: true, previewCoversTheTorso: false)
            func paints(_ masks: ShirtPaintMasks, _ column: Int, _ row: Int) -> Bool { masks.paintable[row * MadeUpPerson.width + column] > 127 }
            let short = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: shortTopToTheHip))
            let long = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: ShirtCoverage(sleeves: .long, length: .hip)))
            for masks in [short, long] {
                // The forearm across the belly is inside the new garment's torso, which does not cover it, so it stays as filmed,
                // while the old top around it is painted.
                #expect(!paints(masks, 160, 156) && !paints(masks, 140, 152))
                #expect(paints(masks, 160, 175) && paints(masks, 160, 140))
            }
            // Under short sleeves the hanging forearms stay as filmed, and under long sleeves they are painted.
            #expect(!paints(short, 82, 175) && !paints(short, 238, 175))
            #expect(paints(long, 82, 175) && paints(long, 238, 175))
        }

        @Test func aLongerHemPaintsTheLegsItCoversAndNothingPastThePerson() throws {
            let frame = MadeUpPerson.frame()
            let hip = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: shortTopToTheHip))
            let knee = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: ShirtCoverage(sleeves: .short, length: .knee)))
            // The gray shorts below the old top's hem are the learner's own at the hip, and under a coat that reaches the knee
            // they are covered.
            #expect(hip.paintable[232 * MadeUpPerson.width + 160] == 0)
            #expect(knee.paintable[232 * MadeUpPerson.width + 160] == 255)
            // The wall beside them, outside the person, is never painted.
            #expect(knee.paintable[232 * MadeUpPerson.width + 20] == 0 && knee.paintable[232 * MadeUpPerson.width + 300] == 0)
        }

        @Test func theNecksSkinIsFoundAtTheFramesOwnSizeAndNeverPainted() throws {
            let neckSkin = ShirtPaintMask.neckSkinRegion(frame: MadeUpPerson.frame())
            // The neck's skin down to the collar, and nothing of the old top, the face beside it, or the room.
            #expect(neckSkin[70 * MadeUpPerson.width + 160] && neckSkin[60 * MadeUpPerson.width + 152])
            #expect(!neckSkin[80 * MadeUpPerson.width + 160] && !neckSkin[150 * MadeUpPerson.width + 160] && !neckSkin[20 * MadeUpPerson.width + 20])
            _ = try #require(masks)
            #expect(!paintable(160, 70) && protectedWeight(160, 70) == 255)
        }

        @Test func aHandRestingOnTheOldTopIsNeverPainted() throws {
            var bodyParts = MadeUpPerson.bodyParts
            let handOnTheShirt = [CGPoint(x: 124, y: 168), CGPoint(x: 136, y: 168), CGPoint(x: 130, y: 180)]
            bodyParts.hands.append(handOnTheShirt)
            let masks = try #require(ShirtPaintMask.make(frame: MadeUpPerson.frame(), bodyParts: bodyParts, coverage: shortTopToTheHip))
            // The old top under the hand would be painted, so the hand is what keeps it out, and the paste keeps it as filmed.
            #expect(masks.paintable[174 * MadeUpPerson.width + 130] == 0)
            #expect(masks.protected[174 * MadeUpPerson.width + 130] == 255)
            #expect(masks.paintable[174 * MadeUpPerson.width + 160] == 255)
        }

        @Test func aBeardJustAboveTheCollarIsKeptFromThePaste() throws {
            // A beard is not skin, so the neck cut is what makes the paste put it back, inside the 24 pixels it grows the mask by.
            let masks = try #require(ShirtPaintMask.make(frame: MadeUpPerson.frame(hasABeard: true), bodyParts: MadeUpPerson.bodyParts, coverage: shortTopToTheHip))
            #expect(masks.protected[69 * MadeUpPerson.width + 160] == 255)
            #expect(masks.paintable[69 * MadeUpPerson.width + 160] == 0)
        }

        @Test func anOldTopTheColorOfSkinIsStillPainted() throws {
            // A beige old top passes the skin rule, so only being the old top keeps its sleeve stubs in the mask.
            #expect(ShirtPaintMask.looksLikeSkin(red: 205, green: 165, blue: 130))
            let masks = try #require(ShirtPaintMask.make(frame: MadeUpPerson.frame(oldTopColor: (205, 165, 130)), bodyParts: MadeUpPerson.bodyParts, coverage: shortTopToTheHip))
            #expect(masks.paintable[100 * MadeUpPerson.width + 74] == 255 && masks.paintable[100 * MadeUpPerson.width + 246] == 255)
        }

        @Test func noMaskWhenTheOldTopCannotBeRead() {
            let frame = MadeUpPerson.frame()
            let nobody = ShirtFrozenFrame(
                cameraImage: frame.cameraImage, previewImage: frame.previewImage,
                personMask: [UInt8](repeating: 0, count: frame.personMask.count), previewGarmentCoverage: [UInt8](repeating: 0, count: frame.personMask.count),
                torso: BodyTorso(imageLeftShoulder: CGPoint(x: 400, y: 400), imageRightShoulder: CGPoint(x: 401, y: 400), imageLeftHip: CGPoint(x: 400, y: 401), imageRightHip: CGPoint(x: 401, y: 401), hipsWereEstimated: true, shouldersAreSeen: false)
            )
            #expect(ShirtPaintMask.make(frame: nobody, bodyParts: ShirtPaintBodyParts(), coverage: shortTopToTheHip) == nil)
        }

        @Test func theSkinRuleKeepsSkinAndLeavesShirtsAndWalls() {
            #expect(ShirtPaintMask.looksLikeSkin(red: 200, green: 150, blue: 120))
            #expect(ShirtPaintMask.looksLikeSkin(red: 120, green: 80, blue: 60))
            #expect(!ShirtPaintMask.looksLikeSkin(red: 30, green: 40, blue: 80))
            #expect(!ShirtPaintMask.looksLikeSkin(red: 150, green: 150, blue: 150))
            #expect(!ShirtPaintMask.looksLikeSkin(red: 250, green: 250, blue: 250))
        }

        @Test func theMorphologyFillsHolesAndDropsSpecks() {
            let width = 9, height = 9
            var ring = [Bool](repeating: false, count: width * height)
            for row in 2...6 { for column in 2...6 where row == 2 || row == 6 || column == 2 || column == 6 { ring[row * width + column] = true } }
            let filled = ShirtPaintMask.withTheHolesFilled(ring, width: width, height: height)
            #expect(filled[4 * width + 4] && !filled[0])
            var speck = [Bool](repeating: false, count: width * height)
            speck[0] = true
            #expect(!ShirtPaintMask.withoutSmallPieces(speck, width: width, height: height, smallestPieceSize: 2).contains(true))
            #expect(ShirtPaintMask.withoutSmallPieces(filled, width: width, height: height, smallestPieceSize: 2)[4 * width + 4])
            let grown = ShirtPaintMask.dilated(speck, width: width, height: height, radius: 1)
            #expect(grown[1] && grown[width] && grown[width + 1] && !grown[2])
            #expect(ShirtPaintMask.eroded(grown, width: width, height: height, radius: 1)[0])
            #expect(!ShirtPaintMask.eroded(grown, width: width, height: height, radius: 1)[width + 1])
            let feathered = ShirtPaintMask.feathered(speck, width: width, height: height, featherPixels: 3)
            #expect(feathered[0] == 255 && feathered[1] < 255 && feathered[1] > feathered[2] && feathered[4] == 0)
        }
    }

    // MARK: - The paste

    struct ShirtPaintedStillPasteTests {
        private func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8, width: Int, height: Int) -> CGImage {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for index in 0..<(width * height) { bytes[index * 4] = red; bytes[index * 4 + 1] = green; bytes[index * 4 + 2] = blue }
            return rgbImage(bytes: bytes, width: width, height: height)!
        }

        @Test func theProtectedRegionsStayExactlyAsFilmedInsideThePastesGrowth() throws {
            let width = 160, height = 100
            let keyframe = solid(128, 128, 128, width: width, height: height)
            let painted = solid(220, 30, 30, width: width, height: height)
            var paintable = [UInt8](repeating: 0, count: width * height)
            var protectedRegion = [Bool](repeating: false, count: width * height)
            for row in 20..<70 { for column in 30..<90 { paintable[row * width + column] = 255 } }
            // A hand right beside the mask, inside the 24 pixels the paste grows it by.
            for row in 35..<50 { for column in 94..<104 { protectedRegion[row * width + column] = true } }
            let masks = ShirtPaintMasks(
                width: width, height: height, paintable: paintable,
                protected: ShirtPaintMask.feathered(protectedRegion, width: width, height: height, featherPixels: 3),
                oldShirt: paintable
            )

            let pasted = try #require(shirtPaintedStillPasted(keyframe: keyframe, painted: painted, masks: masks, context: CIContext()))
            let pixels = try #require(rgbaBytes(of: pasted, width: width, height: height))
            func color(_ column: Int, _ row: Int) -> [UInt8] { Array(pixels[(row * width + column) * 4..<(row * width + column) * 4 + 3]) }

            #expect(color(60, 45) == [220, 30, 30])
            // Every pixel of the hand is the frame's own.
            for row in 35..<50 { for column in 94..<104 { #expect(color(column, row) == [128, 128, 128]) } }
            // Without the protection, the paste's growth would have painted it.
            let maskImage = try #require(grayImage(bytes: paintable, width: width, height: height))
            let unprotected = try #require(furnitureCompositePasted(keyframe: keyframe, generated: painted, mask: maskImage, keepsOnlyThePieceTheReplyChanged: false, context: CIContext()))
            let unprotectedPixels = try #require(rgbaBytes(of: unprotected, width: width, height: height))
            #expect(unprotectedPixels[(40 * width + 96) * 4] != 128)
            // Past the growth, the frame is untouched.
            #expect(color(150, 90) == [128, 128, 128])
        }

        @Test func aPaintingCloseToTheOldTopsColorStillReplacesIt() throws {
            // The furniture's paste keeps the filmed pixels where its reply changed less than 14 levels. The shirt's must not,
            // or an old top close to the new one's color would show through.
            let width = 160, height = 100
            let keyframe = solid(128, 128, 128, width: width, height: height)
            let painted = solid(134, 134, 134, width: width, height: height)
            var paintable = [UInt8](repeating: 0, count: width * height)
            for row in 20..<70 { for column in 30..<90 { paintable[row * width + column] = 255 } }
            let masks = ShirtPaintMasks(width: width, height: height, paintable: paintable, protected: [UInt8](repeating: 0, count: width * height), oldShirt: paintable)

            let pasted = try #require(shirtPaintedStillPasted(keyframe: keyframe, painted: painted, masks: masks, context: CIContext()))
            let pixels = try #require(rgbaBytes(of: pasted, width: width, height: height))
            #expect(Array(pixels[(45 * width + 60) * 4..<(45 * width + 60) * 4 + 3]) == [134, 134, 134])
        }

        @Test func aForearmALongSleeveCoversTakesThePaintingWhileTheHandIsPutBackAsFilmed() throws {
            let frame = MadeUpPerson.frame(torso: MadeUpPerson.torsoWithWrists)
            let masks = try #require(ShirtPaintMask.make(frame: frame, bodyParts: MadeUpPerson.bodyParts, coverage: ShirtCoverage(sleeves: .long, length: .hip)))
            let painted = solid(220, 30, 30, width: MadeUpPerson.width, height: MadeUpPerson.height)

            let pasted = try #require(shirtPaintedStillPasted(keyframe: frame.cameraImage, painted: painted, masks: masks, context: CIContext()))
            let pastedPixels = try #require(rgbaBytes(of: pasted, width: MadeUpPerson.width, height: MadeUpPerson.height))
            let filmedPixels = try #require(rgbaBytes(of: frame.cameraImage, width: MadeUpPerson.width, height: MadeUpPerson.height))
            func pastedColor(_ column: Int, _ row: Int) -> [UInt8] { Array(pastedPixels[(row * MadeUpPerson.width + column) * 4..<(row * MadeUpPerson.width + column) * 4 + 3]) }
            func filmedColor(_ column: Int, _ row: Int) -> [UInt8] { Array(filmedPixels[(row * MadeUpPerson.width + column) * 4..<(row * MadeUpPerson.width + column) * 4 + 3]) }

            // The bare forearms (skin, 200 150 120 as filmed) now carry the painting, not the filmed skin.
            for forearm in [(82, 170), (238, 170)] {
                #expect(filmedColor(forearm.0, forearm.1) == [200, 150, 120])
                let color = pastedColor(forearm.0, forearm.1)
                #expect(color[0] > 150 && color[1] < 90, "the forearm at \(forearm) pasted as \(color)")
            }
            // The hands are exactly as filmed.
            for handPixel in [(82, 208), (238, 208)] {
                #expect(pastedColor(handPixel.0, handPixel.1) == filmedColor(handPixel.0, handPixel.1))
            }
        }

        @Test func masksOfAnotherSizeAreRefused() {
            let keyframe = solid(1, 2, 3, width: 10, height: 10)
            let masks = ShirtPaintMasks(width: 9, height: 10, paintable: [], protected: [], oldShirt: [])
            #expect(shirtPaintedStillPasted(keyframe: keyframe, painted: keyframe, masks: masks, context: CIContext()) == nil)
        }
    }
}

// MARK: - What the Worker is sent

private func paintingRequest(width: Int = 64, height: Int = 36, printDescription: String = "a line drawing", title: String = "Ringer tee") -> ShirtPaintingRequest {
    var bytes = [UInt8](repeating: 200, count: width * height * 4)
    for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
    let keyframe = rgbImage(bytes: bytes, width: width, height: height)!
    var paintable = [UInt8](repeating: 0, count: width * height)
    for index in (width * 10)..<(width * 20) { paintable[index] = 255 }
    return ShirtPaintingRequest(
        keyframe: keyframe,
        productJPEG: jpegData(of: keyframe)!,
        masks: ShirtPaintMasks(width: width, height: height, paintable: paintable, protected: [UInt8](repeating: 0, count: width * height), oldShirt: paintable),
        itemTitle: title,
        garment: ShirtPaintingGarment(kind: .tshirt, sleeves: .short, length: .hip, baseColorHex: "#E9E1CF", printDescription: printDescription)
    )
}

struct ShirtPaintingRequestTests {
    @Test func theBodyIsTheShirtKindWithTheGarmentsOwnWords() throws {
        let body = try #require(shirtPaintingRequestBody(paintingRequest()))
        #expect(body["kind"] as? String == "shirt")
        #expect(body["keyframeWidth"] as? Int == 64 && body["keyframeHeight"] as? Int == 36)
        #expect(body["itemTitle"] as? String == "Ringer tee")
        #expect(body["itemSizeWords"] == nil)
        let garment = try #require(body["garment"] as? [String: String])
        #expect(garment == ["kind": "tshirt", "sleeves": "short", "length": "hip", "baseColorHex": "#E9E1CF", "printDescription": "a line drawing"])
        // The mask is an 8-bit gray PNG the frame's size, white where the painting may draw.
        let maskBase64 = try #require(body["maskPNGBase64"] as? String)
        let maskData = try #require(Data(base64Encoded: maskBase64))
        let mask = try #require(decodedImage(from: maskData))
        #expect(mask.width == 64 && mask.height == 36 && mask.bitsPerPixel == 8)
        let maskBytes = try #require(grayBytes(of: mask, width: 64, height: 36))
        #expect(maskBytes[15 * 64 + 3] == 255 && maskBytes[2 * 64 + 3] == 0)
    }

    @Test func theTitleAndThePrintDescriptionAreCutToTheWorkersLimit() throws {
        let body = try #require(shirtPaintingRequestBody(paintingRequest(printDescription: String(repeating: "😀", count: 200), title: String(repeating: "x", count: 400))))
        let printDescription = try #require((body["garment"] as? [String: String])?["printDescription"])
        #expect(printDescription.utf16.count == 300)
        #expect((body["itemTitle"] as? String)?.utf16.count == 300)
    }

    @Test func theProductIsThePicturesCropAtItsOwnResolution() throws {
        let picture = rgbImage(bytes: [UInt8](repeating: 255, count: 400 * 500 * 4), width: 400, height: 500)!
        let corners = RoomArtCorners(topLeft: CGPoint(x: 100, y: 100), topRight: CGPoint(x: 300, y: 100), bottomRight: CGPoint(x: 300, y: 400), bottomLeft: CGPoint(x: 100, y: 400))
        let productJPEG = try #require(shirtPaintingProductJPEG(picture: picture, itemCorners: corners))
        let product = try #require(decodedImage(from: productJPEG))
        #expect(product.width == 220 && product.height == 330)
        let tiny = RoomArtCorners(topLeft: .zero, topRight: CGPoint(x: 10, y: 0), bottomRight: CGPoint(x: 10, y: 10), bottomLeft: CGPoint(x: 0, y: 10))
        #expect(shirtPaintingProductJPEG(picture: picture, itemCorners: tiny) == nil)
    }

    @Test func aButtonPressCountsFromARecentClickOrFromWhenItIsHandled() {
        #expect(shirtButtonPressTime(currentEventIsAMouseClick: true, currentEventTimestamp: 99.8, now: 100) == 99.8)
        // A VoiceOver press: the current event is the last click, from long before, or not a click at all.
        #expect(shirtButtonPressTime(currentEventIsAMouseClick: true, currentEventTimestamp: 90, now: 100) == 100)
        #expect(shirtButtonPressTime(currentEventIsAMouseClick: false, currentEventTimestamp: 99.9, now: 100) == 100)
        #expect(shirtButtonPressTime(currentEventIsAMouseClick: true, currentEventTimestamp: nil, now: 100) == 100)
        #expect(shirtButtonPressTime(currentEventIsAMouseClick: true, currentEventTimestamp: 100.5, now: 100) == 100)
    }

    @Test func eachFailureHasItsOwnLine() {
        #expect(shirtPaintingFailure(for: RoomFurnitureGenerationError.serviceIsNotSetUp(body: "")) == .serviceIsNotSetUp)
        #expect(shirtPaintingFailure(for: RoomFurnitureGenerationError.serviceIsOutOfCredit(body: "")) == .serviceIsOutOfCredit)
        #expect(shirtPaintingFailure(for: RoomFurnitureGenerationError.workerReturned(statusCode: 502, body: "")) == .paintingFailed)
        #expect(shirtPaintingFailure(for: URLError(.timedOut)) == .workerUnreachable)
        #expect(shirtPaintingFailure(for: RoomFurnitureGenerationError.workerReturned(statusCode: 401, body: "")) == .appSecretRefused)
        let lines = [ShirtPaintingFailure.maskNotMade, .serviceIsNotSetUp, .serviceIsOutOfCredit, .appSecretRefused, .workerUnreachable, .paintingFailed].map(\.spokenLine)
        #expect(Set(lines).count == 6)
        // Out of credit, asking again fails the same way, so its line never offers a retry.
        #expect(!ShirtPaintingFailure.serviceIsOutOfCredit.spokenLine.contains("right there"))
    }
}

// MARK: - The client

/// Answers `http://shirt.stub/<test id>/room-furniture-composite` with the reply a test set, and records each body.
private final class StubbedShirtWorkerURLProtocol: URLProtocol, @unchecked Sendable {
    static let replies = OSAllocatedUnfairLock<[String: (statusCode: Int, body: Data)]>(initialState: [:])
    static let requestBodies = OSAllocatedUnfairLock<[String: [Data]]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "shirt.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ $0[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let readCount = stream.read(&buffer, maxLength: buffer.count)
                guard readCount > 0 else { break }
                body.append(buffer, count: readCount)
            }
            stream.close()
        }
        Self.requestBodies.withLock { $0[url.path, default: []].append(body) }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct ShirtPaintingClientTests {
    private let testID = UUID().uuidString

    private func client() -> ShirtPaintingClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedShirtWorkerURLProtocol.self]
        return ShirtPaintingClient(workerBaseURL: "http://shirt.stub/\(testID)", sessionConfiguration: configuration)
    }

    private func answer(statusCode: Int, body: Data) {
        StubbedShirtWorkerURLProtocol.replies.withLock { $0["/\(testID)/room-furniture-composite"] = (statusCode, body) }
    }

    private func replyBody(width: Int, height: Int, statedWidth: Int? = nil) -> Data {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) { bytes[index * 4] = 20; bytes[index * 4 + 1] = 200; bytes[index * 4 + 2] = 40; bytes[index * 4 + 3] = 255 }
        let painted = jpegData(of: rgbImage(bytes: bytes, width: width, height: height)!)!
        return try! JSONSerialization.data(withJSONObject: ["imageJPEGBase64": painted.base64EncodedString(), "width": statedWidth ?? width, "height": height])
    }

    @Test func aPaintingIsSentAsAShirtAndPastedIntoTheFrame() async throws {
        answer(statusCode: 200, body: replyBody(width: 64, height: 36))

        let pasted = try await client().paint(paintingRequest())

        #expect(pasted.width == 64 && pasted.height == 36)
        let pixels = try #require(rgbaBytes(of: pasted, width: 64, height: 36))
        // Painted inside the mask, and the frame as filmed far from it.
        #expect(pixels[(15 * 64 + 30) * 4 + 1] > 150)
        let sentBody = try #require(StubbedShirtWorkerURLProtocol.requestBodies.withLock { $0["/\(testID)/room-furniture-composite"]?.first })
        let sentJSON = try #require(try JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(sentJSON["kind"] as? String == "shirt")
    }

    @Test func aWorkerWithNoKeyIsNotSetUpAndOtherFailuresAreFailures() async {
        answer(statusCode: 503, body: Data(#"{"error":"OPENAI_API_KEY is not set"}"#.utf8))
        await #expect(throws: RoomFurnitureGenerationError.serviceIsNotSetUp(body: #"{"error":"OPENAI_API_KEY is not set"}"#)) {
            try await client().paint(paintingRequest())
        }
        answer(statusCode: 402, body: Data(#"{"error":"OpenAI is out of credit"}"#.utf8))
        await #expect(throws: RoomFurnitureGenerationError.serviceIsOutOfCredit(body: #"{"error":"OpenAI is out of credit"}"#)) {
            try await client().paint(paintingRequest())
        }
        answer(statusCode: 502, body: Data(#"{"error":"The shirt could not be drawn on you"}"#.utf8))
        await #expect(throws: RoomFurnitureGenerationError.workerReturned(statusCode: 502, body: #"{"error":"The shirt could not be drawn on you"}"#)) {
            try await client().paint(paintingRequest())
        }
    }

    @Test func aReplyWhoseImageIsNotTheSizeItStatesIsRefused() async {
        answer(statusCode: 200, body: replyBody(width: 64, height: 36, statedWidth: 80))
        await #expect(throws: RoomFurnitureGenerationError.self) { try await client().paint(paintingRequest()) }
    }
}
