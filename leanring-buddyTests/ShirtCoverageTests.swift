//
//  ShirtCoverageTests.swift
//  leanring-buddyTests
//
//  The two rules that decide what depends on a garment's cut: which preview shows it (`shirtPreviewKind`), and where it lands
//  on the learner's body (`ShirtCoverage`), plus the wrists the pose reading gains for it. Pure rules on made-up poses, so
//  they need no Vision, no camera, and no window.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

// MARK: - Which preview

struct ShirtPreviewCase: Sendable, CustomTestStringConvertible {
    let photoShows: RoomArtGarmentPhoto
    let sleeves: RoomArtSleeves
    let length: RoomArtGarmentLength
    let garmentWasCutOut: Bool
    let expected: ShirtPreviewKind

    var testDescription: String { "\(photoShows) \(sleeves) \(length) cutOut \(garmentWasCutOut) -> \(expected)" }
}

struct ShirtPreviewKindTests {
    @Test(arguments: [
        // A flat lay, or a photo on a model without long sleeves, that ends at the waist or the hip, and whose cutout was made.
        ShirtPreviewCase(photoShows: .flatLay, sleeves: .short, length: .hip, garmentWasCutOut: true, expected: .liveGarment),
        ShirtPreviewCase(photoShows: .flatLay, sleeves: .none, length: .waist, garmentWasCutOut: true, expected: .liveGarment),
        ShirtPreviewCase(photoShows: .flatLay, sleeves: .long, length: .hip, garmentWasCutOut: true, expected: .liveGarment),
        ShirtPreviewCase(photoShows: .onModel, sleeves: .short, length: .hip, garmentWasCutOut: true, expected: .liveGarment),
        ShirtPreviewCase(photoShows: .onModel, sleeves: .none, length: .waist, garmentWasCutOut: true, expected: .liveGarment),
        // Long sleeves on a model: the model's forearms are cut away with the arms, so each sleeve would end at the upper arm.
        ShirtPreviewCase(photoShows: .onModel, sleeves: .long, length: .hip, garmentWasCutOut: true, expected: .ghostOutline),
        // A hanger photo and any other photo have no flat garment, or no body, to map from.
        ShirtPreviewCase(photoShows: .onHanger, sleeves: .short, length: .hip, garmentWasCutOut: true, expected: .ghostOutline),
        ShirtPreviewCase(photoShows: .other, sleeves: .short, length: .hip, garmentWasCutOut: true, expected: .ghostOutline),
        // A hem lower than the hip reaches past where the overlay's torso ends.
        ShirtPreviewCase(photoShows: .flatLay, sleeves: .short, length: .thigh, garmentWasCutOut: true, expected: .ghostOutline),
        ShirtPreviewCase(photoShows: .flatLay, sleeves: .short, length: .knee, garmentWasCutOut: true, expected: .ghostOutline),
        ShirtPreviewCase(photoShows: .onModel, sleeves: .none, length: .ankle, garmentWasCutOut: true, expected: .ghostOutline),
        // A failed cutout takes the ghost, whatever the photo and the cut.
        ShirtPreviewCase(photoShows: .flatLay, sleeves: .short, length: .hip, garmentWasCutOut: false, expected: .ghostOutline),
        ShirtPreviewCase(photoShows: .onModel, sleeves: .short, length: .hip, garmentWasCutOut: false, expected: .ghostOutline),
        ShirtPreviewCase(photoShows: .onHanger, sleeves: .long, length: .ankle, garmentWasCutOut: false, expected: .ghostOutline),
    ])
    func theRuleChoosesTheLiveGarmentOnlyWhereItWorksTodayAndItsCutoutWasMade(previewCase: ShirtPreviewCase) {
        #expect(shirtPreviewKind(
            photoShows: previewCase.photoShows, sleeves: previewCase.sleeves, length: previewCase.length, garmentWasCutOut: previewCase.garmentWasCutOut
        ) == previewCase.expected)
    }

    @Test func theLiveGarmentIsOnlyTriedWhereItMayWork() {
        // The controller cuts the garment out only for these, so a coat or a hanger photo never pays for a cutout it cannot use.
        #expect(shirtLiveGarmentMayWork(photoShows: .flatLay, sleeves: .long, length: .hip))
        #expect(shirtLiveGarmentMayWork(photoShows: .onModel, sleeves: .short, length: .waist))
        #expect(!shirtLiveGarmentMayWork(photoShows: .onModel, sleeves: .long, length: .hip))
        #expect(!shirtLiveGarmentMayWork(photoShows: .onHanger, sleeves: .none, length: .hip))
        #expect(!shirtLiveGarmentMayWork(photoShows: .flatLay, sleeves: .short, length: .thigh))
    }

    @Test func eachPreviewSaysItsOwnLines() {
        #expect(ShirtPreviewKind.liveGarment.statusLine == "On you")
        #expect(ShirtPreviewKind.liveGarment.spokenLine == "Here's a preview. Say paint it to put it on you.")
        #expect(ShirtPreviewKind.ghostOutline.statusLine == "Where it will go · say paint it")
        #expect(ShirtPreviewKind.ghostOutline.spokenLine == "This outline is where it will go. Say paint it to put it on you.")
    }
}

// MARK: - The area

/// A standing torso in a 400 by 1000 frame, so a hem down to the ankle is still in it: shoulders 100 apart at y 100, hips at
/// y 260 (a torso length of 160), elbows at y 190 and wrists at y 270.
private let standingTorso = BodyTorso(
    imageLeftShoulder: CGPoint(x: 150, y: 100), imageRightShoulder: CGPoint(x: 250, y: 100),
    imageLeftHip: CGPoint(x: 160, y: 260), imageRightHip: CGPoint(x: 240, y: 260),
    hipsWereEstimated: false, shouldersAreSeen: true,
    imageLeftElbow: CGPoint(x: 120, y: 190), imageRightElbow: CGPoint(x: 280, y: 190),
    imageLeftWrist: CGPoint(x: 110, y: 270), imageRightWrist: CGPoint(x: 290, y: 270)
)
private let frameWidth = 400, frameHeight = 1000

private func coveredPixels(_ coverage: ShirtCoverage, torso: BodyTorso = standingTorso, height: Int = frameHeight) -> (_ column: Int, _ row: Int) -> Bool {
    let mask = coverage.area(for: torso).mask(width: frameWidth, height: height)
    return { column, row in mask[row * frameWidth + column] }
}

struct ShirtCoverageTests {
    @Test(arguments: [
        (RoomArtGarmentLength.waist, 220), (.hip, 260), (.thigh, 324), (.knee, 396), (.ankle, 516),
    ])
    func theTorsoEndsAtTheHemForEachLength(length: RoomArtGarmentLength, hemRow: Int) {
        let covered = coveredPixels(ShirtCoverage(sleeves: .short, length: length))
        // On the center line, just inside the hem and just past it.
        #expect(covered(200, hemRow - 4))
        #expect(!covered(200, hemRow + 4))
        // The torso starts at the shoulder line and never above it, so the neck is left to the neck rules.
        #expect(covered(200, 104))
        #expect(!covered(200, 96))
        // A hem lower than the hips is as wide as the hips, not narrower.
        #expect(covered(165, hemRow - 4) && covered(235, hemRow - 4))
        #expect(!covered(100, hemRow - 4) && !covered(300, hemRow - 4))
    }

    @Test func theHemsGetLongerInOrder() {
        let hems = [RoomArtGarmentLength.waist, .hip, .thigh, .knee, .ankle].map { ShirtCoverage.hemInTorsoLengths(for: $0) }
        #expect(hems == hems.sorted() && Set(hems).count == 5)
        #expect(ShirtCoverage.hemInTorsoLengths(for: .hip) == 1)
    }

    @Test func noSleevesCoverNoArm() {
        let covered = coveredPixels(ShirtCoverage(sleeves: .none, length: .hip))
        #expect(!covered(140, 130) && !covered(135, 145) && !covered(115, 230) && !covered(111, 262))
        #expect(!covered(260, 130) && !covered(265, 145) && !covered(285, 230) && !covered(289, 262))
    }

    @Test func shortSleevesCoverEachUpperArmHalfwayToTheElbowAndNoFurther() {
        #expect(ShirtCoverage.shortSleeveShareOfTheUpperArm == 0.5)
        let covered = coveredPixels(ShirtCoverage(sleeves: .short, length: .hip))
        // The upper arm runs from the shoulder (150, 100) to the elbow (120, 190), so the sleeve ends at (135, 145). Outside
        // the torso's edge, along the upper arm, on each side.
        #expect(covered(140, 130) && covered(137, 140))
        #expect(covered(260, 130) && covered(263, 140))
        // Not past the sleeve's end down the upper arm, and not the forearm or the wrist.
        #expect(!covered(128, 165) && !covered(115, 230) && !covered(111, 262))
        #expect(!covered(272, 165) && !covered(285, 230) && !covered(289, 262))
        // The upper arm is a sleeve piece, so the paint mask's skin rule lets a bare upper arm under it be painted.
        let sleeveMask = ShirtCoverage(sleeves: .short, length: .hip).area(for: standingTorso).sleeveMask(width: frameWidth, height: frameHeight)
        #expect(sleeveMask[130 * frameWidth + 140] && !sleeveMask[150 * frameWidth + 200])
    }

    @Test func aShortSleeveWithNoArmJointSeenHangsHalfwayDownTheUpperArm() {
        let noJoints = BodyTorso(
            imageLeftShoulder: standingTorso.imageLeftShoulder, imageRightShoulder: standingTorso.imageRightShoulder,
            imageLeftHip: standingTorso.imageLeftHip, imageRightHip: standingTorso.imageRightHip, hipsWereEstimated: false, shouldersAreSeen: true
        )
        let covered = coveredPixels(ShirtCoverage(sleeves: .short, length: .hip), torso: noJoints)
        // The arm hangs 1.1 torso lengths (176) down from the shoulder, so the elbow is taken 88 down and the sleeve ends 44 down.
        #expect(covered(138, 130) && covered(262, 130))
        #expect(!covered(138, 160) && !covered(262, 160))
    }

    @Test func longSleevesFollowEachArmFromTheShoulderToTheWristAndStopThere() {
        let covered = coveredPixels(ShirtCoverage(sleeves: .long, length: .hip))
        // Along the upper arm, at the elbow, along the forearm, and at the wrist, on each side.
        #expect(covered(135, 145) && covered(120, 190) && covered(115, 230) && covered(111, 266))
        #expect(covered(265, 145) && covered(280, 190) && covered(285, 230) && covered(289, 266))
        // Not past the wrist, where the hand starts, and not beside the arm.
        #expect(!covered(108, 300) && !covered(292, 300))
        #expect(!covered(60, 190) && !covered(340, 190))
    }

    @Test func aWristThePoseDidNotSeeIsMostOfAnUpperArmOnFromTheElbow() {
        let noWrists = BodyTorso(
            imageLeftShoulder: standingTorso.imageLeftShoulder, imageRightShoulder: standingTorso.imageRightShoulder,
            imageLeftHip: standingTorso.imageLeftHip, imageRightHip: standingTorso.imageRightHip, hipsWereEstimated: false, shouldersAreSeen: true,
            imageLeftElbow: standingTorso.imageLeftElbow, imageRightElbow: standingTorso.imageRightElbow
        )
        let covered = coveredPixels(ShirtCoverage(sleeves: .long, length: .hip), torso: noWrists)
        // The elbow is (120, 190) and the upper arm runs (-30, 90), so the wrist is taken 0.8 of it on, at (96, 262), and the
        // sleeve stops there instead of reaching over the hand a full upper arm on.
        #expect(covered(100, 250) && covered(97, 258))
        #expect(!covered(92, 280) && !covered(80, 330))
    }

    @Test func withNoArmJointSeenAnArmHangsDownTheBodysSide() {
        let noJoints = BodyTorso(
            imageLeftShoulder: standingTorso.imageLeftShoulder, imageRightShoulder: standingTorso.imageRightShoulder,
            imageLeftHip: standingTorso.imageLeftHip, imageRightHip: standingTorso.imageRightHip, hipsWereEstimated: false, shouldersAreSeen: true
        )
        let covered = coveredPixels(ShirtCoverage(sleeves: .long, length: .hip), torso: noJoints)
        // Outside the torso's edge, straight below the shoulder, down to 1.1 torso lengths.
        #expect(covered(138, 200) && covered(262, 200) && covered(138, 270))
        #expect(!covered(138, 300) && !covered(100, 200))
    }

    @Test func theAreaIsClippedToTheFrameAndNeverCrashesPastIt() {
        // The hem is far below a frame only 300 rows tall, so the area runs to its last row and stops.
        let covered = coveredPixels(ShirtCoverage(sleeves: .long, length: .ankle), height: 300)
        #expect(covered(200, 299) && covered(200, 150))
        let tiny = ShirtCoverage(sleeves: .long, length: .ankle).area(for: standingTorso).mask(width: 20, height: 20)
        #expect(tiny.count == 400)
        #expect(ShirtCoverage(sleeves: .long, length: .knee).area(for: standingTorso).mask(width: 0, height: 0).isEmpty)
    }

    @Test func theAreaFollowsATorsoScaledToASmallerCopyOfTheFrame() {
        let area = ShirtCoverage(sleeves: .long, length: .knee).area(for: standingTorso.scaled(by: 0.5))
        let mask = area.mask(width: 200, height: 500)
        // The wrist and the knee-length hem, half as far from the corner.
        #expect(mask[133 * 200 + 55] && mask[194 * 200 + 100])
        #expect(!mask[210 * 200 + 100])
    }

    @Test func aCoverageIsReadFromTheClothingReading() {
        let reading = RoomArtClothingReading(
            title: "Wool coat", garment: .coat, sleeves: .long, length: .knee, canBeDrawnOnTheLearner: true, chosenSizeLabel: "M",
            photoShows: .onHanger, printDescription: "", mainColorHex: "#4A3B2F", whyThisSize: "M.", itemCorners: RoomArtCorners(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
        )
        #expect(ShirtCoverage(reading: reading) == ShirtCoverage(sleeves: .long, length: .knee))
    }
}

// MARK: - The wrists

struct BodyTorsoWristTests {
    private let frameSize = CGSize(width: 1000, height: 800)

    private func reading(_ x: Double, _ y: Double, confidence: Float = 0.9) -> ShirtJointReading {
        ShirtJointReading(visionPoint: CGPoint(x: x, y: y), confidence: confidence)
    }

    @Test func eachWristBelongsToTheShoulderOnItsOwnSideWhicheverWayTheCameraIsMirrored() throws {
        // The person's left shoulder is at the image's right, as a mirrored camera puts it.
        let torso = try #require(BodyTorso(
            readings: ShirtBodyJointReadings(
                personLeftShoulder: reading(0.65, 0.7), personRightShoulder: reading(0.35, 0.7), personLeftHip: reading(0.6, 0.4), personRightHip: reading(0.4, 0.4),
                personLeftWrist: reading(0.72, 0.3), personRightWrist: reading(0.28, 0.32)
            ),
            frameSize: frameSize
        ))
        // Image left is the person's right.
        #expect(torso.imageLeftWrist == CGPoint(x: 280, y: 544))
        #expect(torso.imageRightWrist == CGPoint(x: 720, y: 560))
    }

    @Test func aWristThatIsNotConfidentOrIsOutsideTheFrameIsNotSeen() throws {
        let torso = try #require(BodyTorso(
            readings: ShirtBodyJointReadings(
                personLeftShoulder: reading(0.65, 0.7), personRightShoulder: reading(0.35, 0.7), personLeftHip: nil, personRightHip: nil,
                personLeftWrist: reading(0.7, 0.3, confidence: 0.1), personRightWrist: reading(0.3, -0.2)
            ),
            frameSize: frameSize
        ))
        #expect(torso.imageLeftWrist == nil && torso.imageRightWrist == nil)
    }

    @Test func theWristsFollowTheTorsoWhenItIsScaledAndWhenItsLengthChanges() {
        let scaled = standingTorso.scaled(by: 0.5)
        #expect(scaled.imageLeftWrist == CGPoint(x: 55, y: 135) && scaled.imageRightWrist == CGPoint(x: 145, y: 135))
        let longer = standingTorso.withTorsoLength(200)
        #expect(longer.imageLeftWrist == standingTorso.imageLeftWrist && longer.imageRightWrist == standingTorso.imageRightWrist)
    }

    @Test func aWristMissingFromTheNewestResultIsHeldBrieflyThenDropped() throws {
        var smoother = ShirtTorsoSmoother()
        let withWrists = standingTorso
        let withoutWrists = BodyTorso(
            imageLeftShoulder: standingTorso.imageLeftShoulder, imageRightShoulder: standingTorso.imageRightShoulder,
            imageLeftHip: standingTorso.imageLeftHip, imageRightHip: standingTorso.imageRightHip, hipsWereEstimated: false, shouldersAreSeen: true,
            imageLeftElbow: standingTorso.imageLeftElbow, imageRightElbow: standingTorso.imageRightElbow
        )
        _ = smoother.advance(toward: withWrists, at: 0)
        let heldResult = smoother.advance(toward: withoutWrists, at: 0.1)
        let held = try #require(heldResult)
        #expect(held.imageLeftWrist != nil && held.imageRightWrist != nil)
        let droppedResult = smoother.advance(toward: withoutWrists, at: 1.0)
        let dropped = try #require(droppedResult)
        #expect(dropped.imageLeftWrist == nil && dropped.imageRightWrist == nil)
    }
}
