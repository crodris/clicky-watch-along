//
//  RoomFurnitureGenerationTests.swift
//  leanring-buddyTests
//
//  The furniture generation client against a stubbed Worker: the composite request and its paste into the keyframe, the
//  3D model request and its disk cache, every status the Worker can answer, and the pure mask, hull, and paste rules.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import os
import Testing
import UniformTypeIdentifiers
@testable import Clicky

/// Answers the client's requests to `http://furniture.stub/<test id>/<route>` with the reply a test set for that path, and
/// records each request's body. Each test uses its own id, so tests running side by side never share a path.
private final class StubbedFurnitureWorkerURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        let statusCode: Int
        let body: Data
    }

    static let replies = OSAllocatedUnfairLock<[String: Reply]>(initialState: [:])
    static let requestBodies = OSAllocatedUnfairLock<[String: [Data]]>(initialState: [:])

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "furniture.stub" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession moves a request's body into a stream before a protocol sees it.
    private func bodyOfTheRequest() -> Data {
        if let httpBody = request.httpBody { return httpBody }
        guard let bodyStream = request.httpBodyStream else { return Data() }
        bodyStream.open()
        defer { bodyStream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while bodyStream.hasBytesAvailable {
            let readCount = bodyStream.read(&buffer, maxLength: buffer.count)
            guard readCount > 0 else { break }
            body.append(buffer, count: readCount)
        }
        return body
    }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies.withLock({ replies in replies[url.path] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = bodyOfTheRequest()
        Self.requestBodies.withLock { requestBodies in requestBodies[url.path, default: []].append(body) }
        let response = HTTPURLResponse(url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Image helpers

private func solidImage(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func encoded(_ image: CGImage, as type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// A gray mask, white inside `whiteRectangle` (pixels, y growing down) and black elsewhere, as a PNG.
private func rectangleMaskPNG(width: Int, height: Int, whiteRectangle: CGRect) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    context.setFillColor(gray: 0, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(CGRect(x: whiteRectangle.minX, y: CGFloat(height) - whiteRectangle.maxY, width: whiteRectangle.width, height: whiteRectangle.height))
    return encoded(context.makeImage()!, as: .png)
}

/// Each pixel's sRGB bytes, read with y growing down.
private struct PixelReader {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var pixelBytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixelBytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = pixelBytes
    }

    func rgb(x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        // A bitmap context's first row is the image's top row.
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    func isMostlyRed(x: Int, y: Int) -> Bool {
        let pixel = rgb(x: x, y: y)
        return pixel.red > 200 && pixel.blue < 60
    }

    func isMostlyBlue(x: Int, y: Int) -> Bool {
        let pixel = rgb(x: x, y: y)
        return pixel.blue > 200 && pixel.red < 60
    }
}

/// The gray value of each mask pixel, y growing down.
private func grayValue(ofMaskPNG maskPNG: Data, x: Int, y: Int) -> Int {
    let reader = PixelReader(decodedImage(from: maskPNG)!)
    return reader.rgb(x: x, y: y).red
}

private let glbBytes = Data("glTF".utf8) + Data([2, 0, 0, 0, 12, 0, 0, 0])

// MARK: - The mask, the hull, and the paste

struct RoomFurnitureMaskTests {
    @Test func theHullDropsInteriorAndCollinearPoints() {
        let hull = convexHull(of: [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
            CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 0),
        ])

        #expect(Set(hull.map { point in "\(Int(point.x)),\(Int(point.y))" }) == ["0,0", "10,0", "10,10", "0,10"])
    }

    @Test func theMaskIsAnEightBitGrayPNGOfTheFrame() throws {
        let maskPNG = try #require(furnitureCompositeMaskPNG(
            projectedCorners: [CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 120), CGPoint(x: 100, y: 120)],
            frameWidth: 320, frameHeight: 180, shadowMarginPixels: 10
        ))

        // The PNG header's bit depth and color type: 8 and 0, gray, which the Worker reads.
        #expect(Array(maskPNG.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(maskPNG[24] == 8)
        #expect(maskPNG[25] == 0)
        let maskImage = try #require(decodedImage(from: maskPNG))
        #expect(maskImage.width == 320)
        #expect(maskImage.height == 180)
    }

    @Test func theMaskIsWhiteInsideTheHullGrownByTheMarginAndBlackElsewhere() throws {
        // A triangle, so a mask drawn upside down (y not flipped) would fail the point below its top edge.
        let maskPNG = try #require(furnitureCompositeMaskPNG(
            projectedCorners: [CGPoint(x: 100, y: 40), CGPoint(x: 200, y: 140), CGPoint(x: 100, y: 140)],
            frameWidth: 320, frameHeight: 180, shadowMarginPixels: 12
        ))

        #expect(grayValue(ofMaskPNG: maskPNG, x: 120, y: 120) == 255)
        // 8 pixels left of the hull's left edge is inside the margin, and 20 pixels is past it.
        #expect(grayValue(ofMaskPNG: maskPNG, x: 92, y: 100) == 255)
        #expect(grayValue(ofMaskPNG: maskPNG, x: 80, y: 100) == 0)
        // Below the bottom edge, inside and past the margin.
        #expect(grayValue(ofMaskPNG: maskPNG, x: 150, y: 148) == 255)
        #expect(grayValue(ofMaskPNG: maskPNG, x: 150, y: 160) == 0)
        // Up and right of the hypotenuse, past the margin: the corner of the triangle's box that the hull leaves out.
        #expect(grayValue(ofMaskPNG: maskPNG, x: 190, y: 50) == 0)
        #expect(grayValue(ofMaskPNG: maskPNG, x: 10, y: 10) == 0)
    }

    @Test func theMarginIsRoundAtTheHullsCorners() throws {
        let maskPNG = try #require(furnitureCompositeMaskPNG(
            projectedCorners: [CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 120), CGPoint(x: 100, y: 120)],
            frameWidth: 320, frameHeight: 180, shadowMarginPixels: 12
        ))

        // 10 pixels right and 10 below the bottom right corner is 14 pixels from it, past a 12 pixel margin. A square
        // corner would reach it, which would make the mask bigger than the item's room for a shadow.
        #expect(grayValue(ofMaskPNG: maskPNG, x: 210, y: 130) == 0)
        #expect(grayValue(ofMaskPNG: maskPNG, x: 206, y: 126) == 255)
    }

    @Test func aMaskWithNoMarginIsTheHullAlone() throws {
        let maskPNG = try #require(furnitureCompositeMaskPNG(
            projectedCorners: [CGPoint(x: 100, y: 50), CGPoint(x: 200, y: 50), CGPoint(x: 200, y: 120), CGPoint(x: 100, y: 120)],
            frameWidth: 320, frameHeight: 180, shadowMarginPixels: 0
        ))

        #expect(grayValue(ofMaskPNG: maskPNG, x: 150, y: 80) == 255)
        #expect(grayValue(ofMaskPNG: maskPNG, x: 95, y: 80) == 0)
    }

    @Test(arguments: [
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5)], 320, 180, 10.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 5), CGPoint(x: 9, y: 9)], 320, 180, 10.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: CGFloat.nan, y: 5), CGPoint(x: 9, y: 1)], 320, 180, 10.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: CGFloat.infinity, y: 5), CGPoint(x: 9, y: 1)], 320, 180, 10.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9), CGPoint(x: 9, y: 1)], 0, 180, 10.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9), CGPoint(x: 9, y: 1)], 320, -1, 10.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9), CGPoint(x: 9, y: 1)], 320, 180, -1.0),
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9), CGPoint(x: 9, y: 1)], 320, 180, Double.nan),
        ([CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 9), CGPoint(x: 9, y: 1)], 320, 180, Double.infinity),
    ])
    func noMaskForCornersOrSizesThatSpanNothing(corners: [CGPoint], frameWidth: Int, frameHeight: Int, shadowMarginPixels: Double) {
        #expect(furnitureCompositeMaskPNG(projectedCorners: corners, frameWidth: frameWidth, frameHeight: frameHeight, shadowMarginPixels: shadowMarginPixels) == nil)
    }

    @Test func thePasteTakesTheReplyInsideTheGrownMaskAndKeepsTheKeyframeElsewhere() throws {
        let keyframe = solidImage(width: 200, height: 100, red: 1, green: 0, blue: 0)
        let generated = solidImage(width: 200, height: 100, red: 0, green: 0, blue: 1)
        let mask = try #require(decodedImage(from: rectangleMaskPNG(width: 200, height: 100, whiteRectangle: CGRect(x: 80, y: 40, width: 40, height: 20))))

        let pasted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: generated, mask: mask, slackPixels: 10, featherPixels: 2, context: CIContext()))
        let reader = PixelReader(pasted)

        #expect(pasted.width == 200)
        #expect(pasted.height == 100)
        #expect(reader.isMostlyBlue(x: 100, y: 50))
        // 6 pixels left of the mask is inside the 10 pixel slack, so a leg drawn just past the mask is kept.
        #expect(reader.isMostlyBlue(x: 74, y: 50))
        // Past the slack and the feather, the keyframe stays exactly as filmed.
        #expect(reader.rgb(x: 60, y: 50) == (255, 0, 0))
        #expect(reader.rgb(x: 100, y: 10) == (255, 0, 0))
        #expect(reader.rgb(x: 0, y: 0) == (255, 0, 0))
    }

    @Test func thePasteScalesAReplyOfAnotherSizeToTheKeyframe() throws {
        let keyframe = solidImage(width: 200, height: 100, red: 1, green: 0, blue: 0)
        let generated = solidImage(width: 160, height: 80, red: 0, green: 0, blue: 1)
        let mask = try #require(decodedImage(from: rectangleMaskPNG(width: 200, height: 100, whiteRectangle: CGRect(x: 150, y: 60, width: 40, height: 30))))

        let pasted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: generated, mask: mask, slackPixels: 4, featherPixels: 2, context: CIContext()))
        let reader = PixelReader(pasted)

        // Unscaled, the 160 by 80 reply would end left of and above the mask, and the keyframe's red would show here.
        #expect(reader.isMostlyBlue(x: 180, y: 85))
        #expect(reader.rgb(x: 20, y: 20) == (255, 0, 0))
    }

    /// RGBA bytes whose red, green, and blue run through every value, so a fit has spread to work with.
    private func gradientPixels(count: Int, transform: (Double) -> Double = { value in value }) -> [UInt8] {
        (0..<count).flatMap { pixelIndex -> [UInt8] in
            let value = Double(40 + pixelIndex % 160)
            let changed = UInt8(min(255, max(0, transform(value).rounded())))
            return [changed, changed, changed, 255]
        }
    }

    @Test func theToneFitUndoesAReplyThatCameBackBrighterAndFlatter() {
        let keyframePixels = gradientPixels(count: 2_000)
        let replyPixels = gradientPixels(count: 2_000) { value in value * 0.8 + 20 }

        let fits = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: replyPixels, sampleIsInTheRing: Array(repeating: true, count: 2_000))

        for fit in fits {
            #expect(abs(fit.gain - 1.25) < 0.01)
            #expect(abs(fit.offset + 25) < 1)
        }
    }

    @Test func theToneFitOnlyReadsTheRingsPixels() {
        let keyframePixels = gradientPixels(count: 2_000)
        // Outside the ring the reply is unrelated, as the piece is, and the fit must not read it.
        var replyPixels = gradientPixels(count: 2_000) { value in value + 10 }
        for pixelIndex in 1_000..<2_000 { replyPixels[pixelIndex * 4] = 255 }
        let sampleIsInTheRing = (0..<2_000).map { pixelIndex in pixelIndex < 1_000 }

        let fits = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: replyPixels, sampleIsInTheRing: sampleIsInTheRing)

        #expect(abs(fits[0].gain - 1) < 0.01)
        #expect(abs(fits[0].offset + 10) < 1)
    }

    @Test func theToneFitLeavesTheReplyAsItCameWhenTheRingCannotBeTrusted() {
        let keyframePixels = gradientPixels(count: 2_000)
        let everyPixel = Array(repeating: true, count: 2_000)

        // A gain past the range: the ring held something other than the same room.
        let tooDifferent = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: gradientPixels(count: 2_000) { value in value * 0.5 + 60 }, sampleIsInTheRing: everyPixel)
        // A gain past the range with no offset.
        let gainTooHigh = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: gradientPixels(count: 2_000) { value in value / 1.6 }, sampleIsInTheRing: everyPixel)
        // An offset past the limit with a gain of 1.
        let shiftedTooFar = toneFitsMatchingTheReplyToTheKeyframe(keyframePixels: keyframePixels, replyPixels: gradientPixels(count: 2_000) { value in value + 60 }, sampleIsInTheRing: everyPixel)
        // Too few ring pixels to trust.
        let tooFewSamples = toneFitsMatchingTheReplyToTheKeyframe(
            keyframePixels: keyframePixels,
            replyPixels: gradientPixels(count: 2_000) { value in value + 10 },
            sampleIsInTheRing: (0..<2_000).map { pixelIndex in pixelIndex < toneFitFewestSamples - 1 }
        )
        // A flat ring, which has no spread to fit a gain to.
        let flatRing = toneFitsMatchingTheReplyToTheKeyframe(
            keyframePixels: Array(repeating: 90, count: 8_000),
            replyPixels: Array(repeating: 100, count: 8_000),
            sampleIsInTheRing: everyPixel
        )

        for fits in [tooDifferent, gainTooHigh, shiftedTooFar, tooFewSamples, flatRing] {
            #expect(fits == Array(repeating: ChannelToneFit.unchanged, count: 3))
        }
    }

    @Test func thePasteMatchesTheRepliesToneToTheKeyframeSoNoPatchShows() throws {
        // A keyframe with a horizontal gradient, and a reply 15 levels brighter everywhere, as the edit returns it, with a
        // white piece inside the mask, which the fit must not read.
        func gradientImage(brightening: Int, whitePiece: CGRect? = nil) -> CGImage {
            var pixelBytes = [UInt8](repeating: 255, count: 320 * 180 * 4)
            for row in 0..<180 {
                for column in 0..<320 {
                    let isInThePiece = whitePiece?.contains(CGPoint(x: column, y: row)) ?? false
                    let value = isInThePiece ? 255 : UInt8(min(255, 40 + column / 2 + brightening))
                    pixelBytes.replaceSubrange(((row * 320 + column) * 4)..<((row * 320 + column) * 4 + 3), with: [value, value, value])
                }
            }
            let context = CGContext(
                data: &pixelBytes, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 320 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
        let keyframe = gradientImage(brightening: 0)
        let reply = gradientImage(brightening: 15, whitePiece: CGRect(x: 140, y: 70, width: 40, height: 40))
        let mask = try #require(decodedImage(from: rectangleMaskPNG(width: 320, height: 180, whiteRectangle: CGRect(x: 140, y: 70, width: 40, height: 40))))

        let pasted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: reply, mask: mask, slackPixels: 8, featherPixels: 2, toneMatchBandPixels: 20, context: CIContext()))
        let pastedReader = PixelReader(pasted)
        let keyframeReader = PixelReader(keyframe)

        // The piece gets the same correction as the room, 15 levels darker, and in the slack around it the room in the
        // reply is brought back to the keyframe's tone, within two levels.
        #expect(pastedReader.rgb(x: 160, y: 90) == (240, 240, 240))
        for (x, y) in [(135, 90), (160, 65), (184, 100)] {
            #expect(abs(pastedReader.rgb(x: x, y: y).red - keyframeReader.rgb(x: x, y: y).red) <= 2)
        }
    }

    /// The paste tests for a room the edit repainted: a 400 by 300 gray room, and a reply that is the same room with a
    /// left-to-right brightness ramp (100 at the left edge, 140 at the right), as when the edit lights one side of the wall.
    /// `pieceRectangle` is painted dark (60) in the reply over the room, and `paleHoleRectangle` inside it is painted 8
    /// levels above the room, a part of the piece that nearly matches the wall.
    private func repaintedRoomPaste(pieceRectangle: CGRect, paleHoleRectangle: CGRect? = nil) throws -> (pasted: PixelReader, reply: PixelReader, keyframe: PixelReader) {
        let width = 400, height = 300
        let roomLevel: UInt8 = 120
        func image(levelAt: (Int, Int) -> UInt8) -> CGImage {
            var pixelBytes = [UInt8](repeating: 255, count: width * height * 4)
            for row in 0..<height {
                for column in 0..<width {
                    let level = levelAt(column, row)
                    pixelBytes.replaceSubrange(((row * width + column) * 4)..<((row * width + column) * 4 + 3), with: [level, level, level])
                }
            }
            let context = CGContext(
                data: &pixelBytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            return context.makeImage()!
        }
        let keyframe = image { _, _ in roomLevel }
        let reply = image { column, row in
            let point = CGPoint(x: column, y: row)
            if paleHoleRectangle?.contains(point) ?? false { return roomLevel + 8 }
            if pieceRectangle.contains(point) { return 60 }
            return UInt8(100 + 40 * column / width)
        }
        let mask = try #require(decodedImage(from: rectangleMaskPNG(width: width, height: height, whiteRectangle: pieceRectangle)))
        let pasted = try #require(furnitureCompositePasted(keyframe: keyframe, generated: reply, mask: mask, context: CIContext()))
        return (PixelReader(pasted), PixelReader(reply), PixelReader(keyframe))
    }

    @Test func aRepaintedRoomBesideThePieceKeepsTheKeyframeSoNoStepShowsWhereThePastedRegionEnds() throws {
        let pieceRectangle = CGRect(x: 150, y: 110, width: 100, height: 80)
        let (pasted, reply, keyframe) = try repaintedRoomPaste(pieceRectangle: pieceRectangle)

        // Along a row through the piece, from the left edge of the pasted region (the mask grown by 24 pixels) outward,
        // the room is the keyframe's from 24 pixels beside the piece (the piece's margin fades out over that), so the
        // reply's ramp, up to 7 levels off here, leaves no step where the pasted region ends.
        for x in 100...126 {
            #expect(abs(pasted.rgb(x: x, y: 150).red - keyframe.rgb(x: x, y: 150).red) <= 1, "x \(x) beside the piece")
        }
        for x in 274...300 {
            #expect(abs(pasted.rgb(x: x, y: 150).red - keyframe.rgb(x: x, y: 150).red) <= 1, "x \(x) beside the piece")
        }
        // And the reply's own ramp really differed there, so the check can fail.
        #expect(abs(reply.rgb(x: 130, y: 150).red - keyframe.rgb(x: 130, y: 150).red) >= 5)
    }

    @Test func aRepaintedRoomLeavesThePiecesOwnPixelsAndEdgeAsTheReplyDrewThem() throws {
        let pieceRectangle = CGRect(x: 150, y: 110, width: 100, height: 80)
        let (pasted, reply, _) = try repaintedRoomPaste(pieceRectangle: pieceRectangle)

        // Inside the piece and on its first and last pixels, the paste is the reply to within 6 levels, with no
        // halo of the keyframe (60 against the keyframe's 120 would show as a step of many levels).
        for (x, y) in [(200, 150), (150, 110), (249, 189), (150, 150), (249, 150), (200, 110), (200, 189)] {
            #expect(abs(pasted.rgb(x: x, y: y).red - reply.rgb(x: x, y: y).red) <= 6, "(\(x), \(y)) on the piece")
        }
    }

    @Test func aPartOfThePieceThatNearlyMatchesTheRoomIsStillThePiece() throws {
        let pieceRectangle = CGRect(x: 150, y: 110, width: 100, height: 80)
        let paleHoleRectangle = CGRect(x: 185, y: 135, width: 30, height: 30)
        let (pasted, reply, keyframe) = try repaintedRoomPaste(pieceRectangle: pieceRectangle, paleHoleRectangle: paleHoleRectangle)

        // The pale part differs from the keyframe by 8 levels, below the change threshold, but it sits inside the piece,
        // so it stays the reply's and the keyframe's wall does not show through the piece.
        #expect(pasted.rgb(x: 200, y: 150).red == reply.rgb(x: 200, y: 150).red)
        #expect(pasted.rgb(x: 200, y: 150).red != keyframe.rgb(x: 200, y: 150).red)
    }

    @Test func aWideGapTheChangedCellsEncloseIsStillThePiece() throws {
        // A 70 by 50 part of the piece that nearly matches the room, wider than the closing's 40 pixels, such as a pale seat
        // against a pale wall. The piece's dark frame around it encloses it, so the keyframe's wall must not show there.
        let pieceRectangle = CGRect(x: 110, y: 80, width: 180, height: 140)
        let paleHoleRectangle = CGRect(x: 165, y: 125, width: 70, height: 50)
        let (pasted, reply, keyframe) = try repaintedRoomPaste(pieceRectangle: pieceRectangle, paleHoleRectangle: paleHoleRectangle)

        for (x, y) in [(200, 150), (175, 135), (225, 165)] {
            #expect(pasted.rgb(x: x, y: y).red == reply.rgb(x: x, y: y).red, "(\(x), \(y)) in the gap")
            #expect(pasted.rgb(x: x, y: y).red != keyframe.rgb(x: x, y: y).red, "(\(x), \(y)) in the gap")
        }
    }

    @Test func aChangeOutsideThePasteNeverJoinsThePiece() {
        // A 120 by 80 frame where the reply differs from the keyframe by 100 levels in two 24 by 24 blocks: one inside the
        // paste (columns 20 to 43) and one far outside it (columns 90 to 113). Only the first is the piece.
        let width = 120, height = 80
        var keyframePixels = [UInt8](repeating: 255, count: width * height * 4)
        var replyPixels = keyframePixels
        var pasteWeights = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let pixelIndex = row * width + column
                if column < 64 { pasteWeights[pixelIndex] = 255 }
                for channel in 0..<3 {
                    keyframePixels[pixelIndex * 4 + channel] = 120
                    replyPixels[pixelIndex * 4 + channel] = 120
                }
                let isInABlock = (28..<52).contains(row) && ((20..<44).contains(column) || (90..<114).contains(column))
                if isInABlock { for channel in 0..<3 { replyPixels[pixelIndex * 4 + channel] = 20 } }
            }
        }
        let weights = furniturePieceWeights(keyframePixels: keyframePixels, correctedReplyPixels: replyPixels, pasteWeights: pasteWeights, width: width, height: height)

        #expect(weights[40 * width + 32] > 0.99, "the block inside the paste is the piece")
        #expect(weights[40 * width + 102] == 0, "the block outside the paste is not")
    }

    @Test func aCellThePasteOnlyGrazesNeverCountsAsChanged() {
        // The paste takes columns 0 to 64, so the cells of columns 64 to 67 hold 4 pasted pixels of 16. The reply differs by
        // 100 levels in column 64 and in a block well inside the paste, and only the block is the piece.
        let width = 120, height = 80
        var keyframePixels = [UInt8](repeating: 255, count: width * height * 4)
        var replyPixels = keyframePixels
        var pasteWeights = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width {
                let pixelIndex = row * width + column
                if column <= 64 { pasteWeights[pixelIndex] = 255 }
                for channel in 0..<3 {
                    keyframePixels[pixelIndex * 4 + channel] = 120
                    replyPixels[pixelIndex * 4 + channel] = 120
                }
                let isInTheBlock = (28..<52).contains(row) && (12..<36).contains(column)
                if isInTheBlock || column == 64 { for channel in 0..<3 { replyPixels[pixelIndex * 4 + channel] = 20 } }
            }
        }
        let weights = furniturePieceWeights(keyframePixels: keyframePixels, correctedReplyPixels: replyPixels, pasteWeights: pasteWeights, width: width, height: height)

        #expect(weights[40 * width + 24] > 0.99, "the block is the piece")
        #expect(weights[10 * width + 66] == 0, "a cell the paste only grazes is not")
    }

    @Test func theCacheKeyChangesWithThePagePictureOrTheTitleAndNeverJoinsThem() {
        let pagePicture = Data([1, 2, 3])

        #expect(tryItModelCacheKey(cacheKeyData: pagePicture, itemTitle: "Chair") == tryItModelCacheKey(cacheKeyData: pagePicture, itemTitle: "Chair"))
        #expect(tryItModelCacheKey(cacheKeyData: pagePicture, itemTitle: "Chair") != tryItModelCacheKey(cacheKeyData: pagePicture, itemTitle: "Sofa"))
        #expect(tryItModelCacheKey(cacheKeyData: pagePicture, itemTitle: "Chair") != tryItModelCacheKey(cacheKeyData: Data([1, 2, 4]), itemTitle: "Chair"))
        // Without the lengths, picture "AB" with title "C" and picture "A" with title "BC" would hash the same bytes.
        #expect(tryItModelCacheKey(cacheKeyData: Data("AB".utf8), itemTitle: "C") != tryItModelCacheKey(cacheKeyData: Data("A".utf8), itemTitle: "BC"))
        #expect(tryItModelCacheKey(cacheKeyData: pagePicture, itemTitle: "Chair").count == 64)
    }

    @Test func aTransparentCutoutComesOutWhiteWhereItWasTransparentAndKeepsItsPixelsElsewhere() throws {
        // A 40 by 30 cutout: an opaque red block in the middle, transparent everywhere else.
        let context = try #require(CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 10, y: 8, width: 20, height: 14))
        let cutout = try #require(context.makeImage())

        let jpegData = try #require(roomFurnitureCutoutJPEG(cutout))
        let decoded = try #require(decodedImage(from: jpegData))
        let reader = PixelReader(decoded)

        // A JPEG, at the cutout's size.
        #expect(jpegData.prefix(2) == Data([0xFF, 0xD8]))
        #expect(decoded.width == 40 && decoded.height == 30)
        let cornerPixel = reader.rgb(x: 1, y: 1)
        #expect(cornerPixel.red > 245 && cornerPixel.green > 245 && cornerPixel.blue > 245)
        #expect(reader.isMostlyRed(x: 20, y: 15))
    }

    @Test func aTitleIsCutToTheWorkersLimitInUTF16UnitsNeverInsideACharacter() {
        let shortTitle = "LACK Coffee table"
        #expect(roomFurnitureTitleForTheWorker(shortTitle) == shortTitle)
        #expect(roomFurnitureTitleForTheWorker(String(repeating: "a", count: 300)).utf16.count == 300)
        #expect(roomFurnitureTitleForTheWorker(String(repeating: "a", count: 301)).utf16.count == 300)
        // Each chair emoji is two UTF-16 units, so a cut at 300 units keeps 150 of them, and a 299 unit prefix plus one emoji
        // keeps the 299 units and drops the emoji whole.
        #expect(roomFurnitureTitleForTheWorker(String(repeating: "🪑", count: 200)).utf16.count == 300)
        let cutBeforeAnEmoji = roomFurnitureTitleForTheWorker(String(repeating: "a", count: 299) + "🪑")
        #expect(cutBeforeAnEmoji == String(repeating: "a", count: 299))
    }

    @Test func onlyDataThatStartsWithTheGLBMagicIsAModel() {
        #expect(dataIsAGLB(glbBytes))
        #expect(!dataIsAGLB(Data("glT".utf8)))
        #expect(!dataIsAGLB(Data(#"{"error":"x"}"#.utf8)))
    }
}

// MARK: - The client

@MainActor
struct RoomFurnitureGenerationClientTests {
    private let testID = UUID().uuidString
    private let modelCacheFolder = FileManager.default.temporaryDirectory.appendingPathComponent("TryItModelsTest-\(UUID().uuidString)", isDirectory: true)

    private func client() -> RoomFurnitureGenerationClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubbedFurnitureWorkerURLProtocol.self]
        return RoomFurnitureGenerationClient(
            workerBaseURL: "http://furniture.stub/\(testID)",
            sessionConfiguration: configuration,
            modelCacheFolder: modelCacheFolder
        )
    }

    private func answer(_ route: String, statusCode: Int, body: Data) {
        StubbedFurnitureWorkerURLProtocol.replies.withLock { replies in
            replies["/\(testID)/\(route)"] = .init(statusCode: statusCode, body: body)
        }
    }

    private func requestBodies(of route: String) -> [Data] {
        StubbedFurnitureWorkerURLProtocol.requestBodies.withLock { requestBodies in requestBodies["/\(testID)/\(route)"] ?? [] }
    }

    private let keyframeJPEG = encoded(solidImage(width: 200, height: 100, red: 1, green: 0, blue: 0), as: .jpeg)
    private let productJPEG = encoded(solidImage(width: 40, height: 40, red: 1, green: 1, blue: 1), as: .jpeg)
    /// The page picture a model is cached by, which is not the cutout the Worker is sent.
    private let pagePictureJPEG = encoded(solidImage(width: 50, height: 60, red: 0, green: 1, blue: 0), as: .jpeg)
    private let maskPNG = rectangleMaskPNG(width: 200, height: 100, whiteRectangle: CGRect(x: 80, y: 40, width: 40, height: 20))

    private func compositeReply(width: Int = 200, height: Int = 100, statedWidth: Int? = nil) -> Data {
        let generatedJPEG = encoded(solidImage(width: width, height: height, red: 0, green: 0, blue: 1), as: .jpeg)
        let reply: [String: Any] = ["imageJPEGBase64": generatedJPEG.base64EncodedString(), "width": statedWidth ?? width, "height": height]
        return try! JSONSerialization.data(withJSONObject: reply)
    }

    private func paint(using furnitureClient: RoomFurnitureGenerationClient, keyframeJPEG: Data? = nil) async throws -> CGImage {
        try await furnitureClient.paintTheItemIntoTheKeyframe(
            keyframeJPEG: keyframeJPEG ?? self.keyframeJPEG,
            keyframeWidth: 200,
            keyframeHeight: 100,
            productJPEG: productJPEG,
            maskPNG: maskPNG,
            itemTitle: "LACK Coffee table",
            itemSizeWords: "118 cm wide, 45 cm tall, 78 cm deep"
        ).image
    }

    @Test func theCompositeSendsEveryFieldAndPastesTheReplyIntoTheKeyframe() async throws {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())

        let pasted = try await paint(using: client())

        let sentBody = try #require(requestBodies(of: "room-furniture-composite").first)
        let sentJSON = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        #expect(sentJSON["keyframeJPEGBase64"] as? String == keyframeJPEG.base64EncodedString())
        #expect(sentJSON["keyframeWidth"] as? Int == 200)
        #expect(sentJSON["keyframeHeight"] as? Int == 100)
        #expect(sentJSON["productJPEGBase64"] as? String == productJPEG.base64EncodedString())
        #expect(sentJSON["maskPNGBase64"] as? String == maskPNG.base64EncodedString())
        #expect(sentJSON["itemTitle"] as? String == "LACK Coffee table")
        #expect(sentJSON["itemSizeWords"] as? String == "118 cm wide, 45 cm tall, 78 cm deep")

        let reader = PixelReader(pasted)
        #expect(pasted.width == 200)
        #expect(reader.isMostlyBlue(x: 100, y: 50))
        #expect(reader.isMostlyRed(x: 5, y: 5))
    }

    @Test func theCompositeSaysWhichWayThePieceFacesOnlyWhenTheGhostGaveIt() async throws {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())
        let furnitureClient = client()

        _ = try await furnitureClient.paintTheItemIntoTheKeyframe(
            keyframeJPEG: keyframeJPEG, keyframeWidth: 200, keyframeHeight: 100, productJPEG: productJPEG, maskPNG: maskPNG,
            itemTitle: "Dawson sofa", itemSizeWords: "90 inches wide and 32 tall",
            orientation: RoomFurniturePaintingOrientation(facing: .cameraSlightlyLeft, backAgainstTheWall: true)
        )
        _ = try await paint(using: furnitureClient)

        let sentBodies = requestBodies(of: "room-furniture-composite")
        let firstBody = try #require(sentBodies.first), lastBody = try #require(sentBodies.last)
        let withOrientation = try #require(JSONSerialization.jsonObject(with: firstBody) as? [String: Any])
        #expect(withOrientation["itemFacing"] as? String == "cameraSlightlyLeft")
        #expect(withOrientation["backAgainstTheWall"] as? Bool == true)
        let withoutOrientation = try #require(JSONSerialization.jsonObject(with: lastBody) as? [String: Any])
        #expect(withoutOrientation["itemFacing"] == nil && withoutOrientation["backAgainstTheWall"] == nil)
    }

    @Test func theCompositeSaysWhetherTheFramesBottomCutsOffThePiecesFeet() async throws {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())
        let furnitureClient = client()

        for itemContinuesPastTheFrameBottom in [true, false] {
            _ = try await furnitureClient.paintTheItemIntoTheKeyframe(
                keyframeJPEG: keyframeJPEG, keyframeWidth: 200, keyframeHeight: 100, productJPEG: productJPEG, maskPNG: maskPNG,
                itemTitle: "Dawson sofa", itemSizeWords: "90 inches wide and 32 tall",
                orientation: RoomFurniturePaintingOrientation(facing: .camera, backAgainstTheWall: true, itemContinuesPastTheFrameBottom: itemContinuesPastTheFrameBottom)
            )
        }

        let sentFlags = try requestBodies(of: "room-furniture-composite").map { sentBody in
            try #require((JSONSerialization.jsonObject(with: sentBody) as? [String: Any])?["itemContinuesPastTheFrameBottom"] as? Bool)
        }
        #expect(sentFlags == [true, false])
    }

    @Test func theCompositeSaysThePieceStandsOnATableOrShelfAndSaysNothingForTheFloor() async throws {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())
        let furnitureClient = client()

        for standsOn in [RoomArtStandsOn.tableOrShelf, .floor] {
            _ = try await furnitureClient.paintTheItemIntoTheKeyframe(
                keyframeJPEG: keyframeJPEG, keyframeWidth: 200, keyframeHeight: 100, productJPEG: productJPEG, maskPNG: maskPNG,
                itemTitle: "Stoneware mug", itemSizeWords: "4.5 inches wide and 4 tall",
                orientation: RoomFurniturePaintingOrientation(facing: .camera, backAgainstTheWall: false, standsOn: standsOn)
            )
        }
        // A painting with no orientation says nothing about it either, so an older Worker's request is unchanged.
        _ = try await paint(using: furnitureClient)

        let sentBodies = try requestBodies(of: "room-furniture-composite").map { sentBody in
            try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
        }
        #expect(sentBodies.count == 3)
        #expect(sentBodies[0]["standsOn"] as? String == "tableOrShelf")
        // The field is absent, never "floor", so the Worker's floor wording stays byte for byte.
        #expect(sentBodies[1]["standsOn"] == nil)
        #expect(sentBodies[2]["standsOn"] == nil)
    }

    @Test func aTitleOverTheWorkersLimitIsCutBeforeBothRequestsAreSent() async throws {
        let longTitle = String(repeating: "Sofa ", count: 100)
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())
        answer("try-it-model", statusCode: 200, body: glbBytes)
        let furnitureClient = client()
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }

        _ = try await furnitureClient.paintTheItemIntoTheKeyframe(
            keyframeJPEG: keyframeJPEG, keyframeWidth: 200, keyframeHeight: 100, productJPEG: productJPEG,
            maskPNG: maskPNG, itemTitle: longTitle, itemSizeWords: "31.5 inches wide and 29.5 tall"
        )
        _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: longTitle, cacheKeyData: pagePictureJPEG)

        for route in ["room-furniture-composite", "try-it-model"] {
            let sentBody = try #require(requestBodies(of: route).first)
            let sentJSON = try #require(JSONSerialization.jsonObject(with: sentBody) as? [String: Any])
            #expect((sentJSON["itemTitle"] as? String)?.utf16.count == 300)
        }
    }

    @Test func aCompositeReplyOfAnotherSizeComesBackAtTheKeyframesSize() async throws {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply(width: 160, height: 80))

        let pasted = try await paint(using: client())

        #expect(pasted.width == 200)
        #expect(pasted.height == 100)
    }

    @Test func a402SaysOpenAIIsOutOfCredit() async {
        answer("room-furniture-composite", statusCode: 402, body: Data(#"{"error":"OpenAI is out of credit"}"#.utf8))

        await #expect(throws: RoomFurnitureGenerationError.serviceIsOutOfCredit(body: #"{"error":"OpenAI is out of credit"}"#)) {
            _ = try await paint(using: client())
        }
    }

    @Test(arguments: ["room-furniture-composite", "try-it-model"])
    func a503SaysTheServiceIsNotSetUp(route: String) async {
        answer(route, statusCode: 503, body: Data(#"{"error":"FAL_KEY is not set"}"#.utf8))
        let furnitureClient = client()

        await #expect(throws: RoomFurnitureGenerationError.serviceIsNotSetUp(body: #"{"error":"FAL_KEY is not set"}"#)) {
            if route == "try-it-model" {
                _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Chair", cacheKeyData: pagePictureJPEG)
            } else {
                _ = try await paint(using: furnitureClient)
            }
        }
    }

    @Test(arguments: [400, 401, 502, 504])
    func anotherStatusIsAFailureWithItsCode(statusCode: Int) async {
        answer("room-furniture-composite", statusCode: statusCode, body: Data(#"{"error":"x"}"#.utf8))
        answer("try-it-model", statusCode: statusCode, body: Data(#"{"error":"x"}"#.utf8))
        let furnitureClient = client()

        await #expect(throws: RoomFurnitureGenerationError.workerReturned(statusCode: statusCode, body: #"{"error":"x"}"#)) {
            _ = try await paint(using: furnitureClient)
        }
        await #expect(throws: RoomFurnitureGenerationError.workerReturned(statusCode: statusCode, body: #"{"error":"x"}"#)) {
            _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Chair", cacheKeyData: pagePictureJPEG)
        }
    }

    @Test func aCompositeReplyThatHoldsNoImageCannotBeRead() async {
        answer("room-furniture-composite", statusCode: 200, body: Data(#"{"imageJPEGBase64":"bm90IGFuIGltYWdl","width":200,"height":100}"#.utf8))
        let furnitureClient = client()

        await #expect(throws: RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply holds no image")) {
            _ = try await paint(using: furnitureClient)
        }
    }

    @Test func aCompositeReplyWhoseImageIsNotTheSizeItStatesCannotBeRead() async {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply(statedWidth: 1280))
        let furnitureClient = client()

        await #expect(throws: RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the image is 200x100, and the reply says 1280x100")) {
            _ = try await paint(using: furnitureClient)
        }
    }

    @Test func aKeyframeThatIsNotAnImageFailsBeforeAnyRequest() async {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())
        let furnitureClient = client()

        await #expect(throws: RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the keyframe is not an image")) {
            _ = try await paint(using: furnitureClient, keyframeJPEG: Data("not a jpeg".utf8))
        }
        #expect(requestBodies(of: "room-furniture-composite").isEmpty)
    }

    @Test func aMaskThatIsNotAnImageFailsBeforeAnyRequest() async {
        answer("room-furniture-composite", statusCode: 200, body: compositeReply())
        let furnitureClient = client()

        await #expect(throws: RoomFurnitureGenerationError.inputCouldNotBeRead(reason: "the mask is not an image")) {
            _ = try await furnitureClient.paintTheItemIntoTheKeyframe(
                keyframeJPEG: keyframeJPEG, keyframeWidth: 200, keyframeHeight: 100, productJPEG: productJPEG,
                maskPNG: Data("not a png".utf8), itemTitle: "LACK Coffee table", itemSizeWords: "118 cm wide"
            )
        }
        #expect(requestBodies(of: "room-furniture-composite").isEmpty)
    }

    @Test func theModelIsMadeOnceAndThenReadFromTheCache() async throws {
        answer("try-it-model", statusCode: 200, body: glbBytes)
        let furnitureClient = client()
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }

        let firstModel = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)
        let secondModel = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)
        // A new client, as after a relaunch, reads the same file.
        let modelAfterARelaunch = try await client().generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)

        #expect(firstModel == glbBytes)
        #expect(secondModel == glbBytes)
        #expect(modelAfterARelaunch == glbBytes)
        #expect(requestBodies(of: "try-it-model").count == 1)
        let sentJSON = try #require(JSONSerialization.jsonObject(with: requestBodies(of: "try-it-model")[0]) as? [String: Any])
        #expect(sentJSON["productJPEGBase64"] as? String == productJPEG.base64EncodedString())
        #expect(sentJSON["itemTitle"] as? String == "Field Lounge Chair")
        let cacheFile = modelCacheFolder.appendingPathComponent(tryItModelCacheKey(cacheKeyData: pagePictureJPEG, itemTitle: "Field Lounge Chair") + ".glb")
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func aCutoutThatShiftedByAPixelStillReadsTheModelFromTheCache() async throws {
        answer("try-it-model", statusCode: 200, body: glbBytes)
        let furnitureClient = client()
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }
        let shiftedCutoutJPEG = encoded(solidImage(width: 41, height: 40, red: 1, green: 1, blue: 1), as: .jpeg)

        _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)
        _ = try await furnitureClient.generateAModel(productJPEG: shiftedCutoutJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)

        #expect(requestBodies(of: "try-it-model").count == 1)
    }

    @Test func anotherPagePicturePaysForItsOwnModel() async throws {
        answer("try-it-model", statusCode: 200, body: glbBytes)
        let furnitureClient = client()
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }

        _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)
        _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: Data([7, 7, 7]))

        #expect(requestBodies(of: "try-it-model").count == 2)
    }

    @Test func anotherProductPaysForItsOwnModel() async throws {
        answer("try-it-model", statusCode: 200, body: glbBytes)
        let furnitureClient = client()
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }

        _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Field Lounge Chair", cacheKeyData: pagePictureJPEG)
        _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Amaroso Accent Chair", cacheKeyData: pagePictureJPEG)

        #expect(requestBodies(of: "try-it-model").count == 2)
    }

    @Test func aCachedFileThatIsNotAGLBIsMadeAgain() async throws {
        answer("try-it-model", statusCode: 200, body: glbBytes)
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }
        try FileManager.default.createDirectory(at: modelCacheFolder, withIntermediateDirectories: true)
        let cacheFile = modelCacheFolder.appendingPathComponent(tryItModelCacheKey(cacheKeyData: pagePictureJPEG, itemTitle: "Chair") + ".glb")
        try Data("half a download".utf8).write(to: cacheFile)

        let model = try await client().generateAModel(productJPEG: productJPEG, itemTitle: "Chair", cacheKeyData: pagePictureJPEG)

        #expect(model == glbBytes)
        #expect(requestBodies(of: "try-it-model").count == 1)
    }

    @Test func aModelReplyThatIsNotAGLBFailsAndIsNotCached() async {
        answer("try-it-model", statusCode: 200, body: Data(#"{"ok":true}"#.utf8))
        let furnitureClient = client()
        defer { try? FileManager.default.removeItem(at: modelCacheFolder) }

        await #expect(throws: RoomFurnitureGenerationError.replyCouldNotBeRead(reason: "the reply is not a GLB")) {
            _ = try await furnitureClient.generateAModel(productJPEG: productJPEG, itemTitle: "Chair", cacheKeyData: pagePictureJPEG)
        }
        let cacheFile = modelCacheFolder.appendingPathComponent(tryItModelCacheKey(cacheKeyData: pagePictureJPEG, itemTitle: "Chair") + ".glb")
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func theDefaultCacheFolderIsTryItModelsUnderTheAppsCaches() {
        let folder = defaultTryItModelCacheFolder()

        #expect(folder.lastPathComponent == "TryItModels")
        #expect(folder.path.contains("/Library/Caches/"))
    }
}
