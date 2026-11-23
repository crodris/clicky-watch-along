//
//  RoomFurnitureModel.swift
//  leanring-buddy
//
//  The pure geometry that stands a 3D piece of furniture in the learner's room: where its box sits on the measured floor
//  (`RoomFurniturePlacement`), how a model whose units and axes nobody promised is turned and scaled to the page's size
//  (`RoomFurnitureModelFit`), the floor inferred from the wall when the camera sees no floor (`FloorPlane.inferred`), how much
//  of the box the camera sees, and whether the piece draws over the learner. Everything is in the keyframe camera's space
//  (meters, x right, y down, z forward), as the depth service measures it. `RoomFurnitureRenderer.swift` draws from this.
//

import CoreGraphics
import CoreVideo
import Foundation
import simd

// MARK: - The box on the floor

/// The furniture's box standing on the floor, in the keyframe camera's space. Its front bottom edge is centered on the floor
/// point under the anchor, the way the depth service's `/floor` frame and the flat cutout both stand it, and it runs
/// `depthMeters` back from there.
nonisolated struct RoomFurniturePlacement: Equatable, Sendable {
    /// The middle of the box's front bottom edge, on the floor.
    let frontBottomCenter: SIMD3<Double>
    /// Along the front, toward the image's right for a piece in front of the camera.
    let rightDirection: SIMD3<Double>
    /// The floor's normal.
    let upDirection: SIMD3<Double>
    /// Out of the box's front: toward the camera, level with the floor.
    let towardTheFrontDirection: SIMD3<Double>
    let widthMeters: Double
    let heightMeters: Double
    let depthMeters: Double

    /// The box on `floor`. A measured floor turns the front toward the camera, as the flat cutout does, so a piece to the side
    /// is not seen at a slant. A floor inferred from the wall squares the box to the wall instead, since its back stands on
    /// the wall. `rightDirection` is `up` x the front direction, which is image-right for any floor the camera sees from the
    /// front, so a model is never mirrored. Nil for a size that is not a positive number (a depth of 0 is the flat cutout),
    /// or when the camera is straight above the anchor, so no direction toward it is level.
    init?(floor: FloorPlane, widthMeters: Double, heightMeters: Double, depthMeters: Double) {
        let frontDirectionBeforeNormalizing: SIMD3<Double>
        if floor.inferredFromTheWall {
            frontDirectionBeforeNormalizing = -floor.forward
        } else {
            // The camera is the origin, so the direction toward it is -center, made level by removing its part along up.
            let towardTheCamera = -floor.center
            frontDirectionBeforeNormalizing = towardTheCamera - floor.up * simd_dot(towardTheCamera, floor.up)
        }
        self.init(frontBottomCenter: floor.center, upDirection: floor.up, towardTheFront: frontDirectionBeforeNormalizing, widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters)
    }

    /// The box with its front facing `towardTheFront`, which is made level with the floor, such as a ghost the learner
    /// turned or snapped square to a wall (`RoomFurnitureGhost`). Nil for a size that is not a positive number, or a front
    /// direction with nothing left once it is made level.
    init?(frontBottomCenter: SIMD3<Double>, upDirection: SIMD3<Double>, towardTheFront: SIMD3<Double>, widthMeters: Double, heightMeters: Double, depthMeters: Double) {
        guard widthMeters.isFinite, heightMeters.isFinite, depthMeters.isFinite,
              widthMeters > 0, heightMeters > 0, depthMeters >= 0, simd_length(upDirection) > 1e-6 else { return nil }
        let up = simd_normalize(upDirection)
        let levelFront = towardTheFront - up * simd_dot(towardTheFront, up)
        guard simd_length(levelFront) > 1e-6 else { return nil }
        let frontDirection = simd_normalize(levelFront)
        self.frontBottomCenter = frontBottomCenter
        self.upDirection = up
        towardTheFrontDirection = frontDirection
        rightDirection = simd_normalize(simd_cross(up, frontDirection))
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.depthMeters = depthMeters
    }

    /// The box's eight corners in keyframe pixels, in `boxCorners` order, or nil when a corner is behind the camera.
    func keyframeBoxCorners(focalLengthPixels: Double, principalPoint: SIMD2<Double>) -> [CGPoint]? {
        var projectedCorners: [CGPoint] = []
        for corner in boxCorners {
            guard let projectedCorner = pinholeProjection(of: corner, focalLengthPixels: focalLengthPixels, principalPoint: principalPoint) else { return nil }
            projectedCorners.append(projectedCorner)
        }
        return projectedCorners
    }

    /// The center of the box's footprint, on the floor half its depth behind the front.
    var footprintCenter: SIMD3<Double> {
        frontBottomCenter - towardTheFrontDirection * (depthMeters / 2)
    }

    /// The front face's corners clockwise from the top left as the camera sees them, then the back face's in the same order.
    var boxCorners: [SIMD3<Double>] {
        let halfWidth = widthMeters / 2
        let faceCornerOffsets: [(alongRight: Double, alongUp: Double)] = [(-1, 1), (1, 1), (1, 0), (-1, 0)]
        let frontFace = faceCornerOffsets.map { offset in
            frontBottomCenter + rightDirection * (halfWidth * offset.alongRight) + upDirection * (heightMeters * offset.alongUp)
        }
        let backFace = frontFace.map { $0 - towardTheFrontDirection * depthMeters }
        return frontFace + backFace
    }

    /// Maps the model's own space (x along its width, y up, z out of its front, the origin at the middle of its footprint on
    /// the floor) into the keyframe camera's space. A right-handed rotation, since right = up x front.
    var modelToCameraTransform: simd_double4x4 {
        simd_double4x4(columns: (
            SIMD4(rightDirection, 0),
            SIMD4(upDirection, 0),
            SIMD4(towardTheFrontDirection, 0),
            SIMD4(footprintCenter, 1)
        ))
    }
}

/// A camera space point in camera pixels through the pinhole, or nil when it is not in front of the camera.
nonisolated func pinholeProjection(of point: SIMD3<Double>, focalLengthPixels: Double, principalPoint: SIMD2<Double>) -> CGPoint? {
    // Closer than this to the camera plane counts as behind it, as `WallPlane.keyframeCorners` counts it.
    guard point.z > 0.01 else { return nil }
    return CGPoint(
        x: point.x * focalLengthPixels / point.z + principalPoint.x,
        y: point.y * focalLengthPixels / point.z + principalPoint.y
    )
}

extension FloorPlane {
    /// The box's eight corners in keyframe pixels, in `RoomFurniturePlacement.boxCorners` order, or nil when the box cannot
    /// stand here or a corner is behind the camera.
    func keyframeBoxCorners(widthMeters: Double, heightMeters: Double, depthMeters: Double) -> [CGPoint]? {
        guard let placement = RoomFurniturePlacement(floor: self, widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters) else { return nil }
        return placement.keyframeBoxCorners(focalLengthPixels: focalLengthPixels, principalPoint: principalPoint)
    }

    /// The floor under a wall when the camera sees no floor: a laptop camera often shows only the wall behind the learner.
    /// The floor is level with the wall's up and `cameraHeightMeters` below the camera, and the item stands with its back on
    /// the wall below the wall's measured point, its front `itemDepthMeters` out from the wall. Nil when the wall's up is not
    /// a direction or the wall faces away.
    static func inferred(fromTheWall wall: WallPlane, cameraHeightMeters: Double = roomFurnitureCameraHeightMeters, itemDepthMeters: Double) -> FloorPlane? {
        guard simd_length(wall.up) > 1e-6, simd_length(wall.right) > 1e-6, itemDepthMeters.isFinite, itemDepthMeters >= 0 else { return nil }
        let up = simd_normalize(wall.up)
        let right = simd_normalize(wall.right)
        // The depth service builds up = normal x right, so the wall's normal toward the camera is right x up.
        let wallNormalTowardTheCamera = simd_cross(right, up)
        // The camera is the origin, so the floor is every point whose height along up is -cameraHeightMeters.
        let wallFoot = wall.center - up * (simd_dot(wall.center, up) + cameraHeightMeters)
        let frontBottomCenter = wallFoot + wallNormalTowardTheCamera * itemDepthMeters
        guard frontBottomCenter.z > 0 else { return nil }
        let cameraUp = SIMD3<Double>(0, -1, 0)
        var floor = FloorPlane(
            center: frontBottomCenter,
            right: right,
            up: up,
            forward: -wallNormalTowardTheCamera,
            focalLengthPixels: wall.focalLengthPixels,
            principalPoint: wall.principalPoint,
            distanceMeters: simd_length(frontBottomCenter),
            floorTiltDegrees: acos(min(1, max(-1, simd_dot(up, cameraUp)))) * 180 / .pi,
            planeInlierShare: wall.planeInlierShare
        )
        floor.inferredFromTheWall = true
        return floor
    }

    /// Whether the measured floor is level with the wall: a desk, a bed, or a sofa seat measured in its place tilts away from
    /// the wall's up when its fit is poor, and a real floor is square to a real wall.
    func agrees(withTheWall wall: WallPlane, withinDegrees maximumDegrees: Double = roomFurnitureFloorAndWallMostDegreesApart) -> Bool {
        guard simd_length(wall.up) > 1e-6 else { return true }
        let cosineOfTheAngle = simd_dot(simd_normalize(up), simd_normalize(wall.up))
        return acos(min(1, max(-1, cosineOfTheAngle))) * 180 / .pi <= maximumDegrees
    }
}

/// A laptop on a desk holds its camera about this far above the floor, which a floor inferred from the wall assumes.
nonisolated let roomFurnitureCameraHeightMeters = 1.05
/// A measured floor whose normal is further than this from the wall's up is a desk or a bed, not the floor.
nonisolated let roomFurnitureFloorAndWallMostDegreesApart = 20.0
/// A floor inferred from the wall stands the item only when at least this share of its box is inside the frame, since a
/// piece mostly off screen tells the learner nothing.
nonisolated let roomFurnitureLeastShareOfTheBoxInTheFrame = 1.0 / 3.0

// MARK: - How much of the box the camera sees

/// The share of the box's outline (the convex hull of its projected corners, `convexHull(of:)` in
/// RoomFurnitureGeneration.swift) that lies inside the frame, from 0 to 1. 0 when fewer than 3 corners are given or the
/// outline has no area.
nonisolated func shareOfTheBoxInsideTheFrame(projectedCorners: [CGPoint], frameSize: CGSize) -> Double {
    let outline = convexHull(of: projectedCorners)
    let outlineArea = polygonArea(outline)
    guard outline.count >= 3, outlineArea > 1e-9 else { return 0 }
    let insideTheFrame = clipped(outline, toRectangle: CGRect(origin: .zero, size: frameSize))
    return min(1, max(0, polygonArea(insideTheFrame) / outlineArea))
}

/// The loop traces the floor footprint while at least this share of it is in the frame, and the box's visible part below that.
nonisolated let roomFurnitureLeastShareOfTheFootprintInTheFrameForTheLoop = 0.5

/// Whether the box's floor footprint (its bottom corners, 2, 3, 6, and 7 of `RoomFurniturePlacement.boxCorners`) reaches the
/// frame's bottom row or lies below it. That is the usual case on a floor inferred from the wall, where a laptop camera sees
/// no floor: the piece's feet are below the picture, so the frame cuts off its lower part and the footprint's edge on the
/// picture is only the bottom row.
nonisolated func roomFurnitureFootprintReachesTheFrameBottom(projectedBox: [CGPoint], frameHeight: Int) -> Bool {
    guard projectedBox.count == 8 else { return false }
    let lowestFootprintRow = [projectedBox[2], projectedBox[3], projectedBox[6], projectedBox[7]].map(\.y).max() ?? 0
    return lowestFootprintRow >= Double(frameHeight - 1)
}

/// What the loop traces while the piece is arranged: the floor footprint (back left, back right, front right, front left,
/// clockwise on screen), or, when less than `roomFurnitureLeastShareOfTheFootprintInTheFrameForTheLoop` of the footprint is
/// in the frame, the visible part of the box, since a line around a footprint that is mostly below the picture is drawn
/// off it. The visible part is the rectangle around the box's outline clipped to the frame, and the footprint again when
/// none of the box is in the frame.
nonisolated func roomFurnitureLoopQuadrilateral(projectedBox: [CGPoint], frameSize: CGSize) -> RoomArtCorners? {
    guard projectedBox.count == 8 else { return nil }
    let footprint = RoomArtCorners(clockwiseFromTopLeft: [projectedBox[7], projectedBox[6], projectedBox[2], projectedBox[3]])
    guard shareOfTheBoxInsideTheFrame(projectedCorners: footprint.clockwiseFromTopLeft, frameSize: frameSize) < roomFurnitureLeastShareOfTheFootprintInTheFrameForTheLoop else { return footprint }
    let visibleOutline = clipped(convexHull(of: projectedBox), toRectangle: CGRect(origin: .zero, size: frameSize))
    guard visibleOutline.count >= 3 else { return footprint }
    let rectangleAroundTheVisibleOutline = visibleOutline.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    return RoomArtCorners(rect: CGRect(
        x: rectangleAroundTheVisibleOutline.minX, y: rectangleAroundTheVisibleOutline.minY,
        width: max(rectangleAroundTheVisibleOutline.width, 1), height: max(rectangleAroundTheVisibleOutline.height, 1)
    ))
}

/// The polygon's area by the shoelace formula, whichever way it winds.
nonisolated func polygonArea(_ polygon: [CGPoint]) -> Double {
    guard polygon.count >= 3 else { return 0 }
    var twiceTheSignedArea = 0.0
    for index in polygon.indices {
        let current = polygon[index], next = polygon[(index + 1) % polygon.count]
        twiceTheSignedArea += current.x * next.y - next.x * current.y
    }
    return abs(twiceTheSignedArea) / 2
}

/// The convex polygon clipped to the rectangle, one edge at a time (Sutherland and Hodgman).
nonisolated private func clipped(_ polygon: [CGPoint], toRectangle rectangle: CGRect) -> [CGPoint] {
    // Each edge keeps the side where its test is true, and the crossing point is found along the other coordinate.
    let edges: [(keeps: (CGPoint) -> Bool, crossing: (CGPoint, CGPoint) -> CGPoint)] = [
        ({ $0.x >= rectangle.minX }, { crossingAtX(rectangle.minX, $0, $1) }),
        ({ $0.x <= rectangle.maxX }, { crossingAtX(rectangle.maxX, $0, $1) }),
        ({ $0.y >= rectangle.minY }, { crossingAtY(rectangle.minY, $0, $1) }),
        ({ $0.y <= rectangle.maxY }, { crossingAtY(rectangle.maxY, $0, $1) }),
    ]
    var clippedPolygon = polygon
    for edge in edges {
        let inputPolygon = clippedPolygon
        clippedPolygon = []
        guard !inputPolygon.isEmpty else { break }
        for index in inputPolygon.indices {
            let current = inputPolygon[index]
            let previous = inputPolygon[(index + inputPolygon.count - 1) % inputPolygon.count]
            switch (edge.keeps(previous), edge.keeps(current)) {
            case (true, true): clippedPolygon.append(current)
            case (true, false): clippedPolygon.append(edge.crossing(previous, current))
            case (false, true):
                clippedPolygon.append(edge.crossing(previous, current))
                clippedPolygon.append(current)
            case (false, false): break
            }
        }
    }
    return clippedPolygon
}

nonisolated private func crossingAtX(_ x: Double, _ start: CGPoint, _ end: CGPoint) -> CGPoint {
    let share = (x - start.x) / (end.x - start.x)
    return CGPoint(x: x, y: start.y + (end.y - start.y) * share)
}

nonisolated private func crossingAtY(_ y: Double, _ start: CGPoint, _ end: CGPoint) -> CGPoint {
    let share = (y - start.y) / (end.y - start.y)
    return CGPoint(x: start.x + (end.x - start.x) * share, y: y)
}

// MARK: - Fitting a model to the page's size

/// How a model is turned and scaled so it stands at the page's size. A store's or a generated model's units and up axis are
/// never trusted: glTF says y up in meters, but a file can arrive in centimeters or z up, and a generated model has no
/// units at all. The axis whose share of the model best matches the page's shape is up, the model is scaled uniformly to
/// the page's height, and when its width and depth come out swapped by more than `swapMismatch` it is turned 90 degrees
/// about up, since its front is then on the other side axis.
nonisolated struct RoomFurnitureModelFit: Equatable, Sendable {
    enum Axis: Int, Sendable { case x = 0, y = 1, z = 2 }

    /// The model's axes, as signed unit vectors in its own space, that become the furniture's right, up, and front.
    /// right x up = front, so the turn is a rotation and never a mirror.
    let modelRightAxis: SIMD3<Double>
    let modelUpAxis: SIMD3<Double>
    let modelFrontAxis: SIMD3<Double>
    /// Meters per model unit.
    let scale: Double
    /// The worst relative difference between the scaled model's width or depth and the page's, such as 0.12 for 12 percent.
    let worstSideMismatch: Double
    /// Whether the model was turned 90 degrees about up because its width and depth came out swapped.
    let wasTurnedAQuarter: Bool

    /// Past this, width and depth count as swapped.
    static let swapMismatch = 0.15

    /// The fit for a model whose bounding box is `modelExtent` (its size along x, y, and z in its own units). Up is the
    /// glTF y unless another axis fits the page's shape clearly better (a z up file), and the width runs along the model's
    /// own right unless that leaves width and depth off by more than 15 percent while the swap fits. Nil for an extent or
    /// size that is not positive.
    static func fit(modelExtent: SIMD3<Double>, widthMeters: Double, heightMeters: Double, depthMeters: Double) -> RoomFurnitureModelFit? {
        let pageSides = [widthMeters, heightMeters, depthMeters]
        guard pageSides.allSatisfy({ $0.isFinite && $0 > 0 }),
              (0..<3).allSatisfy({ modelExtent[$0].isFinite && modelExtent[$0] > 1e-9 }) else { return nil }

        // How far one assignment's scaled width and depth are from the page's, as the worse of the two relative errors.
        func mismatch(up: Axis, width: Axis, depth: Axis) -> (worst: Double, scale: Double) {
            let scale = heightMeters / modelExtent[up.rawValue]
            let widthError = abs(modelExtent[width.rawValue] * scale / widthMeters - 1)
            let depthError = abs(modelExtent[depth.rawValue] * scale / depthMeters - 1)
            return (max(widthError, depthError), scale)
        }

        // Each up axis with its own default right and front, from the file's convention: glTF is y up with its front on +z,
        // and a z up file comes from tools like Blender, whose front faces -y. An x up file is rare, so it pays more.
        struct UpChoice { let up: Axis; let right: SIMD3<Double>; let front: SIMD3<Double>; let width: Axis; let depth: Axis; let penalty: Double }
        let upChoices = [
            UpChoice(up: .y, right: SIMD3(1, 0, 0), front: SIMD3(0, 0, 1), width: .x, depth: .z, penalty: 0),
            UpChoice(up: .z, right: SIMD3(1, 0, 0), front: SIMD3(0, -1, 0), width: .x, depth: .y, penalty: 0.1),
            UpChoice(up: .x, right: SIMD3(0, 1, 0), front: SIMD3(0, 0, -1), width: .y, depth: .z, penalty: 0.25),
        ]
        func bestOrientation(for choice: UpChoice) -> (worst: Double, scale: Double, swapped: Bool) {
            let asItIs = mismatch(up: choice.up, width: choice.width, depth: choice.depth)
            let swapped = mismatch(up: choice.up, width: choice.depth, depth: choice.width)
            if asItIs.worst > swapMismatch, swapped.worst < asItIs.worst {
                return (swapped.worst, swapped.scale, true)
            }
            return (asItIs.worst, asItIs.scale, false)
        }
        var bestChoice = upChoices[0]
        var bestOrientationFound = bestOrientation(for: upChoices[0])
        for choice in upChoices.dropFirst() {
            let orientation = bestOrientation(for: choice)
            if orientation.worst + choice.penalty < bestOrientationFound.worst + bestChoice.penalty {
                bestChoice = choice
                bestOrientationFound = orientation
            }
        }

        var upAxisVector = SIMD3<Double>(0, 0, 0)
        upAxisVector[bestChoice.up.rawValue] = 1
        // A quarter turn about up takes the old front to the new right: right' = front and front' = -right keep
        // right' x up = front', so it stays a rotation.
        let rightAxis = bestOrientationFound.swapped ? bestChoice.front : bestChoice.right
        let frontAxis = bestOrientationFound.swapped ? -bestChoice.right : bestChoice.front
        return RoomFurnitureModelFit(
            modelRightAxis: rightAxis,
            modelUpAxis: upAxisVector,
            modelFrontAxis: frontAxis,
            scale: bestOrientationFound.scale,
            worstSideMismatch: bestOrientationFound.worst,
            wasTurnedAQuarter: bestOrientationFound.swapped
        )
    }

    /// Maps the model's own space to the furniture's (x right, y up, z front, meters), with the bottom middle of the model's
    /// bounding box at the origin, so `RoomFurniturePlacement.modelToCameraTransform` stands it on the floor.
    func modelToFurnitureTransform(boundingBoxMinimum: SIMD3<Double>, boundingBoxMaximum: SIMD3<Double>) -> simd_double4x4 {
        // Rows of the turn are the model's right, up, and front, so it takes each to x, y, and z.
        let turn = simd_double3x3(rows: [modelRightAxis, modelUpAxis, modelFrontAxis])
        var turnedCorners: [SIMD3<Double>] = []
        for cornerX in [boundingBoxMinimum.x, boundingBoxMaximum.x] {
            for cornerY in [boundingBoxMinimum.y, boundingBoxMaximum.y] {
                for cornerZ in [boundingBoxMinimum.z, boundingBoxMaximum.z] {
                    turnedCorners.append(turn * SIMD3(cornerX, cornerY, cornerZ))
                }
            }
        }
        let turnedMinimum = turnedCorners.reduce(SIMD3(repeating: Double.infinity)) { simd_min($0, $1) }
        let turnedMaximum = turnedCorners.reduce(SIMD3(repeating: -Double.infinity)) { simd_max($0, $1) }
        let bottomMiddle = SIMD3((turnedMinimum.x + turnedMaximum.x) / 2, turnedMinimum.y, (turnedMinimum.z + turnedMaximum.z) / 2)
        let scaledTurn = turn * scale
        return simd_double4x4(columns: (
            SIMD4(scaledTurn.columns.0, 0),
            SIMD4(scaledTurn.columns.1, 0),
            SIMD4(scaledTurn.columns.2, 0),
            SIMD4(-bottomMiddle * scale, 1)
        ))
    }
}

// MARK: - The learner in front or behind

/// Whether the furniture draws over the learner this frame. The learner is usually in front of it, so the person mask draws
/// on top, but when the piece's base is lower in the frame than the learner's lowest masked row (their feet, or the bottom
/// of the frame for a learner cut off by it), the piece stands nearer the camera than they do. `personLowestRow` is nil
/// when no person is in the mask.
///
/// A base at or below the frame's bottom row proves nothing about depth: a seated learner reaches the bottom row, and on a
/// floor inferred from the wall the piece's front-bottom edge projects below the frame, so comparing the two would draw the
/// piece over the learner's chest. The learner stays on top then.
nonisolated func roomFurnitureDrawsOverThePerson(itemBaseRow: Double, personLowestRow: Double?, frameHeight: Double) -> Bool {
    guard let personLowestRow, itemBaseRow < frameHeight else { return false }
    return itemBaseRow > personLowestRow
}

/// The lowest row of a person mask (one byte per pixel, a person above 127) that holds a real share of a person, as a share
/// of the mask's height from 0 at the top to 1 at the bottom, or nil when no row does. A row counts once at least one
/// percent of its pixels are the person, so a few stray pixels near the floor do not read as feet.
nonisolated func lowestPersonRowShare(in personMask: CVPixelBuffer) -> Double? {
    CVPixelBufferLockBaseAddress(personMask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(personMask, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(personMask) == kCVPixelFormatType_OneComponent8,
          let baseAddress = CVPixelBufferGetBaseAddress(personMask) else { return nil }
    let width = CVPixelBufferGetWidth(personMask), height = CVPixelBufferGetHeight(personMask)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(personMask)
    guard width > 0, height > 0 else { return nil }
    let maskBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    let leastPersonPixelsInARow = max(1, width / 100)
    for row in stride(from: height - 1, through: 0, by: -1) {
        var personPixelsInTheRow = 0
        for column in 0..<width where maskBytes[row * bytesPerRow + column] > 127 { personPixelsInTheRow += 1 }
        if personPixelsInTheRow >= leastPersonPixelsInARow { return Double(row + 1) / Double(height) }
    }
    return nil
}

// MARK: - Where the whole piece fits

/// The keyframe's texture at the track size, for choosing bare floor: the Sobel texture of each pixel, 1,000 on and near
/// the person (`textureWithThePersonMarked`).
nonisolated struct RoomFloorTextureMap: Equatable, Sendable {
    let width: Int
    let height: Int
    let texture: [Float]
    let cameraPixelsPerMapPixel: Double

    /// The mean texture in a square around a camera pixel, `halfSideCameraPixels` on each side, with the part outside the
    /// map left out. 1,000 when none of the square is on the map.
    func meanTexture(around cameraPixel: CGPoint, halfSideCameraPixels: Double) -> Double {
        let halfSide = max(halfSideCameraPixels / cameraPixelsPerMapPixel, 1)
        let center = CGPoint(x: cameraPixel.x / cameraPixelsPerMapPixel, y: cameraPixel.y / cameraPixelsPerMapPixel)
        let left = max(0, Int(center.x - halfSide)), right = min(width - 1, Int(center.x + halfSide))
        let top = max(0, Int(center.y - halfSide)), bottom = min(height - 1, Int(center.y + halfSide))
        guard left <= right, top <= bottom else { return 1_000 }
        var total = 0.0, count = 0
        for row in top...bottom {
            for column in left...right {
                total += Double(texture[row * width + column])
                count += 1
            }
        }
        return total / Double(count)
    }
}

extension FloorPlane {
    /// The same floor anchored at another pixel: the floor point that pixel's ray meets, which costs no new measurement,
    /// since a floor is one plane. Nil when the ray does not meet the floor in front of the camera (a pixel above its
    /// horizon). The result is a measured floor, so its piece faces the camera.
    func moved(toAnchorPixel anchorPixel: CGPoint) -> FloorPlane? {
        let ray = SIMD3((anchorPixel.x - principalPoint.x) / focalLengthPixels, (anchorPixel.y - principalPoint.y) / focalLengthPixels, 1)
        let rayAlongUp = simd_dot(ray, up)
        guard abs(rayAlongUp) > 1e-9 else { return nil }
        let distanceAlongTheRay = simd_dot(center, up) / rayAlongUp
        guard distanceAlongTheRay > 0 else { return nil }
        let movedCenter = ray * distanceAlongTheRay
        return FloorPlane(
            center: movedCenter, right: right, up: up, forward: forward,
            focalLengthPixels: focalLengthPixels, principalPoint: principalPoint,
            distanceMeters: simd_length(movedCenter), floorTiltDegrees: floorTiltDegrees, planeInlierShare: planeInlierShare
        )
    }
}

/// Where furniture stands on a measured floor, and whether all of it shows.
nonisolated struct RoomFurnitureSpot: Equatable, Sendable {
    let floor: FloorPlane
    /// Every corner of the piece's box is inside the frame by `roomFurnitureFrameMarginShare`.
    let wholePieceFits: Bool
}

/// The piece's whole box stays this share of the frame's size inside each edge, so it never touches the frame.
nonisolated let roomFurnitureFrameMarginShare = 0.04
/// A furniture spot may lie this much farther along the floor than the measured one, which a measuring difference covers.
nonisolated let farthestBeyondTheMeasuredSpotMeters = 0.1
/// What Clicky says once when no spot on the floor shows the whole piece.
nonisolated let roomFurnitureStepBackLine = "Step back so I can show the whole piece."

/// The spot on the measured floor where the piece stands: of the floor points whose whole box (footprint and full height,
/// from the page's size) fits inside the frame with `roomFurnitureFrameMarginShare` to spare, the one nearest the lower
/// middle of the frame, with bare floor preferred (`texture`, when given). The bare spot the floor was measured at is
/// often a dark, plain corner where the frame cuts the piece off, which a viewer reads as broken. A spot is never farther
/// back than the measured one (`farthestBeyondTheMeasuredSpotMeters`), since the plane goes on forever in the math while
/// the room ends at a wall, and any piece would fit far enough back. When no spot fits, it is the spot that shows the
/// largest share of the box, and `wholePieceFits` is false.
nonisolated func roomFurnitureSpotWhereTheWholePieceFits(
    measuredFloor: FloorPlane,
    widthMeters: Double,
    heightMeters: Double,
    depthMeters: Double,
    frameSize: CGSize,
    texture: RoomFloorTextureMap?
) -> RoomFurnitureSpot {
    let frameWidth = Double(frameSize.width), frameHeight = Double(frameSize.height)
    let insideTheMargins = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        .insetBy(dx: frameWidth * roomFurnitureFrameMarginShare, dy: frameHeight * roomFurnitureFrameMarginShare)
    let lowerMiddle = CGPoint(x: frameWidth * 0.5, y: frameHeight * 0.82)

    struct Candidate { let floor: FloorPlane; let fits: Bool; let shareInTheFrame: Double; let score: Double }
    var candidates: [Candidate] = []
    let farthestDistanceAlongTheFloor = simd_dot(measuredFloor.center, measuredFloor.forward) + farthestBeyondTheMeasuredSpotMeters
    func consider(_ floor: FloorPlane, anchorPixel: CGPoint) {
        guard simd_dot(floor.center, measuredFloor.forward) <= farthestDistanceAlongTheFloor else { return }
        guard let boxCorners = floor.keyframeBoxCorners(widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters) else { return }
        let fits = boxCorners.allSatisfy { insideTheMargins.contains($0) }
        // Nearness to the lower middle, in frame widths, plus the floor's texture under the piece's front, so a bare patch
        // a little farther out wins over a busy one at the middle. The person's 1,000 rules a spot out.
        let distance = hypot(anchorPixel.x - lowerMiddle.x, anchorPixel.y - lowerMiddle.y) / frameWidth
        let frontWidthPixels = abs(boxCorners[2].x - boxCorners[3].x)
        let bareness = texture.map { min($0.meanTexture(around: anchorPixel, halfSideCameraPixels: frontWidthPixels / 2) / 100, 10) } ?? 0
        candidates.append(Candidate(
            floor: floor,
            fits: fits,
            shareInTheFrame: shareOfTheBoxInsideTheFrame(projectedCorners: boxCorners, frameSize: frameSize),
            score: distance + 0.25 * bareness
        ))
    }

    if let measuredAnchor = pinholeProjection(of: measuredFloor.center, focalLengthPixels: measuredFloor.focalLengthPixels, principalPoint: measuredFloor.principalPoint) {
        consider(measuredFloor, anchorPixel: measuredAnchor)
    }
    let columnCount = 48, rowCount = 36
    for rowIndex in 0...rowCount {
        let row = frameHeight * (0.35 + 0.65 * Double(rowIndex) / Double(rowCount))
        for columnIndex in 0...columnCount {
            let anchorPixel = CGPoint(x: frameWidth * Double(columnIndex) / Double(columnCount), y: row)
            if let movedFloor = measuredFloor.moved(toAnchorPixel: anchorPixel) { consider(movedFloor, anchorPixel: anchorPixel) }
        }
    }

    if let bestFitting = candidates.filter(\.fits).min(by: { $0.score < $1.score }) {
        return RoomFurnitureSpot(floor: bestFitting.floor, wholePieceFits: true)
    }
    let mostShown = candidates.max { ($0.shareInTheFrame, -$0.score) < ($1.shareInTheFrame, -$1.score) }
    return RoomFurnitureSpot(floor: mostShown?.floor ?? measuredFloor, wholePieceFits: false)
}

/// The middle of the piece's floor footprint in keyframe pixels: the mean of its box's four bottom corners, which the loop
/// outlines while the piece is placed. Nil when the box does not project.
nonisolated func roomFurnitureFootprintCenterInTheKeyframe(floor: FloorPlane, widthMeters: Double, heightMeters: Double, depthMeters: Double) -> CGPoint? {
    guard let boxCorners = floor.keyframeBoxCorners(widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters) else { return nil }
    let bottomCorners = [boxCorners[2], boxCorners[3], boxCorners[6], boxCorners[7]]
    return CGPoint(x: bottomCorners.map(\.x).reduce(0, +) / 4, y: bottomCorners.map(\.y).reduce(0, +) / 4)
}
