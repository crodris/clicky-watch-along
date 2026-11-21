//
//  RoomTracker.swift
//  leanring-buddy
//
//  Keeps the art on the wall while the laptop turns. Every camera frame is aligned to one keyframe, the frame the wall was
//  measured on, so the art's corners follow the wall and nothing drifts.
//
//  The aligner is ECC, the enhanced correlation coefficient of Evangelidis and Psarakis, ported from OpenCV's ecc.cpp with a
//  3-parameter euclidean model: a rotation and a translation, which is how the picture moves when the laptop turns. A
//  learner's wall is plain and their body covers most of the texture, so corner trackers (Lucas-Kanade, ORB) and a full
//  8-parameter homography all failed in the web prototype, while ECC over every pixel's gradient held at a correlation of 0.78
//  to 1.0 through a pan. The person is masked out of both the keyframe and the current frame.
//
//  Everything here is a pure function over Float grayscale buffers at the track size (320 wide), built from vDSP calls so it
//  stays fast in a Debug build, plus `RoomTracker`, which holds the keyframe and the warp from frame to frame.
//

import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import Vision

// MARK: - Images

/// A grayscale image, row by row from the top, at the track size. Values are any scale, since ECC compares shapes, not levels.
nonisolated struct RoomGrayscaleImage: Sendable {
    let width: Int
    let height: Int
    var pixels: [Float]

    init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "A grayscale image needs width * height pixels")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    /// An 8-bit gray CGImage of the same pixels, clamped to 0...255, for Vision's translational registration.
    var cgImage: CGImage? {
        let bytes = pixels.map { UInt8(max(0, min(255, $0.rounded()))) }
        guard let dataProvider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: dataProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

// MARK: - The warp

/// A turn of the laptop as the picture sees it: a rotation about the image origin (top left) and then a translation, in
/// pixels with y growing down. It maps a keyframe point to where that point is in the current frame.
nonisolated struct EuclideanWarp: Equatable, Sendable {
    var angleRadians: Double
    var translationX: Double
    var translationY: Double

    static let identity = EuclideanWarp(angleRadians: 0, translationX: 0, translationY: 0)

    func apply(to keyframePoint: CGPoint) -> CGPoint {
        let cosine = cos(angleRadians), sine = sin(angleRadians)
        return CGPoint(
            x: cosine * keyframePoint.x - sine * keyframePoint.y + translationX,
            y: sine * keyframePoint.x + cosine * keyframePoint.y + translationY
        )
    }

    /// The same turn in an image `scaleFactor` times as large, such as the camera frame from the track size. A rotation
    /// about the origin keeps its angle, and the translation scales with the pixels.
    func scaled(by scaleFactor: Double) -> EuclideanWarp {
        EuclideanWarp(angleRadians: angleRadians, translationX: translationX * scaleFactor, translationY: translationY * scaleFactor)
    }
}

// MARK: - Settings

/// The numbers the web prototype measured on a plain wall with a person in front of it.
nonisolated enum RoomTrackingSettings {
    /// The camera frame is tracked at this width, 320 by 180 for a 1280 by 720 camera.
    static let trackWidth = 320
    static let eccIterations = 15
    static let eccEpsilon = 1e-3
    /// An alignment counts only at this correlation or above.
    static let goodCorrelation = 0.55
    /// After this many frames in a row below `goodCorrelation`, Vision's translational registration restarts ECC.
    static let framesLostBeforeRecovery = 3
    /// After this many frames in a row below `goodCorrelation`, the art hides until the room is found again.
    static let framesLostBeforeTheArtHides = 15
    /// Each frame the art's corners move this share of the way to their new place, which hides a pixel of jitter.
    static let cornerSmoothingShare = 0.35
}

// MARK: - Buffer operations

/// A 5-tap Gaussian blur (OpenCV's kernel for a size of 5 with no sigma: 1 4 6 4 1, over 16) in both directions, with the
/// edge pixel repeated past the border.
nonisolated func gaussianBlurredWithFiveTaps(_ image: RoomGrayscaleImage) -> RoomGrayscaleImage {
    let width = image.width, height = image.height
    var source = image.pixels
    var destination = [Float](repeating: 0, count: width * height)
    let kernel: [Float] = [1, 4, 6, 4, 1].map { $0 / 16 }
    source.withUnsafeMutableBufferPointer { sourcePointer in
        destination.withUnsafeMutableBufferPointer { destinationPointer in
            var sourceBuffer = vImage_Buffer(data: sourcePointer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
            var destinationBuffer = vImage_Buffer(data: destinationPointer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size)
            _ = vImageSepConvolve_PlanarF(&sourceBuffer, &destinationBuffer, nil, 0, 0, kernel, UInt32(kernel.count), kernel, UInt32(kernel.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
        }
    }
    return RoomGrayscaleImage(width: width, height: height, pixels: destination)
}

/// Samples `image` at each (x, y) with bilinear interpolation, and says which samples fell inside the image (1) or off it
/// (0). The coordinates are pixel centers at whole numbers, y growing down, as OpenCV's warps use.
nonisolated func bilinearSamples(of image: RoomGrayscaleImage, atX sampleXs: [Float], y sampleYs: [Float]) -> (values: [Float], inside: [Float]) {
    let sampleCount = sampleXs.count
    let largestX = Float(image.width - 1), largestY = Float(image.height - 1)
    // Clamp so every gather stays in the image, then mark the samples the clamp moved as outside.
    let clampedXs = vDSP.clip(sampleXs, to: 0...largestX)
    let clampedYs = vDSP.clip(sampleYs, to: 0...largestY)
    let movedByTheClamp = vDSP.add(vDSP.absolute(vDSP.subtract(sampleXs, clampedXs)), vDSP.absolute(vDSP.subtract(sampleYs, clampedYs)))
    var inside = [Float](repeating: 0, count: sampleCount)
    var threshold: Float = 1e-4
    var halfValue: Float = -0.5
    // vDSP_vlim gives -0.5 where a sample moved (at or over the threshold) and +0.5 where it did not, so +0.5 makes it 0 or 1.
    vDSP_vlim(movedByTheClamp, 1, &threshold, &halfValue, &inside, 1, vDSP_Length(sampleCount))
    inside = vDSP.add(0.5, inside)

    // The top-left neighbor stays one pixel inside the far edge, so its right and lower neighbors exist.
    let leftXs = vDSP.clip(vForce.floor(clampedXs), to: 0...max(0, largestX - 1))
    let topYs = vDSP.clip(vForce.floor(clampedYs), to: 0...max(0, largestY - 1))
    let rightShares = vDSP.subtract(clampedXs, leftXs)
    let lowerShares = vDSP.subtract(clampedYs, topYs)
    let topLeftIndexes = vDSP.add(vDSP.multiply(Float(image.width), topYs), leftXs)
    func gathered(offset: Float) -> [Float] {
        let indexes = vDSP.add(offset, topLeftIndexes)
        var values = [Float](repeating: 0, count: sampleCount)
        image.pixels.withUnsafeBufferPointer { pixelsPointer in
            indexes.withUnsafeBufferPointer { indexesPointer in
                vDSP_vindex(pixelsPointer.baseAddress!, indexesPointer.baseAddress!, 1, &values, 1, vDSP_Length(sampleCount))
            }
        }
        return values
    }
    let topLeft = gathered(offset: 0)
    let topRight = gathered(offset: 1)
    let bottomLeft = gathered(offset: Float(image.width))
    let bottomRight = gathered(offset: Float(image.width + 1))
    let top = vDSP.add(topLeft, vDSP.multiply(rightShares, vDSP.subtract(topRight, topLeft)))
    let bottom = vDSP.add(bottomLeft, vDSP.multiply(rightShares, vDSP.subtract(bottomRight, bottomLeft)))
    let values = vDSP.add(top, vDSP.multiply(lowerShares, vDSP.subtract(bottom, top)))
    return (values, inside)
}

/// The central-difference gradient (half the difference of the two neighbors, as ecc.cpp's filter), zero on the border.
nonisolated func centralDifferenceGradients(of pixels: [Float], width: Int, height: Int) -> (alongX: [Float], alongY: [Float]) {
    let pixelCount = width * height
    var alongX = [Float](repeating: 0, count: pixelCount)
    var alongY = [Float](repeating: 0, count: pixelCount)
    guard width >= 3, height >= 3 else { return (alongX, alongY) }
    pixels.withUnsafeBufferPointer { pixelsPointer in
        let base = pixelsPointer.baseAddress!
        // One long subtraction over the whole buffer: pixel i+1 minus pixel i-1, and pixel i+width minus pixel i-width.
        // The values that wrap across a row end are on the border, which is cleared below.
        alongX.withUnsafeMutableBufferPointer { alongXPointer in
            vDSP_vsub(base, 1, base + 2, 1, alongXPointer.baseAddress! + 1, 1, vDSP_Length(pixelCount - 2))
        }
        alongY.withUnsafeMutableBufferPointer { alongYPointer in
            vDSP_vsub(base, 1, base + 2 * width, 1, alongYPointer.baseAddress! + width, 1, vDSP_Length(pixelCount - 2 * width))
        }
    }
    alongX = vDSP.multiply(0.5, alongX)
    alongY = vDSP.multiply(0.5, alongY)
    for row in 0..<height {
        alongX[row * width] = 0
        alongX[row * width + width - 1] = 0
    }
    for column in 0..<width {
        alongY[column] = 0
        alongY[(height - 1) * width + column] = 0
    }
    return (alongX, alongY)
}

// MARK: - ECC

/// The keyframe as ECC needs it, prepared once: blurred, with its room mask (1 where the room is, 0 on the person) and the
/// pixel grid the jacobian is built on.
nonisolated struct RoomECCKeyframe: Sendable {
    let blurred: RoomGrayscaleImage
    let roomMask: [Float]
    let gridXs: [Float]
    let gridYs: [Float]

    init(grayscale: RoomGrayscaleImage, roomMask: [Float]) {
        precondition(roomMask.count == grayscale.pixels.count, "The room mask must match the keyframe")
        blurred = gaussianBlurredWithFiveTaps(grayscale)
        self.roomMask = roomMask
        var gridXs = [Float](repeating: 0, count: grayscale.pixels.count)
        var gridYs = gridXs
        for row in 0..<grayscale.height {
            for column in 0..<grayscale.width {
                gridXs[row * grayscale.width + column] = Float(column)
                gridYs[row * grayscale.width + column] = Float(row)
            }
        }
        self.gridXs = gridXs
        self.gridYs = gridYs
    }
}

nonisolated struct ECCAlignment: Equatable, Sendable {
    let warp: EuclideanWarp
    /// The enhanced correlation coefficient, from -1 to 1. 0 when the alignment could not converge.
    let correlation: Double
}

/// Finds the euclidean warp that maps the keyframe onto the current frame, starting from `startingWarp` (the last frame's
/// warp, so a slow turn needs one or two iterations). `currentBlurred` is the current frame after
/// `gaussianBlurredWithFiveTaps`, and `currentRoomMask` is 1 where the room is and 0 on the person, in the current frame.
/// A pixel counts only where the keyframe and the current frame both show the room.
/// Returns correlation 0 and the starting warp when it cannot converge, as OpenCV throws there.
nonisolated func alignedWithECC(
    keyframe: RoomECCKeyframe,
    currentBlurred: RoomGrayscaleImage,
    currentRoomMask: [Float],
    startingWarp: EuclideanWarp,
    iterations: Int = RoomTrackingSettings.eccIterations,
    epsilon: Double = RoomTrackingSettings.eccEpsilon
) -> ECCAlignment {
    let width = keyframe.blurred.width, height = keyframe.blurred.height
    let currentRoomMaskImage = RoomGrayscaleImage(width: currentBlurred.width, height: currentBlurred.height, pixels: currentRoomMask)
    var warp = startingWarp
    var correlationCoefficient = 0.0
    var lastCorrelationCoefficient = -Double.infinity

    for _ in 0..<iterations {
        guard abs(correlationCoefficient - lastCorrelationCoefficient) >= epsilon else { break }
        let cosine = Float(cos(warp.angleRadians)), sine = Float(sin(warp.angleRadians))

        // Where each keyframe pixel lands in the current frame.
        let sampleXs = vDSP.add(Float(warp.translationX), vDSP.subtract(vDSP.multiply(cosine, keyframe.gridXs), vDSP.multiply(sine, keyframe.gridYs)))
        let sampleYs = vDSP.add(Float(warp.translationY), vDSP.add(vDSP.multiply(sine, keyframe.gridXs), vDSP.multiply(cosine, keyframe.gridYs)))
        let (warpedImage, landedInside) = bilinearSamples(of: currentBlurred, atX: sampleXs, y: sampleYs)
        let (warpedRoomMask, _) = bilinearSamples(of: currentRoomMaskImage, atX: sampleXs, y: sampleYs)
        // A sample counts when it is in the frame, fully on the room in the current frame, and on the room in the keyframe.
        let warpedRoomMaskIsWhole = wholeOnly(warpedRoomMask)
        var validMask = vDSP.multiply(vDSP.multiply(landedInside, warpedRoomMaskIsWhole), keyframe.roomMask)
        // The gradient of the warped image is taken in the keyframe's grid, so its border is not a real gradient.
        clearTheBorder(of: &validMask, width: width, height: height)
        let validPixelCount = Double(vDSP.sum(validMask))
        guard validPixelCount > 100 else { return ECCAlignment(warp: startingWarp, correlation: 0) }

        // The current frame's gradient at each landing point. The warp is a rotation, so the gradient of the warped image
        // turned by the warp's rotation is the frame's own gradient there: grad I(W x) = R grad (I o W)(x).
        let (warpedGradientAlongX, warpedGradientAlongY) = centralDifferenceGradients(of: warpedImage, width: width, height: height)
        let gradientAlongX = vDSP.multiply(validMask, vDSP.subtract(vDSP.multiply(cosine, warpedGradientAlongX), vDSP.multiply(sine, warpedGradientAlongY)))
        let gradientAlongY = vDSP.multiply(validMask, vDSP.add(vDSP.multiply(sine, warpedGradientAlongX), vDSP.multiply(cosine, warpedGradientAlongY)))

        // Zero-mean images over the valid pixels.
        let templateMean = Double(vDSP.dot(keyframe.blurred.pixels, validMask)) / validPixelCount
        let imageMean = Double(vDSP.dot(warpedImage, validMask)) / validPixelCount
        let templateZeroMean = vDSP.multiply(validMask, vDSP.add(Float(-templateMean), keyframe.blurred.pixels))
        let imageZeroMean = vDSP.multiply(validMask, vDSP.add(Float(-imageMean), warpedImage))
        let templateNorm = Double(vDSP.sumOfSquares(templateZeroMean)).squareRoot()
        let imageNorm = Double(vDSP.sumOfSquares(imageZeroMean)).squareRoot()
        guard templateNorm > 0, imageNorm > 0 else { return ECCAlignment(warp: startingWarp, correlation: 0) }

        // The jacobian of the euclidean warp, one column per parameter (angle, x, y), as image_jacobian_euclidean_ECC.
        let hatXs = vDSP.subtract(vDSP.multiply(-sine, keyframe.gridXs), vDSP.multiply(cosine, keyframe.gridYs))
        let hatYs = vDSP.subtract(vDSP.multiply(cosine, keyframe.gridXs), vDSP.multiply(sine, keyframe.gridYs))
        let jacobianColumns = [
            vDSP.add(vDSP.multiply(gradientAlongX, hatXs), vDSP.multiply(gradientAlongY, hatYs)),
            gradientAlongX,
            gradientAlongY,
        ]
        var hessian = simd_double3x3()
        for row in 0..<3 {
            for column in row..<3 {
                let entry = Double(vDSP.dot(jacobianColumns[row], jacobianColumns[column]))
                hessian[column][row] = entry
                hessian[row][column] = entry
            }
        }
        guard abs(hessian.determinant) > 1e-12 else { return ECCAlignment(warp: startingWarp, correlation: 0) }
        let hessianInverse = hessian.inverse

        let correlation = Double(vDSP.dot(templateZeroMean, imageZeroMean))
        lastCorrelationCoefficient = correlationCoefficient
        correlationCoefficient = correlation / (imageNorm * templateNorm)

        let imageProjection = SIMD3<Double>(jacobianColumns.map { Double(vDSP.dot($0, imageZeroMean)) })
        let templateProjection = SIMD3<Double>(jacobianColumns.map { Double(vDSP.dot($0, templateZeroMean)) })
        let imageProjectionHessian = hessianInverse * imageProjection
        let lambdaNumerator = imageNorm * imageNorm - simd_dot(imageProjection, imageProjectionHessian)
        let lambdaDenominator = correlation - simd_dot(templateProjection, imageProjectionHessian)
        // ecc.cpp stops here with an error: the images are too different to converge.
        guard lambdaDenominator > 0 else { return ECCAlignment(warp: startingWarp, correlation: 0) }
        let lambda = lambdaNumerator / lambdaDenominator

        // The error image is lambda * template - image, so its projection is lambda * q - p.
        let errorProjection = lambda * templateProjection - imageProjection
        let warpChange = hessianInverse * errorProjection
        warp.angleRadians += warpChange.x
        warp.translationX += warpChange.y
        warp.translationY += warpChange.z
    }
    return ECCAlignment(warp: warp, correlation: correlationCoefficient)
}

/// 1 where a bilinear sample of a 0-or-1 mask was whole (every neighbor 1), 0 elsewhere, so a pixel next to the person never counts.
nonisolated private func wholeOnly(_ sampledMask: [Float]) -> [Float] {
    var result = [Float](repeating: 0, count: sampledMask.count)
    var threshold: Float = 0.999
    var halfValue: Float = 0.5
    vDSP_vlim(sampledMask, 1, &threshold, &halfValue, &result, 1, vDSP_Length(sampledMask.count))
    return vDSP.add(0.5, result)
}

nonisolated private func clearTheBorder(of mask: inout [Float], width: Int, height: Int) {
    for column in 0..<width {
        mask[column] = 0
        mask[(height - 1) * width + column] = 0
    }
    for row in 0..<height {
        mask[row * width] = 0
        mask[row * width + width - 1] = 0
    }
}

// MARK: - Recovery

/// How far the room moved from the keyframe to the current frame, found by Vision's translational registration, which
/// searches the whole frame, so it finds the room after a turn too fast for ECC. Nil when Vision finds nothing.
nonisolated func translationFromTheKeyframe(keyframeImage: CGImage, currentImage: CGImage) -> CGVector? {
    // The current frame is the reference and the keyframe the image aligned to it. Vision's y grows up, so a room that
    // moved down in the picture comes back with a negative ty.
    let registrationRequest = VNTranslationalImageRegistrationRequest(targetedCGImage: keyframeImage, options: [:])
    do {
        try VNImageRequestHandler(cgImage: currentImage, options: [:]).perform([registrationRequest])
    } catch {
        return nil
    }
    guard let alignment = registrationRequest.results?.first as? VNImageTranslationAlignmentObservation else { return nil }
    return CGVector(dx: alignment.alignmentTransform.tx, dy: -alignment.alignmentTransform.ty)
}

// MARK: - Frames to track

/// A plane of 8-bit pixels (a camera frame's luma, or a person segmentation mask) scaled to `width` by `height`.
nonisolated func planar8Scaled(baseAddress: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, toWidth targetWidth: Int, height targetHeight: Int) -> [UInt8] {
    var scaled = [UInt8](repeating: 0, count: targetWidth * targetHeight)
    scaled.withUnsafeMutableBufferPointer { scaledPointer in
        var sourceBuffer = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: baseAddress), height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: bytesPerRow)
        var destinationBuffer = vImage_Buffer(data: scaledPointer.baseAddress, height: vImagePixelCount(targetHeight), width: vImagePixelCount(targetWidth), rowBytes: targetWidth)
        _ = vImageScale_Planar8(&sourceBuffer, &destinationBuffer, nil, vImage_Flags(kvImageNoFlags))
    }
    return scaled
}

/// The first plane of a pixel buffer (the luma of a 420 frame, or a one-component mask) scaled to the given size.
nonisolated func firstPlaneScaled(of pixelBuffer: CVPixelBuffer, toWidth targetWidth: Int, height targetHeight: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    let planeIsSeparate = CVPixelBufferIsPlanar(pixelBuffer)
    guard let baseAddress = planeIsSeparate ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) : CVPixelBufferGetBaseAddress(pixelBuffer) else {
        return [UInt8](repeating: 0, count: targetWidth * targetHeight)
    }
    return planar8Scaled(
        baseAddress: baseAddress,
        width: planeIsSeparate ? CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) : CVPixelBufferGetWidth(pixelBuffer),
        height: planeIsSeparate ? CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) : CVPixelBufferGetHeight(pixelBuffer),
        bytesPerRow: planeIsSeparate ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : CVPixelBufferGetBytesPerRow(pixelBuffer),
        toWidth: targetWidth,
        height: targetHeight
    )
}

/// The person at the track size, 255 on the person and 0 on the room: the segmentation's confidence over 0.3, grown by 4
/// pixels on each side (a 9 by 9 square), so the person's soft edge stays out of the tracking too.
nonisolated func personMaskAtTrackSize(segmentationConfidence: [UInt8], width: Int, height: Int) -> [UInt8] {
    var person = segmentationConfidence.map { $0 >= 77 ? UInt8(255) : 0 }
    var grown = [UInt8](repeating: 0, count: width * height)
    person.withUnsafeMutableBufferPointer { personPointer in
        grown.withUnsafeMutableBufferPointer { grownPointer in
            var sourceBuffer = vImage_Buffer(data: personPointer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            var destinationBuffer = vImage_Buffer(data: grownPointer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            _ = vImageMax_Planar8(&sourceBuffer, &destinationBuffer, nil, 0, 0, 9, 9, vImage_Flags(kvImageEdgeExtend))
        }
    }
    return grown
}

/// 1 where the room is and 0 on the person, as ECC weighs pixels.
nonisolated func roomMask(fromPersonMask personMask: [UInt8]) -> [Float] {
    personMask.map { $0 == 0 ? 1 : 0 }
}

/// The track size for a camera frame: 320 wide and the frame's shape.
nonisolated func trackSize(forFrameWidth frameWidth: Int, frameHeight: Int) -> (width: Int, height: Int) {
    let trackWidth = RoomTrackingSettings.trackWidth
    return (trackWidth, max(1, Int((Double(frameHeight) * Double(trackWidth) / Double(frameWidth)).rounded())))
}

// MARK: - The tracker

/// What one frame's tracking found.
nonisolated struct RoomTrackStep: Equatable, Sendable {
    let warp: EuclideanWarp
    let correlation: Double
    let framesLostInARow: Int
    /// The room has been lost long enough that the art hides until it is found again.
    var theArtIsHidden: Bool { framesLostInARow > RoomTrackingSettings.framesLostBeforeTheArtHides }
}

/// Holds the keyframe and the last good warp, and aligns each new frame to the keyframe. Used from one queue only.
nonisolated final class RoomTracker {
    let keyframe: RoomECCKeyframe
    private let keyframeImage: CGImage?
    private(set) var warp = EuclideanWarp.identity
    private(set) var framesLostInARow = 0
    /// Starts at the gap, so the first loss may recover at once.
    private var framesSinceTheLastRecovery = RoomTrackingSettings.framesLostBeforeRecovery

    init(keyframeGrayscale: RoomGrayscaleImage, keyframeRoomMask: [Float]) {
        keyframe = RoomECCKeyframe(grayscale: keyframeGrayscale, roomMask: keyframeRoomMask)
        keyframeImage = keyframeGrayscale.cgImage
    }

    /// Aligns `currentGrayscale` (not blurred) to the keyframe. After a few lost frames, Vision finds the room's shift and
    /// ECC restarts from it, at most once every few frames.
    func track(currentGrayscale: RoomGrayscaleImage, currentRoomMask: [Float]) -> RoomTrackStep {
        let currentBlurred = gaussianBlurredWithFiveTaps(currentGrayscale)
        let alignment = alignedWithECC(keyframe: keyframe, currentBlurred: currentBlurred, currentRoomMask: currentRoomMask, startingWarp: warp)
        if alignment.correlation >= RoomTrackingSettings.goodCorrelation {
            warp = alignment.warp
            framesLostInARow = 0
            return RoomTrackStep(warp: warp, correlation: alignment.correlation, framesLostInARow: 0)
        }
        framesLostInARow += 1
        framesSinceTheLastRecovery += 1
        var bestCorrelation = alignment.correlation
        if framesLostInARow >= RoomTrackingSettings.framesLostBeforeRecovery,
           framesSinceTheLastRecovery >= RoomTrackingSettings.framesLostBeforeRecovery,
           let keyframeImage, let currentImage = currentGrayscale.cgImage {
            framesSinceTheLastRecovery = 0
            if let shift = translationFromTheKeyframe(keyframeImage: keyframeImage, currentImage: currentImage) {
                let recoveredAlignment = alignedWithECC(
                    keyframe: keyframe,
                    currentBlurred: currentBlurred,
                    currentRoomMask: currentRoomMask,
                    startingWarp: EuclideanWarp(angleRadians: 0, translationX: shift.dx, translationY: shift.dy)
                )
                bestCorrelation = max(bestCorrelation, recoveredAlignment.correlation)
                if recoveredAlignment.correlation >= RoomTrackingSettings.goodCorrelation {
                    warp = recoveredAlignment.warp
                    framesLostInARow = 0
                }
            }
        }
        return RoomTrackStep(warp: warp, correlation: bestCorrelation, framesLostInARow: framesLostInARow)
    }
}

/// Moves each corner `share` of the way from where it was to where it is now. With no earlier corners, the new ones stand.
nonisolated func smoothedCorners(previous previousCorners: [CGPoint]?, current currentCorners: [CGPoint], share: Double = RoomTrackingSettings.cornerSmoothingShare) -> [CGPoint] {
    guard let previousCorners, previousCorners.count == currentCorners.count else { return currentCorners }
    return zip(previousCorners, currentCorners).map { previousCorner, currentCorner in
        CGPoint(
            x: previousCorner.x + (currentCorner.x - previousCorner.x) * share,
            y: previousCorner.y + (currentCorner.y - previousCorner.y) * share
        )
    }
}
