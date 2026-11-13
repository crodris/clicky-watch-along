//
//  PageImageAnimation.swift
//  leanring-buddy
//
//  The frames of an animated page image (a GIF, an animated WebP, or an APNG), so an image
//  pop-out keeps playing the animation the learner was watching. ImageIO decodes them on device.
//

import AppKit
import ImageIO

struct PageImageAnimationFrame: Equatable {
    let jpegBase64: String
    let delaySeconds: Double
}

enum PageImageAnimation {
    /// Past this many frames the pop-out keeps its still frame, so a long animation cannot bloat the page.
    nonisolated static let largestFrameCount = 150
    /// The page names the URL, so a small file that claims a huge canvas is refused before any frame is decoded.
    nonisolated static let largestPixelCountPerFrame = 4096 * 4096
    nonisolated static let largestPixelCountForAllFrames = 300_000_000
    /// The download runs while Sonnet reads the frame, which takes about 4 seconds.
    private static let downloadTimeoutSeconds: TimeInterval = 4
    private static let largestDownloadByteCount = 8_000_000
    /// No cookies, credentials, or cache, since the URL comes from whatever page is open.
    private static let downloadSession = URLSession(configuration: .ephemeral)

    /// Nil for a still image, a failed or oversized download, or anything that is not an https URL.
    static func frames(
        atImageURL imageURL: URL,
        frameWidth: Int,
        frameHeight: Int,
        capturedFrameJPEGBase64: String
    ) async -> [PageImageAnimationFrame]? {
        guard imageURL.scheme == "https" else { return nil }
        var imageData = Data()
        do {
            let (imageBytes, response) = try await downloadSession.bytes(
                for: URLRequest(url: imageURL, timeoutInterval: downloadTimeoutSeconds),
                delegate: HTTPSOnlyRedirects()
            )
            guard response.expectedContentLength <= largestDownloadByteCount else { return nil }
            for try await byte in imageBytes {
                imageData.append(byte)
                guard imageData.count <= largestDownloadByteCount else { return nil }
            }
        } catch {
            print("Frame pop-out: could not download the page image to animate it: \(error.localizedDescription)")
            return nil
        }
        // Decoding and encoding every frame takes a moment, so it runs off the main actor.
        return await Task.detached(priority: .userInitiated) {
            frames(
                ofImageData: imageData,
                frameWidth: frameWidth,
                frameHeight: frameHeight,
                backgroundColor: cornerColor(ofJPEGBase64: capturedFrameJPEGBase64)
            )
        }.value
    }

    /// Each frame drawn at the captured frame's size over `backgroundColor`, since the page stretches
    /// the image to its element box and the screen capture is that box.
    /// Nil for a still image or one with more than `largestFrameCount` frames.
    nonisolated static func frames(
        ofImageData imageData: Data,
        frameWidth: Int,
        frameHeight: Int,
        backgroundColor: CGColor
    ) -> [PageImageAnimationFrame]? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1, frameCount <= largestFrameCount else { return nil }
        let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        guard let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth * pixelHeight <= largestPixelCountPerFrame,
              pixelWidth * pixelHeight * frameCount <= largestPixelCountForAllFrames else {
            return nil
        }
        var frames: [PageImageAnimationFrame] = []
        for frameIndex in 0..<frameCount {
            // Each decoded frame is freed before the next one, so memory holds one frame at a time.
            let frame: PageImageAnimationFrame? = autoreleasepool {
                // ImageIO hands back each frame already composited over the frames before it.
                guard let frameImage = CGImageSourceCreateImageAtIndex(imageSource, frameIndex, nil),
                      let jpegData = jpegData(of: frameImage, width: frameWidth, height: frameHeight, backgroundColor: backgroundColor) else {
                    return nil
                }
                return PageImageAnimationFrame(
                    jpegBase64: jpegData.base64EncodedString(),
                    delaySeconds: browserDelaySeconds(forUnclampedDelaySeconds: unclampedDelaySeconds(of: imageSource, at: frameIndex))
                )
            }
            guard let frame else { return nil }
            frames.append(frame)
        }
        return frames
    }

    /// Browsers play a frame delay of 10 ms or less as 100 ms, so the pop-out plays at the speed the page did.
    nonisolated static func browserDelaySeconds(forUnclampedDelaySeconds unclampedDelaySeconds: Double) -> Double {
        unclampedDelaySeconds <= 0.01 ? 0.1 : unclampedDelaySeconds
    }

    nonisolated private static func unclampedDelaySeconds(of imageSource: CGImageSource, at frameIndex: Int) -> Double {
        let frameProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, frameIndex, nil) as? [CFString: Any] ?? [:]
        let delayKeyForEachFormat: [(formatDictionaryKey: CFString, unclampedDelayKey: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime),
        ]
        for delayKeys in delayKeyForEachFormat {
            if let formatProperties = frameProperties[delayKeys.formatDictionaryKey] as? [CFString: Any],
               let unclampedDelay = formatProperties[delayKeys.unclampedDelayKey] as? Double {
                return unclampedDelay
            }
        }
        return 0
    }

    /// The top-left pixel of the screen capture. Where an animated image is transparent, the capture shows
    /// the page behind it, so frames are drawn over that color instead of a white or black box.
    nonisolated static func cornerColor(ofJPEGBase64 jpegBase64: String) -> CGColor {
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        guard let jpegData = Data(base64Encoded: jpegBase64),
              let imageSource = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let capturedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
              let cornerImage = capturedImage.cropping(to: CGRect(x: 0, y: 0, width: 1, height: 1)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return white
        }
        var cornerPixel = [UInt8](repeating: 0, count: 4)
        guard let pixelContext = CGContext(
            data: &cornerPixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return white
        }
        pixelContext.draw(cornerImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGColor(
            srgbRed: CGFloat(cornerPixel[0]) / 255,
            green: CGFloat(cornerPixel[1]) / 255,
            blue: CGFloat(cornerPixel[2]) / 255,
            alpha: 1
        )
    }

    nonisolated private static func jpegData(of frameImage: CGImage, width: Int, height: Int, backgroundColor: CGColor) -> Data? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let frameContext = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        let wholeFrame = CGRect(x: 0, y: 0, width: width, height: height)
        frameContext.setFillColor(backgroundColor)
        frameContext.fill(wholeFrame)
        frameContext.interpolationQuality = .high
        frameContext.draw(frameImage, in: wholeFrame)
        guard let drawnFrame = frameContext.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: drawnFrame).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

/// A redirect may only move to another https URL.
/// The completion-handler form is used because Swift 6.3 crashes emitting the async form's thunk under main-actor default isolation.
nonisolated private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
