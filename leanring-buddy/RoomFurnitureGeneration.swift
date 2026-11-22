//
//  RoomFurnitureGeneration.swift
//  leanring-buddy
//
//  The app's side of the two generation services behind the furniture try-on, which work for any furniture page with a
//  photo and a size, not only the few that publish a 3D model:
//  - `POST /room-furniture-composite`: OpenAI's image edit draws the product into a camera keyframe of the learner's room,
//    inside a mask of the item's real size, lit by the room. The client pastes the reply back only inside that mask.
//  - `POST /try-it-model`: fal.ai turns the product photo into a GLB. The client keeps each GLB on disk by a hash of its
//    inputs, so the same product is never paid for twice.
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a generation call failed, so the panel can say "this is not set up" apart from "this failed".
nonisolated enum RoomFurnitureGenerationError: Error, Equatable {
    /// The Worker answered 503: the service has no key (`FAL_KEY` for the 3D model), so asking again will not help.
    case serviceIsNotSetUp(body: String)
    /// Any other status that is not 200. 401 is a missing or wrong app secret, 504 a model that took too long, 502 a
    /// failed or refused generation, and 400 a request the Worker refused.
    case workerReturned(statusCode: Int, body: String)
    /// The Worker answered 200 with something that is not what the route promises.
    case replyCouldNotBeRead(reason: String)
    /// The keyframe or the mask the caller passed could not be decoded, so the reply cannot be pasted into the keyframe.
    case inputCouldNotBeRead(reason: String)
}

// MARK: - The mask

/// The convex hull of `points` in order around it, with collinear points dropped (Andrew's monotone chain).
nonisolated func convexHull(of points: [CGPoint]) -> [CGPoint] {
    let sortedPoints = points.sorted { first, second in first.x != second.x ? first.x < second.x : first.y < second.y }
    guard sortedPoints.count >= 3 else { return sortedPoints }
    func turn(_ origin: CGPoint, _ first: CGPoint, _ second: CGPoint) -> CGFloat {
        (first.x - origin.x) * (second.y - origin.y) - (first.y - origin.y) * (second.x - origin.x)
    }
    var lowerHull: [CGPoint] = []
    for point in sortedPoints {
        while lowerHull.count >= 2, turn(lowerHull[lowerHull.count - 2], lowerHull[lowerHull.count - 1], point) <= 0 {
            lowerHull.removeLast()
        }
        lowerHull.append(point)
    }
    var upperHull: [CGPoint] = []
    for point in sortedPoints.reversed() {
        while upperHull.count >= 2, turn(upperHull[upperHull.count - 2], upperHull[upperHull.count - 1], point) <= 0 {
            upperHull.removeLast()
        }
        upperHull.append(point)
    }
    return Array(lowerHull.dropLast()) + Array(upperHull.dropLast())
}

/// The mask `/room-furniture-composite` takes: an 8-bit gray PNG the size of the keyframe, white inside the convex hull
/// of the item's projected box corners grown by `shadowMarginPixels` (room for its contact shadow), black elsewhere.
/// `projectedCorners` are keyframe pixels with y growing down. Nil when the corners do not span an area, when any number
/// is not finite, or when the frame or the margin is not a usable size.
nonisolated func furnitureCompositeMaskPNG(
    projectedCorners: [CGPoint],
    frameWidth: Int,
    frameHeight: Int,
    shadowMarginPixels: Double
) -> Data? {
    // A zero or negative frame size needs no check of its own: the bitmap context below refuses it.
    guard shadowMarginPixels.isFinite, shadowMarginPixels >= 0,
          projectedCorners.allSatisfy({ corner in corner.x.isFinite && corner.y.isFinite }) else { return nil }
    let hull = convexHull(of: projectedCorners)
    guard hull.count >= 3 else { return nil }

    guard let context = CGContext(
        data: nil,
        width: frameWidth,
        height: frameHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGImageAlphaInfo.none.rawValue
    ) else { return nil }
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight))
    // The corners have y growing down, and a bitmap context's y grows up.
    context.translateBy(x: 0, y: CGFloat(frameHeight))
    context.scaleBy(x: 1, y: -1)

    let hullPath = CGMutablePath()
    hullPath.addLines(between: hull)
    hullPath.closeSubpath()
    context.setFillColor(gray: 1, alpha: 1)
    context.addPath(hullPath)
    context.fillPath()
    // A round-joined stroke of twice the margin around the filled hull is the hull grown by the margin in every direction.
    if shadowMarginPixels > 0 {
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineWidth(CGFloat(shadowMarginPixels * 2))
        context.setLineJoin(.round)
        context.addPath(hullPath)
        context.strokePath()
    }

    guard let maskImage = context.makeImage() else { return nil }
    let pngData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, maskImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return pngData as Data
}

// MARK: - Pasting the reply into the keyframe

/// OpenAI's image edit follows a mask only as guidance: on the live check (2026-11-22) a chair's arm and a table's legs
/// came out up to about 20 pixels past it. The paste takes the reply this far past the mask, so the piece is not cut off.
nonisolated let furnitureCompositePasteSlackPixels: Double = 24
/// The paste's edge fades over about this many pixels, so no seam shows where the reply meets the filmed frame.
nonisolated let furnitureCompositePasteFeatherPixels: Double = 4
/// How wide the ring of room just outside the paste is, where the reply's tone is compared with the keyframe's.
nonisolated let furnitureCompositeToneMatchBandPixels: Double = 96

/// A gain and an offset for one color channel, in sRGB byte values: `corrected = gain * reply + offset`.
nonisolated struct ChannelToneFit: Equatable {
    var gain: Double
    var offset: Double

    static let unchanged = ChannelToneFit(gain: 1, offset: 0)
}

/// A fit outside these bounds means the ring held something other than the same room, such as part of the piece or a
/// flat color, so the reply is pasted as it came. The live check's replies needed gains of about 0.85 to 1 and offsets
/// within about 10.
nonisolated let toneFitGainRange: ClosedRange<Double> = 0.7...1.4
nonisolated let toneFitLargestOffset: Double = 40
/// Fewer ring pixels than this give a fit that one stray patch can swing.
nonisolated let toneFitFewestSamples = 500

/// The least squares gain and offset per channel (red, green, blue) that turn the reply's pixels into the keyframe's at
/// the sampled pixels. The edit re-exposes the whole frame (on the live check, a wall came back 12 to 17 levels brighter),
/// so the pasted region would show as a lighter patch without this. Pixel arrays are RGBA bytes of the same size.
nonisolated func toneFitsMatchingTheReplyToTheKeyframe(
    keyframePixels: [UInt8],
    replyPixels: [UInt8],
    sampleIsInTheRing: [Bool]
) -> [ChannelToneFit] {
    let sampleCount = sampleIsInTheRing.reduce(0) { count, isSampled in count + (isSampled ? 1 : 0) }
    guard sampleCount >= toneFitFewestSamples else { return Array(repeating: .unchanged, count: 3) }
    return (0..<3).map { channel in
        var replySum = 0.0, keyframeSum = 0.0, replySquareSum = 0.0, productSum = 0.0
        for (pixelIndex, isSampled) in sampleIsInTheRing.enumerated() where isSampled {
            let replyValue = Double(replyPixels[pixelIndex * 4 + channel])
            let keyframeValue = Double(keyframePixels[pixelIndex * 4 + channel])
            replySum += replyValue
            keyframeSum += keyframeValue
            replySquareSum += replyValue * replyValue
            productSum += replyValue * keyframeValue
        }
        let count = Double(sampleCount)
        let replyMean = replySum / count
        let keyframeMean = keyframeSum / count
        let replyVariance = replySquareSum / count - replyMean * replyMean
        // A flat ring has no spread to fit a gain to: its gain comes out as NaN or huge, which the range below refuses.
        let gain = (productSum / count - replyMean * keyframeMean) / replyVariance
        let fit = ChannelToneFit(gain: gain, offset: keyframeMean - gain * replyMean)
        guard toneFitGainRange.contains(fit.gain), abs(fit.offset) <= toneFitLargestOffset else { return .unchanged }
        return fit
    }
}

/// An image's RGBA bytes in sRGB at `width` by `height`, scaled when its own size differs, with the first row the top.
nonisolated func rgbaBytes(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    let drew = pixelBytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drew ? pixelBytes : nil
}

/// An image's gray bytes at `width` by `height`, with the first row the top.
nonisolated func grayBytes(of image: CGImage, width: Int, height: Int) -> [UInt8]? {
    var pixelBytes = [UInt8](repeating: 0, count: width * height)
    let drew = pixelBytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drew ? pixelBytes : nil
}

/// The mask grown by `radiusPixels` and blurred by `blurPixels`, at the frame's size.
nonisolated func grownMaskImage(_ mask: CGImage, frameExtent: CGRect, radiusPixels: Double, blurPixels: Double, context: CIContext) -> CGImage? {
    let maskImage = CIImage(cgImage: mask).transformed(by: CGAffineTransform(
        scaleX: frameExtent.width / CGFloat(mask.width),
        y: frameExtent.height / CGFloat(mask.height)
    ))
    let grownMask = CIFilter.morphologyMaximum()
    grownMask.inputImage = maskImage.clampedToExtent()
    grownMask.radius = Float(radiusPixels)
    var outputImage = grownMask.outputImage
    if blurPixels > 0 {
        let blurredMask = CIFilter.gaussianBlur()
        blurredMask.inputImage = outputImage
        // Core Image's radius is about two standard deviations, so the edge fades over about `blurPixels` on each side.
        blurredMask.radius = Float(blurPixels / 2)
        outputImage = blurredMask.outputImage
    }
    guard let outputImage else { return nil }
    return context.createCGImage(outputImage.cropped(to: frameExtent), from: frameExtent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
}

/// The keyframe with `generated` pasted in only where the mask, grown by `slackPixels` and feathered by
/// `featherPixels`, allows. The edit re-renders the whole frame, and pixels away from the piece come back slightly changed
/// (a window's view, the light on a wall), so everything past the grown mask stays exactly as filmed. Before the paste,
/// the reply's tone is matched to the keyframe on a ring `toneMatchBandPixels` wide just outside the paste
/// (`toneFitsMatchingTheReplyToTheKeyframe`), so the pasted region does not show as a lighter or darker patch. A
/// `generated` of another size, which the Worker returns for a keyframe size OpenAI does not take, is scaled to the
/// keyframe first.
nonisolated func furnitureCompositePasted(
    keyframe: CGImage,
    generated: CGImage,
    mask: CGImage,
    slackPixels: Double = furnitureCompositePasteSlackPixels,
    featherPixels: Double = furnitureCompositePasteFeatherPixels,
    toneMatchBandPixels: Double = furnitureCompositeToneMatchBandPixels,
    context: CIContext
) -> CGImage? {
    let width = keyframe.width
    let height = keyframe.height
    let frameExtent = CGRect(x: 0, y: 0, width: width, height: height)
    guard let keyframePixels = rgbaBytes(of: keyframe, width: width, height: height),
          let replyPixels = rgbaBytes(of: generated, width: width, height: height),
          let pasteMask = grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: slackPixels, blurPixels: featherPixels, context: context),
          let ringOuterMask = grownMaskImage(mask, frameExtent: frameExtent, radiusPixels: slackPixels + featherPixels + toneMatchBandPixels, blurPixels: 0, context: context),
          let pasteWeights = grayBytes(of: pasteMask, width: width, height: height),
          let ringOuterWeights = grayBytes(of: ringOuterMask, width: width, height: height) else { return nil }

    // The ring is the room the paste does not take but the grown mask reaches: the closest room to the piece.
    let sampleIsInTheRing = zip(pasteWeights, ringOuterWeights).map { pasteWeight, ringOuterWeight in
        pasteWeight == 0 && ringOuterWeight >= 128
    }
    let toneFits = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: replyPixels, sampleIsInTheRing: sampleIsInTheRing)

    var pastedPixels = keyframePixels
    for pixelIndex in 0..<(width * height) {
        let pasteWeight = Double(pasteWeights[pixelIndex]) / 255
        for channel in 0..<3 {
            let byteIndex = pixelIndex * 4 + channel
            let correctedReplyValue = min(255, max(0, toneFits[channel].gain * Double(replyPixels[byteIndex]) + toneFits[channel].offset))
            pastedPixels[byteIndex] = UInt8((Double(keyframePixels[byteIndex]) * (1 - pasteWeight) + correctedReplyValue * pasteWeight).rounded())
        }
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let pixelProvider = CGDataProvider(data: Data(pastedPixels) as CFData) else { return nil }
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: pixelProvider,
        decode: nil, shouldInterpolate: true, intent: .defaultIntent
    )
}

nonisolated func decodedImage(from imageData: Data) -> CGImage? {
    guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
}

// MARK: - The model cache

/// Every GLB starts with the ASCII magic "glTF".
nonisolated func dataIsAGLB(_ modelData: Data) -> Bool {
    modelData.prefix(4) == Data("glTF".utf8)
}

/// The cache file's name for a model: a SHA-256 of the photo and the title, so a changed photo or title pays again and
/// the same product never does. Each part is written with its length first, so two inputs can never join to the same bytes.
nonisolated func tryItModelCacheKey(productJPEG: Data, itemTitle: String) -> String {
    var hasher = SHA256()
    for part in [productJPEG, Data(itemTitle.utf8)] {
        withUnsafeBytes(of: UInt64(part.count).bigEndian) { lengthBytes in hasher.update(bufferPointer: lengthBytes) }
        hasher.update(data: part)
    }
    return hasher.finalize().map { byte in String(format: "%02x", byte) }.joined()
}

/// `~/Library/Caches/<bundle id>/TryItModels/`. Caches, since macOS may clear it and the Worker can make the model again.
nonisolated func defaultTryItModelCacheFolder() -> URL {
    let cachesFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? FileManager.default.temporaryDirectory
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.crodris.clicky-watch-along"
    return cachesFolder.appendingPathComponent(bundleIdentifier, isDirectory: true).appendingPathComponent("TryItModels", isDirectory: true)
}

// MARK: - The client

/// What `/room-furniture-composite` answers: the drawn frame as JPEG, at the size OpenAI drew it.
private struct RoomFurnitureCompositeReply: Decodable {
    let imageJPEGBase64: String
    let width: Int
    let height: Int
}

@MainActor
final class RoomFurnitureGenerationClient {
    private let compositeURL: URL
    private let tryItModelURL: URL
    private let session: URLSession
    private let modelCacheFolder: URL
    private let ciContext: CIContext

    /// The Worker bounds each call at 120 seconds. A little more here lets its own 502 or 504 arrive instead of a timeout.
    static let timeoutSeconds: TimeInterval = 150

    /// Tests pass a session configuration whose protocol classes answer for the Worker, and a cache folder of their own.
    init(
        workerBaseURL: String,
        sessionConfiguration: URLSessionConfiguration = .default,
        modelCacheFolder: URL = defaultTryItModelCacheFolder(),
        ciContext: CIContext = CIContext()
    ) {
        guard let compositeURL = URL(string: "\(workerBaseURL)/room-furniture-composite"),
              let tryItModelURL = URL(string: "\(workerBaseURL)/try-it-model") else {
            preconditionFailure("Worker base URL did not form the furniture generation URLs: \(workerBaseURL)")
        }
        self.compositeURL = compositeURL
        self.tryItModelURL = tryItModelURL
        sessionConfiguration.timeoutIntervalForRequest = Self.timeoutSeconds
        sessionConfiguration.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: sessionConfiguration)
        self.modelCacheFolder = modelCacheFolder
        self.ciContext = ciContext
    }

    private func post(_ jsonBody: [String: Any], to url: URL) async throws -> Data {
        let (responseData, statusCode) = try await WorkerJSONPost.send(
            try JSONSerialization.data(withJSONObject: jsonBody),
            to: url,
            using: session,
            sendsAppSecret: true
        )
        let responseText = String(decoding: responseData, as: UTF8.self)
        switch statusCode {
        case 200: return responseData
        case 503: throw RoomFurnitureGenerationError.serviceIsNotSetUp(body: responseText)
        default: throw RoomFurnitureGenerationError.workerReturned(statusCode: statusCode, body: responseText)
        }
    }

    /// Draws the product into the keyframe and returns the keyframe with the drawn piece pasted in, at the keyframe's
    /// size. `maskPNG` comes from `furnitureCompositeMaskPNG`, and `itemSizeWords` reads like "55 cm wide, 45 cm tall,
    /// 55 cm deep". The Worker cuts nothing: a title or size words over 300 characters, or an image over 4,000,000
    /// characters of base64 (about 3 MB), gets a 400.
    func paintTheItemIntoTheKeyframe(
        keyframeJPEG: Data,
        keyframeWidth: Int,
        keyframeHeight: Int,
        productJPEG: Data,
        maskPNG: Data,
        itemTitle: String,
        itemSizeWords: String
    ) async throws -> CGImage {
        guard let keyframe = decodedImage(from: keyframeJPEG) else {
            throw RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the keyframe is not an image")
        }
        guard let mask = decodedImage(from: maskPNG) else {
            throw RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the mask is not an image")
        }
        let responseData = try await post([
            "keyframeJPEGBase64": keyframeJPEG.base64EncodedString(),
            "keyframeWidth": keyframeWidth,
            "keyframeHeight": keyframeHeight,
            "productJPEGBase64": productJPEG.base64EncodedString(),
            "maskPNGBase64": maskPNG.base64EncodedString(),
            "itemTitle": itemTitle,
            "itemSizeWords": itemSizeWords,
        ], to: compositeURL)

        guard let reply = try? JSONDecoder().decode(RoomFurnitureCompositeReply.self, from: responseData),
              let generatedJPEG = Data(base64Encoded: reply.imageJPEGBase64),
              let generated = decodedImage(from: generatedJPEG) else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply holds no image")
        }
        guard generated.width == reply.width, generated.height == reply.height else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(
                reason: "the image is \(generated.width)x\(generated.height), and the reply says \(reply.width)x\(reply.height)"
            )
        }
        // The paste walks every pixel of the frame, so it runs off the main actor, where the panel draws.
        let pasteContext = ciContext
        let pastedOrNil = await Task.detached(priority: .userInitiated) {
            furnitureCompositePasted(keyframe: keyframe, generated: generated, mask: mask, context: pasteContext)
        }.value
        guard let pasted = pastedOrNil else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the drawn piece could not be pasted into the keyframe")
        }
        return pasted
    }

    /// The product as a GLB, from the cache when this photo and title were made into a model before. A cache that cannot
    /// be read or written only costs a new model, so its errors never fail the call.
    func generateAModel(productJPEG: Data, itemTitle: String) async throws -> Data {
        let cacheFile = modelCacheFolder.appendingPathComponent(tryItModelCacheKey(productJPEG: productJPEG, itemTitle: itemTitle) + ".glb")
        if let cachedModel = try? Data(contentsOf: cacheFile), dataIsAGLB(cachedModel) {
            return cachedModel
        }

        let modelData = try await post([
            "productJPEGBase64": productJPEG.base64EncodedString(),
            "itemTitle": itemTitle,
        ], to: tryItModelURL)
        guard dataIsAGLB(modelData) else {
            throw RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply is not a GLB")
        }

        do {
            try FileManager.default.createDirectory(at: modelCacheFolder, withIntermediateDirectories: true)
            try modelData.write(to: cacheFile, options: .atomic)
        } catch {
            print("Try-it model: could not cache the model: \(error.localizedDescription)")
        }
        return modelData
    }
}
