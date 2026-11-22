//
//  RoomArtPreview.swift
//  leanring-buddy
//
//  Runs and draws "show me how this would look in my room". `RoomArtPreviewController` reads the page and its picture, opens
//  the panel, starts the camera, takes a keyframe on the first frame with a person mask, and asks the Worker what the page
//  shows (`POST /try-it-item`) and where the wall is (`POST /room-wall`) at once, with Clicky's loop around the wall spot
//  while it waits. `RoomArtFrameProcessor` handles every camera frame on its
//  own queue: it finds the person, tracks the room against the keyframe, and draws the frame with the art on the wall and the
//  learner in front of it.
//
//  Display path: each frame is composed with Core Image and rendered straight into a CAMetalLayer drawable on the processing
//  queue, so the frame never leaves the GPU and never waits for the main thread. Setting a CGImage as CALayer contents would
//  read every 1280 by 720 frame back to the CPU and hop to the main thread to show it.
//

import AppKit
import AVFoundation
import Combine
import CoreImage
import os
import CoreVideo
import Metal
import QuartzCore
import SwiftUI
import Vision

// MARK: - The keyframe

/// The frame a measurement is made on, as the wall request needs it, and the wall's light around the spot.
nonisolated struct RoomArtKeyframe: Sendable {
    let wallRequest: RoomWallRequest
    let wallLight: RoomArtWallLight
}

// MARK: - Frame processor

/// One 5 second window of drawn frames while the art showed.
nonisolated struct RoomArtFrameRateReport: Equatable, Sendable {
    let framesPerSecond: Double
    let trackMilliseconds: Double
    let segmentMilliseconds: Double

    var logLine: String {
        String(format: "Room art: %.0f fps, track %.1f ms, segment %.1f ms", framesPerSecond, trackMilliseconds, segmentMilliseconds)
    }
}

/// What the controller asks of the frame processor. The controller's tests stand in for it, since Vision's person
/// segmentation and Metal drawing do not run in every session, such as CI's background login.
nonisolated protocol RoomArtFrameProcessing: AnyObject, Sendable {
    /// The queue the frame source delivers on, and the one `process(_:)` runs on.
    var processingQueue: DispatchQueue { get }
    /// The layer the panel shows the frames in.
    var metalLayer: CAMetalLayer { get }
    func startASession(onFirstSegmentedFrame: @escaping @Sendable () -> Void, onTheWallLostOrFound: @escaping @Sendable (Bool) -> Void)
    func endTheSession()
    func process(_ cameraFrame: CVPixelBuffer)
    func takeAKeyframe(anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe?
    func showTheArt(_ flattenedArt: CGImage, keyframeCorners: RoomArtCorners)
    func putBackTheArtFromBeforeTheMove()
    /// The loop's window in the newest keyframe and where it is in the newest frame, or nil before the first keyframe of a
    /// session. Safe to call from any thread, since the panel reads it every frame on the main thread.
    func currentLoop() -> RoomArtLoopSnapshot?
}

/// Handles every camera frame on `processingQueue`, which owns all of its state.
nonisolated final class RoomArtFrameProcessor: RoomArtFrameProcessing, @unchecked Sendable {
    let processingQueue = DispatchQueue(label: "com.crodris.clicky.room-art.frames", qos: .userInteractive)
    /// Person segmentation takes about 30 ms a frame, as long as tracking and drawing together, so it runs here beside
    /// them, and each frame is tracked and drawn with the newest mask, one or two frames old.
    private let segmentationQueue = DispatchQueue(label: "com.crodris.clicky.room-art.segmentation", qos: .userInteractive)
    let metalLayer: CAMetalLayer

    private let ciContext: CIContext
    private let commandQueue: MTLCommandQueue?
    private let segmentationRequest: VNGeneratePersonSegmentationRequest
    private let sequenceRequestHandler = VNSequenceRequestHandler()
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Everything below is read and written on `processingQueue` only.
    private var sessionNumber = 0
    private var onFirstSegmentedFrame: (@Sendable () -> Void)?
    private var onTheWallLostOrFound: (@Sendable (Bool) -> Void)?
    /// Whether the last report said the room was lost, so each change is reported once.
    private var theWallIsLostAsLastReported = false
    private var latestFrame: CVPixelBuffer?
    private var latestPersonMask: CVPixelBuffer?
    /// A frame is being segmented, so the next frames skip segmentation until it is done.
    private var segmentationIsRunning = false
    private var latestTrackGrayscale: RoomGrayscaleImage?
    private var latestTrackRoomMask: [Float]?
    private var tracker: RoomTracker?
    private var keyframeWallLight = RoomArtWallLight.neutral
    private var placedArt: PlacedArt?
    /// The tracker and the art from before a click's keyframe, put back when that move's measurement fails.
    private var trackerBeforeTheMove: RoomTracker?
    private var placedArtBeforeTheMove: PlacedArt?
    private var smoothedArtCorners: [CGPoint]?
    /// The window Clicky's loop outlines in the newest keyframe, tracked with the keyframe's own warp each frame.
    private var loopKeyframeCorners: RoomArtCorners?
    private var smoothedLoopCorners: [CGPoint]?
    /// The newest loop snapshot, written on `processingQueue` and read from the main thread.
    private let latestLoop = OSAllocatedUnfairLock<RoomArtLoopSnapshot?>(initialState: nil)
    private var statistics = FrameStatistics()
    private var lastFrameRateReport: RoomArtFrameRateReport?
    #if DEBUG
    /// The last frame as drawn, kept so verification can save what the panel showed.
    private var lastComposedImage: CIImage?
    #endif

    /// The art as it is drawn on every frame: already lit like the wall and softened like the camera, with its shadow.
    private struct PlacedArt {
        let litArt: CIImage
        let shadow: CIImage
        let keyframeCorners: [CGPoint]
    }

    private struct FrameStatistics {
        var windowStartedAt = Date()
        var framesDrawn = 0
        var trackMillisecondsTotal = 0.0
        var segmentMillisecondsTotal = 0.0
        var framesSegmented = 0
    }

    init() {
        let metalDevice = MTLCreateSystemDefaultDevice()
        commandQueue = metalDevice?.makeCommandQueue()
        ciContext = metalDevice.map { CIContext(mtlDevice: $0) } ?? CIContext()
        metalLayer = CAMetalLayer()
        metalLayer.device = metalDevice
        metalLayer.pixelFormat = .bgra8Unorm
        // Core Image writes the drawable with a compute pass, which a framebuffer-only texture refuses.
        metalLayer.framebufferOnly = false
        metalLayer.colorspace = sRGBColorSpace
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.backgroundColor = NSColor.black.cgColor
        segmentationRequest = VNGeneratePersonSegmentationRequest()
        segmentationRequest.qualityLevel = .balanced
        segmentationRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    /// Forgets the last session, so a reopened panel starts with no keyframe and no art. `onFirstSegmentedFrame` runs once,
    /// on the main actor, when the first frame with a person mask has arrived. `onTheWallLostOrFound` runs on the main actor
    /// each time the tracker loses the room long enough to hide the art (true), and when it finds it again (false).
    func startASession(onFirstSegmentedFrame: @escaping @Sendable () -> Void, onTheWallLostOrFound: @escaping @Sendable (Bool) -> Void) {
        processingQueue.sync {
            sessionNumber += 1
            self.onFirstSegmentedFrame = onFirstSegmentedFrame
            self.onTheWallLostOrFound = onTheWallLostOrFound
            theWallIsLostAsLastReported = false
            trackerBeforeTheMove = nil
            placedArtBeforeTheMove = nil
            latestFrame = nil
            latestPersonMask = nil
            latestTrackGrayscale = nil
            latestTrackRoomMask = nil
            tracker = nil
            placedArt = nil
            smoothedArtCorners = nil
            loopKeyframeCorners = nil
            smoothedLoopCorners = nil
            latestLoop.withLock { $0 = nil }
            statistics = FrameStatistics()
        }
    }

    /// Stops reporting the first frame, so a closed panel never starts a measurement.
    func endTheSession() {
        processingQueue.async {
            self.onFirstSegmentedFrame = nil
            self.onTheWallLostOrFound = nil
            self.placedArt = nil
        }
    }

    // MARK: Each frame

    /// Runs on `processingQueue`, where the frame source delivers.
    func process(_ cameraFrame: CVPixelBuffer) {
        let frameWidth = CVPixelBufferGetWidth(cameraFrame), frameHeight = CVPixelBufferGetHeight(cameraFrame)
        let (trackWidth, trackHeight) = trackSize(forFrameWidth: frameWidth, frameHeight: frameHeight)
        if metalLayer.drawableSize != CGSize(width: frameWidth, height: frameHeight) {
            metalLayer.drawableSize = CGSize(width: frameWidth, height: frameHeight)
        }

        startSegmentingIfIdle(cameraFrame)

        // No person until the segmenter has seen a frame, so the room mask is all room before then.
        let trackRoomMask = latestPersonMask.map { personMask in
            roomMaskAtTrackSize(segmentationConfidence: firstPlaneScaled(of: personMask, toWidth: trackWidth, height: trackHeight), width: trackWidth, height: trackHeight)
        } ?? roomMaskWithNoPerson(width: trackWidth, height: trackHeight)
        let trackGrayscale = RoomGrayscaleImage(width: trackWidth, height: trackHeight, pixels: trackGrayscalePixels(of: cameraFrame, width: trackWidth, height: trackHeight))
        latestFrame = cameraFrame
        latestTrackGrayscale = trackGrayscale
        latestTrackRoomMask = trackRoomMask
        if latestPersonMask != nil, let onFirstSegmentedFrame {
            self.onFirstSegmentedFrame = nil
            DispatchQueue.main.async { onFirstSegmentedFrame() }
        }

        let trackStartedAt = Date()
        var trackStep: RoomTrackStep?
        if let tracker {
            trackStep = tracker.track(currentGrayscale: trackGrayscale, currentRoomMask: trackRoomMask)
        }
        let trackMilliseconds = Date().timeIntervalSince(trackStartedAt) * 1000

        // The tracker's turn in camera pixels, which moves both the art's corners and the loop's.
        let cameraWarp = trackStep.map { $0.warp.scaled(by: Double(frameWidth) / Double(trackWidth)) }
        if let loopKeyframeCorners, let trackStep, let cameraWarp, !trackStep.theArtIsHidden {
            let currentLoopCorners = RoomArtLoopGeometry.corners(of: loopKeyframeCorners, after: cameraWarp)
            let smoothedLoopCornerPoints = smoothedCorners(previous: smoothedLoopCorners, current: currentLoopCorners.clockwiseFromTopLeft)
            smoothedLoopCorners = smoothedLoopCornerPoints
            latestLoop.withLock {
                $0 = RoomArtLoopSnapshot(keyframeCorners: loopKeyframeCorners, currentCorners: RoomArtCorners(clockwiseFromTopLeft: smoothedLoopCornerPoints))
            }
        }

        var artCorners: [CGPoint]?
        if let placedArt, let trackStep {
            reportWhetherTheWallIsLost(trackStep.theArtIsHidden)
            if !trackStep.theArtIsHidden, let cameraWarp {
                let currentCorners = placedArt.keyframeCorners.map(cameraWarp.apply)
                artCorners = smoothedCorners(previous: smoothedArtCorners, current: currentCorners)
                smoothedArtCorners = artCorners
            }
        }
        // A frame that found no drawable was not shown, so it does not count toward the frame rate.
        if draw(cameraFrame: cameraFrame, artCorners: artCorners) {
            noteTheFrame(trackMilliseconds: trackMilliseconds)
        }
    }

    /// Tells the main actor when the art hides because the room is lost, and when it shows again, once per change.
    private func reportWhetherTheWallIsLost(_ theWallIsLost: Bool) {
        guard theWallIsLost != theWallIsLostAsLastReported else { return }
        theWallIsLostAsLastReported = theWallIsLost
        guard let onTheWallLostOrFound else { return }
        DispatchQueue.main.async { onTheWallLostOrFound(theWallIsLost) }
    }

    /// Segments `cameraFrame` on the segmentation queue unless a frame is already being segmented. The mask lands back on
    /// the processing queue, where the frames after it use it.
    private func startSegmentingIfIdle(_ cameraFrame: CVPixelBuffer) {
        guard !segmentationIsRunning else { return }
        segmentationIsRunning = true
        let sessionWhenStarted = sessionNumber
        // The camera never writes a frame it has handed out, so the segmentation queue may read it while this queue does.
        nonisolated(unsafe) let frameToSegment = cameraFrame
        segmentationQueue.async {
            let segmentStartedAt = Date()
            var personMask: CVPixelBuffer?
            do {
                try self.sequenceRequestHandler.perform([self.segmentationRequest], on: frameToSegment, orientation: .up)
                personMask = self.segmentationRequest.results?.first?.pixelBuffer
            } catch {
                print("Room art: person segmentation failed: \(error)")
            }
            let segmentMilliseconds = Date().timeIntervalSince(segmentStartedAt) * 1000
            self.processingQueue.async {
                self.segmentationIsRunning = false
                // A mask from a closed panel's frame never reaches the next one.
                guard sessionWhenStarted == self.sessionNumber else { return }
                if let personMask { self.latestPersonMask = personMask }
                self.statistics.framesSegmented += 1
                self.statistics.segmentMillisecondsTotal += segmentMilliseconds
            }
        }
    }

    private func noteTheFrame(trackMilliseconds: Double) {
        statistics.framesDrawn += 1
        statistics.trackMillisecondsTotal += trackMilliseconds
        let secondsInTheWindow = Date().timeIntervalSince(statistics.windowStartedAt)
        guard secondsInTheWindow >= 5 else { return }
        // Logged only while the art shows, since that is when every stage runs.
        if placedArt != nil {
            let framesDrawn = Double(statistics.framesDrawn)
            let frameRateReport = RoomArtFrameRateReport(
                framesPerSecond: framesDrawn / secondsInTheWindow,
                trackMilliseconds: statistics.trackMillisecondsTotal / framesDrawn,
                segmentMilliseconds: statistics.segmentMillisecondsTotal / Double(max(statistics.framesSegmented, 1))
            )
            lastFrameRateReport = frameRateReport
            print(frameRateReport.logLine)
        }
        statistics = FrameStatistics()
    }

    /// The last 5 second window logged while the art showed, or nil before one.
    func lastLoggedFrameRate() -> RoomArtFrameRateReport? {
        processingQueue.sync { lastFrameRateReport }
    }

    // MARK: Drawing

    /// Draws the frame into the layer's next drawable. False when no drawable was free or Core Image refused the frame.
    private func draw(cameraFrame: CVPixelBuffer, artCorners: [CGPoint]?) -> Bool {
        let frameImage = CIImage(cvPixelBuffer: cameraFrame)
        var composedImage = frameImage
        if let placedArt, let artCorners, let latestPersonMask {
            composedImage = frameWithTheArt(frameImage: frameImage, placedArt: placedArt, artCorners: artCorners, personMask: latestPersonMask)
        }
        composedImage = composedImage.cropped(to: frameImage.extent)
        #if DEBUG
        lastComposedImage = composedImage
        #endif
        guard let commandQueue, let drawable = metalLayer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let renderDestination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        renderDestination.colorSpace = sRGBColorSpace
        do {
            _ = try ciContext.startTask(toRender: composedImage, to: renderDestination)
        } catch {
            print("Room art: could not draw a frame: \(error)")
            return false
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    #if DEBUG
    /// The last frame as the panel drew it, for verification. Debug builds only.
    func renderTheLastFrame() -> CGImage? {
        processingQueue.sync {
            lastComposedImage.flatMap { ciContext.createCGImage($0, from: $0.extent, format: .RGBA8, colorSpace: sRGBColorSpace) }
        }
    }
    #endif

    /// The art and its shadow warped onto `artCorners` (camera pixels, y down), over the frame, with the person drawn back
    /// on top through the segmentation mask, so the learner stays in front of the art.
    private func frameWithTheArt(frameImage: CIImage, placedArt: PlacedArt, artCorners: [CGPoint], personMask: CVPixelBuffer) -> CIImage {
        let frameHeight = frameImage.extent.height
        // Core Image's y grows up from the bottom.
        let cornersFromTheBottom = artCorners.map { CGPoint(x: $0.x, y: frameHeight - $0.y) }
        let artExtent = placedArt.litArt.extent
        let artExtentCorners = [
            CGPoint(x: artExtent.minX, y: artExtent.maxY), CGPoint(x: artExtent.maxX, y: artExtent.maxY),
            CGPoint(x: artExtent.maxX, y: artExtent.minY), CGPoint(x: artExtent.minX, y: artExtent.minY),
        ]
        guard let artToFrame = perspectiveTransform(from: artExtentCorners, to: cornersFromTheBottom) else { return frameImage }
        func placedOnTheWall(_ image: CIImage) -> CIImage {
            let extent = image.extent
            let landedCorners = [
                CGPoint(x: extent.minX, y: extent.maxY), CGPoint(x: extent.maxX, y: extent.maxY),
                CGPoint(x: extent.maxX, y: extent.minY), CGPoint(x: extent.minX, y: extent.minY),
            ].map { applyingPerspective(artToFrame, to: $0) }
            return image.applyingFilter("CIPerspectiveTransform", parameters: [
                "inputTopLeft": CIVector(cgPoint: landedCorners[0]),
                "inputTopRight": CIVector(cgPoint: landedCorners[1]),
                "inputBottomRight": CIVector(cgPoint: landedCorners[2]),
                "inputBottomLeft": CIVector(cgPoint: landedCorners[3]),
            ])
        }
        let artOverTheFrame = placedOnTheWall(placedArt.litArt)
            .composited(over: placedOnTheWall(placedArt.shadow))
            .composited(over: frameImage)

        // The mask's confidence from 0.35 to 0.65 becomes the person's opacity, a slightly hard edge that reads as a real
        // occluder instead of a ghost. Every channel reads the first, so a one-channel mask works whichever channel it fills.
        let maskImage = CIImage(cvPixelBuffer: personMask)
        let personOpacity = maskImage
            .transformed(by: CGAffineTransform(scaleX: frameImage.extent.width / maskImage.extent.width, y: frameImage.extent.height / maskImage.extent.height))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 / 0.3, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 1 / 0.3, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 1 / 0.3, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: -0.35 / 0.3, y: -0.35 / 0.3, z: -0.35 / 0.3, w: 0),
            ])
            .applyingFilter("CIColorClamp")
        return frameImage.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: artOverTheFrame,
            kCIInputMaskImageKey: personOpacity,
        ])
    }

    // MARK: Keyframes and the art

    /// Takes the newest frame as the keyframe: the tracker starts from it, the art hides until it is measured again, and the
    /// wall request is built from it. With no anchor, the art centers on the bare wall spot. Nil before any frame arrived.
    func takeAKeyframe(anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe? {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: self.takeAKeyframeOnTheQueue(anchorInCameraPixels: anchorInCameraPixels))
            }
        }
    }

    private func takeAKeyframeOnTheQueue(anchorInCameraPixels: CGPoint?) -> RoomArtKeyframe? {
        guard let latestFrame, let latestTrackGrayscale, let latestTrackRoomMask else { return nil }
        let frameWidth = Double(CVPixelBufferGetWidth(latestFrame)), frameHeight = Double(CVPixelBufferGetHeight(latestFrame))
        let cameraPixelsPerTrackPixel = frameWidth / Double(latestTrackGrayscale.width)
        let anchor = anchorInCameraPixels ?? {
            let trackSpot = bareWallSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
            return CGPoint(x: trackSpot.x * cameraPixelsPerTrackPixel, y: trackSpot.y * cameraPixelsPerTrackPixel)
        }()

        trackerBeforeTheMove = tracker
        placedArtBeforeTheMove = placedArt
        tracker = RoomTracker(keyframeGrayscale: latestTrackGrayscale, keyframeRoomMask: latestTrackRoomMask)
        placedArt = nil
        smoothedArtCorners = nil
        theWallIsLostAsLastReported = false
        // The loop outlines the window around the spot until the art shows, and starts on the keyframe where it was drawn.
        let keyframeLoopCorners = RoomArtLoopGeometry.keyframeCorners(around: anchor, frameSize: CGSize(width: frameWidth, height: frameHeight))
        loopKeyframeCorners = keyframeLoopCorners
        smoothedLoopCorners = nil
        latestLoop.withLock { $0 = RoomArtLoopSnapshot(keyframeCorners: keyframeLoopCorners, currentCorners: keyframeLoopCorners) }

        let frameImage = CIImage(cvPixelBuffer: latestFrame)
        guard let keyframeJPEGData = ciContext.jpegRepresentation(
            of: frameImage,
            colorSpace: sRGBColorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        ) else { return nil }
        // White is the person. Before the segmenter's first mask there is no person, so an empty mask goes instead.
        let maskImage = latestPersonMask.map { CIImage(cvPixelBuffer: $0) }
            ?? CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: latestTrackGrayscale.width, height: latestTrackGrayscale.height))
        guard let personMaskPNGData = ciContext.pngRepresentation(of: maskImage, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }

        keyframeWallLight = wallLight(around: anchor, in: frameImage, frameWidth: frameWidth, frameHeight: frameHeight)
        return RoomArtKeyframe(
            wallRequest: RoomWallRequest(keyframeJPEGData: keyframeJPEGData, personMaskPNGData: personMaskPNGData, anchor: anchor),
            wallLight: keyframeWallLight
        )
    }

    /// The wall's average color in a square 16 percent of the frame wide around the spot, in sRGB.
    private func wallLight(around anchor: CGPoint, in frameImage: CIImage, frameWidth: Double, frameHeight: Double) -> RoomArtWallLight {
        let radius = frameWidth * 0.08
        let patch = CGRect(x: anchor.x - radius, y: frameHeight - anchor.y - radius, width: radius * 2, height: radius * 2)
            .intersection(frameImage.extent)
        guard !patch.isEmpty else { return .neutral }
        let averageColor = frameImage.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: patch)])
        var averageRGBA = [Float](repeating: 0, count: 4)
        ciContext.render(averageColor, toBitmap: &averageRGBA, rowBytes: 4 * MemoryLayout<Float>.size, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: sRGBColorSpace)
        return RoomArtWallLight(wallRed: Double(averageRGBA[0]), wallGreen: Double(averageRGBA[1]), wallBlue: Double(averageRGBA[2]))
    }

    /// Hangs the art at `keyframeCorners` (camera pixels in the keyframe), lit like the wall around the keyframe's spot, with
    /// about 0.7 camera pixels of blur and a soft contact shadow below.
    func showTheArt(_ flattenedArt: CGImage, keyframeCorners: RoomArtCorners) {
        processingQueue.async {
            let corners = keyframeCorners.clockwiseFromTopLeft
            let artWidth = Double(flattenedArt.width), artHeight = Double(flattenedArt.height)
            let artExtent = CGRect(x: 0, y: 0, width: artWidth, height: artHeight)
            let landedWidth = max(hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y), 1)
            let artPixelsPerCameraPixel = artWidth / landedWidth
            let light = self.keyframeWallLight
            let litArt = CIImage(cgImage: flattenedArt)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: light.redGain, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: light.greenGain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: light.blueGain, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 0.94])
                .clampedToExtent()
                .applyingGaussianBlur(sigma: 0.7 * artPixelsPerCameraPixel)
                .cropped(to: artExtent)
            // The shadow sits 2 percent of the art's height below it and spreads 1.5 percent, at 35 percent black.
            let shadowSpread = artHeight * 0.015
            let shadowOffset = -artHeight * 0.02
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                .cropped(to: artExtent.offsetBy(dx: 0, dy: shadowOffset))
                .applyingGaussianBlur(sigma: shadowSpread)
                .cropped(to: artExtent.offsetBy(dx: 0, dy: shadowOffset).insetBy(dx: -3 * shadowSpread, dy: -3 * shadowSpread))
            self.placedArt = PlacedArt(litArt: litArt, shadow: shadow, keyframeCorners: corners)
            self.smoothedArtCorners = nil
            self.theWallIsLostAsLastReported = false
            self.trackerBeforeTheMove = nil
            self.placedArtBeforeTheMove = nil
        }
    }

    /// The loop where the wall last was, for the panel to draw or fade out.
    func currentLoop() -> RoomArtLoopSnapshot? {
        latestLoop.withLock { $0 }
    }

    /// A click's measurement failed, so the art goes back where it hung, tracked against the keyframe it hung on. That
    /// tracker aligns each frame to its own keyframe, so it finds the room again after the frames it missed. The loop
    /// outlined the failed keyframe, so it stops following the room and fades out where it was.
    func putBackTheArtFromBeforeTheMove() {
        processingQueue.async {
            self.loopKeyframeCorners = nil
            guard let placedArtBeforeTheMove = self.placedArtBeforeTheMove else { return }
            self.tracker = self.trackerBeforeTheMove
            self.placedArt = placedArtBeforeTheMove
            self.smoothedArtCorners = nil
            self.theWallIsLostAsLastReported = false
            self.trackerBeforeTheMove = nil
            self.placedArtBeforeTheMove = nil
        }
    }
}

// MARK: - Reading the page

/// The page in Chrome's front tab, as `POST /try-it-item` reads it.
nonisolated struct RoomArtFrontTab: Equatable, Sendable {
    let url: String
    let title: String
    /// Nil when the page's script could not run, such as on a page with an open `alert()`, so no size can be read.
    let text: String?
}

/// The front tab's address, title, and text, the text cut to what `POST /try-it-item` takes. Nil when Chrome has no window.
/// The script has no double quotes or backslashes, since it runs inside an AppleScript string.
@MainActor
func readTheFrontTabForRoomArt() -> RoomArtFrontTab? {
    guard let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow() else { return nil }
    let pageText = try? ChromeVideoTab.runJavaScript(
        "document.body ? document.body.innerText.slice(0, \(RoomArtPageRequest.longestPageText)) : ''",
        in: frontTab
    )
    return RoomArtFrontTab(url: frontTab.url, title: frontTab.title, text: pageText)
}

/// What Clicky says when the front tab has no picture to hang.
nonisolated let roomArtNoPictureLine = "I don't see a picture in Chrome's front tab."

// MARK: - Controller

/// Shows and hides the panel, so tests need no window.
@MainActor
protocol RoomArtPanelPresenting: AnyObject {
    func show()
    func hide()
}

@MainActor
final class RoomArtPreviewController: ObservableObject {
    /// Everything the controller reaches outside itself, so a test can stand in for Chrome, the Worker, the camera, and
    /// the voice.
    struct Environment {
        /// Both Worker routes need the app secret, so with none set the camera never opens.
        var appSecretIsSet: () -> Bool
        var readTheFrontTab: () -> RoomArtFrontTab?
        var capturePicture: () async -> RoomArtPicture?
        var readThePage: (RoomArtPageRequest) async throws -> RoomArtPageReading
        var measureTheWall: (RoomWallRequest) async throws -> WallPlane
        var makeFrameSource: () -> RoomFrameSource
        /// Clears a scene or pop-out on screen, whose window sits above the panel's and would hide it.
        var clearTheLiveScene: () -> Void
        /// Says a line. `isAFailure` says the line reports something that went wrong, so the cursor shakes as Clicky says it.
        var speak: (_ line: String, _ isAFailure: Bool) -> Void
        /// The theme's accent, which Clicky's loop is drawn in. Read each time the panel draws it.
        var loopAccentColor: () -> Color
        /// Runs on every close, from Escape, the Close button, or a new request, so a line about this panel that is
        /// still waiting or playing ends with it.
        var endTheSpokenLine: () -> Void

        /// Chrome, the Worker at `workerBaseURL`, the app's defaults for the secret, and the camera (or a Debug build's
        /// `--room-camera-file`).
        static func live(
            workerBaseURL: String,
            capturePicture: @escaping () async -> RoomArtPicture?,
            clearTheLiveScene: @escaping () -> Void,
            speak: @escaping (String, Bool) -> Void,
            loopAccentColor: @escaping () -> Color,
            endTheSpokenLine: @escaping () -> Void
        ) -> Environment {
            let roomArtClient = RoomArtClient(workerBaseURL: workerBaseURL)
            return Environment(
                appSecretIsSet: { ClickyAppSecret.isSet() },
                readTheFrontTab: readTheFrontTabForRoomArt,
                capturePicture: capturePicture,
                readThePage: { pageRequest in try await roomArtClient.readThePage(pageRequest) },
                measureTheWall: { wallRequest in try await roomArtClient.measureTheWall(wallRequest) },
                makeFrameSource: { makeRoomFrameSource() },
                clearTheLiveScene: clearTheLiveScene,
                speak: speak,
                loopAccentColor: loopAccentColor,
                endTheSpokenLine: endTheSpokenLine
            )
        }
    }

    @Published private(set) var phase = RoomArtPhase.closed {
        didSet { loopState = loopState.after(phaseChangedTo: phase, at: ProcessInfo.processInfo.systemUptime) }
    }
    /// Clicky's loop around the wall spot: drawn from the keyframe until the art shows or the measurement fails.
    @Published private(set) var loopState = RoomArtLoopState.hidden
    /// The tracker lost the room long enough to hide the art, so the status line says so.
    @Published private(set) var theWallIsLost = false

    private let environment: Environment
    private let frameProcessor: RoomArtFrameProcessing
    private var injectedPanelPresenter: RoomArtPanelPresenting?
    private lazy var panelPresenter: RoomArtPanelPresenting = injectedPanelPresenter
        ?? RoomArtPanelController(previewController: self, metalLayer: frameProcessor.metalLayer)
    private let flatteningContext = CIContext()

    private var frameSource: RoomFrameSource?
    private var pageRequest: RoomArtPageRequest?
    private var pictureImage: CGImage?
    private var measurementTask: Task<Void, Never>?
    private var lastMeasurementNumber = 0
    /// Each open counts up, so an await that resumes after the panel closed or reopened changes nothing.
    private var openingNumber = 0
    /// The page and its picture are being read before the panel opens, so Escape has a request to stop.
    private var anOpeningIsUnderway = false
    private var hereItIsWasSaid = false

    /// With no presenter, the real panel shows, and with no frame processor, the real one draws it.
    init(environment: Environment, frameProcessor: RoomArtFrameProcessing = RoomArtFrameProcessor(), panelPresenter: RoomArtPanelPresenting? = nil) {
        self.environment = environment
        self.frameProcessor = frameProcessor
        injectedPanelPresenter = panelPresenter
    }

    var isOpen: Bool { phase.isOpen }

    /// The theme's accent, which the panel draws the loop in.
    var loopAccentColor: Color { environment.loopAccentColor() }

    /// The loop's line as the panel draws it this moment, in panel points, or nil before there is a keyframe or a camera frame.
    func currentLoopOutline(cameraSize: CGSize, panelSize: CGSize) -> Path? {
        guard let snapshot = frameProcessor.currentLoop() else { return nil }
        return RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraSize, viewSize: panelSize))
    }

    /// The loop's fade-out has run.
    func theLoopFadeFinished() {
        loopState = loopState.afterTheFadeFinished()
    }

    /// Reads the page and its picture, opens the panel, and starts the camera. `learnerRequest` is what the learner said, which
    /// tells the Worker which item they mean when the page shows several. The measurement starts on the first frame
    /// with a person mask. Returns once the camera runs or failed. Everything that can fail before the camera does, a
    /// missing app secret, a page that is not https, and page text that cannot be read, is checked first, so the camera
    /// never opens for a request the Worker would refuse.
    func showTheArtInTheRoom(learnerRequest: String) async {
        if isOpen { close() }
        openingNumber += 1
        let thisOpening = openingNumber
        anOpeningIsUnderway = true
        defer { if thisOpening == openingNumber { anOpeningIsUnderway = false } }

        guard environment.appSecretIsSet() else {
            environment.speak(RoomArtFailure.appSecretMissing.spokenLine, true)
            return
        }
        guard let frontTab = environment.readTheFrontTab() else {
            environment.speak(roomArtNoPictureLine, true)
            return
        }
        guard frontTab.url.lowercased().hasPrefix("https://") else {
            environment.speak(RoomArtFailure.pageNotHTTPS.spokenLine, true)
            return
        }
        guard let pageText = frontTab.text, !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            environment.speak(RoomArtFailure.pageNotRead.spokenLine, true)
            return
        }
        // The picture is captured before the panel opens, since the panel covers the screen.
        let picture = await environment.capturePicture()
        // Escape or a new request moved the opening number on, and a push-to-talk press cancelled this task, so the
        // learner moved on and nothing opens or speaks.
        guard thisOpening == openingNumber, !Task.isCancelled else { return }
        guard let picture,
              let pictureSource = CGImageSourceCreateWithData(picture.jpegData as CFData, nil),
              let pictureImage = CGImageSourceCreateImageAtIndex(pictureSource, 0, nil) else {
            environment.speak(roomArtNoPictureLine, true)
            return
        }
        self.pictureImage = pictureImage
        pageRequest = RoomArtPageRequest(pageURL: frontTab.url, pageTitle: frontTab.title, pageText: pageText, learnerRequest: learnerRequest, picture: picture)
        hereItIsWasSaid = false
        theWallIsLost = false
        environment.clearTheLiveScene()
        phase = phase.opening()
        panelPresenter.show()

        frameProcessor.startASession(
            onFirstSegmentedFrame: { [weak self] in
                Task { @MainActor in
                    guard let self, thisOpening == self.openingNumber else { return }
                    self.startAMeasurement(anchorInCameraPixels: nil)
                }
            },
            onTheWallLostOrFound: { [weak self] wallIsLost in
                Task { @MainActor in
                    guard let self, thisOpening == self.openingNumber else { return }
                    self.theWallIsLost = wallIsLost
                }
            }
        )
        let frameSource = environment.makeFrameSource()
        self.frameSource = frameSource
        let frameProcessor = frameProcessor
        do {
            try await frameSource.start(deliveringFramesOn: frameProcessor.processingQueue) { cameraFrame in
                frameProcessor.process(cameraFrame)
            }
            // A close during the start, such as while macOS asks for camera access, stopped this source before it ran,
            // so it stops itself now that it runs.
            if thisOpening != openingNumber { frameSource.stop() }
        } catch {
            guard thisOpening == openingNumber else { return }
            let failure: RoomArtFailure
            switch error as? RoomCameraError {
            case .cameraAccessDenied: failure = .cameraAccessDenied
            case .noCamera: failure = .noCamera
            default:
                print("Room art: the camera did not start: \(error)")
                failure = .noCamera
            }
            apply(phase.afterTheCameraFailed(failure))
        }
    }

    /// Escape closes the panel when it is open, or stops a request still reading the page and its picture, ahead of any
    /// scene behavior.
    func closeOnEscape() -> Bool {
        guard isOpen || anOpeningIsUnderway else { return false }
        close()
        return true
    }

    /// Every close goes through here, the Close button's included, so the camera and the spoken line always stop together.
    func close() {
        environment.endTheSpokenLine()
        openingNumber += 1
        anOpeningIsUnderway = false
        measurementTask?.cancel()
        measurementTask = nil
        frameSource?.stop()
        frameSource = nil
        frameProcessor.endTheSession()
        panelPresenter.hide()
        pageRequest = nil
        pictureImage = nil
        theWallIsLost = false
        phase = phase.closing()
    }

    /// A click on the video moves the art there: a new keyframe and a new wall measurement. A click during a measurement,
    /// or before the art shows, changes nothing. A click after a failed move tries again.
    func moveTheArt(toCameraPixel cameraPixel: CGPoint) {
        guard case .showing = phase else { return }
        startAMeasurement(anchorInCameraPixels: cameraPixel)
    }

    private func startAMeasurement(anchorInCameraPixels: CGPoint?) {
        lastMeasurementNumber += 1
        let measurementID = RoomArtMeasurementID(number: lastMeasurementNumber)
        let measuringPhase = phase.startingAMeasurement(id: measurementID)
        guard measuringPhase != phase else { return }
        phase = measuringPhase
        theWallIsLost = false
        // A move keeps the art it read, and the first measurement reads it.
        let artworkIsAlreadyRead: Bool
        if case .moving = measuringPhase { artworkIsAlreadyRead = true } else { artworkIsAlreadyRead = false }

        measurementTask = Task {
            guard let keyframe = await frameProcessor.takeAKeyframe(anchorInCameraPixels: anchorInCameraPixels) else {
                apply(phase.afterTheMeasurementFailed(.wallNotMeasured, measurementID: measurementID))
                return
            }
            guard !Task.isCancelled else { return }
            // The wall does not depend on the art, so Depth Pro measures it while Claude reads the page, and the wait is
            // the longer of the two, not the sum.
            await withTaskGroup(of: Void.self) { measurementGroup in
                measurementGroup.addTask { @MainActor in
                    await self.measureTheWall(keyframe: keyframe, measurementID: measurementID)
                }
                if !artworkIsAlreadyRead {
                    measurementGroup.addTask { @MainActor in
                        await self.readTheArt(measurementID: measurementID)
                    }
                }
            }
        }
    }

    private func measureTheWall(keyframe: RoomArtKeyframe, measurementID: RoomArtMeasurementID) async {
        do {
            let wall = try await environment.measureTheWall(keyframe.wallRequest)
            guard !Task.isCancelled else { return }
            print(String(format: "Room art: wall %.2f m away at %.0f degrees, %.0f%% of it fits the plane", wall.distanceMeters, wall.wallAngleDegrees, wall.planeInlierShare * 100))
            apply(phase.withWallMeasured(wall, measurementID: measurementID))
        } catch {
            guard !Task.isCancelled else { return }
            print("Room art: the wall was not measured: \(error)")
            apply(phase.afterTheMeasurementFailed(roomArtFailure(forAFailedWallMeasurement: error), measurementID: measurementID))
        }
    }

    private func readTheArt(measurementID: RoomArtMeasurementID) async {
        guard let pageRequest, let pictureImage else { return }
        do {
            let pageReading = try await environment.readThePage(pageRequest)
            guard !Task.isCancelled else { return }
            switch pageReading {
            case .other(let title):
                print("Room art: \"\(title)\" is not wall art, furniture, or clothing")
                apply(phase.afterTheMeasurementFailed(.notWallArt, measurementID: measurementID))
            case .furniture(let furnitureReading):
                print("Room art: \"\(furnitureReading.title)\" is furniture, which is not placed yet")
                apply(phase.afterTheMeasurementFailed(.onlyWallArtSoFar, measurementID: measurementID))
            case .clothing(let clothingReading):
                print("Room art: \"\(clothingReading.title)\" is clothing, which is not placed yet")
                apply(phase.afterTheMeasurementFailed(.onlyWallArtSoFar, measurementID: measurementID))
            case .sizeNotOnThePage(let title):
                print("Room art: the page for \"\(title)\" states no size")
                apply(phase.afterTheMeasurementFailed(.sizeNotOnThePage, measurementID: measurementID))
            case .wallArt(let wallArtReading):
                guard let flattenedImage = flattenedArtwork(
                    picture: pictureImage,
                    corners: wallArtReading.artworkCorners,
                    size: wallArtReading.chosenSize,
                    context: flatteningContext
                ) else {
                    apply(phase.afterTheMeasurementFailed(.pageNotRead, measurementID: measurementID))
                    return
                }
                print("Room art: \"\(wallArtReading.title)\" at \(wallArtReading.chosenSize.label), because \(wallArtReading.whyThisSize)")
                let artwork = RoomArtwork(
                    title: wallArtReading.title,
                    widthMeters: wallArtReading.chosenSize.widthCentimeters / 100,
                    heightMeters: wallArtReading.chosenSize.heightCentimeters / 100,
                    includesFrame: wallArtReading.chosenSizeIncludesFrame,
                    flattenedImage: flattenedImage
                )
                apply(phase.withArtworkRead(artwork, measurementID: measurementID))
            }
        } catch {
            guard !Task.isCancelled else { return }
            print("Room art: the page was not read: \(error)")
            apply(phase.afterTheMeasurementFailed(roomArtFailure(forAFailedPageRead: error), measurementID: measurementID))
        }
    }

    /// Moves to `newPhase` and does what entering it means: hang the art when it shows, put it back when a move failed,
    /// and say why when the panel fails.
    private func apply(_ newPhase: RoomArtPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        switch newPhase {
        case .showing(let artwork, let wall, let moveFailure):
            theWallIsLost = false
            if let moveFailure {
                // The camera keeps running and only the status line says why, since the learner is looking at the panel.
                print("Room art: the art stays where it was, since the move failed: \(moveFailure)")
                frameProcessor.putBackTheArtFromBeforeTheMove()
                return
            }
            // The phase's transitions show the art only on a wall where its corners land, so this always places it.
            guard let keyframeCorners = wall.keyframeCorners(widthMeters: artwork.widthMeters, heightMeters: artwork.heightMeters) else { return }
            frameProcessor.showTheArt(artwork.flattenedImage, keyframeCorners: keyframeCorners)
            if !hereItIsWasSaid {
                hereItIsWasSaid = true
                environment.speak("Here it is at \(artwork.sizeInWords).", false)
            }
        case .failed(let failure):
            // The panel keeps its last frame and says what went wrong until the learner closes it.
            frameSource?.stop()
            frameSource = nil
            frameProcessor.endTheSession()
            environment.speak(failure.spokenLine, true)
        case .closed, .startingCamera, .measuring, .moving:
            break
        }
    }
}

// MARK: - Panel

@MainActor
final class RoomArtPanelController: RoomArtPanelPresenting {
    static let panelSize = CGSize(width: 960, height: 540)

    private weak var previewController: RoomArtPreviewController?
    private let metalLayer: CAMetalLayer
    private var panel: NonKeyFloatingPanel?

    init(previewController: RoomArtPreviewController, metalLayer: CAMetalLayer) {
        self.previewController = previewController
        self.metalLayer = metalLayer
    }

    /// Shows the panel centered on the screen under the mouse.
    func show() {
        guard let previewController else { return }
        let panel = panel ?? makePanel(previewController: previewController)
        self.panel = panel
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            panel.setFrameOrigin(CGPoint(
                x: visibleFrame.midX - Self.panelSize.width / 2,
                y: visibleFrame.midY - Self.panelSize.height / 2
            ))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel(previewController: RoomArtPreviewController) -> NonKeyFloatingPanel {
        let panel = NonKeyFloatingPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        let hostingView = FirstMouseHostingView(rootView: RoomArtPanelView(previewController: previewController, metalLayer: metalLayer))
        hostingView.frame = CGRect(origin: .zero, size: Self.panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        return panel
    }
}

private struct RoomArtPanelView: View {
    @ObservedObject var previewController: RoomArtPreviewController
    let metalLayer: CAMetalLayer
    @State private var closeButtonIsHovered = false

    var body: some View {
        ZStack {
            DS.Colors.background
            RoomArtVideoView(metalLayer: metalLayer) { cameraPixel in
                previewController.moveTheArt(toCameraPixel: cameraPixel)
            }
            if !previewController.loopState.isHidden {
                RoomArtLoopView(
                    state: previewController.loopState,
                    color: previewController.loopAccentColor,
                    outlineProvider: {
                        previewController.currentLoopOutline(cameraSize: metalLayer.drawableSize, panelSize: RoomArtPanelController.panelSize)
                    },
                    onFadeFinished: { previewController.theLoopFadeFinished() }
                )
            }
            // The layer still holds the last session's frame until the camera's first one, so it stays covered until then.
            if previewController.phase == .startingCamera {
                DS.Colors.background
            }
            if case .failed = previewController.phase {
                Color.black.opacity(0.45).allowsHitTesting(false)
            }
            VStack {
                HStack {
                    Spacer()
                    closeButton
                }
                Spacer()
                statusLine
            }
            .padding(16)
        }
        .frame(width: RoomArtPanelController.panelSize.width, height: RoomArtPanelController.panelSize.height)
    }

    private var closeButton: some View {
        Button {
            previewController.close()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Colors.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(closeButtonIsHovered ? DS.Colors.surface4 : DS.Colors.surface2.opacity(0.85)))
                .overlay(Circle().stroke(DS.Colors.borderSubtle, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .hoverAndPointer { isHovered in closeButtonIsHovered = isHovered }
        .accessibilityLabel("Close")
    }

    @ViewBuilder
    private var statusLine: some View {
        let statusText = previewController.phase.statusLine(theWallIsLost: previewController.theWallIsLost)
        if !statusText.isEmpty {
            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(previewController.phase.statusLineIsAFailure(theWallIsLost: previewController.theWallIsLost) ? DS.Colors.destructiveText : DS.Colors.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(DS.Colors.background.opacity(0.82)))
                .overlay(Capsule().stroke(DS.Colors.borderSubtle, lineWidth: 1))
                .allowsHitTesting(false)
        }
    }
}

/// The video, drawn by the frame processor into its Metal layer. A click reports the camera pixel under it.
private struct RoomArtVideoView: NSViewRepresentable {
    let metalLayer: CAMetalLayer
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RoomArtVideoNSView {
        RoomArtVideoNSView(metalLayer: metalLayer, onClick: onClick)
    }

    func updateNSView(_ videoView: RoomArtVideoNSView, context: Context) {
        videoView.onClick = onClick
    }
}

final class RoomArtVideoNSView: NSView {
    private let metalLayer: CAMetalLayer
    var onClick: (CGPoint) -> Void
    private var crosshairTrackingArea: NSTrackingArea?

    init(metalLayer: CAMetalLayer, onClick: @escaping (CGPoint) -> Void) {
        self.metalLayer = metalLayer
        self.onClick = onClick
        super.init(frame: .zero)
        // A layer-hosting view: the processor's Metal layer is this view's own layer.
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("RoomArtVideoNSView is made in code")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The crosshair says a click places the art there. The panel never becomes key, so cursor rects never apply, and an
    /// always-active tracking area sets the cursor instead, as `hoverAndPointer` does.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let crosshairTrackingArea {
            removeTrackingArea(crosshairTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        crosshairTrackingArea = trackingArea
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let pointInView = convert(event.locationInWindow, from: nil)
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0, bounds.width > 0, bounds.height > 0 else { return }
        // The video is fit inside the view keeping its shape, so the click is measured inside the fitted rect.
        let fitScale = min(bounds.width / drawableSize.width, bounds.height / drawableSize.height)
        let fittedSize = CGSize(width: drawableSize.width * fitScale, height: drawableSize.height * fitScale)
        let fittedOrigin = CGPoint(x: (bounds.width - fittedSize.width) / 2, y: (bounds.height - fittedSize.height) / 2)
        let cameraPixel = CGPoint(
            x: (pointInView.x - fittedOrigin.x) / fitScale,
            // The view's y grows up and the camera's grows down.
            y: (fittedOrigin.y + fittedSize.height - pointInView.y) / fitScale
        )
        // A pixel at the frame's width or height is past its last pixel, which the depth service refuses as an anchor.
        guard cameraPixel.x >= 0, cameraPixel.y >= 0, cameraPixel.x < drawableSize.width, cameraPixel.y < drawableSize.height else { return }
        onClick(cameraPixel)
    }
}
