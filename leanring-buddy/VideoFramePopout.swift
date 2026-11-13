//
//  VideoFramePopout.swift
//  leanring-buddy
//
//  A frame grabbed from the playing video or captured over a page image, and
//  the subject and part labels Sonnet found in it. The overlay lifts that subject
//  out of the frame in 3D, starting exactly over the video or image on screen.
//

import AppKit
import Foundation
import Vision

/// A frame to lift a subject out of: what the grab JavaScript in Chrome returns for a video,
/// or a capture of the screen over a page image. The rect is in global screen points
/// with the origin at the top left of the main display.
struct VideoFrameGrab: Decodable {
    let jpeg: String
    let width: Int
    let height: Int
    /// Nil for a page image captured from the screen.
    let videoSeconds: Double?
    let rectX: Double
    let rectY: Double
    let rectWidth: Double
    let rectHeight: Double

    var screenRect: ScreenRectInChromeCoordinates {
        ScreenRectInChromeCoordinates(rectX: rectX, rectY: rectY, rectWidth: rectWidth, rectHeight: rectHeight)
    }

    var source: FramePopoutSource {
        videoSeconds == nil ? .pageImage : .pausedYouTubeFrame
    }
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
    /// True for a cutaway, a 3D render, or a photo, which lifts out as a flat card instead of puffed up.
    let pictureShowsDepth: Bool
    /// The page image's own frames when it is animated, which the lifted subject keeps playing. Empty for a still.
    var animationFrames: [PageImageAnimationFrame] = []
}

private struct VideoFramePartsResponse: Decodable {
    let subjectFound: Bool
    let subjectBox: VideoFramePopout.SubjectBox?
    let parts: [VideoFramePopout.Part]?
    /// True for a painted scene, which lifts out whole instead of as Vision's foreground objects.
    let wholePictureIsSubject: Bool?
    /// Missing from a Worker that predates it, which keeps the puffed-up lift.
    let pictureShowsDepth: Bool?
}

enum VideoFramePopoutClient {
    /// Sonnet answers in about 4 seconds. Past this the moment is asked by voice only.
    private static let requestTimeoutSeconds: TimeInterval = 10

    /// Nil means the frame has no single subject to lift out, such as a chart.
    static func requestPopout(
        workerBaseURL: String,
        frameGrab: VideoFrameGrab,
        subject: String,
        question: String,
        answerLabel: String
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
            "question": question,
            "answerLabel": answerLabel,
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
        let liftsTheWholePicture = framePartsResponse.wholePictureIsSubject == true
        let frameWidth = frameGrab.width, frameHeight = frameGrab.height
        // Building either mask walks every frame pixel, and Vision takes under half a second, so both run off the main actor.
        let subjectMask = try await Task.detached(priority: .userInitiated) {
            if liftsTheWholePicture {
                print("Frame pop-out: lifting the whole picture in Sonnet's box")
                return VideoFrameSubjectMask.wholePictureMask(frameWidth: frameWidth, frameHeight: frameHeight, pictureBox: subjectBox)
            }
            return try VideoFrameSubjectMask.subjectMask(frameJPEGData: frameJPEGData, sonnetSubjectBox: subjectBox)
        }.value
        guard let subjectMask else { return nil }
        return VideoFramePopout(
            frameGrab: frameGrab,
            subjectBox: subjectMask.boundingBox,
            parts: parts,
            subjectMaskPNGBase64: subjectMask.pngData.base64EncodedString(),
            pictureShowsDepth: framePartsResponse.pictureShowsDepth == true
        )
    }
}

/// Apple's subject lifting finds the subject's outline, which a color match cannot do
/// when the drawing sits on a shape or a gradient. Sonnet's box picks which subject to keep,
/// or, for a painted scene, is the mask itself.
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

    /// Vision finds only foreground objects, so in a painted scene it keeps one thing, like the cypress in
    /// The Starry Night, and drops the sky. A painted scene lifts out as the whole box Sonnet drew around it.
    nonisolated static func wholePictureMask(
        frameWidth: Int,
        frameHeight: Int,
        pictureBox: VideoFramePopout.SubjectBox
    ) -> SubjectMask? {
        guard pictureBox.left >= 0, pictureBox.top >= 0,
              pictureBox.right < frameWidth, pictureBox.bottom < frameHeight,
              pictureBox.left < pictureBox.right, pictureBox.top < pictureBox.bottom else {
            return nil
        }
        var maskBytes = [UInt8](repeating: 0, count: frameWidth * frameHeight)
        for y in pictureBox.top...pictureBox.bottom {
            for x in pictureBox.left...pictureBox.right {
                maskBytes[y * frameWidth + x] = 255
            }
        }
        guard let pngData = grayscalePNG(of: maskBytes, width: frameWidth, height: frameHeight) else { return nil }
        return SubjectMask(pngData: pngData, boundingBox: pictureBox)
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

/// A rectangle in global screen points with the origin at the top left of the main display,
/// which is how Chrome reports where a page element sits on screen.
struct ScreenRectInChromeCoordinates: Decodable, Equatable {
    let rectX: Double
    let rectY: Double
    let rectWidth: Double
    let rectHeight: Double
}

/// What Chrome reports about its window and one page element. The page measures in CSS pixels
/// and the window in screen points, so the two only meet through the page zoom.
struct ChromePageGeometry: Decodable, Equatable {
    /// The window's top left in global points, with the origin at the top left of the main display.
    let screenX: Double
    let screenY: Double
    let outerWidth: Double
    let outerHeight: Double
    /// The page viewport in CSS pixels.
    let innerWidth: Double
    let innerHeight: Double
    let devicePixelRatio: Double
    /// The element's visible part in CSS pixels, relative to the viewport.
    let left: Double
    let top: Double
    let width: Double
    let height: Double
    /// The image's URL when it sits wholly inside the viewport, stretched to its box. Nil for a video.
    let imageSourceURL: String?
}

/// The largest visible video or image in Chrome's front tab.
struct LargestVisibleMediaInFrontTab {
    let screenRect: ScreenRectInChromeCoordinates
    /// Set only for an image whose own frames line up with a capture of `screenRect`.
    let imageSourceURL: URL?
}

/// The element's place on screen. The page zoom is the page's device pixel ratio divided by the
/// screen's backing scale factor, so a CSS pixel is `pageZoom` points. At zoom 1 this is the plain
/// sum of the window origin, the browser frame, and the element's offset.
/// This is the fallback for when Chrome's accessibility tree gives no web area, and it assumes the whole
/// browser frame sits left of and above the viewport. Nil when the geometry cannot be trusted.
func screenRectInChromeCoordinates(from pageGeometry: ChromePageGeometry, backingScaleFactor: Double) -> ScreenRectInChromeCoordinates? {
    guard pageGeometry.devicePixelRatio > 0, backingScaleFactor > 0 else { return nil }
    let pageZoom = pageGeometry.devicePixelRatio / backingScaleFactor
    let viewportWidthInPoints = pageGeometry.innerWidth * pageZoom
    let viewportHeightInPoints = pageGeometry.innerHeight * pageZoom
    let browserFrameWidthInPoints = pageGeometry.outerWidth - viewportWidthInPoints
    let browserFrameHeightInPoints = pageGeometry.outerHeight - viewportHeightInPoints
    // Docked DevTools take a side or the bottom of the window, so the gap between the window and the
    // viewport is far bigger than the tab strip and toolbar. The viewport's own offset inside the window
    // is then unknown, and a rect placed from it would sit on the wrong pixels.
    let largestPlausibleBrowserFrameWidthInPoints = 400.0
    let largestPlausibleBrowserFrameHeightInPoints = 250.0
    // A frame below zero by more than rounding means the backing scale factor does not belong to the screen
    // Chrome is on, so the zoom and everything built on it is wrong.
    let mostNegativeBrowserFrameInPointsThatRoundingExplains = -2.0
    guard browserFrameWidthInPoints >= mostNegativeBrowserFrameInPointsThatRoundingExplains,
          browserFrameHeightInPoints >= mostNegativeBrowserFrameInPointsThatRoundingExplains,
          browserFrameWidthInPoints <= largestPlausibleBrowserFrameWidthInPoints,
          browserFrameHeightInPoints <= largestPlausibleBrowserFrameHeightInPoints else {
        return nil
    }
    return ScreenRectInChromeCoordinates(
        rectX: pageGeometry.screenX + browserFrameWidthInPoints + pageGeometry.left * pageZoom,
        rectY: pageGeometry.screenY + browserFrameHeightInPoints + pageGeometry.top * pageZoom,
        rectWidth: pageGeometry.width * pageZoom,
        rectHeight: pageGeometry.height * pageZoom
    )
}

/// A screen rectangle in the overlay page's coordinates. Chrome's screen origin
/// is the top left of the main display, and AppKit's is the bottom left.
func rectInOverlayPage(of screenRect: ScreenRectInChromeCoordinates, overlayScreen: NSScreen) -> [String: Double] {
    let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? overlayScreen.frame.height
    let overlayTopInChromeCoordinates = mainDisplayHeight - overlayScreen.frame.maxY
    return [
        "x": screenRect.rectX - overlayScreen.frame.minX,
        "y": screenRect.rectY - overlayTopInChromeCoordinates,
        "width": screenRect.rectWidth,
        "height": screenRect.rectHeight,
    ]
}

/// The video's place on screen in the overlay page's coordinates.
func videoRectInOverlayPage(of frameGrab: VideoFrameGrab, overlayScreen: NSScreen) -> [String: Double] {
    rectInOverlayPage(of: frameGrab.screenRect, overlayScreen: overlayScreen)
}

/// The screen showing the grabbed video or image, so its pop-out plays over it even when
/// the mouse is on another display. Falls back to the screen under the mouse.
func overlayScreen(showing frameGrab: VideoFrameGrab) -> NSScreen? {
    let screens = NSScreen.screens
    if let screenIndex = indexOfTheScreenFrameHolding(frameGrab.screenRect, screenFramesInAppKitCoordinates: screens.map(\.frame)) {
        return screens[screenIndex]
    }
    return screenUnderTheMouseCursor()
}

/// The index of the screen that holds the largest part of the rect, or nil when no screen touches it.
/// The rect's center can sit in the gap between screens of different sizes, so the center is not used.
/// The first frame is the main display, whose top edge is Chrome's y of 0.
func indexOfTheScreenFrameHolding(
    _ screenRect: ScreenRectInChromeCoordinates,
    screenFramesInAppKitCoordinates: [CGRect]
) -> Int? {
    guard let mainDisplayHeight = screenFramesInAppKitCoordinates.first?.height else { return nil }
    // Flip the rect from Chrome's top-left origin to AppKit's bottom-left origin.
    let rectInAppKitCoordinates = CGRect(
        x: screenRect.rectX,
        y: mainDisplayHeight - (screenRect.rectY + screenRect.rectHeight),
        width: screenRect.rectWidth,
        height: screenRect.rectHeight
    )
    func intersectionArea(with screenFrame: CGRect) -> CGFloat {
        let intersection = rectInAppKitCoordinates.intersection(screenFrame)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
    let areaHeldByEachScreenFrame = screenFramesInAppKitCoordinates.map(intersectionArea(with:))
    guard let largestArea = areaHeldByEachScreenFrame.max(), largestArea > 0 else { return nil }
    return areaHeldByEachScreenFrame.firstIndex(of: largestArea)
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

    let frameGrab = framePopout.frameGrab
    let popoutData: [String: Any] = [
        "frameDataURL": "data:image/jpeg;base64,\(frameGrab.jpeg)",
        "maskDataURL": "data:image/png;base64,\(framePopout.subjectMaskPNGBase64)",
        "videoRect": videoRectInOverlayPage(of: frameGrab, overlayScreen: overlayScreen),
        "subjectBox": [
            "left": framePopout.subjectBox.left,
            "top": framePopout.subjectBox.top,
            "right": framePopout.subjectBox.right,
            "bottom": framePopout.subjectBox.bottom,
        ],
        "parts": framePopout.parts.map { part in
            ["label": part.label, "x": part.x, "y": part.y, "isQuizAnswer": part.isQuizAnswer] as [String: Any]
        },
        "pictureShowsDepth": framePopout.pictureShowsDepth,
        "animationFrames": framePopout.animationFrames.map { animationFrame in
            ["dataURL": "data:image/jpeg;base64,\(animationFrame.jpegBase64)", "delaySeconds": animationFrame.delaySeconds] as [String: Any]
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
