//
//  ShirtPaintedStill.swift
//  leanring-buddy
//
//  The shirt try-on's final look. The live overlay (`ShirtTryOnRenderer`) is the quick preview, and when the learner says
//  "right there" or clicks Paint it, the panel arms a capture (`ShirtStepBackCapture`) that freezes the camera frame once they
//  have stepped back and held still, and OpenAI's image edit paints the store's top onto them in that frame (`POST /room-furniture-composite` with kind "shirt"), which follows their pose, folds, and light the
//  way a 2D overlay cannot. The painted still crossfades in, and "go back" or Back to live returns to the overlay.
//
//  This file holds the pure parts and the Worker client: the phrases, the frozen frame, the mask the painting may draw in,
//  the regions the paste must leave exactly as filmed, and the paste.
//
//  The mask covers the whole garment the learner wears now, not only where the new one lands, since a narrower new top
//  painted inside a torso shape left the old top's sleeve stub and hem showing past it in the spike. It starts from the old
//  top (`ShirtFrameAnalysis`'s old shirt pixels, down to its hem and along its sleeves), the torso, and where the live
//  overlay's garment landed, fills the holes a print leaves, and takes away the neck and head (the analysis's neck cut),
//  the face, the hands, and the bare skin the new top does not cover. The hands and the face are also kept out of the paste,
//  which grows the mask by 24 pixels, since in the spike that growth repainted about 30 percent of the hand pixels.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

// MARK: - The voice

/// What the learner asks of the shirt by voice while the panel shows it.
nonisolated enum ShirtStillVoiceRequest: Equatable, Sendable {
    /// "Right there": arm the capture, which freezes a frame once the learner has stepped back and held still, and paints the shirt into it.
    case paintIt
    /// "Go back": leave the painted still for the live preview.
    case backToLive
}

/// The request in the learner's words, as the whole utterance, so "right there is a window" or "go back to the last video"
/// go to the router. A few words of agreement may come first, and please may come last, as in "okay, right there please".
nonisolated func shirtStillVoiceRequest(for transcript: String) -> ShirtStillVoiceRequest? {
    let words = transcript.lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .replacingOccurrences(of: #"[^a-z' ]"#, with: " ", options: .regularExpression)
        .split(separator: " ")
        .map(String.init)
    let wordsBeforeTheRequest: Set<String> = ["hey", "clicky", "okay", "ok", "yeah", "yes", "yep", "perfect", "great", "good", "nice", "cool", "um", "so", "and", "alright", "now"]
    let wordsAfterTheRequest: Set<String> = ["please", "clicky", "thanks", "now"]
    var requestWords = Array(words.drop { word in wordsBeforeTheRequest.contains(word) })
    while let lastWord = requestWords.last, wordsAfterTheRequest.contains(lastWord) {
        requestWords.removeLast()
    }
    let request = requestWords.joined(separator: " ")
    let paintRequests: Set<String> = [
        "right there", "right here", "that's good", "thats good", "that's good right there", "take it", "take that",
        "paint it", "paint it on me", "paint that", "put it on me", "put it on me for real",
    ]
    let backRequests: Set<String> = [
        "go back", "back to live", "go back to live", "back to the live view", "go back to the live view", "go live", "show me live",
    ]
    if paintRequests.contains(request) { return .paintIt }
    if backRequests.contains(request) { return .backToLive }
    return nil
}

/// A click on the panel's shirt button within this many seconds of it changing role is not counted, as the "Add theme?"
/// card ignores clicks for its first 0.4 seconds.
nonisolated let shirtButtonSecondsIgnoredAfterItChanges = 0.4

/// Whether a click on the shirt button at `now` counts, given when the button last changed role.
nonisolated func shirtButtonPressCounts(atUptime now: TimeInterval, theButtonChangedAt changedAt: TimeInterval) -> Bool {
    now - changedAt >= shirtButtonSecondsIgnoredAfterItChanges
}

/// A click older than this is not the press being handled, such as the last mouse click still current when VoiceOver
/// presses the button, which dequeues no event of its own.
nonisolated let shirtButtonLongestClickToPressSeconds = 1.0

/// The time a press on the shirt button counts from: a mouse click's own time, so a click queued behind a busy main actor
/// is measured from when it was made, or the time the press is handled when the current event is not a click, or is a
/// click timestamped after now or more than `shirtButtonLongestClickToPressSeconds` old.
nonisolated func shirtButtonPressTime(currentEventIsAMouseClick: Bool, currentEventTimestamp: TimeInterval?, now: TimeInterval) -> TimeInterval {
    guard currentEventIsAMouseClick, let clickTime = currentEventTimestamp,
          now - clickTime >= 0, now - clickTime < shirtButtonLongestClickToPressSeconds else { return now }
    return clickTime
}

extension RoomArtPhase {
    /// What the shirt panel can do by voice or by its button in this phase.
    nonisolated var shirtStillVoiceTargets: ShirtStillVoiceTargets {
        switch self {
        case .showingTheShirt: return .livePreview
        case .waitingForTheLearnerToStepBack: return .stepBack
        case .paintingTheShirt, .showingThePaintedShirt: return .paintedStill
        default: return .none
        }
    }
}

/// What the shirt panel can do by voice right now.
nonisolated enum ShirtStillVoiceTargets: Equatable, Sendable {
    /// No shirt shows, so the phrases go to the router as before.
    case none
    /// The live preview shows, so "right there" paints it.
    case livePreview
    /// The capture waits for the learner to step back, so "right there" restarts it and "go back" cancels it.
    case stepBack
    /// A painting is on its way or the painted still shows, so "go back" returns to the preview.
    case paintedStill
}

/// Whether a shirt phrase runs ahead of the router: only for the request the panel can take now, with no quiz question open
/// and the Theme Studio card, which holds every spoken word, closed.
nonisolated func shirtStillPhraseRunsAheadOfTheRouter(
    request: ShirtStillVoiceRequest?,
    targets: ShirtStillVoiceTargets,
    quizQuestionIsOpen: Bool,
    themeStudioIsOpen: Bool
) -> Bool {
    guard let request, !quizQuestionIsOpen, !themeStudioIsOpen else { return false }
    switch (request, targets) {
    case (.paintIt, .livePreview), (.paintIt, .stepBack), (.backToLive, .stepBack), (.backToLive, .paintedStill): return true
    default: return false
    }
}

// MARK: - The lines

/// What Clicky says when the live preview first shows, so the learner knows how to get the real look.
nonisolated let roomArtShirtPreviewLine = "Here's a preview. Say right there to put it on you."
/// What Clicky says when the painted still has crossfaded in.
nonisolated let roomArtShirtPaintedLine = "Here it is on you."
/// The status line while the shirt is painted into the frozen frame.
nonisolated let roomArtShirtPaintingStatusLine = "Putting it on you…"
/// The status line while the painted still shows.
nonisolated let roomArtShirtPaintedStatusLine = "On you · say go back for the live view"
/// The crossfade from the frozen preview to the painted still.
nonisolated let shirtPaintedStillCrossfadeSeconds = 0.5

/// Why the shirt could not be painted, each with its line. Every one goes back to the live preview.
nonisolated enum ShirtPaintingFailure: Error, Equatable, Sendable {
    /// The mask could not be made from the frozen frame, such as an old shirt that could not be found.
    case maskNotMade
    /// The Worker has no OpenAI key.
    case serviceIsNotSetUp
    /// The Worker refused the app secret, which trying again does not change.
    case appSecretRefused
    /// The Worker did not answer: not running, or the request timed out.
    case workerUnreachable
    /// Any other failed call: a refused edit, a timeout, or a reply that could not be pasted.
    case paintingFailed

    var spokenLine: String {
        switch self {
        case .maskNotMade: return "I couldn't find your shirt in that frame. Try again with your shirt in view."
        case .serviceIsNotSetUp: return "Painting a shirt on you needs Clicky's OpenAI key."
        case .appSecretRefused: return RoomArtFailure.appSecretMissing.spokenLine
        case .workerUnreachable: return RoomArtFailure.workerUnreachable.spokenLine
        case .paintingFailed: return "I couldn't put it on you that time. Say right there to try again."
        }
    }
}

// MARK: - The frozen frame

/// The camera frame the panel froze for a painting, with what the live preview knew about it. Every byte array is the
/// frame's size, first row at the top.
nonisolated struct ShirtFrozenFrame: @unchecked Sendable {
    // @unchecked because CGImage is immutable, so sharing one across queues is safe.

    /// The camera frame as filmed, with nothing drawn on it.
    let cameraImage: CGImage
    /// The frame with the live preview's shirt drawn on it, which the panel shows while the painting is made.
    let previewImage: CGImage
    /// 0 to 255, where the person is.
    let personMask: [UInt8]
    /// 0 to 255, where the live preview drew the garment and its base color fill: where the new top lands.
    let previewGarmentCoverage: [UInt8]
    let torso: BodyTorso

    var width: Int { cameraImage.width }
    var height: Int { cameraImage.height }
}

/// The parts of the body the painting must leave exactly as filmed, found by Vision in the frozen frame, in its pixels with
/// y down.
nonisolated struct ShirtPaintBodyParts: Equatable, Sendable {
    /// Each face's box.
    var faceBoxes: [CGRect] = []
    /// Each hand's joints, the wrist among them, from Vision's hand pose, plus each wrist the body pose saw, alone.
    var hands: [[CGPoint]] = []
}

// MARK: - The mask

/// What a painting is made with: the mask OpenAI may draw in, and the regions the paste leaves exactly as filmed.
nonisolated struct ShirtPaintMasks: Equatable, Sendable {
    let width: Int
    let height: Int
    /// 255 where the painting may draw, 0 elsewhere.
    let paintable: [UInt8]
    /// 0 to 255, how much of the filmed frame the paste puts back over the painting: 255 on the hands, the face, and the
    /// neck, fading to 0 over `ShirtPaintMask.protectedFeatherPixels` around the hands and the face, and ending at the
    /// neck's edge.
    let protected: [UInt8]
    /// The old top as found, 255 where it is, for the log and the checks.
    let oldShirt: [UInt8]

    var paintableShare: Double { Double(paintable.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }) / Double(max(paintable.count, 1)) }
}

nonisolated enum ShirtPaintMask {
    /// The old top's hem is taken this many shoulder widths lower than the analysis found it, for the band where it meets
    /// the trousers.
    static let hemMarginInShoulderWidths = 0.06
    /// With no hem found, the old top is taken down to this many torso lengths below the shoulders, past the analysis's 1.08,
    /// since an oversized top hangs lower than the new one lands.
    static let hemWithNoneFoundInTorsoLengths = 1.3
    /// Beside the torso, the old top is taken this far out from the center line, and along each arm this far past the
    /// elbow, in shoulder widths, which covers a sleeve that reaches the elbow.
    static let largestHalfWidthInShoulderWidths = 1.0
    static let sleeveReachPastTheElbowInShoulderWidths = 0.08
    static let sleeveHalfWidthInShoulderWidths = 0.45
    /// The mask's holes (a print on the old top, trim) close over this radius, in shoulder widths.
    static let closingRadiusInShoulderWidths = 0.03
    /// The mask grows this far past the old top's outline, in shoulder widths, so its edge blended with the wall is painted.
    static let outlineGrowthInShoulderWidths = 0.02
    /// Around each hand's joints, how far the hand reaches, in shoulder widths: the fingers' flesh past their joints.
    static let handMarginInShoulderWidths = 0.07
    /// A wrist the body pose saw with no hand pose keeps this radius, which holds a watch or a bracelet.
    static let wristRadiusInShoulderWidths = 0.12
    /// Each face box grows by this share of its size, for the hair and the ears beside it.
    static let faceBoxGrowthShare = 0.25
    /// The protected regions fade to the painting over this many pixels around their edge, so no seam shows.
    static let protectedFeatherPixels = 3
    /// Past this height above the neck's base, in shoulder widths, the analysis's cut is the head whatever its width, as the
    /// analysis's own rule has it.
    static let headStartsAboveTheNeckBaseInShoulderWidths = 0.30
    /// Pieces of the mask under this share of the frame are specks, not garment.
    static let smallestPieceShare = 0.0005

    /// The mask is worked out at this long side, under half of a 1280 by 720 frame, and then scaled up, since the old top's
    /// search at the frame's own size took over 40 seconds in a Debug build. The paste grows and feathers the mask by 24 pixels anyway, and
    /// the hands and the face are drawn at the frame's own size, so nothing that must stay exact is coarse.
    static let workingLongestSide = 480

    /// The masks for one frozen frame, or nil when the shoulders are not in it or the old top's color cannot be read below them.
    static func make(frame: ShirtFrozenFrame, bodyParts: ShirtPaintBodyParts) -> ShirtPaintMasks? {
        let width = frame.width, height = frame.height
        let torso = frame.torso
        // The analysis reads the old top below the shoulders, so the shoulders must be in the frame.
        guard width >= 3, height >= 3, frame.personMask.count == width * height, frame.previewGarmentCoverage.count == width * height,
              torso.shouldersAreSeen, torso.shoulderWidth > 2,
              (0..<Double(width)).contains(Double(torso.shoulderMidpoint.x)), (0..<Double(height)).contains(Double(torso.shoulderMidpoint.y)) else { return nil }
        let scale = min(1, Double(workingLongestSide) / Double(max(width, height)))
        let workWidth = max(3, Int((Double(width) * scale).rounded())), workHeight = max(3, Int((Double(height) * scale).rounded()))
        guard let workRGBA = rgbaBytes(of: frame.cameraImage, width: workWidth, height: workHeight),
              let workPerson = resizedGrayBytes(frame.personMask, width: width, height: height, toWidth: workWidth, toHeight: workHeight),
              let workCoverage = resizedGrayBytes(frame.previewGarmentCoverage, width: width, height: height, toWidth: workWidth, toHeight: workHeight),
              let work = workingMasks(rgba: workRGBA, personMask: workPerson, previewGarmentCoverage: workCoverage, torso: torso.scaled(by: scale), width: workWidth, height: workHeight)
        else { return nil }

        // Scaled up to the frame, where the hands and the face, drawn at its own size, come out exactly.
        let handsAndFace = handAndFaceRegion(bodyParts: bodyParts, width: width, height: height, shoulderWidth: torso.shoulderWidth)
        guard let fullPaintable = resizedGrayBytes(work.paintable.map { $0 ? 255 : 0 }, width: workWidth, height: workHeight, toWidth: width, toHeight: height),
              let fullCut = resizedGrayBytes(work.cut.map { $0 ? 255 : 0 }, width: workWidth, height: workHeight, toWidth: width, toHeight: height),
              let fullOldShirt = resizedGrayBytes(work.oldShirt.map { $0 ? 255 : 0 }, width: workWidth, height: workHeight, toWidth: width, toHeight: height) else { return nil }
        var paintable = [Bool](repeating: false, count: width * height)
        // The paste puts back the hands, the face, and the neck exactly as filmed, past the 24 pixels it grows the mask by.
        // The hands and the face fade out past their edge, so no seam shows on the room or the arm. The neck ends with a hard
        // edge, since a fade past it would bring back a rim of the old collar above the new one.
        var protected = feathered(handsAndFace, width: width, height: height, featherPixels: protectedFeatherPixels)
        let neckSkin = neckSkinRegion(frame: frame)
        for index in 0..<(width * height) {
            paintable[index] = fullPaintable[index] > 127 && !handsAndFace[index] && !neckSkin[index]
            if (fullCut[index] > 127 && frame.personMask[index] > 127) || neckSkin[index] { protected[index] = 255 }
        }
        guard paintable.contains(true) else { return nil }
        return ShirtPaintMasks(
            width: width, height: height,
            paintable: paintable.map { $0 ? 255 : 0 },
            protected: protected,
            oldShirt: fullOldShirt.map { $0 > 127 ? 255 : 0 }
        )
    }

    /// The skin of the neck at the frame's own size: person pixels the skin rule keeps, above the neck's base and within the
    /// neck's half width of its middle, so the edge where the neck meets the collar is exact, which the neck cut scaled up
    /// from the working size is not.
    static func neckSkinRegion(frame: ShirtFrozenFrame) -> [Bool] {
        let width = frame.width, height = frame.height
        var region = [Bool](repeating: false, count: width * height)
        guard let rgba = rgbaBytes(of: frame.cameraImage, width: width, height: height) else { return region }
        let geometry = TorsoGeometry(torso: frame.torso)
        let shoulderWidth = frame.torso.shoulderWidth
        let neckHalfWidth = ShirtFrameAnalysis.shoulderTopsLeastDistanceFromTheNeckInShoulderWidths * shoulderWidth
        let headHeight = headStartsAboveTheNeckBaseInShoulderWidths * shoulderWidth
        // Only the box around the neck is walked.
        let reach = neckHalfWidth + headHeight
        let left = max(0, Int(geometry.neckBase.x - reach)), right = min(width - 1, Int(geometry.neckBase.x + reach))
        let top = max(0, Int(geometry.neckBase.y - reach)), bottom = min(height - 1, Int(geometry.neckBase.y + reach))
        guard left <= right, top <= bottom else { return region }
        for row in top...bottom {
            for column in left...right {
                let index = row * width + column
                guard frame.personMask[index] > 127 else { continue }
                let point = SIMD2(Double(column), Double(row))
                let above = geometry.distanceAboveTheNeckBase(point)
                guard above > 0, above <= headHeight, abs(geometry.distanceAcross(point)) < neckHalfWidth else { continue }
                region[index] = looksLikeSkin(red: rgba[index * 4], green: rgba[index * 4 + 1], blue: rgba[index * 4 + 2])
            }
        }
        return region
    }

    /// The mask at the working size: where the painting may draw, the analysis's neck cut, and the old top as found.
    static func workingMasks(
        rgba: [UInt8], personMask: [UInt8], previewGarmentCoverage: [UInt8], torso: BodyTorso, width: Int, height: Int
    ) -> (paintable: [Bool], cut: [Bool], oldShirt: [Bool])? {
        let analysisFrame = ShirtSmallFrame(width: width, height: height, rgba: rgba, personMask: personMask, torso: torso)
        guard let oldShirtColor = analysisFrame.measureOldShirtColor() else { return nil }
        let analysis = ShirtFrameAnalysis(frame: analysisFrame, oldShirtColor: oldShirtColor)
        let shoulderWidth = torso.shoulderWidth
        guard shoulderWidth > 2 else { return nil }
        let geometry = TorsoGeometry(torso: torso)
        let hemDistance = (analysis.oldShirtHemDistance.map { $0 + hemMarginInShoulderWidths * shoulderWidth })
            ?? hemWithNoneFoundInTorsoLengths * geometry.torsoLength
        let largestHalfWidth = largestHalfWidthInShoulderWidths * shoulderWidth
        let sleeveHalfWidth = sleeveHalfWidthInShoulderWidths * shoulderWidth
        let arms = [(torso.imageLeftShoulder, torso.imageLeftElbow), (torso.imageRightShoulder, torso.imageRightElbow)].compactMap { shoulder, elbow -> (shoulder: SIMD2<Double>, direction: SIMD2<Double>, reach: Double)? in
            guard let elbow else { return nil }
            let shoulderPoint = SIMD2(Double(shoulder.x), Double(shoulder.y))
            let armVector = SIMD2(Double(elbow.x), Double(elbow.y)) - shoulderPoint
            let armLength = simd_length(armVector)
            guard armLength > 2 else { return nil }
            return (shoulderPoint, armVector / armLength, armLength + sleeveReachPastTheElbowInShoulderWidths * shoulderWidth)
        }

        // The old top: the analysis's old shirt in its zone (green), and every pixel of the person below the neck that looks
        // like the old shirt (blue) down to its hem, beside the torso or along a sleeve.
        var oldShirt = [Bool](repeating: false, count: width * height)
        var cut = [Bool](repeating: false, count: width * height)
        let neckHalfWidth = ShirtFrameAnalysis.shoulderTopsLeastDistanceFromTheNeckInShoulderWidths * shoulderWidth
        let headHeight = headStartsAboveTheNeckBaseInShoulderWidths * shoulderWidth
        for index in 0..<(width * height) {
            // The analysis's cut also marks the tops of the shoulders above the line through the joints where the old top
            // does not read as its own color, which the live preview's fill covers. Here only the neck and the head above
            // it are cut, so the old top on the shoulders is painted over, not put back.
            if analysis.maskPixels[index * 4] > 127 {
                let point = SIMD2(Double(index % width), Double(index / width))
                cut[index] = abs(geometry.distanceAcross(point)) < neckHalfWidth || geometry.distanceAboveTheNeckBase(point) > headHeight
            }
            if analysis.maskPixels[index * 4 + 1] > 127 { oldShirt[index] = true; continue }
            guard analysis.maskPixels[index * 4 + 2] > 127 else { continue }
            let point = SIMD2(Double(index % width), Double(index / width))
            let down = geometry.distanceDownTheTorso(point)
            if down >= 0 && down < hemDistance && abs(geometry.distanceAcross(point)) < largestHalfWidth {
                oldShirt[index] = true
                continue
            }
            for arm in arms {
                let offset = point - arm.shoulder
                let along = simd_dot(offset, arm.direction)
                let outward = abs(offset.x * arm.direction.y - offset.y * arm.direction.x)
                if along >= 0 && along < arm.reach && outward < sleeveHalfWidth {
                    oldShirt[index] = true
                    break
                }
            }
        }

        // The torso itself covers a print on the old top whose colors are not its own, and the preview's garment is where
        // the new top lands.
        let torsoQuad = ShirtTryOnRenderer.bodyTorsoCorners(of: torso).map { SIMD2(Double($0.x), Double($0.y)) }
        var paintable = [Bool](repeating: false, count: width * height)
        for index in 0..<(width * height) {
            if oldShirt[index] || previewGarmentCoverage[index] > 127 { paintable[index] = true; continue }
            guard personMask[index] > 127 else { continue }
            paintable[index] = isInside(SIMD2(Double(index % width) + 0.5, Double(index / width) + 0.5), convexQuad: torsoQuad)
        }
        let closingRadius = max(1, Int((closingRadiusInShoulderWidths * shoulderWidth).rounded()))
        paintable = eroded(dilated(paintable, width: width, height: height, radius: closingRadius), width: width, height: height, radius: closingRadius)
        paintable = withTheHolesFilled(paintable, width: width, height: height)
        // Grown past the outline, but only within a little of the person, so the room around stays the room.
        let growthRadius = max(1, Int((outlineGrowthInShoulderWidths * shoulderWidth).rounded()))
        let personNearby = dilated(personMask.map { $0 > 127 }, width: width, height: height, radius: growthRadius)
        let grown = dilated(paintable, width: width, height: height, radius: growthRadius)
        for index in paintable.indices { paintable[index] = grown[index] && (personNearby[index] || paintable[index]) }

        // Bare skin the new top does not cover is taken away here. The hands, the face, and the neck's skin are taken away
        // at the frame's size, where their edges are exact. The mask never reaches above the neck's base, so the neck cut
        // only decides what the paste puts back.
        for index in 0..<(width * height) where paintable[index] {
            guard personMask[index] > 127, previewGarmentCoverage[index] <= 127, !oldShirt[index] else { continue }
            if looksLikeSkin(red: rgba[index * 4], green: rgba[index * 4 + 1], blue: rgba[index * 4 + 2]) { paintable[index] = false }
        }
        paintable = withoutSmallPieces(paintable, width: width, height: height, smallestPieceSize: Int(smallestPieceShare * Double(width * height)))
        return (paintable, cut, oldShirt)
    }

    /// Gray bytes scaled from one size to another with smooth interpolation, first row at the top.
    static func resizedGrayBytes(_ bytes: [UInt8], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [UInt8]? {
        if width == toWidth && height == toHeight { return bytes }
        guard let image = grayImage(bytes: bytes, width: width, height: height) else { return nil }
        var resized = [UInt8](repeating: 0, count: toWidth * toHeight)
        let drew = resized.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: toWidth, height: toHeight, bitsPerComponent: 8, bytesPerRow: toWidth,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: toWidth, height: toHeight))
            return true
        }
        return drew ? resized : nil
    }

    /// The hands (each one's joints, as a convex hull grown by the fingers' flesh, or a wrist alone as a disc) and the faces
    /// (each box grown for the hair and ears).
    static func handAndFaceRegion(bodyParts: ShirtPaintBodyParts, width: Int, height: Int, shoulderWidth: Double) -> [Bool] {
        var region = [Bool](repeating: false, count: width * height)
        let handMargin = handMarginInShoulderWidths * shoulderWidth
        for handPoints in bodyParts.hands where !handPoints.isEmpty {
            let hull = convexHull(of: handPoints).map { SIMD2(Double($0.x), Double($0.y)) }
            let radius = handPoints.count == 1 ? wristRadiusInShoulderWidths * shoulderWidth : handMargin
            let handXValues = handPoints.map { Double($0.x) }, handYValues = handPoints.map { Double($0.y) }
            guard let minX = handXValues.min(), let maxX = handXValues.max(), let minY = handYValues.min(), let maxY = handYValues.max(),
                  [minX, maxX, minY, maxY, radius].allSatisfy(\.isFinite) else { continue }
            let left = max(0, Int((minX - radius).rounded(.down))), right = min(width - 1, Int((maxX + radius).rounded(.up)))
            let top = max(0, Int((minY - radius).rounded(.down))), bottom = min(height - 1, Int((maxY + radius).rounded(.up)))
            guard left <= right, top <= bottom else { continue }
            for row in top...bottom {
                for column in left...right {
                    let point = SIMD2(Double(column) + 0.5, Double(row) + 0.5)
                    if distance(from: point, toConvexHull: hull) <= radius { region[row * width + column] = true }
                }
            }
        }
        for faceBox in bodyParts.faceBoxes {
            let grownBox = faceBox.insetBy(dx: -faceBox.width * faceBoxGrowthShare, dy: -faceBox.height * faceBoxGrowthShare)
            let left = max(0, Int(grownBox.minX)), right = min(width - 1, Int(grownBox.maxX))
            let top = max(0, Int(grownBox.minY)), bottom = min(height - 1, Int(grownBox.maxY))
            guard left <= right, top <= bottom else { continue }
            for row in top...bottom {
                for column in left...right { region[row * width + column] = true }
            }
        }
        return region
    }

    /// The common skin rule in YCbCr (Cb 77 to 127, Cr 133 to 173), which holds across skin tones because it reads the
    /// color apart from its lightness. Bright or dark extremes, where the chroma is noise, never count.
    static func looksLikeSkin(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let redValue = Double(red), greenValue = Double(green), blueValue = Double(blue)
        let luma = 0.299 * redValue + 0.587 * greenValue + 0.114 * blueValue
        guard luma > 35, luma < 245 else { return false }
        let chromaBlue = 128 - 0.168736 * redValue - 0.331264 * greenValue + 0.5 * blueValue
        let chromaRed = 128 + 0.5 * redValue - 0.418688 * greenValue - 0.081312 * blueValue
        return (77...127).contains(chromaBlue) && (133...173).contains(chromaRed)
    }

    // MARK: Pixel operations

    /// The distance from `point` to the hull, 0 inside it. A hull of one or two points is a point or a segment.
    static func distance(from point: SIMD2<Double>, toConvexHull hull: [SIMD2<Double>]) -> Double {
        guard let first = hull.first else { return .infinity }
        if hull.count >= 3, isInside(point, convexQuad: hull) { return 0 }
        if hull.count == 1 { return simd_length(point - first) }
        var nearest = Double.infinity
        for index in hull.indices {
            let start = hull[index], end = hull[(index + 1) % hull.count]
            let segment = end - start
            let share = simd_length_squared(segment) > 0 ? min(1, max(0, simd_dot(point - start, segment) / simd_length_squared(segment))) : 0
            nearest = min(nearest, simd_length(point - (start + segment * share)))
        }
        return nearest
    }

    /// Whether `point` is inside a convex polygon whose corners go around it in either direction.
    static func isInside(_ point: SIMD2<Double>, convexQuad corners: [SIMD2<Double>]) -> Bool {
        guard corners.count >= 3 else { return false }
        var sign = 0.0
        for index in corners.indices {
            let start = corners[index], end = corners[(index + 1) % corners.count]
            let turn = (end.x - start.x) * (point.y - start.y) - (end.y - start.y) * (point.x - start.x)
            if turn == 0 { continue }
            if sign == 0 { sign = turn } else if (turn > 0) != (sign > 0) { return false }
        }
        return true
    }

    /// The mask grown by a square of `radius`, as two passes of a running count, so it costs the same at any radius.
    static func dilated(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        boxFiltered(mask, width: width, height: height, radius: radius) { count in count > 0 }
    }

    static func eroded(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        let window = (2 * radius + 1) * (2 * radius + 1)
        // Past the frame's edge counts as inside, so a mask that runs off the frame keeps its edge.
        return boxFiltered(mask, width: width, height: height, radius: radius, outsideCountsAsSet: true) { count in count == window }
    }

    private static func boxFiltered(_ mask: [Bool], width: Int, height: Int, radius: Int, outsideCountsAsSet: Bool = false, keep: (Int) -> Bool) -> [Bool] {
        guard radius > 0 else { return mask }
        let outsideValue = outsideCountsAsSet ? 1 : 0
        var rowCounts = [Int](repeating: 0, count: width * height)
        for row in 0..<height {
            var count = 0
            for column in -radius...radius {
                count += (column < 0 || column >= width) ? outsideValue : (mask[row * width + column] ? 1 : 0)
            }
            for column in 0..<width {
                rowCounts[row * width + column] = count
                let leaving = column - radius, entering = column + radius + 1
                count -= (leaving < 0 || leaving >= width) ? outsideValue : (mask[row * width + leaving] ? 1 : 0)
                count += (entering < 0 || entering >= width) ? outsideValue : (mask[row * width + entering] ? 1 : 0)
            }
        }
        let outsideRowCount = outsideValue * (2 * radius + 1)
        var result = [Bool](repeating: false, count: width * height)
        for column in 0..<width {
            var count = 0
            for row in -radius...radius {
                count += (row < 0 || row >= height) ? outsideRowCount : rowCounts[row * width + column]
            }
            for row in 0..<height {
                result[row * width + column] = keep(count)
                let leaving = row - radius, entering = row + radius + 1
                count -= (leaving < 0 || leaving >= height) ? outsideRowCount : rowCounts[leaving * width + column]
                count += (entering < 0 || entering >= height) ? outsideRowCount : rowCounts[entering * width + column]
            }
        }
        return result
    }

    /// The mask with every hole filled: a pixel outside the mask that no path of outside pixels joins to the frame's edge.
    static func withTheHolesFilled(_ mask: [Bool], width: Int, height: Int) -> [Bool] {
        var reachedFromTheEdge = [Bool](repeating: false, count: width * height)
        var pending: [Int] = []
        func visit(_ index: Int) {
            guard !mask[index], !reachedFromTheEdge[index] else { return }
            reachedFromTheEdge[index] = true
            pending.append(index)
        }
        for column in 0..<width { visit(column); visit((height - 1) * width + column) }
        for row in 0..<height { visit(row * width); visit(row * width + width - 1) }
        while let index = pending.popLast() {
            let row = index / width, column = index % width
            if column > 0 { visit(index - 1) }
            if column < width - 1 { visit(index + 1) }
            if row > 0 { visit(index - width) }
            if row < height - 1 { visit(index + width) }
        }
        return reachedFromTheEdge.map { !$0 }
    }

    /// The mask with each 4-connected piece under `smallestPieceSize` pixels taken away.
    static func withoutSmallPieces(_ mask: [Bool], width: Int, height: Int, smallestPieceSize: Int) -> [Bool] {
        guard smallestPieceSize > 1 else { return mask }
        var result = mask
        var visited = [Bool](repeating: false, count: width * height)
        var piece: [Int] = []
        var pending: [Int] = []
        for start in mask.indices where mask[start] && !visited[start] {
            piece.removeAll(keepingCapacity: true)
            pending.append(start)
            visited[start] = true
            while let index = pending.popLast() {
                piece.append(index)
                let row = index / width, column = index % width
                if column > 0, mask[index - 1], !visited[index - 1] { visited[index - 1] = true; pending.append(index - 1) }
                if column < width - 1, mask[index + 1], !visited[index + 1] { visited[index + 1] = true; pending.append(index + 1) }
                if row > 0, mask[index - width], !visited[index - width] { visited[index - width] = true; pending.append(index - width) }
                if row < height - 1, mask[index + width], !visited[index + width] { visited[index + width] = true; pending.append(index + width) }
            }
            if piece.count < smallestPieceSize { for index in piece { result[index] = false } }
        }
        return result
    }

    /// 255 inside the region, falling to 0 over `featherPixels` outside it, so the inside stays exactly protected. Only the
    /// box around the region, grown by the feather, is walked, since the protected parts are a small share of the frame.
    static func feathered(_ region: [Bool], width: Int, height: Int, featherPixels: Int) -> [UInt8] {
        var weights = [UInt8](repeating: 0, count: width * height)
        var left = width, right = -1, top = height, bottom = -1
        for index in region.indices where region[index] {
            let row = index / width, column = index % width
            left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
        }
        guard right >= 0 else { return weights }
        left = max(0, left - featherPixels); right = min(width - 1, right + featherPixels)
        top = max(0, top - featherPixels); bottom = min(height - 1, bottom + featherPixels)
        let boxWidth = right - left + 1, boxHeight = bottom - top + 1
        var ring = [Bool](repeating: false, count: boxWidth * boxHeight)
        for row in 0..<boxHeight {
            for column in 0..<boxWidth where region[(top + row) * width + left + column] { ring[row * boxWidth + column] = true }
        }
        var boxWeights = ring.map { $0 ? 255.0 : 0.0 }
        if featherPixels > 0 {
            for step in 1...featherPixels {
                let grown = dilated(ring, width: boxWidth, height: boxHeight, radius: 1)
                let weight = 255.0 * Double(featherPixels + 1 - step) / Double(featherPixels + 1)
                for index in grown.indices where grown[index] && !ring[index] { boxWeights[index] = weight }
                ring = grown
            }
        }
        for row in 0..<boxHeight {
            for column in 0..<boxWidth { weights[(top + row) * width + left + column] = UInt8(boxWeights[row * boxWidth + column].rounded()) }
        }
        return weights
    }
}

/// The torso's own axes in frame pixels: down from the shoulders toward the hips, and across from the center line.
nonisolated private struct TorsoGeometry {
    let shoulderMidpoint: SIMD2<Double>
    let torsoAxis: SIMD2<Double>
    let along: SIMD2<Double>
    let upward: SIMD2<Double>
    let neckBase: SIMD2<Double>
    let torsoLength: Double

    init(torso: BodyTorso) {
        shoulderMidpoint = SIMD2(Double(torso.shoulderMidpoint.x), Double(torso.shoulderMidpoint.y))
        let hipMidpoint = SIMD2(Double(torso.hipMidpoint.x), Double(torso.hipMidpoint.y))
        torsoLength = max(simd_length(hipMidpoint - shoulderMidpoint), 1)
        torsoAxis = (hipMidpoint - shoulderMidpoint) / torsoLength
        along = SIMD2(Double(torso.imageRightShoulder.x - torso.imageLeftShoulder.x), Double(torso.imageRightShoulder.y - torso.imageLeftShoulder.y)) / max(torso.shoulderWidth, 1)
        var upDirection = SIMD2(along.y, -along.x)
        if upDirection.y > 0 { upDirection = -upDirection }
        upward = upDirection
        neckBase = shoulderMidpoint + upDirection * 0.10 * torso.shoulderWidth
    }

    func distanceDownTheTorso(_ point: SIMD2<Double>) -> Double { simd_dot(point - shoulderMidpoint, torsoAxis) }
    func distanceAcross(_ point: SIMD2<Double>) -> Double { simd_dot(point - shoulderMidpoint, along) }
    /// How far above the neck's base, 10 percent of a shoulder width above the shoulder midpoint as the analysis puts it.
    func distanceAboveTheNeckBase(_ point: SIMD2<Double>) -> Double { simd_dot(point - neckBase, upward) }
}

// MARK: - Vision

/// The faces and hands in the frozen frame. Vision's hand pose gives each hand's joints, and the body pose's wrists stand in
/// for a hand Vision's hand pose missed, such as one in a pocket. Slow (about 100 ms), so call it off the main actor.
nonisolated func shirtPaintBodyParts(in cameraImage: CGImage) -> ShirtPaintBodyParts {
    let width = Double(cameraImage.width), height = Double(cameraImage.height)
    func framePoint(_ visionPoint: CGPoint) -> CGPoint { CGPoint(x: visionPoint.x * width, y: (1 - visionPoint.y) * height) }
    let faceRequest = VNDetectFaceRectanglesRequest()
    let handRequest = VNDetectHumanHandPoseRequest()
    handRequest.maximumHandCount = 4
    let bodyRequest = VNDetectHumanBodyPoseRequest()
    do {
        try VNImageRequestHandler(cgImage: cameraImage, orientation: .up).perform([faceRequest, handRequest, bodyRequest])
    } catch {
        print("Shirt painting: Vision could not read the frame: \(error)")
    }
    var bodyParts = ShirtPaintBodyParts()
    bodyParts.faceBoxes = (faceRequest.results ?? []).map { face in
        let box = face.boundingBox
        return CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height)
    }
    for hand in handRequest.results ?? [] {
        let joints = ((try? hand.recognizedPoints(.all)) ?? [:]).values.filter { $0.confidence > 0.3 }.map { framePoint($0.location) }
        if !joints.isEmpty { bodyParts.hands.append(joints) }
    }
    for body in bodyRequest.results ?? [] {
        for wristName in [VNHumanBodyPoseObservation.JointName.leftWrist, .rightWrist] {
            guard let wrist = try? body.recognizedPoint(wristName), wrist.confidence > 0.3 else { continue }
            bodyParts.hands.append([framePoint(wrist.location)])
        }
    }
    return bodyParts
}

// MARK: - The paste

/// The frozen frame with the painting pasted in the way the furniture's is (`furnitureCompositePasted`: the mask grown by
/// 24 pixels and feathered, with the painting's tone matched to the frame on a ring around it), then the protected regions
/// put back exactly as filmed, so the paste's growth never repaints a hand, the face, or the neck. The whole grown region
/// takes the painting, not only the cells it changed as the furniture's does, since a new top close to the old one's color
/// would otherwise leave the old top's pocket or seams showing through.
nonisolated func shirtPaintedStillPasted(keyframe: CGImage, painted: CGImage, masks: ShirtPaintMasks, context: CIContext) -> CGImage? {
    guard masks.width == keyframe.width, masks.height == keyframe.height,
          let maskImage = grayImage(bytes: masks.paintable, width: masks.width, height: masks.height),
          let pasted = furnitureCompositePasted(keyframe: keyframe, generated: painted, mask: maskImage, keepsOnlyThePieceTheReplyChanged: false, context: context),
          var pastedPixels = rgbaBytes(of: pasted, width: masks.width, height: masks.height),
          let keyframePixels = rgbaBytes(of: keyframe, width: masks.width, height: masks.height) else { return nil }
    for pixelIndex in 0..<(masks.width * masks.height) {
        let protectedWeight = Int(masks.protected[pixelIndex])
        guard protectedWeight > 0 else { continue }
        for channel in 0..<3 {
            let byteIndex = pixelIndex * 4 + channel
            // At a weight of 255 this is the filmed byte exactly.
            let blended = (Int(keyframePixels[byteIndex]) * protectedWeight + Int(pastedPixels[byteIndex]) * (255 - protectedWeight) + 127) / 255
            pastedPixels[byteIndex] = UInt8(blended)
        }
    }
    return rgbImage(bytes: pastedPixels, width: masks.width, height: masks.height)
}

/// An 8-bit gray image of `bytes`, first row at the top.
nonisolated func grayImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard bytes.count == width * height, let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
    )
}

/// An sRGB image of RGBA `bytes` whose alpha is opaque, first row at the top.
nonisolated func rgbImage(bytes: [UInt8], width: Int, height: Int) -> CGImage? {
    guard bytes.count == width * height * 4, let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
}

/// A gray image as the 8-bit gray PNG the Worker reads.
nonisolated func grayPNGData(bytes: [UInt8], width: Int, height: Int) -> Data? {
    guard let image = grayImage(bytes: bytes, width: width, height: height) else { return nil }
    let pngData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return pngData as Data
}

/// An image as a JPEG at `quality`.
nonisolated func jpegData(of image: CGImage, quality: Double = 0.92) -> Data? {
    let jpegData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(jpegData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return jpegData as Data
}

// MARK: - What the Worker is sent

/// The garment in the Worker's own words: enums and a color the app measured, so the print description is the only page
/// text, which the Worker puts in a tag.
nonisolated struct ShirtPaintingGarment: Equatable, Sendable {
    let kind: RoomArtGarment
    let sleeves: RoomArtSleeves
    /// The garment's base color in sRGB, as "#RRGGBB".
    let baseColorHex: String
    let printDescription: String

    /// The Worker takes at most this many UTF-16 units of print description.
    static let mostPrintDescriptionUTF16Units = 300
}

/// A linear-light color as "#RRGGBB" in sRGB, which is how the Worker reads it.
nonisolated func sRGBHex(ofLinear color: ShirtRGB) -> String {
    func encoded(_ linearValue: Float) -> Int {
        let clamped = Double(min(1, max(0, linearValue)))
        let encodedValue = clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
        return Int((encodedValue * 255).rounded())
    }
    return String(format: "#%02X%02X%02X", encoded(color.red), encoded(color.green), encoded(color.blue))
}

/// The product photo the Worker is sent: the page picture that shows the garment's front, cropped to its corners with a 5 percent margin, at
/// the picture's own resolution, since every pixel of a print's letters helps the painting copy them. Nil when the crop is
/// under 32 pixels on a side.
nonisolated func shirtPaintingProductJPEG(picture: CGImage, itemCorners: RoomArtCorners) -> Data? {
    let corners = itemCorners.clockwiseFromTopLeft
    let cornerXValues = corners.map(\.x), cornerYValues = corners.map(\.y)
    guard let minX = cornerXValues.min(), let maxX = cornerXValues.max(), let minY = cornerYValues.min(), let maxY = cornerYValues.max() else { return nil }
    let cornersBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    let cropBox = cornersBox.insetBy(dx: -cornersBox.width * 0.05, dy: -cornersBox.height * 0.05)
        .intersection(CGRect(x: 0, y: 0, width: picture.width, height: picture.height)).integral
    guard cropBox.width >= 32, cropBox.height >= 32, let cropped = picture.cropping(to: cropBox) else { return nil }
    return jpegData(of: cropped)
}

/// What one painting sends: the frozen frame, the product, the mask, and the garment's words.
nonisolated struct ShirtPaintingRequest: @unchecked Sendable {
    // @unchecked because CGImage is immutable.
    let keyframe: CGImage
    let productJPEG: Data
    let masks: ShirtPaintMasks
    let itemTitle: String
    let garment: ShirtPaintingGarment
}

/// The JSON body `/room-furniture-composite` takes for a shirt, or nil when an image cannot be encoded.
nonisolated func shirtPaintingRequestBody(_ request: ShirtPaintingRequest) -> [String: Any]? {
    guard let keyframeJPEG = jpegData(of: request.keyframe),
          let maskPNG = grayPNGData(bytes: request.masks.paintable, width: request.masks.width, height: request.masks.height) else { return nil }
    var printDescription = String.UnicodeScalarView()
    var utf16UnitCount = 0
    for unicodeScalar in request.garment.printDescription.unicodeScalars {
        utf16UnitCount += unicodeScalar.value > 0xFFFF ? 2 : 1
        if utf16UnitCount > ShirtPaintingGarment.mostPrintDescriptionUTF16Units { break }
        printDescription.append(unicodeScalar)
    }
    return [
        "kind": "shirt",
        "keyframeJPEGBase64": keyframeJPEG.base64EncodedString(),
        "keyframeWidth": request.keyframe.width,
        "keyframeHeight": request.keyframe.height,
        "productJPEGBase64": request.productJPEG.base64EncodedString(),
        "maskPNGBase64": maskPNG.base64EncodedString(),
        "itemTitle": roomFurnitureTitleForTheWorker(request.itemTitle),
        "garment": [
            "kind": request.garment.kind.rawValue,
            "sleeves": request.garment.sleeves.rawValue,
            "baseColorHex": request.garment.baseColorHex,
            "printDescription": String(printDescription),
        ],
    ]
}

/// What `/room-furniture-composite` answers: the painted frame as JPEG, at the size OpenAI drew it.
nonisolated private struct ShirtPaintingReply: Decodable {
    let imageJPEGBase64: String
    let width: Int
    let height: Int
}

/// Paints the shirt into the frozen frame through the Worker and pastes the reply back, at the frame's size.
@MainActor
final class ShirtPaintingClient {
    private let compositeURL: URL
    private let session: URLSession
    private let ciContext: CIContext

    /// Tests pass a session configuration whose protocol classes answer for the Worker.
    init(workerBaseURL: String, sessionConfiguration: URLSessionConfiguration = .default, ciContext: CIContext = CIContext()) {
        guard let compositeURL = URL(string: "\(workerBaseURL)/room-furniture-composite") else {
            preconditionFailure("Worker base URL did not form the shirt painting URL: \(workerBaseURL)")
        }
        self.compositeURL = compositeURL
        // The Worker bounds the edit at 120 seconds, so its own 502 arrives before this.
        sessionConfiguration.timeoutIntervalForRequest = RoomFurnitureGenerationClient.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = RoomFurnitureGenerationClient.timeoutSeconds
        session = URLSession(configuration: sessionConfiguration)
        self.ciContext = ciContext
    }

    func paint(_ request: ShirtPaintingRequest) async throws -> CGImage {
        guard let requestBody = shirtPaintingRequestBody(request) else {
            throw RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the frame or the mask could not be encoded")
        }
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONSerialization.data(withJSONObject: requestBody), to: compositeURL, using: session, sendsAppSecret: true
        )
        let responseText = String(decoding: responseData, as: UTF8.self)
        switch statusCode {
        case 200: break
        case 503: throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: responseText)
        default: throw RoomFurnitureGenerationError.workerReturned(statusCode: statusCode, body: responseText)
        }
        guard let reply = try? JSONDecoder().decode(ShirtPaintingReply.self, from: responseData),
              let paintedJPEG = Data(base64Encoded: reply.imageJPEGBase64),
              let painted = decodedImage(from: paintedJPEG),
              painted.width == reply.width, painted.height == reply.height else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply holds no painted frame of the size it states")
        }
        // The paste walks every pixel of the frame, so it runs off the main actor, where the panel draws.
        let pasteContext = ciContext
        // A CGImage is immutable, so the detached task may read it.
        nonisolated(unsafe) let keyframe = request.keyframe
        let masks = request.masks
        let pastedOrNil = await Task.detached(priority: .userInitiated) {
            shirtPaintedStillPasted(keyframe: keyframe, painted: painted, masks: masks, context: pasteContext)
        }.value
        guard let pasted = pastedOrNil else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the painting could not be pasted into the frame")
        }
        return pasted
    }
}

/// The failure a painting call ends in, for its spoken line.
nonisolated func shirtPaintingFailure(for error: Error) -> ShirtPaintingFailure {
    switch error {
    case RoomFurnitureGenerationError.serviceIsNotSetUp: return .serviceIsNotSetUp
    // Every room art route answers 401 to a missing or wrong app secret.
    case RoomFurnitureGenerationError.workerReturned(statusCode: 401, _): return .appSecretRefused
    // No answer at all, as the other room art routes read it.
    case is URLError: return .workerUnreachable
    default: return .paintingFailed
    }
}
