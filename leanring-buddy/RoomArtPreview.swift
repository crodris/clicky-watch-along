//
//  RoomArtPreview.swift
//  leanring-buddy
//
//  Runs and draws "show me how this would look in my room" and "could I see this shirt on me". `RoomArtPreviewController`
//  reads the page's picture, opens the panel, starts the camera, and asks the Worker what the page shows
//  (`POST /try-it-item`) at once. The item's kind picks the rest: wall art is measured on the wall (`POST /room-wall`) and
//  furniture on the floor (`POST /room-floor`), each from a keyframe taken on the first frame with a person mask, with
//  Clicky's loop around the spot while it waits, and a top laid flat or worn by a model is cut out of its photo and drawn over the learner's
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
    /// With no anchor, the spot is the bare wall spot for the wall and the bare floor spot for the floor. With no surface,
    /// which a keyframe taken while the page is still read has, the anchor is the bare floor spot, and the room's light is
    /// read at the bare wall spot, so the keyframe serves wall art and furniture alike.
    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind?, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe?
    func showTheWallArt(_ flattenedArtImage: CGImage, keyframeCorners: RoomArtCorners)
    /// Shows layers rendered or painted for the keyframe numbered `keyframeNumber`, with a short crossfade from the look
    /// before them, or from the bare room when nothing showed yet. Layers for an older keyframe, such as one a click has
    /// replaced, are dropped.
    /// `layerToKeyframe` maps the layers' pixels into the keyframe's, for a painting made on a later frame
    /// (`aFrameForThePainting`), and is the identity for layers made on the keyframe itself.
    func showTheFurnitureLayers(_ layers: RoomFurnitureKeyframeLayers, keyframeNumber: Int, layerToKeyframe: EuclideanWarp)
    /// Takes the item off the room, as a press that picks placed furniture back up as its ghost does.
    func hideTheItem()
    /// Moves the loop onto a quadrilateral in the keyframe numbered `keyframeNumber`, the ghost's footprint while its painting
    /// comes (front left, front right, back right, back left, as a box's footprint runs). The loop starts there, with no
    /// glide from where it was, and follows the room with the tracker's turn.
    func outlineTheLoop(aroundKeyframeQuadrilateral footprint: RoomArtCorners, inKeyframeNumber keyframeNumber: Int)
    /// Forgets the keyframe and the loop, for a page that turned out to be a shirt after a keyframe was taken for it.
    func forgetTheKeyframe()
    /// The tracker's newest turn from the keyframe to the current frame, eased like the item's corners, or nil before the
    /// first tracked frame of a keyframe. Safe to call from any thread, since the panel draws the ghost through it.
    func currentTrackedWarp() -> RoomArtTrackedWarp?
    /// The newest camera frame, for a painting: its JPEG, the tracker's turn from the keyframe to it, and how much of
    /// `boxInTheKeyframe` (keyframe pixels) the learner covers in it. Nil before a tracked frame or while the room is lost.
    func aFrameForThePainting(boxInTheKeyframe: [CGPoint]) async -> RoomArtPaintingFrame?
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
    /// softly instead of popping. A nil drawing is the bare room, which a first look fades in from.
    private var crossfadeFrom: (placedArt: PlacedArt?, startedAt: CFTimeInterval)?
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
    /// Where the loop's window lands in the keyframe, when that is not the window itself: the ghost's footprint, a
    /// quadrilateral the loop's line is bent onto. Nil for a loop around its own window.
    private var loopKeyframeTargetCorners: RoomArtCorners?
    private var smoothedLoopCorners: [CGPoint]?
    /// The newest loop snapshot, written on `processingQueue` and read from the main thread.
    private let latestLoop = OSAllocatedUnfairLock<RoomArtLoopSnapshot?>(initialState: nil)
    /// The newest eased turn from the keyframe, written on `processingQueue` and read from the main thread, where the panel
    /// draws the ghost and maps a drag through it.
    private let latestTrackedWarp = OSAllocatedUnfairLock<RoomArtTrackedWarp?>(initialState: nil)
    /// The newest turn as the tracker found it, unsmoothed, which a painting frame is mapped by.
    private var latestCameraWarp: EuclideanWarp?
    private var statistics = FrameStatistics()
    private var lastFrameRateReport: RoomArtFrameRateReport?
    #if DEBUG
    /// The last frame as drawn, kept so verification can save what the panel showed.
    private var lastComposedImage: CIImage?
    #endif

    /// The item as it is drawn on every frame: already lit like the room and softened like the camera, with its shadow.
    private struct PlacedArt {
        enum Drawing {
            /// Wall art warped onto its four corners.
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
        /// Maps `keyframeCorners` into the keyframe before the tracker's turn: the identity, except for a painting made on a
        /// later frame, whose own pixels are what `keyframeCorners` count.
        var layerToKeyframe = EuclideanWarp.identity

        func currentCorners(after cameraWarp: EuclideanWarp) -> [CGPoint] {
            keyframeCorners.map { cameraWarp.apply(to: layerToKeyframe.apply(to: $0)) }
        }
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
    /// or a new keyframe, wall art shown, the item hidden, or a failed move put back resets the tracker's state (false), after
    /// which the next frame reports a room still lost. `forgetTheKeyframe` and `endTheSession` report nothing, since a shirt
    /// and a failed panel show no lost line, and neither does `showTheFurnitureLayers`, so a painting that arrives while the
    /// room is lost keeps the lost line.
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
            latestTrackedWarp.withLock { $0 = nil }
            latestCameraWarp = nil
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
        if let trackStep, let cameraWarp {
            publishTheTrackedWarp(cameraWarp, theRoomIsLost: trackStep.theArtIsHidden)
        }
        if let loopKeyframeCorners, let trackStep, let cameraWarp, !trackStep.theArtIsHidden {
            let currentLoopCorners = RoomArtLoopGeometry.corners(of: loopKeyframeTargetCorners ?? loopKeyframeCorners, after: cameraWarp)
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
        // The lost state is reported whenever the tracker follows the room, so it also covers the ghost, which has no placed
        // art, and a painting is never made on a frame whose room is lost.
        if let trackStep, !shirtTryOnIsOn {
            reportWhetherTheSurfaceIsLost(trackStep.theArtIsHidden)
        }
        if let placedArt, let trackStep {
            if !trackStep.theArtIsHidden, let cameraWarp {
                let currentCorners = placedArt.currentCorners(after: cameraWarp)
                artCorners = smoothedCorners(previous: smoothedArtCorners, current: currentCorners)
                smoothedArtCorners = artCorners
                // The drawing fading out follows the same warp, unsmoothed for its half second.
                fadingArtCorners = crossfadeFrom?.placedArt?.currentCorners(after: cameraWarp)
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

    /// Keeps the newest turn for a painting frame, and eases the one the ghost is drawn through the way the item's corners
    /// are eased. A frame whose room is lost keeps the last good turn, marked lost, since a lost turn is a guess.
    private func publishTheTrackedWarp(_ cameraWarp: EuclideanWarp, theRoomIsLost: Bool) {
        let keyframeNumberNow = keyframeNumber
        if !theRoomIsLost { latestCameraWarp = cameraWarp }
        latestTrackedWarp.withLock { tracked in
            let previous = tracked.flatMap { $0.keyframeNumber == keyframeNumberNow ? $0.keyframeToCurrent : nil }
            let warpToPublish: EuclideanWarp
            if theRoomIsLost {
                warpToPublish = previous ?? cameraWarp
            } else {
                warpToPublish = previous.map { $0.eased(toward: cameraWarp, share: RoomTrackingSettings.cornerSmoothingShare) } ?? cameraWarp
            }
            tracked = RoomArtTrackedWarp(keyframeNumber: keyframeNumberNow, keyframeToCurrent: warpToPublish, theRoomIsLost: theRoomIsLost)
        }
    }

    /// Tells the main actor when the item hides because the room is lost, and when it shows again, once per change. The
    /// panel's copy follows only these reports while it is open: a new keyframe, wall art shown, the item hidden, and a failed
    /// move put back report a found room through here.
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
            if let crossfadeFrom {
                let fadeProgress = (CACurrentMediaTime() - crossfadeFrom.startedAt) / Self.crossfadeSeconds
                // The bare room is the frame itself, and a drawing hidden this frame has nothing to fade from.
                let fadingImage: CIImage? = if let fadingPlacedArt = crossfadeFrom.placedArt {
                    fadingArtCorners.map { frameWithTheArt(frameImage: frameImage, placedArt: fadingPlacedArt, artCorners: $0, personMask: latestPersonMask) }
                } else {
                    frameImage
                }
                if fadeProgress >= 1 {
                    self.crossfadeFrom = nil
                } else if let fadingImage {
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
    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind?, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe? {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: self.takeAKeyframeOnTheQueue(on: surfaceKind, anchorInCameraPixels: anchorInCameraPixels))
            }
        }
    }

    private func takeAKeyframeOnTheQueue(on surfaceKind: RoomArtSurfaceKind?, anchorInCameraPixels: CGPoint?) -> RoomArtKeyframe? {
        guard let latestFrame, let latestTrackGrayscale, let latestTrackRoomMask else { return nil }
        let frameWidth = Double(CVPixelBufferGetWidth(latestFrame)), frameHeight = Double(CVPixelBufferGetHeight(latestFrame))
        let cameraPixelsPerTrackPixel = frameWidth / Double(latestTrackGrayscale.width)
        let anchor = anchorInCameraPixels ?? {
            let trackSpot = switch surfaceKind {
            case .wall: bareWallSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
            case .floor, nil: bareFloorSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
            }
            return CGPoint(x: trackSpot.x * cameraPixelsPerTrackPixel, y: trackSpot.y * cameraPixelsPerTrackPixel)
        }()

        trackerBeforeTheMove = tracker
        placedArtBeforeTheMove = placedArt
        keyframeNumberBeforeTheMove = keyframeNumber
        keyframeNumber += 1
        tracker = RoomTracker(keyframeGrayscale: latestTrackGrayscale, keyframeRoomMask: latestTrackRoomMask)
        latestTrackedWarp.withLock { $0 = RoomArtTrackedWarp(keyframeNumber: keyframeNumber, keyframeToCurrent: .identity, theRoomIsLost: false) }
        latestCameraWarp = .identity
        placedArt = nil
        crossfadeFrom = nil
        smoothedArtCorners = nil
        reportWhetherTheSurfaceIsLost(false)
        // The loop outlines the window around the spot until the item shows, and starts on the keyframe where it was drawn.
        let keyframeLoopCorners = RoomArtLoopGeometry.keyframeCorners(around: anchor, frameSize: CGSize(width: frameWidth, height: frameHeight), on: surfaceKind ?? .floor)
        loopKeyframeCorners = keyframeLoopCorners
        loopKeyframeTargetCorners = nil
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

        // Furniture's wall is measured on the same keyframe, at the wall spot a wall item would take.
        let wallSpotInTrackPixels = bareWallSpot(grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask)
        let wallSpot = CGPoint(x: wallSpotInTrackPixels.x * cameraPixelsPerTrackPixel, y: wallSpotInTrackPixels.y * cameraPixelsPerTrackPixel)
        // A keyframe whose surface is not known yet may hang wall art, so the light is read on the wall.
        keyframeWallLight = wallLight(around: surfaceKind == nil ? wallSpot : anchor, in: frameImage, frameWidth: frameWidth, frameHeight: frameHeight)
        return RoomArtKeyframe(
            measurementRequest: RoomWallRequest(keyframeJPEGData: keyframeJPEGData, personMaskPNGData: personMaskPNGData, anchor: anchor),
            wallLight: keyframeWallLight,
            wallSpotAnchor: wallSpot,
            keyframeNumber: keyframeNumber,
            floorTexture: surfaceKind != .wall ? RoomFloorTextureMap(
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

    /// Places the wall art at `keyframeCorners` (camera pixels in the keyframe), lit like the room around the keyframe's
    /// spot, with about 0.7 camera pixels of blur and a soft shadow just below it on the wall.
    func showTheWallArt(_ flattenedArtImage: CGImage, keyframeCorners: RoomArtCorners) {
        processingQueue.async {
            let flattenedArt = flattenedArtImage
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
            self.placedArt = PlacedArt(drawing: .warpedOntoItsCorners(litArt: litArt, shadow: shadow), keyframeCorners: corners, keyframeBasePoint: nil)
            self.crossfadeFrom = nil
            self.smoothedArtCorners = nil
            self.reportWhetherTheSurfaceIsLost(false)
            self.trackerBeforeTheMove = nil
            self.placedArtBeforeTheMove = nil
        }
    }

    func showTheFurnitureLayers(_ layers: RoomFurnitureKeyframeLayers, keyframeNumber: Int, layerToKeyframe: EuclideanWarp) {
        processingQueue.async {
            guard keyframeNumber == self.keyframeNumber, let latestFrame = self.latestFrame else { return }
            let frameWidth = Double(CVPixelBufferGetWidth(latestFrame)), frameHeight = Double(CVPixelBufferGetHeight(latestFrame))
            // The layers move with the room, so the tracker carries the frame's own corners and the layers follow them.
            let frameCorners = [CGPoint(x: 0, y: 0), CGPoint(x: frameWidth, y: 0), CGPoint(x: frameWidth, y: frameHeight), CGPoint(x: 0, y: frameHeight)]
            // A first look fades in from the bare room, and a later one from the look before it.
            self.crossfadeFrom = (self.placedArt, CACurrentMediaTime())
            self.placedArt = PlacedArt(
                drawing: .keyframeLayers(
                    item: CIImage(cgImage: layers.itemLayer),
                    shadow: layers.shadowLayer.map { CIImage(cgImage: $0) },
                    grainStandardDeviation: layers.cameraNoiseStandardDeviation
                ),
                keyframeCorners: frameCorners,
                keyframeBasePoint: layers.basePointInTheKeyframe,
                layerToKeyframe: layerToKeyframe
            )
            self.smoothedArtCorners = nil
        }
    }

    func hideTheItem() {
        processingQueue.async {
            self.placedArt = nil
            self.crossfadeFrom = nil
            self.smoothedArtCorners = nil
            self.reportWhetherTheSurfaceIsLost(false)
        }
    }

    func outlineTheLoop(aroundKeyframeQuadrilateral footprint: RoomArtCorners, inKeyframeNumber keyframeNumber: Int) {
        processingQueue.async {
            guard keyframeNumber == self.keyframeNumber else { return }
            // The line is drawn around the footprint's bounding box and bent onto its corners, so it traces the footprint
            // the way the loop traces a wall seen at a slant.
            let keyframeLoopCorners = RoomArtLoopGeometry.boundingCorners(of: footprint)
            self.loopKeyframeCorners = keyframeLoopCorners
            self.loopKeyframeTargetCorners = footprint
            self.smoothedLoopCorners = nil
            let currentCorners = self.latestCameraWarp.map { RoomArtLoopGeometry.corners(of: footprint, after: $0) } ?? footprint
            self.latestLoop.withLock { $0 = RoomArtLoopSnapshot(keyframeCorners: keyframeLoopCorners, currentCorners: currentCorners) }
        }
    }

    func forgetTheKeyframe() {
        processingQueue.async {
            self.tracker = nil
            self.loopKeyframeCorners = nil
            self.loopKeyframeTargetCorners = nil
            self.smoothedLoopCorners = nil
            self.latestTrackedWarp.withLock { $0 = nil }
            self.latestCameraWarp = nil
        }
    }

    func currentTrackedWarp() -> RoomArtTrackedWarp? {
        latestTrackedWarp.withLock { $0 }
    }

    func aFrameForThePainting(boxInTheKeyframe: [CGPoint]) async -> RoomArtPaintingFrame? {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: self.aFrameForThePaintingOnTheQueue(boxInTheKeyframe: boxInTheKeyframe))
            }
        }
    }

    private func aFrameForThePaintingOnTheQueue(boxInTheKeyframe: [CGPoint]) -> RoomArtPaintingFrame? {
        guard let latestFrame, let latestCameraWarp, !theSurfaceIsLostAsLastReported else { return nil }
        let frameImage = CIImage(cvPixelBuffer: latestFrame)
        guard let jpegData = ciContext.jpegRepresentation(
            of: frameImage,
            colorSpace: sRGBColorSpace,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
        ), let cgImage = ciContext.createCGImage(frameImage, from: frameImage.extent) else { return nil }
        let boxInTheFrame = boxInTheKeyframe.map(latestCameraWarp.apply)
        let shareCovered = latestPersonMask.map { personMask in
            shareOfTheOutlineThePersonCovers(personMask: personMask, outlineInFramePixels: convexHull(of: boxInTheFrame), frameSize: frameImage.extent.size)
        } ?? 0
        return RoomArtPaintingFrame(jpegData: jpegData, image: cgImage, keyframeToFrame: latestCameraWarp, shareOfTheBoxThePersonCovers: shareCovered)
    }

    func outlineTheLoop(around point: CGPoint, on surfaceKind: RoomArtSurfaceKind, inKeyframeNumber keyframeNumber: Int) {
        processingQueue.async {
            guard keyframeNumber == self.keyframeNumber, self.loopKeyframeCorners != nil, let latestFrame = self.latestFrame else { return }
            let frameSize = CGSize(width: CVPixelBufferGetWidth(latestFrame), height: CVPixelBufferGetHeight(latestFrame))
            // The smoothed corners keep where the loop was, so it glides to the new window over the next frames.
            self.loopKeyframeCorners = RoomArtLoopGeometry.keyframeCorners(around: point, frameSize: frameSize, on: surfaceKind)
            self.loopKeyframeTargetCorners = nil
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
            self.loopKeyframeTargetCorners = nil
            guard let placedArtBeforeTheMove = self.placedArtBeforeTheMove else { return }
            self.tracker = self.trackerBeforeTheMove
            self.placedArt = placedArtBeforeTheMove
            self.keyframeNumber = self.keyframeNumberBeforeTheMove
            self.crossfadeFrom = nil
            self.smoothedArtCorners = nil
            self.reportWhetherTheSurfaceIsLost(false)
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
        /// The theme's cursor, which traces Clicky's loop in the panel. Read each time the panel draws it.
        var loopTracerLook: () -> CursorLoopTracerLook? = { nil }
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
        /// Returns when furniture has waited long enough for its first look, `roomFurnitureSecondsToWaitForALook` after its
        /// floor is measured, so the fallback shows instead. A test returns when it chooses.
        var waitTheLongestForAFurnitureLook: () async -> Void = { try? await Task.sleep(for: .seconds(roomFurnitureSecondsToWaitForALook)) }

        /// Chrome, the Worker at `workerBaseURL`, the app's defaults for the secret, Vision, and the camera (or a Debug
        /// build's `--room-camera-file`).
        static func live(
            workerBaseURL: String,
            capturePicture: @escaping () async -> RoomArtPicture?,
            clearTheLiveScene: @escaping () -> Void,
            speak: @escaping (String, Bool) -> Void,
            loopAccentColor: @escaping () -> Color,
            loopTracerLook: @escaping () -> CursorLoopTracerLook?,
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
                loopTracerLook: loopTracerLook,
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

    /// The theme's cursor, which traces the loop in the panel.
    var loopTracerLook: CursorLoopTracerLook? { environment.loopTracerLook() }

    // MARK: The furniture's looks

    /// Where the search for a model of the furniture stands: the store's model, else a generated one, else none. A model is
    /// rendered only as the painting's fallback.
    private enum FurnitureLookSearch {
        case searching
        case found(RoomFurnitureLoadedModel)
        case noModel
    }
    private var furnitureLookSearch: FurnitureLookSearch?
    private var furnitureLookSearchTask: Task<Void, Never>?
    /// Paints the newest placement's composite, its first look. A new placement or a close cancels it.
    private var furniturePaintingTask: Task<Void, Never>?
    /// Renders the newest placement's model, held back as the painting's fallback. A new placement or a close cancels it.
    private var furnitureRenderTask: Task<Void, Never>?
    /// Shows the fallback once the newest placement has waited `roomFurnitureSecondsToWaitForALook` with no painting. A new
    /// placement or a close cancels it.
    private var furnitureLookDeadlineTask: Task<Void, Never>?
    /// The keyframe of the measurement that just finished, kept until its result is applied.
    private var keyframeOfTheLatestMeasurement: RoomArtKeyframe?
    /// The newest furniture placement: its measurement, the furniture, the keyframe it was placed on, and the floor it
    /// stands on, and the ghost it was placed as. It is set as the piece is arranged, before any look shows. The flat cutout
    /// is never drawn, and is kept only as what both generation services work from.
    private var furniturePlacement: (measurementID: RoomArtMeasurementID, furniture: RoomFurniture, keyframe: RoomArtKeyframe, floor: FloorPlane, ghost: RoomFurnitureGhost)?
    /// The model's render for the newest placement, held back while the painting is on its way, since an early look makes
    /// the painting that follows it read as a small change. It shows only as the fallback.
    private var furnitureRenderHeldBack: (measurementID: RoomArtMeasurementID, layers: RoomFurnitureKeyframeLayers)?
    /// What the newest placement's fallback waits on (`roomFurnitureFallbackStep`): the painting said it cannot come, the
    /// wait ran out, and a render is still being made.
    private var furniturePaintingCannotCome = false
    private var furnitureWaitRanOut = false
    private var furnitureRenderIsRunning = false
    /// The furniture's cutout over white, as a JPEG, which both generation services work from. It is the product cut out of
    /// the page's photo, never the raw page picture, which can hold a cookie banner or the rest of the page.
    private var furnitureCutoutJPEG: Data?
    /// The composite service said it is not set up, so no later placement in this panel asks it again.
    private var compositeServiceIsUnavailable = false
    private var stepBackWasSaid = false

    // MARK: The ghost

    /// The furniture's ghost while the learner places it, and the pose it was placed in afterward, which a pick-up starts
    /// from. Nil until the floor is measured, and after a new measurement starts.
    @Published private(set) var furnitureGhost: RoomFurnitureGhost?
    /// When the ghost began drawing itself, and where the loop's tracer was then (`RoomFurnitureGhostDrawTimeline`).
    @Published private(set) var furnitureGhostDraw: RoomFurnitureGhostDraw?
    /// The learner stands where the piece is about to be painted, so the status line asks them to step aside.
    @Published private(set) var waitingForTheLearnerToStepAside = false
    /// The wall measured on the floor's keyframe, which the ghost snaps to.
    private var wallOfTheLatestMeasurement: WallPlane?
    private var ghostScrollTurn = RoomFurnitureScrollTurn()
    /// The painting asked for as the ghost first appeared, for the box it stood in then (keyframe pixels), so a learner
    /// who places the piece where Clicky put it waits less. A move drops it.
    private var paintingAhead: (boxInTheKeyframe: [CGPoint], task: Task<RoomFurniturePaintingAheadOutcome, Never>)?
    private var stepAsideWasSaid = false
    /// The keyframe taken while the page is still read, and the wall measured on it, so the depth service's run overlaps the
    /// page read. The first measurement uses it, and the depth service answers the floor on it from its cache.
    private var earlyMeasurement: Task<RoomArtEarlyMeasurement?, Never>?

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
        furniturePaintingTask?.cancel()
        furniturePaintingTask = nil
        furnitureRenderTask?.cancel()
        furnitureRenderTask = nil
        furnitureLookDeadlineTask?.cancel()
        furnitureLookDeadlineTask = nil
        furnitureLookSearch = nil
        furniturePlacement = nil
        furnitureRenderHeldBack = nil
        keyframeOfTheLatestMeasurement = nil
        furnitureCutoutJPEG = nil
        compositeServiceIsUnavailable = false
        stepBackWasSaid = false
        forgetTheGhost()
        earlyMeasurement?.cancel()
        earlyMeasurement = nil
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
        if case .waitingForTheCamera = phase {
            startAMeasurement(anchorInCameraPixels: nil)
        } else if case .readingThePage = phase {
            startMeasuringEarly()
        }
    }

    /// Takes the keyframe while the page is still read and measures its wall, which costs the depth service's one run of
    /// about 14 seconds. The depth service keeps that run's depth by the frame's bytes, so the floor measured on the same
    /// keyframe once the page reads as furniture takes under a second, and wall art reuses the wall.
    private func startMeasuringEarly() {
        guard earlyMeasurement == nil else { return }
        let frameProcessor = frameProcessor, measureTheWall = environment.measureTheWall
        earlyMeasurement = Task {
            // A shirt read before this task first runs has cancelled it and forgotten the keyframe, so it takes none.
            guard !Task.isCancelled, let keyframe = await frameProcessor.takeAKeyframe(on: nil, anchorInCameraPixels: nil) else { return nil }
            let wallRequest = RoomWallRequest(
                keyframeJPEGData: keyframe.measurementRequest.keyframeJPEGData,
                personMaskPNGData: keyframe.measurementRequest.personMaskPNGData,
                anchor: keyframe.wallSpotAnchor ?? keyframe.measurementRequest.anchor
            )
            let wall: Result<WallPlane, Error>
            do { wall = .success(try await measureTheWall(wallRequest)) } catch { wall = .failure(error) }
            return RoomArtEarlyMeasurement(keyframe: keyframe, wall: wall)
        }
        print("Room art: took the keyframe while the page is read, and measures its wall now")
    }

    // MARK: Placing the ghost

    /// The pointer pressed on the video. While the ghost shows, it grabs the ghost, or moves it there when the press is
    /// off it. A press on placed furniture picks the piece back up as its ghost first (`aPressPicksTheFurnitureUp`).
    /// Anywhere else, a press places the item the way a click always has (`placeTheItem`).
    func pointerPressed(atCameraPixel cameraPixel: CGPoint) {
        if aPressPicksTheFurnitureUp(atCameraPixel: cameraPixel) {
            pickTheFurnitureBackUp()
        }
        guard phase.furnitureGhostShows else {
            placeTheItem(atCameraPixel: cameraPixel)
            return
        }
        guard var ghost = furnitureGhost, let trackedWarp = trackedWarpForTheGhost(),
              let floorPoint = trackedWarp.floorPoint(underCurrentPixel: cameraPixel, of: ghost) else { return }
        let keyframePixel = trackedWarp.keyframeToCurrent.inverted.apply(to: cameraPixel)
        ghost.grab(atFloorPoint: floorPoint, onTheGhost: ghost.contains(keyframePixel: keyframePixel))
        moveTheGhost(to: ghost)
    }

    func pointerDragged(toCameraPixel cameraPixel: CGPoint) {
        guard phase.furnitureGhostShows, var ghost = furnitureGhost, ghost.isBeingDragged, let trackedWarp = trackedWarpForTheGhost(),
              let floorPoint = trackedWarp.floorPoint(underCurrentPixel: cameraPixel, of: ghost) else { return }
        ghost.drag(toFloorPoint: floorPoint)
        moveTheGhost(to: ghost)
    }

    func pointerReleased() {
        guard var ghost = furnitureGhost, ghost.isBeingDragged else { return }
        ghost.release()
        furnitureGhost = ghost
    }

    /// The scroll wheel or the trackpad over the ghost turns it in 15 degree steps. Momentum after a trackpad flick is left
    /// out, since it would spin the ghost on after the fingers stopped.
    func scrolled(byDeltaY deltaY: Double, hasPreciseDeltas: Bool, isMomentum: Bool, atCameraPixel cameraPixel: CGPoint) {
        guard phase.furnitureGhostShows, !isMomentum, var ghost = furnitureGhost, let trackedWarp = trackedWarpForTheGhost(),
              ghost.contains(keyframePixel: trackedWarp.keyframeToCurrent.inverted.apply(to: cameraPixel)) else { return }
        let steps = ghostScrollTurn.steps(afterScrollingBy: deltaY, hasPreciseDeltas: hasPreciseDeltas)
        guard steps != 0 else { return }
        ghost.turn(byDegrees: Double(steps) * RoomFurnitureScrollTurn.degreesPerStep)
        moveTheGhost(to: ghost)
    }

    /// Whether a press there picks placed furniture back up: a press on the piece while it shows or is being painted, so a
    /// stray press elsewhere keeps a painting that cost a request, and any press after Clicky could not draw it, since
    /// nothing is drawn there to aim at.
    func aPressPicksTheFurnitureUp(atCameraPixel cameraPixel: CGPoint) -> Bool {
        guard phase.pickingTheFurnitureBackUp(placementID: RoomArtMeasurementID(number: 0)) != phase else { return false }
        if case .couldNotDraw = phase { return true }
        guard let furnitureGhost, let trackedWarp = trackedWarpForTheGhost() else { return false }
        return furnitureGhost.contains(keyframePixel: trackedWarp.keyframeToCurrent.inverted.apply(to: cameraPixel))
    }

    /// Whether a pixel of the current frame is on the ghost, for the open hand over it.
    func ghostIsUnder(cameraPixel: CGPoint) -> Bool {
        guard phase.furnitureGhostShows, let furnitureGhost, let trackedWarp = trackedWarpForTheGhost() else { return false }
        return furnitureGhost.contains(keyframePixel: trackedWarp.keyframeToCurrent.inverted.apply(to: cameraPixel))
    }

    /// "Move it a bit to the left" or "turn it". Nil when the ghost moved, or why it did not: no ghost shows, a direction
    /// came with a distance that moves nothing, or the move would take the whole piece out of view, so the voice tool fails
    /// with that reason instead of claiming it, and the ghost stays where it was.
    @discardableResult
    func nudgeTheFurniture(_ direction: RoomFurnitureNudgeDirection?, distanceCentimeters: Double?, turnDegrees: Double?) -> RoomFurnitureNudgeRefusal? {
        guard phase.furnitureGhostShows, var ghost = furnitureGhost else { return .noGhost }
        let distance = distanceCentimeters ?? roomFurnitureDefaultNudgeCentimeters
        if direction != nil, !(distance.isFinite && distance > 0) { return .distanceMovesNothing }
        ghost.nudge(direction, distanceMeters: distance / 100, turnDegrees: turnDegrees ?? 0)
        guard ghost.shareOfTheBoxInTheFrame > 0 else { return .leavesTheView }
        moveTheGhost(to: ghost)
        return nil
    }

    /// "Right there", the Place button, or `place_furniture`: the piece is painted where its ghost stands. False when no
    /// ghost shows.
    @discardableResult
    func placeTheFurnitureWhereItsGhostStands() -> Bool {
        guard phase.furnitureGhostShows, var ghost = furnitureGhost else { return false }
        ghost.release()
        furnitureGhost = ghost
        lastMeasurementNumber += 1
        apply(phase.placingTheFurnitureWhereItsGhostStands(placementID: RoomArtMeasurementID(number: lastMeasurementNumber)))
        return true
    }

    /// The ghost moved: it shows there at once, and a painting asked for its earlier box is dropped.
    private func moveTheGhost(to movedGhost: RoomFurnitureGhost) {
        furnitureGhost = movedGhost
        if let paintingAhead, paintingAhead.boxInTheKeyframe != movedGhost.keyframeBoxCorners {
            paintingAhead.task.cancel()
            self.paintingAhead = nil
            print("Room furniture: the ghost moved, so the painting asked for ahead is dropped")
        }
    }

    /// A press on placed furniture: the painting or the look it shows goes, and its ghost draws itself again where it stood.
    private func pickTheFurnitureBackUp() {
        guard let placedGhost = furnitureGhost else { return }
        lastMeasurementNumber += 1
        let pickedUpPhase = phase.pickingTheFurnitureBackUp(placementID: RoomArtMeasurementID(number: lastMeasurementNumber))
        guard pickedUpPhase != phase else { return }
        stopTheFurnituresLooks()
        frameProcessor.hideTheItem()
        furnitureGhost = RoomFurnitureGhost(pickedUpFrom: placedGhost)
        furnitureGhostDraw = RoomFurnitureGhostDraw(beganAt: ProcessInfo.processInfo.systemUptime, tracerStartInThePanel: nil)
        print("Room furniture: picked the piece back up as its ghost")
        apply(pickedUpPhase)
    }

    /// The tracker's turn for the ghost's keyframe, or nil while the room is lost or a newer keyframe was taken.
    private func trackedWarpForTheGhost() -> RoomArtTrackedWarp? {
        guard let trackedWarp = frameProcessor.currentTrackedWarp(), let keyframe = keyframeOfTheLatestMeasurement,
              trackedWarp.keyframeNumber == keyframe.keyframeNumber, !trackedWarp.theRoomIsLost else { return nil }
        return trackedWarp
    }

    /// The ghost's lines in the panel's points this moment, through the tracker's newest turn, or nil while the room is lost.
    func currentGhostLines(cameraSize: CGSize, panelSize: CGSize) -> RoomFurnitureGhostLines? {
        guard let boxCorners = furnitureGhost?.keyframeBoxCorners, let trackedWarp = trackedWarpForTheGhost() else { return nil }
        return RoomFurnitureGhostLines(keyframeBoxCorners: boxCorners, keyframeToCurrent: trackedWarp.keyframeToCurrent, fit: RoomArtVideoFit(cameraSize: cameraSize, viewSize: panelSize), cameraSize: cameraSize)
    }

    /// Where the loop's tracer is in the panel now, which the ghost's tracer leaves from, so the theme's glyph moves on from
    /// one line to the other.
    private func loopTracerInThePanel() -> CGPoint? {
        guard let beganAt = loopState.beganAt,
              let outline = currentLoopOutline(cameraSize: frameProcessor.metalLayer.drawableSize, panelSize: RoomArtPanelController.panelSize) else { return nil }
        // The loop has just stopped lapping for the ghost, so its glyph's place is read as it was while it lapped.
        let plan = RoomArtLoopDrawingPlan.at(secondsSinceTheLoopBegan: ProcessInfo.processInfo.systemUptime - beganAt, reduceMotionIsOn: false, tracesTheLine: true)
        let line = CursorLoopLine(outline: outline)
        return line.point(atShare: RoomArtLoopCanvas.shareOfTheLine(for: plan.frame.tracer, on: line))
    }

    /// Forgets the ghost and everything asked for it, for a close or a new measurement.
    private func forgetTheGhost() {
        paintingAhead?.task.cancel()
        paintingAhead = nil
        furnitureGhost = nil
        furnitureGhostDraw = nil
        waitingForTheLearnerToStepAside = false
        stepAsideWasSaid = false
        wallOfTheLatestMeasurement = nil
        ghostScrollTurn = RoomFurnitureScrollTurn()
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
            // A shirt measures no surface, so the keyframe taken during the page read is not tracked.
            earlyMeasurement?.cancel()
            earlyMeasurement = nil
            frameProcessor.forgetTheKeyframe()
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
        forgetTheGhost()
        // A click measures where it points, so only the first measurement takes the keyframe taken during the page read.
        let earlyMeasurement = anchorInCameraPixels == nil ? self.earlyMeasurement : nil
        self.earlyMeasurement = nil

        measurementTask = Task {
            let early = await earlyMeasurement?.value
            let keyframeOrNil: RoomArtKeyframe?
            if let early {
                keyframeOrNil = early.keyframe
            } else {
                keyframeOrNil = await frameProcessor.takeAKeyframe(on: surfaceKind, anchorInCameraPixels: anchorInCameraPixels)
            }
            guard let keyframe = keyframeOrNil else {
                apply(phase.afterTheMeasurementFailed(surfaceKind.cannotPlaceFailure, measurementID: measurementID))
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let surface: RoomArtSurface
                switch surfaceKind {
                case .wall:
                    let wall: WallPlane
                    if let early, let wallSpot = keyframe.wallSpotAnchor {
                        // The early keyframe's loop went around the floor spot, so it moves to the wall spot it measured.
                        frameProcessor.outlineTheLoop(around: wallSpot, on: .wall, inKeyframeNumber: keyframe.keyframeNumber)
                        wall = try early.wall.get()
                    } else {
                        wall = try await environment.measureTheWall(keyframe.measurementRequest)
                    }
                    print(String(format: "Room art: wall %.2f m away at %.0f degrees, %.0f%% of it fits the plane", wall.distanceMeters, wall.wallAngleDegrees, wall.planeInlierShare * 100))
                    surface = .wall(wall)
                case .floor:
                    let floor = try await measureTheFurnituresFloor(on: keyframe, for: measuringPhase.itemBeingMeasured, anchorWasClicked: anchorInCameraPixels != nil, wallAlreadyMeasured: early?.wall)
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

    /// Moves to `newPhase` and does what entering it means: look for furniture's first look while it is arranged, place wall
    /// art when it shows, put the item back when a move failed, say "Here it is" once when the item shows, and say why when
    /// the panel fails.
    private func apply(_ newPhase: RoomArtPhase) {
        guard newPhase != phase else { return }
        phase = newPhase
        switch newPhase {
        case .showing(let item, let surface, let moveFailure):
            if let moveFailure {
                // The camera keeps running and only the status line says why, since the learner is looking at the panel.
                print("Room art: the item stays where it was, since the move failed: \(moveFailure)")
                frameProcessor.putBackTheItemFromBeforeTheMove()
                return
            }
            // Furniture's look was drawn before the panel entered `showing`, so only wall art is placed here. The phase's
            // transitions show the item only on a surface where its corners land, so this always places it.
            if case .wallArt(let artwork) = item {
                guard let keyframeCorners = surface.keyframeCorners(of: item) else { return }
                frameProcessor.showTheWallArt(artwork.flattenedImage, keyframeCorners: keyframeCorners)
            }
            sayHereItIsOnce(item.hereItIsLine)
            // Whether the whole piece shows is read from where the learner placed its ghost, not from the spot search.
            if case .furniture = item, let furnitureGhost, furnitureGhost.shareOfTheBoxInTheFrame < roomFurnitureShareOfTheBoxThatShowsWhole, !stepBackWasSaid {
                stepBackWasSaid = true
                environment.speak(roomFurnitureStepBackLine, false)
            }
        case .placingTheFurniture(_, let item, let surface):
            stopTheFurnituresLooks()
            // A pick-up made its ghost already. The first time, the ghost stands where the spot search put the piece, and its
            // tracer leaves the measuring loop's line.
            guard furnitureGhost == nil else { return }
            guard case .furniture(let furniture) = item, case .floor(let floor) = surface,
                  let ghost = RoomFurnitureGhost(standingOn: floor, wall: wallOfTheLatestMeasurement, widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters) else {
                print("Room furniture: the ghost cannot stand on this floor, so the panel asks for a click on the floor")
                apply(phase.afterTheGhostCouldNotStand())
                return
            }
            furnitureGhostDraw = RoomFurnitureGhostDraw(beganAt: ProcessInfo.processInfo.systemUptime, tracerStartInThePanel: loopTracerInThePanel())
            furnitureGhost = ghost
            print("Room furniture: the ghost shows\(ghost.shownPose.isSnappedToTheWall ? ", square to the wall" : "")")
            startPaintingAhead(for: ghost, furniture: furniture)
        case .arranging(let measurementID, let item, let surface):
            stopTheFurnituresLooks()
            guard case .furniture(let furniture) = item, case .floor(let floor) = surface, let keyframe = keyframeOfTheLatestMeasurement,
                  let ghost = furnitureGhost, let boxInTheKeyframe = ghost.keyframeBoxCorners else {
                furniturePlacement = nil
                print("Room furniture: the placement could not be read, so nothing can be painted")
                apply(phase.afterTheFurnitureCouldNotBeDrawn(measurementID: measurementID))
                return
            }
            // While the painting comes, the loop goes around the ghost's footprint, which stays at half opacity.
            // The loop traces the placed footprint: back left, back right, front right, front left, clockwise on screen.
            frameProcessor.outlineTheLoop(
                aroundKeyframeQuadrilateral: RoomArtCorners(clockwiseFromTopLeft: [boxInTheKeyframe[7], boxInTheKeyframe[6], boxInTheKeyframe[2], boxInTheKeyframe[3]]),
                inKeyframeNumber: keyframe.keyframeNumber
            )
            print(String(
                format: "Room furniture: placed facing %@%@%@", ghost.facing.rawValue,
                ghost.shownPose.isSnappedToTheWall ? ", its back on the wall" : "", floor.inferredFromTheWall ? ", on a floor inferred from the wall" : ""
            ))
            // The painting is the piece's first look, and the model's render shows only if none comes in time.
            furniturePlacement = (measurementID, furniture, keyframe, floor, ghost)
            furniturePaintingCannotCome = false
            furnitureWaitRanOut = false
            startPaintingTheFurniture()
            startRenderingTheFurnituresModel()
            let thisOpening = openingNumber
            let waitTheLongestForAFurnitureLook = environment.waitTheLongestForAFurnitureLook
            furnitureLookDeadlineTask = Task {
                await waitTheLongestForAFurnitureLook()
                guard !Task.isCancelled, thisOpening == openingNumber, furniturePlacement?.measurementID == measurementID else { return }
                furnitureWaitRanOut = true
                showTheFurnitureFallbackIfItIsDue()
            }
        case .couldNotDraw:
            // The loop stays and the camera keeps running, so a click on the floor picks the ghost back up there.
            environment.speak(roomFurnitureNotDrawnLine, true)
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

    /// Stops every look on its way for the placement before, for a new placement or a pick-up.
    private func stopTheFurnituresLooks() {
        furnitureLookDeadlineTask?.cancel()
        furniturePaintingTask?.cancel()
        furnitureRenderTask?.cancel()
        furnitureRenderIsRunning = false
        furnitureRenderHeldBack = nil
        waitingForTheLearnerToStepAside = false
        stepAsideWasSaid = false
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
    fileprivate func measureTheFurnituresFloor(
        on keyframe: RoomArtKeyframe, for item: RoomArtPlacedItem?, anchorWasClicked: Bool, wallAlreadyMeasured: Result<WallPlane, Error>? = nil
    ) async throws -> FloorPlane {
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
            // The wall measured during the page read stood at this same spot on this same keyframe.
            if let wallAlreadyMeasured {
                wall = try wallAlreadyMeasured.get()
            } else {
                wall = try await environment.measureTheWall(wallRequest)
            }
        } catch {
            print("Room furniture: the wall behind the floor was not measured: \(error)")
            wall = nil
        }
        wallOfTheLatestMeasurement = wall
        if let measuredFloor, let floorForThePiece {
            guard let wall, !measuredFloor.agrees(withTheWall: wall) else { return floorForThePiece }
            print("Room furniture: the measured floor is not level with the wall, so it is a desk or a bed, not the floor")
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
    /// piece no spot shows whole is placed where most of it shows. Where the learner places its ghost decides the step back
    /// line, said once after "Here it is" when the placed piece does not all show.
    private func floorWhereTheWholePieceShows(_ measuredFloor: FloorPlane, on keyframe: RoomArtKeyframe, for item: RoomArtPlacedItem?, anchorWasClicked: Bool) -> FloorPlane {
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

    /// Searches for a model of the furniture while its floor is measured: the store's own model in the page, else a model
    /// the generation service makes. Either is rendered only as the painting's fallback. When the search ends it renders the
    /// newest placement's model, or tells its fallback that no render is coming.
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
            furnitureLookSearch = foundModel.map { .found($0) } ?? .noModel
            startRenderingTheFurnituresModel()
            showTheFurnitureFallbackIfItIsDue()
        }
    }

    /// Paints the newest placement's composite, its first look: it takes 15 to 20 seconds and looks real (a real contact
    /// shadow and the room's own light), and any look shown before it made the painting read as a small change. It does not
    /// wait for the model search. When no painting can come (the service is not set up, two paintings were refused, or the
    /// request failed), the fallback shows: the model's render, else the line that the piece could not be drawn.
    private func startPaintingTheFurniture() {
        guard let placement = furniturePlacement, let boxInTheKeyframe = placement.ghost.keyframeBoxCorners else { return }
        furniturePaintingTask?.cancel()
        let thisOpening = openingNumber
        // The painting asked for as the ghost appeared counts only when the piece stands in the box it was asked for.
        let paintingAheadForThisBox = paintingAhead.flatMap { $0.boxInTheKeyframe == boxInTheKeyframe ? $0.task : nil }
        if paintingAheadForThisBox == nil { paintingAhead?.task.cancel() }
        paintingAhead = nil
        let orientation = placement.ghost.paintingOrientation
        furniturePaintingTask = Task {
            var finishedPainting: RoomFurnitureFinishedPainting?
            var paintingsWereAskedFor = false
            if let paintingAheadForThisBox {
                print("Room furniture: the piece stands where Clicky put it, so the painting asked for ahead is used")
                switch await withTaskCancellationHandler(operation: { await paintingAheadForThisBox.value }, onCancel: { paintingAheadForThisBox.cancel() }) {
                case .painted(let paintingAhead): finishedPainting = paintingAhead
                // Its two paintings were refused or failed, which another two for the same box would likely repeat.
                case .noPaintingStood: paintingsWereAskedFor = true
                case .notAsked: break
                }
            }
            if finishedPainting == nil, !paintingsWereAskedFor, !compositeServiceIsUnavailable,
               let paintingFrame = await aClearFrameForThePainting(boxInTheKeyframe: boxInTheKeyframe, thisOpening: thisOpening) {
                finishedPainting = await paintTheComposite(
                    furniture: placement.furniture, paintingFrame: paintingFrame, boxInTheKeyframe: boxInTheKeyframe,
                    orientation: orientation, keyframeNumber: placement.keyframe.keyframeNumber, thisOpening: thisOpening
                )
            }
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            if let finishedPainting {
                frameProcessor.showTheFurnitureLayers(finishedPainting.layers, keyframeNumber: finishedPainting.keyframeNumber, layerToKeyframe: finishedPainting.layerToKeyframe)
                print("Room furniture: showing the painted composite\(placement.floor.inferredFromTheWall ? ", painted on a floor inferred from the wall" : "")")
                apply(phase.withTheFurnitureShowing(measurementID: placement.measurementID))
                return
            }
            furniturePaintingCannotCome = true
            showTheFurnitureFallbackIfItIsDue()
        }
    }

    /// As the ghost first appears, its painting is asked for in the background, for the box it stands in then, since a
    /// learner who places the piece where Clicky put it then waits seconds instead of 20. A move drops it
    /// (`moveTheGhost`). Nothing is asked for while the learner stands in that box, since the painter would draw through them.
    private func startPaintingAhead(for ghost: RoomFurnitureGhost, furniture: RoomFurniture) {
        paintingAhead?.task.cancel()
        paintingAhead = nil
        guard !compositeServiceIsUnavailable, furnitureCutoutJPEG != nil, let boxInTheKeyframe = ghost.keyframeBoxCorners,
              let keyframe = keyframeOfTheLatestMeasurement else { return }
        let thisOpening = openingNumber, orientation = ghost.paintingOrientation, frameProcessor = frameProcessor
        let task = Task { () -> RoomFurniturePaintingAheadOutcome in
            guard let paintingFrame = await frameProcessor.aFrameForThePainting(boxInTheKeyframe: boxInTheKeyframe) else { return .notAsked }
            guard paintingFrame.shareOfTheBoxThePersonCovers <= roomFurnitureMostOfTheBoxThePersonMayCover else {
                print("Room furniture: the learner stands where the ghost is, so nothing is painted ahead")
                return .notAsked
            }
            print("Room furniture: painting ahead where the ghost stands")
            let finishedPainting = await paintTheComposite(
                furniture: furniture, paintingFrame: paintingFrame, boxInTheKeyframe: boxInTheKeyframe,
                orientation: orientation, keyframeNumber: keyframe.keyframeNumber, thisOpening: thisOpening
            )
            return finishedPainting.map { .painted($0) } ?? .noPaintingStood
        }
        paintingAhead = (boxInTheKeyframe, task)
    }

    /// The newest frame once the learner is out of the box, which the painting is made on. While they cover it, Clicky
    /// says "Step aside for a second." once and the status line asks too. Nil when the task is cancelled or the panel closed.
    private func aClearFrameForThePainting(boxInTheKeyframe: [CGPoint], thisOpening: Int) async -> RoomArtPaintingFrame? {
        defer { if thisOpening == openingNumber { waitingForTheLearnerToStepAside = false } }
        while !Task.isCancelled, thisOpening == openingNumber {
            if let paintingFrame = await frameProcessor.aFrameForThePainting(boxInTheKeyframe: boxInTheKeyframe) {
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                if paintingFrame.shareOfTheBoxThePersonCovers <= roomFurnitureMostOfTheBoxThePersonMayCover { return paintingFrame }
                waitingForTheLearnerToStepAside = true
                if !stepAsideWasSaid {
                    stepAsideWasSaid = true
                    print(String(format: "Room furniture: the learner covers %.0f%% of the box, so the painting waits for them to step aside", paintingFrame.shareOfTheBoxThePersonCovers * 100))
                    environment.speak(roomFurnitureStepAsideLine, false)
                }
            }
            // No frame while the room is lost, or the learner still in the way: look again shortly.
            try? await Task.sleep(for: .milliseconds(300))
        }
        return nil
    }

    /// Renders the model found for the newest placement and holds the render back as the painting's fallback. Waits for the
    /// search while it runs, since the search calls this again when it ends.
    private func startRenderingTheFurnituresModel() {
        guard let placement = furniturePlacement, case .found(let model) = furnitureLookSearch else { return }
        furnitureRenderTask?.cancel()
        let thisOpening = openingNumber
        furnitureRenderIsRunning = true
        furnitureRenderTask = Task {
            if let keyframeImage = decodedKeyframe(placement.keyframe) {
                await renderTheModel(model, furniture: placement.furniture, keyframe: placement.keyframe, keyframeImage: keyframeImage, floor: placement.floor, ghost: placement.ghost, measurementID: placement.measurementID, thisOpening: thisOpening)
            }
            // A render that ended in any way, made or not, may be what the fallback waited for. A newer placement resets
            // the flag itself, so a cancelled task leaves it alone.
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            furnitureRenderIsRunning = false
            showTheFurnitureFallbackIfItIsDue()
        }
    }

    /// Where the newest placement's render stands, for its fallback.
    private var furnitureRenderState: RoomFurnitureRenderState {
        guard let furniturePlacement else { return .none }
        if let furnitureRenderHeldBack, furnitureRenderHeldBack.measurementID == furniturePlacement.measurementID { return .ready }
        if furnitureRenderIsRunning { return .coming }
        if case .searching = furnitureLookSearch { return .coming }
        return .none
    }

    /// Shows the newest placement's fallback when `roomFurnitureFallbackStep` says it is due: the model's render, else no
    /// piece and a line that says it could not be drawn, since the flat cutout reads as a sticker. A placement that already
    /// shows a look changes nothing, a painting that arrives later still crossfades over the render or shows the piece, and
    /// a render that finishes after the piece could not be drawn still shows it.
    private func showTheFurnitureFallbackIfItIsDue() {
        guard let furniturePlacement else { return }
        let reason = furnitureWaitRanOut ? "no painting came within \(Int(roomFurnitureSecondsToWaitForALook)) s" : "no painting can come"
        let measurementID = furniturePlacement.measurementID
        switch roomFurnitureFallbackStep(paintingCannotCome: furniturePaintingCannotCome, theWaitRanOut: furnitureWaitRanOut, render: furnitureRenderState) {
        case .keepWaiting:
            return
        case .showTheRender:
            let showingPhase = phase.withTheFurnitureShowing(measurementID: measurementID)
            guard showingPhase != phase, let furnitureRenderHeldBack else { return }
            print("Room furniture: showing the \(furnitureRenderHeldBack.layers.look.rawValue), since \(reason)")
            frameProcessor.showTheFurnitureLayers(furnitureRenderHeldBack.layers, keyframeNumber: furniturePlacement.keyframe.keyframeNumber, layerToKeyframe: .identity)
            apply(showingPhase)
        case .sayItCouldNotBeDrawn:
            let couldNotDrawPhase = phase.afterTheFurnitureCouldNotBeDrawn(measurementID: measurementID)
            guard couldNotDrawPhase != phase else { return }
            print("Room furniture: nothing to draw, since \(reason) and there is no render")
            apply(couldNotDrawPhase)
        }
    }

    /// Renders the model for this placement and holds the render back as the fallback for the painting.
    private func renderTheModel(
        _ model: RoomFurnitureLoadedModel, furniture: RoomFurniture, keyframe: RoomArtKeyframe, keyframeImage: CGImage, floor: FloorPlane,
        ghost: RoomFurnitureGhost, measurementID: RoomArtMeasurementID, thisOpening: Int
    ) async {
        // The model stands in the ghost's box, turned and against the wall as the learner placed it.
        guard let placement = ghost.shownPlacement else { return }
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
            print("Room furniture: the \(model.look.rawValue) did not render, so there is no render to fall back on")
            return
        }
        furnitureRenderHeldBack = (measurementID, layers)
        print("Room furniture: rendered the \(model.look.rawValue) from \(model.originForTheLog), held back while the painting comes")
    }

    /// Asks for the painted composite on `paintingFrame`, twice at most, and returns it as layers in the keyframe's space,
    /// or nil when no painting stood at the measured size and on the footprint.
    private func paintTheComposite(
        furniture: RoomFurniture, paintingFrame: RoomArtPaintingFrame, boxInTheKeyframe: [CGPoint], orientation: RoomFurniturePaintingOrientation,
        keyframeNumber: Int, thisOpening: Int
    ) async -> RoomFurnitureFinishedPainting? {
        let projectedBox = paintingFrame.boxInThisFrame(boxInTheKeyframe)
        let frameImage = paintingFrame.image
        guard let furnitureCutoutJPEG,
              let maskPNG = environment.compositeMaskPNG(projectedBox, frameImage.width, frameImage.height, Self.compositeShadowMarginPixels) else { return nil }
        // The service paints each request afresh, so a painting refused for its height or its footprint, or a failed
        // request, is asked for once more before the piece falls back to the model's render.
        for attempt in 1...Self.mostPaintingAttempts {
            do {
                let painted = try await environment.furnitureGeneration.paintTheItemIntoTheKeyframe(
                    keyframeJPEG: paintingFrame.jpegData,
                    keyframeWidth: frameImage.width,
                    keyframeHeight: frameImage.height,
                    productJPEG: furnitureCutoutJPEG,
                    maskPNG: maskPNG,
                    itemTitle: furniture.title,
                    itemSizeWords: furniture.sizeInWords,
                    orientation: orientation
                )
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                #if DEBUG
                // Verification reads the painting the checks judged, kept or refused, with what it was judged against.
                // Debug builds only.
                writeThePaintingForVerification(painted, keyframeJPEG: paintingFrame.jpegData, maskPNG: maskPNG, projectedBox: projectedBox)
                #endif
                if let layers = await environment.paintedItemLayers(painted, frameImage, maskPNG, projectedBox) {
                    guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                    // The painting is in the painting frame's pixels, which go back to the keyframe through the tracker's turn.
                    return RoomFurnitureFinishedPainting(layers: layers, keyframeNumber: keyframeNumber, layerToKeyframe: paintingFrame.keyframeToFrame.inverted)
                }
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                print("Room furniture: painting \(attempt) is shorter than the box's front, taller than its outline, off its footprint, or cut off, so it is not shown")
            } catch {
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                print("Room furniture: no painted composite from painting \(attempt): \(error)")
                // A Worker with no OpenAI key stays that way for this panel, so later placements do not ask again.
                if case RoomFurnitureGenerationError.serviceIsNotSetUp = error { compositeServiceIsUnavailable = true }
                guard roomFurniturePaintingIsWorthAskingForAgain(after: error) else { return nil }
            }
        }
        print("Room furniture: no painting stood at the measured size")
        return nil
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
        case .waitingForTheCamera, .measuring, .placingTheFurniture, .couldNotDraw, .moving, .waitingForAFloorClick: return true
        // Placed furniture moves only by a press on the piece, which shows the open hand, so a press beside it does nothing.
        case .showing(let item, _, _): return item.surfaceKind != .floor
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
    @State private var placeButtonIsHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ghostOpacity: Double? {
        switch previewController.phase {
        case .placingTheFurniture: return 1
        // While the painting comes, the ghost stays at half opacity where the piece will appear.
        case .arranging: return 0.5
        default: return nil
        }
    }

    var body: some View {
        ZStack {
            DS.Colors.background
            RoomArtVideoView(
                metalLayer: metalLayer,
                showsTheCrosshair: previewController.phase.theItemIsPlacedByClicking,
                onPress: { cameraPixel in previewController.pointerPressed(atCameraPixel: cameraPixel) },
                onDrag: { cameraPixel in previewController.pointerDragged(toCameraPixel: cameraPixel) },
                onRelease: { previewController.pointerReleased() },
                onScroll: { deltaY, hasPreciseDeltas, isMomentum, cameraPixel in
                    previewController.scrolled(byDeltaY: deltaY, hasPreciseDeltas: hasPreciseDeltas, isMomentum: isMomentum, atCameraPixel: cameraPixel)
                },
                pointerIsOnTheGhost: { cameraPixel in previewController.ghostIsUnder(cameraPixel: cameraPixel) },
                theGhostIsHeld: { previewController.furnitureGhost?.isBeingDragged == true },
                aPressPicksTheFurnitureUp: { cameraPixel in previewController.aPressPicksTheFurnitureUp(atCameraPixel: cameraPixel) }
            )
            if !previewController.loopState.isHidden {
                RoomArtLoopView(
                    state: previewController.loopState,
                    color: previewController.loopAccentColor,
                    tracerLook: previewController.loopTracerLook,
                    outlineProvider: {
                        previewController.currentLoopOutline(cameraSize: metalLayer.drawableSize, panelSize: RoomArtPanelController.panelSize)
                    },
                    onFadeFinished: { previewController.theLoopFadeFinished() }
                )
            }
            if let ghostOpacity, let ghost = previewController.furnitureGhost, let ghostDraw = previewController.furnitureGhostDraw {
                RoomFurnitureGhostView(
                    draw: ghostDraw,
                    color: previewController.loopAccentColor,
                    tracerLook: previewController.loopTracerLook,
                    sizePillText: roomFurnitureGhostSizePillText(widthMeters: ghost.widthMeters, heightMeters: ghost.heightMeters),
                    linesProvider: {
                        previewController.currentGhostLines(cameraSize: metalLayer.drawableSize, panelSize: RoomArtPanelController.panelSize)
                    }
                )
                .opacity(ghostOpacity)
                .animation(.easeOut(duration: 0.3), value: ghostOpacity)
                .transition(.opacity.animation(.easeOut(duration: 0.5)))
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
                ZStack {
                    statusLine
                    if previewController.phase.furnitureGhostShows {
                        HStack {
                            Spacer()
                            placeButton
                        }
                    }
                }
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

    /// Places the piece where its ghost stands, as "right there" does. Filled with the theme's accent so it reads at a
    /// glance over any room, with the Tether ink on it.
    private var placeButton: some View {
        Button {
            previewController.placeTheFurnitureWhereItsGhostStands()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                Text("Place")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(DS.Colors.inkOnAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(previewController.loopAccentColor))
            .overlay(Capsule().stroke(DS.Colors.textPrimary.opacity(placeButtonIsHovered ? 0.7 : 0.25), lineWidth: placeButtonIsHovered ? 2 : 1))
            .shadow(color: DS.Colors.inkOnAccent.opacity(0.35), radius: placeButtonIsHovered ? 8 : 4, y: 2)
            // Hover grows the button a little on the Snap move, and with Reduce Motion only its edge and shadow change.
            .scaleEffect(placeButtonIsHovered && !reduceMotion ? 1.04 : 1)
            .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: placeButtonIsHovered)
        }
        .buttonStyle(.plain)
        .hoverAndPointer { isHovered in placeButtonIsHovered = isHovered }
        .accessibilityLabel("Place it here")
    }

    @ViewBuilder
    private var statusLine: some View {
        let statusText = previewController.waitingForTheLearnerToStepAside
            ? roomFurnitureStepAsideLine
            : previewController.phase.statusLine(theSurfaceIsLost: previewController.theSurfaceIsLost, shirtCoachingLine: previewController.shirtCoachingLine)
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

/// The video, drawn by the frame processor into its Metal layer. A press, a drag, a release, and the scroll wheel report
/// the camera pixel under the pointer.
private struct RoomArtVideoView: NSViewRepresentable {
    let metalLayer: CAMetalLayer
    /// A click places a wall or floor item, so the crosshair says so. A shirt follows the learner, so a click does nothing.
    let showsTheCrosshair: Bool
    let onPress: (CGPoint) -> Void
    let onDrag: (CGPoint) -> Void
    let onRelease: () -> Void
    let onScroll: (_ deltaY: Double, _ hasPreciseDeltas: Bool, _ isMomentum: Bool, _ cameraPixel: CGPoint) -> Void
    let pointerIsOnTheGhost: (CGPoint) -> Bool
    let theGhostIsHeld: () -> Bool
    let aPressPicksTheFurnitureUp: (CGPoint) -> Bool

    func makeNSView(context: Context) -> RoomArtVideoNSView {
        let videoView = RoomArtVideoNSView(metalLayer: metalLayer)
        updateNSView(videoView, context: context)
        return videoView
    }

    func updateNSView(_ videoView: RoomArtVideoNSView, context: Context) {
        videoView.onPress = onPress
        videoView.onDrag = onDrag
        videoView.onRelease = onRelease
        videoView.onScroll = onScroll
        videoView.pointerIsOnTheGhost = pointerIsOnTheGhost
        videoView.theGhostIsHeld = theGhostIsHeld
        videoView.aPressPicksTheFurnitureUp = aPressPicksTheFurnitureUp
        videoView.showsTheCrosshair = showsTheCrosshair
    }
}

final class RoomArtVideoNSView: NSView {
    private let metalLayer: CAMetalLayer
    var onPress: (CGPoint) -> Void = { _ in }
    var onDrag: (CGPoint) -> Void = { _ in }
    var onRelease: () -> Void = {}
    var onScroll: (Double, Bool, Bool, CGPoint) -> Void = { _, _, _, _ in }
    var pointerIsOnTheGhost: (CGPoint) -> Bool = { _ in false }
    var theGhostIsHeld: () -> Bool = { false }
    var aPressPicksTheFurnitureUp: (CGPoint) -> Bool = { _ in false }
    var showsTheCrosshair = true
    private var crosshairTrackingArea: NSTrackingArea?

    init(metalLayer: CAMetalLayer) {
        self.metalLayer = metalLayer
        super.init(frame: .zero)
        // A layer-hosting view: the processor's Metal layer is this view's own layer.
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("RoomArtVideoNSView is made in code")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The cursor says what a press does. The panel never becomes key, so cursor rects never apply, and an always-active
    /// tracking area sets the cursor instead, as `hoverAndPointer` does, on every move.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let crosshairTrackingArea {
            removeTrackingArea(crosshairTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        crosshairTrackingArea = trackingArea
    }

    /// The closed hand while the ghost is held, the open hand over the ghost or over placed furniture a press picks up,
    /// and the crosshair where a press places the item.
    private func setTheCursor(for event: NSEvent) {
        if theGhostIsHeld() {
            NSCursor.closedHand.set()
        } else if let pointedCameraPixel = cameraPixel(of: event), aPressPicksTheFurnitureUp(pointedCameraPixel) || pointerIsOnTheGhost(pointedCameraPixel) {
            NSCursor.openHand.set()
        } else {
            (showsTheCrosshair ? NSCursor.crosshair : NSCursor.arrow).set()
        }
    }

    override func cursorUpdate(with event: NSEvent) { setTheCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { setTheCursor(for: event) }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let cameraPixel = cameraPixel(of: event) else { return }
        onPress(cameraPixel)
        setTheCursor(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // A drag past the frame's edge keeps its last point inside, so the ghost stops at the edge instead of jumping.
        guard let cameraPixel = cameraPixel(of: event, clampedToTheFrame: true) else { return }
        onDrag(cameraPixel)
    }

    override func mouseUp(with event: NSEvent) {
        onRelease()
        setTheCursor(for: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let cameraPixel = cameraPixel(of: event) else { return }
        onScroll(Double(event.scrollingDeltaY), event.hasPreciseScrollingDeltas, !event.momentumPhase.isEmpty, cameraPixel)
    }

    /// The camera pixel under the event, or nil off the frame. A pixel at the frame's width or height is past its last
    /// pixel, which the depth service refuses as an anchor.
    private func cameraPixel(of event: NSEvent, clampedToTheFrame: Bool = false) -> CGPoint? {
        let pointInView = convert(event.locationInWindow, from: nil)
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        // The video is fit inside the view keeping its shape, so the point is measured inside the fitted rect.
        let fitScale = min(bounds.width / drawableSize.width, bounds.height / drawableSize.height)
        let fittedSize = CGSize(width: drawableSize.width * fitScale, height: drawableSize.height * fitScale)
        let fittedOrigin = CGPoint(x: (bounds.width - fittedSize.width) / 2, y: (bounds.height - fittedSize.height) / 2)
        var cameraPixel = CGPoint(
            x: (pointInView.x - fittedOrigin.x) / fitScale,
            // The view's y grows up and the camera's grows down.
            y: (fittedOrigin.y + fittedSize.height - pointInView.y) / fitScale
        )
        if clampedToTheFrame {
            cameraPixel = CGPoint(x: min(max(cameraPixel.x, 0), drawableSize.width - 1), y: min(max(cameraPixel.y, 0), drawableSize.height - 1))
        }
        guard cameraPixel.x >= 0, cameraPixel.y >= 0, cameraPixel.x < drawableSize.width, cameraPixel.y < drawableSize.height else { return nil }
        return cameraPixel
    }
}
