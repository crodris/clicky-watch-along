//
//  ShirtTryOnRenderer.swift
//  leanring-buddy
//
//  Draws the garment over the shirt the learner wears so it looks worn in the room, not pasted on. The garment's torso is
//  mapped onto the body's torso and each sleeve along its upper arm; the person mask keeps the shirt on the body and the neck
//  and face stay. The color is worked out in linear light: the product photo over its own white is the cloth's albedo, which
//  is lit by the room's white and tinted toward the room's light, then shaded by the old shirt's own light and folds, darkened
//  a little where cloth turns away at its edges, and rolled off softly at the top so no highlight blows out. Core Image draws
//  it with built-in filters.
//
//  The questions Core Image's filters cannot ask (which pixels are the old shirt, where the neck is, the room's light) are
//  answered on a small copy in ShirtFrameAnalysis.swift. They are CPU loops, which an unoptimized Debug build runs many
//  times slower than a release build, so they run on their own queue every few frames, and each frame reuses the newest
//  answer with its masks moved along with the torso since. The frame itself only builds Core Image filters.
//
//  Points are in camera pixels with y down. Core Image's y grows up, so every point crosses `flipped` on the way in.
//

import CoreImage
import Foundation
import os
import simd

extension BodyTorso {
    /// The torso in a frame `scale` times as large.
    nonisolated func scaled(by scale: Double) -> BodyTorso {
        func scaledPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
        return BodyTorso(
            imageLeftShoulder: scaledPoint(imageLeftShoulder), imageRightShoulder: scaledPoint(imageRightShoulder),
            imageLeftHip: scaledPoint(imageLeftHip), imageRightHip: scaledPoint(imageRightHip),
            hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: shouldersAreSeen,
            imageLeftElbow: imageLeftElbow.map(scaledPoint), imageRightElbow: imageRightElbow.map(scaledPoint)
        )
    }
}

/// One sleeve as it was drawn: its side, where its quadrilateral landed (seam top, opening outer, opening inner, seam
/// bottom, in camera pixels with y down), and whether it lies along its arm or keeps the angle the whole garment gives it.
nonisolated struct ShirtDrawnSleeve: Sendable {
    let side: ShirtSleeveSide
    let landing: [CGPoint]
    let liesAlongTheArm: Bool

    /// From the middle of the seam to the middle of the opening.
    var axis: CGVector {
        CGVector(dx: (landing[1].x + landing[2].x - landing[0].x - landing[3].x) / 2, dy: (landing[1].y + landing[2].y - landing[0].y - landing[3].y) / 2)
    }
}

/// One composite and the layers it was made of. The panel draws only `image`; the look checks in ShirtLookCheckTests.swift
/// read the rest to measure the result against the frame.
nonisolated struct ShirtTryOnComposition: @unchecked Sendable {
    // @unchecked because CIImage is immutable, so sharing one across queues is safe.

    /// The frame with the garment drawn on it.
    let image: CIImage
    /// Where the garment itself covers the frame, 0 to 1 in the red channel: its warped alpha times the person mask, minus
    /// the neck cut. The base color fill is not in it.
    let garmentAlpha: CIImage
    /// The garment and the base color fill together, the mask the garment is drawn with.
    let totalAlpha: CIImage
    /// The product photo's colors where they land in the frame, over the base color, before any light or shading.
    let warpedGarmentColor: CIImage
    /// The body's torso corners the garment's torso landed on, top left first, in camera pixels with y down.
    let landedTorsoCorners: [CGPoint]
    /// The sleeves as drawn, image left first: along the arms, or at the whole garment's angle. Empty when the garment has
    /// no sleeves apart or an elbow is not seen, when the garment is drawn in one piece.
    let sleeves: [ShirtDrawnSleeve]
}

/// What one run of the frame analysis learned, which the frames after it reuse.
nonisolated private struct ShirtFrameAnalysisResult: @unchecked Sendable {
    // @unchecked because CIImage is immutable, so sharing one across queues is safe.

    /// Counts runs, so each frame knows whether it has folded this one's numbers in yet.
    let runNumber: Int
    /// The torso the analysis ran for, in camera pixels. The masks are moved from it to each frame's torso.
    let torso: BodyTorso
    /// The analysis masks (`ShirtFrameAnalysis.maskPixels`) as an image the size of the small copy.
    let masks: CIImage
    let oldShirtMedianLinearLuminance: Float
    /// The row where the learner's neck meets the old shirt, and how far below the shoulders the old shirt ends, both in
    /// camera pixels, each nil when it was not found.
    let neckRow: Double?
    let oldShirtHemDistance: Double?
    let roomLight: ShirtRoomLight?
    /// The old shirt's half widths at `ShirtFrameAnalysis.torsoWidthFractions` and its old sleeves, both in camera pixels
    /// for `torso`.
    let oldShirtHalfWidths: [[Double?]]
    let oldSleeves: [ShirtOldSleeveExtent?]

    func numbered(_ runNumber: Int) -> ShirtFrameAnalysisResult {
        ShirtFrameAnalysisResult(
            runNumber: runNumber, torso: torso, masks: masks, oldShirtMedianLinearLuminance: oldShirtMedianLinearLuminance,
            neckRow: neckRow, oldShirtHemDistance: oldShirtHemDistance, roomLight: roomLight,
            oldShirtHalfWidths: oldShirtHalfWidths, oldSleeves: oldSleeves
        )
    }
}

/// Draws a garment over the learner. One renderer serves one try-on session on one queue: it keeps a few smoothed numbers
/// between frames (the old shirt's color, the room's light, how far the necklines are apart, where the old shirt ends), so
/// use `reset()` for a new session or a new garment, and call `composite` from one queue only.
nonisolated final class ShirtTryOnRenderer: @unchecked Sendable {
    /// The per-frame questions run on a copy of the frame this wide.
    static let analysisFrameWidth = 320.0
    /// A new analysis starts at most every this many frames, and only once the last has finished. About 10 a second at 30
    /// frames a second, which keeps the masks close to the body while a Debug build's slow loops never hold a frame up.
    static let framesBetweenAnalyses = 3
    /// Where the garment's bottom edge sits along the body, in torso lengths from the shoulder midpoint: the spike puts the
    /// shirt's hem 8 percent of a torso below the hips.
    static let garmentBottomInTorsoLengths = 1.08
    /// The analysis masks are blurred by this many of their own pixels once scaled up, which turns their steps into curves.
    static let analysisMaskSmoothingInSmallPixels = 0.8
    /// The base color fill is closed (grown by twice this, then shrunk by this many analysis pixels), which fills holes a
    /// few pixels wide where a fold read as not the old shirt, and leaves it grown by this much under the garment's edge,
    /// so the two meet with no gap.
    static let baseColorGrowthUnderTheGarmentInSmallPixels = 1.6
    /// The garment is drawn where the person mask is over the first of these and fully over the second. The mask's soft
    /// edge starts in the room, so a looser ramp would lay the bright garment over the wall as a light halo.
    static let personMaskRampForTheGarment = (from: 0.5, to: 0.9)
    /// How far the room's color is carried in under the person's outline, in half size pixels.
    static let roomBehindBlurSigmaAtHalfSize = 3.0
    /// The room shows through under the garment's reach from a person mask of the first of these, fully from the second up to
    /// where the garment draws, so the old shirt's dark blend with the wall outside the matte's 0.5 line goes too.
    static let roomShowsThroughFromPersonMask = (from: 0.12, to: 0.3)

    // The light.
    /// Cloth is lit a little below the room's white: the white is read from walls and doors that face the light, and a
    /// white T-shirt reflects a little less than a white wall does.
    static let clothShareOfTheRoomWhite: Float = 0.9
    /// How much of the room light's color the garment takes. All of it would tint a white shirt the color of a beige wall
    /// when the walls are what was measured, and none leaves a neutral shirt cold in a warm room.
    static let roomTintStrength: Float = 0.6
    /// The room's white when it cannot be measured, a dim room's.
    static let roomWhiteWhenUnmeasured: Float = 0.35
    /// Each new analysis moves the smoothed room light and old shirt brightness this share of the way, so a hand passing a
    /// lamp does not flicker the shirt.
    static let roomLightSmoothingShare: Float = 0.3

    // The shading, in half size pixels.
    /// The old shirt's broad light: how the body turns toward and away from the light.
    static let broadShadingBlurSigmaAtHalfSize = 7.0
    /// The widest light, which a broad light with no old shirt near falls back to: the side of the body, the top of the arm.
    static let widestShadingBlurSigmaAtHalfSize = 30.0
    /// The old shirt's folds: its finer light over the broad light, so a crease shows through the print.
    static let foldShadingBlurSigmaAtHalfSize = 2.5
    static let broadShadingRange = (lowest: 0.5, highest: 1.7)
    static let foldShadingRange = (lowest: 0.9, highest: 1.1)
    /// The shading is raised to this power before it lights the garment. A dark webcam shirt's light is mostly noise at its
    /// finer scales, and in linear light that noise is large next to its level, so the full ratio mottles a light garment
    /// like tie-dye; this keeps the body's light and folds and quiets the noise.
    static let shadingStrength = 0.8
    /// The old shirt's pixels are shrunk by this many small pixels before its light is read. A pixel next to the body's
    /// outline or the old shirt's piping still passes the color rule but carries some of the bright wall or trim, which
    /// showed as a light rim along the body's sides and light lines where the piping was.
    static let shadingWeightShrinkInSmallPixels = 1.2
    /// A pixel brighter than the first of these times the old shirt's median counts less toward its light, and one brighter
    /// than the second not at all. The broad shading tops out at 1.7, so cloth that bright adds nothing but a blend does.
    static let shadingBrightestShareOfTheMedian = (from: 2.0, to: 3.0)
    /// How much old shirt weight a shading sample needs before it is believed, as a share of a pixel. Where no old shirt is
    /// near, such as a sleeve over a bare arm, the shading falls back to a broader band's light (see `shadingImage`).
    static let shadingWeightFloor = 0.02

    // The cloth's edges.
    /// Cloth turns away from the camera at the body's outline, the neck, and the armpits, and catches less light there: it is
    /// darkened by up to this share at its edge, fading over `edgeDarkeningReachInShoulderWidths` inside.
    static let edgeDarkeningStrength = 0.26
    static let edgeDarkeningReachInShoulderWidths = 0.035

    // The highlights.
    /// Linear values above this roll off softly toward `highlightCeiling` instead of clipping, so a lit cream shirt keeps its
    /// cream and its folds instead of turning flat white.
    static let highlightKnee = 0.6
    /// The brightest linear value the garment reaches, sRGB 242.
    static let highlightCeiling = 0.88
    /// The highlight rolloff's input runs from 0 to this, in linear light: four times a white wall, more than any lit cloth.
    static let highlightRolloffDomainTop = 4.0

    // The sleeves.
    /// A flat sleeve's opening is half the sleeve's circumference; on the arm, seen from the front, it shows a little wider
    /// than the arm, so it lands at this share of its flat width.
    static let sleeveOpeningShareOnTheArm = 0.8
    /// How far the opening's center moves from the line through the seam's middle toward the arm's own line.
    static let sleeveOpeningShareTowardTheArmLine = 0.5
    /// A sleeve lengthened to cover the old one stops this share of the way to the elbow.
    static let mostSleeveReachShareOfTheArm = 0.95
    /// The sleeves are drawn apart along the arms once an arm turns out this far past its whole-garment sleeve, and go back
    /// to the whole garment once both arms are back within `armPastTheSleeveToGoBackToTheWholeGarmentDegrees`.
    static let armPastTheSleeveToDrawItApartDegrees = 10.0
    static let armPastTheSleeveToGoBackToTheWholeGarmentDegrees = 4.0

    // Covering the old shirt.
    /// The garment's sides and sleeves reach this far past the old shirt they cover, in shoulder widths.
    static let oldShirtCoverMarginInShoulderWidths = 0.03
    /// The most a lower torso corner moves out to cover a looser old shirt, so a misread never turns the shirt into a tent.
    static let mostHipWideningInShoulderWidths = 0.15
    /// How far above the learner's own neckline the garment's front collar lands. The old collar's edge is a few pixels of
    /// dark blend with the neck's skin, and a collar any lower leaves it as a dark line between the two.
    static let frontCollarRiseAboveTheOldNecklineInShoulderWidths = 0.05
    /// The fill covers the old shirt within this many shoulder widths of the center: over the old sleeves when the garment is
    /// drawn in one piece, and only over the torso (its shoulder corners are 0.62 out) when the sleeves are drawn apart,
    /// since each is then lengthened to cover its old sleeve itself, and a fill out there would hang under it as a tab.
    static let oldShirtZoneHalfWidthWithTheGarmentWhole = 0.9
    static let oldShirtZoneHalfWidthWithTheSleevesApart = 0.62

    private let ciContext: CIContext
    private let analysisRunsInTheBackground: Bool
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let linearColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let analysisQueue = DispatchQueue(label: "com.crodris.clicky.shirt-try-on.analysis", qos: .userInitiated)
    private let highlightRolloffCurve = ShirtTryOnRenderer.highlightRolloffCurveData()

    /// Shared with the analysis queue.
    private struct AnalysisState {
        var latestResult: ShirtFrameAnalysisResult?
        var runIsInFlight = false
        var nextRunNumber = 1
        var smoothedOldShirtColor: SIMD3<Float>?
        /// Counts resets, so a run that finishes after one does not bring the last session's answer back.
        var generation = 0
    }
    private let analysisState = OSAllocatedUnfairLock(initialState: AnalysisState())

    // Written and read on the one queue that calls `composite`.
    private var framesSinceAnAnalysisStarted = 0
    private var foldedRunNumber = 0
    private var smoothedNeckShift = 0.0
    private var hasNeckShift = false
    private var smoothedTorsoLengthInShoulderWidths: Double?
    private var smoothedRoomWhite: Float?
    private var smoothedIlluminant = SIMD3<Float>(1, 1, 1)
    private var smoothedOldShirtMedianLinearLuminance: Float?
    /// How far each lower torso corner, image left first, moves out to cover the old shirt, in shoulder widths.
    private var smoothedHipWideningInShoulderWidths = [0.0, 0.0]
    /// Each old sleeve, image left first, in shoulder widths.
    private var smoothedOldSleevesInShoulderWidths: [ShirtOldSleeveExtent?] = [nil, nil]
    private var lastFrameDrewTheSleevesApart = false
    private var lastFrameLaidTheSleevesAlongTheArms = false

    /// `ciContext` reads the small frame back for the analysis. Pass the one that draws the frames. With
    /// `analysisRunsInTheBackground` (the panel's way), the first frames are drawn without the garment until the first
    /// analysis is in, and later analyses never hold a frame up; without it every frame analyzes itself first, which a test
    /// needs to see the garment on the frame it passed.
    init(ciContext: CIContext = CIContext(), analysisRunsInTheBackground: Bool = true) {
        self.ciContext = ciContext
        self.analysisRunsInTheBackground = analysisRunsInTheBackground
    }

    func reset() {
        analysisState.withLock { state in
            state = AnalysisState(generation: state.generation + 1)
        }
        framesSinceAnAnalysisStarted = 0
        foldedRunNumber = 0
        smoothedNeckShift = 0
        hasNeckShift = false
        smoothedTorsoLengthInShoulderWidths = nil
        smoothedRoomWhite = nil
        smoothedIlluminant = SIMD3(1, 1, 1)
        smoothedOldShirtMedianLinearLuminance = nil
        smoothedHipWideningInShoulderWidths = [0, 0]
        smoothedOldSleevesInShoulderWidths = [nil, nil]
        lastFrameDrewTheSleevesApart = false
        lastFrameLaidTheSleevesAlongTheArms = false
    }

    /// `frame` with `garment` drawn over the person's shirt. `personMask` is white where the person is (any size, it is scaled
    /// to the frame), and should be made with `CIImage(cvPixelBuffer:, options: [.colorSpace: NSNull()])` so Core Image
    /// reads its values as they are. `torso` comes from `ShirtFraming.ready`. The result is lazy, with the frame's extent.
    func composite(frame: CIImage, personMask: CIImage, torso: BodyTorso, garment: ShirtGarment) -> CIImage {
        composition(frame: frame, personMask: personMask, torso: torso, garment: garment)?.image ?? frame
    }

    /// The composite with its layers, or nil when the garment cannot be drawn on this frame (too small a frame, no analysis
    /// in yet, no old shirt to measure, or a torso that cannot be mapped), when `composite` returns the frame as it is.
    func composition(frame: CIImage, personMask: CIImage, torso suppliedTorso: BodyTorso, garment: ShirtGarment) -> ShirtTryOnComposition? {
        let frameExtent = frame.extent
        guard frameExtent.width >= 64, frameExtent.height >= 64, !personMask.extent.isEmpty else { return nil }
        let frameWidth = frameExtent.width
        let shoulderWidth = suppliedTorso.shoulderWidth

        // 1. The analysis: the newest one, and a new one started when it is due.
        func torsoWithTheLearnedLength() -> BodyTorso {
            smoothedTorsoLengthInShoulderWidths.map { suppliedTorso.withTorsoLength($0 * suppliedTorso.shoulderWidth) } ?? suppliedTorso
        }
        // While the sleeves are drawn apart, each is lengthened over its old sleeve, so the fill stays on the torso, where a
        // tab of it hanging under a sleeve would show. The last frame says whether they were, since a sleeve that cannot land
        // falls back to the garment in one piece, whose sleeves cover less of the old ones.
        let oldShirtZoneHalfWidth = lastFrameDrewTheSleevesApart ? Self.oldShirtZoneHalfWidthWithTheSleevesApart : Self.oldShirtZoneHalfWidthWithTheGarmentWhole
        guard let analysis = analysisForThisFrame(frame: frame, personMask: personMask, torso: torsoWithTheLearnedLength(), oldShirtZoneHalfWidth: oldShirtZoneHalfWidth) else { return nil }
        foldInTheNumbers(of: analysis)
        let torso = torsoWithTheLearnedLength()
        // How the body moved since the analysis ran, which moves its masks and its neck row with it.
        let motionSinceTheAnalysis = Self.motion(from: analysis.torso, to: torso)

        // 2. Where the garment lands, with the necklines met.
        let sourceCorners = garment.torsoCorners.clockwiseFromTopLeft
        var bodyCorners = Self.bodyTorsoCorners(of: torso, widenedHipsBy: smoothedHipWideningInShoulderWidths)
        guard let unshiftedHomography = perspectiveTransform(from: sourceCorners, to: bodyCorners) else { return nil }
        var rawNeckShift = 0.0
        if garment.frontNeckWasFound, let neckRowAtTheAnalysis = analysis.neckRow {
            // The front collar rises a little above the old neckline, so the old shirt's own collar never shows above it.
            let neckRow = neckRowAtTheAnalysis + (torso.shoulderMidpoint.y - analysis.torso.shoulderMidpoint.y)
                - Self.frontCollarRiseAboveTheOldNecklineInShoulderWidths * shoulderWidth
            let garmentNeckInFrame = applyingPerspective(unshiftedHomography, to: garment.frontNeckPoint)
            let difference = neckRow - garmentNeckInFrame.y
            // Further apart than a quarter of the shoulders, the scan found something other than the old collar.
            if abs(difference) < 0.25 * shoulderWidth { rawNeckShift = difference }
        }
        smoothedNeckShift = hasNeckShift ? smoothedNeckShift + (rawNeckShift - smoothedNeckShift) * 0.35 : rawNeckShift
        hasNeckShift = true
        // Only the shoulder corners move, so the collar meets the neck while the hem stays at the old shirt's hem.
        bodyCorners = bodyCorners.enumerated().map { index, corner in index < 2 ? CGPoint(x: corner.x, y: corner.y + smoothedNeckShift) : corner }
        guard let homography = perspectiveTransform(from: sourceCorners, to: bodyCorners) else { return nil }

        // 3. The garment warped onto the body: in one piece when an elbow is not seen, or its torso with each sleeve drawn on
        // its own. While an arm hangs below its sleeve, the sleeve keeps the whole garment's angle, which stands off a hanging
        // arm as a worn short sleeve does and covers the old sleeve and shoulder, where a sleeve laid along the hanging arm
        // left the old one showing outside it, and it is lengthened over the old sleeve's hem. Once an arm rises past its
        // sleeve (`wholeGarmentSleevesHoldTheArms`), the sleeves lie along the arms. A garment much larger than its landing
        // is scaled down first with Lanczos, since the warp samples bilinearly and would shimmer the print.
        let landedTorsoWidth = hypot(bodyCorners[1].x - bodyCorners[0].x, bodyCorners[1].y - bodyCorners[0].y)
        let garmentTorsoWidth = max(garment.torsoCorners.topRight.x - garment.torsoCorners.topLeft.x, 1)
        let preScale = min(1, landedTorsoWidth / garmentTorsoWidth * 1.15)
        func preScaled(_ image: CIImage) -> CIImage {
            preScale < 0.8 ? image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: preScale, kCIInputAspectRatioKey: 1]) : image
        }
        let clearFrame = CIImage(color: .clear).cropped(to: frameExtent)
        let wholeGarmentBox = CGRect(origin: .zero, size: garment.size)
        var warpedGarment: CIImage
        // The sleeves land by the torso's map before the neck match, except each seam's top, which moves with the shoulder
        // corners so the sleeve stays joined to the torso. Raising the shoulder corners stretches the garment's top, which
        // would lift each sleeve's armpit too and bare the old shirt under it.
        let sleeveHomography = unshiftedHomography
        let wholeGarmentSleeves = Self.wholeGarmentSleeveLandings(of: garment, torso: torso, torsoHomography: sleeveHomography)
        let sleevesHoldTheArms = Self.wholeGarmentSleevesHoldTheArms(
            wholeGarmentSleeves, torso: torso,
            pastTheSleeveDegrees: lastFrameLaidTheSleevesAlongTheArms ? Self.armPastTheSleeveToGoBackToTheWholeGarmentDegrees : Self.armPastTheSleeveToDrawItApartDegrees
        )
        var drawnSleeves: [ShirtDrawnSleeve] = []
        if let sleeveLayers = warpedSleeves(
            of: garment, torso: torso, torsoHomography: sleeveHomography, shoulderHomography: homography,
            landedTorsoWidth: landedTorsoWidth, frameExtent: frameExtent, alongTheArms: !sleevesHoldTheArms
        ),
           let torsoWithoutSleeves = garment.torsoWithoutSleeves,
           let warpedTorso = Self.warped(preScaled(torsoWithoutSleeves), lyingIn: wholeGarmentBox, by: homography, frameExtent: frameExtent) {
            // The sleeves go under the torso, which covers their tucked-in strip at the seam.
            let sleevesUnderneath = sleeveLayers.reduce(clearFrame) { layers, sleeve in sleeve.image.composited(over: layers) }
            warpedGarment = warpedTorso.composited(over: sleevesUnderneath).cropped(to: frameExtent)
            // A sleeve from a photo on a model keeps the angle it hung at off the model's arm, the way a whole garment's does.
            drawnSleeves = sleeveLayers.map { ShirtDrawnSleeve(side: $0.side, landing: $0.landing, liesAlongTheArm: garment.modelPose == nil && !sleevesHoldTheArms) }
        } else {
            guard let warpedWhole = Self.warped(preScaled(garment.cutout), lyingIn: wholeGarmentBox, by: homography, frameExtent: frameExtent) else { return nil }
            warpedGarment = warpedWhole.composited(over: clearFrame).cropped(to: frameExtent)
        }

        // 4. The masks.
        let scaledPersonMask = Self.channel(Self.scaled(personMask, toFill: frameExtent), 0)
        let personOpacity = Self.ramp(scaledPersonMask, from: Self.personMaskRampForTheGarment.from, to: Self.personMaskRampForTheGarment.to)
        let cameraPixelsPerSmallPixel = frameWidth / analysis.masks.extent.width
        // The analysis masks are a quarter of the frame's width, so scaled up they are blocky. Blurred by about one small
        // pixel before their ramp, their edges come out as smooth curves instead of steps.
        let movedMasks = Self.scaled(analysis.masks, toFill: frameExtent)
            .transformed(by: Self.coreImageTransform(of: motionSinceTheAnalysis, frameExtent: frameExtent))
            .clampedToExtent().applyingGaussianBlur(sigma: cameraPixelsPerSmallPixel * Self.analysisMaskSmoothingInSmallPixels).cropped(to: frameExtent)
        let neckCut = Self.ramp(Self.channel(movedMasks, 0), from: 0.3, to: 0.7)
        let uncoveredOldShirt = Self.ramp(Self.channel(movedMasks, 1), from: 0.3, to: 0.7)
        let oldShirtForTheShading = Self.channel(movedMasks, 2)

        let alphaOfTheGarment = Self.multiplied(Self.multiplied(Self.channel(warpedGarment, 3), personOpacity), Self.inverted(neckCut))
        // The old shirt the garment's outline misses (the waist, under the arms, the tops of the shoulders) takes the
        // garment's base color. The fill grows a little under the garment's edge, so no gap of the old shirt shows between
        // them, and reaches the person's edge as the garment does, where the room shows through under it (step 6), so the
        // old shirt's outline at the silhouette is covered too.
        let growthRadius = cameraPixelsPerSmallPixel * Self.baseColorGrowthUnderTheGarmentInSmallPixels
        let grownUncoveredOldShirt = uncoveredOldShirt
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2 * growthRadius])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: growthRadius])
            .cropped(to: frameExtent)
        let fillReach = Self.multiplied(grownUncoveredOldShirt, Self.inverted(neckCut))
        let baseColorCoverage = Self.multiplied(fillReach, personOpacity)
        // The garment is drawn over the base color, so their alphas join the way two layers do: a + (1 - a) b, which is the
        // screen blend. Where the garment's softened edge meets the fill, the two together cover the old shirt with no
        // notch between them, where the larger of the two would leave a dip. Core Image's addition filter adds the gray
        // images' own alphas too, which skews the mask, so it is not used here.
        let totalAlpha = alphaOfTheGarment.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: baseColorCoverage])

        // 5. The color, in Core Image's linear working space. The garment lies over the base color by its own alpha, so its
        // softened edge fades into the fill and not into the old shirt.
        let baseColor = CIColor(red: CGFloat(garment.baseColor.red), green: CGFloat(garment.baseColor.green), blue: CGFloat(garment.baseColor.blue), colorSpace: sRGBColorSpace) ?? .white
        // Beyond the garment's outline the fill is the cloth's base color, which the shading then lights like the garment. Rows
        // of the garment smeared sideways into it read as a glitch on a striped shirt, and the lower torso is widened to cover
        // a looser old shirt, so little fill is left.
        let fillColors = CIImage(color: baseColor).cropped(to: frameExtent)
        let garmentWithBaseColor = warpedGarment.composited(over: fillColors)
        // Albedo times the room's light: the photo over its own white, times the cloth's share of the room's white, tinted.
        let roomWhite = smoothedRoomWhite ?? Self.roomWhiteWhenUnmeasured
        let tint = SIMD3<Float>(repeating: 1) + (smoothedIlluminant - 1) * Self.roomTintStrength
        let lightOnEachChannel = tint * roomWhite * Self.clothShareOfTheRoomWhite / simd_max(garment.photoWhite, SIMD3(repeating: 0.05))
        let lit = garmentWithBaseColor.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(lightOnEachChannel.x), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(lightOnEachChannel.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(lightOnEachChannel.z), w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let shading = shadingImage(
            frame: frame, oldShirtForTheShading: oldShirtForTheShading, frameExtent: frameExtent, cameraPixelsPerSmallPixel: cameraPixelsPerSmallPixel,
            oldShirtMedianLinearLuminance: Double(smoothedOldShirtMedianLinearLuminance ?? analysis.oldShirtMedianLinearLuminance)
        )
        // The cloth's outline is the garment and its base color fill together, so the fill below a short garment's hem is not
        // darkened as an edge.
        let edgeDarkening = edgeDarkeningImage(clothAlpha: totalAlpha, frameExtent: frameExtent, shoulderWidth: shoulderWidth)
        let worn = Self.multiplied(Self.multiplied(lit, shading), edgeDarkening)
            .clampedToExtent().applyingGaussianBlur(sigma: 0.7).cropped(to: frameExtent)
            .applyingFilter("CIColorCurves", parameters: [
                "inputCurvesData": highlightRolloffCurve, "inputCurvesDomain": CIVector(x: 0, y: CGFloat(Self.highlightRolloffDomainTop)),
                "inputColorSpace": linearColorSpace,
            ])

        // 6. The garment over the frame, where the total alpha says. In the person matte's soft edge the frame is the old shirt
        // blended with the room, so a light garment drawn partly over it, or drawn up to it, would keep a dark outline of the
        // old shirt. Where the garment reaches, that edge shows the room behind the person instead, from a person mask of
        // `roomShowsThroughFromPersonMask` in, and only where enough of the room is near to know its color.
        let roomBehind = roomBehindThePersonImage(frame: frame, scaledPersonMask: scaledPersonMask, frameExtent: frameExtent)
        let roomBehindThePerson = roomBehind.room
        let garmentReach = Self.multiplied(Self.channel(warpedGarment, 3), Self.inverted(neckCut))
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: fillReach])
        let inTheMattesEdge = Self.ramp(scaledPersonMask, from: Self.roomShowsThroughFromPersonMask.from, to: Self.roomShowsThroughFromPersonMask.to)
        let roomShowsThrough = Self.multiplied(Self.multiplied(Self.multiplied(garmentReach, Self.inverted(personOpacity)), inTheMattesEdge), roomBehind.isKnown)
        let underneath = roomBehindThePerson.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: frame, kCIInputMaskImageKey: roomShowsThrough])
        let image = worn
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: underneath, kCIInputMaskImageKey: totalAlpha])
            .cropped(to: frameExtent)
        lastFrameDrewTheSleevesApart = !drawnSleeves.isEmpty
        lastFrameLaidTheSleevesAlongTheArms = drawnSleeves.contains(where: \.liesAlongTheArm)
        return ShirtTryOnComposition(
            image: image, garmentAlpha: alphaOfTheGarment, totalAlpha: totalAlpha, warpedGarmentColor: garmentWithBaseColor,
            landedTorsoCorners: bodyCorners, sleeves: drawnSleeves
        )
    }

    // MARK: The light

    /// The old shirt's light as a gray image around 1: its broad light over its median, times its folds over its broad light.
    /// Each is a normalized blur, the blur of the luminance where the old shirt is over the blur of where it is, so the room
    /// beside the body, the arms, and the old shirt's own print and trim never bleed into it. That bleed was the light rim
    /// along the body's sides. Where a band has too little old shirt near, it takes the next broader band's light, and the
    /// broadest takes the median, so a gap in the old shirt (its piping, the body's outline) is lit like the cloth around it
    /// and never like the median while that cloth is in shadow.
    private func shadingImage(frame: CIImage, oldShirtForTheShading: CIImage, frameExtent: CGRect, cameraPixelsPerSmallPixel: Double, oldShirtMedianLinearLuminance: Double) -> CIImage {
        let halfExtent = CGRect(x: 0, y: 0, width: (frameExtent.width / 2).rounded(), height: (frameExtent.height / 2).rounded())
        let luminance = frame.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let halfSizeLuminance = Self.scaled(luminance, toFill: halfExtent)
        let median = max(oldShirtMedianLinearLuminance, 1e-4)
        // The weight is made hard before it is shrunk, since the smoothed mask's soft edge would only fade the shrink, and a
        // pixel far brighter than the old shirt's median is a blend with the wall or the trim, not the cloth's own light.
        let notTooBright = Self.inverted(Self.ramp(
            halfSizeLuminance, from: Self.shadingBrightestShareOfTheMedian.from * median, to: Self.shadingBrightestShareOfTheMedian.to * median
        ))
        let halfSizeWeight = Self.multiplied(
            Self.ramp(Self.scaled(oldShirtForTheShading, toFill: halfExtent), from: 0.5, to: 0.9)
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: cameraPixelsPerSmallPixel * Self.shadingWeightShrinkInSmallPixels / 2])
                .cropped(to: halfExtent),
            notTooBright
        )
        let weightedLuminance = Self.multiplied(halfSizeLuminance, halfSizeWeight)
        let floor = Self.shadingWeightFloor
        // (blur(luminance * weight) + floor * fallback) / (blur(weight) + floor), each a gray image, which is the plain ratio
        // blur(luminance * weight) / blur(weight) laid over the fallback by blur(weight) / (blur(weight) + floor).
        func normalizedBlur(sigma: Double, fallback: CIImage) -> CIImage {
            let blurredWeight = halfSizeWeight.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: halfExtent)
            let blurredLuminance = weightedLuminance.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: halfExtent)
            // The divide blend divides its background by its input. The tiny bias keeps an empty weight from dividing by 0.
            let plainRatio = Self.withBias(blurredWeight, parameters: ["inputBiasVector": CIVector(x: 1e-5, y: 1e-5, z: 1e-5, w: 0)])
                .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: blurredLuminance])
            let trust = Self.withBias(blurredWeight, parameters: ["inputBiasVector": CIVector(x: floor, y: floor, z: floor, w: 0)])
                .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: blurredWeight])
            return plainRatio.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: fallback, kCIInputMaskImageKey: trust]).cropped(to: halfExtent)
        }
        let medianImage = CIImage(color: CIColor(red: median, green: median, blue: median, alpha: 1, colorSpace: linearColorSpace) ?? .gray).cropped(to: halfExtent)
        let widestLight = normalizedBlur(sigma: Self.widestShadingBlurSigmaAtHalfSize, fallback: medianImage)
        let broadLight = normalizedBlur(sigma: Self.broadShadingBlurSigmaAtHalfSize, fallback: widestLight)
        let foldLight = normalizedBlur(sigma: Self.foldShadingBlurSigmaAtHalfSize, fallback: broadLight)
        let broadShading = broadLight
            .applyingFilter("CIColorMatrix", parameters: Self.grayGain(1 / median))
            .applyingFilter("CIColorClamp", parameters: Self.clampParameters(Self.broadShadingRange))
        let foldShading = broadLight
            .applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: foldLight])
            .applyingFilter("CIColorClamp", parameters: Self.clampParameters(Self.foldShadingRange))
        let shading = Self.multiplied(broadShading, foldShading).applyingFilter("CIGammaAdjust", parameters: ["inputPower": Self.shadingStrength])
        return Self.scaled(shading, toFill: frameExtent)
    }

    /// The room behind the person near their outline: the frame off the person, blurred with the person's pixels left out
    /// (a normalized blur, as the shading's), so the wall's color reaches a few pixels in under the person's edge, and a gray
    /// image that is 1 where enough of the room was near to know that color, and 0 deep in a crease between arm and body.
    private func roomBehindThePersonImage(frame: CIImage, scaledPersonMask: CIImage, frameExtent: CGRect) -> (room: CIImage, isKnown: CIImage) {
        let halfExtent = CGRect(x: 0, y: 0, width: (frameExtent.width / 2).rounded(), height: (frameExtent.height / 2).rounded())
        let roomWeight = Self.inverted(Self.ramp(Self.scaled(scaledPersonMask, toFill: halfExtent), from: 0.1, to: 0.3))
        let weightedRoom = Self.multiplied(Self.scaled(frame, toFill: halfExtent), roomWeight)
        let blurredWeight = Self.withBias(
            roomWeight.clampedToExtent().applyingGaussianBlur(sigma: Self.roomBehindBlurSigmaAtHalfSize).cropped(to: halfExtent),
            parameters: ["inputBiasVector": CIVector(x: 1e-4, y: 1e-4, z: 1e-4, w: 0)]
        )
        let blurredRoom = weightedRoom.clampedToExtent().applyingGaussianBlur(sigma: Self.roomBehindBlurSigmaAtHalfSize).cropped(to: halfExtent)
        // The divide blend divides its background by its input, per channel.
        let room = Self.scaled(blurredWeight.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: blurredRoom]), toFill: frameExtent)
        let isKnown = Self.scaled(Self.ramp(blurredWeight, from: 0.05, to: 0.25), toFill: frameExtent)
        return (room, isKnown)
    }

    /// A gray image that is 1 inside the cloth and darkens toward its edge: the cloth's alpha blurred, so it falls toward
    /// 0.5 at the outline and the neck, and further in the concave corner of an armpit.
    private func edgeDarkeningImage(clothAlpha: CIImage, frameExtent: CGRect, shoulderWidth: Double) -> CIImage {
        let halfExtent = CGRect(x: 0, y: 0, width: (frameExtent.width / 2).rounded(), height: (frameExtent.height / 2).rounded())
        let blurredAlpha = Self.scaled(clothAlpha, toFill: halfExtent)
            .clampedToExtent().applyingGaussianBlur(sigma: max(1, Self.edgeDarkeningReachInShoulderWidths * shoulderWidth / 2)).cropped(to: halfExtent)
        // 1 - strength * (1 - blurred alpha), clipped at 1.
        let strength = Self.edgeDarkeningStrength
        let darkening = Self.withBias(blurredAlpha, parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: strength, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1 - strength, y: 1 - strength, z: 1 - strength, w: 1),
        ]).applyingFilter("CIColorClamp")
        return Self.scaled(darkening, toFill: frameExtent)
    }

    /// The rolloff curve: values pass as they are up to the knee, then ease toward the ceiling, never reaching it, with no
    /// corner at the knee.
    static func highlightRolloff(_ value: Double) -> Double {
        guard value > highlightKnee else { return value }
        let headroom = highlightCeiling - highlightKnee
        return highlightKnee + headroom * (1 - exp(-(value - highlightKnee) / headroom))
    }

    /// The rolloff as `CIColorCurves` takes it: 1024 steps over the domain, each the same for the three channels.
    private static func highlightRolloffCurveData() -> Data {
        let stepCount = 1024
        var values: [Float] = []
        values.reserveCapacity(stepCount * 3)
        for step in 0..<stepCount {
            let rolledOff = Float(highlightRolloff(Double(step) / Double(stepCount - 1) * highlightRolloffDomainTop))
            values.append(contentsOf: [rolledOff, rolledOff, rolledOff])
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: The analysis

    /// The analysis this frame uses. Starts a new run when one is due. With nothing in yet, the background way returns nil and
    /// the first run's result reaches a later frame.
    private func analysisForThisFrame(frame: CIImage, personMask: CIImage, torso: BodyTorso, oldShirtZoneHalfWidth: Double) -> ShirtFrameAnalysisResult? {
        framesSinceAnAnalysisStarted += 1
        guard analysisRunsInTheBackground else {
            framesSinceAnAnalysisStarted = 0
            let generation = analysisState.withLock { $0.generation }
            runTheAnalysis(frame: frame, personMask: personMask, torso: torso, oldShirtZoneHalfWidth: oldShirtZoneHalfWidth, generation: generation)
            return analysisState.withLock { $0.latestResult }
        }
        let generationToRun: Int? = analysisState.withLock { state in
            guard !state.runIsInFlight, state.latestResult == nil || framesSinceAnAnalysisStarted >= Self.framesBetweenAnalyses else { return nil }
            state.runIsInFlight = true
            return state.generation
        }
        if let generationToRun {
            framesSinceAnAnalysisStarted = 0
            // The camera never writes a frame it has handed out, so the analysis queue may read it while this frame draws.
            nonisolated(unsafe) let frameToRead = frame
            nonisolated(unsafe) let personMaskToRead = personMask
            analysisQueue.async {
                self.runTheAnalysis(frame: frameToRead, personMask: personMaskToRead, torso: torso, oldShirtZoneHalfWidth: oldShirtZoneHalfWidth, generation: generationToRun)
            }
        }
        return analysisState.withLock { $0.latestResult }
    }

    /// Reads the small copy back, asks the per-frame questions, and keeps the answer, unless a reset came in between.
    private func runTheAnalysis(frame: CIImage, personMask: CIImage, torso: BodyTorso, oldShirtZoneHalfWidth: Double, generation: Int) {
        let previousColor = analysisState.withLock { $0.smoothedOldShirtColor }
        let outcome = analyze(frame: frame, personMask: personMask, torso: torso, oldShirtZoneHalfWidth: oldShirtZoneHalfWidth, previousOldShirtColor: previousColor)
        analysisState.withLock { state in
            state.runIsInFlight = false
            guard state.generation == generation, let outcome else { return }
            state.smoothedOldShirtColor = outcome.oldShirtColor
            state.latestResult = outcome.result.numbered(state.nextRunNumber)
            state.nextRunNumber += 1
        }
    }

    private func analyze(frame: CIImage, personMask: CIImage, torso: BodyTorso, oldShirtZoneHalfWidth: Double, previousOldShirtColor: SIMD3<Float>?) -> (result: ShirtFrameAnalysisResult, oldShirtColor: SIMD3<Float>)? {
        let frameExtent = frame.extent
        let analysisScale = min(1, Self.analysisFrameWidth / frameExtent.width)
        let smallWidth = max(3, Int((frameExtent.width * analysisScale).rounded())), smallHeight = max(3, Int((frameExtent.height * analysisScale).rounded()))
        let smallBytes = renderedSmallFrameAndPersonMask(frame: frame, personMask: personMask, width: smallWidth, height: smallHeight)
        let smallFrame = ShirtSmallFrame(width: smallWidth, height: smallHeight, rgba: smallBytes.frame, personMask: smallBytes.person, torso: torso.scaled(by: analysisScale))
        // The old shirt's color is smoothed over runs, so one run's hand or fold never moves it.
        guard let measuredColor = smallFrame.measureOldShirtColor() ?? previousOldShirtColor else { return nil }
        let oldShirtColor = previousOldShirtColor.map { $0 + (measuredColor - $0) * 0.5 } ?? measuredColor
        let frameAnalysis = ShirtFrameAnalysis(frame: smallFrame, oldShirtColor: oldShirtColor, oldShirtZoneHalfWidthInShoulderWidths: oldShirtZoneHalfWidth)
        let masks = CIImage(
            bitmapData: Data(frameAnalysis.maskPixels), bytesPerRow: smallWidth * 4, size: CGSize(width: smallWidth, height: smallHeight), format: .RGBA8, colorSpace: nil
        )
        let result = ShirtFrameAnalysisResult(
            runNumber: 0, torso: torso, masks: masks, oldShirtMedianLinearLuminance: frameAnalysis.oldShirtMedianLinearLuminance,
            neckRow: smallFrame.bodyNeckRow(oldShirtColor: oldShirtColor).map { $0 / analysisScale },
            oldShirtHemDistance: frameAnalysis.oldShirtHemDistance.map { $0 / analysisScale },
            roomLight: ShirtRoomLight.measure(in: smallFrame),
            oldShirtHalfWidths: frameAnalysis.oldShirtHalfWidths.map { side in side.map { $0.map { $0 / analysisScale } } },
            oldSleeves: frameAnalysis.oldSleeves.map { sleeve in
                sleeve.map { ShirtOldSleeveExtent(reachAlongTheArm: $0.reachAlongTheArm / analysisScale, outward: $0.outward / analysisScale, inward: $0.inward / analysisScale) }
            }
        )
        return (result, oldShirtColor)
    }

    /// Folds a new analysis's numbers into the smoothed ones, once per run.
    private func foldInTheNumbers(of analysis: ShirtFrameAnalysisResult) {
        guard analysis.runNumber != foldedRunNumber else { return }
        foldedRunNumber = analysis.runNumber
        let share = Self.roomLightSmoothingShare
        if let roomLight = analysis.roomLight {
            if let previousRoomWhite = smoothedRoomWhite {
                smoothedRoomWhite = previousRoomWhite + (roomLight.whiteLuminance - previousRoomWhite) * share
                smoothedIlluminant += (roomLight.illuminant - smoothedIlluminant) * share
            } else {
                smoothedRoomWhite = roomLight.whiteLuminance
                smoothedIlluminant = roomLight.illuminant
            }
        }
        let median = analysis.oldShirtMedianLinearLuminance
        smoothedOldShirtMedianLinearLuminance = smoothedOldShirtMedianLinearLuminance.map { $0 + (median - $0) * share } ?? median
        // Where the old shirt really ends, when the hips were only estimated. The garment's hem lands there, so it never
        // draws over trousers.
        if analysis.torso.hipsWereEstimated, let hemDistance = analysis.oldShirtHemDistance {
            let measuredLength = hemDistance / Self.garmentBottomInTorsoLengths / analysis.torso.shoulderWidth
            smoothedTorsoLengthInShoulderWidths = smoothedTorsoLengthInShoulderWidths.map { $0 + (measuredLength - $0) * 0.2 } ?? measuredLength
        }
        // The old shirt's width and its sleeves, in shoulder widths, so they apply to the torso of every later frame. The first
        // run's numbers are taken whole, and an old sleeve not found this run keeps its last extent, since a hand can hide it.
        let isTheFirstRun = analysis.runNumber == 1
        let measuredWidening = Self.hipWidening(of: analysis.torso, toCover: analysis.oldShirtHalfWidths)
        for side in 0..<2 {
            let previous = smoothedHipWideningInShoulderWidths[side]
            smoothedHipWideningInShoulderWidths[side] = isTheFirstRun ? measuredWidening[side] : previous + (measuredWidening[side] - previous) * Double(share)
            guard let measuredSleeve = analysis.oldSleeves[side] else { continue }
            let shoulderWidth = analysis.torso.shoulderWidth
            let measured = ShirtOldSleeveExtent(
                reachAlongTheArm: measuredSleeve.reachAlongTheArm / shoulderWidth, outward: measuredSleeve.outward / shoulderWidth, inward: measuredSleeve.inward / shoulderWidth
            )
            if let previousSleeve = smoothedOldSleevesInShoulderWidths[side], !isTheFirstRun {
                func eased(_ from: Double, _ to: Double) -> Double { from + (to - from) * Double(share) }
                smoothedOldSleevesInShoulderWidths[side] = ShirtOldSleeveExtent(
                    reachAlongTheArm: eased(previousSleeve.reachAlongTheArm, measured.reachAlongTheArm),
                    outward: eased(previousSleeve.outward, measured.outward), inward: eased(previousSleeve.inward, measured.inward)
                )
            } else {
                smoothedOldSleevesInShoulderWidths[side] = measured
            }
        }
    }

    // MARK: Geometry

    /// The body's torso as the garment's torso lands on it: a shirt's shoulder seam sits a little outside the shoulder joints
    /// (12 percent of the shoulder width) and a little above them, and its hem a little below the hips. Top left, top right,
    /// bottom right, bottom left.
    static func bodyTorsoCorners(of torso: BodyTorso) -> [CGPoint] {
        bodyTorsoCorners(of: torso, widenedHipsBy: [0, 0])
    }

    /// The body's torso corners with each lower corner, image left first, moved out along the shoulder line by its share of
    /// the shoulder width, so the garment's sides cover a looser old shirt at the waist.
    static func bodyTorsoCorners(of torso: BodyTorso, widenedHipsBy hipWideningInShoulderWidths: [Double]) -> [CGPoint] {
        let shoulderSpan = CGPoint(x: torso.imageRightShoulder.x - torso.imageLeftShoulder.x, y: torso.imageRightShoulder.y - torso.imageLeftShoulder.y)
        let outward = CGPoint(x: shoulderSpan.x * 0.12, y: shoulderSpan.y * 0.12)
        let hemDrop = CGPoint(x: torso.hipMidpoint.x - torso.shoulderMidpoint.x, y: torso.hipMidpoint.y - torso.shoulderMidpoint.y)
        return [
            CGPoint(x: torso.imageLeftShoulder.x - outward.x - hemDrop.x * 0.04, y: torso.imageLeftShoulder.y - outward.y - hemDrop.y * 0.04),
            CGPoint(x: torso.imageRightShoulder.x + outward.x - hemDrop.x * 0.04, y: torso.imageRightShoulder.y + outward.y - hemDrop.y * 0.04),
            CGPoint(
                x: torso.imageRightHip.x + outward.x * 0.6 + hemDrop.x * 0.08 + shoulderSpan.x * hipWideningInShoulderWidths[1],
                y: torso.imageRightHip.y + outward.y * 0.6 + hemDrop.y * 0.08 + shoulderSpan.y * hipWideningInShoulderWidths[1]
            ),
            CGPoint(
                x: torso.imageLeftHip.x - outward.x * 0.6 + hemDrop.x * 0.08 - shoulderSpan.x * hipWideningInShoulderWidths[0],
                y: torso.imageLeftHip.y - outward.y * 0.6 + hemDrop.y * 0.08 - shoulderSpan.y * hipWideningInShoulderWidths[0]
            ),
        ]
    }

    /// How far each lower torso corner, image left first, must move out, in shoulder widths, for the garment's side to reach
    /// `oldShirtCoverMarginInShoulderWidths` past the old shirt at each fraction of `ShirtFrameAnalysis.torsoWidthFractions`
    /// where `halfWidths` (camera pixels from the torso's center line) found it. A side runs straight from its shoulder corner
    /// to its hip corner, so the hip corner moves out by however much the widest shortfall needs along that line, at most
    /// `mostHipWideningInShoulderWidths`.
    static func hipWidening(of torso: BodyTorso, toCover halfWidths: [[Double?]]) -> [Double] {
        let corners = bodyTorsoCorners(of: torso)
        let shoulderMidpoint = SIMD2(Double(torso.shoulderMidpoint.x), Double(torso.shoulderMidpoint.y))
        let hipMidpoint = SIMD2(Double(torso.hipMidpoint.x), Double(torso.hipMidpoint.y))
        let torsoLength = simd_length(hipMidpoint - shoulderMidpoint), shoulderWidth = torso.shoulderWidth
        guard torsoLength > 1, shoulderWidth > 1, halfWidths.count == 2 else { return [0, 0] }
        let torsoAxis = (hipMidpoint - shoulderMidpoint) / torsoLength
        let alongTheShoulders = SIMD2(Double(torso.imageRightShoulder.x - torso.imageLeftShoulder.x), Double(torso.imageRightShoulder.y - torso.imageLeftShoulder.y)) / shoulderWidth
        return (0..<2).map { side in
            let outwardSign = side == 0 ? -1.0 : 1.0
            let top = SIMD2(Double(corners[side == 0 ? 0 : 1].x), Double(corners[side == 0 ? 0 : 1].y))
            let bottom = SIMD2(Double(corners[side == 0 ? 3 : 2].x), Double(corners[side == 0 ? 3 : 2].y))
            func fraction(_ point: SIMD2<Double>) -> Double { simd_dot(point - shoulderMidpoint, torsoAxis) / torsoLength }
            func outward(_ point: SIMD2<Double>) -> Double { outwardSign * simd_dot(point - shoulderMidpoint, alongTheShoulders) }
            var widening = 0.0
            for (index, torsoFraction) in ShirtFrameAnalysis.torsoWidthFractions.enumerated() {
                guard index < halfWidths[side].count, let halfWidth = halfWidths[side][index] else { continue }
                let shareDownTheSide = (torsoFraction - fraction(top)) / (fraction(bottom) - fraction(top))
                guard shareDownTheSide > 0.05, shareDownTheSide <= 1.05 else { continue }
                let wanted = halfWidth + oldShirtCoverMarginInShoulderWidths * shoulderWidth
                let wantedAtTheBottom = outward(top) + (wanted - outward(top)) / shareDownTheSide
                widening = max(widening, (wantedAtTheBottom - outward(bottom)) / shoulderWidth)
            }
            return min(widening, mostHipWideningInShoulderWidths)
        }
    }

    /// Where a sleeve's quadrilateral (`ShirtSleeveGeometry.quadrilateral`) lands on the body, or nil when either of its two
    /// triangles (see `ShirtGarmentSleeve`) would land mirrored. The seam lands where the torso's map puts it, so the sleeve
    /// meets the torso. The sleeve runs down the shoulder-to-elbow line as far as it is long past its seam's middle, with its
    /// opening across the arm, as wide as it lies on the arm, and its outer end on the side away from the body. A sleeve wraps
    /// the arm but is wider than it, so its opening hangs between the line through the seam's middle and the arm's own line
    /// (`sleeveOpeningShareTowardTheArmLine`). `garmentToBodyScale` is camera pixels per photo pixel at the torso.
    ///
    /// With `oldSleeve` (camera pixels, already grown by its margin), the opening moves down the arm and widens until it covers
    /// the old sleeve's reach and width, so the learner's own sleeve never shows under the new one. The drawn sleeve may then
    /// be longer than the product's.
    static func sleeveLanding(
        of sleeve: ShirtSleeveGeometry, torsoHomography: simd_double3x3, shoulder: CGPoint, elbow: CGPoint, bodyCenter: CGPoint, garmentToBodyScale: Double,
        oldSleeve: ShirtOldSleeveExtent? = nil
    ) -> [CGPoint]? {
        let seamTop = applyingPerspective(torsoHomography, to: sleeve.seamTop), seamBottom = applyingPerspective(torsoHomography, to: sleeve.seamBottom)
        let seamCenter = SIMD2((seamTop.x + seamBottom.x) / 2, (seamTop.y + seamBottom.y) / 2)
        let armVector = SIMD2(elbow.x - shoulder.x, elbow.y - shoulder.y)
        guard simd_length(armVector) > 1 else { return nil }
        let armDirection = simd_normalize(armVector)
        var awayFromTheBody = SIMD2(-armDirection.y, armDirection.x)
        if simd_dot(awayFromTheBody, seamCenter - SIMD2(bodyCenter.x, bodyCenter.y)) < 0 { awayFromTheBody = -awayFromTheBody }
        let shoulderPoint = SIMD2(Double(shoulder.x), Double(shoulder.y))
        let seamCenterOffTheArmLine = simd_dot(seamCenter - shoulderPoint, awayFromTheBody)
        var openingCenter = seamCenter + armDirection * sleeve.length * garmentToBodyScale
            - awayFromTheBody * seamCenterOffTheArmLine * sleeveOpeningShareTowardTheArmLine
        var halfOpening = sleeve.openingWidth * garmentToBodyScale * sleeveOpeningShareOnTheArm / 2
        if let oldSleeve {
            let downTheArm = simd_dot(openingCenter - shoulderPoint, armDirection)
            let wantedDownTheArm = min(max(downTheArm, oldSleeve.reachAlongTheArm), mostSleeveReachShareOfTheArm * simd_length(armVector))
            openingCenter += armDirection * (wantedDownTheArm - downTheArm)
            let centerOut = simd_dot(openingCenter - shoulderPoint, awayFromTheBody)
            let innerEnd = min(centerOut - halfOpening, -oldSleeve.inward), outerEnd = max(centerOut + halfOpening, oldSleeve.outward)
            openingCenter += awayFromTheBody * ((innerEnd + outerEnd) / 2 - centerOut)
            halfOpening = (outerEnd - innerEnd) / 2
        }
        let openingOuter = openingCenter + awayFromTheBody * halfOpening, openingInner = openingCenter - awayFromTheBody * halfOpening
        let landing = [seamTop, CGPoint(x: openingOuter.x, y: openingOuter.y), CGPoint(x: openingInner.x, y: openingInner.y), seamBottom]
        let source = sleeve.quadrilateral
        // Each triangle must turn the same way on the body as in the photo, or its map would mirror the cloth.
        func turn(_ first: CGPoint, _ second: CGPoint, _ third: CGPoint) -> Double {
            (second.x - first.x) * (third.y - first.y) - (second.y - first.y) * (third.x - first.x)
        }
        for (first, second, third) in [(0, 1, 2), (0, 2, 3)] {
            let sourceTurn = turn(source[first], source[second], source[third]), landingTurn = turn(landing[first], landing[second], landing[third])
            guard abs(landingTurn) > 1e-6, (sourceTurn > 0) == (landingTurn > 0) else { return nil }
        }
        return landing
    }

    /// Each sleeve drawn on its own, image left first: laid along its arm (`alongTheArms`), or at the whole garment's angle
    /// and lengthened to cover the old sleeve, or for a photo on a model carried from the model's arm to the learner's. Nil
    /// when the garment has no sleeves apart, an elbow is not seen, or a sleeve cannot be mapped, when the garment is drawn
    /// in one piece. Each half of a sleeve takes the affine map of its own
    /// triangle (see `ShirtGarmentSleeve`), and the inner half is drawn over the outer half's strip past the diagonal.
    private func warpedSleeves(
        of garment: ShirtGarment, torso: BodyTorso, torsoHomography: simd_double3x3, shoulderHomography: simd_double3x3,
        landedTorsoWidth: Double, frameExtent: CGRect, alongTheArms: Bool
    ) -> [(side: ShirtSleeveSide, landing: [CGPoint], image: CIImage)]? {
        guard garment.sleeves.count == 2, let imageLeftElbow = torso.imageLeftElbow, let imageRightElbow = torso.imageRightElbow else { return nil }
        let garmentToBodyScale = landedTorsoWidth / max(garment.torsoCorners.topRight.x - garment.torsoCorners.topLeft.x, 1)
        let bodyCenter = CGPoint(x: (torso.shoulderMidpoint.x + torso.hipMidpoint.x) / 2, y: (torso.shoulderMidpoint.y + torso.hipMidpoint.y) / 2)
        var layers: [(side: ShirtSleeveSide, landing: [CGPoint], image: CIImage)] = []
        for sleeve in garment.sleeves {
            let isImageLeft = sleeve.geometry.side == .imageLeft
            let shoulderWidth = torso.shoulderWidth, margin = Self.oldShirtCoverMarginInShoulderWidths
            let oldSleeve = smoothedOldSleevesInShoulderWidths[isImageLeft ? 0 : 1].map {
                ShirtOldSleeveExtent(
                    reachAlongTheArm: ($0.reachAlongTheArm + margin) * shoulderWidth, outward: ($0.outward + margin) * shoulderWidth, inward: ($0.inward + margin) * shoulderWidth
                )
            }
            let shoulder = isImageLeft ? torso.imageLeftShoulder : torso.imageRightShoulder, elbow = isImageLeft ? imageLeftElbow : imageRightElbow
            let landingResult: [CGPoint]?
            if let modelPose = garment.modelPose {
                // A photo on a model: the sleeve is carried from the model's arm to the learner's (ShirtOnModel.swift).
                landingResult = ShirtOnModelSleeveLanding.landing(of: sleeve.geometry, modelPose: modelPose, torso: torso, torsoHomography: torsoHomography, oldSleeve: oldSleeve)
            } else if alongTheArms {
                // Covering the old sleeve's inner side can push the opening's inner end under the torso, which would turn the
                // sleeve's inner triangle over, so the landing tries the whole cover, then the cover without its inner side,
                // then the sleeve as the product shows it.
                let oldSleeveWithoutItsInnerSide = oldSleeve.map { ShirtOldSleeveExtent(reachAlongTheArm: $0.reachAlongTheArm, outward: $0.outward, inward: -Double.infinity) }
                landingResult = [oldSleeve, oldSleeveWithoutItsInnerSide, nil].lazy.compactMap { cover in
                    Self.sleeveLanding(
                        of: sleeve.geometry, torsoHomography: torsoHomography, shoulder: shoulder, elbow: elbow,
                        bodyCenter: bodyCenter, garmentToBodyScale: garmentToBodyScale, oldSleeve: cover
                    )
                }.first
            } else {
                let wholeGarmentLanding = sleeve.geometry.quadrilateral.map { applyingPerspective(torsoHomography, to: $0) }
                landingResult = Self.wholeGarmentSleeveLanding(wholeGarmentLanding, lengthenedToCover: oldSleeve, shoulder: shoulder, elbow: elbow, bodyCenter: bodyCenter)
            }
            guard var landing = landingResult else { return nil }
            // The seam's top lands where the torso's shoulder does (`shoulderHomography`), so the two meet at the shoulder.
            landing[0] = applyingPerspective(shoulderHomography, to: sleeve.geometry.seamTop)
            let source = sleeve.geometry.quadrilateral, triangles = sleeve.geometry.triangleIndices
            guard let firstMap = Self.affineTransform(from: triangles.first.map { source[$0] }, to: triangles.first.map { landing[$0] }),
                  let secondMap = Self.affineTransform(from: triangles.second.map { source[$0] }, to: triangles.second.map { landing[$0] }) else { return nil }
            let firstHalf = sleeve.firstHalf.transformed(by: Self.coreImageTransform(ofPhotoBox: sleeve.boundingBox, mappedBy: firstMap, frameExtent: frameExtent))
            let secondHalf = sleeve.secondHalf.transformed(by: Self.coreImageTransform(ofPhotoBox: sleeve.boundingBox, mappedBy: secondMap, frameExtent: frameExtent))
            layers.append((sleeve.geometry.side, landing, secondHalf.composited(over: firstHalf)))
        }
        return layers
    }

    /// A sleeve at the whole garment's angle (`landing`: seam top, opening outer, opening inner, seam bottom, in camera
    /// pixels) with its opening moved further along the sleeve's own axis, until the old sleeve's hem, its reach down the arm
    /// from its inner side to its outer side, lies on the seam's side of the opening. A product's short sleeve is often
    /// shorter than the shirt the person wears, whose sleeve would hang out under it. The sleeve grows to at most twice its
    /// own length, so a misread old sleeve never makes a long one.
    static func wholeGarmentSleeveLanding(
        _ landing: [CGPoint], lengthenedToCover oldSleeve: ShirtOldSleeveExtent?, shoulder: CGPoint, elbow: CGPoint, bodyCenter: CGPoint
    ) -> [CGPoint] {
        func vector(_ point: CGPoint) -> SIMD2<Double> { SIMD2(Double(point.x), Double(point.y)) }
        guard let oldSleeve, landing.count == 4 else { return landing }
        let armVector = vector(elbow) - vector(shoulder)
        guard simd_length(armVector) > 1 else { return landing }
        let armDirection = simd_normalize(armVector)
        let seamCenter = (vector(landing[0]) + vector(landing[3])) / 2, openingCenter = (vector(landing[1]) + vector(landing[2])) / 2
        var awayFromTheBody = SIMD2(-armDirection.y, armDirection.x)
        if simd_dot(awayFromTheBody, seamCenter - vector(bodyCenter)) < 0 { awayFromTheBody = -awayFromTheBody }
        let sleeveLength = simd_length(openingCenter - seamCenter)
        guard sleeveLength > 1 else { return landing }
        let sleeveAxis = (openingCenter - seamCenter) / sleeveLength
        let opening = vector(landing[1]) - vector(landing[2])
        var openingNormal = simd_normalize(SIMD2(-opening.y, opening.x))
        if simd_dot(openingNormal, sleeveAxis) < 0 { openingNormal = -openingNormal }
        let axisAcrossTheOpening = simd_dot(sleeveAxis, openingNormal)
        guard axisAcrossTheOpening > 0.2 else { return landing }
        let hemReach = vector(shoulder) + armDirection * oldSleeve.reachAlongTheArm
        let hemEnds = [hemReach + awayFromTheBody * oldSleeve.outward, hemReach - awayFromTheBody * oldSleeve.inward]
        let wanted = hemEnds.map { simd_dot($0 - openingCenter, openingNormal) / axisAcrossTheOpening }.max() ?? 0
        let lengthening = min(max(wanted, 0), sleeveLength)
        let shift = sleeveAxis * lengthening
        return [landing[0], CGPoint(x: landing[1].x + shift.x, y: landing[1].y + shift.y), CGPoint(x: landing[2].x + shift.x, y: landing[2].y + shift.y), landing[3]]
    }

    /// Where each sleeve of the whole garment lands, image left first, through the torso's homography, or empty when the
    /// garment has no sleeves apart or an elbow is not seen.
    static func wholeGarmentSleeveLandings(of garment: ShirtGarment, torso: BodyTorso, torsoHomography: simd_double3x3) -> [(side: ShirtSleeveSide, landing: [CGPoint])] {
        guard garment.sleeves.count == 2, torso.imageLeftElbow != nil, torso.imageRightElbow != nil else { return [] }
        return garment.sleeves.map { sleeve in
            (sleeve.geometry.side, sleeve.geometry.quadrilateral.map { applyingPerspective(torsoHomography, to: $0) })
        }
    }

    /// How far `direction` turns out from the body's down direction, from the shoulders' middle to the hips' middle, toward
    /// its own side, in degrees: 0 straight down, 90 straight out, past 90 raised, below 0 across the body.
    static func outwardAngleFromTheBodysDown(of direction: CGVector, side: ShirtSleeveSide, torso: BodyTorso) -> Double {
        let down = SIMD2(torso.hipMidpoint.x - torso.shoulderMidpoint.x, torso.hipMidpoint.y - torso.shoulderMidpoint.y)
        let towardTheSide = side == .imageLeft
            ? SIMD2(torso.imageLeftShoulder.x - torso.imageRightShoulder.x, torso.imageLeftShoulder.y - torso.imageRightShoulder.y)
            : SIMD2(torso.imageRightShoulder.x - torso.imageLeftShoulder.x, torso.imageRightShoulder.y - torso.imageLeftShoulder.y)
        let vector = SIMD2(Double(direction.dx), Double(direction.dy))
        return atan2(simd_dot(vector, simd_normalize(towardTheSide)), simd_dot(vector, simd_normalize(down))) * 180 / .pi
    }

    /// Whether every sleeve of the whole garment holds its arm: the arm turns out from the body no more than
    /// `pastTheSleeveDegrees` past the sleeve. A short sleeve stands off a hanging arm, so the product's flat sleeves look
    /// right on any arm below them; an arm raised past its sleeve would come out of the cloth, and then the sleeves are
    /// drawn apart along the arms. Callers pass a smaller angle while the sleeves are drawn apart, so an arm near the limit
    /// does not switch the drawing back and forth from frame to frame.
    static func wholeGarmentSleevesHoldTheArms(_ sleeves: [(side: ShirtSleeveSide, landing: [CGPoint])], torso: BodyTorso, pastTheSleeveDegrees: Double) -> Bool {
        sleeves.allSatisfy { sleeve in
            let isImageLeft = sleeve.side == .imageLeft
            guard let elbow = isImageLeft ? torso.imageLeftElbow : torso.imageRightElbow else { return true }
            let shoulder = isImageLeft ? torso.imageLeftShoulder : torso.imageRightShoulder
            let sleeveAxis = ShirtDrawnSleeve(side: sleeve.side, landing: sleeve.landing, liesAlongTheArm: false).axis
            let armAxis = CGVector(dx: elbow.x - shoulder.x, dy: elbow.y - shoulder.y)
            let armPastTheSleeve = outwardAngleFromTheBodysDown(of: armAxis, side: sleeve.side, torso: torso)
                - outwardAngleFromTheBodysDown(of: sleeveAxis, side: sleeve.side, torso: torso)
            return armPastTheSleeve <= pastTheSleeveDegrees
        }
    }

    /// The affine transform that carries three points onto three others, or nil when the first three are on one line.
    static func affineTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == 3, destination.count == 3 else { return nil }
        let sourceMatrix = simd_double3x3(rows: source.map { SIMD3($0.x, $0.y, 1) })
        guard abs(sourceMatrix.determinant) > 1e-9 else { return nil }
        let inverse = sourceMatrix.inverse
        // Each destination coordinate is a linear function of (x, y, 1), whose three numbers solve the three equations.
        let xCoefficients = inverse * SIMD3(destination[0].x, destination[1].x, destination[2].x)
        let yCoefficients = inverse * SIMD3(destination[0].y, destination[1].y, destination[2].y)
        return CGAffineTransform(a: xCoefficients.x, b: yCoefficients.x, c: xCoefficients.y, d: yCoefficients.y, tx: xCoefficients.z, ty: yCoefficients.z)
    }

    /// The transform for an image whose extent starts at the origin and holds the photo's `box` (top left origin, y down):
    /// into photo pixels, through `map` (photo pixels to camera pixels, both y down), and into Core Image's frame coordinates.
    private static func coreImageTransform(ofPhotoBox box: CGRect, mappedBy map: CGAffineTransform, frameExtent: CGRect) -> CGAffineTransform {
        let imageToPhoto = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: box.minX, ty: box.maxY)
        let cameraToCoreImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: frameExtent.minX, ty: frameExtent.minY + frameExtent.height)
        return imageToPhoto.concatenating(map).concatenating(cameraToCoreImage)
    }

    /// `image`, whose extent starts at the origin and holds the photo's `box` (top left origin, y down), warped by
    /// `homography` from photo pixels to camera pixels, or nil when a corner would land behind the camera's horizon.
    private static func warped(_ image: CIImage, lyingIn box: CGRect, by homography: simd_double3x3, frameExtent: CGRect) -> CIImage? {
        let boxCorners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        var landed: [CGPoint] = []
        for corner in boxCorners {
            let mapped = homography * SIMD3(corner.x, corner.y, 1)
            guard mapped.z > 1e-9, mapped.x.isFinite, mapped.y.isFinite else { return nil }
            landed.append(flipped(CGPoint(x: mapped.x / mapped.z, y: mapped.y / mapped.z), frameExtent: frameExtent))
        }
        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: landed[0]), "inputTopRight": CIVector(cgPoint: landed[1]),
            "inputBottomRight": CIVector(cgPoint: landed[2]), "inputBottomLeft": CIVector(cgPoint: landed[3]),
        ])
    }

    /// The motion of the body from `earlier` to `later`, in camera pixels with y down: the turn, scale, and shift that carry
    /// the earlier shoulders onto the later ones.
    static func motion(from earlier: BodyTorso, to later: BodyTorso) -> CGAffineTransform {
        let earlierSpan = SIMD2(earlier.imageRightShoulder.x - earlier.imageLeftShoulder.x, earlier.imageRightShoulder.y - earlier.imageLeftShoulder.y)
        let laterSpan = SIMD2(later.imageRightShoulder.x - later.imageLeftShoulder.x, later.imageRightShoulder.y - later.imageLeftShoulder.y)
        let earlierLengthSquared = simd_length_squared(earlierSpan)
        guard earlierLengthSquared > 1 else { return .identity }
        // The later span as the earlier span turned and scaled, as a ratio of complex numbers.
        let cosineTimesScale = simd_dot(laterSpan, earlierSpan) / earlierLengthSquared
        let sineTimesScale = (earlierSpan.x * laterSpan.y - earlierSpan.y * laterSpan.x) / earlierLengthSquared
        let earlierMidpoint = earlier.shoulderMidpoint, laterMidpoint = later.shoulderMidpoint
        return CGAffineTransform(translationX: -earlierMidpoint.x, y: -earlierMidpoint.y)
            .concatenating(CGAffineTransform(a: cosineTimesScale, b: sineTimesScale, c: -sineTimesScale, d: cosineTimesScale, tx: 0, ty: 0))
            .concatenating(CGAffineTransform(translationX: laterMidpoint.x, y: laterMidpoint.y))
    }

    /// `motion` (y down) for an image in Core Image's coordinates (y up) with `frameExtent`.
    private static func coreImageTransform(of motion: CGAffineTransform, frameExtent: CGRect) -> CGAffineTransform {
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: frameExtent.minY * 2 + frameExtent.height)
        return flip.concatenating(motion).concatenating(flip)
    }

    private static func flipped(_ point: CGPoint, frameExtent: CGRect) -> CGPoint {
        CGPoint(x: frameExtent.minX + point.x, y: frameExtent.minY + frameExtent.height - point.y)
    }

    // MARK: Core Image helpers

    /// `image` scaled and moved to cover `extent` exactly.
    private static func scaled(_ image: CIImage, toFill extent: CGRect) -> CIImage {
        let imageExtent = image.extent
        return image
            .transformed(by: CGAffineTransform(translationX: -imageExtent.minX, y: -imageExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / imageExtent.width, y: extent.height / imageExtent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// One channel of `image` as an opaque gray image.
    private static func channel(_ image: CIImage, _ index: Int) -> CIImage {
        let unit = CIVector(x: index == 0 ? 1 : 0, y: index == 1 ? 1 : 0, z: index == 2 ? 1 : 0, w: index == 3 ? 1 : 0)
        return withBias(image, parameters: [
            "inputRVector": unit, "inputGVector": unit, "inputBVector": unit,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// A gray image's values from `low` to `high` stretched to 0 to 1 and clipped.
    private static func ramp(_ gray: CIImage, from low: Double, to high: Double) -> CIImage {
        let gain = 1 / (high - low), bias = -low / (high - low)
        return withBias(gray, parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// `image` through a color matrix with a bias, cropped back to its own extent. A bias lights the clear pixels outside an
    /// image too, so the matrix's output reaches to infinity, and scaling an infinite image to fit a rectangle gives nothing.
    private static func withBias(_ image: CIImage, parameters: [String: Any]) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: parameters).cropped(to: image.extent)
    }

    private static func grayGain(_ gain: Double) -> [String: Any] {
        [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]
    }

    private static func clampParameters(_ range: (lowest: Double, highest: Double)) -> [String: Any] {
        [
            "inputMinComponents": CIVector(x: range.lowest, y: range.lowest, z: range.lowest, w: 0),
            "inputMaxComponents": CIVector(x: range.highest, y: range.highest, z: range.highest, w: 1),
        ]
    }

    private static func multiplied(_ first: CIImage, _ second: CIImage) -> CIImage {
        first.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: second])
    }

    private static func inverted(_ gray: CIImage) -> CIImage {
        gray.applyingFilter("CIColorInvert")
    }

    /// The frame (sRGB encoded RGBA) and the person mask (one byte per pixel, the values Core Image sees, 255 where the
    /// person is), each `width` by `height`, read back with two renders so no loop has to pull them apart.
    private func renderedSmallFrameAndPersonMask(frame: CIImage, personMask: CIImage, width: Int, height: Int) -> (frame: [UInt8], person: [UInt8]) {
        let smallExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let frameExtent = frame.extent
        // Lanczos averages the pixels the small copy stands for, so thin lines do not alias away.
        let smallFrame = frame
            .transformed(by: CGAffineTransform(translationX: -frameExtent.minX, y: -frameExtent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(width) / frameExtent.width, kCIInputAspectRatioKey: (Double(height) / frameExtent.height) / (Double(width) / frameExtent.width)])
            .clampedToExtent().cropped(to: smallExtent)
        var frameBytes = [UInt8](repeating: 0, count: width * height * 4)
        var personBytes = [UInt8](repeating: 0, count: width * height)
        frameBytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ciContext.render(smallFrame, toBitmap: baseAddress, rowBytes: width * 4, bounds: smallExtent, format: .RGBA8, colorSpace: sRGBColorSpace)
        }
        personBytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            // No color space: the mask is read as it is.
            ciContext.render(Self.scaled(personMask, toFill: smallExtent), toBitmap: baseAddress, rowBytes: width, bounds: smallExtent, format: .R8, colorSpace: nil)
        }
        return (frameBytes, personBytes)
    }
}
