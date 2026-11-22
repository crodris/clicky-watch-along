//
//  ShirtOnModelTests.swift
//  leanring-buddyTests
//
//  Tests of the shirt try-on from a photo of the shirt on a model (ShirtOnModel.swift), on a model drawn in the test, so they
//  need no Vision: the parts the model is split into, the seeds and limits that steer the split, the shirt's geometry from the
//  model's joints, each sleeve carried from the model's arm to the learner's, and the garment as the renderer draws it.
//

import CoreGraphics
import CoreImage
import Foundation
import simd
import Testing
@testable import Clicky

private let skin: (UInt8, UInt8, UInt8) = (200, 150, 120)
private let shirtBlue: (UInt8, UInt8, UInt8) = (40, 70, 160)
private let trousers: (UInt8, UInt8, UInt8) = (30, 30, 30)

/// A model drawn in a 400 by 500 working photo on a light backdrop. The shoulders are at (140, 150) and (260, 150), so the
/// shoulder width is 120. A skin head and neck above a blue shirt, whose torso runs from row 140 to its hem at row 340 and
/// whose sleeves hang from row 145 to 215 beside it, with a skin-colored square printed on the chest; bare forearms from
/// row 215 down to the wrists, and dark trousers below the hem.
private struct DrawnModel {
    var photo = ShirtTestCanvas(width: 400, height: 500, color: (240, 240, 240))
    var personMask = [UInt8](repeating: 0, count: 400 * 500)

    init() {
        draw(columns: 182..<218, rows: 100..<158, color: skin)
        drawCircle(centerColumn: 200, centerRow: 70, radius: 40, color: skin)
        draw(columns: 125..<275, rows: 140..<340, color: shirtBlue)
        draw(columns: 95..<135, rows: 145..<215, color: shirtBlue)
        draw(columns: 265..<305, rows: 145..<215, color: shirtBlue)
        // The neck over the front of the shirt leaves the neck hole, and the print on the chest is skin colored.
        draw(columns: 182..<218, rows: 140..<158, color: skin)
        draw(columns: 185..<215, rows: 220..<250, color: skin)
        draw(columns: 98..<130, rows: 215..<345, color: skin)
        draw(columns: 270..<302, rows: 215..<345, color: skin)
        draw(columns: 135..<265, rows: 340..<500, color: trousers)
    }

    mutating func draw(columns: Range<Int>, rows: Range<Int>, color: (UInt8, UInt8, UInt8)) {
        photo.fill(columns: columns, rows: rows, color: color)
        for row in rows { for column in columns { personMask[row * 400 + column] = 255 } }
    }

    mutating func drawCircle(centerColumn: Int, centerRow: Int, radius: Int, color: (UInt8, UInt8, UInt8)) {
        photo.fillCircle(centerColumn: centerColumn, centerRow: centerRow, radius: radius, color: color)
        for row in (centerRow - radius)...(centerRow + radius) {
            for column in (centerColumn - radius)...(centerColumn + radius) where (column - centerColumn) * (column - centerColumn) + (row - centerRow) * (row - centerRow) <= radius * radius {
                personMask[row * 400 + column] = 255
            }
        }
    }

    var pose: ShirtModelPose {
        ShirtModelPose(
            torso: BodyTorso(
                imageLeftShoulder: CGPoint(x: 140, y: 150), imageRightShoulder: CGPoint(x: 260, y: 150),
                imageLeftHip: CGPoint(x: 160, y: 324), imageRightHip: CGPoint(x: 240, y: 324), hipsWereEstimated: true, shouldersAreSeen: true,
                imageLeftElbow: CGPoint(x: 114, y: 260), imageRightElbow: CGPoint(x: 286, y: 260)
            ),
            nose: CGPoint(x: 200, y: 80), imageLeftWrist: CGPoint(x: 114, y: 335), imageRightWrist: CGPoint(x: 286, y: 335)
        )
    }

    func garment() -> ShirtGarment? {
        ShirtGarment.make(onModelPhotoPixels: photo.bytes, width: 400, height: 500, personMask: personMask, pose: pose)
    }
}

/// The alpha of `image` (extent from the origin, Core Image's y up) at a pixel given top left first.
private func alpha(of image: CIImage, column: Int, row: Int) -> Int {
    var pixel = [UInt8](repeating: 0, count: 4)
    let height = Int(image.extent.height)
    pixel.withUnsafeMutableBytes { buffer in
        CIContext().render(image, toBitmap: buffer.baseAddress!, rowBytes: 4, bounds: CGRect(x: column, y: height - 1 - row, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
    }
    return Int(pixel[3])
}

/// How many pixels of `image` have a channel at least half, the alpha by default.
private func opaquePixelCount(of image: CIImage, channel: Int = 3) -> Int {
    let width = Int(image.extent.width), height = Int(image.extent.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        CIContext().render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: nil)
    }
    return stride(from: channel, to: bytes.count, by: 4).filter { bytes[$0] >= 128 }.count
}

struct ShirtModelPoseTests {
    private func reading(_ x: Double, _ y: Double, _ confidence: Float = 0.8) -> ShirtJointReading {
        ShirtJointReading(visionPoint: CGPoint(x: x, y: y), confidence: confidence)
    }

    @Test func eachWristGoesWithTheShoulderOnItsOwnSideAndAnUnsureJointIsLeftOut() throws {
        // A model facing the camera: their left shoulder is on the image right.
        let pose = try #require(ShirtModelPose(readings: ShirtModelJointReadings(
            body: ShirtBodyJointReadings(
                personLeftShoulder: reading(0.65, 0.7), personRightShoulder: reading(0.35, 0.7), personLeftHip: nil, personRightHip: nil,
                personLeftElbow: reading(0.7, 0.5), personRightElbow: reading(0.3, 0.5)
            ),
            nose: reading(0.5, 0.9, 0.2), personLeftWrist: reading(0.7, 0.3), personRightWrist: reading(0.3, 0.3)
        ), photoSize: CGSize(width: 100, height: 100)))
        #expect(pose.imageLeftWrist == CGPoint(x: 30, y: 70))
        #expect(pose.imageRightWrist == CGPoint(x: 70, y: 70))
        #expect(pose.nose == nil)
    }

    @Test func noPoseWithoutBothShouldersSeen() {
        let unsure = ShirtModelJointReadings(
            body: ShirtBodyJointReadings(personLeftShoulder: reading(0.65, 0.7), personRightShoulder: reading(0.35, 0.7, 0.1), personLeftHip: nil, personRightHip: nil),
            nose: nil, personLeftWrist: nil, personRightWrist: nil
        )
        #expect(ShirtModelPose(readings: unsure, photoSize: CGSize(width: 100, height: 100)) == nil)
    }

    @Test func theBodyFrameRunsAcrossTheShouldersAndDownTheBody() {
        let frame = ShirtBodyFrame(torso: DrawnModel().pose.torso)
        #expect(frame.shoulderWidth == 120)
        #expect(frame.bodyCoordinates(of: SIMD2(260, 270)) == SIMD2(0.5, 1))
        #expect(frame.photoPoint(atBodyCoordinates: SIMD2(-0.5, 1)) == SIMD2(140, 270))
    }
}

struct ShirtModelPartTests {
    @Test func theSeedsAndTheirLimitsFollowTheJoints() {
        let model = DrawnModel()
        let seeds = ShirtModelPartSeeds(pose: model.pose, rgba: model.photo.bytes, isPerson: model.personMask.map { $0 >= 128 }, width: 400, height: 500)
        func isSeed(_ part: ShirtModelPart, _ column: Int, _ row: Int) -> Bool { seeds.seedsOfEachPart[part.rawValue][row * 400 + column] }
        func mayReach(_ part: ShirtModelPart, _ column: Int, _ row: Int) -> Bool { seeds.allowedOfEachPart[part.rawValue][row * 400 + column] }
        #expect(isSeed(.shirt, 200, 260))
        #expect(isSeed(.head, 200, 80))
        #expect(isSeed(.arms, 114, 320))
        // The dark trousers along the photo's bottom edge are below the hem, by their color alone.
        #expect(isSeed(.belowTheHem, 200, 495))
        // The head stays above the collar and off the tops of the shoulders; the arms stay near their bones.
        #expect(mayReach(.head, 200, 120))
        #expect(!mayReach(.head, 245, 145))
        #expect(!mayReach(.arms, 200, 260))
        #expect(mayReach(.arms, 114, 230))
    }

    @Test func thePhotosBottomEdgeIsBelowTheHemOnlyWhereItsColorIsUnlikeTheShirts() {
        // Hips this low put the joints' own below-the-hem seed past the photo's bottom, so only the color rule seeds it.
        let lowHips = BodyTorso(
            imageLeftShoulder: CGPoint(x: 140, y: 150), imageRightShoulder: CGPoint(x: 260, y: 150),
            imageLeftHip: CGPoint(x: 160, y: 470), imageRightHip: CGPoint(x: 240, y: 470), hipsWereEstimated: true, shouldersAreSeen: true,
            imageLeftElbow: CGPoint(x: 114, y: 260), imageRightElbow: CGPoint(x: 286, y: 260)
        )
        func bottomEdgeSeeds(trouserColor: (UInt8, UInt8, UInt8)) -> Int {
            var model = DrawnModel()
            model.draw(columns: 135..<265, rows: 340..<500, color: trouserColor)
            let pose = ShirtModelPose(torso: lowHips, nose: model.pose.nose, imageLeftWrist: model.pose.imageLeftWrist, imageRightWrist: model.pose.imageRightWrist)
            let seeds = ShirtModelPartSeeds(pose: pose, rgba: model.photo.bytes, isPerson: model.personMask.map { $0 >= 128 }, width: 400, height: 500)
            return seeds.seedsOfEachPart[ShirtModelPart.belowTheHem.rawValue].filter { $0 }.count
        }
        #expect(bottomEdgeSeeds(trouserColor: trousers) > 0)
        #expect(bottomEdgeSeeds(trouserColor: shirtBlue) == 0)
    }

    @Test func eachPixelGoesToItsPartAndASkinColoredPrintStaysShirt() throws {
        let model = DrawnModel()
        let labels = try #require(ShirtGarment.onModelPartLabels(
            photoPixels: model.photo.bytes, isPerson: model.personMask.map { $0 >= 128 }, width: 400, height: 500, pose: model.pose
        ))
        func label(_ column: Int, _ row: Int) -> ShirtModelPart? { labels[row * 400 + column] }
        #expect(label(200, 235) == .shirt)
        #expect(label(110, 180) == .shirt)
        #expect(label(200, 60) == .head)
        #expect(label(200, 125) == .head)
        #expect(label(114, 300) == .arms)
        #expect(label(200, 450) == .belowTheHem)
        #expect(label(20, 20) == nil)
    }

    @Test func roundingTakesOffASpeckAndTheCornersOfABlock() {
        var flags = [Bool](repeating: false, count: 20 * 20)
        flags[2 * 20 + 2] = true
        for row in 8..<18 { for column in 8..<18 { flags[row * 20 + column] = true } }
        let rounded = ShirtGarment.roundedCorners(of: flags, width: 20, height: 20, radius: 2)
        #expect(!rounded[2 * 20 + 2])
        #expect(!rounded[8 * 20 + 8])
        #expect(rounded[12 * 20 + 12])
        #expect(rounded[8 * 20 + 12])
    }
}

struct ShirtOnModelGeometryTests {
    @Test func aSleeveEndsWhereTheArmsSkinStartsAlongIt() throws {
        var isArm = [Bool](repeating: false, count: 100 * 100)
        for row in 60..<90 { for column in 48..<52 { isArm[row * 100 + column] = true } }
        let end = try #require(ShirtOnModelGeometry.sleeveEnd(isArm: isArm, width: 100, height: 100, shoulder: SIMD2(50, 10), elbow: SIMD2(50, 90), shoulderWidth: 100))
        #expect(abs(end - 50.5) < 1.5)
        // With no skin on the upper arm, the sleeve ends at a short sleeve's usual place.
        let noSkin = try #require(ShirtOnModelGeometry.sleeveEnd(isArm: [Bool](repeating: false, count: 100 * 100), width: 100, height: 100, shoulder: SIMD2(50, 10), elbow: SIMD2(50, 90), shoulderWidth: 100))
        #expect(abs(noSkin - 0.55 * 80) < 1e-9)
    }

    @Test func theShirtsGeometryComesFromTheModelsJoints() throws {
        let garment = try #require(DrawnModel().garment())
        // The corners lie on the shirt's own sides, from the shoulder seams' height to the hem. The forearms cover the torso's
        // outer five columns on each side, so the shirt shows from column 130 to 269.
        let corners = garment.torsoCorners
        #expect(abs(corners.topLeft.x - 131) < 2 && abs(corners.topRight.x - 269) < 2)
        #expect(abs(corners.bottomLeft.y - 339) < 2 && abs(corners.bottomRight.y - 339) < 2)
        #expect(corners.topLeft.y < 150 && corners.topLeft.y > 140)
        // The front of the neck is the first shirt below the model's neck.
        #expect(garment.frontNeckWasFound)
        #expect(abs(garment.frontNeckPoint.y - 158) < 2)
        // Both sleeves hang, end where the forearm's skin starts, and are split from the armpit.
        #expect(garment.sleeves.count == 2)
        for sleeve in garment.sleeves {
            #expect(sleeve.geometry.splitsFromTheArmpit)
            #expect(abs(sleeve.geometry.openingCenter.y - 214) < 6)
            #expect(sleeve.geometry.openingWidth > 25)
        }
        #expect(garment.modelPose == DrawnModel().pose)
    }

    @Test func theCutoutLeavesTheHeadTheArmsAndTheTrousersOut() throws {
        let garment = try #require(DrawnModel().garment())
        #expect(alpha(of: garment.cutout, column: 200, row: 235) == 255)
        #expect(alpha(of: garment.cutout, column: 200, row: 300) == 255)
        #expect(alpha(of: garment.cutout, column: 200, row: 70) == 0)
        #expect(alpha(of: garment.cutout, column: 200, row: 145) == 0)
        #expect(alpha(of: garment.cutout, column: 114, row: 300) == 0)
        #expect(alpha(of: garment.cutout, column: 200, row: 420) == 0)
        // The photo's white is read from the backdrop, not from the skin or the trousers left out of the cutout.
        #expect(garment.photoWhite.x > 0.8 && garment.photoWhite.y > 0.8)
    }

    @Test func aHangingSleevesClothBelowTheArmpitStaysInTheTorsoAndItsFirstHalfHoldsAllOfIt() throws {
        let garment = try #require(DrawnModel().garment())
        let torso = try #require(garment.torsoWithoutSleeves)
        let leftSleeve = try #require(garment.sleeves.first { $0.geometry.side == .imageLeft })
        // Above the armpit the sleeve is drawn on its own; below it, where it hangs in front of the shirt's side, the torso
        // keeps the cloth too.
        #expect(alpha(of: torso, column: 105, row: 165) == 0)
        #expect(leftSleeve.geometry.isSleevePixel[208 * 400 + 112])
        #expect(alpha(of: torso, column: 112, row: 208) > 0)
        #expect(opaquePixelCount(of: leftSleeve.firstHalf) >= opaquePixelCount(of: leftSleeve.secondHalf.composited(over: leftSleeve.firstHalf)))
    }
}

struct ShirtOnModelSleeveLandingTests {
    @Test func onTheModelsOwnBodyTheSleeveLandsWhereItLies() throws {
        let model = DrawnModel()
        let garment = try #require(model.garment())
        for sleeve in garment.sleeves {
            let landing = try #require(ShirtOnModelSleeveLanding.landing(
                of: sleeve.geometry, modelPose: model.pose, torso: model.pose.torso, torsoHomography: matrix_identity_double3x3, oldSleeve: nil
            ))
            for (landed, source) in zip(landing, sleeve.geometry.quadrilateral) {
                #expect(hypot(landed.x - source.x, landed.y - source.y) < 1e-6)
            }
        }
    }

    @Test func anArmTurnedOutTurnsTheOpeningWithItAboutTheShoulder() throws {
        let model = DrawnModel()
        let garment = try #require(model.garment())
        let sleeve = try #require(garment.sleeves.first { $0.geometry.side == .imageLeft })
        // The learner's left arm turns 20 degrees further out from the shoulder at (140, 150).
        let modelElbow = try #require(model.pose.torso.imageLeftElbow)
        let angle = 20.0 * .pi / 180
        func turned(_ point: CGPoint) -> CGPoint {
            let offset = CGPoint(x: point.x - 140, y: point.y - 150)
            return CGPoint(x: 140 + offset.x * cos(angle) - offset.y * sin(angle), y: 150 + offset.x * sin(angle) + offset.y * cos(angle))
        }
        let learner = model.pose.torso
        let learnerTorso = BodyTorso(
            imageLeftShoulder: learner.imageLeftShoulder, imageRightShoulder: learner.imageRightShoulder, imageLeftHip: learner.imageLeftHip,
            imageRightHip: learner.imageRightHip, hipsWereEstimated: true, shouldersAreSeen: true, imageLeftElbow: turned(modelElbow), imageRightElbow: learner.imageRightElbow
        )
        let landing = try #require(ShirtOnModelSleeveLanding.landing(of: sleeve.geometry, modelPose: model.pose, torso: learnerTorso, torsoHomography: matrix_identity_double3x3, oldSleeve: nil))
        // The seam stays with the torso, and the opening's ends turn with the arm.
        #expect(landing[0] == sleeve.geometry.seamTop && landing[3] == sleeve.geometry.seamBottom)
        for (landed, source) in [(landing[1], sleeve.geometry.openingOuter), (landing[2], sleeve.geometry.openingInner)] {
            let expected = turned(source)
            #expect(hypot(landed.x - expected.x, landed.y - expected.y) < 1e-6)
        }
    }

    @Test func theOpeningMovesDownTheArmToCoverAnOldSleeveThatReachesFurther() throws {
        let model = DrawnModel()
        let garment = try #require(model.garment())
        let sleeve = try #require(garment.sleeves.first { $0.geometry.side == .imageLeft })
        let bare = try #require(ShirtOnModelSleeveLanding.landing(of: sleeve.geometry, modelPose: model.pose, torso: model.pose.torso, torsoHomography: matrix_identity_double3x3, oldSleeve: nil))
        let covering = try #require(ShirtOnModelSleeveLanding.landing(
            of: sleeve.geometry, modelPose: model.pose, torso: model.pose.torso, torsoHomography: matrix_identity_double3x3,
            oldSleeve: ShirtOldSleeveExtent(reachAlongTheArm: 90, outward: 0, inward: -100)
        ))
        // The arm runs from (140, 150) to (114, 260), 113 pixels long, so 90 along it is 21 pixels further than the bare opening.
        let arm = SIMD2(114.0 - 140, 260 - 150) / hypot(114.0 - 140, 260 - 150)
        func alongTheArm(_ point: CGPoint) -> Double { simd_dot(SIMD2(point.x - 140, point.y - 150), arm) }
        #expect(alongTheArm(covering[1]) > alongTheArm(bare[1]) + 10)
        #expect(abs((alongTheArm(covering[1]) + alongTheArm(covering[2])) / 2 - 90) < 1e-6)
    }

    @Test func aSleeveThatWouldLandMirroredIsNotDrawnApart() throws {
        let model = DrawnModel()
        let garment = try #require(model.garment())
        let sleeve = try #require(garment.sleeves.first { $0.geometry.side == .imageLeft })
        // An arm raised straight up past the head turns the sleeve's triangles over.
        let learner = model.pose.torso
        let raised = BodyTorso(
            imageLeftShoulder: learner.imageLeftShoulder, imageRightShoulder: learner.imageRightShoulder, imageLeftHip: learner.imageLeftHip,
            imageRightHip: learner.imageRightHip, hipsWereEstimated: true, shouldersAreSeen: true, imageLeftElbow: CGPoint(x: 166, y: 40), imageRightElbow: learner.imageRightElbow
        )
        #expect(ShirtOnModelSleeveLanding.landing(of: sleeve.geometry, modelPose: model.pose, torso: raised, torsoHomography: matrix_identity_double3x3, oldSleeve: nil) == nil)
    }
}

struct ShirtOnModelRendererTests {
    @Test func theRendererCarriesEachSleeveFromTheModelsArm() throws {
        let model = DrawnModel()
        let garment = try #require(model.garment())
        // The learner is the same drawn model, in a 400 by 500 frame, wearing the blue shirt as their old one.
        let frame = model.photo.ciImage
        var personCanvas = ShirtTestCanvas(width: 400, height: 500, color: (0, 0, 0))
        for index in model.personMask.indices where model.personMask[index] != 0 {
            personCanvas.fill(columns: (index % 400)..<(index % 400 + 1), rows: (index / 400)..<(index / 400 + 1), color: (255, 255, 255))
        }
        let personMask = CIImage(bitmapData: Data(personCanvas.bytes), bytesPerRow: 400 * 4, size: CGSize(width: 400, height: 500), format: .RGBA8, colorSpace: nil)
        let renderer = ShirtTryOnRenderer(ciContext: CIContext(), analysisRunsInTheBackground: false)
        let composition = try #require(renderer.composition(frame: frame, personMask: personMask, torso: model.pose.torso, garment: garment))
        #expect(composition.sleeves.count == 2)
        // An on-model sleeve keeps its angle off the arm, so it is not laid along the arm.
        #expect(composition.sleeves.allSatisfy { !$0.liesAlongTheArm })
        // The garment area of the frame just drawn is kept for the painted still, and a reset forgets it.
        let garmentArea = try #require(renderer.lastDrawnGarmentArea)
        #expect(garmentArea.extent == frame.extent)
        // The area is a gray mask: covered pixels are light in the red channel, and the room around the model is not.
        let coveredPixels = opaquePixelCount(of: garmentArea, channel: 0)
        #expect(coveredPixels > 10_000 && coveredPixels < 400 * 500 / 2)
        renderer.reset()
        #expect(renderer.lastDrawnGarmentArea == nil)
    }
}
