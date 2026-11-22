//
//  FrameGrabFormatTests.swift
//  leanring-buddyTests
//
//  A YouTube frame grab's bytes come from a script in the page, so only a JPEG may reach a decoder.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Clicky

struct FrameGrabFormatTests {
    /// A small solid image encoded in the given format, as base64.
    private func base64Image(encodedAs imageType: UTType) throws -> String {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let drawingContext = try #require(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        drawingContext.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        drawingContext.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let solidImage = try #require(drawingContext.makeImage())
        let encodedData = NSMutableData()
        let imageDestination = try #require(CGImageDestinationCreateWithData(encodedData, imageType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(imageDestination, solidImage, nil)
        #expect(CGImageDestinationFinalize(imageDestination))
        return (encodedData as Data).base64EncodedString()
    }

    @Test func aJPEGFrameGrabIsAccepted() throws {
        #expect(frameGrabHoldsAJPEG(base64JPEG: try base64Image(encodedAs: .jpeg)))
    }

    @Test func aFrameGrabInAnotherFormatIsNotAJPEG() throws {
        #expect(!frameGrabHoldsAJPEG(base64JPEG: try base64Image(encodedAs: .tiff)))
        #expect(!frameGrabHoldsAJPEG(base64JPEG: try base64Image(encodedAs: .png)))
        // Two of the three marker bytes are not enough.
        #expect(!frameGrabHoldsAJPEG(base64JPEG: Data([0xFF, 0xD8]).base64EncodedString()))
        #expect(!frameGrabHoldsAJPEG(base64JPEG: Data([0xFF, 0xD8, 0x00, 0xE0]).base64EncodedString()))
    }

    /// The page script's reply, as `grabFrameJavaScript` writes it, holding `base64Bytes` as the grab.
    private func scriptReply(holding base64Bytes: String) -> String {
        "{\"jpeg\":\"\(base64Bytes)\",\"width\":8,\"height\":8,\"videoSeconds\":12.5,\"rectX\":0,\"rectY\":0,\"rectWidth\":8,\"rectHeight\":8}"
    }

    @MainActor
    @Test func theScriptReplyKeepsAJPEGGrab() throws {
        let jpegBytes = try base64Image(encodedAs: .jpeg)
        let frameGrab = try VideoQuizSession.frameGrab(inTheScriptReply: scriptReply(holding: jpegBytes))
        #expect(frameGrab.jpeg == jpegBytes)
        #expect(frameGrab.videoSeconds == 12.5)
    }

    @MainActor
    @Test func theScriptReplyRefusesAGrabInAnotherFormatBeforeAnyDecode() throws {
        let pngBytes = try base64Image(encodedAs: .png)
        #expect(throws: (any Error).self) { try VideoQuizSession.frameGrab(inTheScriptReply: scriptReply(holding: pngBytes)) }
        #expect(throws: (any Error).self) { try VideoQuizSession.frameGrab(inTheScriptReply: "no-video") }
    }

    @Test func aFrameGrabThatIsNotBase64OrNotAnImageIsRefused() {
        #expect(!frameGrabHoldsAJPEG(base64JPEG: "not base64 at all"))
        #expect(!frameGrabHoldsAJPEG(base64JPEG: Data("hello".utf8).base64EncodedString()))
        #expect(!frameGrabHoldsAJPEG(base64JPEG: ""))
    }
}
