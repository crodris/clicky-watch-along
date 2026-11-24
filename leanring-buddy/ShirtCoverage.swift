//
//  ShirtCoverage.swift
//  leanring-buddy
//
//  Where a garment goes on the learner. Any garment the page reader says can be drawn on the learner is painted on, and
//  `ShirtCoverage` (sleeves and length) is the single source of truth for the area the new garment covers on the body. The
//  paint mask adds it to what the painting may draw in, so a long sleeve is painted over the bare forearm and a coat down
//  over the thighs, and the live painted top cuts its layer with it.
//
//  Every point is in camera pixels with the origin at the top left and y growing down, as `BodyTorso` is.
//

import CoreGraphics
import Foundation
import simd

// MARK: - The area

/// Where the new garment lands on the body, which depends only on its sleeves and its length.
nonisolated struct ShirtCoverage: Equatable, Sendable {
    let sleeves: RoomArtSleeves
    let length: RoomArtGarmentLength

    /// Where each hem lies, in torso lengths down from the shoulders: a torso length is shoulder to hip, about half a meter on
    /// an adult, so the hip is 1, a cropped top ends at the waist, and the rest follow a standing adult's proportions.
    static func hemInTorsoLengths(for length: RoomArtGarmentLength) -> Double {
        switch length {
        case .waist: return 0.75
        case .hip: return 1.0
        case .thigh: return 1.4
        case .knee: return 1.85
        case .ankle: return 2.6
        }
    }

    /// The area reaches this far past each shoulder joint, in shoulder widths, since the body and the cloth extend past the
    /// joints. It starts at the shoulder line and never above it, so it leaves the neck to the neck rules.
    static let sideMarginInShoulderWidths = 0.06
    /// A long sleeve is this wide on each side of the line from the shoulder to the wrist, in shoulder widths: an arm and
    /// the loose cloth around it.
    static let armHalfWidthInShoulderWidths = 0.16
    /// With neither elbow nor wrist seen, the arm hangs straight down this many torso lengths from the shoulder.
    static let armWithNoJointsInTorsoLengths = 1.1
    /// A wrist the pose did not see is taken this share of the upper arm's length on from the elbow. A forearm is about as long
    /// as the upper arm, but the wrist then sits on the hand's edge, so a full upper arm would reach over the hand, which the
    /// paint mask must keep as filmed. Short of the wrist, the sleeve's cuff still covers most of the bare forearm.
    static let unseenWristShareOfTheUpperArm = 0.8
    /// A short sleeve reaches this share of the way from the shoulder joint to the elbow. A crew tee's sleeve hem sits near
    /// the middle of the upper arm, a fitted one a little above it and a boxy one a little below. Past the sleeve's end the
    /// paste puts the bare arm back as filmed, so a share too short cuts the painted sleeve off with a hard band of bare arm
    /// under it, while a share too long only lets the painting redraw a little of the bare arm below a shorter sleeve.
    static let shortSleeveShareOfTheUpperArm = 0.5

    init(sleeves: RoomArtSleeves, length: RoomArtGarmentLength) {
        self.sleeves = sleeves
        self.length = length
    }

    init(reading: RoomArtClothingReading) {
        self.init(sleeves: reading.sleeves, length: reading.length)
    }

    /// The area the garment covers on `torso`: the torso from the shoulders down to the hem, for short sleeves each upper
    /// arm from the shoulder to `shortSleeveShareOfTheUpperArm` of the way to the elbow, and for long sleeves each arm from
    /// the shoulder to the wrist. Convex pieces, whose union is the area, in the torso's own pixels, so a torso scaled
    /// to a small copy of the frame gives the area on that copy.
    func area(for torso: BodyTorso) -> ShirtCoverageArea {
        func vector(_ point: CGPoint) -> SIMD2<Double> { SIMD2(Double(point.x), Double(point.y)) }
        func point(_ vector: SIMD2<Double>) -> CGPoint { CGPoint(x: vector.x, y: vector.y) }
        let shoulderWidth = torso.shoulderWidth
        let leftShoulder = vector(torso.imageLeftShoulder), rightShoulder = vector(torso.imageRightShoulder)
        let leftHip = vector(torso.imageLeftHip), rightHip = vector(torso.imageRightHip)
        let shoulderMiddle = (leftShoulder + rightShoulder) / 2, hipMiddle = (leftHip + rightHip) / 2
        let torsoLength = max(simd_length(hipMiddle - shoulderMiddle), 1)
        let downTheTorso = (hipMiddle - shoulderMiddle) / torsoLength
        let acrossTheShoulders = simd_normalize(rightShoulder - leftShoulder)

        // Down to the hip each side keeps to the line from its shoulder to its hip, and below it each side runs straight down,
        // since a hem lower than the hips is not narrower than them.
        let hemInTorsoLengths = Self.hemInTorsoLengths(for: length)
        func hemPoint(shoulder: SIMD2<Double>, hip: SIMD2<Double>) -> SIMD2<Double> {
            hemInTorsoLengths <= 1 ? shoulder + (hip - shoulder) * hemInTorsoLengths : hip + downTheTorso * (hemInTorsoLengths - 1) * torsoLength
        }
        let sideMargin = Self.sideMarginInShoulderWidths * shoulderWidth
        let torsoPiece = [
            leftShoulder - acrossTheShoulders * sideMargin,
            rightShoulder + acrossTheShoulders * sideMargin,
            hemPoint(shoulder: rightShoulder, hip: rightHip) + acrossTheShoulders * sideMargin,
            hemPoint(shoulder: leftShoulder, hip: leftHip) - acrossTheShoulders * sideMargin,
        ].map(point)
        let bodyPieces = [torsoPiece]
        var sleevePieces: [[CGPoint]] = []

        let armHalfWidth = Self.armHalfWidthInShoulderWidths * shoulderWidth
        let arms = [
            (shoulder: leftShoulder, elbow: torso.imageLeftElbow.map(vector), wrist: torso.imageLeftWrist.map(vector)),
            (shoulder: rightShoulder, elbow: torso.imageRightElbow.map(vector), wrist: torso.imageRightWrist.map(vector)),
        ]
        // A piece `armHalfWidth` to each side of the line from `start` to `end`, nil for a line too short to have a direction.
        func armPiece(from start: SIMD2<Double>, to end: SIMD2<Double>) -> [CGPoint]? {
            let segment = end - start
            guard simd_length(segment) > 1 else { return nil }
            let direction = simd_normalize(segment)
            let sideways = SIMD2(-direction.y, direction.x) * armHalfWidth
            return [start + sideways, end + sideways, end - sideways, start - sideways].map(point)
        }

        if sleeves == .short {
            for arm in arms {
                // The elbow, or with none seen, halfway to the wrist, or halfway down an arm hanging by the body's side.
                let elbow = arm.elbow
                    ?? arm.wrist.map { (arm.shoulder + $0) / 2 }
                    ?? arm.shoulder + downTheTorso * Self.armWithNoJointsInTorsoLengths * torsoLength / 2
                if let piece = armPiece(from: arm.shoulder, to: arm.shoulder + (elbow - arm.shoulder) * Self.shortSleeveShareOfTheUpperArm) {
                    sleevePieces.append(piece)
                }
            }
        }

        if sleeves == .long {
            for arm in arms {
                // The arm's joints in order. A wrist the pose did not see is most of an upper arm's length on from the elbow
                // (`unseenWristShareOfTheUpperArm`), and with no joint at all the arm hangs down the body's side.
                var joints = [arm.shoulder]
                switch (arm.elbow, arm.wrist) {
                case (let elbow?, let wrist?): joints += [elbow, wrist]
                case (let elbow?, nil): joints += [elbow, elbow + (elbow - arm.shoulder) * Self.unseenWristShareOfTheUpperArm]
                case (nil, let wrist?): joints += [wrist]
                case (nil, nil): joints += [arm.shoulder + downTheTorso * Self.armWithNoJointsInTorsoLengths * torsoLength]
                }
                for (start, end) in zip(joints, joints.dropFirst()) {
                    if let piece = armPiece(from: start, to: end) { sleevePieces.append(piece) }
                }
                // A square at each bend between two segments, which fills the notch their two pieces leave on the outside.
                if joints.count == 3 {
                    let elbow = joints[1]
                    sleevePieces.append([
                        elbow + SIMD2(-armHalfWidth, -armHalfWidth), elbow + SIMD2(armHalfWidth, -armHalfWidth),
                        elbow + SIMD2(armHalfWidth, armHalfWidth), elbow + SIMD2(-armHalfWidth, armHalfWidth),
                    ].map(point))
                }
            }
        }
        return ShirtCoverageArea(bodyPieces: bodyPieces, sleevePieces: sleevePieces)
    }
}

/// The area a garment covers: convex pieces in camera pixels whose union is the area, kept in two groups. The body pieces are
/// the torso down to the hem. The sleeve pieces are the arms a sleeve covers (the upper arm under a short sleeve, the whole
/// arm under a long one), and only they stand where bare skin is legitimately painted over (a learner's bare upper arm
/// under a new tee's sleeve, a forearm under a long sleeve), so the paint mask's skin rule exempts the sleeve mask and no
/// more. It is not clipped to the frame, since a coat's hem is below it, and its masks are, because a mask only has the
/// frame's pixels.
nonisolated struct ShirtCoverageArea: Equatable, Sendable {
    let bodyPieces: [[CGPoint]]
    let sleevePieces: [[CGPoint]]

    /// Which pixels of a `width` by `height` frame the whole area covers, body and sleeves, first row at the top, a pixel
    /// counting when its center is inside a piece.
    func mask(width: Int, height: Int) -> [Bool] {
        Self.mask(of: bodyPieces + sleevePieces, width: width, height: height)
    }

    /// Which pixels the sleeve pieces alone cover, in the same layout as `mask(width:height:)`.
    func sleeveMask(width: Int, height: Int) -> [Bool] {
        Self.mask(of: sleevePieces, width: width, height: height)
    }

    private static func mask(of pieces: [[CGPoint]], width: Int, height: Int) -> [Bool] {
        var covered = [Bool](repeating: false, count: max(width, 0) * max(height, 0))
        guard width > 0, height > 0 else { return covered }
        for piece in pieces {
            let corners = piece.map { SIMD2(Double($0.x), Double($0.y)) }
            guard let leftMost = piece.map(\.x).min(), let rightMost = piece.map(\.x).max(),
                  let topMost = piece.map(\.y).min(), let bottomMost = piece.map(\.y).max(),
                  [leftMost, rightMost, topMost, bottomMost].allSatisfy(\.isFinite) else { continue }
            let firstColumn = max(0, Int(leftMost.rounded(.down))), lastColumn = min(width - 1, Int(rightMost.rounded(.up)))
            let firstRow = max(0, Int(topMost.rounded(.down))), lastRow = min(height - 1, Int(bottomMost.rounded(.up)))
            guard firstColumn <= lastColumn, firstRow <= lastRow else { continue }
            for row in firstRow...lastRow {
                for column in firstColumn...lastColumn where ShirtPaintMask.isInside(SIMD2(Double(column) + 0.5, Double(row) + 0.5), convexQuad: corners) {
                    covered[row * width + column] = true
                }
            }
        }
        return covered
    }
}
