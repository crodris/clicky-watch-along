//
//  VideoFramePopout.swift
//  leanring-buddy
//
//  A frame grabbed from the playing video, and the subject and part labels
//  Sonnet found in it. At a quiz pause the overlay lifts that subject out of
//  the frame in 3D, starting exactly over the video on screen.
//

import AppKit
import Foundation
import Vision

/// What the grab JavaScript in Chrome returns. The rect is the video element in
/// global screen points with the origin at the top left of the main display.
struct VideoFrameGrab: Decodable {
    let jpeg: String
    let width: Int
    let height: Int
    let videoSeconds: Double
    let rectX: Double
    let rectY: Double
    let rectWidth: Double
    let rectHeight: Double
}

struct VideoFramePopout {
    struct SubjectBox: Decodable {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int
    }

    struct Part: Decodable {
        let label: String
        let x: Int
        let y: Int
        let isQuizAnswer: Bool
    }

    let frameGrab: VideoFrameGrab
    /// The bounding box of the subject mask, in frame pixels.
    let subjectBox: SubjectBox
    let parts: [Part]
    /// A PNG as large as the frame, white where the subject is.
    let subjectMaskPNGBase64: String
}

private struct VideoFramePartsResponse: Decodable {
    let subjectFound: Bool
    let subjectBox: VideoFramePopout.SubjectBox?
    let parts: [VideoFramePopout.Part]?
}

enum VideoFramePopoutClient {
    /// Sonnet answers in about 4 seconds. Past this the moment is asked by voice only.
    private static let requestTimeoutSeconds: TimeInterval = 10

    /// Nil means the frame has no single subject to lift out, such as a chart.
    static func requestPopout(
        workerBaseURL: String,
        frameGrab: VideoFrameGrab,
        subject: String,
        quiz: LiveSceneQuiz
    ) async throws -> VideoFramePopout? {
        guard let framePartsURL = URL(string: "\(workerBaseURL)/video-frame-parts") else {
            preconditionFailure("Worker base URL did not form the frame parts URL: \(workerBaseURL)")
        }
        var request = URLRequest(url: framePartsURL, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "frameBase64": frameGrab.jpeg,
            "frameWidth": frameGrab.width,
            "frameHeight": frameGrab.height,
            "subject": subject,
            "question": quiz.question,
            "answerLabel": quiz.answerLabel,
        ])
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "Frame parts returned \(statusCode): \(String(decoding: responseData.prefix(300), as: UTF8.self))",
            ])
        }
        let framePartsResponse = try JSONDecoder().decode(VideoFramePartsResponse.self, from: responseData)
        guard framePartsResponse.subjectFound,
              let subjectBox = framePartsResponse.subjectBox,
              let parts = framePartsResponse.parts, !parts.isEmpty else {
            return nil
        }
        guard let frameJPEGData = Data(base64Encoded: frameGrab.jpeg) else { return nil }
        // Vision is on-device and takes under half a second, so it runs off the main actor.
        let subjectMask = try await Task.detached(priority: .userInitiated) {
            try VideoFrameSubjectMask.subjectMask(frameJPEGData: frameJPEGData, sonnetSubjectBox: subjectBox)
        }.value
        guard let subjectMask else { return nil }
        return VideoFramePopout(
            frameGrab: frameGrab,
            subjectBox: subjectMask.boundingBox,
            parts: parts,
            subjectMaskPNGBase64: subjectMask.pngData.base64EncodedString()
        )
    }
}

/// Apple's subject lifting finds the subject's outline, which a color match cannot do
/// when the drawing sits on a shape or a gradient. Sonnet's box picks which subject to keep.
enum VideoFrameSubjectMask {
    struct SubjectMask {
        let pngData: Data
        let boundingBox: VideoFramePopout.SubjectBox
    }

    /// An instance counts as the subject when most of it lies inside Sonnet's box.
    private static let shareOfAnInstanceInsideTheBox = 0.5

    nonisolated static func subjectMask(
        frameJPEGData: Data,
        sonnetSubjectBox: VideoFramePopout.SubjectBox
    ) throws -> SubjectMask? {
        guard let imageSource = CGImageSourceCreateWithData(frameJPEGData as CFData, nil),
              let frameImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        let maskRequest = VNGenerateForegroundInstanceMaskRequest()
        let requestHandler = VNImageRequestHandler(cgImage: frameImage)
        try requestHandler.perform([maskRequest])
        guard let maskObservation = maskRequest.results?.first else { return nil }

        let frameWidth = frameImage.width, frameHeight = frameImage.height
        var combinedMask = [UInt8](repeating: 0, count: frameWidth * frameHeight)
        var keptInstanceCount = 0
        for instance in maskObservation.allInstances {
            let instanceMaskBuffer = try maskObservation.generateScaledMaskForImage(forInstances: [instance], from: requestHandler)
            let instanceMask = maskValues(of: instanceMaskBuffer, width: frameWidth, height: frameHeight)
            var pixelCount = 0, pixelsInsideTheBox = 0
            for y in 0..<frameHeight {
                for x in 0..<frameWidth where instanceMask[y * frameWidth + x] {
                    pixelCount += 1
                    if x >= sonnetSubjectBox.left, x <= sonnetSubjectBox.right, y >= sonnetSubjectBox.top, y <= sonnetSubjectBox.bottom {
                        pixelsInsideTheBox += 1
                    }
                }
            }
            guard pixelCount > 0, Double(pixelsInsideTheBox) / Double(pixelCount) > shareOfAnInstanceInsideTheBox else { continue }
            keptInstanceCount += 1
            for pixelIndex in combinedMask.indices where instanceMask[pixelIndex] {
                combinedMask[pixelIndex] = 255
            }
        }
        guard keptInstanceCount > 0 else { return nil }

        var left = frameWidth, top = frameHeight, right = -1, bottom = -1
        for y in 0..<frameHeight {
            for x in 0..<frameWidth where combinedMask[y * frameWidth + x] == 255 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right - left >= 40, bottom - top >= 40,
              let pngData = grayscalePNG(of: combinedMask, width: frameWidth, height: frameHeight) else {
            return nil
        }
        print("Video quiz: Vision kept \(keptInstanceCount) of \(maskObservation.allInstances.count) subjects")
        return SubjectMask(
            pngData: pngData,
            boundingBox: VideoFramePopout.SubjectBox(left: left, top: top, right: right, bottom: bottom)
        )
    }

    /// The scaled mask is one 32-bit float per pixel, 0 outside the subject and 1 inside.
    nonisolated private static func maskValues(of maskBuffer: CVPixelBuffer, width: Int, height: Int) -> [Bool] {
        CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly) }
        var values = [Bool](repeating: false, count: width * height)
        guard let baseAddress = CVPixelBufferGetBaseAddress(maskBuffer),
              CVPixelBufferGetWidth(maskBuffer) == width,
              CVPixelBufferGetHeight(maskBuffer) == height else {
            return values
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(maskBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
            for x in 0..<width {
                values[y * width + x] = row[x] > 0.5
            }
        }
        return values
    }

    nonisolated private static func grayscalePNG(of maskBytes: [UInt8], width: Int, height: Int) -> Data? {
        var pixelBytes = maskBytes
        guard let context = CGContext(
            data: &pixelBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let maskImage = context.makeImage() else {
            return nil
        }
        return NSBitmapImageRep(cgImage: maskImage).representation(using: .png, properties: [:])
    }
}

/// The bundled pop-out page with this frame's data in it, or nil when the template is missing.
/// The overlay covers `overlayScreen`, so the video rect is moved into that screen's page coordinates.
func framePopoutPageHTML(for framePopout: VideoFramePopout, overlayScreen: NSScreen) -> String? {
    let templateURL = Bundle.main.url(forResource: "frame-popout", withExtension: "html", subdirectory: "LiveSceneAssets")
        ?? Bundle.main.url(forResource: "frame-popout", withExtension: "html")
    guard let templateURL, let templateHTML = try? String(contentsOf: templateURL, encoding: .utf8) else {
        print("Video quiz: frame-popout.html is not in the app bundle")
        return nil
    }

    // Chrome's screen origin is the top left of the main display, and AppKit's is the bottom left.
    let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? overlayScreen.frame.height
    let overlayTopInChromeCoordinates = mainDisplayHeight - overlayScreen.frame.maxY
    let frameGrab = framePopout.frameGrab
    let popoutData: [String: Any] = [
        "frameDataURL": "data:image/jpeg;base64,\(frameGrab.jpeg)",
        "maskDataURL": "data:image/png;base64,\(framePopout.subjectMaskPNGBase64)",
        "videoRect": [
            "x": frameGrab.rectX - overlayScreen.frame.minX,
            "y": frameGrab.rectY - overlayTopInChromeCoordinates,
            "width": frameGrab.rectWidth,
            "height": frameGrab.rectHeight,
        ],
        "subjectBox": [
            "left": framePopout.subjectBox.left,
            "top": framePopout.subjectBox.top,
            "right": framePopout.subjectBox.right,
            "bottom": framePopout.subjectBox.bottom,
        ],
        "parts": framePopout.parts.map { part in
            ["label": part.label, "x": part.x, "y": part.y, "isQuizAnswer": part.isQuizAnswer] as [String: Any]
        },
    ]
    // JSONSerialization escapes "/" as "\/", so a label can never close the script tag.
    guard let popoutDataJSON = try? JSONSerialization.data(withJSONObject: popoutData),
          let popoutDataText = String(data: popoutDataJSON, encoding: .utf8) else {
        return nil
    }
    return templateHTML.replacingOccurrences(
        of: "/*CLICKY_FRAME_POPOUT_DATA*/",
        with: "window.__framePopout = \(popoutDataText);"
    )
}
