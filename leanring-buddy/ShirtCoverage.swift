//
//  ShirtCoverage.swift
//  leanring-buddy
//
//  Where a garment goes on the learner, and which preview shows it. Any garment the page reader says can be drawn on the
//  learner is tried on, so two pure rules decide everything that depends on the garment's cut:
//
//  - `ShirtCoverage` (sleeves and length) is the single source of truth for the area the new garment covers on the body.
//    The paint mask adds it to what the painting may draw in, so a long sleeve is painted over the bare forearm and a coat
//    down over the thighs, and the ghost outline draws it, so what the learner sees is what will be painted.
//  - `shirtPreviewKind` picks the live preview: the 2D garment drawn over the learner where that works today, and the
//    ghost outline of the covered area for everything else.
//
//  Every point is in camera pixels with the origin at the top left and y growing down, as `BodyTorso` is.
//

import CoreGraphics
import Foundation
import simd

// MARK: - The preview

/// What the live preview draws over the learner before the painting.
nonisolated enum ShirtPreviewKind: Equatable, Sendable {
    /// The garment cut out of its product photo, drawn over the learner's own top (`ShirtTryOnRenderer`).
    case liveGarment
    /// The camera as filmed, with a ghost outline of the area the painting will cover (`ShirtCoverage`) around the learner's
    /// own top, since that garment cannot be drawn flat over the learner.
    case ghostOutline

    /// What Clicky says once, when this preview first shows, so the learner knows how to get the painted look.
    var spokenLine: String {
        switch self {
        case .liveGarment: return roomArtShirtPreviewLine
        case .ghostOutline: return roomArtShirtGhostLine
        }
    }

    /// The panel's status line while this preview shows over the learner.
    var statusLine: String {
        switch self {
        case .liveGarment: return "On you"
        case .ghostOutline: return roomArtShirtGhostStatusLine
        }
    }
}

/// Whether the live 2D garment can draw this garment at all, before its cutout is tried: a top laid flat, or worn by a model
/// with no long sleeves (the model's forearms are cut away with the arms, so each sleeve would end at the upper arm), that
/// ends at the waist or the hip. A hanger photo, a long garment, and any other photo shape have no flat garment to map onto
/// the learner's torso.
nonisolated func shirtLiveGarmentMayWork(photoShows: RoomArtGarmentPhoto, sleeves: RoomArtSleeves, length: RoomArtGarmentLength) -> Bool {
    let photoWorks: Bool
    switch photoShows {
    case .flatLay: photoWorks = true
    case .onModel: photoWorks = sleeves != .long
    case .onHanger, .other: photoWorks = false
    }
    return photoWorks && (length == .waist || length == .hip)
}

/// The one rule that picks the preview: the live garment only where it works and its cutout was made, the ghost outline for
/// everything else, a failed cutout included.
nonisolated func shirtPreviewKind(photoShows: RoomArtGarmentPhoto, sleeves: RoomArtSleeves, length: RoomArtGarmentLength, garmentWasCutOut: Bool) -> ShirtPreviewKind {
    shirtLiveGarmentMayWork(photoShows: photoShows, sleeves: sleeves, length: length) && garmentWasCutOut ? .liveGarment : .ghostOutline
}

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

    init(sleeves: RoomArtSleeves, length: RoomArtGarmentLength) {
        self.sleeves = sleeves
        self.length = length
    }

    init(reading: RoomArtClothingReading) {
        self.init(sleeves: reading.sleeves, length: reading.length)
    }

    /// The area the garment covers on `torso`: the torso from the shoulders down to the hem, and for long sleeves each arm
    /// from the shoulder to the wrist. Convex pieces, whose union is the area, in the torso's own pixels, so a torso scaled
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
        let hemLengths = Self.hemInTorsoLengths(for: length)
        func hemPoint(shoulder: SIMD2<Double>, hip: SIMD2<Double>) -> SIMD2<Double> {
            hemLengths <= 1 ? shoulder + (hip - shoulder) * hemLengths : hip + downTheTorso * (hemLengths - 1) * torsoLength
        }
        let sideMargin = Self.sideMarginInShoulderWidths * shoulderWidth
        let torsoPiece = [
            leftShoulder - acrossTheShoulders * sideMargin,
            rightShoulder + acrossTheShoulders * sideMargin,
            hemPoint(shoulder: rightShoulder, hip: rightHip) + acrossTheShoulders * sideMargin,
            hemPoint(shoulder: leftShoulder, hip: leftHip) - acrossTheShoulders * sideMargin,
        ].map(point)
        var pieces = [torsoPiece]

        if sleeves == .long {
            let armHalfWidth = Self.armHalfWidthInShoulderWidths * shoulderWidth
            let arms = [
                (shoulder: leftShoulder, elbow: torso.imageLeftElbow.map(vector), wrist: torso.imageLeftWrist.map(vector)),
                (shoulder: rightShoulder, elbow: torso.imageRightElbow.map(vector), wrist: torso.imageRightWrist.map(vector)),
            ]
            for arm in arms {
                // The arm's joints in order. A wrist the pose did not see is one upper arm's length on from the elbow, and with
                // no joint at all the arm hangs down the body's side.
                var joints = [arm.shoulder]
                switch (arm.elbow, arm.wrist) {
                case (let elbow?, let wrist?): joints += [elbow, wrist]
                case (let elbow?, nil): joints += [elbow, elbow + (elbow - arm.shoulder)]
                case (nil, let wrist?): joints += [wrist]
                case (nil, nil): joints += [arm.shoulder + downTheTorso * Self.armWithNoJointsInTorsoLengths * torsoLength]
                }
                for (start, end) in zip(joints, joints.dropFirst()) {
                    let segment = end - start
                    guard simd_length(segment) > 1 else { continue }
                    let direction = simd_normalize(segment)
                    let sideways = SIMD2(-direction.y, direction.x) * armHalfWidth
                    pieces.append([start + sideways, end + sideways, end - sideways, start - sideways].map(point))
                }
                // A square at each bend between two segments, which fills the notch their two pieces leave on the outside.
                if joints.count == 3 {
                    let elbow = joints[1]
                    pieces.append([
                        elbow + SIMD2(-armHalfWidth, -armHalfWidth), elbow + SIMD2(armHalfWidth, -armHalfWidth),
                        elbow + SIMD2(armHalfWidth, armHalfWidth), elbow + SIMD2(-armHalfWidth, armHalfWidth),
                    ].map(point))
                }
            }
        }
        return ShirtCoverageArea(pieces: pieces)
    }
}

/// The area a garment covers: convex pieces in camera pixels whose union is the area. It is not clipped to the frame, since a
/// coat's hem is below it, and its mask is, because a mask only has the frame's pixels.
nonisolated struct ShirtCoverageArea: Equatable, Sendable {
    let pieces: [[CGPoint]]

    /// Which pixels of a `width` by `height` frame the area covers, first row at the top, a pixel counting when its center is
    /// inside a piece.
    func mask(width: Int, height: Int) -> [Bool] {
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
