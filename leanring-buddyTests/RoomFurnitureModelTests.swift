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

struct RoomFurnitureOcclusionTests {
    @Test func theLearnerStaysInFrontUnlessThePiecesBaseIsBelowTheirFeet() {
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 500, personLowestRow: 719))
        #expect(roomFurnitureDrawsOverThePerson(itemBaseRow: 650, personLowestRow: 600))
        #expect(!roomFurnitureDrawsOverThePerson(itemBaseRow: 650, personLowestRow: nil))
    }
}
