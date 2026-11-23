//
//  RoomFurnitureGhost.swift
//  leanring-buddy
//
//  The furniture's ghost: before anything is painted, the piece shows as a true-size outline on the learner's floor, which
//  they drag, turn, and nudge by voice until they say "right there". This file holds the pure parts: where the ghost stands
//  and which way it faces (`RoomFurnitureGhost`), the snap that squares it to the wall behind it, the drag that maps a pixel
//  of the current camera frame back to the keyframe and onto the measured floor, the scroll wheel's 15 degree turns, the
//  voice nudges, the timeline that draws it line by line when it first appears (`RoomFurnitureGhostDrawTimeline`), the
//  pill that says its size, and the phrases that place it. Everything is in the keyframe camera's space (meters, x right,
//  y down, z forward), as the depth service measures it, so no move needs a new measurement. The panel draws it in
//  `RoomFurnitureGhostView.swift`, and `RoomArtPreviewController` runs it.
//

import CoreGraphics
import CoreVideo
import Foundation
import simd

// MARK: - Where the ghost stands

/// The ghost on the measured floor. `footprintCenter` and `turnDegrees` are where the learner put it, and `shownPose`
/// is where it shows: the same pose, or squared to the wall with its back on it when its back comes within
/// `roomFurnitureWallSnapMeters` of the wall measured on the same keyframe.
nonisolated struct RoomFurnitureGhost: Equatable, Sendable {
    /// What the pointer is doing with the ghost.
    enum Stage: Equatable, Sendable {
        case placing
        /// The pointer holds the ghost. `grabOffset` is the footprint's center minus the floor point under the pointer
        /// when it was grabbed, so the ghost moves with the pointer without jumping to it.
        case dragging(grabOffset: SIMD3<Double>)
    }

    /// Where it shows: the middle of its footprint on the floor, the level direction its front faces, and whether it is
    /// squared to the wall.
    struct Pose: Equatable, Sendable {
        let footprintCenter: SIMD3<Double>
        let towardTheFront: SIMD3<Double>
        let isSnappedToTheWall: Bool
    }

    let floor: FloorPlane
    /// The wall measured on the floor's keyframe, which the ghost snaps to. Nil when it was not measured.
    let wall: WallPlane?
    let widthMeters: Double
    let heightMeters: Double
    let depthMeters: Double
    /// Where the learner put the middle of the footprint, on the floor.
    private(set) var footprintCenter: SIMD3<Double>
    /// How far the learner turned it from facing the camera, counterclockwise seen from above.
    private(set) var turnDegrees: Double = 0
    /// A turn or a nudge away from the wall holds the snap off, so a piece can be turned in place against the wall or
    /// pulled off it. The next drag, click, or nudge toward the wall lets the snap apply again.
    private(set) var snapIsHeldOff = false
    private(set) var stage = Stage.placing

    /// The ghost standing where the spot search put the piece (`roomFurnitureSpotWhereTheWholePieceFits`), facing the camera,
    /// or square to the wall on a floor inferred from it. Nil when that box cannot stand there.
    init?(standingOn spotFloor: FloorPlane, wall: WallPlane?, widthMeters: Double, heightMeters: Double, depthMeters: Double) {
        guard let placement = RoomFurniturePlacement(floor: spotFloor, widthMeters: widthMeters, heightMeters: heightMeters, depthMeters: depthMeters) else { return nil }
        floor = spotFloor
        self.wall = wall
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.depthMeters = depthMeters
        footprintCenter = placement.footprintCenter
        turnDegrees = Self.turnDegrees(of: placement.towardTheFrontDirection, at: placement.footprintCenter, up: spotFloor.up)
    }

    /// The ghost picked back up from a placed piece, in the pose it was placed in.
    init(pickedUpFrom placedGhost: RoomFurnitureGhost) {
        self = placedGhost
        let shown = placedGhost.shownPose
        footprintCenter = shown.footprintCenter
        turnDegrees = Self.turnDegrees(of: shown.towardTheFront, at: shown.footprintCenter, up: placedGhost.floor.up)
        snapIsHeldOff = false
        stage = .placing
    }

    var isBeingDragged: Bool {
        if case .dragging = stage { return true }
        return false
    }

    // MARK: Where it shows

    var shownPose: Pose {
        if !snapIsHeldOff, let snappedPose = poseSnappedToTheWall(footprintCenter: footprintCenter) { return snappedPose }
        return Pose(footprintCenter: footprintCenter, towardTheFront: frontDirection(at: footprintCenter, turnDegrees: turnDegrees), isSnappedToTheWall: false)
    }

    /// The box as it shows, which the render and the painting stand the piece in.
    var shownPlacement: RoomFurniturePlacement? {
        let pose = shownPose
        return RoomFurniturePlacement(
            frontBottomCenter: pose.footprintCenter + pose.towardTheFront * (depthMeters / 2),
            upDirection: floor.up,
            towardTheFront: pose.towardTheFront,
            widthMeters: widthMeters,
            heightMeters: heightMeters,
            depthMeters: depthMeters
        )
    }

    /// The shown box's eight corners in keyframe pixels (`RoomFurniturePlacement.boxCorners` order), or nil when a corner
    /// is behind the camera.
    var keyframeBoxCorners: [CGPoint]? {
        shownPlacement?.keyframeBoxCorners(focalLengthPixels: floor.focalLengthPixels, principalPoint: floor.principalPoint)
    }

    /// The share of the ghost's projected box inside the keyframe, from 0 (gone from view or behind the camera) to 1 (all
    /// of it shows). The depth service's principal point is the frame's center.
    var shareOfTheBoxInTheFrame: Double {
        guard let boxCorners = keyframeBoxCorners else { return 0 }
        return shareOfTheBoxInsideTheFrame(projectedCorners: boxCorners, frameSize: CGSize(width: floor.principalPoint.x * 2, height: floor.principalPoint.y * 2))
    }

    /// Whether a keyframe pixel is on the ghost: inside the outline of its projected box.
    func contains(keyframePixel: CGPoint) -> Bool {
        guard let boxCorners = keyframeBoxCorners else { return false }
        return convexPolygon(convexHull(of: boxCorners), contains: keyframePixel)
    }

    /// The level direction toward the camera from a floor point, turned `turnDegrees` counterclockwise about up.
    private func frontDirection(at point: SIMD3<Double>, turnDegrees: Double) -> SIMD3<Double> {
        let towardTheCamera = Self.levelDirectionTowardTheCamera(from: point, up: floor.up)
        let radians = turnDegrees * .pi / 180
        // A level vector turned about up: v cos + (up x v) sin, since v has no part along up.
        return simd_normalize(towardTheCamera * cos(radians) + simd_cross(floor.up, towardTheCamera) * sin(radians))
    }

    private static func levelDirectionTowardTheCamera(from point: SIMD3<Double>, up: SIMD3<Double>) -> SIMD3<Double> {
        let towardTheCamera = -point
        let level = towardTheCamera - up * simd_dot(towardTheCamera, up)
        // A point straight below the camera has no level direction toward it, so it faces the camera's forward axis back.
        guard simd_length(level) > 1e-9 else { return simd_normalize(SIMD3(0, 0, -1) - up * simd_dot(SIMD3(0, 0, -1), up)) }
        return simd_normalize(level)
    }

    /// The turn from facing the camera that gives `front` at `point`, so a pose can be kept as a turn.
    private static func turnDegrees(of front: SIMD3<Double>, at point: SIMD3<Double>, up: SIMD3<Double>) -> Double {
        let towardTheCamera = levelDirectionTowardTheCamera(from: point, up: up)
        let cosine = simd_dot(towardTheCamera, front)
        let sine = simd_dot(simd_cross(towardTheCamera, front), up)
        return atan2(sine, cosine) * 180 / .pi
    }

    // MARK: The wall

    /// The wall's level normal toward the camera, and how much of the true normal lies along it, or nil when there is no
    /// wall or it is not upright enough to stand furniture against.
    private var levelWallNormal: (level: SIMD3<Double>, trueNormal: SIMD3<Double>, alongTheLevel: Double)? {
        guard let wall, simd_length(wall.right) > 1e-9, simd_length(wall.up) > 1e-9 else { return nil }
        var trueNormal = simd_normalize(simd_cross(simd_normalize(wall.right), simd_normalize(wall.up)))
        // The camera, at the origin, is in front of the wall.
        if simd_dot(-wall.center, trueNormal) < 0 { trueNormal = -trueNormal }
        let levelPart = trueNormal - floor.up * simd_dot(trueNormal, floor.up)
        guard simd_length(levelPart) > 1e-9 else { return nil }
        let level = simd_normalize(levelPart)
        let alongTheLevel = simd_dot(level, trueNormal)
        guard alongTheLevel > roomFurnitureWallLeastUprightness else { return nil }
        return (level, trueNormal, alongTheLevel)
    }

    /// How far the footprint's back is from the wall, along the floor, when the piece stands square to it. Negative when
    /// the back is past the wall.
    private func backGapFromTheWall(footprintCenter point: SIMD3<Double>) -> Double? {
        guard let wall, let normal = levelWallNormal else { return nil }
        // Along the level normal, the wall is this far from the point.
        let gapAlongTheFloor = simd_dot(point - wall.center, normal.trueNormal) / normal.alongTheLevel
        return gapAlongTheFloor - depthMeters / 2
    }

    /// The pose square to the wall with the back touching it, when the back is within `roomFurnitureWallSnapMeters` of the
    /// wall or past it, so the piece never sinks into the wall.
    private func poseSnappedToTheWall(footprintCenter point: SIMD3<Double>) -> Pose? {
        guard let normal = levelWallNormal, let backGap = backGapFromTheWall(footprintCenter: point), backGap < roomFurnitureWallSnapMeters else { return nil }
        return Pose(footprintCenter: point - normal.level * backGap, towardTheFront: normal.level, isSnappedToTheWall: true)
    }

    // MARK: Moves

    /// The pointer pressed at `floorPoint`. On the ghost, it grabs it where it is. Anywhere else, the ghost jumps there
    /// first, so a click moves it and a drag carries it.
    mutating func grab(atFloorPoint floorPoint: SIMD3<Double>, onTheGhost pressIsOnTheGhost: Bool) {
        let shown = shownPose
        snapIsHeldOff = false
        if pressIsOnTheGhost {
            // The snapped pose becomes the learner's own, so the grab never makes the piece jump off the wall.
            footprintCenter = shown.footprintCenter
            stage = .dragging(grabOffset: shown.footprintCenter - floorPoint)
        } else {
            footprintCenter = floorPoint
            stage = .dragging(grabOffset: .zero)
        }
    }

    /// The pointer moved to `floorPoint` while it holds the ghost.
    mutating func drag(toFloorPoint floorPoint: SIMD3<Double>) {
        guard case .dragging(let grabOffset) = stage else { return }
        footprintCenter = pointOnTheFloor(floorPoint + grabOffset)
    }

    mutating func release() {
        stage = .placing
    }

    /// The scroll wheel or a voice nudge turned it. A piece squared to the wall turns from the wall's square, and the turn
    /// holds the snap off, so it turns in place instead of snapping back.
    mutating func turn(byDegrees degrees: Double) {
        guard degrees.isFinite, degrees != 0 else { return }
        let shown = shownPose
        if shown.isSnappedToTheWall {
            footprintCenter = shown.footprintCenter
            turnDegrees = Self.turnDegrees(of: shown.towardTheFront, at: shown.footprintCenter, up: floor.up)
            snapIsHeldOff = true
        }
        turnDegrees = (turnDegrees + degrees).truncatingRemainder(dividingBy: 360)
    }

    /// A voice nudge: `distanceMeters` toward the camera's left or right, nearer to it, or farther from it, then `turnDegrees`.
    /// Moving a squared piece more than a few centimeters away from its wall pulls it off, and any other move lets the snap
    /// apply again, so "move it left" slides a piece along the wall it stands against.
    mutating func nudge(_ direction: RoomFurnitureNudgeDirection?, distanceMeters requestedDistanceMeters: Double, turnDegrees degrees: Double) {
        let shown = shownPose
        // A spoken distance comes from the router's model, so it is held to a room's size.
        let distanceMeters = min(requestedDistanceMeters, roomFurnitureLongestNudgeMeters)
        if let direction, distanceMeters.isFinite, distanceMeters > 0 {
            let towardTheCamera = Self.levelDirectionTowardTheCamera(from: shown.footprintCenter, up: floor.up)
            // The box's right is up x front, which is image-right for a piece facing the camera.
            let towardTheRight = simd_normalize(simd_cross(floor.up, towardTheCamera))
            let step: SIMD3<Double> = switch direction {
            case .left: -towardTheRight * distanceMeters
            case .right: towardTheRight * distanceMeters
            case .closer: towardTheCamera * distanceMeters
            case .farther: -towardTheCamera * distanceMeters
            }
            footprintCenter = pointOnTheFloor(shown.footprintCenter + step)
            if shown.isSnappedToTheWall {
                // The turn the wall gave it stays, so a piece pulled off the wall keeps facing out from it.
                turnDegrees = Self.turnDegrees(of: shown.towardTheFront, at: footprintCenter, up: floor.up)
            }
            let movesAwayFromTheWall = shown.isSnappedToTheWall
                && (levelWallNormal.map { simd_dot(step, $0.level) > roomFurnitureNudgeAwayFromTheWallMeters } ?? false)
            snapIsHeldOff = movesAwayFromTheWall
        }
        turn(byDegrees: degrees)
    }

    /// The point moved onto the floor plane along its normal, so a sum of floor points never drifts off the floor.
    private func pointOnTheFloor(_ point: SIMD3<Double>) -> SIMD3<Double> {
        point - floor.up * simd_dot(point - floor.center, floor.up)
    }

    /// Which way the shown piece faces from the camera's view, for the painter (`RoomFurniturePaintingOrientation`).
    var facing: RoomFurnitureFacing {
        let shown = shownPose
        return RoomFurnitureFacing(turnDegreesFromFacingTheCamera: Self.turnDegrees(of: shown.towardTheFront, at: shown.footprintCenter, up: floor.up))
    }

    /// What the painter is told about the shown pose.
    var paintingOrientation: RoomFurniturePaintingOrientation {
        RoomFurniturePaintingOrientation(facing: facing, backAgainstTheWall: shownPose.isSnappedToTheWall)
    }

    /// The floor point under a pixel of the keyframe, or nil above the floor's horizon.
    func floorPoint(underKeyframePixel keyframePixel: CGPoint) -> SIMD3<Double>? {
        floor.moved(toAnchorPixel: keyframePixel)?.center
    }
}

/// Which way the piece's front faces from the camera's view, as the Worker's `/room-furniture-composite` names it.
nonisolated enum RoomFurnitureFacing: String, CaseIterable, Sendable {
    case camera, cameraSlightlyLeft, cameraSlightlyRight, left, right, awayFromTheCamera

    /// A positive turn moves the front toward the image's right, since up x (toward the camera) is image-right.
    init(turnDegreesFromFacingTheCamera turnDegrees: Double) {
        var degrees = turnDegrees.truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 }
        if degrees < -180 { degrees += 360 }
        switch abs(degrees) {
        case ..<12: self = .camera
        case ..<40: self = degrees > 0 ? .cameraSlightlyRight : .cameraSlightlyLeft
        case ..<135: self = degrees > 0 ? .right : .left
        default: self = .awayFromTheCamera
        }
    }
}

/// The ghost snaps square to the wall when its back comes this close to the wall measured behind it.
nonisolated let roomFurnitureWallSnapMeters = 0.3
/// A nudge that moves a squared piece this far or more away from its wall pulls it off the wall.
nonisolated let roomFurnitureNudgeAwayFromTheWallMeters = 0.05
/// A wall whose normal is mostly up or down, such as a measurement that caught a table, is no wall to snap to: the level
/// part of its normal must be at least this share of it.
nonisolated let roomFurnitureWallLeastUprightness = 0.5

/// Whether a point is inside a convex polygon, whichever way it winds. A polygon of fewer than 3 points holds nothing.
nonisolated func convexPolygon(_ polygon: [CGPoint], contains point: CGPoint) -> Bool {
    guard polygon.count >= 3 else { return false }
    var sideSign = 0.0
    for index in polygon.indices {
        let start = polygon[index], end = polygon[(index + 1) % polygon.count]
        let cross = (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
        if cross == 0 { continue }
        if sideSign == 0 { sideSign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sideSign { return false }
    }
    return true
}

// MARK: - The drag in the current frame

nonisolated extension EuclideanWarp {
    /// The warp that takes the current frame back to the keyframe.
    var inverted: EuclideanWarp {
        let cosine = cos(angleRadians), sine = sin(angleRadians)
        // The inverse of x' = R x + t is x = R^T (x' - t).
        return EuclideanWarp(
            angleRadians: -angleRadians,
            translationX: -(cosine * translationX + sine * translationY),
            translationY: -(-sine * translationX + cosine * translationY)
        )
    }

    /// This warp eased toward `newer` by `share`, the way the tracked corners are smoothed, so the ghost holds still to a
    /// pixel of jitter.
    func eased(toward newer: EuclideanWarp, share: Double) -> EuclideanWarp {
        EuclideanWarp(
            angleRadians: angleRadians + (newer.angleRadians - angleRadians) * share,
            translationX: translationX + (newer.translationX - translationX) * share,
            translationY: translationY + (newer.translationY - translationY) * share
        )
    }
}

/// The tracker's newest warp from the keyframe to the current frame, which the ghost is drawn and dragged through.
nonisolated struct RoomArtTrackedWarp: Equatable, Sendable {
    let keyframeNumber: Int
    let keyframeToCurrent: EuclideanWarp
    /// The tracker lost the room long enough to hide the item, so the ghost hides and a drag does nothing.
    let theRoomIsLost: Bool

    /// The floor point under a pixel of the current camera frame: the pixel goes back through the tracker's turn to the
    /// keyframe, where the floor was measured, and its ray meets the floor there. Nil while the room is lost or above the
    /// floor's horizon.
    func floorPoint(underCurrentPixel currentPixel: CGPoint, of ghost: RoomFurnitureGhost) -> SIMD3<Double>? {
        guard !theRoomIsLost else { return nil }
        return ghost.floorPoint(underKeyframePixel: keyframeToCurrent.inverted.apply(to: currentPixel))
    }
}

// MARK: - Turning with the scroll wheel

/// The scroll wheel or the trackpad over the ghost turns it in 15 degree steps. A trackpad sends many small precise
/// deltas, which add up to a step every `pointsPerStep`, and a wheel's notch is one step.
nonisolated struct RoomFurnitureScrollTurn: Equatable, Sendable {
    static let degreesPerStep = 15.0
    static let pointsPerStep = 28.0
    private(set) var leftoverPoints = 0.0

    /// The whole steps this scroll adds, up being positive. A change of direction drops the points saved the other way.
    mutating func steps(afterScrollingBy deltaY: Double, hasPreciseDeltas: Bool) -> Int {
        guard deltaY.isFinite, deltaY != 0 else { return 0 }
        guard hasPreciseDeltas else { return deltaY > 0 ? 1 : -1 }
        if leftoverPoints != 0, (leftoverPoints > 0) != (deltaY > 0) { leftoverPoints = 0 }
        leftoverPoints += deltaY
        let wholeSteps = Int(leftoverPoints / Self.pointsPerStep)
        leftoverPoints -= Double(wholeSteps) * Self.pointsPerStep
        return wholeSteps
    }
}

// MARK: - Voice

/// The directions "move it a bit to the left" names, from the camera's view.
nonisolated enum RoomFurnitureNudgeDirection: String, CaseIterable, Sendable {
    case left, right, closer, farther
}

/// How far a nudge moves the piece when the learner names no distance.
nonisolated let roomFurnitureDefaultNudgeCentimeters = 30.0
/// The share of the box in the frame above which the whole piece counts as showing. The last tenth is a margin for the
/// clipping's rounding and for a piece only a little past an edge, since a laptop camera on a desk usually cuts off a
/// sofa's feet and Clicky should advise the learner only when the cut is large.
nonisolated let roomFurnitureShareOfTheBoxThatShowsWhole = 0.9
/// Why a spoken nudge left the ghost where it was, in words the router's model reads back to the learner.
nonisolated enum RoomFurnitureNudgeRefusal: Equatable, Sendable {
    case noGhost
    case distanceMovesNothing
    case leavesTheView

    var toolError: String {
        switch self {
        case .noGhost: return "No furniture is being placed"
        case .distanceMovesNothing: return "distanceCentimeters must be more than 0"
        case .leavesTheView: return "That would move the whole piece out of view, so it stayed where it was"
        }
    }
}

/// The farthest one spoken nudge moves the ghost.
nonisolated let roomFurnitureLongestNudgeMeters = 3.0

/// The chip for `move_furniture`, such as "Moving it left", or nil for a call that moves and turns nothing.
nonisolated func roomFurnitureMoveChipPhrase(direction: RoomFurnitureNudgeDirection?, turnDegrees: Double?) -> String? {
    if let direction { return "Moving it \(direction.rawValue)" }
    if let turnDegrees, turnDegrees != 0 { return "Turning it" }
    return nil
}

/// "Right there" and its close forms, which confirm what the room art panel is placing: the furniture's ghost, and any
/// other try-on that waits for the learner's go, so every surface shares one phrase rule.
nonisolated enum RoomArtConfirmPhrase {
    /// As the whole utterance, so "right there is the window" or "put it there and paint it blue" go to the router. A few
    /// words of agreement may come first, and please may come last.
    static func matches(_ transcript: String) -> Bool {
        let words = transcript.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        let wordsBeforeTheRequest: Set<String> = ["hey", "clicky", "okay", "ok", "yeah", "yes", "yep", "perfect", "great", "good", "nice", "cool", "um", "so", "and", "alright"]
        let wordsAfterTheRequest: Set<String> = ["please", "clicky", "thanks"]
        var requestWords = Array(words.drop { word in wordsBeforeTheRequest.contains(word) })
        while let lastWord = requestWords.last, wordsAfterTheRequest.contains(lastWord) {
            requestWords.removeLast()
        }
        return confirmRequests.contains(requestWords.joined(separator: " "))
    }

    private static let confirmRequests: Set<String> = [
        "right there", "right here", "put it there", "put it here", "put it right there", "put it right here",
        "place it", "place it there", "place it here", "place it right there", "that's good", "thats good",
        "that's good right there", "that's good there", "leave it there", "leave it here", "that spot", "this spot",
    ]

    /// Whether the phrase runs ahead of the router: only while something waits for the learner's go, no quiz question is
    /// open, and the Theme Studio card, which holds every spoken word, is closed.
    static func runsAheadOfTheRouter(matches phraseMatches: Bool, somethingWaitsToBeConfirmed: Bool, quizQuestionIsOpen: Bool, themeStudioIsOpen: Bool) -> Bool {
        phraseMatches && somethingWaitsToBeConfirmed && !quizQuestionIsOpen && !themeStudioIsOpen
    }
}

/// What the voice router's scene state says about the ghost, so "move it left" and "right there" read as commands for it.
nonisolated func voiceCommandFurnitureGhostState(_ ghost: RoomFurnitureGhost) -> JSONValue {
    .object([
        "placing": .bool(true),
        "facing": .string(ghost.facing.rawValue),
        "againstTheWall": .bool(ghost.shownPose.isSnappedToTheWall),
    ])
}

// MARK: - Drawing it line by line

/// The ghost draws itself the first time it appears and each time a placed piece is picked back up, the way the theme's
/// cursor glyph draws the loop: the glyph leaves the measuring loop's line (`handoff`), traces the footprint, rides up
/// each dashed corner post in turn, then draws the top outline, and the fill, the shadow, and the size pill come in last.
/// Every part is a pure function of the time since the draw began, so a test reads any moment.
nonisolated enum RoomFurnitureGhostDrawTimeline {
    static let handoffSeconds = 0.2
    static let footprintSeconds = 0.45
    static let secondsPerPost = 0.08
    static let topSeconds = 0.3
    static let fillSeconds = 0.2
    static let postCount = 4

    /// Where the tracer, the theme's cursor glyph, is.
    enum Tracer: Equatable {
        /// Flying from the loop's line to the footprint's first corner, 0 at the line and 1 at the corner.
        case leavingTheLoop(share: Double)
        case onTheFootprint(share: Double)
        case onAPost(index: Int, share: Double)
        case onTheTop(share: Double)
        /// The lines are drawn, and the tracer is gone.
        case gone
    }

    struct Frame: Equatable {
        /// How much of each part is drawn, from 0 to 1.
        let footprintShare: Double
        let postShares: [Double]
        let topShare: Double
        /// The fill and the contact shadow's opacity, as a share of their full opacity.
        let fillShare: Double
        let pillIsShown: Bool
        let tracer: Tracer

        static let whole = Frame(footprintShare: 1, postShares: Array(repeating: 1, count: postCount), topShare: 1, fillShare: 1, pillIsShown: true, tracer: .gone)
    }

    /// The whole draw's length: about 1.3 seconds, or 1.5 with the handoff from the loop.
    static func totalSeconds(startsFromTheLoop: Bool) -> Double {
        (startsFromTheLoop ? handoffSeconds : 0) + footprintSeconds + secondsPerPost * Double(postCount) + topSeconds + fillSeconds
    }

    /// The draw `secondsSinceBegan` in. `startsFromTheLoop` says the tracer leaves the measuring loop's line first, which a
    /// pick-up, with no loop, skips.
    static func frame(secondsSinceBegan: Double, startsFromTheLoop: Bool) -> Frame {
        var seconds = max(0, secondsSinceBegan)
        func share(of length: Double) -> Double { min(1, max(0, seconds / length)) }
        let noPosts = Array(repeating: 0.0, count: postCount)

        if startsFromTheLoop {
            if seconds < handoffSeconds {
                return Frame(footprintShare: 0, postShares: noPosts, topShare: 0, fillShare: 0, pillIsShown: false, tracer: .leavingTheLoop(share: share(of: handoffSeconds)))
            }
            seconds -= handoffSeconds
        }
        if seconds < footprintSeconds {
            let footprintShare = share(of: footprintSeconds)
            return Frame(footprintShare: footprintShare, postShares: noPosts, topShare: 0, fillShare: 0, pillIsShown: false, tracer: .onTheFootprint(share: footprintShare))
        }
        seconds -= footprintSeconds
        let postsSeconds = secondsPerPost * Double(postCount)
        if seconds < postsSeconds {
            let postIndex = min(postCount - 1, Int(seconds / secondsPerPost))
            let growingShare = min(1, (seconds - Double(postIndex) * secondsPerPost) / secondsPerPost)
            let postShares = (0..<postCount).map { index in index < postIndex ? 1 : (index == postIndex ? growingShare : 0) }
            return Frame(footprintShare: 1, postShares: postShares, topShare: 0, fillShare: 0, pillIsShown: false, tracer: .onAPost(index: postIndex, share: growingShare))
        }
        seconds -= postsSeconds
        let allPosts = Array(repeating: 1.0, count: postCount)
        if seconds < topSeconds {
            let topShare = share(of: topSeconds)
            return Frame(footprintShare: 1, postShares: allPosts, topShare: topShare, fillShare: 0, pillIsShown: false, tracer: .onTheTop(share: topShare))
        }
        seconds -= topSeconds
        return Frame(footprintShare: 1, postShares: allPosts, topShare: 1, fillShare: share(of: fillSeconds), pillIsShown: true, tracer: .gone)
    }
}

/// The footprint's soft glow, which breathes slowly once the ghost is drawn, and holds still with Reduce Motion on.
nonisolated enum RoomFurnitureGhostGlow {
    static let restingFillOpacity = 0.22
    static let breathOpacity = 0.07
    static let secondsPerBreath = 2.4

    static func fillOpacity(secondsSinceDrawn: Double, reduceMotionIsOn: Bool) -> Double {
        guard !reduceMotionIsOn else { return restingFillOpacity }
        return restingFillOpacity + breathOpacity * sin(2 * .pi * max(0, secondsSinceDrawn) / secondsPerBreath)
    }
}

// MARK: - Its lines in the panel

/// The ghost's lines in the panel's points this moment: the box's corners go from the keyframe through the tracker's turn
/// to the current frame, then into the panel. The footprint runs front left, front right, back right, back left; the posts
/// rise from those corners in that order; and the top starts above the back left corner, where the last post ends, so the
/// tracer's path never jumps there.
nonisolated struct RoomFurnitureGhostLines: Equatable, Sendable {
    /// Closed, front left first.
    let footprint: [CGPoint]
    /// Each from the floor up, in the footprint's order.
    let posts: [(bottom: CGPoint, top: CGPoint)]
    /// Closed, back left first.
    let top: [CGPoint]
    /// The camera frame in the panel, which the size pill stays inside.
    let videoRect: CGRect

    static func == (lhs: RoomFurnitureGhostLines, rhs: RoomFurnitureGhostLines) -> Bool {
        lhs.footprint == rhs.footprint && lhs.top == rhs.top && lhs.videoRect == rhs.videoRect
            && lhs.posts.map(\.bottom) == rhs.posts.map(\.bottom) && lhs.posts.map(\.top) == rhs.posts.map(\.top)
    }

    /// Nil unless there are 8 box corners and the fit has a frame. `cameraSize` is the frame's, in camera pixels.
    init?(keyframeBoxCorners boxCorners: [CGPoint], keyframeToCurrent: EuclideanWarp, fit: RoomArtVideoFit, cameraSize: CGSize) {
        guard boxCorners.count == 8, fit.isUsable else { return nil }
        let inThePanel = boxCorners.map { fit.viewPoint(forCameraPixel: keyframeToCurrent.apply(to: $0)) }
        // `RoomFurniturePlacement.boxCorners`: the front face clockwise from its top left, then the back face the same way.
        let frontLeftBottom = inThePanel[3], frontRightBottom = inThePanel[2], backRightBottom = inThePanel[6], backLeftBottom = inThePanel[7]
        let frontLeftTop = inThePanel[0], frontRightTop = inThePanel[1], backRightTop = inThePanel[5], backLeftTop = inThePanel[4]
        footprint = [frontLeftBottom, frontRightBottom, backRightBottom, backLeftBottom]
        posts = [(frontLeftBottom, frontLeftTop), (frontRightBottom, frontRightTop), (backRightBottom, backRightTop), (backLeftBottom, backLeftTop)]
        top = [backLeftTop, frontLeftTop, frontRightTop, backRightTop]
        videoRect = CGRect(origin: fit.origin, size: CGSize(width: cameraSize.width * fit.scale, height: cameraSize.height * fit.scale))
    }

    /// Where the size pill's center sits: over the middle of the part of the top outline the frame shows, a little above
    /// its highest point, with the whole pill at least `pillMarginInPoints` inside the frame's sides, below the Close button,
    /// and above the status line and the Place button, so a piece that runs off the frame's edge still has its size next to it.
    var pillCenter: CGPoint {
        let visibleTopPoints = top.indices.flatMap { index -> [CGPoint] in
            let start = top[index], end = top[(index + 1) % top.count]
            return (0..<24).map { step in
                let share = Double(step) / 24
                return CGPoint(x: start.x + (end.x - start.x) * share, y: start.y + (end.y - start.y) * share)
            }
        }.filter { videoRect.contains($0) }
        let anchorPoints = visibleTopPoints.isEmpty ? top : visibleTopPoints
        let leftmost = anchorPoints.map(\.x).min() ?? videoRect.midX, rightmost = anchorPoints.map(\.x).max() ?? videoRect.midX
        let highest = anchorPoints.map(\.y).min() ?? videoRect.midY
        let wantedCenter = CGPoint(x: (leftmost + rightmost) / 2, y: highest - Self.pillGapAboveTheTopInPoints)
        let lowestX = videoRect.minX + Self.pillHalfWidthInPoints + Self.pillMarginInPoints
        let highestX = videoRect.maxX - Self.pillHalfWidthInPoints - Self.pillMarginInPoints
        let lowestY = videoRect.minY + Self.pillHalfHeightInPoints + Self.controlsHeightAtTheTopInPoints
        let highestY = videoRect.maxY - Self.pillHalfHeightInPoints - Self.controlsHeightAtTheBottomInPoints
        guard lowestX < highestX, lowestY < highestY else { return wantedCenter }
        return CGPoint(x: min(max(wantedCenter.x, lowestX), highestX), y: min(max(wantedCenter.y, lowestY), highestY))
    }

    static let pillGapAboveTheTopInPoints = 26.0
    static let pillMarginInPoints = 12.0
    /// Half the pill's size, with room for the longest size words, such as "31.5″ wide · 32.5″ tall" in 13 point semibold.
    static let pillHalfWidthInPoints = 100.0
    static let pillHalfHeightInPoints = 15.0
    /// The Close button along the panel's top: its 30 points, the panel's 16 point padding, and a gap below.
    static let controlsHeightAtTheTopInPoints = 54.0
    /// The status line and the Place button along the panel's bottom, with the panel's 16 point padding and a gap above.
    static let controlsHeightAtTheBottomInPoints = 72.0
}

/// The size pill's words, such as "90″ wide · 32″ tall", or "~5″ wide · 10″ tall" for a width measured from the photo.
nonisolated func roomFurnitureGhostSizePillText(widthMeters: Double, heightMeters: Double, widthIsMeasuredFromThePhoto: Bool) -> String {
    let approximately = widthIsMeasuredFromThePhoto ? "~" : ""
    return "\(approximately)\(roomArtInchesInWords(centimeters: widthMeters * 100))\u{2033} wide · \(roomArtInchesInWords(centimeters: heightMeters * 100))\u{2033} tall"
}

/// The status line while the ghost shows.
nonisolated let roomFurnitureGhostStatusLine = "Drag to move · say \u{201C}right there\u{201D}"

// MARK: - The frame a placement is painted on

/// The newest camera frame, which a placement is painted on instead of the keyframe, so the painter sees the room as it is
/// now: the learner who stood in the way at the measurement may have stepped aside, and the camera may have turned.
nonisolated struct RoomArtPaintingFrame: @unchecked Sendable {
    // @unchecked because CGImage is immutable, so sharing one across queues is safe.
    let jpegData: Data
    let image: CGImage
    /// The tracker's turn from the keyframe to this frame, which takes the ghost's box into this frame's pixels.
    let keyframeToFrame: EuclideanWarp
    /// How much of the ghost's box the learner covers in this frame, from 0 to 1.
    let shareOfTheBoxThePersonCovers: Double

    /// The box's corners in this frame's pixels.
    func boxInThisFrame(_ boxInTheKeyframe: [CGPoint]) -> [CGPoint] {
        boxInTheKeyframe.map(keyframeToFrame.apply)
    }
}

/// A painting waits for the learner to step aside while they cover more than this share of the box: the painter would
/// draw the piece through them, or paint them out.
nonisolated let roomFurnitureMostOfTheBoxThePersonMayCover = 0.03
/// What Clicky says once per panel when the ghost first appears, so the learner knows they place the piece and how. The
/// status line says the same in fewer words, and nothing was spoken at this point, which left a quiet panel for the seconds
/// the learner takes to read it.
nonisolated let roomFurnitureGhostLine = "Here's where it would go. Drag it, or say right there."
/// What Clicky says once when the learner stands where the piece is about to be painted.
nonisolated let roomFurnitureStepAsideLine = "Step aside for a second."

/// The share of an outline's pixels the person mask covers (a mask byte over 127), from 0 to 1. The outline is in
/// `frameSize` pixels and the mask may be smaller, as Vision's is, so the outline is scaled onto it. 0 for an outline that
/// covers no mask pixel.
nonisolated func shareOfTheOutlineThePersonCovers(maskBytes: [UInt8], maskWidth: Int, maskHeight: Int, outlineInFramePixels outline: [CGPoint], frameSize: CGSize) -> Double {
    guard maskWidth > 0, maskHeight > 0, maskBytes.count >= maskWidth * maskHeight, outline.count >= 3, frameSize.width > 0, frameSize.height > 0 else { return 0 }
    let scaleX = Double(maskWidth) / frameSize.width, scaleY = Double(maskHeight) / frameSize.height
    let outlineInTheMask = outline.map { CGPoint(x: $0.x * scaleX, y: $0.y * scaleY) }
    guard outlineInTheMask.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return 0 }
    // The bounds are clamped to the mask before they become whole numbers, since a corner projected far off the frame
    // could be past what an Int holds.
    func clampedColumn(_ x: CGFloat) -> Int { Int(min(max(x, 0), CGFloat(maskWidth - 1))) }
    func clampedRow(_ y: CGFloat) -> Int { Int(min(max(y, 0), CGFloat(maskHeight - 1))) }
    let left = clampedColumn(outlineInTheMask.map(\.x).min() ?? 0), right = clampedColumn((outlineInTheMask.map(\.x).max() ?? 0).rounded(.up))
    let top = clampedRow(outlineInTheMask.map(\.y).min() ?? 0), bottom = clampedRow((outlineInTheMask.map(\.y).max() ?? 0).rounded(.up))
    guard left <= right, top <= bottom else { return 0 }
    var insidePixels = 0, coveredPixels = 0
    for row in top...bottom {
        for column in left...right where convexPolygon(outlineInTheMask, contains: CGPoint(x: Double(column) + 0.5, y: Double(row) + 0.5)) {
            insidePixels += 1
            if maskBytes[row * maskWidth + column] > 127 { coveredPixels += 1 }
        }
    }
    return insidePixels == 0 ? 0 : Double(coveredPixels) / Double(insidePixels)
}

/// The same, for Vision's one-byte person mask.
nonisolated func shareOfTheOutlineThePersonCovers(personMask: CVPixelBuffer, outlineInFramePixels outline: [CGPoint], frameSize: CGSize) -> Double {
    CVPixelBufferLockBaseAddress(personMask, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(personMask, .readOnly) }
    guard CVPixelBufferGetPixelFormatType(personMask) == kCVPixelFormatType_OneComponent8, let baseAddress = CVPixelBufferGetBaseAddress(personMask) else { return 0 }
    let width = CVPixelBufferGetWidth(personMask), height = CVPixelBufferGetHeight(personMask), bytesPerRow = CVPixelBufferGetBytesPerRow(personMask)
    let rowBytes = baseAddress.assumingMemoryBound(to: UInt8.self)
    var maskBytes = [UInt8](repeating: 0, count: width * height)
    for row in 0..<height {
        for column in 0..<width { maskBytes[row * width + column] = rowBytes[row * bytesPerRow + column] }
    }
    return shareOfTheOutlineThePersonCovers(maskBytes: maskBytes, maskWidth: width, maskHeight: height, outlineInFramePixels: outline, frameSize: frameSize)
}

// MARK: - What the controller keeps

/// When the ghost began drawing itself, and where its tracer leaves from in the panel: the measuring loop's tracer the first
/// time, or nowhere for a pick-up, which starts on the footprint.
nonisolated struct RoomFurnitureGhostDraw: Equatable, Sendable {
    let beganAt: TimeInterval
    let tracerStartInThePanel: CGPoint?
}

/// A painting that stood at the measured size and on its footprint, ready to show, in the keyframe's space.
nonisolated struct RoomFurnitureFinishedPainting: Sendable {
    let layers: RoomFurnitureKeyframeLayers
    let keyframeNumber: Int
    /// From the painting frame's pixels back to the keyframe's.
    let layerToKeyframe: EuclideanWarp
}

/// What the painting asked for as the ghost appeared came to.
nonisolated enum RoomFurniturePaintingAheadOutcome: Sendable {
    case painted(RoomFurnitureFinishedPainting)
    /// It was asked for, and no painting stood at the measured size and on its footprint, or the service failed.
    case noPaintingStood
    /// Nothing was asked for: the learner stood in the box, or the room was lost.
    case notAsked
}

/// The keyframe taken while the page was still read, and the wall measured on it then. They are two tasks because the
/// keyframe is ready at once while the wall takes the depth service's one run of about 14 seconds, and the loop must move
/// to the wall spot as soon as the keyframe exists, not when the wall is back.
nonisolated struct RoomArtEarlyMeasurement: Sendable {
    /// Nil when no keyframe could be taken, or a shirt read cancelled it first.
    let keyframe: Task<RoomArtKeyframe?, Never>
    /// The wall measured on that keyframe, nil when there was no keyframe or the measurement was cancelled.
    let wall: Task<Result<WallPlane, Error>?, Never>

    func cancel() {
        keyframe.cancel()
        wall.cancel()
    }
}
