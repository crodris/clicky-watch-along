//
//  RoomArtPictureSourceTests.swift
//  leanring-buddyTests
//
//  Where room art gets its picture, against a stubbed image host: the page's image file is used and scaled to a long side
//  of 1280 (a screen capture would hold a cookie banner over the product photo), and the screen capture is the fallback
//  for no URL, a URL that is not https or names this Mac or a private network, a redirect to http, a file over 8 MB, a side
//  over 4096 before decoding, a file under 160 pixels, a failed or stalled download, and bytes that are not a JPEG, PNG,
//  WebP, GIF, or HEIC image. A cancelled request captures nothing.
//

import AppKit
import Foundation
import os
import Testing
import UniformTypeIdentifiers
@testable import Clicky

/// Answers requests to `https://pictures.stub/<path>` with the reply a test set for that path, and records the scheme and
/// path of every request that started, so a test can say a redirect to http was never followed.
private final class StubbedPictureURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case image(Data)
        /// A valid image whose reply says it is `declaredByteCount` bytes long, or says nothing about its length for nil.
        case imageDeclaring(byteCount: Int?, Data)
        /// An error status whose body is still a valid image, so only the status can refuse it.
        case status(Int, body: Data)
        case redirect(toURL: String)
        /// A 200 reply that sends one byte and then nothing more, like a server that trickles or hangs.
        case stalls
    }

    static let replies = OSAllocatedUnfairLock<[String: Reply]>(initialState: [:])
    static let startedRequests = OSAllocatedUnfairLock<[String]>(initialState: [])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "pictures.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.startedRequests.withLock { startedRequests in startedRequests.append("\(url.scheme ?? "")://\(url.path)") }
        guard let reply = Self.replies.withLock({ replies in replies[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch reply {
        case .image(let imageData):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png", "Content-Length": String(imageData.count)]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: imageData)
            client?.urlProtocolDidFinishLoading(self)
        case .imageDeclaring(let declaredByteCount, let imageData):
            var headerFields = ["Content-Type": "image/png"]
            if let declaredByteCount { headerFields["Content-Length"] = String(declaredByteCount) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headerFields)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: imageData)
            client?.urlProtocolDidFinishLoading(self)
        case .status(let statusCode, let body):
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .stalls:
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([0x89]))
        case .redirect(let redirectedURL):
            let redirectResponse = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": redirectedURL]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: redirectedURL)!), redirectResponse: redirectResponse)
            // A session that refuses the redirect keeps the 302 as its reply and waits for the protocol to finish.
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

@MainActor
struct RoomArtPictureSourceTests {
    /// A session whose requests reach the stub, with the cookie and cache settings the real download session has.
    private func stubbedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedPictureURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// A URL on the stub host with its own path, so tests running side by side never share a reply.
    private func stubbedImageURL(answeringWith reply: StubbedPictureURLProtocol.Reply) -> URL {
        let path = "/\(UUID().uuidString).png"
        StubbedPictureURLProtocol.replies.withLock { replies in replies[path] = reply }
        return URL(string: "https://pictures.stub\(path)")!
    }

    /// A TIFF, a format ImageIO reads but room art does not.
    nonisolated private func tiffData(width: Int, height: Int) -> Data {
        NSBitmapImageRep(data: pngData(width: width, height: height))!.representation(using: .tiff, properties: [:])!
    }

    /// A PNG of one color, with an alpha channel, `alpha` 0 for a transparent one.
    nonisolated private func pngData(width: Int, height: Int, alpha: CGFloat = 1) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: 0.8 * alpha, green: 0.1 * alpha, blue: 0.1 * alpha, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    }

    private let screenCapture = RoomArtPicture(jpegData: Data("screen capture".utf8), width: 640, height: 360)

    /// The picture room art ends up with, and whether the screen was captured to get it.
    private func pictureAndWhetherTheScreenWasCaptured(imageFileURL: URL?) async -> (picture: RoomArtPicture?, screenWasCaptured: Bool) {
        var screenWasCaptured = false
        let picture = await RoomArtPictureSource.picture(imageFileURL: imageFileURL, session: stubbedSession()) {
            screenWasCaptured = true
            return screenCapture
        }
        return (picture, screenWasCaptured)
    }

    @Test func theImageFileIsScaledToALongSideOf1280AndTheScreenIsNeverCaptured() async throws {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(pngData(width: 2560, height: 1280)))
        )
        let picture = try #require(result.picture)
        #expect(picture != screenCapture)
        #expect(picture.width == 1280)
        #expect(picture.height == 640)
        #expect(result.screenWasCaptured == false)
        let decodedPicture = try #require(NSBitmapImageRep(data: picture.jpegData))
        #expect(decodedPicture.pixelsWide == 1280)
        #expect(decodedPicture.pixelsHigh == 640)
    }

    @Test func aSmallImageFileIsNotScaledUp() async throws {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(pngData(width: 300, height: 200)))
        )
        let picture = try #require(result.picture)
        #expect(picture.width == 300)
        #expect(picture.height == 200)
    }

    @Test func aTransparentImageFileIsDrawnOverWhiteNotBlack() async throws {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(pngData(width: 200, height: 200, alpha: 0)))
        )
        let picture = try #require(result.picture)
        let decodedPicture = try #require(NSBitmapImageRep(data: picture.jpegData))
        let centerColor = try #require(decodedPicture.colorAt(x: 100, y: 100)?.usingColorSpace(.sRGB))
        #expect(centerColor.redComponent > 0.95 && centerColor.greenComponent > 0.95 && centerColor.blueComponent > 0.95)
    }

    @Test func aPageWithNoImageFileURLUsesTheScreenCapture() async {
        let result = await pictureAndWhetherTheScreenWasCaptured(imageFileURL: nil)
        #expect(result.picture == screenCapture)
        #expect(result.screenWasCaptured)
    }

    @Test func anHTTPImageFileIsNeverRequestedAndTheScreenIsCaptured() async {
        let path = "/\(UUID().uuidString).png"
        StubbedPictureURLProtocol.replies.withLock { replies in replies[path] = .image(pngData(width: 100, height: 100)) }
        let result = await pictureAndWhetherTheScreenWasCaptured(imageFileURL: URL(string: "http://pictures.stub\(path)")!)
        #expect(result.picture == screenCapture)
        #expect(!StubbedPictureURLProtocol.startedRequests.withLock { $0.contains("http://\(path)") })
    }

    @Test func aRedirectToHTTPIsRefusedAndTheScreenIsCaptured() async {
        let httpPath = "/\(UUID().uuidString)-insecure.png"
        StubbedPictureURLProtocol.replies.withLock { replies in replies[httpPath] = .image(pngData(width: 100, height: 100)) }
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .redirect(toURL: "http://pictures.stub\(httpPath)"))
        )
        #expect(result.picture == screenCapture)
        #expect(!StubbedPictureURLProtocol.startedRequests.withLock { $0.contains("http://\(httpPath)") })
    }

    @Test func aFileOver8MegabytesIsRefusedAndTheScreenIsCaptured() async {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(Data(count: PageImageAnimation.largestDownloadByteCount + 1)))
        )
        #expect(result.picture == screenCapture)
    }

    @Test func aFileThatDeclaresOver8MegabytesIsRefusedBeforeItIsRead() async {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .imageDeclaring(
                byteCount: PageImageAnimation.largestDownloadByteCount + 1,
                pngData(width: 100, height: 100)
            ))
        )
        #expect(result.picture == screenCapture)
    }

    @Test func aFileThatDeclaresNoLengthIsStillStoppedAt8Megabytes() async {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .imageDeclaring(
                byteCount: nil,
                // ImageIO ignores bytes after the image's end, so only the size cap can refuse this one.
                pngData(width: 100, height: 100) + Data(count: PageImageAnimation.largestDownloadByteCount)
            ))
        )
        #expect(result.picture == screenCapture)
    }

    @Test func aSideOver4096IsRefusedBeforeDecodingAndTheScreenIsCaptured() async {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(pngData(width: 4097, height: 8)))
        )
        #expect(result.picture == screenCapture)
    }

    @Test func aFailedReplyAndBytesThatAreNotAnImageUseTheScreenCapture() async {
        let failedReply = await pictureAndWhetherTheScreenWasCaptured(imageFileURL: stubbedImageURL(answeringWith: .status(404, body: pngData(width: 100, height: 100))))
        #expect(failedReply.picture == screenCapture)
        let notAnImage = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(Data("<html>sold out</html>".utf8)))
        )
        #expect(notAnImage.picture == screenCapture)
    }

    @Test func aFileOfAFormatRoomArtDoesNotReadIsRefusedAndTheScreenIsCaptured() async throws {
        let tiffFile = tiffData(width: 300, height: 200)
        #expect(RoomArtPictureSource.picture(ofImageData: tiffFile) == nil)
        let result = await pictureAndWhetherTheScreenWasCaptured(imageFileURL: stubbedImageURL(answeringWith: .image(tiffFile)))
        #expect(result.picture == screenCapture)
        #expect(RoomArtPictureSource.picture(ofImageData: pngData(width: 300, height: 200)) != nil)
    }

    @Test func aPlaceholderUnder160PixelsIsRefusedAndTheScreenIsCaptured() async {
        let placeholder = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .image(pngData(width: 1, height: 1)))
        )
        #expect(placeholder.picture == screenCapture)
        #expect(RoomArtPictureSource.picture(ofImageData: pngData(width: 159, height: 100)) == nil)
        #expect(RoomArtPictureSource.picture(ofImageData: pngData(width: 160, height: 10)) != nil)
    }

    @Test func aDownloadThatStallsPastTheDeadlineFallsBackToTheScreenCapture() async {
        var screenWasCaptured = false
        let startedAt = ContinuousClock.now
        let picture = await RoomArtPictureSource.picture(
            imageFileURL: stubbedImageURL(answeringWith: .stalls),
            session: stubbedSession(),
            downloadDeadlineSeconds: 0.3
        ) {
            screenWasCaptured = true
            return screenCapture
        }
        // The request's own idle timeout is 5 seconds, so only the deadline can end this one in under 3.
        #expect(ContinuousClock.now - startedAt < .seconds(3))
        #expect(picture == screenCapture)
        #expect(screenWasCaptured)
    }

    @Test func aCancelledRequestCapturesNothingAndStopsTheDownload() async {
        let stalledImageURL = stubbedImageURL(answeringWith: .stalls)
        let session = stubbedSession()
        let screenCaptureCount = OSAllocatedUnfairLock(initialState: 0)
        let roomArtRequest = Task {
            await RoomArtPictureSource.picture(imageFileURL: stalledImageURL, session: session, downloadDeadlineSeconds: 60) {
                screenCaptureCount.withLock { $0 += 1 }
                return RoomArtPicture(jpegData: Data("screen capture".utf8), width: 640, height: 360)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        roomArtRequest.cancel()
        // The 60 second deadline never passes, so the request can only end because the cancel stopped the download.
        #expect(await roomArtRequest.value == nil)
        #expect(screenCaptureCount.withLock { $0 } == 0)
    }

    @Test func aHostOnThisMacOrAPrivateNetworkIsNeverDownloadedFrom() {
        let refusedHosts = [
            "localhost", "app.localhost", "printer.local", "wiki.internal", "router.lan", "nas.home.arpa", "intranet",
            "127.0.0.1", "127.1", "2130706433", "0x7f.0.0.1", "0.0.0.0", "10.0.0.5", "172.16.0.1", "172.31.255.255",
            "192.168.1.1", "169.254.169.254", "100.64.0.1", "198.18.0.1", "224.0.0.1", "255.255.255.255",
            "::1", "::", "fe80::1", "fd00::1", "fc00::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
        ]
        for refusedHost in refusedHosts {
            #expect(PageImageAnimation.hostIsLocalOrPrivate(refusedHost), "\(refusedHost) should be refused")
        }
        let allowedHosts = [
            "example.com", "cdn.shop.example", "pictures.stub", "a.localhostx.com", "93.184.216.34", "172.15.0.1", "172.32.0.1",
            "100.63.0.1", "198.20.0.1", "2606:4700::1111", "::ffff:8.8.8.8",
        ]
        for allowedHost in allowedHosts {
            #expect(!PageImageAnimation.hostIsLocalOrPrivate(allowedHost), "\(allowedHost) should be allowed")
        }
        #expect(!PageImageAnimation.mayDownload(URL(string: "https://127.0.0.1/a.png")))
        #expect(!PageImageAnimation.mayDownload(URL(string: "https://[::1]:8443/a.png")))
        #expect(!PageImageAnimation.mayDownload(URL(string: "https://localhost:3000/a.png")))
        #expect(PageImageAnimation.mayDownload(URL(string: "https://example.com:8443/a.png")))
    }

    @Test func theAnimationPathReadsOnlyTheFormatsAnAnimatedImageComesIn() throws {
        func multiFrameFile(typeIdentifier: String) throws -> Data {
            let frameImage = try #require(NSBitmapImageRep(data: pngData(width: 16, height: 16))?.cgImage)
            let fileData = NSMutableData()
            let destination = try #require(CGImageDestinationCreateWithData(fileData, typeIdentifier as CFString, 2, nil))
            CGImageDestinationAddImage(destination, frameImage, nil)
            CGImageDestinationAddImage(destination, frameImage, nil)
            #expect(CGImageDestinationFinalize(destination))
            return fileData as Data
        }
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        // A two-page GIF is read, and a two-page TIFF holds the same frames but is not a format an animated image comes in.
        #expect(PageImageAnimation.frames(ofImageData: try multiFrameFile(typeIdentifier: UTType.gif.identifier), frameWidth: 8, frameHeight: 6, backgroundColor: white)?.count == 2)
        #expect(PageImageAnimation.frames(ofImageData: try multiFrameFile(typeIdentifier: UTType.tiff.identifier), frameWidth: 8, frameHeight: 6, backgroundColor: white) == nil)
    }

    @Test func aRedirectToAPrivateHostIsRefusedAndTheScreenIsCaptured() async {
        let result = await pictureAndWhetherTheScreenWasCaptured(
            imageFileURL: stubbedImageURL(answeringWith: .redirect(toURL: "https://192.168.1.1/a.png"))
        )
        #expect(result.picture == screenCapture)
    }

    @Test func theLargestPictureReportsItsFileEvenWhenItIsNotStretchedToItsBox() throws {
        let pageReply = """
        {"screenX":0,"screenY":0,"outerWidth":1200,"outerHeight":800,"innerWidth":1200,"innerHeight":700,"devicePixelRatio":2,\
        "left":10,"top":20,"width":400,"height":300,"imageSourceURL":null,"imageFileURL":"https://shop.example/print.jpg"}
        """
        let pageGeometry = try JSONDecoder().decode(ChromePageGeometry.self, from: Data(pageReply.utf8))
        let largestMedia = LargestVisibleMediaInFrontTab(
            screenRect: ScreenRectInChromeCoordinates(rectX: 0, rectY: 0, rectWidth: 400, rectHeight: 300),
            pageGeometry: pageGeometry,
            imageSourceURL: nil
        )
        #expect(largestMedia.imageFileURL == URL(string: "https://shop.example/print.jpg"))
        #expect(ChromeVideoTab.largestVisibleMediaJavaScript.contains("imageFileURL: imageFileURL"))
        // A page script from before this field still decodes, with no file.
        let olderReply = pageReply.replacingOccurrences(of: ",\"imageFileURL\":\"https://shop.example/print.jpg\"", with: "")
        #expect(try JSONDecoder().decode(ChromePageGeometry.self, from: Data(olderReply.utf8)).imageFileURL == nil)
    }
}
