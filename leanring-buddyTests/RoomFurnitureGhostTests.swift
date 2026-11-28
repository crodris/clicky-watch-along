//
//  RoomFurnitureGhostTests.swift
//  leanring-buddyTests
//
//  The furniture's ghost: where it stands, the drag that goes back through the tracker's turn onto the floor, the snap
//  to the wall and its release, turning with the scroll wheel, voice nudges, the timeline that draws it line by line, its
//  lines in the panel, and the phrases that place it.
//

import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import simd
@testable import Clicky

/// A floor below a camera tilted down, the anchor about 2.8 m ahead, as `RoomFurnitureModelTests` uses.
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

/// An upright wall `metersBeyond` past the floor's anchor along the floor, facing the camera.
private func wallBehind(_ floor: FloorPlane, metersBeyond: Double) -> WallPlane {
    WallPlane(
        center: floor.center + floor.forward * metersBeyond + floor.up * 1.0,
        right: floor.right,
        up: floor.up,
        focalLengthPixels: floor.focalLengthPixels,
        principalPoint: floor.principalPoint,
        distanceMeters: 4,
        wallAngleDegrees: 0,
        planeInlierShare: 0.9
    )
}

/// A sofa 2.29 m wide, 0.81 m tall, and 0.9 m deep.
private func sofaGhost(on floor: FloorPlane = floorAhead(), wall: WallPlane?) throws -> RoomFurnitureGhost {
    try #require(RoomFurnitureGhost(standingOn: floor, wall: wall, widthMeters: 2.29, heightMeters: 0.81, depthMeters: 0.9))
}

/// How far the shown box's back face is in front of the wall, along the wall's normal toward the camera.
private func backFaceGap(of ghost: RoomFurnitureGhost, wall: WallPlane) throws -> Double {
    let placement = try #require(ghost.shownPlacement)
    let wallNormal = simd_normalize(simd_cross(wall.right, wall.up))
    return placement.boxCorners[4...7].map { simd_dot($0 - wall.center, wallNormal) }.min() ?? .nan
}

private func degreesBetween(_ first: SIMD3<Double>, _ second: SIMD3<Double>) -> Double {
    acos(min(1, max(-1, simd_dot(simd_normalize(first), simd_normalize(second))))) * 180 / .pi
}

struct RoomFurnitureGhostPoseTests {
    @Test func theGhostStartsWhereTheSpotSearchPutThePieceFacingTheCamera() throws {
        let floor = floorAhead(centerX: 0.3)
        let ghost = try sofaGhost(on: floor, wall: nil)
        let ghostCorners = try #require(ghost.keyframeBoxCorners)
        let spotCorners = try #require(floor.keyframeBoxCorners(widthMeters: 2.29, heightMeters: 0.81, depthMeters: 0.9))
        for (ghostCorner, spotCorner) in zip(ghostCorners, spotCorners) {
            #expect(hypot(ghostCorner.x - spotCorner.x, ghostCorner.y - spotCorner.y) < 1e-6)
        }
        #expect(!ghost.shownPose.isSnappedToTheWall)
    }

    @Test func dragsCarryTheGhostWithThePointerWithoutAJump() throws {
        var ghost = try sofaGhost(wall: nil)
        let startingCenter = ghost.shownPose.footprintCenter
        let pressPoint = startingCenter + ghost.floor.right * 0.2
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        #expect(simd_length(ghost.shownPose.footprintCenter - startingCenter) < 1e-9)
        ghost.drag(toFloorPoint: pressPoint + ghost.floor.right * 0.5)
        #expect(simd_length(ghost.shownPose.footprintCenter - (startingCenter + ghost.floor.right * 0.5)) < 1e-9)
        ghost.release()
        #expect(!ghost.isBeingDragged)
        // A drag with nothing grabbed changes nothing.
        ghost.drag(toFloorPoint: pressPoint)
        #expect(simd_length(ghost.shownPose.footprintCenter - (startingCenter + ghost.floor.right * 0.5)) < 1e-9)
    }

    @Test func aPressOffTheGhostJumpsItThere() throws {
        var ghost = try sofaGhost(wall: nil)
        let elsewhere = ghost.floor.center + ghost.floor.right * 0.8
        ghost.grab(atFloorPoint: elsewhere, onTheGhost: false)
        #expect(simd_length(ghost.shownPose.footprintCenter - elsewhere) < 1e-9)
    }

    @Test func theGhostKeepsToTheFloor() throws {
        var ghost = try sofaGhost(wall: nil)
        ghost.grab(atFloorPoint: ghost.floor.center, onTheGhost: true)
        ghost.drag(toFloorPoint: ghost.floor.center + ghost.floor.up * 0.4)
        let height = simd_dot(ghost.shownPose.footprintCenter - ghost.floor.center, ghost.floor.up)
        #expect(abs(height) < 1e-9)
    }

    @Test func aPressOnTheGhostIsInsideItsOutline() throws {
        let ghost = try sofaGhost(wall: nil)
        let corners = try #require(ghost.keyframeBoxCorners)
        let middle = CGPoint(x: corners.map(\.x).reduce(0, +) / 8, y: corners.map(\.y).reduce(0, +) / 8)
        #expect(ghost.contains(keyframePixel: middle))
        #expect(!ghost.contains(keyframePixel: CGPoint(x: 5, y: 5)))
    }
}

struct RoomFurnitureGhostWallSnapTests {
    @Test func aGhostOnAFloorInferredFromTheWallStandsOnTheWallAndStillDragsAndSnaps() throws {
        // A laptop camera that sees only the wall: the floor is inferred 1.05 m below the camera, square to the wall.
        let wall = WallPlane(center: SIMD3(0.1, -0.1, 3.2), right: SIMD3(1, 0, 0), up: SIMD3(0, -1, 0), focalLengthPixels: 1100,
                             principalPoint: SIMD2(640, 360), distanceMeters: 3.2, wallAngleDegrees: 0, planeInlierShare: 0.9)
        let inferredFloor = try #require(FloorPlane.inferred(fromTheWall: wall, itemDepthMeters: 0.9))
        var ghost = try #require(RoomFurnitureGhost(standingOn: inferredFloor, wall: wall, widthMeters: 2.29, heightMeters: 0.81, depthMeters: 0.9))
        #expect(ghost.shownPose.isSnappedToTheWall)
        #expect(abs(try backFaceGap(of: ghost, wall: wall)) < 1e-6)
        #expect(ghost.keyframeBoxCorners != nil)
        // A drag along the wall slides it there, still on the wall.
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + SIMD3(0.6, 0, 0))
        #expect(ghost.shownPose.isSnappedToTheWall)
        #expect(abs(ghost.shownPose.footprintCenter.x - (pressPoint.x + 0.6)) < 1e-9)
        // A drag out into the room lets it go.
        ghost.drag(toFloorPoint: pressPoint + SIMD3(0.6, 0, -0.8))
        #expect(!ghost.shownPose.isSnappedToTheWall)
        // The floor under a pixel is the inferred plane's.
        let floorPoint = try #require(ghost.floorPoint(underKeyframePixel: CGPoint(x: 640, y: 650)))
        #expect(abs(simd_dot(floorPoint - inferredFloor.center, inferredFloor.up)) < 1e-9)
    }

    @Test func theBackSnapsToTheWallWithinThirtyCentimetersAndSquaresTheFront() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        // At the start the back is 0.6 m from the wall: 1.5 m less the footprint's half depth twice.
        #expect(!ghost.shownPose.isSnappedToTheWall)
        ghost.turn(byDegrees: 30)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.35)
        #expect(ghost.shownPose.isSnappedToTheWall)
        #expect(abs(try backFaceGap(of: ghost, wall: wall)) < 1e-6)
        let wallNormalTowardTheCamera = simd_normalize(simd_cross(wall.right, wall.up))
        #expect(degreesBetween(ghost.shownPose.towardTheFront, wallNormalTowardTheCamera) < 1e-6)
    }

    @Test func theBackJustOutsideThirtyCentimetersDoesNotSnap() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.29)
        #expect(!ghost.shownPose.isSnappedToTheWall)
        #expect(abs(try backFaceGap(of: ghost, wall: wall) - 0.31) < 1e-6)
    }

    @Test func aDragPastTheWallStopsAtTheWall() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 2)
        #expect(ghost.shownPose.isSnappedToTheWall)
        #expect(abs(try backFaceGap(of: ghost, wall: wall)) < 1e-6)
    }

    @Test func movingAwayReleasesTheSnapAndTheLearnersTurnComesBack() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        ghost.turn(byDegrees: 30)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.5)
        #expect(ghost.shownPose.isSnappedToTheWall)
        ghost.drag(toFloorPoint: pressPoint)
        #expect(!ghost.shownPose.isSnappedToTheWall)
    }

    @Test func noWallNeverSnaps() throws {
        var ghost = try sofaGhost(wall: nil)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + ghost.floor.forward * 3)
        #expect(!ghost.shownPose.isSnappedToTheWall)
    }

    @Test func aWallLyingFlatIsNoWall() throws {
        let floor = floorAhead()
        // A "wall" whose up lies along the floor, like a table top caught by the measurement.
        let flatWall = WallPlane(center: floor.center + floor.forward * 1.2, right: floor.right, up: floor.forward,
                                 focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 4, wallAngleDegrees: 80, planeInlierShare: 0.9)
        var ghost = try sofaGhost(on: floor, wall: flatWall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.9)
        #expect(!ghost.shownPose.isSnappedToTheWall)
    }

    @Test func aWallLeaningFarOverIsNoWall() throws {
        let floor = floorAhead()
        // A plane leaning 75 degrees from upright, such as a sloped ceiling or a table caught at an angle: its normal is
        // mostly along the floor's up, and only a little of it lies level.
        let leanRadians = 75.0 * .pi / 180
        let leaningUp = simd_normalize(floor.up * cos(leanRadians) + floor.forward * sin(leanRadians))
        let leaningWall = WallPlane(center: floor.center + floor.forward * 1.2, right: floor.right, up: leaningUp,
                                    focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 4, wallAngleDegrees: 75, planeInlierShare: 0.9)
        var ghost = try sofaGhost(on: floor, wall: leaningWall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.9)
        #expect(!ghost.shownPose.isSnappedToTheWall)
    }

    @Test func aTurnAgainstTheWallTurnsFromItsSquareAndHoldsTheSnapOff() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.5)
        ghost.release()
        let squareFront = ghost.shownPose.towardTheFront
        let snappedCenter = ghost.shownPose.footprintCenter
        ghost.turn(byDegrees: 15)
        #expect(!ghost.shownPose.isSnappedToTheWall)
        #expect(abs(degreesBetween(ghost.shownPose.towardTheFront, squareFront) - 15) < 1e-6)
        #expect(simd_length(ghost.shownPose.footprintCenter - snappedCenter) < 1e-9)
        // The next drag lets the snap apply again.
        ghost.grab(atFloorPoint: snappedCenter, onTheGhost: true)
        #expect(ghost.shownPose.isSnappedToTheWall)
    }

    @Test func aNudgeAlongTheWallStaysSnappedAndANudgeCloserPullsItOff() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.5)
        ghost.release()
        let snappedCenter = ghost.shownPose.footprintCenter
        ghost.nudge(.left, distanceMeters: 0.3, turnDegrees: 0)
        #expect(ghost.shownPose.isSnappedToTheWall)
        // Left on screen is the image's left, which is the camera's -x here.
        #expect(ghost.shownPose.footprintCenter.x < snappedCenter.x - 0.25)
        let squareFront = ghost.shownPose.towardTheFront
        ghost.nudge(.closer, distanceMeters: 0.3, turnDegrees: 0)
        #expect(!ghost.shownPose.isSnappedToTheWall)
        #expect(abs(try backFaceGap(of: ghost, wall: wall) - 0.3) < 0.02)
        // Pulled off the wall, it keeps facing out from it.
        #expect(degreesBetween(ghost.shownPose.towardTheFront, squareFront) < 2)
        // A nudge farther lets the snap apply again.
        ghost.nudge(.farther, distanceMeters: 0.1, turnDegrees: 0)
        #expect(ghost.shownPose.isSnappedToTheWall)
    }

    @Test func aNudgeOnlyTurningTurnsInPlace() throws {
        var ghost = try sofaGhost(wall: nil)
        let before = ghost.shownPose
        ghost.nudge(nil, distanceMeters: 0.3, turnDegrees: 90)
        #expect(simd_length(ghost.shownPose.footprintCenter - before.footprintCenter) < 1e-9)
        #expect(abs(degreesBetween(ghost.shownPose.towardTheFront, before.towardTheFront) - 90) < 1e-6)
    }

    @Test func aSpokenNudgeMovesAtMostThreeMetersAndTheShareInTheFrameFollowsTheMove() throws {
        var ghost = try sofaGhost(wall: nil)
        let before = ghost.shownPose.footprintCenter
        #expect(ghost.shareOfTheBoxInTheFrame > 0.99)
        ghost.nudge(.left, distanceMeters: 2e18, turnDegrees: 0)
        #expect(abs(simd_length(ghost.shownPose.footprintCenter - before) - roomFurnitureLongestNudgeMeters) < 1e-6)
        #expect(ghost.shareOfTheBoxInTheFrame < 0.99)
    }

    @Test func aPickedUpPieceKeepsThePoseItWasPlacedIn() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.5)
        let placedPose = ghost.shownPose
        let pickedUp = RoomFurnitureGhost(pickedUpFrom: ghost)
        #expect(!pickedUp.isBeingDragged)
        #expect(simd_length(pickedUp.shownPose.footprintCenter - placedPose.footprintCenter) < 1e-9)
        #expect(degreesBetween(pickedUp.shownPose.towardTheFront, placedPose.towardTheFront) < 1e-6)
    }
}

struct RoomFurnitureFacingTests {
    @Test(arguments: [
        (0.0, RoomFurnitureFacing.camera), (11, .camera), (-11, .camera), (20, .cameraSlightlyRight), (-20, .cameraSlightlyLeft),
        (60, .right), (-60, .left), (134, .right), (150, .awayFromTheCamera), (-180, .awayFromTheCamera), (350, .camera), (-340, .cameraSlightlyRight),
    ])
    func eachTurnHasAFacing(turnDegrees: Double, expectedFacing: RoomFurnitureFacing) {
        #expect(RoomFurnitureFacing(turnDegreesFromFacingTheCamera: turnDegrees) == expectedFacing)
    }

    @Test func aPositiveTurnFacesTheImagesRight() throws {
        var ghost = try sofaGhost(wall: nil)
        #expect(ghost.facing == .camera)
        ghost.turn(byDegrees: 75)
        #expect(ghost.facing == .right)
        // The front's level direction points toward +x, which the pinhole draws to the right.
        #expect(ghost.shownPose.towardTheFront.x > 0.5)
    }

    @Test func aPieceOnTheWallTellsThePainterSo() throws {
        let floor = floorAhead()
        let wall = wallBehind(floor, metersBeyond: 1.5)
        var ghost = try sofaGhost(on: floor, wall: wall)
        #expect(ghost.paintingOrientation == RoomFurniturePaintingOrientation(facing: .camera, backAgainstTheWall: false))
        let pressPoint = ghost.shownPose.footprintCenter
        ghost.grab(atFloorPoint: pressPoint, onTheGhost: true)
        ghost.drag(toFloorPoint: pressPoint + floor.forward * 0.5)
        #expect(ghost.paintingOrientation == RoomFurniturePaintingOrientation(facing: .camera, backAgainstTheWall: true))
    }
}

struct RoomFurnitureGhostDragMappingTests {
    @Test func aCurrentPixelGoesBackThroughTheTrackersTurnToTheSameFloorPoint() throws {
        let ghost = try sofaGhost(wall: nil)
        let warp = EuclideanWarp(angleRadians: 0.04, translationX: -38, translationY: 12)
        let tracked = RoomArtTrackedWarp(keyframeNumber: 3, keyframeToCurrent: warp, theRoomIsLost: false)
        let keyframePixel = CGPoint(x: 700, y: 610)
        let currentPixel = warp.apply(to: keyframePixel)
        let throughTheWarp = try #require(tracked.floorPoint(underCurrentPixel: currentPixel, of: ghost))
        let direct = try #require(ghost.floorPoint(underKeyframePixel: keyframePixel))
        #expect(simd_length(throughTheWarp - direct) < 1e-9)
        // Taking the current pixel as a keyframe pixel would land somewhere else.
        let untracked = try #require(ghost.floorPoint(underKeyframePixel: currentPixel))
        #expect(simd_length(untracked - direct) > 0.05)
    }

    @Test func aLostRoomOrAPixelAboveTheHorizonGivesNoFloorPoint() throws {
        let ghost = try sofaGhost(wall: nil)
        let lost = RoomArtTrackedWarp(keyframeNumber: 1, keyframeToCurrent: .identity, theRoomIsLost: true)
        #expect(lost.floorPoint(underCurrentPixel: CGPoint(x: 640, y: 600), of: ghost) == nil)
        let found = RoomArtTrackedWarp(keyframeNumber: 1, keyframeToCurrent: .identity, theRoomIsLost: false)
        #expect(found.floorPoint(underCurrentPixel: CGPoint(x: 640, y: -4000), of: ghost) == nil)
    }

    @Test func theInvertedWarpUndoesTheWarp() {
        let warp = EuclideanWarp(angleRadians: -0.3, translationX: 55, translationY: -21)
        let point = CGPoint(x: 312, y: 489)
        let roundTrip = warp.inverted.apply(to: warp.apply(to: point))
        #expect(hypot(roundTrip.x - point.x, roundTrip.y - point.y) < 1e-9)
    }

    @Test func anEasedWarpMovesThatShareOfTheWay() {
        let eased = EuclideanWarp.identity.eased(toward: EuclideanWarp(angleRadians: 0.2, translationX: 10, translationY: -20), share: 0.25)
        #expect(abs(eased.angleRadians - 0.05) < 1e-12 && abs(eased.translationX - 2.5) < 1e-12 && abs(eased.translationY + 5) < 1e-12)
    }
}

struct RoomFurnitureGhostPersonShareTests {
    @Test func theShareOfTheBoxThePersonCoversCountsOnlyThePersonsPixelsInsideIt() {
        // A 10 by 10 mask over a 100 by 100 frame, with the person in the left half (columns 0 to 4).
        var maskBytes = [UInt8](repeating: 0, count: 100)
        for row in 0..<10 { for column in 0..<5 { maskBytes[row * 10 + column] = 255 } }
        let frameSize = CGSize(width: 100, height: 100)
        func share(_ rect: CGRect) -> Double {
            shareOfTheOutlineThePersonCovers(
                maskBytes: maskBytes, maskWidth: 10, maskHeight: 10,
                outlineInFramePixels: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                frameSize: frameSize
            )
        }
        #expect(share(CGRect(x: 0, y: 0, width: 100, height: 100)) == 0.5)
        #expect(share(CGRect(x: 60, y: 0, width: 40, height: 100)) == 0)
        #expect(share(CGRect(x: 0, y: 0, width: 40, height: 50)) == 1)
        // An outline off the frame, or with no area, covers nothing.
        #expect(share(CGRect(x: 200, y: 200, width: 10, height: 10)) == 0)
        #expect(shareOfTheOutlineThePersonCovers(maskBytes: maskBytes, maskWidth: 10, maskHeight: 10, outlineInFramePixels: [.zero, CGPoint(x: 5, y: 5)], frameSize: frameSize) == 0)
        // A box projected past what an Int holds, as a ghost nudged absurdly far would be, is measured inside the mask
        // instead of trapping, and a corner that is not a number covers nothing.
        #expect(share(CGRect(x: -1e30, y: -1e30, width: 2e30, height: 2e30)) == 0.5)
        #expect(shareOfTheOutlineThePersonCovers(
            maskBytes: maskBytes, maskWidth: 10, maskHeight: 10,
            outlineInFramePixels: [CGPoint(x: Double.nan, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)], frameSize: frameSize
        ) == 0)
    }
}

struct RoomFurnitureScrollTurnTests {
    @Test func aWheelNotchIsOneStepEachWay() {
        var scrollTurn = RoomFurnitureScrollTurn()
        #expect(scrollTurn.steps(afterScrollingBy: 3, hasPreciseDeltas: false) == 1)
        #expect(scrollTurn.steps(afterScrollingBy: -1, hasPreciseDeltas: false) == -1)
        #expect(scrollTurn.steps(afterScrollingBy: 0, hasPreciseDeltas: false) == 0)
    }

    @Test func trackpadDeltasAddUpToAStep() {
        var scrollTurn = RoomFurnitureScrollTurn()
        #expect(scrollTurn.steps(afterScrollingBy: 10, hasPreciseDeltas: true) == 0)
        #expect(scrollTurn.steps(afterScrollingBy: 10, hasPreciseDeltas: true) == 0)
        #expect(scrollTurn.steps(afterScrollingBy: 10, hasPreciseDeltas: true) == 1)
        #expect(scrollTurn.steps(afterScrollingBy: 60, hasPreciseDeltas: true) == 2)
    }

    @Test func aChangeOfDirectionDropsThePointsSavedTheOtherWay() {
        var scrollTurn = RoomFurnitureScrollTurn()
        _ = scrollTurn.steps(afterScrollingBy: 25, hasPreciseDeltas: true)
        #expect(scrollTurn.steps(afterScrollingBy: -10, hasPreciseDeltas: true) == 0)
        #expect(scrollTurn.leftoverPoints == -10)
    }
}

struct RoomFurnitureGhostDrawTimelineTests {
    typealias Timeline = RoomFurnitureGhostDrawTimeline

    @Test func theWholeDrawTakesAboutASecondAndAHalf() {
        #expect((1.2...1.5).contains(Timeline.totalSeconds))
    }

    @Test func theFirstFrameOfTheDrawIsTheTracerOnTheFootprintsFirstCorner() {
        // No loop shows while the floor is measured, so the ghost's tracer starts on the footprint with nothing drawn yet.
        let frame = Timeline.frame(secondsSinceBegan: 0)
        #expect(frame.tracer == .onTheFootprint(share: 0))
        #expect(frame.footprintShare == 0)
        #expect(frame.postShares == [0, 0, 0, 0] && frame.topShare == 0 && frame.fillShare == 0 && !frame.pillIsShown)
    }

    @Test func theFootprintDrawsBeforeAnyPost() {
        let midFootprint = Timeline.frame(secondsSinceBegan: Timeline.footprintSeconds * 0.4)
        #expect(abs(midFootprint.footprintShare - 0.4) < 1e-9)
        #expect(midFootprint.tracer == .onTheFootprint(share: midFootprint.footprintShare))
        #expect(midFootprint.postShares == [0, 0, 0, 0])
        #expect(midFootprint.fillShare == 0 && !midFootprint.pillIsShown)
    }

    @Test func thePostsGrowOneAfterAnother() {
        let secondPostHalfway = Timeline.footprintSeconds + Timeline.secondsPerPost * 1.5
        let frame = Timeline.frame(secondsSinceBegan: secondPostHalfway)
        #expect(frame.footprintShare == 1)
        #expect(frame.postShares[0] == 1)
        #expect(abs(frame.postShares[1] - 0.5) < 1e-9)
        #expect(frame.postShares[2] == 0 && frame.postShares[3] == 0)
        #expect(frame.topShare == 0)
        guard case .onAPost(let index, let share) = frame.tracer else {
            Issue.record("the tracer should ride the second post")
            return
        }
        #expect(index == 1 && abs(share - 0.5) < 1e-9)
    }

    @Test func theTopDrawsAfterTheLastPostThenTheFillAndThePillComeIn() {
        let postsEnd = Timeline.footprintSeconds + Timeline.secondsPerPost * 4
        let midTop = Timeline.frame(secondsSinceBegan: postsEnd + Timeline.topSeconds / 2)
        #expect(midTop.postShares == [1, 1, 1, 1])
        #expect(abs(midTop.topShare - 0.5) < 1e-9)
        #expect(midTop.fillShare == 0 && !midTop.pillIsShown)
        let midFill = Timeline.frame(secondsSinceBegan: postsEnd + Timeline.topSeconds + Timeline.fillSeconds / 2)
        #expect(midFill.topShare == 1)
        #expect(abs(midFill.fillShare - 0.5) < 1e-9)
        #expect(midFill.pillIsShown)
        #expect(midFill.tracer == .gone)
        #expect(Timeline.frame(secondsSinceBegan: 10) == .whole)
    }

    @Test func theGlowBreathesAndHoldsStillWithReduceMotion() {
        let quarterBreath = RoomFurnitureGhostGlow.secondsPerBreath / 4
        #expect(RoomFurnitureGhostGlow.fillOpacity(secondsSinceDrawn: quarterBreath, reduceMotionIsOn: false) > RoomFurnitureGhostGlow.restingFillOpacity)
        #expect(RoomFurnitureGhostGlow.fillOpacity(secondsSinceDrawn: quarterBreath, reduceMotionIsOn: true) == RoomFurnitureGhostGlow.restingFillOpacity)
    }
}

/// The camera frame and the panel the ghost's lines are drawn in, as the room art panel's default size shows them.
private let ghostCameraFrame = CGSize(width: 1280, height: 720)
private let ghostPanelSize = CGSize(width: 960, height: 540)
private func ghostPanelFit() -> RoomArtVideoFit { RoomArtVideoFit(cameraSize: ghostCameraFrame, viewSize: ghostPanelSize) }

/// The box with the corners at these keyframe pixels, every corner `depth` meters from the camera, as `floorAhead`'s pinhole
/// sees them, so a test names the outline it wants in pixels.
private func boxCornersInCameraSpace(atPixels pixels: [CGPoint], depth: Double = 3) -> [SIMD3<Double>] {
    pixels.map { SIMD3((Double($0.x) - 640) * depth / 1100, (Double($0.y) - 360) * depth / 1100, depth) }
}

private func linesOfTheBox(_ corners: [SIMD3<Double>], warp: EuclideanWarp = .identity) -> RoomFurnitureGhostLines? {
    RoomFurnitureGhostLines(boxCornersInCameraSpace: corners, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), keyframeToCurrent: warp, fit: ghostPanelFit(), cameraSize: ghostCameraFrame)
}

/// A floor 1.05 m below a level camera, which is where a laptop's floor inferred from the wall stands.
private func floorBelowALevelCamera() -> FloorPlane {
    let up = SIMD3<Double>(0, -1, 0), right = SIMD3<Double>(1, 0, 0)
    return FloorPlane(center: SIMD3(0, 1.05, 2.0), right: right, up: up, forward: simd_cross(up, right), focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), distanceMeters: 2.2, floorTiltDegrees: 0, planeInlierShare: 0.95)
}

/// A box of `RoomFurniturePlacement.boxCorners` order from x -1 to 1 m, its bottom 0.5 m below the camera and its top 0.3 m
/// above it, the front face `frontDepth` meters in front of the camera (negative is behind it) and the back face 3 m in front.
private func box(frontDepth: Double) -> [SIMD3<Double>] {
    func corner(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x, y, z) }
    return [
        corner(-1, -0.3, frontDepth), corner(1, -0.3, frontDepth), corner(1, 0.5, frontDepth), corner(-1, 0.5, frontDepth),
        corner(-1, -0.3, 3), corner(1, -0.3, 3), corner(1, 0.5, 3), corner(-1, 0.5, 3),
    ]
}

/// The front face 1 m behind the camera.
private func boxWithItsFrontBehindTheCamera() -> [SIMD3<Double>] { box(frontDepth: -1) }

/// The front face 0.11 m in front of the camera, just past the near plane, so its corners project 10,000 points away.
private func boxWithItsFrontJustPastTheNearPlane() -> [SIMD3<Double>] { box(frontDepth: 0.11) }

/// Every point of the lines, for a test that checks where they are.
private func everyPoint(of lines: RoomFurnitureGhostLines) -> [CGPoint] {
    (lines.footprintEdges + lines.posts + lines.topEdges).compactMap { $0 }.flatMap { [$0.start, $0.end] } + lines.footprintFill
}

/// The rectangle every line stays in: the frame in the panel and the drawing margin around it.
private func rectangleTheLinesStayIn(_ lines: RoomFurnitureGhostLines) -> CGRect {
    lines.videoRect.insetBy(dx: -RoomFurnitureGhostLines.drawingMarginInPoints - 1e-6, dy: -RoomFurnitureGhostLines.drawingMarginInPoints - 1e-6)
}

struct RoomFurnitureGhostLinesTests {
    @Test func theLinesFollowTheTrackersTurnIntoThePanel() throws {
        let ghost = try sofaGhost(wall: nil)
        let corners = try #require(ghost.keyframeBoxCorners)
        let warp = EuclideanWarp(angleRadians: 0, translationX: 20, translationY: -10)
        let lines = try #require(RoomFurnitureGhostLines(ghost: ghost, keyframeToCurrent: warp, fit: ghostPanelFit(), cameraSize: ghostCameraFrame))
        // Front left bottom is corner 3, shifted by the warp and scaled by 0.75 into the panel.
        let frontEdge = try #require(lines.footprintEdges[0])
        #expect(abs(frontEdge.start.x - (corners[3].x + 20) * 0.75) < 1e-9)
        #expect(abs(frontEdge.start.y - (corners[3].y - 10) * 0.75) < 1e-9)
        // The last post ends where the top starts, so the tracer never jumps there.
        #expect(lines.posts[3]?.end == lines.topEdges[0]?.start)
        // Each post rises from its footprint corner.
        for (post, footprintEdge) in zip(lines.posts, lines.footprintEdges) { #expect(post?.start == footprintEdge?.start) }
        // A box wholly in the frame and in front of the camera loses nothing to the cuts.
        #expect((lines.footprintEdges + lines.posts + lines.topEdges).allSatisfy { $0 != nil })
        #expect(lines.pillCenter.y < (lines.topEdges.compactMap { $0 }.flatMap { [$0.start.y, $0.end.y] }.min() ?? 0))
    }

    @Test func theThemesGlyphTracesEachLineAndLeavesWhenTheyAreDrawn() throws {
        let ghost = try sofaGhost(wall: nil)
        let lines = try #require(RoomFurnitureGhostLines(ghost: ghost, keyframeToCurrent: .identity, fit: ghostPanelFit(), cameraSize: ghostCameraFrame))
        func ink(_ tracer: RoomFurnitureGhostDrawTimeline.Tracer) -> CGPoint? {
            RoomFurnitureGhostCanvas.tracerPlacement(for: tracer, lines: lines, cursorFacing: .followsMouseMovement)?.inkPoint
        }
        func isNear(_ point: CGPoint?, _ expected: CGPoint) -> Bool { point.map { hypot($0.x - expected.x, $0.y - expected.y) < 0.5 } ?? false }
        // It goes around the footprint from its first corner, up each post, and around the top.
        #expect(isNear(ink(.onTheFootprint(share: 0)), try #require(lines.footprintEdges[0]).start))
        let post = try #require(lines.posts[1])
        #expect(isNear(ink(.onAPost(index: 1, share: 0.5)), CGPoint(x: (post.start.x + post.end.x) / 2, y: (post.start.y + post.end.y) / 2)))
        #expect(isNear(ink(.onTheTop(share: 0)), try #require(lines.topEdges[0]).start))
        // A volleyball faces up a post, the way the line runs, and the glyph is gone once the lines are drawn.
        let onThePost = try #require(RoomFurnitureGhostCanvas.tracerPlacement(for: .onAPost(index: 1, share: 0.5), lines: lines, cursorFacing: .followsMouseMovement))
        let postHeading = atan2(Double(post.end.y - post.start.y), Double(post.end.x - post.start.x)) * 180 / .pi + 90
        #expect(abs(onThePost.rotationDegrees - postHeading) < 1)
        #expect(ink(.gone) == nil)
    }

    @Test func thePillStaysOverTheVisiblePartOfATopThatRunsOffTheFrame() throws {
        // A top outline whose left half is past the frame's left edge, as for a long sofa dragged near the camera.
        let boxCorners = boxCornersInCameraSpace(atPixels: [
            CGPoint(x: -600, y: 300), CGPoint(x: 700, y: 330), CGPoint(x: 700, y: 700), CGPoint(x: -600, y: 680),
            CGPoint(x: -300, y: 200), CGPoint(x: 900, y: 230), CGPoint(x: 900, y: 500), CGPoint(x: -300, y: 480),
        ])
        let lines = try #require(linesOfTheBox(boxCorners))
        let pill = lines.pillCenter
        // Inside the frame, over the visible part of the top (x from 0 to 675 in the panel), and above its highest point
        // there, about 155 points down.
        #expect(lines.videoRect.insetBy(dx: 1, dy: 1).contains(pill))
        #expect(pill.x > 200 && pill.x < 600)
        #expect(pill.y < 150)
    }

    @Test func thePillStaysWholeInsideTheFrameAndAboveTheControlsNearAnyEdge() throws {
        // A box at the frame's right edge and one low near its bottom left corner.
        let atTheRightEdge = [
            CGPoint(x: 1200, y: 300), CGPoint(x: 1279, y: 300), CGPoint(x: 1279, y: 500), CGPoint(x: 1200, y: 500),
            CGPoint(x: 1210, y: 250), CGPoint(x: 1279, y: 250), CGPoint(x: 1279, y: 450), CGPoint(x: 1210, y: 450),
        ]
        let lowAtTheLeft = [
            CGPoint(x: 0, y: 690), CGPoint(x: 80, y: 690), CGPoint(x: 80, y: 719), CGPoint(x: 0, y: 719),
            CGPoint(x: 5, y: 680), CGPoint(x: 75, y: 680), CGPoint(x: 75, y: 710), CGPoint(x: 5, y: 710),
        ]
        // A tall piece whose top runs off the frame near the Close button.
        let tallAtTheTopRight = [
            CGPoint(x: 1150, y: -200), CGPoint(x: 1279, y: -200), CGPoint(x: 1279, y: 400), CGPoint(x: 1150, y: 400),
            CGPoint(x: 1160, y: -260), CGPoint(x: 1279, y: -260), CGPoint(x: 1279, y: 350), CGPoint(x: 1160, y: 350),
        ]
        for pixels in [atTheRightEdge, lowAtTheLeft, tallAtTheTopRight] {
            let lines = try #require(linesOfTheBox(boxCornersInCameraSpace(atPixels: pixels)))
            let pillRect = CGRect(
                x: lines.pillCenter.x - RoomFurnitureGhostLines.pillHalfWidthInPoints, y: lines.pillCenter.y - RoomFurnitureGhostLines.pillHalfHeightInPoints,
                width: RoomFurnitureGhostLines.pillHalfWidthInPoints * 2, height: RoomFurnitureGhostLines.pillHalfHeightInPoints * 2
            )
            #expect(lines.videoRect.contains(pillRect))
            #expect(pillRect.maxY <= lines.videoRect.maxY - RoomFurnitureGhostLines.controlsHeightAtTheBottomInPoints)
            #expect(pillRect.minY >= lines.videoRect.minY + RoomFurnitureGhostLines.controlsHeightAtTheTopInPoints)
        }
    }

    @Test func noLinesWithoutEightCornersOrAFrame() {
        let corners = boxCornersInCameraSpace(atPixels: Array(repeating: CGPoint(x: 640, y: 360), count: 8))
        let noFit = RoomArtVideoFit(cameraSize: .zero, viewSize: ghostPanelSize)
        #expect(RoomFurnitureGhostLines(boxCornersInCameraSpace: corners, focalLengthPixels: 1100, principalPoint: SIMD2(640, 360), keyframeToCurrent: .identity, fit: noFit, cameraSize: .zero) == nil)
        #expect(linesOfTheBox(Array(corners.prefix(4))) == nil)
    }

    @Test func theSizePillSaysWidthAndHeightInInches() {
        #expect(roomFurnitureGhostSizePillText(widthMeters: 2.286, heightMeters: 0.813, widthIsMeasuredFromThePhoto: false) == "90\u{2033} wide · 32\u{2033} tall")
    }
}

/// A sofa wider than the camera's view, which the learner drags toward the camera: its front corners come within a few
/// centimeters of the camera plane, where the pinhole sends them thousands of panel points away. The first fix of this
/// bug drew straight lines between those projected points.
struct RoomFurnitureGhostLinesBeyondTheViewTests {
    /// The sofa dragged so its front corners are `frontMetersFromTheCamera` in front of a level camera (negative: behind it).
    private func sofaWithItsFrontAt(_ frontMetersFromTheCamera: Double) throws -> RoomFurnitureGhost {
        var ghost = try #require(RoomFurnitureGhost(standingOn: floorBelowALevelCamera(), wall: nil, widthMeters: 2.29, heightMeters: 0.81, depthMeters: 0.9))
        ghost.grab(atFloorPoint: SIMD3(0, 1.05, frontMetersFromTheCamera + 0.45), onTheGhost: false)
        return ghost
    }

    @Test(arguments: [3.0, 1.5, 0.6, 0.3, 0.15, 0.11, 0.05, 0, -0.15, -1.0])
    func everyLineStaysNearThePanelHoweverCloseTheSofaIs(frontMetersFromTheCamera: Double) throws {
        let ghost = try sofaWithItsFrontAt(frontMetersFromTheCamera)
        let lines = try #require(RoomFurnitureGhostLines(ghost: ghost, keyframeToCurrent: .identity, fit: ghostPanelFit(), cameraSize: ghostCameraFrame))
        let bounds = rectangleTheLinesStayIn(lines)
        let points = everyPoint(of: lines)
        #expect(points.allSatisfy { bounds.contains($0) }, "a line left the panel: \(points.filter { !bounds.contains($0) })")
        #expect(bounds.contains(lines.pillCenter))
    }

    @Test func aBoxWithACornerBehindTheCameraKeepsItsVisibleEdges() throws {
        // The old code gave up on the whole ghost when one corner was behind the camera.
        let lines = try #require(linesOfTheBox(boxWithItsFrontBehindTheCamera()))
        // The edges that lie wholly behind the camera are gone: the front footprint edge and the front top edge.
        #expect(lines.footprintEdges[0] == nil)
        #expect(lines.topEdges[1] == nil)
        // The back top edge is whole: (1, -0.3, 3) and (-1, -0.3, 3) at 1100 pixels of focal length, in panel points.
        let backTopEdge = try #require(lines.topEdges[3])
        #expect(hypot(backTopEdge.start.x - 755, backTopEdge.start.y - 187.5) < 1e-6)
        #expect(hypot(backTopEdge.end.x - 205, backTopEdge.end.y - 187.5) < 1e-6)
        // The left top edge crosses the near plane. Its part in front of the camera is a straight line in the panel, the
        // one through the projections of its two ends, so the clipped line runs along it.
        let leftTopEdge = try #require(lines.topEdges[0])
        let backLeftTopInThePanel = CGPoint(x: 205, y: 187.5)
        let nearPlanePointInThePanel = CGPoint(x: (640 - 1 * 1100 / 0.1) * 0.75, y: (360 - 0.3 * 1100 / 0.1) * 0.75)
        #expect(hypot(leftTopEdge.start.x - backLeftTopInThePanel.x, leftTopEdge.start.y - backLeftTopInThePanel.y) < 1e-6)
        let alongTheLine = (leftTopEdge.end.x - leftTopEdge.start.x) * (nearPlanePointInThePanel.y - leftTopEdge.start.y)
            - (leftTopEdge.end.y - leftTopEdge.start.y) * (nearPlanePointInThePanel.x - leftTopEdge.start.x)
        #expect(abs(alongTheLine) / leftTopEdge.length / hypot(nearPlanePointInThePanel.x - leftTopEdge.start.x, nearPlanePointInThePanel.y - leftTopEdge.start.y) < 1e-6)
        // Its far end was 11,000 panel points away, and it now ends where it leaves the drawing rectangle.
        let drawingRect = lines.videoRect.insetBy(dx: -RoomFurnitureGhostLines.drawingMarginInPoints, dy: -RoomFurnitureGhostLines.drawingMarginInPoints)
        #expect(abs(leftTopEdge.end.x - drawingRect.minX) < 1e-6 || abs(leftTopEdge.end.y - drawingRect.minY) < 1e-6)
        // The pill sits over the part of the top that shows.
        #expect(lines.videoRect.contains(lines.pillCenter))
        let bounds = rectangleTheLinesStayIn(lines)
        #expect(everyPoint(of: lines).allSatisfy { bounds.contains($0) })
    }

    @Test func aBoxWhollyBehindTheCameraDrawsNothingAndTheGhostStillHasAPill() throws {
        let corners = boxCornersInCameraSpace(atPixels: Array(repeating: CGPoint(x: 640, y: 360), count: 8)).map { SIMD3($0.x, $0.y, -2) }
        let lines = try #require(linesOfTheBox(corners))
        #expect((lines.footprintEdges + lines.posts + lines.topEdges).allSatisfy { $0 == nil })
        #expect(lines.footprintFill.isEmpty)
        #expect(lines.videoRect.contains(lines.pillCenter))
        #expect(RoomFurnitureGhostCanvas.tracerPlacement(for: .onTheFootprint(share: 0.5), lines: lines, cursorFacing: .pointerAngle) == nil)
    }

    @Test func theGlyphStaysOnTheLinesThatShowWhileTheFootprintDrawsOn() throws {
        let lines = try #require(RoomFurnitureGhostLines(ghost: try sofaWithItsFrontAt(0.15), keyframeToCurrent: .identity, fit: ghostPanelFit(), cameraSize: ghostCameraFrame))
        let bounds = rectangleTheLinesStayIn(lines)
        let tracers: [RoomFurnitureGhostDrawTimeline.Tracer] =
            (0...10).map { .onTheFootprint(share: Double($0) / 10) } + (0...3).map { .onAPost(index: $0, share: 0.5) } + (0...10).map { .onTheTop(share: Double($0) / 10) }
        for tracer in tracers {
            // A line cut away entirely has no glyph, and every other one stays inside the drawing rect.
            if let placement = RoomFurnitureGhostCanvas.tracerPlacement(for: tracer, lines: lines, cursorFacing: .followsMouseMovement) {
                #expect(bounds.contains(placement.inkPoint), "the glyph left the panel at \(tracer)")
            }
        }
    }
}

struct RoomFurnitureGhostLineCuttingTests {
    @Test func aSegmentInFrontOfTheCameraIsKeptAsItIs() throws {
        let start = SIMD3<Double>(1, 2, 3), end = SIMD3<Double>(-1, 0.5, 0.2)
        let kept = try #require(roomFurnitureGhostSegmentInFrontOfTheCamera(from: start, to: end))
        #expect(kept.start == start && kept.end == end)
    }

    @Test func aSegmentCrossingTheNearPlaneIsCutWhereItCrossesInEitherDirection() throws {
        let behind = SIMD3<Double>(-2, 1, -1), inFront = SIMD3<Double>(2, -1, 3)
        let forwards = try #require(roomFurnitureGhostSegmentInFrontOfTheCamera(from: behind, to: inFront, nearPlaneMeters: 0.5))
        #expect(forwards.end == inFront)
        #expect(abs(forwards.start.z - 0.5) < 1e-12)
        // The cut point is on the segment: one quarter and a half of the way along (z from -1 to 3 reaches 0.5 at 3/8).
        #expect(simd_length(forwards.start - (behind + (inFront - behind) * 0.375)) < 1e-12)
        let backwards = try #require(roomFurnitureGhostSegmentInFrontOfTheCamera(from: inFront, to: behind, nearPlaneMeters: 0.5))
        #expect(backwards.start == inFront)
        #expect(simd_length(backwards.end - forwards.start) < 1e-12)
    }

    @Test func aSegmentWhollyBehindTheNearPlaneOrNotANumberIsGone() {
        #expect(roomFurnitureGhostSegmentInFrontOfTheCamera(from: SIMD3(0, 0, -1), to: SIMD3(1, 1, 0.05)) == nil)
        #expect(roomFurnitureGhostSegmentInFrontOfTheCamera(from: SIMD3(.nan, 0, 1), to: SIMD3(1, 1, 2)) == nil)
        #expect(roomFurnitureGhostSegmentInFrontOfTheCamera(from: SIMD3(0, 0, 1), to: SIMD3(.infinity, 1, 2)) == nil)
    }

    @Test func aPolygonIsCutToTheNearPlaneAndKeepsItsCornersInFront() {
        let square: [SIMD3<Double>] = [SIMD3(-1, 0, 2), SIMD3(1, 0, 2), SIMD3(1, 0, -2), SIMD3(-1, 0, -2)]
        let cut = roomFurnitureGhostPolygonInFrontOfTheCamera(square, nearPlaneMeters: 0.5)
        #expect(cut.count == 4)
        #expect(cut.allSatisfy { $0.z >= 0.5 - 1e-12 })
        #expect(cut.contains(SIMD3(-1, 0, 2)) && cut.contains(SIMD3(1, 0, 2)))
        #expect(roomFurnitureGhostPolygonInFrontOfTheCamera(square.map { SIMD3($0.x, $0.y, -abs($0.z) - 1) }).isEmpty)
    }

    @Test func aSegmentInsideTheRectangleComesBackExactlyAndOneOutsideIsGone() throws {
        let rectangle = CGRect(x: 0, y: 0, width: 100, height: 50)
        let inside = try #require(roomFurnitureGhostSegment(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 40), clippedTo: rectangle))
        #expect(inside.start == CGPoint(x: 10, y: 10) && inside.end == CGPoint(x: 90, y: 40))
        #expect(roomFurnitureGhostSegment(from: CGPoint(x: -50, y: 10), to: CGPoint(x: -10, y: 40), clippedTo: rectangle) == nil)
        #expect(roomFurnitureGhostSegment(from: CGPoint(x: CGFloat.nan, y: 10), to: CGPoint(x: 10, y: 40), clippedTo: rectangle) == nil)
        // Past each corner, a line that never touches the rectangle.
        #expect(roomFurnitureGhostSegment(from: CGPoint(x: -100, y: 40), to: CGPoint(x: 40, y: 200), clippedTo: rectangle) == nil)
    }

    @Test func aSegmentThroughTheRectangleIsCutAtItsBordersAlongTheSameLine() throws {
        let rectangle = CGRect(x: 0, y: 0, width: 100, height: 50)
        let across = try #require(roomFurnitureGhostSegment(from: CGPoint(x: -1000, y: 25), to: CGPoint(x: 5000, y: 25), clippedTo: rectangle))
        #expect(across.start == CGPoint(x: 0, y: 25) && across.end == CGPoint(x: 100, y: 25))
        let slanted = try #require(roomFurnitureGhostSegment(from: CGPoint(x: -50, y: -50), to: CGPoint(x: 150, y: 100), clippedTo: rectangle))
        // The line is y = 0.75 x - 12.5, which enters at y = 0 and leaves at y = 50, where x is 250 / 3.
        #expect(abs(slanted.start.y) < 1e-9 && abs(slanted.start.x - 50.0 / 3) < 1e-9)
        #expect(abs(slanted.end.y - 50) < 1e-9 && abs(slanted.end.x - 250.0 / 3) < 1e-9)
        let vertical = try #require(roomFurnitureGhostSegment(from: CGPoint(x: 30, y: -500), to: CGPoint(x: 30, y: 500), clippedTo: rectangle))
        #expect(vertical.start == CGPoint(x: 30, y: 0) && vertical.end == CGPoint(x: 30, y: 50))
    }
}

/// The ghost's lines drawn at 2x for a sofa wider than the view, which `CLICKY_RENDER_DUMP_DIR` also writes as PNGs.
@MainActor
struct RoomFurnitureGhostRenderTests {
    private func render(_ lines: RoomFurnitureGhostLines, named name: String) async throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let padding: CGFloat = 200
        let canvas = RoomFurnitureGhostCanvas(lines: lines, frame: .whole, color: Color(hex: "#F97316"), fillOpacity: RoomFurnitureGhostGlow.restingFillOpacity)
        // The canvas sits in the middle of a larger, empty area, so a line drawn past the panel would show there.
        let view = canvas.frame(width: ghostPanelSize.width, height: ghostPanelSize.height)
            .padding(padding)
            .background(Color(white: 0.12))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        if let dumpFolder = ProcessInfo.processInfo.environment["CLICKY_RENDER_DUMP_DIR"],
           let pngData = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try pngData.write(to: URL(fileURLWithPath: dumpFolder).appendingPathComponent("\(name).png"))
        }
        // A CGImage never changes after the render, so the detached task may read it.
        nonisolated(unsafe) let imageToRead = image
        let bytes = try #require(await Task.detached { () -> [UInt8]? in
            var bytes = [UInt8](repeating: 0, count: imageToRead.width * imageToRead.height * 4)
            let didDraw: Bool = bytes.withUnsafeMutableBytes { buffer in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: imageToRead.width, height: imageToRead.height, bitsPerComponent: 8, bytesPerRow: imageToRead.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else { return false }
                context.draw(imageToRead, in: CGRect(x: 0, y: 0, width: imageToRead.width, height: imageToRead.height))
                return true
            }
            return didDraw ? bytes : nil
        }.value)
        return (image.width, image.height, bytes)
    }

    /// The pixels that are not the backdrop, as a rectangle in points from the render's top left, or nil when it is all backdrop.
    private func drawnBounds(width: Int, height: Int, bytes: [UInt8]) async -> CGRect? {
        await Task.detached {
            var left = width, right = -1, top = height, bottom = -1
            // The backdrop is whatever the top left pixel is, since the padding around the canvas is empty.
            let backdrop = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
            for row in 0..<height {
                for column in 0..<width {
                    let offset = (row * width + column) * 4
                    if abs(Int(bytes[offset]) - backdrop.0) > 3 || abs(Int(bytes[offset + 1]) - backdrop.1) > 3 || abs(Int(bytes[offset + 2]) - backdrop.2) > 3 {
                        left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
                    }
                }
            }
            return right < 0 ? nil : CGRect(x: Double(left) / 2, y: Double(top) / 2, width: Double(right - left + 1) / 2, height: Double(bottom - top + 1) / 2)
        }.value
    }

    @Test(arguments: [
        ("ghost-front-behind-the-camera", boxWithItsFrontBehindTheCamera()),
        ("ghost-wide-and-near-the-plane", boxWithItsFrontJustPastTheNearPlane()),
    ])
    func aBoxPastTheCameraDrawsInsideThePanelAndItsMargin(name: String, corners: [SIMD3<Double>]) async throws {
        let lines = try #require(linesOfTheBox(corners))
        let drawing = try await render(lines, named: name)
        let bounds = try #require(await drawnBounds(width: drawing.width, height: drawing.height, bytes: drawing.bytes))
        // The panel starts 200 points in. The strokes may reach their margin and half their width past it, and the blurred
        // glow a few points more, so the whole drawing stays within 80 points of the panel.
        let panel = CGRect(x: 200, y: 200, width: ghostPanelSize.width, height: ghostPanelSize.height)
        #expect(panel.insetBy(dx: -80, dy: -80).contains(bounds), "drawn up to \(bounds), the panel is \(panel)")
        // Something shows inside the panel itself.
        #expect(bounds.intersects(panel))
    }
}

struct RoomFurnitureGhostVoiceTests {
    @Test(arguments: ["right there", "Right there.", "put it there", "place it", "That's good", "that\u{2019}s good", "okay, right there please", "perfect, put it right there"])
    func phrasesThatPlaceIt(transcript: String) {
        #expect(RoomArtConfirmPhrase.matches(transcript))
    }

    @Test(arguments: ["right there is the window", "put it there and make it blue", "what's good about it", "place it on the left", "move it to the left", "there"])
    func phrasesThatDoNot(transcript: String) {
        #expect(!RoomArtConfirmPhrase.matches(transcript))
    }

    @Test func thePhraseRunsAheadOfTheRouterOnlyWhileSomethingWaitsToBeConfirmed() {
        #expect(RoomArtConfirmPhrase.runsAheadOfTheRouter(matches: true, somethingWaitsToBeConfirmed: true, quizQuestionIsOpen: false, themeStudioIsOpen: false))
        #expect(!RoomArtConfirmPhrase.runsAheadOfTheRouter(matches: true, somethingWaitsToBeConfirmed: false, quizQuestionIsOpen: false, themeStudioIsOpen: false))
        #expect(!RoomArtConfirmPhrase.runsAheadOfTheRouter(matches: true, somethingWaitsToBeConfirmed: true, quizQuestionIsOpen: true, themeStudioIsOpen: false))
        #expect(!RoomArtConfirmPhrase.runsAheadOfTheRouter(matches: true, somethingWaitsToBeConfirmed: true, quizQuestionIsOpen: false, themeStudioIsOpen: true))
        #expect(!RoomArtConfirmPhrase.runsAheadOfTheRouter(matches: false, somethingWaitsToBeConfirmed: true, quizQuestionIsOpen: false, themeStudioIsOpen: false))
    }

    @Test func theMoveChipSaysWhereItGoes() {
        #expect(roomFurnitureMoveChipPhrase(direction: .left, turnDegrees: nil) == "Moving it left")
        #expect(roomFurnitureMoveChipPhrase(direction: nil, turnDegrees: 45) == "Turning it")
        #expect(roomFurnitureMoveChipPhrase(direction: nil, turnDegrees: 0) == nil)
    }
}

struct RoomFurnitureGhostVoiceRoutingTests {
    /// The room art panel on a store page: no scene, no video, nothing else for the router to command.
    private func storePageContext(ghostShows: Bool) -> TranscriptRouteContext {
        TranscriptRouteContext(
            themeStudioIsOpen: false,
            phaseIsWaitingForAQuizAnswer: false,
            liveSceneIsUpWithNoQuizQuestion: false,
            sceneIsBuilding: false,
            sceneIsOnScreen: false,
            brainTakesEveryRequest: false,
            backgroundSceneIsReady: false,
            taskAnswerIsReady: false,
            approvalIsWaiting: false,
            backgroundAgentIsRunning: false,
            backgroundAgentsArePaused: false,
            furnitureGhostShows: ghostShows
        )
    }

    @Test func rightTherePlacesTheGhostWithNoModelCallAndOtherWordsReachTheRouter() {
        #expect(transcriptRoute(for: "right there", in: storePageContext(ghostShows: true), videoIsInFront: { false }) == .confirmTheRoomArt)
        #expect(transcriptRoute(for: "move it a bit to the left", in: storePageContext(ghostShows: true), videoIsInFront: { false }) == .voiceCommandRouter)
        // With no ghost, a store page has nothing for the router, and "right there" is a question for the keyword path.
        #expect(transcriptRoute(for: "right there", in: storePageContext(ghostShows: false), videoIsInFront: { false }) == .keywordPath)
        #expect(transcriptRoute(for: "move it a bit to the left", in: storePageContext(ghostShows: false), videoIsInFront: { false }) == .keywordPath)
    }

    @Test func whileTheGhostShowsARoomPhraseReachesTheRouterAndNeverClosesTheGhost() {
        #expect(transcriptRoute(for: "put it on the table", in: storePageContext(ghostShows: true), videoIsInFront: { false }) == .voiceCommandRouter)
        #expect(transcriptRoute(for: "put this lamp on my desk", in: storePageContext(ghostShows: true), videoIsInFront: { false }) == .voiceCommandRouter)
        // With no ghost, the same words open the panel for a new item.
        #expect(transcriptRoute(for: "put this lamp on my desk", in: storePageContext(ghostShows: false), videoIsInFront: { false }) == .keywordBranch(.showArtInMyRoom))
    }

    @Test func onTheTableNamesAPaintedTableOnlyWhileAPlacedItemKeepsTheRoom() {
        var keptRoom = storePageContext(ghostShows: false)
        keptRoom.aRoomArtItemKeepsTheRoom = true
        #expect(transcriptRoute(for: "how would this lamp look on the table", in: keptRoom, videoIsInFront: { false }) == .keywordBranch(.showArtInMyRoom))
        // With no panel, "put the numbers on the table" is no request for the camera: a question on a store page, and the
        // router's during a video lesson.
        #expect(transcriptRoute(for: "put the numbers on the table", in: storePageContext(ghostShows: false), videoIsInFront: { false }) == .keywordPath)
        #expect(transcriptRoute(for: "put the numbers on the table", in: storePageContext(ghostShows: false), videoIsInFront: { true }) == .voiceCommandRouter)
    }

    @Test func theRouterTakesTheGhostsCommandsButNotAQuizAnswerOrABuildingScene() {
        #expect(voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, furnitureGhostShows: true, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
        #expect(!voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, furnitureGhostShows: true, phaseIsWaitingForAQuizAnswer: true, sceneIsBuilding: false))
        #expect(!voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, furnitureGhostShows: true, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: true))
        #expect(!voiceCommandRouterTakesTheTranscript(sceneIsOnScreen: false, videoIsInFront: false, furnitureGhostShows: false, phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
    }

    @Test func theGhostsToolsAreOfferedOnlyWhileItShows() {
        var context = AppVoiceTool.Context(sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false, videoQuizIsRunning: false, quizQuestionIsOpen: false)
        #expect(!AppVoiceTool.available(in: context).contains(.placeFurniture))
        #expect(!AppVoiceTool.available(in: context).contains(.moveFurniture))
        context.furnitureGhostShows = true
        #expect(AppVoiceTool.available(in: context).contains(.placeFurniture))
        #expect(AppVoiceTool.available(in: context).contains(.moveFurniture))
        context.quizQuestionIsOpen = true
        #expect(!AppVoiceTool.available(in: context).contains(.moveFurniture))
        #expect(!AppVoiceTool.placeFurniture.mayHandOff && !AppVoiceTool.moveFurniture.mayHandOff)
    }

    @Test func theChipsSayWhatMoved() {
        func chip(_ name: String, _ input: [String: JSONValue]) -> String? { VoiceToolCall(id: "1", name: name, input: input).chipPhrase }
        #expect(chip("move_furniture", ["direction": .string("left")]) == "Moving it left")
        #expect(chip("move_furniture", ["turnDegrees": .number(90)]) == "Turning it")
        #expect(chip("move_furniture", ["direction": .string("sideways")]) == nil)
        #expect(chip("place_furniture", [:]) == "Placing it")
    }

    @Test func theSceneStateNamesTheGhostsFacingAndItsWall() throws {
        let floor = floorAhead()
        let ghost = try sofaGhost(on: floor, wall: wallBehind(floor, metersBeyond: 1.5))
        let state = voiceCommandFurnitureGhostState(ghost)
        #expect(state["placing"]?.boolValue == true)
        #expect(state["facing"]?.stringValue == "camera")
        #expect(state["againstTheWall"]?.boolValue == false)
    }
}
