//
//  RoomFurnitureModelTests.swift
//  leanring-buddyTests
//
//  The furniture's 3D geometry: its box on the floor, SceneKit's camera against the pinhole, fitting a model to the page's
//  size, the floor inferred from the wall, how much of the box is in the frame, and when it draws over the learner.
//

import CoreGraphics
import Foundation
import Testing
import simd
@testable import Clicky

/// A floor below a camera tilted down, as a laptop camera sees a room: the anchor about 2.8 m ahead, near the frame's bottom.
private func floorAhead(centerX: Double = 0) -> FloorPlane {
    let up = simd_normalize(SIMD3<Double>(0, -0.96, -0.28))
    let right = SIMD3<Double>(1, 0, 0)
    return FloorPlane(
        center: SIMD3(centerX, 0.8, 2.8),
        right: right,
        up: up,
        forward: simd_cross(up, right),
        focalLengthPixels: 1100,
        principalPoint: SIMD2(640, 360),
        distanceMeters: 2.6,
        floorTiltDegrees: 16,
        planeInlierShare: 0.95
    )
}

struct RoomFurniturePlacementTests {
    @Test func theBoxsFrontFaceIsTheFlatCutoutsRectangle() throws {
        let floor = floorAhead(centerX: 0.4)
        let boxCorners = try #require(floor.keyframeBoxCorners(widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55))
        let cutoutCorners = try #require(floor.keyframeCorners(widthMeters: 0.55, heightMeters: 0.45))
        for (boxCorner, cutoutCorner) in zip(boxCorners.prefix(4), cutoutCorners.clockwiseFromTopLeft) {
            #expect(abs(boxCorner.x - cutoutCorner.x) < 1e-9 && abs(boxCorner.y - cutoutCorner.y) < 1e-9)
        }
    }

    @Test func theBackFaceIsFartherAwaySoItIsSmallerAndHigherInTheFrame() throws {
        let boxCorners = try #require(floorAhead().keyframeBoxCorners(widthMeters: 0.8, heightMeters: 0.7, depthMeters: 0.6))
        let frontBottomWidth = boxCorners[2].x - boxCorners[3].x
        let backBottomWidth = boxCorners[6].x - boxCorners[7].x
        #expect(backBottomWidth < frontBottomWidth)
        #expect(boxCorners[6].y < boxCorners[2].y)
    }

    @Test func aModelIsNeverMirrored() throws {
        let placement = try #require(RoomFurniturePlacement(floor: floorAhead(centerX: -0.7), widthMeters: 1, heightMeters: 1, depthMeters: 1))
        let rotation = simd_double3x3(columns: (placement.rightDirection, placement.upDirection, placement.towardTheFrontDirection))
        #expect(abs(rotation.determinant - 1) < 1e-9)
        // The model's +x lands to the right in the image.
        let leftPoint = try #require(pinholeProjection(of: placement.frontBottomCenter - placement.rightDirection * 0.3, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360)))
        let rightPoint = try #require(pinholeProjection(of: placement.frontBottomCenter + placement.rightDirection * 0.3, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360)))
        #expect(rightPoint.x > leftPoint.x)
    }

    @Test func aBadSizeOrAnAnchorUnderTheCameraPlacesNothing() {
        #expect(RoomFurniturePlacement(floor: floorAhead(), widthMeters: 0, heightMeters: 1, depthMeters: 1) == nil)
        #expect(RoomFurniturePlacement(floor: floorAhead(), widthMeters: 1, heightMeters: 1, depthMeters: -0.1) == nil)
        let up = SIMD3<Double>(0, -1, 0)
        let floorStraightBelow = FloorPlane(center: SIMD3(0, 1, 0), right: SIMD3(1, 0, 0), up: up, forward: SIMD3(0, 0, 1),
                                            focalLengthPixels: 1000, principalPoint: SIMD2(640, 360), distanceMeters: 1, floorTiltDegrees: 0, planeInlierShare: 1)
        #expect(RoomFurniturePlacement(floor: floorStraightBelow, widthMeters: 1, heightMeters: 1, depthMeters: 1) == nil)
    }

    /// SceneKit's camera with the pinhole projection lands an asymmetric box's corners within a pixel of the pinhole.
    @Test func sceneKitsCameraProjectsLikeThePinhole() throws {
        let floor = floorAhead(centerX: 0.55)
        let placement = try #require(RoomFurniturePlacement(floor: floor, widthMeters: 1.3, heightMeters: 0.45, depthMeters: 0.35))
        let projection = roomFurnitureProjection(focalLengthPixels: floor.focalLengthPixels, principalPoint: floor.principalPoint, frameWidth: 1280, frameHeight: 720)
        for corner in placement.boxCorners {
            let pinholePixel = try #require(pinholeProjection(of: corner, focalLengthPixels: floor.focalLengthPixels, principalPoint: floor.principalPoint))
            let sceneKitPixel = try #require(roomFurnitureSceneKitPixel(of: corner, projection: projection, frameWidth: 1280, frameHeight: 720))
            #expect(hypot(pinholePixel.x - sceneKitPixel.x, pinholePixel.y - sceneKitPixel.y) < 1)
        }
    }
}

struct RoomFurnitureModelFitTests {
    @Test func aYUpModelInMetersScalesToThePageHeight() throws {
        let fit = try #require(RoomFurnitureModelFit.fit(modelExtent: SIMD3(0.55, 0.45, 0.55), widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55))
        #expect(fit.modelUpAxis == SIMD3(0, 1, 0))
        #expect(abs(fit.scale - 1) < 1e-9)
        #expect(fit.worstSideMismatch < 1e-9)
        #expect(!fit.wasTurnedAQuarter)
    }

    @Test func aZUpModelInCentimetersIsFoundAndScaled() throws {
        // A sofa 220 wide, 80 tall, 95 deep, in centimeters with z up.
        let fit = try #require(RoomFurnitureModelFit.fit(modelExtent: SIMD3(220, 95, 80), widthMeters: 2.2, heightMeters: 0.8, depthMeters: 0.95))
        #expect(fit.modelUpAxis == SIMD3(0, 0, 1))
        #expect(abs(fit.scale - 0.01) < 1e-9)
    }

    @Test func aModelWhoseWidthAndDepthAreSwappedTurnsAQuarter() throws {
        // A bench whose long side runs along the model's z.
        let fit = try #require(RoomFurnitureModelFit.fit(modelExtent: SIMD3(0.4, 0.45, 1.2), widthMeters: 1.2, heightMeters: 0.45, depthMeters: 0.4))
        #expect(fit.wasTurnedAQuarter)
        #expect(fit.worstSideMismatch < 1e-9)
        #expect(abs(simd_dot(simd_cross(fit.modelRightAxis, fit.modelUpAxis), fit.modelFrontAxis) - 1) < 1e-9)
    }

    @Test func aSmallMismatchKeepsTheModelsOwnFront() throws {
        // Width 9 percent and depth 13 percent off is a measuring difference, not a model turned on its side, even though the
        // turned model would fit a little better.
        let fit = try #require(RoomFurnitureModelFit.fit(modelExtent: SIMD3(0.6, 0.45, 0.52), widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.6))
        #expect(!fit.wasTurnedAQuarter)
    }

    @Test func theTransformStandsTheModelsBottomMiddleOnTheOriginAtThePagesSize() throws {
        let boxMinimum = SIMD3<Double>(-10, 5, -30), boxMaximum = SIMD3<Double>(110, 95, 50)
        let fit = try #require(RoomFurnitureModelFit.fit(modelExtent: boxMaximum - boxMinimum, widthMeters: 1.2, heightMeters: 0.9, depthMeters: 0.8))
        let transform = fit.modelToFurnitureTransform(boundingBoxMinimum: boxMinimum, boundingBoxMaximum: boxMaximum)
        var transformedMinimum = SIMD3<Double>(repeating: .infinity), transformedMaximum = SIMD3<Double>(repeating: -.infinity)
        for cornerX in [boxMinimum.x, boxMaximum.x] {
            for cornerY in [boxMinimum.y, boxMaximum.y] {
                for cornerZ in [boxMinimum.z, boxMaximum.z] {
                    let corner = transform * SIMD4(cornerX, cornerY, cornerZ, 1)
                    transformedMinimum = simd_min(transformedMinimum, SIMD3(corner.x, corner.y, corner.z))
                    transformedMaximum = simd_max(transformedMaximum, SIMD3(corner.x, corner.y, corner.z))
                }
            }
        }
        #expect(simd_length(transformedMaximum - transformedMinimum - SIMD3(1.2, 0.9, 0.8)) < 1e-9)
        #expect(abs(transformedMinimum.y) < 1e-9)
        #expect(abs(transformedMinimum.x + transformedMaximum.x) < 1e-9)
        #expect(abs(transformedMinimum.z + transformedMaximum.z) < 1e-9)
    }

    @Test func aModelWithNoSizeFitsNothing() {
        #expect(RoomFurnitureModelFit.fit(modelExtent: SIMD3(0, 1, 1), widthMeters: 1, heightMeters: 1, depthMeters: 1) == nil)
        #expect(RoomFurnitureModelFit.fit(modelExtent: SIMD3(1, 1, 1), widthMeters: 1, heightMeters: .nan, depthMeters: 1) == nil)
    }
}

struct RoomFurnitureFloorFromTheWallTests {
    /// A wall 3 m ahead, square to a level camera.
    private let wallAhead = WallPlane(
        center: SIMD3(0.2, -0.1, 3), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0),
        focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 3, wallAngleDegrees: 0, planeInlierShare: 0.9
    )

    @Test func theFloorIsTheCameraHeightBelowAndTheBackStandsOnTheWall() throws {
        let floor = try #require(FloorPlane.inferred(fromTheWall: wallAhead, itemDepthMeters: 0.4))
        #expect(floor.inferredFromTheWall)
        // y grows down, so the floor 1.05 m below the camera is at y 1.05.
        #expect(abs(floor.center.y - 1.05) < 1e-9)
        #expect(abs(floor.center.z - 2.6) < 1e-9)
        let placement = try #require(RoomFurniturePlacement(floor: floor, widthMeters: 0.8, heightMeters: 0.6, depthMeters: 0.4))
        // Square to the wall: its back face is on the wall plane at z 3.
        for backCorner in placement.boxCorners.suffix(4) { #expect(abs(backCorner.z - 3) < 1e-9) }
    }

    @Test func aFloorLevelWithTheWallAgreesAndATiltedOneDoesNot() {
        let level = floorAhead()
        let wallWithUp = { (up: SIMD3<Double>) in
            WallPlane(center: SIMD3(0, 0, 3), right: SIMD3(1, 0, 0), up: up, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 3, wallAngleDegrees: 0, planeInlierShare: 1)
        }
        #expect(level.agrees(withTheWall: wallWithUp(level.up)))
        let tenDegrees = 10.0 * .pi / 180, thirtyDegrees = 30.0 * .pi / 180
        let tiltedTen = simd_normalize(level.up * cos(tenDegrees) + SIMD3(1, 0, 0) * sin(tenDegrees))
        let tiltedThirty = simd_normalize(level.up * cos(thirtyDegrees) + SIMD3(1, 0, 0) * sin(thirtyDegrees))
        #expect(level.agrees(withTheWall: wallWithUp(tiltedTen)))
        #expect(!level.agrees(withTheWall: wallWithUp(tiltedThirty)))
    }
}

struct RoomFurnitureFrameShareTests {
    private let frameSize = CGSize(width: 1280, height: 720)

    @Test func aBoxInsideTheFrameIsWhollySeen() {
        let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300)]
        #expect(abs(shareOfTheBoxInsideTheFrame(projectedCorners: corners, frameSize: frameSize) - 1) < 1e-9)
    }

    @Test func aBoxHalfBelowTheFrameIsHalfSeen() {
        let corners = [CGPoint(x: 100, y: 620), CGPoint(x: 300, y: 620), CGPoint(x: 300, y: 820), CGPoint(x: 100, y: 820)]
        #expect(abs(shareOfTheBoxInsideTheFrame(projectedCorners: corners, frameSize: frameSize) - 0.5) < 1e-9)
    }

    @Test func aBoxOutsideTheFrameIsNotSeen() {
        let corners = [CGPoint(x: 100, y: 800), CGPoint(x: 300, y: 800), CGPoint(x: 300, y: 900), CGPoint(x: 100, y: 900)]
        #expect(shareOfTheBoxInsideTheFrame(projectedCorners: corners, frameSize: frameSize) == 0)
    }
}

struct RoomFurnitureAdviceForACutOffPieceTests {
    @Test func aPieceTheFrameCutsOffByMoreThanATenthGetsAdviceAndAWholePieceGetsNone() {
        #expect(roomFurnitureAdviceForAPieceTheFrameCutsOff(shareOfTheBoxInTheFrame: 1, floorIsInferredFromTheWall: false) == nil)
        // 95 percent is within the margin for a sofa's feet on a desk camera, so it was never worth a line.
        #expect(roomFurnitureAdviceForAPieceTheFrameCutsOff(shareOfTheBoxInTheFrame: 0.95, floorIsInferredFromTheWall: false) == nil)
        #expect(roomFurnitureAdviceForAPieceTheFrameCutsOff(shareOfTheBoxInTheFrame: 0.9, floorIsInferredFromTheWall: false) == nil)
        #expect(roomFurnitureAdviceForAPieceTheFrameCutsOff(shareOfTheBoxInTheFrame: 0.89, floorIsInferredFromTheWall: false) == roomFurnitureStepBackLine)
    }

    @Test func aLaptopCameraIsToldToTiltTheScreenDownBecauseItCannotStepBackFromTheWall() {
        #expect(roomFurnitureAdviceForAPieceTheFrameCutsOff(shareOfTheBoxInTheFrame: 0.5, floorIsInferredFromTheWall: true) == "Tilt the screen down so I can show the whole piece.")
        #expect(roomFurnitureAdviceForAPieceTheFrameCutsOff(shareOfTheBoxInTheFrame: 0.95, floorIsInferredFromTheWall: true) == nil)
    }
}

struct RoomFurnitureFloorHeightTests {
    private func plane(heightBelowTheCamera: Double, tiltedAbout up: SIMD3<Double> = SIMD3(0, -1, 0)) -> FloorPlane {
        // A point on the plane that is `heightBelowTheCamera` along its normal from the camera, and 3 m out and to the side
        // along the plane, which does not change the height.
        let normal = simd_normalize(up)
        let alongThePlane = simd_normalize(simd_cross(normal, SIMD3(1, 0, 0))) * 3 + SIMD3(0.5, 0, 0)
        return FloorPlane(
            center: -normal * heightBelowTheCamera + alongThePlane, right: SIMD3(1, 0, 0), up: normal, forward: simd_cross(normal, SIMD3(1, 0, 0)),
            focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 3, floorTiltDegrees: 0, planeInlierShare: 1
        )
    }

    @Test func theHeightBelowTheCameraIsAlongThePlanesNormalWhateverPointItWasMeasuredAt() {
        #expect(abs(plane(heightBelowTheCamera: 0.4).heightBelowTheCameraMeters - 0.4) < 1e-9)
        #expect(abs(plane(heightBelowTheCamera: 1.1).heightBelowTheCameraMeters - 1.1) < 1e-9)
        // A camera tilted down 16 degrees sees the same floor, with its normal tilted in the camera's space.
        #expect(abs(plane(heightBelowTheCamera: 1.1, tiltedAbout: SIMD3(0, -0.96, -0.28)).heightBelowTheCameraMeters - 1.1) < 1e-9)
        #expect(plane(heightBelowTheCamera: 1.1).moved(toAnchorPixel: CGPoint(x: 900, y: 600)).map { abs($0.heightBelowTheCameraMeters - 1.1) < 1e-9 } == true)
    }

    @Test func aFloorInferredFromTheWallIsAtTheLaptopCamerasHeight() throws {
        let wall = WallPlane(
            center: SIMD3(-0.3, -0.2, 4), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 500,
            principalPoint: SIMD2(320, 180), distanceMeters: 4, wallAngleDegrees: 0, planeInlierShare: 0.9
        )
        let floor = try #require(FloorPlane.inferred(fromTheWall: wall, itemDepthMeters: 0.5))
        #expect(abs(floor.heightBelowTheCameraMeters - roomFurnitureCameraHeightMeters) < 1e-9)
        #expect(floor.heightBelowTheCameraMeters >= roomFurnitureLeastFloorHeightBelowTheCameraMeters)
    }

    @Test func aDeskAndABedAreUnderTheLeastFloorHeightAndARealFloorIsNot() {
        #expect(plane(heightBelowTheCamera: 0.4).heightBelowTheCameraMeters < roomFurnitureLeastFloorHeightBelowTheCameraMeters)
        #expect(plane(heightBelowTheCamera: 1.1).heightBelowTheCameraMeters >= roomFurnitureLeastFloorHeightBelowTheCameraMeters)
    }
}

struct RoomFurnitureOcclusionTests {
    @Test func theLearnerStaysInFrontUnlessThePiecesBaseIsBelowTheirFeet() {
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 500, personLowestRow: 719, frameHeight: 720))
        #expect(roomFurnitureDrawsOverThePerson(itemBaseRow: 650, personLowestRow: 600, frameHeight: 720))
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 650, personLowestRow: nil, frameHeight: 720))
    }

    /// A seated learner reaches the frame's bottom row, and on a floor inferred from the wall the piece's base projects
    /// below the frame. Neither says which is nearer, so the learner stays on top.
    @Test func aBaseBelowTheFrameNeverDrawsOverALearnerCutOffByTheFrameBottom() {
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 880, personLowestRow: 720, frameHeight: 720))
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 720, personLowestRow: 700, frameHeight: 720))
        // Feet in view at row 600 and a base below the frame is still no proof, only a base inside the frame is.
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 900, personLowestRow: 600, frameHeight: 720))
        #expect(roomFurnitureDrawsOverThePerson(itemBaseRow: 719, personLowestRow: 600, frameHeight: 720))
    }
}

/// A laptop camera that sees no floor puts the piece's feet below the picture. The box is the front face (top left, top
/// right, bottom right, bottom left) and then the back face, as `FloorPlane.keyframeBoxCorners` gives it.
struct RoomFurnitureFootprintBelowTheFrameTests {
    private let frameSize = CGSize(width: 1280, height: 720)

    private func box(frontBottomRow: Double, backBottomRow: Double) -> [CGPoint] {
        [
            CGPoint(x: 300, y: 500), CGPoint(x: 900, y: 500), CGPoint(x: 900, y: frontBottomRow), CGPoint(x: 300, y: frontBottomRow),
            CGPoint(x: 400, y: 420), CGPoint(x: 800, y: 420), CGPoint(x: 800, y: backBottomRow), CGPoint(x: 400, y: backBottomRow),
        ]
    }

    @Test func aFootprintReachesTheFrameBottomOnceItsLowestCornerIsOnTheBottomRow() {
        #expect(!roomFurnitureFootprintReachesTheFrameBottom(projectedBox: box(frontBottomRow: 650, backBottomRow: 600), frameHeight: 720))
        #expect(roomFurnitureFootprintReachesTheFrameBottom(projectedBox: box(frontBottomRow: 719, backBottomRow: 600), frameHeight: 720))
        #expect(roomFurnitureFootprintReachesTheFrameBottom(projectedBox: box(frontBottomRow: 1020, backBottomRow: 800), frameHeight: 720))
        // Only a footprint corner counts: a back top corner below the frame is not the feet.
        var boxWithAHighFootprint = box(frontBottomRow: 650, backBottomRow: 600)
        boxWithAHighFootprint[4] = CGPoint(x: 400, y: 900)
        #expect(!roomFurnitureFootprintReachesTheFrameBottom(projectedBox: boxWithAHighFootprint, frameHeight: 720))
        #expect(!roomFurnitureFootprintReachesTheFrameBottom(projectedBox: [], frameHeight: 720))
    }

    @Test func theLoopTracesTheFootprintWhileItIsInTheFrame() throws {
        let projectedBox = box(frontBottomRow: 650, backBottomRow: 600)
        let loop = try #require(roomFurnitureLoopQuadrilateral(projectedBox: projectedBox, frameSize: frameSize))
        // Back left, back right, front right, front left.
        #expect(loop.clockwiseFromTopLeft == [projectedBox[7], projectedBox[6], projectedBox[2], projectedBox[3]])
    }

    @Test func theLoopKeepsTracingAFootprintThatIsMostlyInTheFrame() throws {
        // The front corners are 20 rows below the frame, but most of the footprint is in it.
        let projectedBox = box(frontBottomRow: 740, backBottomRow: 600)
        let loop = try #require(roomFurnitureLoopQuadrilateral(projectedBox: projectedBox, frameSize: frameSize))
        #expect(loop.clockwiseFromTopLeft == [projectedBox[7], projectedBox[6], projectedBox[2], projectedBox[3]])
    }

    @Test func theLoopTracesTheVisiblePartOfTheBoxWhenTheFootprintIsBelowTheFrame() throws {
        let projectedBox = box(frontBottomRow: 1020, backBottomRow: 800)
        let loop = try #require(roomFurnitureLoopQuadrilateral(projectedBox: projectedBox, frameSize: frameSize))
        // The box's outline spans columns 300 to 900 and rows 420 to 1020, and the frame cuts it at row 720.
        #expect(loop.topLeft == CGPoint(x: 300, y: 420) && loop.bottomRight == CGPoint(x: 900, y: 720))
        for corner in loop.clockwiseFromTopLeft {
            #expect(CGRect(origin: .zero, size: frameSize).contains(corner) || corner.y == frameSize.height)
        }
    }

    @Test func theLoopFallsBackToTheFootprintWhenNoPartOfTheBoxIsInTheFrame() throws {
        let projectedBox = [
            CGPoint(x: 300, y: 800), CGPoint(x: 900, y: 800), CGPoint(x: 900, y: 1020), CGPoint(x: 300, y: 1020),
            CGPoint(x: 400, y: 790), CGPoint(x: 800, y: 790), CGPoint(x: 800, y: 900), CGPoint(x: 400, y: 900),
        ]
        let loop = try #require(roomFurnitureLoopQuadrilateral(projectedBox: projectedBox, frameSize: frameSize))
        #expect(loop.clockwiseFromTopLeft == [projectedBox[7], projectedBox[6], projectedBox[2], projectedBox[3]])
    }
}

struct RoomFurnitureSpotTests {
    private let frameSize = CGSize(width: 1280, height: 720)

    /// A floor 1.1 m below a camera tilted 16 degrees down, measured at a pixel near the frame's right edge, where the
    /// bare spot search often lands.
    private func floorMeasuredNearTheRightEdge() throws -> FloorPlane {
        let up = simd_normalize(SIMD3<Double>(0, -0.96, -0.28))
        let right = SIMD3<Double>(1, 0, 0)
        let floor = FloorPlane(center: SIMD3(0, 1.1, 3.5), right: right, up: up, forward: simd_cross(up, right),
                               focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 3.7, floorTiltDegrees: 16, planeInlierShare: 1)
        return try #require(floor.moved(toAnchorPixel: CGPoint(x: 1230, y: 600)))
    }

    private func cornersAreInsideTheMargins(_ corners: [CGPoint]) -> Bool {
        let insideTheMargins = CGRect(origin: .zero, size: frameSize).insetBy(dx: frameSize.width * roomFurnitureFrameMarginShare, dy: frameSize.height * roomFurnitureFrameMarginShare)
        return corners.allSatisfy { insideTheMargins.contains($0) }
    }

    @Test func theLoopsSpotIsTheMiddleOfThePiecesFootprint() throws {
        // A 0.9 m wide, 0.8 m tall, 0.6 m deep chair: the loop goes around the floor it stands on, not its front face.
        let floor = try #require(try floorMeasuredNearTheRightEdge().moved(toAnchorPixel: CGPoint(x: 640, y: 600)))
        let placement = try #require(RoomFurniturePlacement(floor: floor, widthMeters: 0.9, heightMeters: 0.8, depthMeters: 0.6))
        let footprintCenterPixel = try #require(pinholeProjection(of: placement.footprintCenter, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360)))
        let loopCenter = try #require(roomFurnitureFootprintCenterInTheKeyframe(floor: floor, widthMeters: 0.9, heightMeters: 0.8, depthMeters: 0.6))
        // The mean of the four projected corners is within a few pixels of the projected middle at this distance.
        #expect(hypot(loopCenter.x - footprintCenterPixel.x, loopCenter.y - footprintCenterPixel.y) < 4)
    }

    @Test func aFloorMovedToAPixelMeetsThatPixelsRayOnTheSamePlane() throws {
        let floor = try floorMeasuredNearTheRightEdge()
        let moved = try #require(floor.moved(toAnchorPixel: CGPoint(x: 400, y: 650)))
        let pixel = try #require(pinholeProjection(of: moved.center, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360)))
        #expect(abs(pixel.x - 400) < 1e-6 && abs(pixel.y - 650) < 1e-6)
        #expect(abs(simd_dot(moved.center - floor.center, floor.up)) < 1e-9)
        // A pixel high above the horizon never meets the floor in front of the camera.
        #expect(floor.moved(toAnchorPixel: CGPoint(x: 640, y: 0)) == nil)
    }

    @Test func aSpotWhereTheBoxWouldLeaveTheFrameIsRefused() throws {
        let measuredFloor = try floorMeasuredNearTheRightEdge()
        let measuredBox = try #require(measuredFloor.keyframeBoxCorners(widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55))
        #expect(!cornersAreInsideTheMargins(measuredBox))

        let spot = roomFurnitureSpotWhereTheWholePieceFits(measuredFloor: measuredFloor, widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55, frameSize: frameSize, texture: nil)
        #expect(spot.wholePieceFits)
        let chosenBox = try #require(spot.floor.keyframeBoxCorners(widthMeters: 0.55, heightMeters: 0.45, depthMeters: 0.55))
        #expect(cornersAreInsideTheMargins(chosenBox))
        // On the same plane, near the lower middle.
        #expect(abs(simd_dot(spot.floor.center - measuredFloor.center, measuredFloor.up)) < 1e-9)
        let anchor = try #require(pinholeProjection(of: spot.floor.center, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360)))
        #expect(abs(anchor.x - 640) < 120)
    }

    @Test func aSpotIsNeverFartherBackThanTheMeasuredOne() throws {
        // Far enough back, a 6 m sofa would fit, but the room ends at a wall the plane does not know about.
        let measuredFloor = try floorMeasuredNearTheRightEdge()
        let spot = roomFurnitureSpotWhereTheWholePieceFits(measuredFloor: measuredFloor, widthMeters: 6, heightMeters: 0.85, depthMeters: 1, frameSize: frameSize, texture: nil)
        #expect(simd_dot(spot.floor.center, measuredFloor.forward) <= simd_dot(measuredFloor.center, measuredFloor.forward) + farthestBeyondTheMeasuredSpotMeters + 1e-9)
    }

    @Test func aPieceThatFitsOnlyWithoutTheMarginDoesNotCountAsWhole() throws {
        // The widest piece whose box fits the bare frame at some spot, which the 4 percent margin then refuses.
        let measuredFloor = try floorMeasuredNearTheRightEdge()
        var widthThatFitsOnlyTheBareFrame: Double?
        for widthCentimeters in stride(from: 200, through: 600, by: 5) {
            let width = Double(widthCentimeters) / 100
            let fitsTheBareFrame = (0...36).contains { rowIndex in
                (0...48).contains { columnIndex in
                    let anchor = CGPoint(x: 1280 * Double(columnIndex) / 48, y: 720 * (0.35 + 0.65 * Double(rowIndex) / 36))
                    guard let floor = measuredFloor.moved(toAnchorPixel: anchor),
                          simd_dot(floor.center, measuredFloor.forward) <= simd_dot(measuredFloor.center, measuredFloor.forward) + farthestBeyondTheMeasuredSpotMeters,
                          let corners = floor.keyframeBoxCorners(widthMeters: width, heightMeters: 0.5, depthMeters: 0.5) else { return false }
                    return corners.allSatisfy { CGRect(origin: .zero, size: frameSize).contains($0) }
                }
            }
            let spot = roomFurnitureSpotWhereTheWholePieceFits(measuredFloor: measuredFloor, widthMeters: width, heightMeters: 0.5, depthMeters: 0.5, frameSize: frameSize, texture: nil)
            if fitsTheBareFrame && !spot.wholePieceFits { widthThatFitsOnlyTheBareFrame = width; break }
        }
        #expect(widthThatFitsOnlyTheBareFrame != nil)
    }

    @Test func aPieceNoSpotShowsWholeStandsWhereMostOfItShows() throws {
        let measuredFloor = try floorMeasuredNearTheRightEdge()
        let spot = roomFurnitureSpotWhereTheWholePieceFits(measuredFloor: measuredFloor, widthMeters: 6, heightMeters: 2.5, depthMeters: 1.2, frameSize: frameSize, texture: nil)
        #expect(!spot.wholePieceFits)
        let measuredShare = shareOfTheBoxInsideTheFrame(projectedCorners: try #require(measuredFloor.keyframeBoxCorners(widthMeters: 6, heightMeters: 2.5, depthMeters: 1.2)), frameSize: frameSize)
        let chosenShare = shareOfTheBoxInsideTheFrame(projectedCorners: try #require(spot.floor.keyframeBoxCorners(widthMeters: 6, heightMeters: 2.5, depthMeters: 1.2)), frameSize: frameSize)
        #expect(chosenShare > measuredShare)
    }

    @Test func bareFloorWinsOverABusyPatchAtTheMiddle() throws {
        // A texture map at a quarter of the frame's size that is busy everywhere but a bare patch left of the middle.
        let mapWidth = 320, mapHeight = 180
        var texture = [Float](repeating: 400, count: mapWidth * mapHeight)
        for row in 100..<180 { for column in 70..<130 { texture[row * mapWidth + column] = 5 } }
        let map = RoomFloorTextureMap(width: mapWidth, height: mapHeight, texture: texture, cameraPixelsPerMapPixel: 4)
        let spot = roomFurnitureSpotWhereTheWholePieceFits(measuredFloor: try floorMeasuredNearTheRightEdge(), widthMeters: 0.4, heightMeters: 0.45, depthMeters: 0.4, frameSize: frameSize, texture: map)
        let anchor = try #require(pinholeProjection(of: spot.floor.center, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360)))
        #expect(spot.wholePieceFits)
        #expect((280.0...520.0).contains(anchor.x))
    }
}
