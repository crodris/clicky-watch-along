//
//  ShirtTryOnRenderer.swift
//  leanring-buddy
//
//  Draws the garment over the shirt the learner wears. The method is the spike's: the garment's torso is mapped onto the
//  body's torso, the person mask keeps the shirt on the body, the neck and face stay, the old shirt's shading is carried onto
//  the new print, and the camera's exposure is matched. Core Image draws it with built-in filters. The per-frame questions
//  they cannot ask (which pixels are the old shirt) are answered on a small copy in ShirtFrameAnalysis.swift.
//
//  Points are in camera pixels with y down. Core Image's y grows up, so every point crosses `flipped` on the way in.
//

import CoreImage
import Foundation
import simd

extension BodyTorso {
    /// The torso in a frame `scale` times as large.
    nonisolated func scaled(by scale: Double) -> BodyTorso {
        func scaledPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
        return BodyTorso(
            imageLeftShoulder: scaledPoint(imageLeftShoulder), imageRightShoulder: scaledPoint(imageRightShoulder),
            imageLeftHip: scaledPoint(imageLeftHip), imageRightHip: scaledPoint(imageRightHip),
            hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: shouldersAreSeen
        )
    }
}

/// Draws a garment over the learner. One renderer serves one try-on session on one queue: it keeps a few smoothed numbers
/// between frames (the old shirt's color, how far the necklines are apart, where the old shirt ends), so use `reset()` for a
/// new session or a new garment, and call `composite` from one queue only.
nonisolated final class ShirtTryOnRenderer: @unchecked Sendable {
    /// The per-frame questions run on a copy of the frame this wide.
    static let analysisFrameWidth = 320.0
    /// The old shirt's color is measured again every this many frames. It changes only with the light, and each frame's
    /// median would only add flicker.
    static let framesBetweenOldShirtColorMeasurements = 4
    /// Where the garment's bottom edge sits along the body, in torso lengths from the shoulder midpoint: the spike puts the
    /// shirt's hem 8 percent of a torso below the hips.
    static let garmentBottomInTorsoLengths = 1.08
    /// The shading comes from the camera's luminance, blurred this much (in half size pixels) so a noisy dark webcam shirt
    /// does not put its grain into the print. The spike used 2 full size pixels, which showed the grain.
    static let shadingBlurSigmaAtHalfSize = 3.0
    /// The analysis masks are blurred by this many of their own pixels once scaled up, which turns their steps into curves.
    static let analysisMaskSmoothingInSmallPixels = 0.8
    /// The base color fill is closed (grown by twice this, then shrunk by this many analysis pixels), which fills holes a
    /// few pixels wide where a fold read as not the old shirt, and leaves it grown by this much under the garment's edge,
    /// so the two meet with no gap.
    static let baseColorGrowthUnderTheGarmentInSmallPixels = 1.0
    /// The base color fill stays this share of the frame's width inside the person mask's edge: about 4 camera pixels at
    /// 1280, which keeps it off the room where the mask reaches past the arm.
    static let baseColorFillPullInShareOfTheFrameWidth = 0.0025

    private let ciContext: CIContext
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Written and read on the one queue that calls `composite`.
    private var smoothedOldShirtColor: SIMD3<Float>?
    private var framesSinceTheOldShirtColorWasMeasured = 0
    private var smoothedNeckShift = 0.0
    private var hasNeckShift = false
    private var smoothedTorsoLengthInShoulderWidths: Double?

    /// `ciContext` reads the small frame back for the analysis. Pass the one that draws the frames.
    init(ciContext: CIContext = CIContext()) {
        self.ciContext = ciContext
    }

    func reset() {
        smoothedOldShirtColor = nil
        framesSinceTheOldShirtColorWasMeasured = 0
        smoothedNeckShift = 0
        hasNeckShift = false
        smoothedTorsoLengthInShoulderWidths = nil
    }

    /// `frame` with `garment` drawn over the person's shirt. `personMask` is white where the person is (any size, it is scaled
    /// to the frame), and should be made with `CIImage(cvPixelBuffer:, options: [.colorSpace: NSNull()])` so Core Image
    /// reads its values as they are. `torso` comes from `ShirtFraming.ready`. The result is lazy, with the frame's extent.
    func composite(frame: CIImage, personMask: CIImage, torso suppliedTorso: BodyTorso, garment: ShirtGarment) -> CIImage {
        let frameExtent = frame.extent
        guard frameExtent.width >= 64, frameExtent.height >= 64, !personMask.extent.isEmpty else { return frame }
        let frameWidth = frameExtent.width, frameHeight = frameExtent.height
        let analysisScale = min(1, Self.analysisFrameWidth / frameWidth)
        let smallWidth = max(3, Int((frameWidth * analysisScale).rounded())), smallHeight = max(3, Int((frameHeight * analysisScale).rounded()))

        // What the previous frames learned about the body: where the old shirt ends, as a share of the shoulder width.
        func torsoWithTheLearnedLength() -> BodyTorso {
            smoothedTorsoLengthInShoulderWidths.map { suppliedTorso.withTorsoLength($0 * suppliedTorso.shoulderWidth) } ?? suppliedTorso
        }
        let torsoForTheAnalysis = torsoWithTheLearnedLength()

        // 1. The small copy and the analysis. One render reads the small frame and the small person mask back together.
        guard let smallBytes = renderedSmallFrameAndPersonMask(frame: frame, personMask: personMask, width: smallWidth, height: smallHeight) else { return frame }
        let smallFrame = ShirtSmallFrame(width: smallWidth, height: smallHeight, rgba: smallBytes.frame, personMask: smallBytes.person, torso: torsoForTheAnalysis.scaled(by: analysisScale))
        guard let oldShirtColor = oldShirtColor(of: smallFrame) else { return frame }
        let analysis = ShirtFrameAnalysis(frame: smallFrame, oldShirtColor: oldShirtColor)
        let shoulderWidth = suppliedTorso.shoulderWidth

        // Where the old shirt really ends, when the hips were only estimated. The garment's hem lands there, so it never
        // draws over trousers, and this frame's garment already uses it.
        if suppliedTorso.hipsWereEstimated, let hemDistance = analysis.oldShirtHemDistance.map({ $0 / analysisScale }) {
            let measuredLength = hemDistance / Self.garmentBottomInTorsoLengths / shoulderWidth
            smoothedTorsoLengthInShoulderWidths = smoothedTorsoLengthInShoulderWidths.map { $0 + (measuredLength - $0) * 0.2 } ?? measuredLength
        }

        let torso = torsoWithTheLearnedLength()

        // 2. Where the garment lands, with the necklines met.
        let sourceCorners = garment.torsoCorners.clockwiseFromTopLeft
        var bodyCorners = Self.bodyTorsoCorners(of: torso)
        guard let unshiftedHomography = perspectiveTransform(from: sourceCorners, to: bodyCorners) else { return frame }
        var rawNeckShift = 0.0
        if garment.frontNeckWasFound, let neckRowInSmallFrame = smallFrame.bodyNeckRow(oldShirtColor: oldShirtColor) {
            let garmentNeckInFrame = applyingPerspective(unshiftedHomography, to: garment.frontNeckPoint)
            let difference = neckRowInSmallFrame / analysisScale - garmentNeckInFrame.y
            // Further apart than a quarter of the shoulders, the scan found something other than the old collar.
            if abs(difference) < 0.25 * shoulderWidth { rawNeckShift = difference }
        }
        smoothedNeckShift = hasNeckShift ? smoothedNeckShift + (rawNeckShift - smoothedNeckShift) * 0.35 : rawNeckShift
        hasNeckShift = true
        bodyCorners = bodyCorners.map { CGPoint(x: $0.x, y: $0.y + smoothedNeckShift) }

        // 3. The garment warped onto the body. A garment much larger than its landing is scaled down first with Lanczos, since
        // the warp samples bilinearly and would shimmer the print.
        let landedTorsoWidth = hypot(bodyCorners[1].x - bodyCorners[0].x, bodyCorners[1].y - bodyCorners[0].y)
        let garmentTorsoWidth = max(garment.torsoCorners.topRight.x - garment.torsoCorners.topLeft.x, 1)
        let preScale = min(1, landedTorsoWidth / garmentTorsoWidth * 1.15)
        let appliedPreScale = preScale < 0.8 ? preScale : 1
        let garmentImage = appliedPreScale < 1
            ? garment.cutout.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: appliedPreScale, kCIInputAspectRatioKey: 1])
            : garment.cutout
        let scaledSourceCorners = sourceCorners.map { CGPoint(x: $0.x * appliedPreScale, y: $0.y * appliedPreScale) }
        guard let homography = perspectiveTransform(from: scaledSourceCorners, to: bodyCorners) else { return frame }
        let garmentWidth = garment.size.width * appliedPreScale, garmentHeight = garment.size.height * appliedPreScale
        let landedCorners = [CGPoint(x: 0, y: 0), CGPoint(x: garmentWidth, y: 0), CGPoint(x: garmentWidth, y: garmentHeight), CGPoint(x: 0, y: garmentHeight)]
            .map { applyingPerspective(homography, to: $0) }
            .map { Self.flipped($0, frameExtent: frameExtent) }
        let clearFrame = CIImage(color: .clear).cropped(to: frameExtent)
        let warpedGarment = garmentImage
            .applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: landedCorners[0]), "inputTopRight": CIVector(cgPoint: landedCorners[1]),
                "inputBottomRight": CIVector(cgPoint: landedCorners[2]), "inputBottomLeft": CIVector(cgPoint: landedCorners[3]),
            ])
            .composited(over: clearFrame)
            .cropped(to: frameExtent)

        // 4. The masks. The person's opacity ramps from 0.35 to 0.65, the room art's occluder, a slightly hard edge.
        let personOpacity = Self.ramp(Self.channel(Self.scaled(personMask, toFill: frameExtent), 0), from: 0.35, to: 0.65)
        let smallMasks = CIImage(bitmapData: Data(analysis.maskPixels), bytesPerRow: smallWidth * 4, size: CGSize(width: smallWidth, height: smallHeight), format: .RGBA8, colorSpace: nil)
        // The analysis masks are a quarter of the frame's width, so scaled up they are blocky. Blurred by about one small
        // pixel before their ramp, their edges come out as smooth curves instead of steps.
        let cameraPixelsPerSmallPixel = frameWidth / Double(smallWidth)
        let upscaledMasks = Self.scaled(smallMasks, toFill: frameExtent)
            .clampedToExtent().applyingGaussianBlur(sigma: cameraPixelsPerSmallPixel * Self.analysisMaskSmoothingInSmallPixels).cropped(to: frameExtent)
        let neckCut = Self.ramp(Self.channel(upscaledMasks, 0), from: 0.3, to: 0.7)
        let uncoveredOldShirt = Self.ramp(Self.channel(upscaledMasks, 1), from: 0.3, to: 0.7)

        let garmentAlpha = Self.channel(warpedGarment, 3)
        let alphaOfTheGarment = Self.multiplied(Self.multiplied(garmentAlpha, personOpacity), Self.inverted(neckCut))
        // The old shirt the garment's outline misses (the waist, under the arms) takes the garment's base color. The fill
        // grows a little under the garment's edge, so no gap of the old shirt shows between them, and it stays inside the
        // person mask pulled in from its edge, since the mask's edge is soft and a fill out to it would spill onto the room.
        let bodyInsideItsEdge = Self.ramp(
            Self.channel(Self.scaled(personMask, toFill: frameExtent), 0)
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: frameWidth * Self.baseColorFillPullInShareOfTheFrameWidth]),
            from: 0.45, to: 0.75
        )
        let growthRadius = cameraPixelsPerSmallPixel * Self.baseColorGrowthUnderTheGarmentInSmallPixels
        let grownUncoveredOldShirt = uncoveredOldShirt
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 2 * growthRadius])
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: growthRadius])
            .cropped(to: frameExtent)
        let baseColorCoverage = Self.multiplied(Self.multiplied(grownUncoveredOldShirt, bodyInsideItsEdge), Self.inverted(neckCut))
        // The garment is drawn over the base color, so their alphas join the way two layers do: a + (1 - a) b, which is the
        // screen blend. Where the garment's softened edge meets the fill, the two together cover the old shirt with no
        // notch between them, where the larger of the two would leave a dip. Core Image's addition filter adds the gray
        // images' own alphas too, which skews the mask, so it is not used here.
        let totalAlpha = alphaOfTheGarment.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: baseColorCoverage])

        // 5. The colors, in gamma encoded sRGB like the spike, since the shading is a ratio of encoded luminances. The garment
        // lies over the base color by its own alpha, so its softened edge fades into the fill and not into the old shirt.
        let baseColor = CIColor(red: CGFloat(garment.baseColor.red), green: CGFloat(garment.baseColor.green), blue: CGFloat(garment.baseColor.blue), colorSpace: sRGBColorSpace) ?? .white
        let garmentWithBaseColor = warpedGarment.composited(over: CIImage(color: baseColor).cropped(to: frameExtent))
        let garmentInGamma = garmentWithBaseColor.applyingFilter("CILinearToSRGBToneCurve")

        let frameInGamma = frame.applyingFilter("CILinearToSRGBToneCurve")
        let luminance = frameInGamma.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), "inputGVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputBVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        let halfSizeLuminance = luminance.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 0.5, kCIInputAspectRatioKey: 1])
        let blurredHalfSize = halfSizeLuminance.clampedToExtent().applyingGaussianBlur(sigma: Self.shadingBlurSigmaAtHalfSize).cropped(to: halfSizeLuminance.extent)
        let blurredLuminance = Self.scaled(blurredHalfSize, toFill: frameExtent)
        // The old shirt's shading relative to its mean, clipped to 0.55 to 1.45, and the exposure match: a product photo is
        // lit flat and bright, so the garment takes half of the camera's brightness ratio.
        let meanLuminance = max(Double(analysis.oldShirtMeanLuminance), 1e-3)
        let exposure = min(1.2, max(0.6, Double(analysis.oldShirtMeanBrightness) / Double(max(garment.meanBrightness, 1e-3))))
        let exposureGain = 0.5 + 0.5 * exposure
        let shading = blurredLuminance
            .applyingFilter("CIColorMatrix", parameters: Self.grayGain(1 / meanLuminance))
            .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0.55, y: 0.55, z: 0.55, w: 0), "inputMaxComponents": CIVector(x: 1.45, y: 1.45, z: 1.45, w: 1)])
            .applyingFilter("CIColorMatrix", parameters: Self.grayGain(exposureGain))
        let worn = Self.multiplied(garmentInGamma, shading)
            .clampedToExtent().applyingGaussianBlur(sigma: 0.8).cropped(to: frameExtent)
            .applyingFilter("CISRGBToneCurveToLinear")

        // 6. The garment over the frame, where the total alpha says.
        return worn
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: frame, kCIInputMaskImageKey: totalAlpha])
            .cropped(to: frameExtent)
    }

    // MARK: Geometry

    /// The body's torso as the garment's torso lands on it: a shirt's shoulder seam sits a little outside the shoulder joints
    /// (12 percent of the shoulder width) and a little above them, and its hem a little below the hips. Top left, top right,
    /// bottom right, bottom left.
    static func bodyTorsoCorners(of torso: BodyTorso) -> [CGPoint] {
        let shoulderSpan = CGPoint(x: torso.imageRightShoulder.x - torso.imageLeftShoulder.x, y: torso.imageRightShoulder.y - torso.imageLeftShoulder.y)
        let outward = CGPoint(x: shoulderSpan.x * 0.12, y: shoulderSpan.y * 0.12)
        let hemDrop = CGPoint(x: torso.hipMidpoint.x - torso.shoulderMidpoint.x, y: torso.hipMidpoint.y - torso.shoulderMidpoint.y)
        return [
            CGPoint(x: torso.imageLeftShoulder.x - outward.x - hemDrop.x * 0.04, y: torso.imageLeftShoulder.y - outward.y - hemDrop.y * 0.04),
            CGPoint(x: torso.imageRightShoulder.x + outward.x - hemDrop.x * 0.04, y: torso.imageRightShoulder.y + outward.y - hemDrop.y * 0.04),
            CGPoint(x: torso.imageRightHip.x + outward.x * 0.6 + hemDrop.x * 0.08, y: torso.imageRightHip.y + outward.y * 0.6 + hemDrop.y * 0.08),
            CGPoint(x: torso.imageLeftHip.x - outward.x * 0.6 + hemDrop.x * 0.08, y: torso.imageLeftHip.y - outward.y * 0.6 + hemDrop.y * 0.08),
        ]
    }

    private static func flipped(_ point: CGPoint, frameExtent: CGRect) -> CGPoint {
        CGPoint(x: frameExtent.minX + point.x, y: frameExtent.minY + frameExtent.height - point.y)
    }

    // MARK: The old shirt's color

    /// The old shirt's color, measured now or every few frames and smoothed in between, so one frame's hand or fold never
    /// moves it.
    private func oldShirtColor(of smallFrame: ShirtSmallFrame) -> SIMD3<Float>? {
        framesSinceTheOldShirtColorWasMeasured += 1
        if smoothedOldShirtColor == nil || framesSinceTheOldShirtColorWasMeasured >= Self.framesBetweenOldShirtColorMeasurements, let measured = smallFrame.measureOldShirtColor() {
            smoothedOldShirtColor = smoothedOldShirtColor.map { $0 + (measured - $0) * 0.5 } ?? measured
            framesSinceTheOldShirtColorWasMeasured = 0
        }
        return smoothedOldShirtColor
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
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": unit, "inputGVector": unit, "inputBVector": unit,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// A gray image's values from `low` to `high` stretched to 0 to 1 and clipped.
    private static func ramp(_ gray: CIImage, from low: Double, to high: Double) -> CIImage {
        let gain = 1 / (high - low), bias = -low / (high - low)
        return gray.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    private static func grayGain(_ gain: Double) -> [String: Any] {
        [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ]
    }

    private static func multiplied(_ first: CIImage, _ second: CIImage) -> CIImage {
        first.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: second])
    }

    private static func inverted(_ gray: CIImage) -> CIImage {
        gray.applyingFilter("CIColorInvert")
    }

    /// The frame and the person mask, each `width` by `height`, read back in one render. The frame is sRGB encoded, the mask
    /// is the values Core Image sees, and the mask's red channel is the person (255 where the person is).
    private func renderedSmallFrameAndPersonMask(frame: CIImage, personMask: CIImage, width: Int, height: Int) -> (frame: [UInt8], person: [UInt8])? {
        let smallExtent = CGRect(x: 0, y: 0, width: width, height: height)
        let frameExtent = frame.extent
        // Lanczos averages the pixels the small copy stands for, so thin lines do not alias away.
        let smallFrame = frame
            .transformed(by: CGAffineTransform(translationX: -frameExtent.minX, y: -frameExtent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(width) / frameExtent.width, kCIInputAspectRatioKey: (Double(height) / frameExtent.height) / (Double(width) / frameExtent.width)])
            .clampedToExtent().cropped(to: smallExtent)
            .applyingFilter("CILinearToSRGBToneCurve")
        let smallPerson = Self.scaled(personMask, toFill: smallExtent).transformed(by: CGAffineTransform(translationX: CGFloat(width), y: 0))
        let combined = smallPerson.composited(over: smallFrame).cropped(to: CGRect(x: 0, y: 0, width: 2 * width, height: height))
        let rowBytes = 2 * width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            // No color space: the frame is already encoded above, and the mask is read as it is.
            ciContext.render(combined, toBitmap: baseAddress, rowBytes: rowBytes, bounds: combined.extent, format: .RGBA8, colorSpace: nil)
        }
        var frameBytes = [UInt8](repeating: 0, count: width * height * 4)
        var personBytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let frameIndex = (row * width + column) * 4, combinedIndex = row * rowBytes + column * 4
                frameBytes[frameIndex] = bytes[combinedIndex]
                frameBytes[frameIndex + 1] = bytes[combinedIndex + 1]
                frameBytes[frameIndex + 2] = bytes[combinedIndex + 2]
                frameBytes[frameIndex + 3] = 255
                personBytes[row * width + column] = bytes[row * rowBytes + (width + column) * 4]
            }
        }
        return (frameBytes, personBytes)
    }
}
