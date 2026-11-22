//
//  PageImageAnimation.swift
//  leanring-buddy
//
//  The frames of an animated page image (a GIF, an animated WebP, or an APNG), so an image
//  pop-out keeps playing the animation the learner was watching. ImageIO decodes them on device.
//

import AppKit
import Darwin
import ImageIO

struct PageImageAnimationFrame: Equatable {
    let jpegBase64: String
    let delaySeconds: Double
}

enum PageImageAnimation {
    /// Past this many frames the pop-out keeps its still frame, so a long animation cannot bloat the page.
    nonisolated static let largestFrameCount = 150
    /// The page names the URL, so a small file that claims a huge canvas is refused before any frame is decoded.
    nonisolated static let largestFrameSide = 4096
    nonisolated static let largestPixelCountForAllFrames = 300_000_000
    /// Every frame is drawn at the capture's size and decoded at once in the page, so this caps the page's memory.
    nonisolated static let largestOutputPixelCountForAllFrames = 60_000_000
    /// The download runs while Sonnet reads the frame, which takes about 4 seconds.
    nonisolated private static let downloadTimeoutSeconds: TimeInterval = 4
    nonisolated static let largestDownloadByteCount = 8_000_000
    /// No cookies, credentials, or cache, since the URL comes from whatever page is open.
    nonisolated static let downloadSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.urlCredentialStorage = nil
        return URLSession(configuration: sessionConfiguration)
    }()

    /// Nil for a still image, a failed, oversized, or cancelled download, or anything that is not an https URL.
    /// It runs off the main actor, since the download reads up to 8 MB one byte at a time.
    @concurrent nonisolated static func frames(
        atImageURL imageURL: URL,
        frameWidth: Int,
        frameHeight: Int,
        capturedFrameJPEGBase64: String
    ) async -> [PageImageAnimationFrame]? {
        guard let imageData = await downloadedImageData(atImageURL: imageURL, timeoutSeconds: downloadTimeoutSeconds) else {
            return nil
        }
        return frames(
            ofImageData: imageData,
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            backgroundColor: cornerColor(ofJPEGBase64: capturedFrameJPEGBase64)
        )
    }

    /// The bytes of the file at an https URL, the one download every page image use shares (the animation's frames and
    /// room art's picture). Https only for the first request and every redirect, no cookies or credentials (the session),
    /// at most `largestDownloadByteCount` bytes, and a 200 reply, since a refused redirect leaves the 3xx reply behind.
    /// Nil for anything else. The session is a parameter so a test can stub the network.
    @concurrent nonisolated static func downloadedImageData(
        atImageURL imageURL: URL,
        timeoutSeconds: TimeInterval,
        session: URLSession = downloadSession
    ) async -> Data? {
        guard mayDownload(imageURL) else { return nil }
        var imageData = Data()
        do {
            let (imageBytes, response) = try await session.bytes(
                for: URLRequest(url: imageURL, timeoutInterval: timeoutSeconds),
                delegate: HTTPSOnlyRedirects()
            )
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.expectedContentLength <= largestDownloadByteCount else { return nil }
            for try await byte in imageBytes {
                imageData.append(byte)
                guard imageData.count <= largestDownloadByteCount else { return nil }
            }
        } catch {
            print("Page image: could not download \(imageURL.host ?? "the page image"): \(error.localizedDescription)")
            return nil
        }
        return imageData
    }

    /// The page names the URL, so only https is fetched, for the first request and for every redirect, and never from
    /// this Mac or its network (`hostIsLocalOrPrivate`), since any open page could otherwise send a blind GET to a service
    /// on localhost or the LAN. A public name that resolves to a private address is not caught here.
    nonisolated static func mayDownload(_ imageURL: URL?) -> Bool {
        guard let imageURL, imageURL.scheme == "https", let host = imageURL.host, !hostIsLocalOrPrivate(host) else { return false }
        return true
    }

    /// True for a name or address that points at this Mac or a private network: `localhost` and its subdomains, `.local`
    /// and `.internal` names, a name with no dot, and an IP address (in any form `inet_aton` reads, such as `127.1`) that
    /// is unspecified, loopback, private, link-local, shared (100.64.0.0/10), benchmarking, multicast, or reserved, for IPv4
    /// and IPv6 (including an IPv4 address mapped into IPv6).
    nonisolated static func hostIsLocalOrPrivate(_ host: String) -> Bool {
        let lowercaseHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if lowercaseHost.isEmpty { return true }
        var ipv4Address = in_addr()
        if inet_aton(lowercaseHost, &ipv4Address) != 0 {
            return ipv4AddressIsLocalOrPrivate(UInt32(bigEndian: ipv4Address.s_addr))
        }
        let hostWithoutIPv6Zone = lowercaseHost.split(separator: "%", maxSplits: 1).first.map(String.init) ?? lowercaseHost
        var ipv6Address = in6_addr()
        if inet_pton(AF_INET6, hostWithoutIPv6Zone, &ipv6Address) == 1 {
            let ipv6Bytes = withUnsafeBytes(of: ipv6Address) { Array($0) }
            return ipv6AddressIsLocalOrPrivate(ipv6Bytes)
        }
        if !lowercaseHost.contains(".") { return true }
        return lowercaseHost.hasSuffix(".localhost") || lowercaseHost.hasSuffix(".local") || lowercaseHost.hasSuffix(".internal")
    }

    nonisolated private static func ipv4AddressIsLocalOrPrivate(_ address: UInt32) -> Bool {
        let firstByte = address >> 24
        let secondByte = (address >> 16) & 0xFF
        switch (firstByte, secondByte) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (100, 64...127): return true
        case (172, 16...31): return true
        case (198, 18...19): return true
        case (192, 0) where (address >> 8) & 0xFF == 0: return true
        default: return firstByte >= 224
        }
    }

    nonisolated private static func ipv6AddressIsLocalOrPrivate(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        let isUnspecifiedOrLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] <= 1
        let isMappedIPv4 = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        if isMappedIPv4 {
            let mappedAddress = bytes[12..<16].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return ipv4AddressIsLocalOrPrivate(mappedAddress)
        }
        let isLinkLocalOrSiteLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 || bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0
        let isUniqueLocal = (bytes[0] & 0xFE) == 0xFC
        let isMulticast = bytes[0] == 0xFF
        return isUnspecifiedOrLoopback || isLinkLocalOrSiteLocal || isUniqueLocal || isMulticast
    }

    /// Each frame drawn at the captured frame's size over `backgroundColor`, since the page stretches
    /// the image to its element box and the screen capture is that box.
    /// Nil for a still image, one with more than `largestFrameCount` frames, one whose frames at the capture's size
    /// pass `largestOutputPixelCountForAllFrames`, or a cancelled task.
    nonisolated static func frames(
        ofImageData imageData: Data,
        frameWidth: Int,
        frameHeight: Int,
        backgroundColor: CGColor
    ) -> [PageImageAnimationFrame]? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }
        let frameCount = CGImageSourceGetCount(imageSource)
        guard frameCount > 1, frameCount <= largestFrameCount,
              frameCount * frameWidth * frameHeight <= largestOutputPixelCountForAllFrames else {
            return nil
        }
        let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        guard let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int,
              pixelWidth <= largestFrameSide, pixelHeight <= largestFrameSide,
              pixelWidth * pixelHeight * frameCount <= largestPixelCountForAllFrames else {
            return nil
        }
        var frames: [PageImageAnimationFrame] = []
        for frameIndex in 0..<frameCount {
            // A pop-out that no longer waits for the frames stops the work here.
            if Task.isCancelled { return nil }
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
nonisolated final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(PageImageAnimation.mayDownload(request.url) ? request : nil)
    }
}
