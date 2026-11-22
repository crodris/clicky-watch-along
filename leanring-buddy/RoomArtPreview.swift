//
//  RoomArtPreview.swift
//  leanring-buddy
//
//  Runs and draws "show me how this would look in my room" and "could I see this shirt on me". `RoomArtPreviewController`
//  reads the page's picture, opens the panel, starts the camera, and asks the Worker what the page shows
//  (`POST /try-it-item`) at once. The item's kind picks the rest: wall art is measured on the wall (`POST /room-wall`) and
//  furniture on the floor (`POST /room-floor`), each from a keyframe taken on the first frame with a person mask, with
//  Clicky's loop around the spot while it waits, and a flat lay top is cut out of its photo and drawn over the learner's
//  own shirt with no measurement. `RoomArtFrameProcessor` handles every camera frame on its own queue: it finds the person,
//  tracks the room against the keyframe, and draws the frame with the item on its surface and the learner in front of it,
//  or, for a shirt, finds the learner's torso and draws the shirt on them.
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

/// The frame a measurement is made on, as the wall and floor requests need it, and the room's light around the spot.
nonisolated struct RoomArtKeyframe: Sendable {
    let measurementRequest: RoomWallRequest
    let wallLight: RoomArtWallLight
    /// The barest wall spot in this keyframe, where furniture's wall is measured: the wall checks that a measured floor is
    /// level, and stands the piece against it when the camera sees no floor. Nil when the frame processor did not find one.
    var wallSpotAnchor: CGPoint? = nil
    /// Counts up with each keyframe the processor takes, so a render made for one keyframe is never drawn on another.
    var keyframeNumber = 0
    /// The keyframe's texture with the person marked, which furniture's spot choice reads to prefer bare floor.
    var floorTexture: RoomFloorTextureMap? = nil
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
    func startASession(onFirstSegmentedFrame: @escaping @Sendable () -> Void, onTheSurfaceLostOrFound: @escaping @Sendable (Bool) -> Void)
    func endTheSession()
    func process(_ cameraFrame: CVPixelBuffer)
    /// With no anchor, the spot is the bare wall spot for the wall and the bare floor spot for the floor.
    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe?
    func showTheItem(_ itemImage: CGImage, keyframeCorners: RoomArtCorners, on surfaceKind: RoomArtSurfaceKind)
    /// Replaces the furniture's flat cutout with layers rendered or painted for the keyframe numbered `keyframeNumber`, with
    /// a short crossfade. Layers for an older keyframe, such as one a click has replaced, are dropped.
    func showTheFurnitureLayers(_ layers: RoomFurnitureKeyframeLayers, keyframeNumber: Int)
    /// Moves the loop to the window around `point` in the keyframe numbered `keyframeNumber`, such as the spot the furniture
    /// moved to after its floor was measured. The loop glides there, and a newer keyframe's loop is left alone.
    func outlineTheLoop(around point: CGPoint, on surfaceKind: RoomArtSurfaceKind, inKeyframeNumber keyframeNumber: Int)
    func putBackTheItemFromBeforeTheMove()
    /// Starts drawing a shirt instead of tracking a surface: each frame finds the torso, and `onTheFramingSettled` runs on
    /// the main actor each time the framing settles on a new kind (`ShirtFramingDebouncer`). The loop traces the torso.
    func startTheShirtTryOn(onTheFramingSettled: @escaping @Sendable (ShirtFramingKind) -> Void)
    /// The garment to draw on every frame where the framing has settled on ready.
    func wearTheGarment(_ garment: ShirtGarment)
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
    private var onTheSurfaceLostOrFound: (@Sendable (Bool) -> Void)?
    /// Whether the last report said the room was lost, so each change is reported once.
    private var theSurfaceIsLostAsLastReported = false
    private var latestFrame: CVPixelBuffer?
    private var latestPersonMask: CVPixelBuffer?
    /// The lowest row the newest person mask reaches, as a share of the frame's height, or nil with no person in it.
    private var latestPersonLowestRowShare: Double?
    /// A frame is being segmented, so the next frames skip segmentation until it is done.
    private var segmentationIsRunning = false
    private var latestTrackGrayscale: RoomGrayscaleImage?
    private var latestTrackRoomMask: [Float]?
    private var tracker: RoomTracker?
    private var keyframeWallLight = RoomArtWallLight.neutral
    private var placedArt: PlacedArt?
    /// The drawing the furniture's layers replaced and when, faded out over `crossfadeSeconds` so the better look arrives
    /// softly instead of popping.
    private var crossfadeFrom: (placedArt: PlacedArt, startedAt: CFTimeInterval)?
    private static let crossfadeSeconds = 0.5
    /// The number of the newest keyframe, which `showTheFurnitureLayers` checks.
    private var keyframeNumber = 0
    /// The tracker, the item, and the keyframe number from before a click's keyframe, put back when that move's
    /// measurement fails.
    private var trackerBeforeTheMove: RoomTracker?
    private var placedArtBeforeTheMove: PlacedArt?
    private var keyframeNumberBeforeTheMove = 0
    /// The shirt try-on, on while the item is a top. The pose tracker and the renderer belong to this queue's session,
    /// and the renderer is only ever called from this queue.
    private var shirtTryOnIsOn = false
    private let shirtPoseTracker = ShirtPoseTracker()
    private let shirtRenderer: ShirtTryOnRenderer
    private var shirtGarment: ShirtGarment?
    private var shirtFramingDebouncer = ShirtFramingDebouncer()
    private var onTheShirtFramingSettled: (@Sendable (ShirtFramingKind) -> Void)?
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

    /// The item as it is drawn on every frame: already lit like the room and softened like the camera, with its shadow.
    private struct PlacedArt {
        enum Drawing {
            /// A picture warped onto its four corners: wall art, or furniture's flat cutout.
            case warpedOntoItsCorners(litArt: CIImage, shadow: CIImage)
            /// Furniture rendered or painted over the whole keyframe, moved with the room by the tracker's warp.
            case keyframeLayers(item: CIImage, shadow: CIImage?, grainStandardDeviation: Double)
        }
        let drawing: Drawing
        /// The keyframe points the tracker moves each frame: the item's corners, or the frame's corners for keyframe layers.
        let keyframeCorners: [CGPoint]
        /// Where furniture stands on the floor in the keyframe, which decides whether it draws over the learner. Nil for
        /// wall art, which is always behind them.
        let keyframeBasePoint: CGPoint?
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
        shirtRenderer = ShirtTryOnRenderer(ciContext: ciContext)
    }

    /// Forgets the last session, so a reopened panel starts with no keyframe, no item, and no shirt. `onFirstSegmentedFrame`
    /// runs once, on the main actor, when the first frame with a person mask has arrived. `onTheSurfaceLostOrFound` runs on
    /// the main actor each time the tracker loses the room long enough to hide the item (true), and when it finds it again
    /// (false).
    func startASession(onFirstSegmentedFrame: @escaping @Sendable () -> Void, onTheSurfaceLostOrFound: @escaping @Sendable (Bool) -> Void) {
        processingQueue.sync {
            sessionNumber += 1
            self.onFirstSegmentedFrame = onFirstSegmentedFrame
            self.onTheSurfaceLostOrFound = onTheSurfaceLostOrFound
            theSurfaceIsLostAsLastReported = false
            shirtTryOnIsOn = false
            shirtGarment = nil
            shirtFramingDebouncer = ShirtFramingDebouncer()
            onTheShirtFramingSettled = nil
            shirtPoseTracker.reset()
            shirtRenderer.reset()
            trackerBeforeTheMove = nil
            placedArtBeforeTheMove = nil
            crossfadeFrom = nil
            latestFrame = nil
            latestPersonMask = nil
            latestPersonLowestRowShare = nil
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
            self.onTheSurfaceLostOrFound = nil
            self.onTheShirtFramingSettled = nil
            self.placedArt = nil
            self.crossfadeFrom = nil
            self.shirtTryOnIsOn = false
            self.shirtGarment = nil
        }
    }

    func startTheShirtTryOn(onTheFramingSettled: @escaping @Sendable (ShirtFramingKind) -> Void) {
        processingQueue.async {
            self.shirtTryOnIsOn = true
            self.onTheShirtFramingSettled = onTheFramingSettled
        }
    }

    func wearTheGarment(_ garment: ShirtGarment) {
        processingQueue.async {
            guard self.shirtTryOnIsOn else { return }
            self.shirtGarment = garment
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

        // The shirt follows the body, not the room: the torso comes from the pose tracker, and the loop traces it.
        var shirtTorsoToDraw: BodyTorso?
        if shirtTryOnIsOn {
            shirtTorsoToDraw = torsoForTheShirt(in: cameraFrame, frameSize: CGSize(width: frameWidth, height: frameHeight))
        }

        var artCorners: [CGPoint]?
        var fadingArtCorners: [CGPoint]?
        if let placedArt, let trackStep {
            reportWhetherTheSurfaceIsLost(trackStep.theArtIsHidden)
            if !trackStep.theArtIsHidden, let cameraWarp {
                let currentCorners = placedArt.keyframeCorners.map(cameraWarp.apply)
                artCorners = smoothedCorners(previous: smoothedArtCorners, current: currentCorners)
                smoothedArtCorners = artCorners
                // The drawing fading out follows the same warp, unsmoothed for its half second.
                fadingArtCorners = crossfadeFrom?.placedArt.keyframeCorners.map(cameraWarp.apply)
            }
        }
        // A frame that found no drawable was not shown, so it does not count toward the frame rate.
        if draw(cameraFrame: cameraFrame, artCorners: artCorners, fadingArtCorners: fadingArtCorners, shirtTorso: shirtTorsoToDraw) {
            noteTheFrame(trackMilliseconds: trackMilliseconds)
        }
    }

    /// The torso the shirt is drawn on this frame, or nil when it is not drawn. The framing is assessed every frame, but the
    /// shirt is drawn only once the debounced framing has settled on ready, so a learner at the edge of a threshold does not
    /// make it flicker. Each settled change goes to the main actor, and the loop traces the torso whenever there is one.
    private func torsoForTheShirt(in cameraFrame: CVPixelBuffer, frameSize: CGSize) -> BodyTorso? {
        let now = CACurrentMediaTime()
        let torso = shirtPoseTracker.torso(forFrame: cameraFrame, atTime: now)
        let framing = ShirtFraming.assess(torso: torso, frameSize: frameSize)
        if let settledKind = shirtFramingDebouncer.advance(to: ShirtFramingKind(framing), at: now), let onTheShirtFramingSettled {
            DispatchQueue.main.async { onTheShirtFramingSettled(settledKind) }
        }
        let torsoLoop = torso.flatMap(RoomArtLoopGeometry.torsoLoop(of:))
        latestLoop.withLock { $0 = torsoLoop }
        guard shirtFramingDebouncer.settledKind == .ready else { return nil }
        return torso
    }

    /// Tells the main actor when the item hides because the room is lost, and when it shows again, once per change.
    private func reportWhetherTheSurfaceIsLost(_ theSurfaceIsLost: Bool) {
        guard theSurfaceIsLost != theSurfaceIsLostAsLastReported else { return }
        theSurfaceIsLostAsLastReported = theSurfaceIsLost
        guard let onTheSurfaceLostOrFound else { return }
        DispatchQueue.main.async { onTheSurfaceLostOrFound(theSurfaceIsLost) }
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
            let personLowestRowShare = personMask.flatMap(lowestPersonRowShare(in:))
            self.processingQueue.async {
                self.segmentationIsRunning = false
                // A mask from a closed panel's frame never reaches the next one.
                guard sessionWhenStarted == self.sessionNumber else { return }
                if let personMask {
                    self.latestPersonMask = personMask
                    self.latestPersonLowestRowShare = personLowestRowShare
                }
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
        // Logged only while the item or the shirt shows, since that is when every stage runs.
        if placedArt != nil || shirtGarment != nil {
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
    private func draw(cameraFrame: CVPixelBuffer, artCorners: [CGPoint]?, fadingArtCorners: [CGPoint]?, shirtTorso: BodyTorso?) -> Bool {
        let frameImage = CIImage(cvPixelBuffer: cameraFrame)
        var composedImage = frameImage
        if let placedArt, let artCorners, let latestPersonMask {
            composedImage = frameWithTheArt(frameImage: frameImage, placedArt: placedArt, artCorners: artCorners, personMask: latestPersonMask)
            if let crossfadeFrom, let fadingArtCorners {
                let fadeProgress = (CACurrentMediaTime() - crossfadeFrom.startedAt) / Self.crossfadeSeconds
                if fadeProgress >= 1 {
                    self.crossfadeFrom = nil
                } else {
                    let fadingImage = frameWithTheArt(frameImage: frameImage, placedArt: crossfadeFrom.placedArt, artCorners: fadingArtCorners, personMask: latestPersonMask)
                    composedImage = fadingImage.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: composedImage,
                        kCIInputTimeKey: max(0, fadeProgress),
                    ])
                }
            }
        } else if let shirtTorso, let shirtGarment, let latestPersonMask {
            // The renderer reads the mask's values as they are, which a mask tagged with no color space keeps.
            let personMask = CIImage(cvPixelBuffer: latestPersonMask, options: [.colorSpace: NSNull()])
            composedImage = shirtRenderer.composite(frame: frameImage, personMask: personMask, torso: shirtTorso, garment: shirtGarment)
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

    /// The item over the frame where the tracker put `artCorners` (camera pixels, y down), with the person drawn back on top
    /// through the segmentation mask, so the learner stays in front of it, unless furniture stands nearer the camera than
    /// the learner's feet (`roomFurnitureDrawsOverThePerson`).
    private func frameWithTheArt(frameImage: CIImage, placedArt: PlacedArt, artCorners: [CGPoint], personMask: CVPixelBuffer) -> CIImage {
        let itemOverTheFrame: CIImage
        switch placedArt.drawing {
        case .warpedOntoItsCorners(let litArt, let shadow):
            itemOverTheFrame = pictureWarpedOntoItsCorners(frameImage: frameImage, litArt: litArt, shadow: shadow, artCorners: artCorners)
        case .keyframeLayers(let item, let shadow, let grainStandardDeviation):
            guard let keyframeToCurrent = RoomFurnitureComposition.keyframeToCurrentFrame(
                keyframePoints: placedArt.keyframeCorners, currentPoints: artCorners, frameHeight: frameImage.extent.height
            ) else { return frameImage }
            itemOverTheFrame = RoomFurnitureComposition.frameWithTheFurniture(
                frame: frameImage,
                itemLayer: item,
                shadowLayer: shadow,
                keyframeToCurrent: keyframeToCurrent,
                grainStandardDeviation: grainStandardDeviation,
                // A new offset each frame, so the grain moves like the camera's own.
                grainOffset: CGPoint(x: Double.random(in: 0..<512), y: Double.random(in: 0..<512))
            )
        }
        if let keyframeBasePoint = placedArt.keyframeBasePoint,
           let currentBasePoint = currentPoint(of: keyframeBasePoint, keyframeCorners: placedArt.keyframeCorners, currentCorners: artCorners),
           roomFurnitureDrawsOverThePerson(itemBaseRow: currentBasePoint.y, personLowestRow: latestPersonLowestRowShare.map { $0 * frameImage.extent.height }) {
            return itemOverTheFrame
        }
        return withThePersonOnTop(of: itemOverTheFrame, frameImage: frameImage, personMask: personMask)
    }

    /// Where a keyframe point is now, through the affine map the tracked corners give, in camera pixels with y down.
    private func currentPoint(of keyframePoint: CGPoint, keyframeCorners: [CGPoint], currentCorners: [CGPoint]) -> CGPoint? {
        // The map works in Core Image's y-up space, so the point goes in and comes back out with y flipped about 0.
        guard let keyframeToCurrent = RoomFurnitureComposition.keyframeToCurrentFrame(keyframePoints: keyframeCorners, currentPoints: currentCorners, frameHeight: 0) else { return nil }
        let movedPoint = CGPoint(x: keyframePoint.x, y: -keyframePoint.y).applying(keyframeToCurrent)
        return CGPoint(x: movedPoint.x, y: -movedPoint.y)
    }

    /// The picture and its shadow warped onto `artCorners`, over the frame.
    private func pictureWarpedOntoItsCorners(frameImage: CIImage, litArt: CIImage, shadow: CIImage, artCorners: [CGPoint]) -> CIImage {
        let frameHeight = frameImage.extent.height
        // Core Image's y grows up from the bottom.
        let cornersFromTheBottom = artCorners.map { CGPoint(x: $0.x, y: frameHeight - $0.y) }
        let artExtent = litArt.extent
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
        return placedOnTheWall(litArt)
            .composited(over: placedOnTheWall(shadow))
            .composited(over: frameImage)
    }

    /// The learner from the camera frame drawn back over `artOverTheFrame` through the segmentation mask.
    private func withThePersonOnTop(of artOverTheFrame: CIImage, frameImage: CIImage, personMask: CVPixelBuffer) -> CIImage {
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

    /// Takes the newest frame as the keyframe: the tracker starts from it, the item hides until it is measured again, and the
    /// measurement request is built from it. With no anchor, the item centers on the bare wall spot or stands on the bare
    /// floor spot. Nil before any frame arrived.
    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe? {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: self.takeAKeyframeOnTheQueue(on: surfaceKind, anchorInCameraPixels: anchorInCameraPixels))
            }
        }
    }

    private func takeAKeyframeOnTheQueue(on surfaceKind: RoomArtSurfaceKind, anchorInCameraPixels: CGPoint?) -> RoomArtKeyframe? {
        guard let latestFrame, let latestTrackGrayscale, let latestTrackRoomMask else { return nil }
        let frameWidth = Double(CVPixelBufferGetWidth(latestFrame)), frameHeight = Double(CVPixelBufferGetHeight(latestFrame))
        let cameraPixelsPerTrackPixel = frameWidth / Double(latestTrackGrayscale.width)
        let anchor = anchorInCameraPixels ?? {
            let trackSpot = switch surfaceKind {
            case .wall: bareWallSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
            case .floor: bareFloorSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
            }
            return CGPoint(x: trackSpot.x * cameraPixelsPerTrackPixel, y: trackSpot.y * cameraPixelsPerTrackPixel)
        }()

        trackerBeforeTheMove = tracker
        placedArtBeforeTheMove = placedArt
        keyframeNumberBeforeTheMove = keyframeNumber
        keyframeNumber += 1
        tracker = RoomTracker(keyframeGrayscale: latestTrackGrayscale, keyframeRoomMask: latestTrackRoomMask)
        placedArt = nil
        crossfadeFrom = nil
        smoothedArtCorners = nil
        theSurfaceIsLostAsLastReported = false
        // The loop outlines the window around the spot until the item shows, and starts on the keyframe where it was drawn.
        let keyframeLoopCorners = RoomArtLoopGeometry.keyframeCorners(around: anchor, frameSize: CGSize(width: frameWidth, height: frameHeight), on: surfaceKind)
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
        // Furniture's wall is measured on the same keyframe, at the wall spot a wall item would take.
        let wallSpotInTrackPixels = bareWallSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
        return RoomArtKeyframe(
            measurementRequest: RoomWallRequest(keyframeJPEGData: keyframeJPEGData, personMaskPNGData: personMaskPNGData, anchor: anchor),
            wallLight: keyframeWallLight,
            wallSpotAnchor: CGPoint(x: wallSpotInTrackPixels.x * cameraPixelsPerTrackPixel, y: wallSpotInTrackPixels.y * cameraPixelsPerTrackPixel),
            keyframeNumber: keyframeNumber,
            floorTexture: surfaceKind == .floor ? RoomFloorTextureMap(
                width: latestTrackGrayscale.width,
                height: latestTrackGrayscale.height,
                texture: textureWithThePersonMarked(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask),
                cameraPixelsPerMapPixel: cameraPixelsPerTrackPixel
            ) : nil
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

    /// Places the item at `keyframeCorners` (camera pixels in the keyframe), lit like the room around the keyframe's spot,
    /// with about 0.7 camera pixels of blur and a soft contact shadow: below the art on a wall, and under the base of
    /// furniture on the floor.
    func showTheItem(_ itemImage: CGImage, keyframeCorners: RoomArtCorners, on surfaceKind: RoomArtSurfaceKind) {
        processingQueue.async {
            let flattenedArt = itemImage
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
            let shadow: CIImage
            var keyframeBasePoint: CGPoint?
            switch surfaceKind {
            case .wall:
                // The shadow sits 2 percent of the art's height below it and spreads 1.5 percent, at 35 percent black.
                let shadowSpread = artHeight * 0.015
                let shadowOffset = -artHeight * 0.02
                shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35))
                    .cropped(to: artExtent.offsetBy(dx: 0, dy: shadowOffset))
                    .applyingGaussianBlur(sigma: shadowSpread)
                    .cropped(to: artExtent.offsetBy(dx: 0, dy: shadowOffset).insetBy(dx: -3 * shadowSpread, dy: -3 * shadowSpread))
            case .floor:
                shadow = self.furnitureContactShadow(artExtent: artExtent)
                keyframeBasePoint = CGPoint(x: (corners[2].x + corners[3].x) / 2, y: max(corners[2].y, corners[3].y))
            }
            self.placedArt = PlacedArt(drawing: .warpedOntoItsCorners(litArt: litArt, shadow: shadow), keyframeCorners: corners, keyframeBasePoint: keyframeBasePoint)
            self.crossfadeFrom = nil
            self.smoothedArtCorners = nil
            self.theSurfaceIsLostAsLastReported = false
            self.trackerBeforeTheMove = nil
            self.placedArtBeforeTheMove = nil
        }
    }

    /// A soft dark ellipse across the furniture's base, in the cutout's space (Core Image's y up, the base at y 0), so the
    /// same warp that stands the cutout on the floor puts the shadow under it. Its lower half shows below the base, which
    /// reads as the shadow on the floor in front of the piece, and the piece covers the rest. A radial gradient from 45
    /// percent black at the center to clear at the rim, squashed to the ellipse's height.
    private func furnitureContactShadow(artExtent: CGRect) -> CIImage {
        let shadowWidth = artExtent.width * 0.96
        let shadowHeight = max(artExtent.height * 0.08, 2)
        guard let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 0, y: 0),
            "inputRadius0": 0,
            "inputRadius1": shadowWidth / 2,
            "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.45),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])?.outputImage else { return CIImage.empty() }
        return gradient
            .transformed(by: CGAffineTransform(scaleX: 1, y: shadowHeight / shadowWidth))
            .transformed(by: CGAffineTransform(translationX: artExtent.midX, y: artExtent.minY))
            .cropped(to: CGRect(x: artExtent.midX - shadowWidth / 2, y: artExtent.minY - shadowHeight / 2, width: shadowWidth, height: shadowHeight))
    }

    func showTheFurnitureLayers(_ layers: RoomFurnitureKeyframeLayers, keyframeNumber: Int) {
        processingQueue.async {
            guard keyframeNumber == self.keyframeNumber, let latestFrame = self.latestFrame else { return }
            let frameWidth = Double(CVPixelBufferGetWidth(latestFrame)), frameHeight = Double(CVPixelBufferGetHeight(latestFrame))
            // The layers move with the room, so the tracker carries the frame's own corners and the layers follow them.
            let frameCorners = [CGPoint(x: 0, y: 0), CGPoint(x: frameWidth, y: 0), CGPoint(x: frameWidth, y: frameHeight), CGPoint(x: 0, y: frameHeight)]
            if let placedArt = self.placedArt { self.crossfadeFrom = (placedArt, CACurrentMediaTime()) }
            self.placedArt = PlacedArt(
                drawing: .keyframeLayers(
                    item: CIImage(cgImage: layers.itemLayer),
                    shadow: layers.shadowLayer.map { CIImage(cgImage: $0) },
                    grainStandardDeviation: layers.cameraNoiseStandardDeviation
                ),
                keyframeCorners: frameCorners,
                keyframeBasePoint: layers.basePointInTheKeyframe
            )
            self.smoothedArtCorners = nil
        }
    }

    func outlineTheLoop(around point: CGPoint, on surfaceKind: RoomArtSurfaceKind, inKeyframeNumber keyframeNumber: Int) {
        processingQueue.async {
            guard keyframeNumber == self.keyframeNumber, self.loopKeyframeCorners != nil, let latestFrame = self.latestFrame else { return }
            let frameSize = CGSize(width: CVPixelBufferGetWidth(latestFrame), height: CVPixelBufferGetHeight(latestFrame))
            // The smoothed corners keep where the loop was, so it glides to the new window over the next frames.
            self.loopKeyframeCorners = RoomArtLoopGeometry.keyframeCorners(around: point, frameSize: frameSize, on: surfaceKind)
        }
    }

    /// The loop where the surface or the torso last was, for the panel to draw or fade out.
    func currentLoop() -> RoomArtLoopSnapshot? {
        latestLoop.withLock { $0 }
    }

    /// A click's measurement failed, so the item goes back where it stood, tracked against the keyframe it stood on. That
    /// tracker aligns each frame to its own keyframe, so it finds the room again after the frames it missed. The loop
    /// outlined the failed keyframe, so it stops following the room and fades out where it was.
    func putBackTheItemFromBeforeTheMove() {
        processingQueue.async {
            self.loopKeyframeCorners = nil
            guard let placedArtBeforeTheMove = self.placedArtBeforeTheMove else { return }
            self.tracker = self.trackerBeforeTheMove
            self.placedArt = placedArtBeforeTheMove
            self.keyframeNumber = self.keyframeNumberBeforeTheMove
            self.crossfadeFrom = nil
            self.smoothedArtCorners = nil
            self.theSurfaceIsLostAsLastReported = false
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
/// A store often hides a product's size in a collapsed section, as IKEA hides the height under Measurements, so the read
/// first opens those sections (`roomArtExpandTheSizeSectionsScript`) and waits a moment for them to fill, and the text then
/// adds the page's structured data that names a dimension (`roomArtPageTextScript`). The scripts have no double quotes or
/// backslashes, since they run inside an AppleScript string.
@MainActor
func readTheFrontTabForRoomArt() async -> RoomArtFrontTab? {
    guard let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow() else { return nil }
    let sectionsOpened = (try? ChromeVideoTab.runJavaScript(roomArtExpandTheSizeSectionsScript, in: frontTab)).flatMap { Int($0) } ?? 0
    if sectionsOpened > 0 {
        print("Room art: opened \(sectionsOpened) collapsed sections of the page before reading it")
        // IKEA's Measurements text was in the page 12 ms after its click, and a slower store gets more room than that.
        try? await Task.sleep(for: .milliseconds(600))
    }
    let pageText = try? ChromeVideoTab.runJavaScript(roomArtPageTextScript(longestCharacters: RoomArtPageRequest.longestPageText), in: frontTab)
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
    /// Everything the controller reaches outside itself, so a test can stand in for Chrome, the Worker, the camera, Vision,
    /// and the voice.
    struct Environment {
        /// Every Worker route the panel calls needs the app secret, so with none set the camera never opens.
        var appSecretIsSet: () -> Bool
        var readTheFrontTab: () async -> RoomArtFrontTab?
        var capturePicture: () async -> RoomArtPicture?
        var readThePage: (RoomArtPageRequest) async throws -> RoomArtPageReading
        var measureTheWall: (RoomWallRequest) async throws -> WallPlane
        var measureTheFloor: (RoomWallRequest) async throws -> FloorPlane
        /// The furniture cut out of its product photo, nil when Vision finds none. Vision takes a while, so it runs off the
        /// main actor.
        var cutOutTheFurniture: (_ picture: CGImage, _ itemCorners: RoomArtCorners) async -> CGImage?
        /// The top cut out of its product photo, nil when no garment is found: `ShirtGarment.make` for a flat lay and
        /// `make(onModelPhoto:itemCorners:)` for a photo of it worn by a model. It runs off the main actor.
        var makeTheShirtGarment: (_ picture: CGImage, _ itemCorners: RoomArtCorners, _ photoShows: RoomArtGarmentPhoto) async -> ShirtGarment?
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
        /// The store's own 3D model in the front tab, downloaded and loaded, or nil when the page at that address offers none
        /// the app can read. The furniture's first look.
        var findTheStoreModel: (_ pageURL: String) async -> RoomFurnitureLoadedModel? = { _ in nil }
        /// The generation service's client: a generated model (the second look) and a painted composite (the third).
        var furnitureGeneration: RoomFurnitureGenerating = RoomFurnitureGenerationNotSetUp()
        /// A model's GLB bytes loaded as a node tree, off the main actor, or nil when they do not load.
        var loadAGeneratedModel: (_ glbData: Data) async -> RoomFurnitureLoadedModel? = { _ in nil }
        /// The mask the painted composite is painted inside, from the item box's projected corners, as a PNG
        /// (`roomFurnitureCompositeMaskPNG`).
        var compositeMaskPNG: (_ projectedBox: [CGPoint], _ frameWidth: Int, _ frameHeight: Int, _ shadowMarginPixels: Double) -> Data? = { _, _, _, _ in nil }
        /// Renders a model standing on the floor as keyframe layers, off the main actor, or nil when the render fails.
        var renderTheFurniture: (RoomFurnitureRenderRequest) async -> RoomFurnitureKeyframeLayers? = { _ in nil }
        /// Turns a painted keyframe into its item layer (`RoomFurniturePaintedComposite`), off the main actor.
        var paintedItemLayers: (_ painted: CGImage, _ keyframe: CGImage, _ maskPNG: Data, _ projectedBox: [CGPoint]) async -> RoomFurnitureKeyframeLayers? = { _, _, _, _ in nil }

        /// Chrome, the Worker at `workerBaseURL`, the app's defaults for the secret, Vision, and the camera (or a Debug
        /// build's `--room-camera-file`).
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
                measureTheFloor: { floorRequest in try await roomArtClient.measureTheFloor(floorRequest) },
                cutOutTheFurniture: { picture, itemCorners in
                    // A CGImage is immutable, so the detached task may read it.
                    nonisolated(unsafe) let pictureToCut = picture
                    return await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        furnitureCutout(picture: pictureToCut, itemCorners: itemCorners, context: CIContext())
                    }.value
                },
                makeTheShirtGarment: { picture, itemCorners, photoShows in
                    nonisolated(unsafe) let pictureToCut = picture
                    return await Task.detached(priority: .userInitiated) {
                        photoShows == .onModel
                            ? ShirtGarment.make(onModelPhoto: pictureToCut, itemCorners: itemCorners)
                            : ShirtGarment.make(productPhoto: pictureToCut, itemCorners: itemCorners)
                    }.value
                },
                makeFrameSource: { makeRoomFrameSource() },
                clearTheLiveScene: clearTheLiveScene,
                speak: speak,
                loopAccentColor: loopAccentColor,
                endTheSpokenLine: endTheSpokenLine,
                findTheStoreModel: { pageURL in await RoomFurnitureModelLoading.findTheStoreModel(onThePageAt: pageURL) },
                furnitureGeneration: RoomFurnitureGenerationClient(workerBaseURL: workerBaseURL),
                loadAGeneratedModel: { glbData in
                    await Task.detached(priority: .userInitiated) { () -> RoomFurnitureLoadedModel? in
                        do {
                            let rootNode = try RoomFurnitureModelLoading.rootNode(fromGLBData: glbData)
                            return RoomFurnitureLoadedModel(rootNode: rootNode, look: .generatedModel, originForTheLog: "generated")
                        } catch {
                            print("Room furniture: the generated model did not load: \(error)")
                            return nil
                        }
                    }.value
                },
                compositeMaskPNG: { projectedBox, frameWidth, frameHeight, shadowMarginPixels in
                    roomFurnitureCompositeMaskPNG(projectedBox: projectedBox, frameWidth: frameWidth, frameHeight: frameHeight, shadowMarginPixels: shadowMarginPixels)
                },
                renderTheFurniture: { renderRequest in
                    await withCheckedContinuation { continuation in
                        roomFurnitureRenderQueue.async {
                            let rendered = sharedRoomFurnitureRenderer.render(renderRequest)
                            if let report = rendered?.report { print(report.logLine) }
                            continuation.resume(returning: rendered?.layers)
                        }
                    }
                },
                paintedItemLayers: { painted, keyframe, maskPNG, projectedBox in
                    // CGImages are immutable, so the detached task may read them.
                    nonisolated(unsafe) let paintedImage = painted, keyframeImage = keyframe
                    return await Task.detached(priority: .userInitiated) { () -> RoomFurnitureKeyframeLayers? in
                        let composite = RoomFurniturePaintedComposite.itemLayers(painted: paintedImage, keyframe: keyframeImage, maskPNG: maskPNG, projectedBox: projectedBox)
                        if let ratio = composite.paintedHeightRatio, let rows = composite.paintedRows {
                            print(String(format: "Room furniture: the painted item is %.0f%% of the measured box's outline (%@)", ratio * 100, roomFurniturePaintedRowsAgainstTheBox(rows, projectedBox)))
                        }
                        return composite.layers
                    }.value
                }
            )
        }
    }

    @Published private(set) var phase = RoomArtPhase.closed {
        didSet { loopState = loopState.after(phaseChangedTo: phase, at: ProcessInfo.processInfo.systemUptime) }
    }
    /// Clicky's loop around the measured spot or the learner's torso: drawn until the item or the shirt shows, or a failure.
    @Published private(set) var loopState = RoomArtLoopState.hidden
    /// The tracker lost the room long enough to hide the item, so the status line says so.
    @Published private(set) var theSurfaceIsLost = false
    /// What the settled framing tells the learner while the shirt cannot be drawn, nil once they stand in view.
    @Published private(set) var shirtCoachingLine: String?
    /// The camera's first frame with a person mask has arrived since the panel opened, so the video shows and a keyframe
    /// can be taken. Until then the layer still holds the last session's frame, so the panel covers it.
    @Published private(set) var theFirstFrameIsIn = false

    private let environment: Environment
    private let frameProcessor: RoomArtFrameProcessing
    private var injectedPanelPresenter: RoomArtPanelPresenting?
    private lazy var panelPresenter: RoomArtPanelPresenting = injectedPanelPresenter
        ?? RoomArtPanelController(previewController: self, metalLayer: frameProcessor.metalLayer)
    private let flatteningContext = CIContext()

    private var frameSource: RoomFrameSource?
    private var pageRequest: RoomArtPageRequest?
    private var pictureImage: CGImage?
    /// Reads the page as the panel opens and prepares what it shows: the flattened art, the furniture's cutout, or the
    /// garment. A close cancels it.
    private var pageReadingTask: Task<Void, Never>?
    private var measurementTask: Task<Void, Never>?
    /// The picture's download or capture, which a close cancels, so Escape stops a slow download at once.
    private var pictureTask: Task<RoomArtPicture?, Never>?
    private var lastMeasurementNumber = 0
    /// Each open counts up, so an await that resumes after the panel closed or reopened changes nothing.
    private var openingNumber = 0
    /// The page and its picture are being read before the panel opens, so Escape has a request to stop.
    private var anOpeningIsUnderway = false
    private var hereItIsWasSaid = false
    /// The floor line is said once, the first time no floor is found, and a click's failure only shows in the status line.
    private var floorNotFoundWasSaid = false
    /// The shirt's coaching is said once, before the shirt first shows, and after that only the status line follows it.
    private var shirtCoachingWasSaid = false
    /// The framing last settled on ready, so a garment that is ready later shows the shirt at once.
    private var theLearnerIsInFrame = false

    /// With no presenter, the real panel shows, and with no frame processor, the real one draws it.
    init(environment: Environment, frameProcessor: RoomArtFrameProcessing = RoomArtFrameProcessor(), panelPresenter: RoomArtPanelPresenting? = nil) {
        self.environment = environment
        self.frameProcessor = frameProcessor
        injectedPanelPresenter = panelPresenter
    }

    var isOpen: Bool { phase.isOpen }

    /// The theme's accent, which the panel draws the loop in.
    var loopAccentColor: Color { environment.loopAccentColor() }

    // MARK: The furniture's looks

    /// Where the search for a model of the furniture stands: the store's model, else a generated one, else none, when the
    /// painted composite is the only step. The flat cutout shows meanwhile.
    private enum FurnitureLookSearch {
        case searching
        case found(RoomFurnitureLoadedModel)
        case paintTheComposite
        /// Nothing more to try, so the flat cutout stays.
        case keepTheCutout
    }
    private var furnitureLookSearch: FurnitureLookSearch?
    private var furnitureLookSearchTask: Task<Void, Never>?
    /// Renders or paints the best look for the placement showing now. A new placement or a close cancels it.
    private var furnitureUpgradeTask: Task<Void, Never>?
    /// The keyframe of the measurement that just finished, kept until its result is applied.
    private var keyframeOfTheLatestMeasurement: RoomArtKeyframe?
    /// The furniture showing now, the keyframe it was placed on, and the floor it stands on.
    private var furniturePlacementShowing: (furniture: RoomFurniture, keyframe: RoomArtKeyframe, floor: FloorPlane)?
    /// The furniture's cutout over white, as a JPEG, which both generation services work from. It is the product cut out of
    /// the page's photo, never the raw page picture, which can hold a cookie banner or the rest of the page.
    private var furnitureCutoutJPEG: Data?
    /// The composite service said it is not set up, so no later placement in this panel asks it again.
    private var compositeServiceIsUnavailable = false
    /// The latest furniture spot shows only part of the piece, so Clicky asks the learner to step back.
    fileprivate var theWholePieceDoesNotShow = false
    private var stepBackWasSaid = false

    /// The loop's line as the panel draws it this moment, in panel points, or nil before there is a keyframe, a torso, or a
    /// camera frame.
    func currentLoopOutline(cameraSize: CGSize, panelSize: CGSize) -> Path? {
        guard let snapshot = frameProcessor.currentLoop() else { return nil }
        return RoomArtLoopOutline.path(for: snapshot, fit: RoomArtVideoFit(cameraSize: cameraSize, viewSize: panelSize))
    }

    /// The loop's fade-out has run.
    func theLoopFadeFinished() {
        loopState = loopState.afterTheFadeFinished()
    }

    /// Reads the page's picture, opens the panel, starts the camera, and reads the page at once. `learnerRequest` is what the
    /// learner said, which tells the Worker which item they mean when the page shows several. The page's kind decides what
    /// follows (`roomArtReadingPlan`). Returns once the camera runs or failed. Everything that can fail before the camera
    /// does, a missing app secret, a page that is not https, and page text that cannot be read, is checked first, so the
    /// camera never opens for a request the Worker would refuse.
    func showTheArtInTheRoom(learnerRequest: String) async {
        if isOpen { close() }
        openingNumber += 1
        let thisOpening = openingNumber
        // An earlier request still fetching its picture is stale now, so its download stops instead of running to its deadline.
        pictureTask?.cancel()
        anOpeningIsUnderway = true
        defer { if thisOpening == openingNumber { anOpeningIsUnderway = false } }

        guard environment.appSecretIsSet() else {
            environment.speak(RoomArtFailure.appSecretMissing.spokenLine, true)
            return
        }
        guard let frontTab = await environment.readTheFrontTab() else {
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
        let capturePicture = environment.capturePicture
        let pictureTask = Task { await capturePicture() }
        self.pictureTask = pictureTask
        let picture = await withTaskCancellationHandler { await pictureTask.value } onCancel: { pictureTask.cancel() }
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
        floorNotFoundWasSaid = false
        shirtCoachingWasSaid = false
        theLearnerIsInFrame = false
        theSurfaceIsLost = false
        shirtCoachingLine = nil
        theFirstFrameIsIn = false
        environment.clearTheLiveScene()
        phase = phase.opening()
        panelPresenter.show()

        frameProcessor.startASession(
            onFirstSegmentedFrame: { [weak self] in
                Task { @MainActor in
                    guard let self, thisOpening == self.openingNumber else { return }
                    self.theFirstSegmentedFrameArrived()
                }
            },
            onTheSurfaceLostOrFound: { [weak self] surfaceIsLost in
                Task { @MainActor in
                    guard let self, thisOpening == self.openingNumber else { return }
                    self.theSurfaceIsLost = surfaceIsLost
                }
            }
        )
        // The page is read while the camera starts, so the kind is known by the time the first frame arrives, and only the
        // surface the item needs is measured.
        pageReadingTask = Task { await self.readThePageAndPrepareTheItem(thisOpening: thisOpening) }

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

    /// Escape reaches the panel when it is open, or when a request still reads the page and its picture.
    var takesEscape: Bool { isOpen || anOpeningIsUnderway }

    /// Escape closes the panel when it is open, or stops a request still reading the page and its picture, ahead of any
    /// scene behavior.
    func closeOnEscape() -> Bool {
        guard takesEscape else { return false }
        close()
        return true
    }

    /// Every close goes through here, the Close button's included, so the camera and the spoken line always stop together.
    func close() {
        environment.endTheSpokenLine()
        openingNumber += 1
        anOpeningIsUnderway = false
        pageReadingTask?.cancel()
        pageReadingTask = nil
        pictureTask?.cancel()
        pictureTask = nil
        measurementTask?.cancel()
        measurementTask = nil
        furnitureLookSearchTask?.cancel()
        furnitureLookSearchTask = nil
        furnitureUpgradeTask?.cancel()
        furnitureUpgradeTask = nil
        furnitureLookSearch = nil
        furniturePlacementShowing = nil
        keyframeOfTheLatestMeasurement = nil
        furnitureCutoutJPEG = nil
        compositeServiceIsUnavailable = false
        theWholePieceDoesNotShow = false
        stepBackWasSaid = false
        frameSource?.stop()
        frameSource = nil
        frameProcessor.endTheSession()
        panelPresenter.hide()
        pageRequest = nil
        pictureImage = nil
        theSurfaceIsLost = false
        shirtCoachingLine = nil
        theFirstFrameIsIn = false
        phase = phase.closing()
    }

    /// A click on the video places the item there: it moves an item that shows with a new keyframe and measurement, or
    /// measures the floor where none was found. A click during a measurement, before the item shows, or on a shirt changes
    /// nothing, since `RoomArtPhase.startingAMeasurement` starts none then. A click after a failed move tries again.
    func placeTheItem(atCameraPixel cameraPixel: CGPoint) {
        startAMeasurement(anchorInCameraPixels: cameraPixel)
    }

    private func theFirstSegmentedFrameArrived() {
        theFirstFrameIsIn = true
        // The page was read before the camera had a frame, so its surface is measured now.
        if case .waitingForTheCamera = phase { startAMeasurement(anchorInCameraPixels: nil) }
    }

    // MARK: Reading the page

    /// Reads the page and prepares what its kind needs: wall art is flattened, furniture cut out, and a top cut out while
    /// the shirt try-on starts. A kind that cannot be tried, or a page with no size, fails with its own line.
    private func readThePageAndPrepareTheItem(thisOpening: Int) async {
        guard let pageRequest, let pictureImage else { return }
        let pageReading: RoomArtPageReading
        do {
            pageReading = try await environment.readThePage(pageRequest)
        } catch {
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            print("Room art: the page was not read: \(error)")
            apply(phase.afterThePageFailed(roomArtFailure(forAFailedPageRead: error)))
            return
        }
        guard !Task.isCancelled, thisOpening == openingNumber else { return }

        switch roomArtReadingPlan(for: pageReading) {
        case .fail(let failure):
            print("Room art: the page reads as \(pageReading.kindForTheLog), which cannot be tried: \(failure)")
            apply(phase.afterThePageFailed(failure))

        case .hangOnTheWall(let wallArtReading):
            guard let flattenedImage = flattenedArtwork(
                picture: pictureImage,
                corners: wallArtReading.artworkCorners,
                size: wallArtReading.chosenSize,
                context: flatteningContext
            ) else {
                apply(phase.afterThePageFailed(.pageNotRead))
                return
            }
            print("Room art: \"\(wallArtReading.title)\" at \(wallArtReading.chosenSize.label), because \(wallArtReading.whyThisSize)")
            itemIsReady(.wallArt(RoomArtwork(
                title: wallArtReading.title,
                widthMeters: wallArtReading.chosenSize.widthCentimeters / 100,
                heightMeters: wallArtReading.chosenSize.heightCentimeters / 100,
                includesFrame: wallArtReading.chosenSizeIncludesFrame,
                flattenedImage: flattenedImage
            )))

        case .standOnTheFloor(let furnitureReading, let size):
            print("Room art: \"\(furnitureReading.title)\" at \(size.label), because \(furnitureReading.whyThisSize)")
            let cutoutImage = await environment.cutOutTheFurniture(pictureImage, furnitureReading.itemCorners)
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            guard let cutoutImage else {
                apply(phase.afterThePageFailed(.furnitureNotCutOut))
                return
            }
            // Both generation services get the cutout over white and never the raw page picture, so the search for the
            // better looks starts once the cutout exists. It then runs while the floor is measured, which takes seconds.
            furnitureCutoutJPEG = roomFurnitureCutoutJPEG(cutoutImage)
            if furnitureCutoutJPEG == nil {
                print("Room furniture: the cutout could not be encoded, so only the store's model is searched")
            }
            startSearchingForTheFurnituresBestLook(
                itemTitle: furnitureReading.title, pageURL: pageRequest.pageURL, pagePictureJPEG: pageRequest.picture.jpegData, thisOpening: thisOpening
            )
            itemIsReady(.furniture(RoomFurniture(
                title: furnitureReading.title,
                widthMeters: size.widthCentimeters / 100,
                heightMeters: size.heightCentimeters / 100,
                depthMeters: size.depthCentimeters / 100,
                cutoutImage: cutoutImage
            )))

        case .tryOnTheShirt(let clothingReading):
            print("Room art: \"\(clothingReading.title)\" is a \(clothingReading.garment.rawValue) photographed \(clothingReading.photoShows.rawValue), size \(clothingReading.chosenSizeLabel)")
            apply(phase.startingTheShirt(title: clothingReading.title))
            // The camera looks for the learner while the garment is cut out, so the coaching can start at once.
            frameProcessor.startTheShirtTryOn(onTheFramingSettled: { [weak self] settledKind in
                Task { @MainActor in
                    guard let self, thisOpening == self.openingNumber else { return }
                    self.theShirtFramingSettled(on: settledKind)
                }
            })
            // The garment is cut out of the picture that shows its front, which the page reader chose from the page's photos.
            let frontPicture = clothingReading.frontPictureIndex == 0 ? pictureImage : pageRequest.picture.picture(numbered: clothingReading.frontPictureIndex).flatMap { picture in
                CGImageSourceCreateWithData(picture.jpegData as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            guard let frontPicture else {
                apply(phase.afterTheGarmentFailed())
                return
            }
            print("Room art: the garment's front is picture \(clothingReading.frontPictureIndex) of \(1 + pageRequest.picture.otherPictures.count)")
            let garment = await environment.makeTheShirtGarment(frontPicture, clothingReading.itemCorners, clothingReading.photoShows)
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            guard let garment else {
                apply(phase.afterTheGarmentFailed())
                return
            }
            frameProcessor.wearTheGarment(garment)
            apply(phase.withTheGarmentReady(learnerIsInFrame: theLearnerIsInFrame))
        }
    }

    /// Wall art or furniture is ready, and its surface is measured as soon as the camera has a frame.
    private func itemIsReady(_ item: RoomArtPlacedItem) {
        apply(phase.withTheItemReady(item))
        if theFirstFrameIsIn { startAMeasurement(anchorInCameraPixels: nil) }
    }

    // MARK: The shirt

    private func theShirtFramingSettled(on settledKind: ShirtFramingKind) {
        theLearnerIsInFrame = settledKind == .ready
        shirtCoachingLine = settledKind.coachingLine
        if settledKind == .ready {
            apply(phase.afterTheLearnerStoodInFrame())
            return
        }
        // The first advice is said once while the shirt is still on its way, and after that the status line follows the
        // learner, so a learner who steps in and out is not talked at.
        guard !shirtCoachingWasSaid, let coachingLine = settledKind.coachingLine else { return }
        switch phase {
        case .preparingTheShirt, .waitingToSeeTheLearner:
            shirtCoachingWasSaid = true
            environment.speak(coachingLine, false)
        default:
            break
        }
    }

    // MARK: Measuring

    private func startAMeasurement(anchorInCameraPixels: CGPoint?) {
        lastMeasurementNumber += 1
        let measurementID = RoomArtMeasurementID(number: lastMeasurementNumber)
        let measuringPhase = phase.startingAMeasurement(id: measurementID)
        guard measuringPhase != phase, let surfaceKind = measuringPhase.itemBeingMeasured?.surfaceKind else { return }
        phase = measuringPhase
        theSurfaceIsLost = false

        measurementTask = Task {
            guard let keyframe = await frameProcessor.takeAKeyframe(on: surfaceKind, anchorInCameraPixels: anchorInCameraPixels) else {
                apply(phase.afterTheMeasurementFailed(surfaceKind.cannotPlaceFailure, measurementID: measurementID))
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let surface: RoomArtSurface
                switch surfaceKind {
                case .wall:
                    let wall = try await environment.measureTheWall(keyframe.measurementRequest)
                    print(String(format: "Room art: wall %.2f m away at %.0f degrees, %.0f%% of it fits the plane", wall.distanceMeters, wall.wallAngleDegrees, wall.planeInlierShare * 100))
                    surface = .wall(wall)
                case .floor:
                    let floor = try await measureTheFurnituresFloor(on: keyframe, for: measuringPhase.itemBeingMeasured, anchorWasClicked: anchorInCameraPixels != nil)
                    print(String(format: "Room art: floor %.2f m away, tilted %.0f degrees, %.0f%% of it fits the plane%@", floor.distanceMeters, floor.floorTiltDegrees, floor.planeInlierShare * 100, floor.inferredFromTheWall ? ", inferred from the wall" : ""))
                    surface = .floor(floor)
                }
                guard !Task.isCancelled else { return }
                keyframeOfTheLatestMeasurement = keyframe
                apply(phase.withTheSurfaceMeasured(surface, measurementID: measurementID))
            } catch {
                guard !Task.isCancelled else { return }
                print("Room art: the \(surfaceKind) was not measured: \(error)")
                apply(phase.afterTheMeasurementFailed(roomArtFailure(forAFailedMeasurementOf: surfaceKind, error: error), measurementID: measurementID))
            }
        }
    }

    /// Moves to `newPhase` and does what entering it means: place the item when it shows, put it back when a move failed,
    /// say "Here it is" once, and say why when the panel fails.
    private func apply(_ newPhase: RoomArtPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        switch newPhase {
        case .showing(let item, let surface, let moveFailure):
            theSurfaceIsLost = false
            if let moveFailure {
                // The camera keeps running and only the status line says why, since the learner is looking at the panel.
                print("Room art: the item stays where it was, since the move failed: \(moveFailure)")
                frameProcessor.putBackTheItemFromBeforeTheMove()
                return
            }
            // The phase's transitions show the item only on a surface where its corners land, so this always places it.
            guard let keyframeCorners = surface.keyframeCorners(of: item) else { return }
            frameProcessor.showTheItem(item.image, keyframeCorners: keyframeCorners, on: item.surfaceKind)
            sayHereItIsOnce(item.hereItIsLine)
            if case .furniture = item, theWholePieceDoesNotShow, !stepBackWasSaid {
                stepBackWasSaid = true
                environment.speak(roomFurnitureStepBackLine, false)
            }
            // Furniture's flat cutout is the placeholder: its best look is rendered or painted for this placement.
            if case .furniture(let furniture) = item, case .floor(let floor) = surface, let keyframe = keyframeOfTheLatestMeasurement {
                furniturePlacementShowing = (furniture, keyframe, floor)
                showTheFurnituresBestLook()
            }
        case .waitingForAFloorClick:
            // The camera keeps running, so the learner can tilt the screen down and click the floor.
            guard !floorNotFoundWasSaid else { return }
            floorNotFoundWasSaid = true
            environment.speak(RoomArtFailure.floorNotFound.spokenLine, true)
        case .showingTheShirt:
            shirtCoachingLine = nil
            sayHereItIsOnce(roomArtShirtHereItIsLine)
        case .failed(let failure):
            // The panel keeps its last frame and says what went wrong until the learner closes it.
            frameSource?.stop()
            frameSource = nil
            frameProcessor.endTheSession()
            environment.speak(failure.spokenLine, true)
        case .closed, .readingThePage, .waitingForTheCamera, .measuring, .moving, .preparingTheShirt, .waitingToSeeTheLearner:
            break
        }
    }

    private func sayHereItIsOnce(_ line: String) {
        guard !hereItIsWasSaid else { return }
        hereItIsWasSaid = true
        environment.speak(line, false)
    }
}

extension RoomArtPreviewController {
    // MARK: The floor under furniture

    /// The floor furniture stands on, measured at the keyframe's anchor and checked against the wall measured on the same
    /// keyframe, which the depth service answers from its cached depth in a fraction of a second. A floor that is not level
    /// with the wall (a desk or a bed) is not the floor. With no floor, a floor inferred from the wall stands the piece with
    /// its back on the wall, when at least a third of its box is in the frame. A depth service that is down or refuses the
    /// request fails as it is, with no wall measurement.
    fileprivate func measureTheFurnituresFloor(on keyframe: RoomArtKeyframe, for item: RoomArtPlacedItem?, anchorWasClicked: Bool) async throws -> FloorPlane {
        var measuredFloor: FloorPlane?
        var floorError: Error?
        do {
            measuredFloor = try await environment.measureTheFloor(keyframe.measurementRequest)
        } catch {
            guard roomArtFailure(forAFailedMeasurementOf: .floor, error: error) == .floorNotFound else { throw error }
            floorError = error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        // The spot is chosen before the wall is measured, so the loop outlines it while the wall request runs.
        let floorForThePiece = measuredFloor.map { floorWhereTheWholePieceShows($0, on: keyframe, for: item, anchorWasClicked: anchorWasClicked) }
        let wallRequest = RoomWallRequest(
            keyframeJPEGData: keyframe.measurementRequest.keyframeJPEGData,
            personMaskPNGData: keyframe.measurementRequest.personMaskPNGData,
            anchor: keyframe.wallSpotAnchor ?? keyframe.measurementRequest.anchor
        )
        let wall: WallPlane?
        do {
            wall = try await environment.measureTheWall(wallRequest)
        } catch {
            print("Room furniture: the wall behind the floor was not measured: \(error)")
            wall = nil
        }
        if let measuredFloor, let floorForThePiece {
            guard let wall, !measuredFloor.agrees(withTheWall: wall) else { return floorForThePiece }
            print("Room furniture: the measured floor is not level with the wall, so it is a desk or a bed, not the floor")
            theWholePieceDoesNotShow = false
        }
        if let wall, case .furniture(let furniture) = item,
           let inferredFloor = FloorPlane.inferred(fromTheWall: wall, itemDepthMeters: furniture.depthMeters),
           let boxCorners = inferredFloor.keyframeBoxCorners(widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters) {
            let frameSize = CGSize(width: inferredFloor.principalPoint.x * 2, height: inferredFloor.principalPoint.y * 2)
            let shareInTheFrame = shareOfTheBoxInsideTheFrame(projectedCorners: boxCorners, frameSize: frameSize)
            print(String(format: "Room furniture: no floor in view, so the floor is inferred from the wall, with %.0f%% of the piece in the frame", shareInTheFrame * 100))
            if shareInTheFrame >= roomFurnitureLeastShareOfTheBoxInTheFrame { return inferredFloor }
        }
        throw floorError ?? RoomArtWorkerError.workerReturned(statusCode: 422, body: #"{"error":"The floor is not level with the wall"}"#)
    }

    /// The floor anchored where the whole piece shows (`roomFurnitureSpotWhereTheWholePieceFits`), since the bare spot it was
    /// measured at is often a corner where the frame cuts the piece off. A click keeps the spot the learner clicked, and a
    /// piece no spot shows whole is placed where most of it shows, with the step back line said once after "Here it is".
    private func floorWhereTheWholePieceShows(_ measuredFloor: FloorPlane, on keyframe: RoomArtKeyframe, for item: RoomArtPlacedItem?, anchorWasClicked: Bool) -> FloorPlane {
        theWholePieceDoesNotShow = false
        guard !anchorWasClicked, case .furniture(let furniture) = item else { return measuredFloor }
        let spot = roomFurnitureSpotWhereTheWholePieceFits(
            measuredFloor: measuredFloor,
            widthMeters: furniture.widthMeters,
            heightMeters: furniture.heightMeters,
            depthMeters: furniture.depthMeters,
            // The depth service's principal point is the frame's center.
            frameSize: CGSize(width: measuredFloor.principalPoint.x * 2, height: measuredFloor.principalPoint.y * 2),
            texture: keyframe.floorTexture
        )
        theWholePieceDoesNotShow = !spot.wholePieceFits
        print("Room furniture: \(spot.wholePieceFits ? "moved the piece to where all of it shows" : "no spot shows the whole piece, so it stands where most of it shows")")
        // The loop outlined the bare spot the floor was measured at, so it moves to where the piece will stand.
        if let footprintCenter = roomFurnitureFootprintCenterInTheKeyframe(
            floor: spot.floor, widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters
        ) {
            frameProcessor.outlineTheLoop(around: footprintCenter, on: .floor, inKeyframeNumber: keyframe.keyframeNumber)
        }
        return spot.floor
    }

    // MARK: The furniture's best look

    /// Searches for the furniture's best look while the cutout shows: the store's own model in the page, else a model the
    /// generation service makes, else the painted composite. The result is shown on the placement showing then, and on
    /// every placement after it.
    /// `pagePictureJPEG` is the page's picture, which a generated model is cached by.
    fileprivate func startSearchingForTheFurnituresBestLook(itemTitle: String, pageURL: String, pagePictureJPEG: Data, thisOpening: Int) {
        furnitureLookSearch = .searching
        furnitureLookSearchTask?.cancel()
        let furnitureCutoutJPEG = furnitureCutoutJPEG
        furnitureLookSearchTask = Task {
            var foundModel = await environment.findTheStoreModel(pageURL)
            if let foundModel {
                print("Room furniture: found the store's own model at \(foundModel.originForTheLog)")
            } else if let furnitureCutoutJPEG {
                do {
                    let glbData = try await environment.furnitureGeneration.generateAModel(
                        productJPEG: furnitureCutoutJPEG, itemTitle: itemTitle, cacheKeyData: pagePictureJPEG
                    )
                    guard !Task.isCancelled else { return }
                    foundModel = await environment.loadAGeneratedModel(glbData)
                } catch {
                    print("Room furniture: no generated model: \(error)")
                }
            }
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            furnitureLookSearch = foundModel.map { .found($0) } ?? .paintTheComposite
            showTheFurnituresBestLook()
        }
    }

    /// Shows the best look found so far for the furniture showing now. A model (the store's or a generated one) is rendered
    /// first, which takes under a second, and then the painted composite is asked for, which takes 15 to 20 seconds and
    /// looked more real than the render on the same frame (a real contact shadow and the room's own light), so it replaces
    /// the render when it stands at the measured height. With no model, the composite is the only step. The frame processor
    /// crossfades each step. While the search runs, the search calls this again when it ends.
    fileprivate func showTheFurnituresBestLook() {
        guard let placementShowing = furniturePlacementShowing, let furnitureLookSearch else { return }
        furnitureUpgradeTask?.cancel()
        let thisOpening = openingNumber
        let furniture = placementShowing.furniture, keyframe = placementShowing.keyframe, floor = placementShowing.floor
        let modelToRender: RoomFurnitureLoadedModel?
        switch furnitureLookSearch {
        case .searching, .keepTheCutout: return
        case .found(let model): modelToRender = model
        case .paintTheComposite: modelToRender = nil
        }
        furnitureUpgradeTask = Task {
            guard let keyframeImage = decodedKeyframe(keyframe) else { return }
            if let modelToRender {
                await renderTheModel(modelToRender, furniture: furniture, keyframe: keyframe, keyframeImage: keyframeImage, floor: floor, thisOpening: thisOpening)
            }
            guard !Task.isCancelled, thisOpening == openingNumber, !compositeServiceIsUnavailable else { return }
            await paintTheComposite(furniture: furniture, keyframe: keyframe, keyframeImage: keyframeImage, floor: floor, thisOpening: thisOpening)
        }
    }

    private func renderTheModel(
        _ model: RoomFurnitureLoadedModel, furniture: RoomFurniture, keyframe: RoomArtKeyframe, keyframeImage: CGImage, floor: FloorPlane, thisOpening: Int
    ) async {
        guard let placement = RoomFurniturePlacement(floor: floor, widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters) else { return }
        let layers = await environment.renderTheFurniture(RoomFurnitureRenderRequest(
            modelRootNode: model.rootNode,
            placement: placement,
            focalLengthPixels: floor.focalLengthPixels,
            principalPoint: floor.principalPoint,
            keyframeImage: keyframeImage,
            look: model.look
        ))
        guard !Task.isCancelled, thisOpening == openingNumber else { return }
        guard let layers else {
            print("Room furniture: the \(model.look.rawValue) did not render, so the composite is next")
            return
        }
        frameProcessor.showTheFurnitureLayers(layers, keyframeNumber: keyframe.keyframeNumber)
        print("Room furniture: showing the \(model.look.rawValue) from \(model.originForTheLog)")
    }

    private func paintTheComposite(furniture: RoomFurniture, keyframe: RoomArtKeyframe, keyframeImage: CGImage, floor: FloorPlane, thisOpening: Int) async {
        guard let furnitureCutoutJPEG,
              let projectedBox = floor.keyframeBoxCorners(widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters),
              let maskPNG = environment.compositeMaskPNG(projectedBox, keyframeImage.width, keyframeImage.height, Self.compositeShadowMarginPixels) else { return }
        // The service paints each request afresh, so a painting refused for its height, or a failed request, is asked for
        // once more before the piece is left with the look before it, which with no model is the flat cutout.
        for attempt in 1...Self.mostPaintingAttempts {
            do {
                let painted = try await environment.furnitureGeneration.paintTheItemIntoTheKeyframe(
                    keyframeJPEG: keyframe.measurementRequest.keyframeJPEGData,
                    keyframeWidth: keyframeImage.width,
                    keyframeHeight: keyframeImage.height,
                    productJPEG: furnitureCutoutJPEG,
                    maskPNG: maskPNG,
                    itemTitle: furniture.title,
                    itemSizeWords: furniture.sizeInWords
                )
                guard !Task.isCancelled, thisOpening == openingNumber else { return }
                #if DEBUG
                // Verification reads the painting the height check judged, kept or refused, with what it was judged
                // against. Debug builds only.
                writeThePaintingForVerification(painted, keyframeJPEG: keyframe.measurementRequest.keyframeJPEGData, maskPNG: maskPNG, projectedBox: projectedBox)
                #endif
                if let layers = await environment.paintedItemLayers(painted, keyframeImage, maskPNG, projectedBox) {
                    guard !Task.isCancelled, thisOpening == openingNumber else { return }
                    frameProcessor.showTheFurnitureLayers(layers, keyframeNumber: keyframe.keyframeNumber)
                    print("Room furniture: showing the painted composite")
                    return
                }
                guard !Task.isCancelled, thisOpening == openingNumber else { return }
                print("Room furniture: painting \(attempt) is shorter than the box's front, taller than its outline, or cut off, so it is not shown")
            } catch {
                guard !Task.isCancelled, thisOpening == openingNumber else { return }
                print("Room furniture: no painted composite from painting \(attempt): \(error)")
                // A Worker with no OpenAI key stays that way for this panel, so later placements do not ask again.
                if case RoomFurnitureGenerationError.serviceIsNotSetUp = error { compositeServiceIsUnavailable = true }
                guard roomFurniturePaintingIsWorthAskingForAgain(after: error) else { return }
            }
        }
        print("Room furniture: no painting stood at the measured size, so the look before it stays")
    }

    #if DEBUG
    private func writeThePaintingForVerification(_ painted: CGImage, keyframeJPEG: Data, maskPNG: Data, projectedBox: [CGPoint]) {
        let stem = "clicky-room-furniture-painting-\(Int(Date().timeIntervalSince1970 * 1000))"
        let folder = FileManager.default.temporaryDirectory
        let fileURL = folder.appendingPathComponent("\(stem).png")
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, painted, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try? keyframeJPEG.write(to: folder.appendingPathComponent("\(stem)-keyframe.jpg"))
        try? maskPNG.write(to: folder.appendingPathComponent("\(stem)-mask.png"))
        let boxNumbers = projectedBox.flatMap { [Double($0.x), Double($0.y)] }
        try? JSONSerialization.data(withJSONObject: boxNumbers).write(to: folder.appendingPathComponent("\(stem)-box.json"))
        print("Room furniture: wrote the painting to \(fileURL.path), with its keyframe, mask, and box beside it")
    }
    #endif

    /// How many paintings one placement asks for before it keeps the look before them.
    fileprivate static let mostPaintingAttempts = 2

    /// The painted composite's mask reaches this far past the box's floor footprint, so the item's shadow on the floor is
    /// painted too.
    fileprivate static let compositeShadowMarginPixels = 24.0

    private func decodedKeyframe(_ keyframe: RoomArtKeyframe) -> CGImage? {
        guard let keyframeSource = CGImageSourceCreateWithData(keyframe.measurementRequest.keyframeJPEGData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(keyframeSource, 0, nil)
    }
}

/// The furniture renderer's queue: one render at a time, off the main actor and the camera's queue.
nonisolated let roomFurnitureRenderQueue = DispatchQueue(label: "com.crodris.clicky.room-furniture.render", qos: .userInitiated)
nonisolated let sharedRoomFurnitureRenderer = RoomFurnitureRenderer()

/// What Clicky says once the shirt first shows on the learner.
nonisolated let roomArtShirtHereItIsLine = "Here it is on you."

extension RoomArtPhase {
    /// The item a measurement is running for, nil outside one.
    var itemBeingMeasured: RoomArtPlacedItem? {
        switch self {
        case .measuring(_, let item), .moving(_, let item, _): return item
        default: return nil
        }
    }

    /// A click places a wall or floor item, so the video shows the crosshair in those phases and not for a shirt.
    var theItemIsPlacedByClicking: Bool {
        switch self {
        case .waitingForTheCamera, .measuring, .showing, .moving, .waitingForAFloorClick: return true
        default: return false
        }
    }
}

extension RoomArtPageReading {
    /// The kind of item, for a log line that never prints page text beyond the title.
    var kindForTheLog: String {
        switch self {
        case .wallArt(let reading): return "wall art \"\(reading.title)\""
        case .sizeNotOnThePage(let title): return "wall art \"\(title)\" with no size"
        case .furniture(let reading): return "furniture \"\(reading.title)\"\(reading.chosenSize == nil ? " with no size" : "")"
        case .clothing(let reading): return "a \(reading.garment.rawValue) \"\(reading.title)\" photographed \(reading.photoShows.rawValue)"
        case .other(let title): return "\"\(title)\", which is not wall art, furniture, or clothing"
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
            RoomArtVideoView(metalLayer: metalLayer, showsTheCrosshair: previewController.phase.theItemIsPlacedByClicking) { cameraPixel in
                previewController.placeTheItem(atCameraPixel: cameraPixel)
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
            if !previewController.theFirstFrameIsIn {
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
        let statusText = previewController.phase.statusLine(theSurfaceIsLost: previewController.theSurfaceIsLost, shirtCoachingLine: previewController.shirtCoachingLine)
        if !statusText.isEmpty {
            Text(statusText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(previewController.phase.statusLineIsAFailure(theSurfaceIsLost: previewController.theSurfaceIsLost) ? DS.Colors.destructiveText : DS.Colors.textPrimary)
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
    /// A click places a wall or floor item, so the crosshair says so. A shirt follows the learner, so a click does nothing.
    let showsTheCrosshair: Bool
    let onClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RoomArtVideoNSView {
        RoomArtVideoNSView(metalLayer: metalLayer, onClick: onClick)
    }

    func updateNSView(_ videoView: RoomArtVideoNSView, context: Context) {
        videoView.onClick = onClick
        videoView.showsTheCrosshair = showsTheCrosshair
    }
}

final class RoomArtVideoNSView: NSView {
    private let metalLayer: CAMetalLayer
    var onClick: (CGPoint) -> Void
    var showsTheCrosshair = true
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

    /// The crosshair says a click places the item there. The panel never becomes key, so cursor rects never apply, and an
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
        (showsTheCrosshair ? NSCursor.crosshair : NSCursor.arrow).set()
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
