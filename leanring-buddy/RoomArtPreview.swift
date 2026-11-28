//
//  RoomArtPreview.swift
//  leanring-buddy
//
//  Runs and draws "show me how this would look in my room" and "could I see this shirt on me". `RoomArtPreviewController`
//  reads the page's picture, opens the panel, starts the camera, and asks the Worker what the page shows
//  (`POST /try-it-item`) at once. The item's kind picks the rest: wall art is measured on the wall (`POST /room-wall`) and
//  furniture on the floor (`POST /room-floor`), each from a keyframe taken on the first frame with a person mask, with
//  only the status line while it waits, and a garment the page reader says can be drawn on the learner is painted on them
//  with no measurement: the camera shows them as filmed until they say "paint it", and the painting is the only look.
//  `RoomArtFrameProcessor` handles every camera frame on its own queue: it finds the person, tracks the room against the
//  keyframe, and draws the frame with the item on its surface and the learner in front of it, or, for a garment, finds the
//  learner's torso for the step-back capture and draws the painted top once there is one.
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

extension RoomArtKeyframe {
    /// This keyframe with the placed items drawn into it, as the next item is measured on. The bare wall spot and the floor's
    /// texture are found again on the baked picture, so a floor item's wall is never measured on the front of a bookcase
    /// Clicky painted where the wall spot used to be.
    func baked(keyframeJPEGData: Data, trackGrayscale: RoomGrayscaleImage, trackRoomMask: [Float], cameraPixelsPerTrackPixel: Double) -> RoomArtKeyframe {
        let wallSpotInTrackPixels = bareWallSpot(grayscale: trackGrayscale, roomMask: trackRoomMask)
        return RoomArtKeyframe(
            measurementRequest: RoomWallRequest(
                keyframeJPEGData: keyframeJPEGData, personMaskPNGData: measurementRequest.personMaskPNGData, anchor: measurementRequest.anchor
            ),
            wallLight: wallLight,
            wallSpotAnchor: CGPoint(x: wallSpotInTrackPixels.x * cameraPixelsPerTrackPixel, y: wallSpotInTrackPixels.y * cameraPixelsPerTrackPixel),
            keyframeNumber: keyframeNumber,
            floorTexture: RoomFloorTextureMap(
                width: trackGrayscale.width,
                height: trackGrayscale.height,
                texture: textureWithThePersonMarked(grayscale: trackGrayscale, roomMask: trackRoomMask),
                cameraPixelsPerMapPixel: cameraPixelsPerTrackPixel
            )
        )
    }
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
    /// From the moment it returns, no new frame is submitted and the loop's corners do not move until the next session, a frame
    /// still being processed included. A frame Metal already received can still show.
    func endTheSession()
    func process(_ cameraFrame: CVPixelBuffer)
    /// With no anchor, the spot is the bare wall spot for the wall and the bare floor spot for the floor. With no surface,
    /// which a keyframe taken while the page is still read has, the anchor is the bare floor spot, and the room's light is
    /// read at the bare wall spot, so the keyframe serves wall art and furniture alike. `anchorInCameraPixels` is in the
    /// newest frame. While the room has a background (`fixTheShownItemIntoTheBackground`), no new keyframe is taken, since
    /// the background's items are drawn in the keyframe's pixels: the keyframe returned is the one they stand in, with them
    /// drawn in, the same number, and the anchor moved back into it through the tracker's turn. With no anchor, the bare spot
    /// is searched for on that keyframe, so the placed items count as busy texture and the new item is not placed over one.
    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind?, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe?
    /// A new request keeps the room: the item that shows becomes part of its background (`RoomArtBackground`). It keeps
    /// drawing every frame through the tracker's turn, under the newest item and with the learner in front of it, nothing
    /// hides or moves it, and the keyframe and its tracker stay. Does nothing when no item shows.
    func fixTheShownItemIntoTheBackground()
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
    /// Forgets the keyframe, the loop, and any background drawn in the keyframe's pixels, for a page that turned out to be a
    /// shirt after a keyframe was taken for it.
    func forgetTheKeyframe()
    /// The tracker's newest turn from the keyframe to the current frame, eased like the item's corners, or nil before the
    /// first tracked frame of a keyframe. Safe to call from any thread, since the panel draws the ghost through it.
    func currentTrackedWarp() -> RoomArtTrackedWarp?
    /// The newest camera frame, for a painting: its JPEG, the tracker's turn from the keyframe to it, and how much of
    /// `boxInTheKeyframe` (keyframe pixels) the learner covers in it. Nil before a tracked frame or while the room is lost.
    /// While the room has a background, it is the keyframe with the background drawn in, whatever the newest frame shows:
    /// the item was measured on that image, and a painting made on it holds the items it stands on or beside, so the item's
    /// layer, cut out by its difference from that image, is placed on them pixel for pixel with no turn to undo. The learner
    /// cannot step out of a keyframe, so its share is 0 and the painting never waits.
    func aFrameForThePainting(boxInTheKeyframe: [CGPoint]) async -> RoomArtPaintingFrame?
    func putBackTheItemFromBeforeTheMove()
    /// Starts the shirt try-on instead of tracking a surface: the camera shows the learner as filmed, each frame finds the
    /// torso, and `onTheFramingSettled` runs on the main actor each time the framing settles on a new kind
    /// (`ShirtFramingDebouncer`). The learner's own top is traced for the loop that shows once a frame freezes.
    func startTheShirtTryOn(onTheFramingSettled: @escaping @Sendable (ShirtFramingKind) -> Void)
    /// Arms the capture (`ShirtStepBackCapture`): each frame judges whether the learner stands in the ready framing and holds
    /// still, and the first frame where they have held for the whole countdown freezes the panel as filmed, paired with the
    /// torso found for that same frame. `onEvent` runs on the main actor with the countdown numbers, the frozen frame, or the
    /// time out. The loop traces the learner's own top, held still, then the area being painted, until the painted still
    /// shows or the live camera comes back. Arming again restarts the capture and leaves any frozen frame for the live camera.
    func armTheShirtCapture(onEvent: @escaping @Sendable (ShirtCaptureEvent) -> Void)
    /// Stops waiting for the learner to hold still. Safe with no capture armed.
    func disarmTheShirtCapture()
    /// Crossfades from the frozen frame to the painted still over `shirtPaintedStillCrossfadeSeconds`, and holds it until
    /// the painted top follows the learner (`followTheLearnerWithThePaintedTop`).
    func showThePaintedStill(_ paintedImage: CGImage)
    /// Paint once, then track it: once the painted still shows, the painted top follows the learner in the live camera view
    /// (`ShirtLivePaintedTop`), and the still shows again while they are out of its reach. `onTheHintChanged` runs on the main
    /// actor with whether the learner should be told to stand as they did. Does nothing unless the painted still shows.
    func followTheLearnerWithThePaintedTop(_ paintedTop: ShirtLivePaintedTop, onTheHintChanged: @escaping @Sendable (Bool) -> Void)
    /// Leaves the frozen frame or the painted still, and the live camera draws again.
    func resumeTheLiveShirt()
    /// While the frame is frozen, the loop traces `outline` (camera pixels), the area being painted.
    func outlineTheAreaBeingPainted(_ outline: [CGPoint])
    /// The loop's window in the newest keyframe and where it is in the newest frame, or nil when no loop has a shape to
    /// follow: a footprint or a shirt's outline. Safe to call from any thread, since the panel reads it every frame on the
    /// main thread.
    func currentLoop() -> RoomArtLoopSnapshot?
    /// The last frame as the panel drew it, at the camera's own size, with the person, the items, and their shadows as shown:
    /// what Save photo writes. Nil before the first frame. It renders on `processingQueue`, so call it off the main actor.
    func renderTheLastFrame() -> CGImage?
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

    /// False from `endTheSession` until the next session. `endTheSession` writes it on the caller's thread, ahead of its queued
    /// cleanup, so a frame queued or being drawn then is not submitted. Submitting a frame and moving the loop hold the lock.
    private let theSessionStillRuns = OSAllocatedUnfairLock(initialState: true)

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
    private var latestKeyframeBeforeTheMove: TakenKeyframe?
    /// The keyframe the tracker aligns to, as it was taken, with the person mask of that moment, which the background's bake
    /// draws the learner back on top with.
    private var latestKeyframe: TakenKeyframe?
    private struct TakenKeyframe {
        let keyframe: RoomArtKeyframe
        let personMask: CVPixelBuffer?
        let personLowestRowShare: Double?
        /// The room's light in the keyframe as the camera filmed it, which a look made on the keyframe is relit from.
        let roomLight: RoomArtLightReference?
    }
    /// For each furniture layer's light reference in use, by its `id`, the gains that relight it to the room now, smoothed
    /// over the last few measurements.
    private var smoothedLightGains: [UUID: SIMD3<Double>] = [:]
    /// How many frames in a row the tracker has missed the room, so a light copy is never paired through a turn it only guessed.
    private var latestFramesLostInARow = 0
    private var lastRoomLightMeasuredAt: CFTimeInterval = 0
    /// The references in use at the last measurement, so a new one is measured at once, and only once.
    private var referenceIDsMeasuredAtOnce: Set<UUID> = []
    private var loggedLightGains = RoomArtLightReference.unchangedGains
    /// The live room's light is measured this often while a furniture layer shows, a few times a second.
    private static let secondsBetweenRoomLightMeasurements = 0.2
    /// The items placed in this panel before its newest one, nil until a request keeps the room.
    private var background: RoomArtBackground?
    /// The items a new request fixed into the room, so the next item is placed among them: each draws every frame through
    /// the tracker's turn, under the newest item and with the learner in front of it, and nothing hides or moves it. They are
    /// drawn in the keyframe's pixels, so the keyframe and its tracker stay while they do, and the keyframe with them drawn in
    /// is what the next item is measured and painted on.
    private struct RoomArtBackground {
        /// Oldest first, so a later item draws over an earlier one, each with its corners eased like the newest item's.
        var items: [(placedArt: PlacedArt, smoothedCorners: [CGPoint]?)]
        /// The keyframe with every item drawn in, as the panel would draw them on the keyframe's own frame: the JPEG the next
        /// measurement sends, with the keyframe's number, person mask, wall spot, and floor texture, the texture read from
        /// these pixels.
        let keyframe: RoomArtKeyframe
        /// The same pixels, which a painting is made on and the next item is drawn into.
        let keyframeImage: CGImage
        /// The same pixels at the track size, and the room in them with the keyframe's learner left out, which the bare wall
        /// and floor spot search runs on, so a placed item counts as busy texture and the next one is not placed over it.
        let trackGrayscale: RoomGrayscaleImage
        let trackRoomMask: [Float]
    }
    /// The shirt try-on, on while the item is a top. The pose tracker belongs to this queue's session.
    private var shirtTryOnIsOn = false
    private let shirtPoseTracker = ShirtPoseTracker()
    private var shirtFramingDebouncer = ShirtFramingDebouncer()
    private var onTheShirtFramingSettled: (@Sendable (ShirtFramingKind) -> Void)?
    /// The armed capture, with the countdown number last reported so only a change goes to the main actor.
    private var shirtCapture: (state: ShirtStepBackCapture, lastReportedNumber: Int?, onEvent: @Sendable (ShirtCaptureEvent) -> Void)?
    /// The frozen frame, as filmed, shown while the shirt is painted into it, and the painted still once it arrives, with when it
    /// arrived for the crossfade. While it is set, no camera frame is drawn, except that once the painted still has crossfaded
    /// in and its top is cut out (`livePaintedTop`), the top is drawn over the live frames.
    private var frozenShirt: (frame: CIImage, painted: CIImage?, paintedArrivedAt: CFTimeInterval)?
    /// The painted top following the learner once the painted still has crossfaded in, with the closure that reports its hint
    /// to the main actor. Set only while `frozenShirt` holds the painted still, and cleared with it.
    private var livePaintedTop: (follower: ShirtLivePaintedTopFollower, onTheHintChanged: @Sendable (Bool) -> Void)?
    /// The outline of the learner's own top, traced on `shirtOutlineQueue` every `secondsBetweenShirtOutlines` while the
    /// try-on is prepared, with the torso it was traced on, so the loop follows the body between traces.
    private var latestShirtOutline: (outline: [CGPoint], torso: BodyTorso)?
    private var shirtOutlineIsBeingTraced = false
    private var shirtOutlineFailureWasLogged = false
    private var lastShirtOutlineStartedAt: CFTimeInterval = 0
    private let shirtOutlineQueue = DispatchQueue(label: "com.crodris.clicky.room-art.shirt-outline", qos: .utility)
    private static let secondsBetweenShirtOutlines = 0.5
    private var smoothedArtCorners: [CGPoint]?
    /// The bounding box of the ghost's footprint in the newest keyframe, which Clicky's loop is drawn around and tracked
    /// with the keyframe's own warp each frame. Nil with no footprint loop.
    private var loopKeyframeCorners: RoomArtCorners?
    /// The ghost's footprint in the keyframe, a quadrilateral the loop's line is bent onto.
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
    /// The last frame as drawn, kept so Save photo, and verification, can save what the panel showed.
    private var lastComposedImage: CIImage?

    /// The item as it is drawn on every frame: already lit like the room and softened like the camera, with its shadow.
    struct PlacedArt {
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
        /// The room's light in the frame furniture's layers were made on, which each frame relights them from. Nil for wall
        /// art, which is lit once from the keyframe's wall.
        var roomLightWhenMade: RoomArtLightReference? = nil

        func currentCorners(after cameraWarp: EuclideanWarp) -> [CGPoint] {
            keyframeCorners.map { cameraWarp.apply(to: layerToKeyframe.apply(to: $0)) }
        }

        /// Furniture's layers over a whole frame of `frameSize`: the tracker carries the frame's own corners, and the layers
        /// follow them.
        static func keyframeLayers(
            _ layers: RoomFurnitureKeyframeLayers, frameSize: CGSize, layerToKeyframe: EuclideanWarp, roomLightWhenMade: RoomArtLightReference?
        ) -> PlacedArt {
            let frameCorners = [
                CGPoint(x: 0, y: 0), CGPoint(x: frameSize.width, y: 0), CGPoint(x: frameSize.width, y: frameSize.height), CGPoint(x: 0, y: frameSize.height),
            ]
            return PlacedArt(
                drawing: .keyframeLayers(
                    item: CIImage(cgImage: layers.itemLayer),
                    shadow: layers.shadowLayer.map { CIImage(cgImage: $0) },
                    grainStandardDeviation: layers.cameraNoiseStandardDeviation
                ),
                keyframeCorners: frameCorners,
                keyframeBasePoint: layers.basePointInTheKeyframe,
                layerToKeyframe: layerToKeyframe,
                roomLightWhenMade: roomLightWhenMade
            )
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
            theSessionStillRuns.withLock { $0 = true }
            sessionNumber += 1
            self.onFirstSegmentedFrame = onFirstSegmentedFrame
            self.onTheSurfaceLostOrFound = onTheSurfaceLostOrFound
            theSurfaceIsLostAsLastReported = false
            shirtTryOnIsOn = false
            shirtFramingDebouncer = ShirtFramingDebouncer()
            onTheShirtFramingSettled = nil
            shirtCapture = nil
            frozenShirt = nil
            // A new session saves nothing until it has drawn a frame of its own, so Save photo never writes the last one's.
            lastComposedImage = nil
            livePaintedTop = nil
            latestShirtOutline = nil
            shirtOutlineFailureWasLogged = false
            shirtPoseTracker.reset()
            trackerBeforeTheMove = nil
            placedArtBeforeTheMove = nil
            latestKeyframeBeforeTheMove = nil
            latestKeyframe = nil
            background = nil
            crossfadeFrom = nil
            smoothedLightGains = [:]
            lastRoomLightMeasuredAt = 0
            referenceIDsMeasuredAtOnce = []
            loggedLightGains = RoomArtLightReference.unchangedGains
            latestFramesLostInARow = 0
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

    /// Stops submitting frames and moving the loop's corners at once, and stops reporting the first frame, so a closed panel
    /// never starts a measurement.
    func endTheSession() {
        theSessionStillRuns.withLock { $0 = false }
        processingQueue.async {
            self.onFirstSegmentedFrame = nil
            self.onTheSurfaceLostOrFound = nil
            self.onTheShirtFramingSettled = nil
            self.placedArt = nil
            self.crossfadeFrom = nil
            self.shirtTryOnIsOn = false
            self.shirtCapture = nil
            self.frozenShirt = nil
            self.livePaintedTop = nil
            self.latestShirtOutline = nil
        }
    }

    func startTheShirtTryOn(onTheFramingSettled: @escaping @Sendable (ShirtFramingKind) -> Void) {
        processingQueue.async {
            self.shirtTryOnIsOn = true
            self.onTheShirtFramingSettled = onTheFramingSettled
        }
    }

    func armTheShirtCapture(onEvent: @escaping @Sendable (ShirtCaptureEvent) -> Void) {
        processingQueue.async {
            guard self.shirtTryOnIsOn else { return }
            // Arming means the live camera shows, so a frame an earlier capture froze, whose event the controller may have
            // dropped as stale, is left here.
            self.frozenShirt = nil
            self.livePaintedTop = nil
            self.shirtCapture = (ShirtStepBackCapture(armedAt: CACurrentMediaTime()), nil, onEvent)
        }
    }

    func disarmTheShirtCapture() {
        processingQueue.async {
            self.shirtCapture = nil
        }
    }

    /// Judges this frame for the armed capture, and freezes it when the learner has held still for the whole countdown. The
    /// torso is the one found for this same frame, so the frozen frame and the torso always belong together.
    private func advanceTheShirtCapture(torso: BodyTorso?) {
        guard var capture = shirtCapture else { return }
        let step = capture.state.advance(framingKind: shirtFramingDebouncer.settledKind, torso: torso, at: CACurrentMediaTime())
        let onEvent = capture.onEvent
        func report(_ event: ShirtCaptureEvent) { DispatchQueue.main.async { onEvent(event) } }
        func reportTheNumber(_ number: Int?) {
            guard number != capture.lastReportedNumber else { return }
            capture.lastReportedNumber = number
            report(.countdown(number))
        }
        switch step {
        case .keepWaiting:
            reportTheNumber(nil)
        case .counting(let number):
            reportTheNumber(number)
        case .freezeNow:
            if let torso, let frozenFrame = freezeTheShirtFrameOnTheQueue(torso: torso) {
                shirtCapture = nil
                report(.frozen(frozenFrame))
                return
            }
            // Nothing could be frozen on this frame, such as no person mask yet, so the hold starts over.
            print("Shirt painting: nothing could be frozen on the frame that completed the hold, so the hold starts over")
            capture.state.restartTheHold()
            reportTheNumber(nil)
        case .giveUp:
            shirtCapture = nil
            report(.timedOut)
            return
        }
        shirtCapture = capture
    }

    private func freezeTheShirtFrameOnTheQueue(torso: BodyTorso) -> ShirtFrozenFrame? {
        guard shirtTryOnIsOn, frozenShirt == nil, let latestFrame, let latestPersonMask else { return nil }
        let frameImage = CIImage(cvPixelBuffer: latestFrame)
        let frameExtent = frameImage.extent
        let personMask = CIImage(cvPixelBuffer: latestPersonMask, options: [.colorSpace: NSNull()])
        let personMaskAtFrameSize = personMask.transformed(by: CGAffineTransform(
            scaleX: frameExtent.width / personMask.extent.width, y: frameExtent.height / personMask.extent.height
        ))
        guard let cameraImage = ciContext.createCGImage(frameImage, from: frameExtent, format: .RGBA8, colorSpace: sRGBColorSpace),
              let personBytes = redChannel(of: personMaskAtFrameSize, extent: frameExtent) else { return nil }
        // Nothing is drawn on the learner before the painting, so the frozen frame is the camera as filmed.
        frozenShirt = (frame: CIImage(cgImage: cameraImage), painted: nil, paintedArrivedAt: 0)
        // Until the paint mask's outline is in, the loop traces the learner's own top as last traced, held still, or no line
        // before a first trace.
        publishTheLoop(shirtLoop(for: torso))
        return ShirtFrozenFrame(cameraImage: cameraImage, personMask: personBytes, torso: torso)
    }

    /// The red channel of a mask image at the frame's size, read with no color space so its values are as they are.
    private func redChannel(of maskImage: CIImage, extent: CGRect) -> [UInt8]? {
        let width = Int(extent.width), height = Int(extent.height)
        var rgbaBytes = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(maskImage.cropped(to: extent), toBitmap: &rgbaBytes, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: nil)
        // Row 0 of the rendered bytes is the frame's top row, as y-down frame pixels count.
        var redBytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for column in 0..<width { redBytes[row * width + column] = rgbaBytes[(row * width + column) * 4] }
        }
        return redBytes
    }

    func showThePaintedStill(_ paintedImage: CGImage) {
        // A CGImage is immutable, so the processing queue may read it.
        nonisolated(unsafe) let painted = paintedImage
        processingQueue.async {
            guard let frozenShirt = self.frozenShirt else { return }
            self.frozenShirt = (frame: frozenShirt.frame, painted: CIImage(cgImage: painted), paintedArrivedAt: CACurrentMediaTime())
        }
    }

    func followTheLearnerWithThePaintedTop(_ paintedTop: ShirtLivePaintedTop, onTheHintChanged: @escaping @Sendable (Bool) -> Void) {
        processingQueue.async {
            // A painting the learner went back from has already cleared the frozen frame, so a late top is dropped here.
            guard self.frozenShirt?.painted != nil else { return }
            self.livePaintedTop = (ShirtLivePaintedTopFollower(top: paintedTop), onTheHintChanged)
        }
    }

    func resumeTheLiveShirt() {
        processingQueue.async {
            self.frozenShirt = nil
            self.livePaintedTop = nil
        }
    }

    func outlineTheAreaBeingPainted(_ outline: [CGPoint]) {
        processingQueue.async {
            guard self.frozenShirt != nil, let paintedAreaLoop = RoomArtLoopSnapshot(tracing: outline) else { return }
            self.publishTheLoop(paintedAreaLoop)
        }
    }

    /// The loop for a shirt on `torso`: the learner's own top as last traced, moved with the body since, or no line before
    /// the first trace, since a box over the body traces nothing of the shirt.
    private func shirtLoop(for torso: BodyTorso) -> RoomArtLoopSnapshot? {
        guard let latestShirtOutline else { return nil }
        return RoomArtLoopSnapshot(tracing: ShirtOutline.moved(latestShirtOutline.outline, from: latestShirtOutline.torso, to: torso))
    }

    /// Traces the learner's own top on `shirtOutlineQueue` at most every `secondsBetweenShirtOutlines`, one trace at a time,
    /// from a small copy of the frame and the person mask made here.
    private func traceTheShirtOutlineIfDue(in cameraFrame: CVPixelBuffer, torso: BodyTorso, now: CFTimeInterval) {
        guard !shirtOutlineIsBeingTraced, now - lastShirtOutlineStartedAt >= Self.secondsBetweenShirtOutlines else { return }
        guard let latestPersonMask else {
            if !shirtOutlineFailureWasLogged {
                shirtOutlineFailureWasLogged = true
                print("Shirt outline: no person mask yet to trace the learner's own top in")
            }
            return
        }
        let frameImage = CIImage(cvPixelBuffer: cameraFrame)
        let frameExtent = frameImage.extent
        let scale = min(1, Double(ShirtPaintMask.outlineLongestSide) / Double(max(frameExtent.width, frameExtent.height)))
        let smallWidth = max(3, Int((Double(frameExtent.width) * scale).rounded())), smallHeight = max(3, Int((Double(frameExtent.height) * scale).rounded()))
        let smallExtent = CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight)
        let personMask = CIImage(cvPixelBuffer: latestPersonMask, options: [.colorSpace: NSNull()])
        var smallFrame = [UInt8](repeating: 0, count: smallWidth * smallHeight * 4)
        var smallPersonRGBA = [UInt8](repeating: 0, count: smallWidth * smallHeight * 4)
        ciContext.render(
            frameImage.transformed(by: CGAffineTransform(scaleX: CGFloat(smallWidth) / frameExtent.width, y: CGFloat(smallHeight) / frameExtent.height)),
            toBitmap: &smallFrame, rowBytes: smallWidth * 4, bounds: smallExtent, format: .RGBA8, colorSpace: sRGBColorSpace
        )
        ciContext.render(
            personMask.transformed(by: CGAffineTransform(scaleX: CGFloat(smallWidth) / personMask.extent.width, y: CGFloat(smallHeight) / personMask.extent.height)),
            toBitmap: &smallPersonRGBA, rowBytes: smallWidth * 4, bounds: smallExtent, format: .RGBA8, colorSpace: nil
        )
        let smallPerson = stride(from: 0, to: smallPersonRGBA.count, by: 4).map { smallPersonRGBA[$0] }
        shirtOutlineIsBeingTraced = true
        lastShirtOutlineStartedAt = now
        let sessionWhenStarted = sessionNumber
        let smallTorso = torso.scaled(by: Double(smallWidth) / frameExtent.width)
        shirtOutlineQueue.async {
            let ownTopArea = ShirtPaintMask.oldGarmentArea(rgba: smallFrame, personMask: smallPerson, torso: smallTorso, width: smallWidth, height: smallHeight)
            let outline = ownTopArea
                .flatMap { ShirtOutline.outline(of: $0, width: smallWidth, height: smallHeight) }
                .map { ShirtOutline.scaled($0, fromMaskScale: Double(smallWidth) / frameExtent.width) }
            self.processingQueue.async {
                self.shirtOutlineIsBeingTraced = false
                guard sessionWhenStarted == self.sessionNumber else { return }
                guard let outline else {
                    if !self.shirtOutlineFailureWasLogged {
                        self.shirtOutlineFailureWasLogged = true
                        print("Shirt outline: the learner's own top was not found in a \(smallWidth)x\(smallHeight) copy of the frame")
                    }
                    return
                }
                if self.latestShirtOutline == nil { print("Shirt outline: traced the learner's own top, \(outline.count) points") }
                self.latestShirtOutline = (outline, torso)
            }
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

        // A frozen frame holds still while the shirt is painted into it and while the painted still shows, so the camera's
        // frames only pace the redraw, which plays the crossfade. Nothing is segmented or tracked meanwhile, except that once
        // the painted still has crossfaded in and its top is cut out, the top follows the learner in the live frames.
        if let frozenShirt {
            if drawThePaintedTopFollowingTheLearner(in: cameraFrame, frozenShirt: frozenShirt) { return }
            if present(frozenShirtImage(frozenShirt), extent: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)) {
                noteTheFrame(trackMilliseconds: 0)
            }
            return
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
            publishTheLoop(RoomArtLoopSnapshot(keyframeCorners: loopKeyframeCorners, currentCorners: RoomArtCorners(clockwiseFromTopLeft: smoothedLoopCornerPoints)))
        }

        // The shirt follows the body, not the room: the torso comes from the pose tracker, and the loop traces it.
        if shirtTryOnIsOn {
            // A capture freezes only on a torso found for this frame, never on where the learner stood seconds ago.
            advanceTheShirtCapture(torso: torsoForTheShirt(in: cameraFrame, frameSize: CGSize(width: frameWidth, height: frameHeight)))
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
        // The background's items move with the same warp and are eased the same way, so they and the newest item move as one.
        var backgroundItemsToDraw: [(placedArt: PlacedArt, corners: [CGPoint])] = []
        if var background, let trackStep, !trackStep.theArtIsHidden, let cameraWarp {
            for itemIndex in background.items.indices {
                let item = background.items[itemIndex]
                let corners = smoothedCorners(previous: item.smoothedCorners, current: item.placedArt.currentCorners(after: cameraWarp))
                background.items[itemIndex].smoothedCorners = corners
                backgroundItemsToDraw.append((item.placedArt, corners))
            }
            self.background = background
        }
        latestFramesLostInARow = trackStep?.framesLostInARow ?? 0
        // While the tracker misses the room it keeps its last turn, which no longer pairs the copies' pixels.
        if let trackStep, trackStep.framesLostInARow == 0, let cameraWarp {
            measureTheRoomLightIfDue(in: cameraFrame, keyframeToThisFrame: cameraWarp)
        }
        // A frame that found no drawable was not shown, so it does not count toward the frame rate.
        if draw(cameraFrame: cameraFrame, backgroundItems: backgroundItemsToDraw, artCorners: artCorners, fadingArtCorners: fadingArtCorners) {
            noteTheFrame(trackMilliseconds: trackMilliseconds)
        }
    }

    /// Draws this frame with the painted top following the learner, once the painted still has crossfaded in and its top is cut
    /// out (`ShirtLivePaintedTop`). The torso comes from the pose tracker directly, not `torsoForTheShirt`, which would report
    /// framing changes and move the loop. Returns false when the frozen path draws this frame instead.
    private func drawThePaintedTopFollowingTheLearner(in cameraFrame: CVPixelBuffer, frozenShirt: (frame: CIImage, painted: CIImage?, paintedArrivedAt: CFTimeInterval)) -> Bool {
        guard var livePaintedTop, frozenShirt.painted != nil,
              CACurrentMediaTime() - frozenShirt.paintedArrivedAt >= shirtPaintedStillCrossfadeSeconds else { return false }
        let now = CACurrentMediaTime()
        if !livePaintedTop.follower.hasStarted {
            // The person mask and the pose are from before the freeze, seconds old, so the live top waits for new ones.
            latestPersonMask = nil
            latestPersonLowestRowShare = nil
            shirtPoseTracker.reset()
        }
        startSegmentingIfIdle(cameraFrame)
        latestFrame = cameraFrame
        let torso = shirtPoseTracker.torso(forFrame: cameraFrame, atTime: now)
        if let hintIsShowing = livePaintedTop.follower.advance(currentTorso: torso, at: now) {
            print("Shirt painting: the painted top is \(hintIsShowing ? "out of reach (\(livePaintedTop.follower.reach)), so the still shows" : "back in reach")")
            let onTheHintChanged = livePaintedTop.onTheHintChanged
            DispatchQueue.main.async { onTheHintChanged(hintIsShowing) }
        }
        self.livePaintedTop = livePaintedTop
        let frameImage = CIImage(cvPixelBuffer: cameraFrame)
        // The renderer reads the mask's values as they are, which a mask tagged with no color space keeps.
        let personMask = latestPersonMask.map { CIImage(cvPixelBuffer: $0, options: [.colorSpace: NSNull()]) }
        if present(livePaintedTop.follower.image(frame: frameImage, personMask: personMask), extent: frameImage.extent) {
            noteTheFrame(trackMilliseconds: 0)
        }
        return true
    }

    /// The torso the step-back capture judges on this frame, or nil until the debounced framing has settled on ready, so a
    /// learner at the edge of a threshold does not flicker in and out of a hold. The framing is assessed every frame, each
    /// settled change goes to the main actor, and the learner's own top is traced for the loop, moved with the torso
    /// whenever there is one.
    private func torsoForTheShirt(in cameraFrame: CVPixelBuffer, frameSize: CGSize) -> BodyTorso? {
        let now = CACurrentMediaTime()
        let torso = shirtPoseTracker.torso(forFrame: cameraFrame, atTime: now)
        let framing = ShirtFraming.assess(torso: torso, frameSize: frameSize)
        if let settledKind = shirtFramingDebouncer.advance(to: ShirtFramingKind(framing), at: now), let onTheShirtFramingSettled {
            DispatchQueue.main.async { onTheShirtFramingSettled(settledKind) }
        }
        // The learner's own top is retraced twice a second and moved with the body in between, so a freeze for a painting
        // starts from a fresh outline.
        if let torso {
            traceTheShirtOutlineIfDue(in: cameraFrame, torso: torso, now: now)
        }
        publishTheLoop(torso.flatMap(shirtLoop(for:)))
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
        // Logged only while the item, the live camera of a shirt try-on, or the painted top following the learner shows,
        // since that is when every stage runs.
        if placedArt != nil || (shirtTryOnIsOn && frozenShirt == nil) || livePaintedTop?.follower.hasStarted == true {
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

    /// Draws the frame into the layer's next drawable: the background's items, oldest first, then the newest item over them.
    /// False when no drawable was free or Core Image refused the frame.
    private func draw(
        cameraFrame: CVPixelBuffer, backgroundItems: [(placedArt: PlacedArt, corners: [CGPoint])], artCorners: [CGPoint]?, fadingArtCorners: [CGPoint]?
    ) -> Bool {
        let frameImage = CIImage(cvPixelBuffer: cameraFrame)
        // The room as the newest item finds it: the frame, with the background's items drawn in. With no background it is
        // the frame itself. Each step keeps the frame's extent, which the next item's drawing measures.
        let roomImage = latestPersonMask.map { personMask in
            backgroundItems.reduce(frameImage) { roomSoFar, backgroundItem in
                Self.frameWithTheArt(
                    frameImage: roomSoFar, placedArt: backgroundItem.placedArt, artCorners: backgroundItem.corners,
                    personMask: personMask, personLowestRowShare: latestPersonLowestRowShare, grainOffset: Self.aNewGrainOffset(),
                    lightGains: lightGains(for: backgroundItem.placedArt)
                ).cropped(to: frameImage.extent)
            }
        } ?? frameImage
        var composedImage = roomImage
        if let placedArt, let artCorners, let latestPersonMask {
            composedImage = Self.frameWithTheArt(
                frameImage: roomImage, placedArt: placedArt, artCorners: artCorners,
                personMask: latestPersonMask, personLowestRowShare: latestPersonLowestRowShare, grainOffset: Self.aNewGrainOffset(),
                lightGains: lightGains(for: placedArt)
            )
            if let crossfadeFrom {
                let fadeProgress = (CACurrentMediaTime() - crossfadeFrom.startedAt) / Self.crossfadeSeconds
                // The bare room is the frame with the background drawn in, and a drawing hidden this frame has nothing to fade from.
                let fadingImage: CIImage? = if let fadingPlacedArt = crossfadeFrom.placedArt {
                    fadingArtCorners.map {
                        Self.frameWithTheArt(
                            frameImage: roomImage, placedArt: fadingPlacedArt, artCorners: $0,
                            personMask: latestPersonMask, personLowestRowShare: latestPersonLowestRowShare, grainOffset: Self.aNewGrainOffset(),
                            lightGains: lightGains(for: fadingPlacedArt)
                        )
                    }
                } else {
                    roomImage
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
        }
        return present(composedImage, extent: frameImage.extent)
    }

    /// The frozen frame, the crossfade to the painted still, or the painted still.
    private func frozenShirtImage(_ frozenShirt: (frame: CIImage, painted: CIImage?, paintedArrivedAt: CFTimeInterval)) -> CIImage {
        guard let painted = frozenShirt.painted else { return frozenShirt.frame }
        let fadeProgress = (CACurrentMediaTime() - frozenShirt.paintedArrivedAt) / shirtPaintedStillCrossfadeSeconds
        guard fadeProgress < 1 else { return painted }
        return frozenShirt.frame.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: painted,
            kCIInputTimeKey: max(0, fadeProgress),
        ])
    }

    /// Draws `image` cropped to `extent` into the layer's next drawable. False when no drawable was free, Core Image refused
    /// the frame, or the session has ended.
    private func present(_ image: CIImage, extent: CGRect) -> Bool {
        let composedImage = image.cropped(to: extent)
        guard let commandQueue, let drawable = metalLayer.nextDrawable(), let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let renderDestination = CIRenderDestination(mtlTexture: drawable.texture, commandBuffer: commandBuffer)
        renderDestination.colorSpace = sRGBColorSpace
        do {
            _ = try ciContext.startTask(toRender: composedImage, to: renderDestination)
        } catch {
            print("Room art: could not draw a frame: \(error)")
            return false
        }
        // Asked here, as the frame is about to show, since the session can end while it is drawn.
        return theSessionStillRuns.withLockUnchecked { sessionStillRuns in
            guard sessionStillRuns else { return false }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            lastComposedImage = composedImage
            return true
        }
    }

    func renderTheLastFrame() -> CGImage? {
        processingQueue.sync {
            Self.imageToSave(lastComposedImage: lastComposedImage, paintedStill: frozenShirt?.painted)
                .flatMap { ciContext.createCGImage($0, from: $0.extent, format: .RGBA8, colorSpace: sRGBColorSpace) }
        }
    }

    /// What Save photo writes: the painted still once it has arrived, so a save during its 0.5 s crossfade writes the
    /// finished still and never a mix of it with the frozen frame, and otherwise the last frame as drawn. While the painted
    /// top follows the learner live, the still is saved too: it is the painting itself, and the live top is the same
    /// painting moved with the shoulders, which is close to it only while the learner stands near the frozen pose.
    static func imageToSave(lastComposedImage: CIImage?, paintedStill: CIImage?) -> CIImage? {
        guard let paintedStill else { return lastComposedImage }
        return paintedStill.cropped(to: lastComposedImage?.extent ?? paintedStill.extent)
    }

    /// The item over the frame where the tracker put `artCorners` (camera pixels, y down), with the person drawn back on top
    /// through the segmentation mask, so the learner stays in front of it, unless furniture stands nearer the camera than
    /// the learner's feet (`roomFurnitureDrawsOverThePerson`). With no mask, no one is drawn back on top. `grainOffset` moves
    /// the furniture's grain, a new offset each frame so it moves like the camera's own.
    /// `lightGains` relights furniture's layers from the light they were made in to the room's now (`RoomArtLightReference`).
    static func frameWithTheArt(
        frameImage: CIImage, placedArt: PlacedArt, artCorners: [CGPoint], personMask: CVPixelBuffer?, personLowestRowShare: Double?, grainOffset: CGPoint,
        lightGains: SIMD3<Double> = RoomArtLightReference.unchangedGains
    ) -> CIImage {
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
                grainOffset: grainOffset,
                lightGains: lightGains
            )
        }
        guard let personMask else { return itemOverTheFrame }
        if let keyframeBasePoint = placedArt.keyframeBasePoint,
           let currentBasePoint = currentPoint(of: keyframeBasePoint, keyframeCorners: placedArt.keyframeCorners, currentCorners: artCorners),
           roomFurnitureDrawsOverThePerson(
               itemBaseRow: currentBasePoint.y,
               personLowestRow: personLowestRowShare.map { $0 * frameImage.extent.height },
               frameHeight: frameImage.extent.height
           ) {
            return itemOverTheFrame
        }
        return withThePersonOnTop(of: itemOverTheFrame, frameImage: frameImage, personMask: personMask)
    }

    private static func aNewGrainOffset() -> CGPoint {
        CGPoint(x: Double.random(in: 0..<512), y: Double.random(in: 0..<512))
    }

    /// The keyframe with `placedArt` drawn in, as the panel draws it on the keyframe's own frame: at its keyframe corners,
    /// with the learner of that moment drawn back on top through `personMask`. The grain sits at a fixed offset, so the same
    /// item always bakes to the same pixels. Drawing a second item into the result puts it over the first.
    /// `keyframeRoomLight` is the keyframe's own light, which a layer made on a later frame is relit to before it is baked in.
    static func keyframe(
        _ keyframeImage: CIImage, withTheItemDrawnIn placedArt: PlacedArt, personMask: CVPixelBuffer?, personLowestRowShare: Double?,
        keyframeRoomLight: RoomArtLightReference? = nil
    ) -> CIImage {
        let lightGains = placedArt.roomLightWhenMade.flatMap { itemLight in
            keyframeRoomLight.flatMap { RoomArtLightReference.gains(from: itemLight, to: $0) }
        } ?? RoomArtLightReference.unchangedGains
        return frameWithTheArt(
            frameImage: keyframeImage, placedArt: placedArt, artCorners: placedArt.currentCorners(after: .identity),
            personMask: personMask, personLowestRowShare: personLowestRowShare, grainOffset: .zero, lightGains: lightGains
        ).cropped(to: keyframeImage.extent)
    }

    /// Where a keyframe point is now, through the affine map the tracked corners give, in camera pixels with y down.
    private static func currentPoint(of keyframePoint: CGPoint, keyframeCorners: [CGPoint], currentCorners: [CGPoint]) -> CGPoint? {
        // The map works in Core Image's y-up space, so the point goes in and comes back out with y flipped about 0.
        guard let keyframeToCurrent = RoomFurnitureComposition.keyframeToCurrentFrame(keyframePoints: keyframeCorners, currentPoints: currentCorners, frameHeight: 0) else { return nil }
        let movedPoint = CGPoint(x: keyframePoint.x, y: -keyframePoint.y).applying(keyframeToCurrent)
        return CGPoint(x: movedPoint.x, y: -movedPoint.y)
    }

    /// The picture and its shadow warped onto `artCorners`, over the frame.
    private static func pictureWarpedOntoItsCorners(frameImage: CIImage, litArt: CIImage, shadow: CIImage, artCorners: [CGPoint]) -> CIImage {
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
    private static func withThePersonOnTop(of artOverTheFrame: CIImage, frameImage: CIImage, personMask: CVPixelBuffer) -> CIImage {
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
    /// floor spot. Nil before any frame arrived. While the room has a background, the background's keyframe is handed out
    /// instead (`backgroundKeyframeOnTheQueue`).
    func takeAKeyframe(on surfaceKind: RoomArtSurfaceKind?, anchorInCameraPixels: CGPoint?) async -> RoomArtKeyframe? {
        await withCheckedContinuation { continuation in
            processingQueue.async {
                continuation.resume(returning: self.takeAKeyframeOnTheQueue(on: surfaceKind, anchorInCameraPixels: anchorInCameraPixels))
            }
        }
    }

    private func takeAKeyframeOnTheQueue(on surfaceKind: RoomArtSurfaceKind?, anchorInCameraPixels: CGPoint?) -> RoomArtKeyframe? {
        guard let latestFrame, let latestTrackGrayscale, let latestTrackRoomMask else { return nil }
        if let background {
            // A click moves back from the newest frame through the eased turn the panel draws with, so it is measured on the
            // pixel of the keyframe the learner saw there. The spot search runs on the keyframe with its items drawn in.
            let keyframeToTheNewestFrame = latestTrackedWarp.withLock { $0?.keyframeToCurrent } ?? .identity
            let anchor = anchorInCameraPixels.map { keyframeToTheNewestFrame.inverted.apply(to: $0) } ?? bareSpot(
                on: surfaceKind, grayscale: background.trackGrayscale, roomMask: background.trackRoomMask,
                cameraPixelsPerTrackPixel: Double(background.keyframeImage.width) / Double(background.trackGrayscale.width)
            )
            return backgroundKeyframeOnTheQueue(background, on: surfaceKind, anchor: anchor)
        }
        let frameWidth = Double(CVPixelBufferGetWidth(latestFrame)), frameHeight = Double(CVPixelBufferGetHeight(latestFrame))
        let cameraPixelsPerTrackPixel = frameWidth / Double(latestTrackGrayscale.width)
        let anchor = anchorInCameraPixels ?? bareSpot(
            on: surfaceKind, grayscale: latestTrackGrayscale, roomMask: latestTrackRoomMask, cameraPixelsPerTrackPixel: cameraPixelsPerTrackPixel
        )

        trackerBeforeTheMove = tracker
        placedArtBeforeTheMove = placedArt
        keyframeNumberBeforeTheMove = keyframeNumber
        latestKeyframeBeforeTheMove = latestKeyframe
        keyframeNumber += 1
        tracker = RoomTracker(keyframeGrayscale: latestTrackGrayscale, keyframeRoomMask: latestTrackRoomMask)
        latestTrackedWarp.withLock { $0 = RoomArtTrackedWarp(keyframeNumber: keyframeNumber, keyframeToCurrent: .identity, theRoomIsLost: false) }
        latestCameraWarp = .identity
        placedArt = nil
        crossfadeFrom = nil
        smoothedArtCorners = nil
        reportWhetherTheSurfaceIsLost(false)
        // No loop is drawn while the surface is measured, so a footprint loop from an earlier look is forgotten.
        forgetTheLoopOnTheQueue()

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
        let keyframe = RoomArtKeyframe(
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
        latestKeyframe = TakenKeyframe(
            keyframe: keyframe, personMask: latestPersonMask, personLowestRowShare: latestPersonLowestRowShare,
            roomLight: roomLight(of: frameImage, personMask: latestPersonMask, keyframeToThisFrame: .identity)
        )
        return keyframe
    }

    /// Where an item goes with no anchor, in camera pixels: the bare wall spot for the wall, else the bare floor spot.
    private func bareSpot(on surfaceKind: RoomArtSurfaceKind?, grayscale: RoomGrayscaleImage, roomMask: [Float], cameraPixelsPerTrackPixel: Double) -> CGPoint {
        let trackSpot = switch surfaceKind {
        case .wall: bareWallSpot(grayscale: grayscale, roomMask: roomMask)
        case .floor, nil: bareFloorSpot(grayscale: grayscale, roomMask: roomMask)
        }
        return CGPoint(x: trackSpot.x * cameraPixelsPerTrackPixel, y: trackSpot.y * cameraPixelsPerTrackPixel)
    }

    /// The background's keyframe for the next measurement, in place of a new one, at `anchor` in its pixels. The item before
    /// the measurement hides and is kept for a failed move, as with a new keyframe, while the tracker, the keyframe's number,
    /// and the background stay.
    private func backgroundKeyframeOnTheQueue(_ background: RoomArtBackground, on surfaceKind: RoomArtSurfaceKind?, anchor: CGPoint) -> RoomArtKeyframe {
        trackerBeforeTheMove = tracker
        placedArtBeforeTheMove = placedArt
        keyframeNumberBeforeTheMove = keyframeNumber
        latestKeyframeBeforeTheMove = latestKeyframe
        placedArt = nil
        crossfadeFrom = nil
        smoothedArtCorners = nil
        let frameSize = CGSize(width: background.keyframeImage.width, height: background.keyframeImage.height)
        forgetTheLoopOnTheQueue()
        let wallSpot = background.keyframe.wallSpotAnchor ?? anchor
        keyframeWallLight = wallLight(
            around: surfaceKind == nil ? wallSpot : anchor, in: CIImage(cgImage: background.keyframeImage),
            frameWidth: frameSize.width, frameHeight: frameSize.height
        )
        let backgroundRequest = background.keyframe.measurementRequest
        return RoomArtKeyframe(
            measurementRequest: RoomWallRequest(keyframeJPEGData: backgroundRequest.keyframeJPEGData, personMaskPNGData: backgroundRequest.personMaskPNGData, anchor: anchor),
            wallLight: keyframeWallLight,
            wallSpotAnchor: background.keyframe.wallSpotAnchor,
            keyframeNumber: keyframeNumber,
            floorTexture: background.keyframe.floorTexture
        )
    }

    func fixTheShownItemIntoTheBackground() {
        processingQueue.async {
            guard let placedArt = self.placedArt, let latestKeyframe = self.latestKeyframe else { return }
            let keyframeImage = self.background.map { CIImage(cgImage: $0.keyframeImage) }
                ?? CIImage(data: latestKeyframe.keyframe.measurementRequest.keyframeJPEGData)
            guard let keyframeImage else { return }
            let bakedImage = Self.keyframe(
                keyframeImage, withTheItemDrawnIn: placedArt, personMask: latestKeyframe.personMask, personLowestRowShare: latestKeyframe.personLowestRowShare,
                keyframeRoomLight: latestKeyframe.roomLight
            )
            guard let bakedCGImage = self.ciContext.createCGImage(bakedImage, from: keyframeImage.extent, format: .RGBA8, colorSpace: self.sRGBColorSpace),
                  let bakedJPEGData = self.ciContext.jpegRepresentation(
                      of: CIImage(cgImage: bakedCGImage),
                      colorSpace: self.sRGBColorSpace,
                      options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.92]
                  ) else { return }
            let takenKeyframe = latestKeyframe.keyframe
            let (trackWidth, trackHeight) = trackSize(forFrameWidth: bakedCGImage.width, frameHeight: bakedCGImage.height)
            guard let bakedTrackGrayscale = trackGrayscale(of: bakedCGImage, width: trackWidth, height: trackHeight) else { return }
            // The baked keyframe draws the learner back where the keyframe's own mask has them, so that mask leaves them out.
            let bakedTrackRoomMask = latestKeyframe.personMask.map { personMask in
                roomMaskAtTrackSize(segmentationConfidence: firstPlaneScaled(of: personMask, toWidth: trackWidth, height: trackHeight), width: trackWidth, height: trackHeight)
            } ?? roomMaskWithNoPerson(width: trackWidth, height: trackHeight)
            self.background = RoomArtBackground(
                items: (self.background?.items ?? []) + [(placedArt, self.smoothedArtCorners)],
                keyframe: takenKeyframe.baked(
                    keyframeJPEGData: bakedJPEGData, trackGrayscale: bakedTrackGrayscale, trackRoomMask: bakedTrackRoomMask,
                    cameraPixelsPerTrackPixel: Double(bakedCGImage.width) / Double(trackWidth)
                ),
                keyframeImage: bakedCGImage,
                trackGrayscale: bakedTrackGrayscale,
                trackRoomMask: bakedTrackRoomMask
            )
            print("Room art: the item that showed is now part of the room, which holds \(self.background?.items.count ?? 0) placed items")
            // The item is the background's now, so no move puts it back and nothing hides it.
            self.placedArt = nil
            self.crossfadeFrom = nil
            self.smoothedArtCorners = nil
            self.trackerBeforeTheMove = nil
            self.placedArtBeforeTheMove = nil
        }
    }

    /// The gains that relight `placedArt` to the room now: the smoothed gains of its light reference, or none before the
    /// first measurement and for wall art.
    private func lightGains(for placedArt: PlacedArt) -> SIMD3<Double> {
        placedArt.roomLightWhenMade.flatMap { smoothedLightGains[$0.id] } ?? RoomArtLightReference.unchangedGains
    }

    /// Measures the live room's light a few times a second while a furniture layer shows, and moves each layer's smoothed
    /// gains toward it. `keyframeToThisFrame` is the tracker's turn in camera pixels. A layer whose gains cannot be measured
    /// this time, such as one the learner hides the room around, keeps its gains from before.
    private func measureTheRoomLightIfDue(in cameraFrame: CVPixelBuffer, keyframeToThisFrame: EuclideanWarp) {
        let referencesInUse = ([placedArt, crossfadeFrom?.placedArt] + (background?.items.map(\.placedArt) ?? []))
            .compactMap { $0?.roomLightWhenMade }
        guard !referencesInUse.isEmpty else {
            smoothedLightGains = [:]
            return
        }
        // A look just shown has no gains yet, so it is measured at once instead of drawn unrelit until the next measurement.
        // Only once per look: one whose light cannot be measured waits for the usual interval after that.
        let aReferenceIsNew = referencesInUse.contains { !referenceIDsMeasuredAtOnce.contains($0.id) }
        let now = CACurrentMediaTime()
        guard aReferenceIsNew || now - lastRoomLightMeasuredAt >= Self.secondsBetweenRoomLightMeasurements else { return }
        lastRoomLightMeasuredAt = now
        referenceIDsMeasuredAtOnce = Set(referencesInUse.map(\.id))
        guard let currentLight = roomLight(of: CIImage(cvPixelBuffer: cameraFrame), personMask: latestPersonMask, keyframeToThisFrame: keyframeToThisFrame) else { return }
        smoothedLightGains = RoomArtLightReference.smoothedGainsInUse(references: referencesInUse, current: currentLight, previous: smoothedLightGains)
        // The log shows the newest item's gains each time they move by more than a few percent, so a live check sees the relight.
        if let newestReference = placedArt?.roomLightWhenMade, let newestGains = smoothedLightGains[newestReference.id],
           max(abs(newestGains.x - loggedLightGains.x), abs(newestGains.y - loggedLightGains.y), abs(newestGains.z - loggedLightGains.z)) > 0.05 {
            loggedLightGains = newestGains
            print(String(format: "Room furniture: the room's light changed, so the item is relit by %.2f, %.2f, %.2f", newestGains.x, newestGains.y, newestGains.z))
        }
    }

    /// The room's light in `frameImage`, as a copy at the track size with its learner (`RoomArtLightReference`).
    /// `keyframeToThisFrame` is the tracker's turn from the keyframe to this frame, in camera pixels.
    private func roomLight(of frameImage: CIImage, personMask: CVPixelBuffer?, keyframeToThisFrame: EuclideanWarp) -> RoomArtLightReference? {
        let frameWidth = Int(frameImage.extent.width), frameHeight = Int(frameImage.extent.height)
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        let (smallWidth, smallHeight) = trackSize(forFrameWidth: frameWidth, frameHeight: frameHeight)
        let smallPixelsPerCameraPixel = Double(smallWidth) / Double(frameWidth)
        let smallImage = frameImage.transformed(by: CGAffineTransform(scaleX: smallPixelsPerCameraPixel, y: Double(smallHeight) / Double(frameHeight)))
        var rgbaBytes = [UInt8](repeating: 0, count: smallWidth * smallHeight * 4)
        // The bitmap's first row is the frame's top row, as the person mask's is.
        ciContext.render(
            smallImage, toBitmap: &rgbaBytes, rowBytes: smallWidth * 4,
            bounds: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight), format: .RGBA8, colorSpace: sRGBColorSpace
        )
        return RoomArtLightReference(
            width: smallWidth, height: smallHeight, rgbaBytes: rgbaBytes,
            personConfidence: personMask.map { firstPlaneScaled(of: $0, toWidth: smallWidth, height: smallHeight) },
            keyframeToThisFrame: keyframeToThisFrame.scaled(by: smallPixelsPerCameraPixel)
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
            let shadow = wallArtShadow(of: flattenedArt)
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
            let frameSize = CGSize(width: CVPixelBufferGetWidth(latestFrame), height: CVPixelBufferGetHeight(latestFrame))
            // A first look fades in from the bare room, and a later one from the look before it.
            self.crossfadeFrom = (self.placedArt, CACurrentMediaTime())
            // A look made on the keyframe, such as a render, carries no light of its own and takes the keyframe's.
            self.placedArt = .keyframeLayers(
                layers, frameSize: frameSize, layerToKeyframe: layerToKeyframe, roomLightWhenMade: layers.roomLightWhenMade ?? self.latestKeyframe?.roomLight
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
            self.publishTheLoop(RoomArtLoopSnapshot(keyframeCorners: keyframeLoopCorners, currentCorners: currentCorners))
        }
    }

    func forgetTheKeyframe() {
        processingQueue.async {
            // The background is drawn in the keyframe's pixels, so it goes with it.
            self.background = nil
            self.latestKeyframe = nil
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
        if let background {
            // The baked keyframe is the keyframe's own frame, with its light.
            return RoomArtPaintingFrame(
                jpegData: background.keyframe.measurementRequest.keyframeJPEGData, image: background.keyframeImage,
                keyframeToFrame: .identity, shareOfTheBoxThePersonCovers: 0, roomLight: latestKeyframe?.roomLight
            )
        }
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
        return RoomArtPaintingFrame(
            jpegData: jpegData, image: cgImage, keyframeToFrame: latestCameraWarp, shareOfTheBoxThePersonCovers: shareCovered,
            // A turn the tracker only guessed would pair the wrong pixels later, so the keyframe's light stands in then.
            roomLight: latestFramesLostInARow == 0 ? roomLight(of: frameImage, personMask: latestPersonMask, keyframeToThisFrame: latestCameraWarp) : nil
        )
    }

    /// Forgets the footprint loop, which a new keyframe's measurement draws no loop to replace.
    private func forgetTheLoopOnTheQueue() {
        loopKeyframeCorners = nil
        loopKeyframeTargetCorners = nil
        smoothedLoopCorners = nil
        publishTheLoop(nil)
    }

    /// Moves the loop, unless the session has ended, which leaves it where the closing panel last showed it.
    private func publishTheLoop(_ loop: RoomArtLoopSnapshot?) {
        theSessionStillRuns.withLock { sessionStillRuns in
            guard sessionStillRuns else { return }
            latestLoop.withLock { $0 = loop }
        }
    }

    /// The loop where the footprint or the torso last was, for the panel to draw or fade out.
    func currentLoop() -> RoomArtLoopSnapshot? {
        latestLoop.withLock { $0 }
    }

    /// A click's measurement failed, so the item goes back where it stood, tracked against the keyframe it stood on. That
    /// tracker aligns each frame to its own keyframe, so it finds the room again after the frames it missed.
    func putBackTheItemFromBeforeTheMove() {
        processingQueue.async {
            guard let placedArtBeforeTheMove = self.placedArtBeforeTheMove else { return }
            self.tracker = self.trackerBeforeTheMove
            self.placedArt = placedArtBeforeTheMove
            self.keyframeNumber = self.keyframeNumberBeforeTheMove
            self.latestKeyframe = self.latestKeyframeBeforeTheMove
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
nonisolated struct RoomArtFrontTab: Sendable {
    let url: String
    let title: String
    /// Nil when the page's script could not run, such as on a page with an open `alert()`, so no size can be read.
    let text: String?
    /// The page's largest picture, read before the page's sections opened, which this request's picture is taken from. Nil
    /// when the page shows none or Chrome could not be read.
    var largestPicture: LargestVisibleMediaInFrontTab? = nil
}

/// The front tab's address, title, and text, the text cut to what `POST /try-it-item` takes. Nil when Chrome has no window.
/// A store often hides a product's size in a collapsed section, as IKEA hides the height under Measurements, so the read
/// first opens those sections (`roomArtExpandTheSizeSectionsScript`) and waits a moment for them to fill, and the text then
/// adds the page's structured data that names a dimension (`roomArtPageTextScript`). The scripts have no double quotes or
/// backslashes, since they run inside an AppleScript string.
/// The largest picture is read first, so it is the page as the learner sees it: IKEA opens its Product details section as a
/// side sheet whose construction cutaway is the largest picture once it shows, and the KIVIK sofa was painted from that
/// beige cutaway instead of its black product photo.
@MainActor
func readTheFrontTabForRoomArt() async -> RoomArtFrontTab? {
    guard let frontTab = try? ChromeVideoTab.frontTabOfTheFrontWindow() else { return nil }
    let largestPicture: LargestVisibleMediaInFrontTab?
    do {
        largestPicture = try ChromeVideoTab.largestVisibleMediaInFrontTabOrNone()
    } catch {
        print("Room art: could not read the largest picture from Chrome: \(error)")
        largestPicture = nil
    }
    let sectionsOpened = (try? ChromeVideoTab.runJavaScript(roomArtExpandTheSizeSectionsScript, in: frontTab)).flatMap { Int($0) } ?? 0
    if sectionsOpened > 0 {
        print("Room art: opened \(sectionsOpened) collapsed sections of the page before reading it")
        // IKEA's Measurements text was in the page 12 ms after its click, and a slower store gets more room than that.
        try? await Task.sleep(for: .milliseconds(600))
    }
    let pageText = try? ChromeVideoTab.runJavaScript(roomArtPageTextScript(longestCharacters: RoomArtPageRequest.longestPageText), in: frontTab)
    return RoomArtFrontTab(url: frontTab.url, title: frontTab.title, text: pageText, largestPicture: largestPicture)
}

/// The front tab's largest picture for room art: the page's image file when it names one, else a screen capture of it
/// (`RoomArtPictureSource`), since a capture also holds a cookie banner or any other page element over the picture. Nil when
/// the page shows no picture.
@MainActor
func roomArtPicture(of largestPicture: LargestVisibleMediaInFrontTab?) async -> RoomArtPicture? {
    guard let largestPicture else { return nil }
    return await RoomArtPictureSource.picture(imageFileURL: largestPicture.imageFileURL, otherImageFileURLs: largestPicture.otherImageFileURLs) {
        guard let pictureGrab = try? await CompanionScreenCaptureUtility.captureScreenRectAsJPEG(largestPicture.screenRect),
              let jpegData = Data(base64Encoded: pictureGrab.jpeg) else {
            return nil
        }
        return RoomArtPicture(jpegData: jpegData, width: pictureGrab.width, height: pictureGrab.height)
    }
}

/// What Clicky says when the front tab has no picture to hang.
nonisolated let roomArtNoPictureLine = "I don't see a picture in Chrome's front tab."

// MARK: - Controller

/// Shows and hides the panel, so tests need no window.
@MainActor
protocol RoomArtPanelPresenting: AnyObject {
    func show()
    /// Fades the panel out. `onceHidden` runs once it is off the screen, and never when a newer show or hide replaced the fade.
    func hide(onceHidden: @escaping @MainActor () -> Void)
}

/// Everything of the controller's state that the panel draws. A close forgets that state at once, while the window still
/// fades out, so the panel draws its content from `RoomArtPreviewController.panelContent`.
struct RoomArtPanelContent {
    let phase: RoomArtPhase
    let theFirstFrameIsIn: Bool
    let theSurfaceIsLost: Bool
    let waitingForTheLearnerToStepAside: Bool
    let shirtCoachingLine: String?
    let thePaintedTopIsOutOfReach: Bool
    let shirtCaptureCountdownNumber: Int?
    let loopState: RoomArtLoopState
    let furnitureGhost: RoomFurnitureGhost?
    let furnitureGhostDraw: RoomFurnitureGhostDraw?
}

/// What a closing panel keeps drawing: its content as the close began, and the room's turn of that moment, which the
/// ghost's lines are worked out from once the keyframe is forgotten.
private struct RoomArtClosingPanel {
    let content: RoomArtPanelContent
    let ghostTrackedWarp: RoomArtTrackedWarp?
}

@MainActor
final class RoomArtPreviewController: ObservableObject {
    /// Everything the controller reaches outside itself, so a test can stand in for Chrome, the Worker, the camera, Vision,
    /// and the voice.
    struct Environment {
        /// Every Worker route the panel calls needs the app secret, so with none set the camera never opens.
        var appSecretIsSet: () -> Bool
        var readTheFrontTab: () async -> RoomArtFrontTab?
        /// The request's picture, taken from the front tab that request read.
        var capturePicture: (RoomArtFrontTab) async -> RoomArtPicture?
        var readThePage: (RoomArtPageRequest) async throws -> RoomArtPageReading
        var measureTheWall: (RoomWallRequest) async throws -> WallPlane
        var measureTheFloor: (RoomWallRequest) async throws -> FloorPlane
        /// The furniture cut out of its product photo, nil when Vision finds none. Vision takes a while, so it runs off the
        /// main actor.
        var cutOutTheFurniture: (_ picture: CGImage, _ itemCorners: RoomArtCorners) async -> CGImage?
        /// The whole product photo with only the wall item's own shape opaque, nil when Vision finds none: for a wall item whose
        /// outline does not fill its four corners, such as a round clock. It runs off the main actor.
        var cutOutTheWallItemByItsShape: (_ picture: CGImage, _ itemCorners: RoomArtCorners) async -> CGImage?
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
        var paintedItemLayers: (_ painted: RoomFurniturePaintedKeyframe, _ keyframe: CGImage, _ maskPNG: Data, _ projectedBox: [CGPoint]) async -> RoomFurnitureKeyframeLayers? = { _, _, _, _ in nil }
        /// Returns when furniture has waited long enough for its first look, `roomFurnitureSecondsToWaitForALook` after a
        /// painting request for its placement goes out, so the fallback shows instead. A test returns when it chooses.
        var waitTheLongestForAFurnitureLook: () async -> Void = { try? await Task.sleep(for: .seconds(roomFurnitureSecondsToWaitForALook)) }
        /// The same wait counted from the placement, which covers a placement whose request never goes out, such as while the
        /// learner covers the box. A test returns when it chooses.
        var waitTheLongestAfterAFurniturePlacement: () async -> Void = { try? await Task.sleep(for: .seconds(roomFurnitureSecondsToWaitForALook)) }
        /// The masks a painting of the shirt is made with, from Vision's faces and hands in the frozen frame and the area the
        /// garment covers (`ShirtPaintMask.make`), off the main actor, or nil when the old top cannot be found.
        var makeTheShirtPaintMasks: (ShirtFrozenFrame, ShirtCoverage) async -> ShirtPaintMasks? = { _, _ in nil }
        /// Paints the shirt into the frozen frame through the Worker and pastes it back (`ShirtPaintingClient`).
        var paintTheShirt: (ShirtPaintingRequest) async throws -> CGImage = { _ in throw ShirtPaintingFailure.serviceIsNotSetUp }
        /// The painted top cut out of the painted still so it can follow the learner live (`ShirtLivePaintedTop.make`), off the
        /// main actor, or nil when it cannot be made. The arguments are the painted still, the masks it was painted with, the
        /// torso of the frozen frame, and the garment's coverage.
        var makeTheLivePaintedTop: (CGImage, ShirtPaintMasks, BodyTorso, ShirtCoverage) async -> ShirtLivePaintedTop? = { _, _, _, _ in nil }
        /// The learner asked the open panel for something: a painting or a return to the live camera, by voice or by its button,
        /// the furniture placed by voice or the Place button, or moved by voice. The line that answers it lands after any press
        /// they made before, so it must not be dropped as one they moved on from. A drag, click, or scroll that moves the ghost
        /// does not call it, since no line answers one.
        var theLearnerAskedThePanel: () -> Void = {}
        /// Plays a countdown sound of the shirt's step-back capture: a tick for each number and a different sound when the
        /// frame freezes. A test counts them instead of playing them.
        var playTheShirtCountdownSound: (ShirtCountdownSound) -> Void = { $0.play() }
        /// Shows a chip above the cursor, as a failure when `isAFailure` is true: what Save photo did.
        var showTheChip: (_ phrase: String, _ isAFailure: Bool) -> Void = { _, _ in }
        /// Where Save photo writes, ~/Pictures/Clicky. A test passes a folder of its own.
        var photoFolder: URL = RoomArtPhotoSaving.standardFolder

        /// Chrome, the Worker at `workerBaseURL`, the app's defaults for the secret, Vision, and the camera (or a Debug
        /// build's `--room-camera-file`).
        static func live(
            workerBaseURL: String,
            clearTheLiveScene: @escaping () -> Void,
            speak: @escaping (String, Bool) -> Void,
            loopAccentColor: @escaping () -> Color,
            loopTracerLook: @escaping () -> CursorLoopTracerLook?,
            endTheSpokenLine: @escaping () -> Void,
            theLearnerAskedThePanel: @escaping () -> Void,
            showTheChip: @escaping (String, Bool) -> Void
        ) -> Environment {
            let roomArtClient = RoomArtClient(workerBaseURL: workerBaseURL)
            let shirtPaintingClient = ShirtPaintingClient(workerBaseURL: workerBaseURL)
            return Environment(
                appSecretIsSet: { ClickyAppSecret.isSet() },
                readTheFrontTab: { await readTheFrontTabForRoomArt() },
                capturePicture: { frontTab in await roomArtPicture(of: frontTab.largestPicture) },
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
                cutOutTheWallItemByItsShape: { picture, itemCorners in
                    nonisolated(unsafe) let pictureToCut = picture
                    return await Task.detached(priority: .userInitiated) { () -> CGImage? in
                        pictureWithOnlyTheItemOpaque(picture: pictureToCut, itemCorners: itemCorners, context: CIContext())
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
                    nonisolated(unsafe) let keyframeImage = keyframe
                    return await Task.detached(priority: .userInitiated) { () -> RoomFurnitureKeyframeLayers? in
                        let composite = RoomFurniturePaintedComposite.itemLayers(
                            painted: painted.image, pastedRegion: painted.pastedRegion, pieceLayer: painted.pieceLayer, keyframe: keyframeImage, maskPNG: maskPNG, projectedBox: projectedBox
                        )
                        if let ratio = composite.paintedHeightRatio, let rows = composite.paintedRows {
                            print(String(format: "Room furniture: the painted item is %.0f%% of the measured box's outline (%@)", ratio * 100, roomFurniturePaintedRowsAgainstTheBox(rows, projectedBox)))
                        }
                        if let refusal = composite.refusal { print("Room furniture: the painting is refused, since \(refusal)") }
                        return composite.layers
                    }.value
                },
                makeTheShirtPaintMasks: { frozenFrame, coverage in
                    await Task.detached(priority: .userInitiated) { () -> ShirtPaintMasks? in
                        ShirtPaintMask.make(frame: frozenFrame, bodyParts: shirtPaintBodyParts(in: frozenFrame.cameraImage), coverage: coverage)
                    }.value
                },
                paintTheShirt: { paintingRequest in try await shirtPaintingClient.paint(paintingRequest) },
                makeTheLivePaintedTop: { painted, masks, frozenTorso, coverage in
                    // A CGImage is immutable, so the detached task may read it.
                    nonisolated(unsafe) let paintedStill = painted
                    return await Task.detached(priority: .userInitiated) {
                        ShirtLivePaintedTop.make(painted: paintedStill, masks: masks, frozenTorso: frozenTorso, coverage: coverage)
                    }.value
                },
                theLearnerAskedThePanel: theLearnerAskedThePanel,
                showTheChip: showTheChip
            )
        }
    }

    @Published private(set) var phase = RoomArtPhase.closed {
        didSet {
            let now = ProcessInfo.processInfo.systemUptime
            loopState = loopState.after(phaseChangedTo: phase, at: now)
            // A panel opened again while it fades draws the new request.
            if phase.isOpen { closingPanel = nil }
            if phase.shirtStillVoiceTargets != oldValue.shirtStillVoiceTargets { shirtStillVoiceTargetsChangedAt = now }
        }
    }
    /// When the shirt button last changed role, which a click right after it does not count against.
    private var shirtStillVoiceTargetsChangedAt: TimeInterval = 0
    /// Clicky's loop around the placed furniture's footprint or the learner's torso: drawn until the item or the shirt shows, or a failure.
    @Published private(set) var loopState = RoomArtLoopState.hidden
    /// The tracker lost the room long enough to hide the item, so the status line says so.
    @Published private(set) var theSurfaceIsLost = false
    /// What the settled framing tells the learner while they are out of view or too close for the capture, nil once they
    /// stand in the ready framing.
    @Published private(set) var shirtCoachingLine: String?
    /// The painted top cannot follow the learner now, so the painted still shows and the status line says how to see it live
    /// (`ShirtLivePaintedTopFollower`). Only the painted still's status line reads it, and each painted still starts it false.
    @Published private(set) var thePaintedTopIsOutOfReach = false
    /// The countdown number the armed capture last reported, 3 then 2 then 1, nil while no hold is under way.
    @Published private(set) var shirtCaptureCountdownNumber: Int?
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
    /// Each opening counts up when a request commits to a new item (its checks passed and its picture is in hand) and on each
    /// close, so an await that resumes after the panel closed, reopened, or moved on to a new item changes nothing. A request
    /// that fails a check never moves it, so the item that still shows keeps its pending painting and the painting still lands.
    private var openingNumber = 0
    /// Each request and each close counts up, so a request that a newer request, Escape, or a close overtook stops where it is.
    /// It is apart from `openingNumber` so a request that fails a check, before it commits to anything, leaves the shown
    /// item's work alone.
    private var requestNumber = 0
    /// Each camera session counts up: a request that opens the panel starts one and a close ends it. A request that keeps the
    /// room (`RoomArtPhase.keepsTheRoomForANewItem`) keeps the session, so the frame processor's reports for it still reach
    /// the panel while `openingNumber` moves on to the new item.
    private var cameraSessionNumber = 0
    /// The page and its picture are being read before the panel opens, so Escape has a request to stop.
    private var anOpeningIsUnderway = false
    private var hereItIsWasSaid = false
    /// Each prompt for a click on a surface is said once per panel: the floor line the first time no floor is found, and a
    /// table or shelf's invitation and its first failed click. A later failed click only shows in the status line.
    private var surfaceClickPromptsSaid: Set<RoomArtSurfaceClickPrompt> = []
    /// The clothing being tried on and the page picture that shows its front, which a painting crops the product photo from,
    /// since the reading's corners are in that picture. The reading holds the cloth color the painting is told.
    private var shirtBeingTried: (reading: RoomArtClothingReading, frontPicture: CGImage)?
    /// Freezes the frame and paints the shirt into it. Going back or a close cancels it.
    private var shirtPaintingTask: Task<Void, Never>?
    private var lastShirtPaintingNumber = 0
    /// A press cancelled the waiting capture, and its transcript has not been routed yet.
    private var aPressCancelledTheCapture = false
    /// The save in progress, so a second press while it runs saves nothing more, and a test can wait for it.
    private(set) var photoSavingTask: Task<Void, Never>?

    /// With no presenter, the real panel shows, and with no frame processor, the real one draws it.
    init(environment: Environment, frameProcessor: RoomArtFrameProcessing = RoomArtFrameProcessor(), panelPresenter: RoomArtPanelPresenting? = nil) {
        self.environment = environment
        self.frameProcessor = frameProcessor
        injectedPanelPresenter = panelPresenter
    }

    var isOpen: Bool { phase.isOpen }

    /// Set from a close until the panel is off the screen.
    @Published private var closingPanel: RoomArtClosingPanel?

    /// What the panel draws: the live state, or a closing panel's last open content.
    var panelContent: RoomArtPanelContent { closingPanel?.content ?? livePanelContent }

    private var livePanelContent: RoomArtPanelContent {
        RoomArtPanelContent(
            phase: phase,
            theFirstFrameIsIn: theFirstFrameIsIn,
            theSurfaceIsLost: theSurfaceIsLost,
            waitingForTheLearnerToStepAside: waitingForTheLearnerToStepAside,
            shirtCoachingLine: shirtCoachingLine,
            thePaintedTopIsOutOfReach: thePaintedTopIsOutOfReach,
            shirtCaptureCountdownNumber: shirtCaptureCountdownNumber,
            loopState: loopState,
            furnitureGhost: furnitureGhost,
            furnitureGhostDraw: furnitureGhostDraw
        )
    }

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
    /// Shows the fallback once the newest placement's painting request has been out for `roomFurnitureSecondsToWaitForALook`
    /// with no painting. A new request, a new placement, or a close cancels it.
    private var furnitureLookDeadlineTask: Task<Void, Never>?
    /// Shows the fallback once `roomFurnitureSecondsToWaitForALook` have passed since the newest placement, request or not,
    /// since the learner may cover the box for as long as they like. A new placement or a close cancels it.
    private var furniturePlacementDeadlineTask: Task<Void, Never>?
    /// The keyframe of the measurement that just finished, kept until its result is applied.
    private var keyframeOfTheLatestMeasurement: RoomArtKeyframe?
    /// The newest furniture placement: its measurement, the furniture, the keyframe it was placed on, and the floor it
    /// stands on, and the ghost it was placed as. It is set as the piece is arranged, before any look shows. The flat cutout
    /// is never drawn, and is kept only as what both generation services work from.
    private var furniturePlacement: (measurementID: RoomArtMeasurementID, furniture: RoomFurniture, keyframe: RoomArtKeyframe, floor: FloorPlane, ghost: RoomFurnitureGhost)?
    /// The model's render for the newest placement, held back while the painting is on its way, since an early look makes
    /// the painting that follows it read as a small change. It shows only as the fallback.
    private var furnitureRenderHeldBack: (measurementID: RoomArtMeasurementID, layers: RoomFurnitureKeyframeLayers)?
    /// What the newest placement's fallback waits on, the inputs of `roomFurnitureFallbackStep`: the painting said it cannot
    /// come, the wait counted from the painting request ran out (`furnitureWaitRanOut`), the wait counted from the placement
    /// ran out (`furniturePlacementWaitRanOut`), a painting request is out (`furniturePaintingRequestIsOut`), and where the
    /// model's render stands (`furnitureRenderState`: held back and ready, still being made or searched for, or none).
    private var furniturePaintingCannotCome = false
    private var furnitureWaitRanOut = false
    private var furniturePlacementWaitRanOut = false
    /// A painting request is out for the newest placement, so its fallback never gives up on the painting for want of a render.
    private var furniturePaintingRequestIsOut = false
    private var furnitureRenderIsRunning = false
    /// The furniture's cutout over white, as a JPEG, which both generation services work from. It is the product cut out of
    /// the page's photo, never the raw page picture, which can hold a cookie banner or the rest of the page.
    private var furnitureCutoutJPEG: Data?
    /// The composite service said it is not set up (503) or OpenAI is out of credit (402), so no later placement in this panel
    /// asks it again.
    private var compositeServiceIsUnavailable = false
    private var stepBackWasSaid = false

    // MARK: The ghost

    /// The furniture's ghost while the learner places it, and the pose it was placed in afterward, which a pick-up starts
    /// from. Nil until the floor is measured, and after a new measurement starts.
    @Published private(set) var furnitureGhost: RoomFurnitureGhost?
    /// When the ghost began drawing itself (`RoomFurnitureGhostDrawTimeline`).
    @Published private(set) var furnitureGhostDraw: RoomFurnitureGhostDraw?
    /// Whether the furniture's width was measured from its cutout, so the ghost's size pill says "about". Set each time a
    /// piece of furniture is ready, which is before its ghost can show.
    private(set) var furnitureWidthIsMeasuredFromThePhoto = false
    /// The learner stands where the piece is about to be painted, so the status line asks them to step aside.
    @Published private(set) var waitingForTheLearnerToStepAside = false
    /// The wall measured on the floor's keyframe, which the ghost snaps to.
    private var wallOfTheLatestMeasurement: WallPlane?
    private var ghostScrollTurn = RoomFurnitureScrollTurn()
    /// The painting asked for as the ghost first appeared, for the box it stood in then (keyframe pixels), so a learner
    /// who places the piece where Clicky put it waits less. A move drops it.
    private var paintingAhead: (boxInTheKeyframe: [CGPoint], task: Task<RoomFurniturePaintingAheadOutcome, Never>)?
    private var stepAsideWasSaid = false
    /// The placement whose painting asked the learner to step aside (`waitingForTheLearnerToStepAside`). A painting task that
    /// a pick-up cancelled ends a moment after the next placement's task started, so it clears the flag only while the flag
    /// is still its own, and never one the newer placement set.
    private var placementTheLearnerIsAskedToStepAsideFor: RoomArtMeasurementID?
    /// The keyframe taken while the page is still read, and the wall measured on it, so the depth service's run overlaps the
    /// page read. The first measurement uses it, and the depth service answers the floor on it from its cache.
    private var earlyMeasurement: RoomArtEarlyMeasurement?

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
    /// While an item shows, the request keeps the room: the panel, the camera, the keyframe, and the tracker stay, the item
    /// becomes part of the room's background (`fixTheShownItemIntoTheBackground`), and the new item is measured and painted
    /// into that room, so a lamp can stand on a table Clicky painted. A check that fails then leaves the room as it was, and a
    /// page that shows nothing keeps it (`RoomArtPhase.roomKeptAfterAFailedItem`). Any other open panel closes and opens again.
    func showTheArtInTheRoom(learnerRequest: String) async {
        if isOpen, !phase.keepsTheRoomForANewItem { close() }
        requestNumber += 1
        var thisRequest = requestNumber
        // An earlier request still fetching its picture is stale now, so its download stops instead of running to its deadline.
        pictureTask?.cancel()
        anOpeningIsUnderway = true
        defer { if thisRequest == requestNumber { anOpeningIsUnderway = false } }

        guard environment.appSecretIsSet() else {
            environment.speak(RoomArtFailure.appSecretMissing.spokenLine, true)
            return
        }
        guard let frontTab = await environment.readTheFrontTab() else {
            environment.speak(roomArtNoPictureLine, true)
            return
        }
        // The read waits while the page's sections open, so a newer request or Escape may have moved on meanwhile.
        guard thisRequest == requestNumber, !Task.isCancelled else { return }
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
        let pictureTask = Task { await capturePicture(frontTab) }
        self.pictureTask = pictureTask
        let picture = await withTaskCancellationHandler { await pictureTask.value } onCancel: { pictureTask.cancel() }
        // Escape or a new request moved the opening number on, and a push-to-talk press cancelled this task, so the
        // learner moved on and nothing opens or speaks.
        guard thisRequest == requestNumber, !Task.isCancelled else { return }
        guard let picture,
              let pictureSource = CGImageSourceCreateWithData(picture.jpegData as CFData, nil),
              let pictureImage = CGImageSourceCreateImageAtIndex(pictureSource, 0, nil) else {
            environment.speak(roomArtNoPictureLine, true)
            return
        }
        // Read after the picture's wait, since a pick-up or a click that moves the item during it takes the item out of the
        // room, and that panel then starts over like any other.
        let keepsTheRoom = phase.keepsTheRoomForANewItem
        if isOpen, !keepsTheRoom {
            close()
            thisRequest = requestNumber
            anOpeningIsUnderway = true
        }
        // Every check passed, so this request now owns an item. Work asked for the item before it stops being current.
        openingNumber += 1
        let thisOpening = openingNumber
        if keepsTheRoom {
            // The item that showed stops being the newest: its own work ends, and it stays in the room for the new one.
            stopTheItemsWork()
            frameProcessor.fixTheShownItemIntoTheBackground()
        }
        self.pictureImage = pictureImage
        pageRequest = RoomArtPageRequest(pageURL: frontTab.url, pageTitle: frontTab.title, pageText: pageText, learnerRequest: learnerRequest, picture: picture)
        hereItIsWasSaid = false
        surfaceClickPromptsSaid = []
        shirtCoachingLine = nil
        if !keepsTheRoom {
            theSurfaceIsLost = false
            theFirstFrameIsIn = false
        }
        environment.clearTheLiveScene()
        phase = phase.opening()
        if keepsTheRoom {
            // The panel, the camera, and its session run on, and the camera already has a frame, so the item is measured as
            // soon as the page is read.
            pageReadingTask = Task { await self.readThePageAndPrepareTheItem(thisOpening: thisOpening) }
            return
        }
        panelPresenter.show()

        cameraSessionNumber += 1
        let thisSession = cameraSessionNumber
        frameProcessor.startASession(
            onFirstSegmentedFrame: { [weak self] in
                Task { @MainActor in
                    guard let self, thisSession == self.cameraSessionNumber else { return }
                    self.theFirstSegmentedFrameArrived()
                }
            },
            onTheSurfaceLostOrFound: { [weak self] surfaceIsLost in
                Task { @MainActor in
                    guard let self, thisSession == self.cameraSessionNumber else { return }
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
            if thisSession != cameraSessionNumber { frameSource.stop() }
        } catch {
            guard thisSession == cameraSessionNumber else { return }
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
    /// The room's background goes with the session, since the next panel starts a new one. The fading panel keeps drawing
    /// what it showed.
    func close() {
        environment.endTheSpokenLine()
        // Taken before anything is forgotten. A second close during the fade keeps the first one's content.
        if isOpen {
            closingPanel = RoomArtClosingPanel(content: livePanelContent, ghostTrackedWarp: trackedWarpForTheGhost())
        }
        openingNumber += 1
        requestNumber += 1
        cameraSessionNumber += 1
        anOpeningIsUnderway = false
        stopTheItemsWork()
        compositeServiceIsUnavailable = false
        frameSource?.stop()
        frameSource = nil
        frameProcessor.endTheSession()
        panelPresenter.hide(onceHidden: { [weak self] in self?.closingPanel = nil })
        pageRequest = nil
        pictureImage = nil
        theSurfaceIsLost = false
        shirtCoachingLine = nil
        theFirstFrameIsIn = false
        phase = phase.closing()
    }

    /// Stops everything a request started for its item and forgets the item's state: the page read, the picture, the
    /// measurement, the furniture's looks and their waits, the shirt's painting, and the ghost. A close runs it, and so does a
    /// request that keeps the room, so nothing asked for the item before reaches the new one.
    private func stopTheItemsWork() {
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
        furniturePlacementDeadlineTask?.cancel()
        furniturePlacementDeadlineTask = nil
        furniturePaintingRequestIsOut = false
        shirtPaintingTask?.cancel()
        shirtPaintingTask = nil
        aPressCancelledTheCapture = false
        shirtCaptureCountdownNumber = nil
        shirtBeingTried = nil
        furnitureLookSearch = nil
        furniturePlacement = nil
        furnitureRenderHeldBack = nil
        keyframeOfTheLatestMeasurement = nil
        furnitureCutoutJPEG = nil
        stepBackWasSaid = false
        forgetTheGhost()
        earlyMeasurement?.cancel()
        earlyMeasurement = nil
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
            measureOrAskForAClick()
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
        let keyframeTask = Task { () -> RoomArtKeyframe? in
            // A shirt read before this task first runs has cancelled it and forgotten the keyframe, so it takes none.
            guard !Task.isCancelled else { return nil }
            return await frameProcessor.takeAKeyframe(on: nil, anchorInCameraPixels: nil)
        }
        let wallTask = Task { () -> Result<WallPlane, Error>? in
            guard let keyframe = await keyframeTask.value, !Task.isCancelled else { return nil }
            let wallRequest = RoomWallRequest(
                keyframeJPEGData: keyframe.measurementRequest.keyframeJPEGData,
                personMaskPNGData: keyframe.measurementRequest.personMaskPNGData,
                anchor: keyframe.wallSpotAnchor ?? keyframe.measurementRequest.anchor
            )
            do { return .success(try await measureTheWall(wallRequest)) } catch { return .failure(error) }
        }
        earlyMeasurement = RoomArtEarlyMeasurement(keyframe: keyframeTask, wall: wallTask)
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
        environment.theLearnerAskedThePanel()
        moveTheGhost(to: ghost)
        return nil
    }

    /// "Right there", the Place button, or `place_furniture`: the piece is painted where its ghost stands. False when no
    /// ghost shows.
    @discardableResult
    func placeTheFurnitureWhereItsGhostStands() -> Bool {
        guard phase.furnitureGhostShows, var ghost = furnitureGhost else { return false }
        // A placement by voice or by the Place button is the learner's own, so "Step aside" and "Here it is" after it count
        // from this moment and are not dropped for an earlier press.
        environment.theLearnerAskedThePanel()
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
        furnitureGhostDraw = RoomFurnitureGhostDraw(beganAt: ProcessInfo.processInfo.systemUptime)
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
    /// A closing panel keeps the lines it had.
    func currentGhostLines(cameraSize: CGSize, panelSize: CGSize) -> RoomFurnitureGhostLines? {
        let trackedWarp = if let closingPanel { closingPanel.ghostTrackedWarp } else { trackedWarpForTheGhost() }
        guard let boxCorners = panelContent.furnitureGhost?.keyframeBoxCorners, let trackedWarp else { return nil }
        return RoomFurnitureGhostLines(keyframeBoxCorners: boxCorners, keyframeToCurrent: trackedWarp.keyframeToCurrent, fit: RoomArtVideoFit(cameraSize: cameraSize, viewSize: panelSize), cameraSize: cameraSize)
    }

    /// Forgets the ghost and everything asked for it, for a close or a new measurement.
    private func forgetTheGhost() {
        paintingAhead?.task.cancel()
        paintingAhead = nil
        furnitureGhost = nil
        furnitureGhostDraw = nil
        waitingForTheLearnerToStepAside = false
        placementTheLearnerIsAskedToStepAsideFor = nil
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
            // An item that fills its four corners is flattened from the photo as it is. Any other outline, such as a round
            // clock, would hang the photo's background corners with it, so it is cut out by its own shape first and the
            // flattened art keeps transparent pixels outside the item.
            var pictureToFlatten = pictureImage
            if !wallArtReading.fillsItsCorners {
                let itemOnItsOwn = await environment.cutOutTheWallItemByItsShape(pictureImage, wallArtReading.artworkCorners)
                guard !Task.isCancelled, thisOpening == openingNumber else { return }
                guard let itemOnItsOwn else {
                    print("Room art: Vision found no shape to cut the wall item out by")
                    apply(phase.afterThePageFailed(.furnitureNotCutOut))
                    return
                }
                print("Room art: cut the wall item out of its photo by its own shape")
                pictureToFlatten = itemOnItsOwn
            }
            guard let flattenedImage = flattenedArtwork(
                picture: pictureToFlatten,
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
            if furnitureReading.standsOn.needsAClickOnItsSurface, let earlyMeasurement {
                // The click takes its own keyframe, so the depth service cannot answer it from the early frame's cached depth.
                // The early measurement is cancelled and its keyframe forgotten, as a shirt's are, so its reply is never read.
                // The service still finishes that run of about 14 seconds under its one lock, since it does not stop when the
                // app drops the request, so the click's own measurement may wait for it. A request that kept the room took no
                // early keyframe, and its keyframe holds the items the click is measured on, so it stays.
                earlyMeasurement.cancel()
                self.earlyMeasurement = nil
                frameProcessor.forgetTheKeyframe()
            }
            guard let furniture = RoomFurniture.standing(title: furnitureReading.title, size: size, cutoutImage: cutoutImage, standsOn: furnitureReading.standsOn) else {
                print("Room furniture: the width measured from the cutout is outside 2 to 600 cm, so nothing is placed")
                apply(phase.afterThePageFailed(.sizeNotOnThePage))
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
            furnitureWidthIsMeasuredFromThePhoto = furniture.widthIsMeasuredFromThePhoto
            itemIsReady(.furniture(furniture))

        case .tryOnTheShirt(let clothingReading):
            print("Room art: \"\(clothingReading.title)\" is a \(clothingReading.garment.rawValue) with \(clothingReading.sleeves.rawValue) sleeves to the \(clothingReading.length.rawValue), photographed \(clothingReading.photoShows.rawValue), size \(clothingReading.chosenSizeLabel)")
            // A shirt measures no surface, so the keyframe taken during the page read is not tracked.
            earlyMeasurement?.cancel()
            earlyMeasurement = nil
            frameProcessor.forgetTheKeyframe()
            // The painting crops the product photo from the picture that shows the garment's front, which the page reader
            // chose from the page's photos, so the panel fails with `pageNotRead` when that picture cannot be decoded.
            let frontPicture = clothingReading.frontPictureIndex == 0 ? pictureImage : pageRequest.picture.picture(numbered: clothingReading.frontPictureIndex).flatMap { picture in
                CGImageSourceCreateWithData(picture.jpegData as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            }
            guard let frontPicture else {
                apply(phase.afterTheShirtsPictureCouldNotBeRead())
                return
            }
            print("Room art: the garment's front is picture \(clothingReading.frontPictureIndex) of \(1 + pageRequest.picture.otherPictures.count), its cloth is \(clothingReading.mainColorHex)")
            shirtBeingTried = (clothingReading, frontPicture)
            // The camera shows the learner as filmed, and the framing is read for the capture "paint it" arms.
            frameProcessor.startTheShirtTryOn(onTheFramingSettled: { [weak self] settledKind in
                Task { @MainActor in
                    guard let self, thisOpening == self.openingNumber else { return }
                    self.shirtCoachingLine = settledKind.coachingLine
                }
            })
            apply(phase.startingTheShirt(title: clothingReading.title))
        }
    }

    /// A wall item or a standing item is ready, and its surface is measured as soon as the camera has a frame.
    private func itemIsReady(_ item: RoomArtPlacedItem) {
        apply(phase.withTheItemReady(item))
        if theFirstFrameIsIn { measureOrAskForAClick() }
    }

    /// The item is ready and the camera has a frame: the item's surface is measured where the bare spot search puts it, or a
    /// table or shelf item asks for a click first (`RoomArtPhase.askingForAClickIfTheItemNeedsOne`).
    private func measureOrAskForAClick() {
        let askingPhase = phase.askingForAClickIfTheItemNeedsOne()
        guard askingPhase == phase else {
            apply(askingPhase)
            return
        }
        startAMeasurement(anchorInCameraPixels: nil)
    }

    // MARK: The shirt

    /// "Paint it" (or its alias "right there") or the Paint it button: arms the capture, so the learner can step back
    /// from the keyboard, and the frame freezes once they stand in the ready framing and hold still for the countdown
    /// (`ShirtStepBackCapture`). Asking again while the capture waits restarts it. One painting runs at a time
    /// (`RoomArtPhase.armingTheShirtCapture`).
    func paintTheShirt() {
        let paintingID = ShirtPaintingID(number: lastShirtPaintingNumber + 1)
        let armedPhase = phase.armingTheShirtCapture(id: paintingID)
        guard armedPhase != phase, shirtBeingTried != nil else { return }
        environment.theLearnerAskedThePanel()
        lastShirtPaintingNumber = paintingID.number
        aPressCancelledTheCapture = false
        shirtCaptureCountdownNumber = nil
        apply(armedPhase)
        environment.speak(roomArtShirtStepBackLine, false)
        // The painting numbers count up across openings, so an event from an earlier panel names an ID no phase holds.
        frameProcessor.armTheShirtCapture { [weak self] event in
            Task { @MainActor in
                self?.theShirtCaptureReported(event, id: paintingID)
            }
        }
    }

    /// What the armed capture reports. Each event names the capture it came from, so one from a capture the learner
    /// restarted, cancelled, or left changes nothing.
    private func theShirtCaptureReported(_ event: ShirtCaptureEvent, id paintingID: ShirtPaintingID) {
        guard case .waitingForTheLearnerToStepBack(_, let armedID) = phase, armedID == paintingID else { return }
        if let countdownSound = shirtCountdownSound(for: event) {
            environment.playTheShirtCountdownSound(countdownSound)
        }
        switch event {
        case .countdown(let number):
            shirtCaptureCountdownNumber = number
        case .timedOut:
            print("Shirt painting: the capture gave up, since no hold completed within \(Int(ShirtStepBackCapture.secondsBeforeGivingUp)) s")
            shirtCaptureCountdownNumber = nil
            apply(phase.afterTheStepBackTimedOut(id: paintingID))
            environment.speak(roomArtShirtStepBackTimeoutLine, false)
        case .frozen(let frozenFrame):
            shirtCaptureCountdownNumber = nil
            apply(phase.afterTheLearnerHeldStill(id: paintingID))
            paintTheShirt(onTheFrozenFrame: frozenFrame, id: paintingID)
        }
    }

    private func paintTheShirt(onTheFrozenFrame frozenFrame: ShirtFrozenFrame, id paintingID: ShirtPaintingID) {
        guard let shirtBeingTried else { return }
        let thisOpening = openingNumber
        let startedAt = Date()
        shirtPaintingTask = Task {
            // Each await below can come back to a panel the learner closed or went back from, which both cancel this task.
            @MainActor func isStillThisPainting() -> Bool { !Task.isCancelled && thisOpening == self.openingNumber }
            // A go back before this task first ran resumed nothing yet, so nothing may be sent after it.
            guard isStillThisPainting() else { return }
            guard let masks = await environment.makeTheShirtPaintMasks(frozenFrame, ShirtCoverage(reading: shirtBeingTried.reading)) else {
                guard isStillThisPainting() else { return }
                theShirtPaintingFailed(.maskNotMade, id: paintingID)
                return
            }
            guard isStillThisPainting() else { return }
            // The loop now traces the area being painted, the mask's own outline. It is traced here, under the same check as
            // every other step, so an outline from a painting the learner left never lands on a newer freeze.
            let paintedAreaOutline = await Task.detached(priority: .userInitiated) { ShirtPaintMask.outlineOfThePaintableArea(masks) }.value
            guard isStillThisPainting() else { return }
            if let paintedAreaOutline { frameProcessor.outlineTheAreaBeingPainted(paintedAreaOutline) }
            print(String(format: "Shirt painting: the mask covers %.1f%% of the frame, %.1f s after the capture froze", masks.paintableShare * 100, Date().timeIntervalSince(startedAt)))
            guard let productJPEG = shirtPaintingProductJPEG(picture: shirtBeingTried.frontPicture, itemCorners: shirtBeingTried.reading.itemCorners) else {
                theShirtPaintingFailed(.paintingFailed, id: paintingID)
                return
            }
            let paintingRequest = ShirtPaintingRequest(
                keyframe: frozenFrame.cameraImage,
                productJPEG: productJPEG,
                masks: masks,
                itemTitle: shirtBeingTried.reading.title,
                garment: ShirtPaintingGarment(
                    kind: shirtBeingTried.reading.garment,
                    sleeves: shirtBeingTried.reading.sleeves,
                    length: shirtBeingTried.reading.length,
                    baseColorHex: shirtBeingTried.reading.mainColorHex,
                    printDescription: shirtBeingTried.reading.printDescription
                )
            )
            let painted: CGImage
            do {
                painted = try await environment.paintTheShirt(paintingRequest)
            } catch {
                guard isStillThisPainting() else { return }
                print("Shirt painting: the shirt was not painted: \(error)")
                theShirtPaintingFailed(shirtPaintingFailure(for: error), id: paintingID)
                return
            }
            guard isStillThisPainting() else { return }
            print(String(format: "Shirt painting: painted and pasted in %.1f s", Date().timeIntervalSince(startedAt)))
            frameProcessor.showThePaintedStill(painted)
            apply(phase.withThePaintedShirt(id: paintingID))
            thePaintedTopIsOutOfReach = false
            // Paint once, then track it: the painted top is cut out of the still, and the still shows until it is ready.
            let livePaintedTop = await environment.makeTheLivePaintedTop(painted, masks, frozenFrame.torso, ShirtCoverage(reading: shirtBeingTried.reading))
            guard isStillThisPainting() else { return }
            guard let livePaintedTop else {
                print("Shirt painting: the painted top could not be cut out to follow the learner, so the still stays")
                return
            }
            letThePaintedTopFollowTheLearner(livePaintedTop)
            print(String(format: "Shirt painting: the painted top follows the learner live, %.1f s after the capture froze", Date().timeIntervalSince(startedAt)))
        }
    }

    /// Save photo, by its button or "save this photo": writes the frame the panel last drew, at the camera's own size, as a
    /// JPEG in `photoFolder`, and shows a chip that says where, or that it failed. The panel stays open either way.
    func saveThePhoto() {
        guard let itemTitle = phase.photoTitleToSave, photoSavingTask == nil else { return }
        let frameProcessor = frameProcessor, photoFolder = environment.photoFolder, savedAt = Date()
        photoSavingTask = Task { [weak self] in
            // The render waits on the processing queue and the write on the disk, so neither runs on the main actor.
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                guard let frameImage = frameProcessor.renderTheLastFrame() else { return .failure(RoomArtPhotoSaving.SaveError.nothingDrawnYet) }
                return Result { try RoomArtPhotoSaving.save(frameImage, itemTitle: itemTitle, savedAt: savedAt, in: photoFolder) }
            }.value
            guard let self else { return }
            photoSavingTask = nil
            switch outcome {
            case .success(let photoURL):
                print("Room art: saved the photo to \(photoURL.path)")
                environment.showTheChip(roomArtPhotoSavedChip, false)
            case .failure(let error):
                print("Room art: could not save the photo: \(error)")
                environment.showTheChip(roomArtPhotoNotSavedChip, true)
            }
        }
    }

    private func letThePaintedTopFollowTheLearner(_ livePaintedTop: ShirtLivePaintedTop) {
        frameProcessor.followTheLearnerWithThePaintedTop(livePaintedTop) { [weak self] hintIsShowing in
            Task { @MainActor in
                self?.thePaintedTopHintChanged(isShowing: hintIsShowing)
            }
        }
    }

    /// The painted top went out of the learner's reach (so the status line says to stand as they did) or came back. Only
    /// while the painted still shows, since the line is the still's.
    private func thePaintedTopHintChanged(isShowing: Bool) {
        guard case .showingThePaintedShirt = phase else { return }
        thePaintedTopIsOutOfReach = isShowing
    }

    /// "Go back" or Back to live: the live camera comes back, from the painted still or from a painting on its way, which
    /// is cancelled.
    func goBackToTheLiveShirt() {
        let livePhase = phase.backToTheLiveShirt()
        guard livePhase != phase else { return }
        environment.theLearnerAskedThePanel()
        shirtPaintingTask?.cancel()
        shirtPaintingTask = nil
        frameProcessor.disarmTheShirtCapture()
        shirtCaptureCountdownNumber = nil
        frameProcessor.resumeTheLiveShirt()
        apply(livePhase)
    }

    /// A push-to-talk press while the capture waits for the learner to step back cancels it, with nothing said, since the
    /// press is the learner's next request, such as "paint it" again, which arms a new capture. The press also resumes the
    /// live frame, since the processor may have frozen one whose event is still on its way and will be dropped as stale. The
    /// transcript of that press still reaches the capture's phrases (`shirtStillVoiceTargetsForTheRoute`), so "go back" never
    /// falls through to the router and seeks a video.
    func theLearnerPressedPushToTalk() {
        aPressCancelledTheCapture = false
        guard case .waitingForTheLearnerToStepBack = phase else { return }
        leaveTheStepBack()
        aPressCancelledTheCapture = true
    }

    private func leaveTheStepBack() {
        frameProcessor.disarmTheShirtCapture()
        shirtCaptureCountdownNumber = nil
        frameProcessor.resumeTheLiveShirt()
        apply(phase.backToTheLiveShirt())
    }

    /// What the voice route reads for the shirt's phrases. Right after a press cancelled the waiting capture, the capture's
    /// phrases still apply to that press's transcript, until the next press, a new capture, or a close.
    var shirtStillVoiceTargetsForTheRoute: ShirtStillVoiceTargets {
        if aPressCancelledTheCapture, case .readyToPaintTheShirt = phase { return .stepBack }
        return phase.shirtStillVoiceTargets
    }

    /// What the shirt panel can do by voice now, which the voice route reads.
    var shirtStillVoiceTargets: ShirtStillVoiceTargets { phase.shirtStillVoiceTargets }

    /// A click on the panel's shirt button: Paint it while the camera shows the learner, Back to live while a painting is made or
    /// the painted still shows. The one button changes role as the phase does, so a click within
    /// `shirtButtonSecondsIgnoredAfterItChanges` of a change is not counted (`shirtButtonPressCounts`), or the second click
    /// of a double-click on Back to live would send a new camera frame out. `now` is the system uptime, which a test passes.
    func pressTheShirtButton(atUptime now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard shirtButtonPressCounts(atUptime: now, theButtonChangedAt: shirtStillVoiceTargetsChangedAt) else {
            print("Shirt painting: a click on the button right after it changed was not counted")
            return
        }
        switch shirtStillVoiceTargets {
        case .readyToPaint: paintTheShirt()
        case .stepBack, .paintedStill: goBackToTheLiveShirt()
        case .none: break
        }
    }

    private func theShirtPaintingFailed(_ failure: ShirtPaintingFailure, id paintingID: ShirtPaintingID) {
        print("Shirt painting: back to the live camera, because \(failure)")
        frameProcessor.resumeTheLiveShirt()
        apply(phase.afterThePaintingFailed(id: paintingID))
        environment.speak(failure.spokenLine, true)
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
            // This task now owns the early measurement, so `close()` finds none in `self.earlyMeasurement` to cancel. A close
            // cancels this task instead, and the cancel goes on to the early keyframe and the early wall's 14 second depth run,
            // which unstructured tasks never receive from the task that awaits them.
            await withTaskCancellationHandler {
                // The keyframe is ready at once. The early wall is awaited separately, since it takes the depth service's 14 seconds.
                let earlyKeyframe = await earlyMeasurement?.keyframe.value
                let keyframeOrNil: RoomArtKeyframe?
                if let earlyKeyframe {
                    keyframeOrNil = earlyKeyframe
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
                        if earlyKeyframe != nil, let earlyWall = earlyMeasurement?.wall {
                            guard let earlyWallResult = await earlyWall.value else { throw CancellationError() }
                            wall = try earlyWallResult.get()
                        } else {
                            wall = try await environment.measureTheWall(keyframe.measurementRequest)
                        }
                        print(String(format: "Room art: wall %.2f m away at %.0f degrees, %.0f%% of it fits the plane", wall.distanceMeters, wall.wallAngleDegrees, wall.planeInlierShare * 100))
                        surface = .wall(wall)
                    case .floor:
                        // The floor waits for the early wall's run, and so answers from the depth service's cache: asked while that
                        // run is in flight, it would start a second 14 second run of the same frame.
                        let earlyWallResult = await earlyMeasurement?.wall.value
                        let floor = try await measureTheFurnituresFloor(on: keyframe, for: measuringPhase.itemBeingMeasured, anchorWasClicked: anchorInCameraPixels != nil, wallAlreadyMeasured: earlyWallResult)
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
            } onCancel: {
                earlyMeasurement?.cancel()
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
            // Whether the whole piece shows is read from where the learner placed its ghost, not from the spot search.
            var adviceForACutOffPiece: String?
            if case .furniture = item, case .floor(let floor) = surface, let furnitureGhost {
                adviceForACutOffPiece = roomFurnitureAdviceForAPieceTheFrameCutsOff(
                    shareOfTheBoxInTheFrame: furnitureGhost.shareOfTheBoxInTheFrame, floorIsInferredFromTheWall: floor.inferredFromTheWall
                )
            }
            // "Here it is" and the advice are one line: each line cancels the one waiting before it, so two lines started
            // in this turn would play only the advice.
            if !hereItIsWasSaid {
                hereItIsWasSaid = true
                stepBackWasSaid = stepBackWasSaid || adviceForACutOffPiece != nil
                environment.speak([item.hereItIsLine, adviceForACutOffPiece].compactMap { $0 }.joined(separator: " "), false)
            } else if let adviceForACutOffPiece, !stepBackWasSaid {
                // A later placement that the frame cuts off, after one that it did not, still gets the advice once.
                stepBackWasSaid = true
                environment.speak(adviceForACutOffPiece, false)
            }
        case .placingTheFurniture(_, let item, let surface):
            stopTheFurnituresLooks()
            // A pick-up made its ghost already. The first time, the ghost stands where the spot search put the piece, and its
            // tracer starts on the footprint, since no loop showed while the floor was measured.
            guard furnitureGhost == nil else { return }
            guard case .furniture(let furniture) = item, case .floor(let floor) = surface,
                  let ghost = RoomFurnitureGhost(standingOn: floor, wall: wallOfTheLatestMeasurement, widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters) else {
                print("Room furniture: the ghost cannot stand on this floor, so the panel asks for a click on the floor")
                apply(phase.afterTheGhostCouldNotStand())
                return
            }
            furnitureGhostDraw = RoomFurnitureGhostDraw(beganAt: ProcessInfo.processInfo.systemUptime)
            furnitureGhost = ghost
            print("Room furniture: the ghost shows\(ghost.shownPose.isSnappedToTheWall ? ", square to the wall" : "")")
            // Said here and never after a pick-up, which returned above with its ghost already made, so it is once per panel.
            environment.speak(roomFurnitureGhostLine, false)
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
            // While the painting comes, the loop goes around the ghost's footprint, which stays at half opacity: back left,
            // back right, front right, front left, clockwise on screen. A footprint below the frame is drawn off the picture,
            // so the loop goes around the visible part of the box then (`roomFurnitureLoopQuadrilateral`).
            // The depth service's principal point is the frame's center.
            let frameSize = CGSize(width: floor.principalPoint.x * 2, height: floor.principalPoint.y * 2)
            if let loopQuadrilateral = roomFurnitureLoopQuadrilateral(projectedBox: boxInTheKeyframe, frameSize: frameSize) {
                frameProcessor.outlineTheLoop(aroundKeyframeQuadrilateral: loopQuadrilateral, inKeyframeNumber: keyframe.keyframeNumber)
            }
            print(String(
                format: "Room furniture: placed facing %@%@%@", ghost.facing.rawValue,
                ghost.shownPose.isSnappedToTheWall ? ", its back on the wall" : "", floor.inferredFromTheWall ? ", on a floor inferred from the wall" : ""
            ))
            // The painting is the piece's first look, and the model's render shows only if none comes in time. The wait
            // for the request starts when it goes out (`startTheLookDeadline`), and the wait from the placement starts here,
            // since no request goes out while the learner covers the box.
            furniturePlacement = (measurementID, furniture, keyframe, floor, ghost)
            furniturePaintingCannotCome = false
            furnitureWaitRanOut = false
            furniturePlacementWaitRanOut = false
            startThePlacementDeadline(measurementID: measurementID)
            startPaintingTheFurniture()
            startRenderingTheFurnituresModel()
        case .couldNotDraw(_, let item, _):
            // The loop stays and the camera keeps running, so a click on the surface picks the ghost back up there.
            environment.speak(item.notDrawnLine, true)
        case .waitingForAFloorClick(let item, let aClickFoundNothing, _):
            // The camera keeps running, so the learner can tilt the screen down and click the floor, or click the table or
            // shelf where the item goes.
            let prompt = item.surfaceClickPrompt(afterAClickFoundNothing: aClickFoundNothing)
            guard surfaceClickPromptsSaid.insert(prompt).inserted else { return }
            environment.speak(prompt.spokenLine, prompt.isAFailure)
        case .readyToPaintTheShirt:
            // Said once per panel, also when a painting the learner left or that failed brings this phase back: how to start
            // the painting, and that the painted top follows only a pose close to the one it was painted in.
            sayHereItIsOnce(roomArtShirtReadyLine)
        case .showingThePaintedShirt:
            // Said each time a painting shows, since each is a new look the learner asked for.
            environment.speak(roomArtShirtPaintedLine, false)
        case .failed(let failure):
            // The panel keeps its last frame and says what went wrong until the learner closes it. The wall measured on the
            // early keyframe has nothing left to place, so its request stops too.
            earlyMeasurement?.cancel()
            earlyMeasurement = nil
            frameSource?.stop()
            frameSource = nil
            frameProcessor.endTheSession()
            environment.speak(failure.spokenLine, true)
        case .roomKeptAfterAFailedItem(let failure):
            // The camera and the room's placed items stay, so the next request places its item among them.
            environment.speak(failure.spokenLine, true)
        case .closed, .readingThePage, .readingThePageInTheKeptRoom, .waitingForTheCamera, .measuring, .moving,
             .waitingForTheLearnerToStepBack, .paintingTheShirt:
            break
        }
    }

    /// Stops every look on its way for the placement before, for a new placement or a pick-up.
    private func stopTheFurnituresLooks() {
        furnitureLookDeadlineTask?.cancel()
        furniturePlacementDeadlineTask?.cancel()
        furniturePaintingTask?.cancel()
        // The request itself is not cancelled: a pick-up that puts the piece back in the same box uses it
        // (`startPaintingTheFurniture`), and a move, a new measurement, and a close cancel it (`paintingAhead`).
        furniturePaintingRequestIsOut = false
        furnitureRenderTask?.cancel()
        furnitureRenderIsRunning = false
        furnitureRenderHeldBack = nil
        waitingForTheLearnerToStepAside = false
        placementTheLearnerIsAskedToStepAsideFor = nil
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
    /// with the wall (a desk or a bed) is not the floor, and neither is a plane less than
    /// `roomFurnitureLeastFloorHeightBelowTheCameraMeters` below the camera unless the learner clicked it, since a desk is
    /// level with the wall. With no floor, a floor inferred from the wall stands the piece with
    /// its back on the wall, when at least a third of its box is in the frame. A depth service that is down or refuses the
    /// request fails as it is, with no wall measurement.
    fileprivate func measureTheFurnituresFloor(
        on keyframe: RoomArtKeyframe, for item: RoomArtPlacedItem?, anchorWasClicked: Bool, wallAlreadyMeasured: Result<WallPlane, Error>? = nil
    ) async throws -> FloorPlane {
        var measuredFloor: FloorPlane?
        var floorError: Error?
        // A table or shelf top is measured with its own fit, so the request says what the item stands on.
        var floorRequest = keyframe.measurementRequest
        floorRequest.standsOn = item?.standsOn ?? .floor
        do {
            measuredFloor = try await environment.measureTheFloor(floorRequest)
        } catch {
            guard roomArtFailure(forAFailedMeasurementOf: .floor, error: error) == .floorNotFound else { throw error }
            floorError = error
        }
        guard !Task.isCancelled else { throw CancellationError() }
        // The spot is chosen before the wall is measured.
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
        // Why no floor could stand the piece, for the error and the log, which differ for each way a measured floor is refused.
        var whyNoFloorStoodThePiece = "No floor was in view and the wall gave none to stand the piece on"
        if let measuredFloor, let floorForThePiece {
            if !anchorWasClicked, measuredFloor.heightBelowTheCameraMeters < roomFurnitureLeastFloorHeightBelowTheCameraMeters {
                // Level with the wall, so the angle check below passes it, but nearer the camera than any floor is.
                whyNoFloorStoodThePiece = "The measured floor is less than \(roomFurnitureLeastFloorHeightBelowTheCameraMeters) m below the camera"
                print(String(format: "Room furniture: the measured floor is only %.2f m below the camera, so it is a desk, a bed, or a table, not the floor", measuredFloor.heightBelowTheCameraMeters))
            } else if let wall, !measuredFloor.agrees(withTheWall: wall) {
                whyNoFloorStoodThePiece = "The floor is not level with the wall"
                print("Room furniture: the measured floor is not level with the wall, so it is a desk or a bed, not the floor")
            } else {
                return floorForThePiece
            }
        }
        // A table or shelf item is never put on a floor inferred from the wall: the learner clicks its surface instead.
        if let wall, case .furniture(let furniture) = item, !furniture.standsOn.needsAClickOnItsSurface,
           let inferredFloor = FloorPlane.inferred(fromTheWall: wall, itemDepthMeters: furniture.depthMeters),
           let boxCorners = inferredFloor.keyframeBoxCorners(widthMeters: furniture.widthMeters, heightMeters: furniture.heightMeters, depthMeters: furniture.depthMeters) {
            let frameSize = CGSize(width: inferredFloor.principalPoint.x * 2, height: inferredFloor.principalPoint.y * 2)
            let shareInTheFrame = shareOfTheBoxInsideTheFrame(projectedCorners: boxCorners, frameSize: frameSize)
            print(String(format: "Room furniture: no floor in view, so the floor is inferred from the wall, with %.0f%% of the piece in the frame", shareInTheFrame * 100))
            if shareInTheFrame >= roomFurnitureLeastShareOfTheBoxInTheFrame { return inferredFloor }
        }
        throw floorError ?? RoomArtWorkerError.workerReturned(statusCode: 422, body: #"{"error":"\#(whyNoFloorStoodThePiece)"}"#)
    }

    /// The floor anchored where the whole piece shows (`roomFurnitureSpotWhereTheWholePieceFits`), since the bare spot it was
    /// measured at is often a corner where the frame cuts the piece off. A click keeps the spot the learner clicked, and a
    /// piece no spot shows whole is placed where most of it shows. Where the learner places its ghost decides the advice
    /// that is part of the "Here it is" line, when the placed piece does not all show (`roomFurnitureAdviceForAPieceTheFrameCutsOff`).
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
        let thisOpening = openingNumber, measurementID = placement.measurementID
        // A painting request already out for this box counts: the one asked for as the ghost appeared, or the one a pick-up
        // left running, since a learner who puts the piece back where it stood needs no second request. Any other box
        // drops it. It stays in `paintingAhead` while it runs, so a pick-up keeps it.
        let paintingInFlightForThisBox = paintingAhead.flatMap { $0.boxInTheKeyframe == boxInTheKeyframe ? $0.task : nil }
        if paintingInFlightForThisBox == nil {
            paintingAhead?.task.cancel()
            paintingAhead = nil
        }
        let orientation = placement.ghost.paintingOrientation
        furniturePaintingTask = Task {
            var finishedPainting: RoomFurnitureFinishedPainting?
            var paintingsWereAskedFor = false
            if let paintingInFlightForThisBox {
                print("Room furniture: the piece stands where a painting is already asked for, so that painting is used")
                // The request is out for this placement now, so the wait for it counts from here.
                startTheLookDeadline(measurementID: measurementID)
                let outcome = await paintingInFlightForThisBox.value
                guard !Task.isCancelled, thisOpening == openingNumber else { return }
                switch outcome {
                case .painted(let paintingAhead): finishedPainting = paintingAhead
                // Its two paintings were refused or failed, which another two for the same box would likely repeat.
                case .noPaintingStood: paintingsWereAskedFor = true
                // Nothing was asked, since the learner stood in the box, so the wait starts again once they are out of it.
                case .notAsked: stopTheLookDeadline()
                }
            }
            if finishedPainting == nil, !paintingsWereAskedFor, !compositeServiceIsUnavailable,
               let paintingFrame = await aClearFrameForThePainting(boxInTheKeyframe: boxInTheKeyframe, measurementID: measurementID, thisOpening: thisOpening) {
                let request = Task { () -> RoomFurniturePaintingAheadOutcome in
                    let painting = await paintTheComposite(
                        furniture: placement.furniture, paintingFrame: paintingFrame, boxInTheKeyframe: boxInTheKeyframe,
                        orientation: orientation, keyframeNumber: placement.keyframe.keyframeNumber, thisOpening: thisOpening
                    )
                    return painting.map { .painted($0) } ?? .noPaintingStood
                }
                paintingAhead = (boxInTheKeyframe, request)
                startTheLookDeadline(measurementID: measurementID)
                let outcome = await request.value
                guard !Task.isCancelled, thisOpening == openingNumber else { return }
                if case .painted(let painting) = outcome { finishedPainting = painting }
            }
            guard !Task.isCancelled, thisOpening == openingNumber else { return }
            // The request is back, whatever it brought, so nothing is in flight and a finished one is not used again.
            furniturePaintingRequestIsOut = false
            paintingAhead = nil
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

    /// Starts the wait for the newest placement's painting once its request is out, and marks the request as in flight.
    /// The wait counts only the request's own time: it does not start while the learner stands in the box
    /// (`aClearFrameForThePainting`), which has no limit of its own. It ends the fallback's patience only for a render, since
    /// a request in flight has its own timeout (`roomFurnitureFallbackStep`).
    private func startTheLookDeadline(measurementID: RoomArtMeasurementID) {
        furniturePaintingRequestIsOut = true
        furnitureWaitRanOut = false
        furnitureLookDeadlineTask?.cancel()
        let thisOpening = openingNumber
        let waitTheLongestForAFurnitureLook = environment.waitTheLongestForAFurnitureLook
        furnitureLookDeadlineTask = Task {
            await waitTheLongestForAFurnitureLook()
            guard !Task.isCancelled, thisOpening == openingNumber, furniturePlacement?.measurementID == measurementID else { return }
            furnitureWaitRanOut = true
            showTheFurnitureFallbackIfItIsDue()
        }
    }

    /// Starts the wait counted from the newest placement, which runs whether or not a request goes out. When it runs out it
    /// shows a ready render, or says the piece could not be drawn once the model search has ended with no render and no
    /// request is out (`roomFurnitureFallbackStep`).
    private func startThePlacementDeadline(measurementID: RoomArtMeasurementID) {
        furniturePlacementDeadlineTask?.cancel()
        let thisOpening = openingNumber
        let waitTheLongestAfterAFurniturePlacement = environment.waitTheLongestAfterAFurniturePlacement
        furniturePlacementDeadlineTask = Task {
            await waitTheLongestAfterAFurniturePlacement()
            guard !Task.isCancelled, thisOpening == openingNumber, furniturePlacement?.measurementID == measurementID else { return }
            furniturePlacementWaitRanOut = true
            showTheFurnitureFallbackIfItIsDue()
        }
    }

    private func stopTheLookDeadline() {
        furnitureLookDeadlineTask?.cancel()
        furnitureLookDeadlineTask = nil
        furniturePaintingRequestIsOut = false
        furnitureWaitRanOut = false
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
    private func aClearFrameForThePainting(boxInTheKeyframe: [CGPoint], measurementID: RoomArtMeasurementID, thisOpening: Int) async -> RoomArtPaintingFrame? {
        // Only this placement's own ask is taken back. A task that a pick-up cancelled ends after the next placement's task
        // set its ask, and must not clear it until that task's next look, 300 ms later, sets it again.
        defer {
            if placementTheLearnerIsAskedToStepAsideFor == measurementID {
                waitingForTheLearnerToStepAside = false
                placementTheLearnerIsAskedToStepAsideFor = nil
            }
        }
        while !Task.isCancelled, thisOpening == openingNumber {
            if let paintingFrame = await frameProcessor.aFrameForThePainting(boxInTheKeyframe: boxInTheKeyframe) {
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                if paintingFrame.shareOfTheBoxThePersonCovers <= roomFurnitureMostOfTheBoxThePersonMayCover { return paintingFrame }
                waitingForTheLearnerToStepAside = true
                placementTheLearnerIsAskedToStepAsideFor = measurementID
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
    /// piece and a line that says it could not be drawn, since the flat cutout reads as a sticker. The line never comes while
    /// a painting request is out, so a painting that arrives after it was said is one that was asked for later, once the
    /// learner stepped out of the box. A placement that already shows a look changes nothing, a painting that arrives later
    /// still crossfades over the render or shows the piece, and a render that finishes after the piece could not be drawn
    /// still shows it.
    private func showTheFurnitureFallbackIfItIsDue() {
        guard let furniturePlacement else { return }
        let reason = furnitureWaitRanOut || furniturePlacementWaitRanOut ? "no painting came within \(Int(roomFurnitureSecondsToWaitForALook)) s" : "no painting can come"
        let measurementID = furniturePlacement.measurementID
        switch roomFurnitureFallbackStep(
            paintingCannotCome: furniturePaintingCannotCome, theWaitRanOut: furnitureWaitRanOut,
            thePlacementWaitRanOut: furniturePlacementWaitRanOut,
            aPaintingRequestIsInFlight: furniturePaintingRequestIsOut, render: furnitureRenderState
        ) {
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
        // The tracker's turn moves the box, so whether the frame cuts off its feet is read for this painting frame.
        var orientation = orientation
        orientation.itemContinuesPastTheFrameBottom = roomFurnitureFootprintReachesTheFrameBottom(projectedBox: projectedBox, frameHeight: frameImage.height)
        orientation.standsOn = furniture.standsOn
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
                    orientation: orientation,
                    projectedBox: projectedBox
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
                    var layersWithTheirLight = layers
                    layersWithTheirLight.roomLightWhenMade = paintingFrame.roomLight
                    return RoomFurnitureFinishedPainting(layers: layersWithTheirLight, keyframeNumber: keyframeNumber, layerToKeyframe: paintingFrame.keyframeToFrame.inverted)
                }
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                print("Room furniture: painting \(attempt) is shorter than the box's front, taller than its outline, off its footprint, or cut off, so it is not shown")
            } catch {
                guard !Task.isCancelled, thisOpening == openingNumber else { return nil }
                print("Room furniture: no painted composite from painting \(attempt): \(error)")
                // A Worker with no OpenAI key, or an OpenAI account out of credit, stays that way for this panel, so later
                // placements do not ask again.
                switch error {
                case RoomFurnitureGenerationError.serviceIsNotSetUp, RoomFurnitureGenerationError.serviceIsOutOfCredit: compositeServiceIsUnavailable = true
                default: break
                }
                guard roomFurniturePaintingIsWorthAskingForAgain(after: error) else { return nil }
            }
        }
        print("Room furniture: no painting stood at the measured size")
        return nil
    }

    #if DEBUG
    private func writeThePaintingForVerification(_ painted: RoomFurniturePaintedKeyframe, keyframeJPEG: Data, maskPNG: Data, projectedBox: [CGPoint]) {
        // Only the running Debug app keeps its paintings. A test run's stub paintings left about 21,000 files in the
        // temporary folder on 2026-11-23, so neither `tools/swift-check.sh`'s runner nor Xcode's test host writes them.
        guard debugAppKeepsItsPaintings(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment,
            xcTestIsLoaded: NSClassFromString("XCTestCase") != nil
        ) else { return }
        let stem = "clicky-room-furniture-painting-\(Int(Date().timeIntervalSince1970 * 1000))"
        let folder = FileManager.default.temporaryDirectory
        let fileURL = folder.appendingPathComponent("\(stem).png")
        func writePNG(_ image: CGImage, to url: URL) -> Bool {
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination)
        }
        guard writePNG(painted.image, to: fileURL) else { return }
        _ = writePNG(painted.pastedRegion, to: folder.appendingPathComponent("\(stem)-region.png"))
        _ = writePNG(painted.pieceLayer, to: folder.appendingPathComponent("\(stem)-piece.png"))
        try? keyframeJPEG.write(to: folder.appendingPathComponent("\(stem)-keyframe.jpg"))
        try? maskPNG.write(to: folder.appendingPathComponent("\(stem)-mask.png"))
        let boxNumbers = projectedBox.flatMap { [Double($0.x), Double($0.y)] }
        try? JSONSerialization.data(withJSONObject: boxNumbers).write(to: folder.appendingPathComponent("\(stem)-box.json"))
        print("Room furniture: wrote the painting to \(fileURL.path), with its pasted region, piece layer, keyframe, mask, and box beside it")
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

extension RoomArtPhase {
    /// The item a measurement is running for, nil outside one.
    var itemBeingMeasured: RoomArtPlacedItem? {
        switch self {
        case .measuring(_, let item, _), .moving(_, let item, _): return item
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
        case .wallArt(let reading): return "a wall item \"\(reading.title)\""
        case .sizeNotOnThePage(let title): return "a wall item \"\(title)\" with no size"
        case .furniture(let reading): return "a standing item \"\(reading.title)\" on \(reading.standsOn.rawValue)\(reading.chosenSize == nil ? " with no size" : "")"
        case .clothing(let reading): return "a \(reading.garment.rawValue) \"\(reading.title)\" photographed \(reading.photoShows.rawValue)"
        case .cannotBeShown(let title, _): return "\"\(title)\""
        }
    }
}

// MARK: - Panel

@MainActor
final class RoomArtPanelController: RoomArtPanelPresenting {
    private weak var previewController: RoomArtPreviewController?
    private let metalLayer: CAMetalLayer
    private var panel: NonKeyFloatingPanel?
    private let motion = RoomArtPanelMotion()
    private var frameObservers: [NSObjectProtocol] = []

    init(previewController: RoomArtPreviewController, metalLayer: CAMetalLayer) {
        self.previewController = previewController
        self.metalLayer = metalLayer
    }

    /// Shows the panel where the learner last left it, or centered on the screen under the mouse the first time
    /// (`roomArtPanelFrameToShow`).
    func show() {
        guard let previewController else { return }
        let panel = panel ?? makePanel(previewController: previewController)
        self.panel = panel
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visibleFrameUnderTheMouse = screen?.visibleFrame {
            let savedFrame = UserDefaults.standard.string(forKey: roomArtPanelFrameDefaultsKey).map(NSRectFromString)
            panel.setFrame(roomArtPanelFrameToShow(
                savedFrame: savedFrame, visibleFrames: NSScreen.screens.map(\.visibleFrame), visibleFrameUnderTheMouse: visibleFrameUnderTheMouse
            ), display: false)
        }
        motion.open(panel)
    }

    func hide(onceHidden: @escaping @MainActor () -> Void) {
        guard let panel else { return onceHidden() }
        motion.close(panel, onceHidden: onceHidden)
    }

    private func makePanel(previewController: RoomArtPreviewController) -> NonKeyFloatingPanel {
        let panel = NonKeyFloatingPanel(
            contentRect: CGRect(origin: .zero, size: roomArtPanelDefaultSize),
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
        // The aspect ratio holds for any resize AppKit makes, and the grip keeps it itself (`roomArtPanelResizedFrame`).
        panel.contentAspectRatio = NSSize(width: 16, height: 9)
        panel.minSize = roomArtPanelSmallestSize
        let hostingView = FirstMouseHostingView(rootView: RoomArtPanelView(previewController: previewController, metalLayer: metalLayer))
        hostingView.frame = CGRect(origin: .zero, size: roomArtPanelDefaultSize)
        // The window's frame sets the content's size, never the other way round, so a resize is never undone by SwiftUI.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        // The Card's corner. The layer clips the video too, and the window's own shadow follows the shape.
        hostingView.layer?.cornerRadius = DS.CornerRadius.card
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        panel.contentView = hostingView
        // A drag or a resize keeps the panel's new frame, so the next panel opens there.
        for notificationName in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(forName: notificationName, object: panel, queue: .main) { [weak panel] _ in
                guard let panel, panel.isVisible else { return }
                UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: roomArtPanelFrameDefaultsKey)
            })
        }
        return panel
    }
}

/// The panel's moves. It fades in on the Glide move's time, or its Reduce Motion fade, and fades out over
/// `DS.Move.fadeSeconds`. The next panel uses the same window, so only the newest move may order it out, and a panel opened
/// again before it left fades back in from where it is.
@MainActor
final class RoomArtPanelMotion {
    typealias WindowFade = (_ window: NSWindow, _ alpha: CGFloat, _ seconds: Double, _ completion: @escaping @MainActor () -> Void) -> Void

    private let reduceMotionIsOn: () -> Bool
    private let fadeTheWindow: WindowFade
    /// Counts the opens and closes, so a fade that ends after a newer move changes nothing.
    private var moveNumber = 0

    /// A test passes its own fade and ends it by hand.
    init(
        reduceMotionIsOn: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        fadeTheWindow: @escaping WindowFade = RoomArtPanelMotion.fadeWithAppKit
    ) {
        self.reduceMotionIsOn = reduceMotionIsOn
        self.fadeTheWindow = fadeTheWindow
    }

    func open(_ window: NSWindow) {
        moveNumber += 1
        if !window.isVisible { window.alphaValue = 0 }
        window.orderFrontRegardless()
        window.ignoresMouseEvents = false
        // The closing window ignored the mouse, so a control hovered then never heard the pointer leave.
        if let contentView = window.contentView { refreshTheRowHovers(in: contentView, windowPassesTheMouseThrough: false) }
        let seconds = reduceMotionIsOn() ? DS.Move.glide.reduceMotionForm.fadeSeconds : DS.Move.glide.curve.seconds()
        fadeTheWindow(window, 1, seconds) {}
    }

    func close(_ window: NSWindow, onceHidden: @escaping @MainActor () -> Void = {}) {
        guard window.isVisible else { return onceHidden() }
        moveNumber += 1
        let thisMove = moveNumber
        // The panel fades for a moment, and a click on it then must not reach its buttons.
        window.ignoresMouseEvents = true
        fadeTheWindow(window, 0, DS.Move.fadeSeconds) { [weak self, weak window] in
            guard let self, thisMove == self.moveNumber else { return }
            window?.orderOut(nil)
            onceHidden()
        }
    }

    static func fadeWithAppKit(_ window: NSWindow, toAlpha alpha: CGFloat, overSeconds seconds: Double, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = seconds
            window.animator().alphaValue = alpha
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }
}

/// The panel's two window controls: the handle at its top that moves it, and the grip at its bottom right corner that
/// resizes it at 16:9. The panel never becomes key, so the handle moves it with `performDrag(with:)`, which works on a
/// window that is not key, and the grip sets the frame itself. The video under them keeps every other press and drag for
/// placing and moving the item.
private struct RoomArtPanelWindowControl: NSViewRepresentable {
    enum Kind { case moveHandle, resizeGrip }
    let kind: Kind

    func makeNSView(context: Context) -> RoomArtPanelWindowControlNSView {
        RoomArtPanelWindowControlNSView(kind: kind)
    }

    func updateNSView(_ nsView: RoomArtPanelWindowControlNSView, context: Context) {}
}

private final class RoomArtPanelWindowControlNSView: NSView {
    private let kind: RoomArtPanelWindowControl.Kind
    /// The panel's frame and the pointer's screen point when the grip was pressed, which each drag of the grip measures from.
    private var resizeStart: (frame: CGRect, pointer: CGPoint)?

    init(kind: RoomArtPanelWindowControl.Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("RoomArtPanelWindowControlNSView is made in code")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        switch kind {
        case .moveHandle: window.performDrag(with: event)
        case .resizeGrip: resizeStart = (window.frame, NSEvent.mouseLocation)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard kind == .resizeGrip, let resizeStart, let window, let visibleFrame = window.screen?.visibleFrame else { return }
        let pointer = NSEvent.mouseLocation
        window.setFrame(roomArtPanelResizedFrame(
            startFrame: resizeStart.frame,
            pointerMovedBy: CGSize(width: pointer.x - resizeStart.pointer.x, height: pointer.y - resizeStart.pointer.y),
            visibleFrame: visibleFrame
        ), display: true)
    }

    override func mouseUp(with event: NSEvent) {
        resizeStart = nil
    }
}

private struct RoomArtPanelView: View {
    @ObservedObject var previewController: RoomArtPreviewController
    let metalLayer: CAMetalLayer
    @State private var moveHandleIsHovered = false
    @State private var resizeGripIsHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The state the panel draws comes from here, never from the live properties a close clears, so a closing panel fades out
    /// whole.
    private var content: RoomArtPanelContent { previewController.panelContent }

    private var ghostOpacity: Double? {
        switch content.phase {
        case .placingTheFurniture: return 1
        // While the painting comes, the ghost stays at half opacity where the piece will appear.
        case .arranging: return 0.5
        default: return nil
        }
    }

    var body: some View {
        // The panel resizes, so the loop and the ghost map camera pixels onto the size it has now.
        GeometryReader { geometry in
            panelContent(panelSize: geometry.size)
        }
    }

    private func panelContent(panelSize: CGSize) -> some View {
        ZStack {
            RoomArtPanelSurface()
            RoomArtVideoView(
                metalLayer: metalLayer,
                showsTheCrosshair: content.phase.theItemIsPlacedByClicking,
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
            if !content.loopState.isHidden {
                RoomArtLoopView(
                    state: content.loopState,
                    color: previewController.loopAccentColor,
                    tracerLook: previewController.loopTracerLook,
                    outlineProvider: {
                        previewController.currentLoopOutline(cameraSize: metalLayer.drawableSize, panelSize: panelSize)
                    },
                    onFadeFinished: { previewController.theLoopFadeFinished() }
                )
            }
            if let ghostOpacity, let ghost = content.furnitureGhost, let ghostDraw = content.furnitureGhostDraw {
                RoomFurnitureGhostView(
                    draw: ghostDraw,
                    color: previewController.loopAccentColor,
                    tracerLook: previewController.loopTracerLook,
                    sizePillText: roomFurnitureGhostSizePillText(
                        widthMeters: ghost.widthMeters,
                        heightMeters: ghost.heightMeters,
                        widthIsMeasuredFromThePhoto: previewController.furnitureWidthIsMeasuredFromThePhoto
                    ),
                    linesProvider: {
                        previewController.currentGhostLines(cameraSize: metalLayer.drawableSize, panelSize: panelSize)
                    }
                )
                .opacity(ghostOpacity)
                .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: ghostOpacity)
                .transition(.opacity.animation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion)))
            }
            // The video's layer still holds the last session's frame until the camera's first one.
            if !content.theFirstFrameIsIn {
                RoomArtPanelSurface()
            }
            if case .failed = content.phase {
                Color.black.opacity(0.45).allowsHitTesting(false)
            }
            if let countdownNumber = content.shirtCaptureCountdownNumber {
                ShirtCountdownNumberView(number: countdownNumber, accentColor: previewController.loopAccentColor)
            }
            VStack {
                ZStack(alignment: .top) {
                    moveHandle
                    HStack {
                        Spacer()
                        closeButton
                    }
                }
                Spacer()
                bottomRow
                    // The buttons end left of the corner grip, so a click on a button's right end never starts a resize.
                    .padding(.trailing, roomArtPanelBottomRowTrailingInset - roomArtPanelContentInset)
            }
            .padding(roomArtPanelContentInset)
        }
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        // The video fills the panel, so the Card's edge is drawn over it.
        .overlay { TetherCardEdge() }
        .frame(width: panelSize.width, height: panelSize.height)
    }

    private var bottomRow: some View {
        RoomArtPanelBottomRow(
            statusText: roomArtPanelStatusText(
                phase: content.phase,
                waitingForTheLearnerToStepAside: content.waitingForTheLearnerToStepAside,
                theSurfaceIsLost: content.theSurfaceIsLost,
                shirtCoachingLine: content.shirtCoachingLine,
                thePaintedTopIsOutOfReach: content.thePaintedTopIsOutOfReach
            ),
            statusIsAFailure: content.phase.statusLineIsAFailure(theSurfaceIsLost: content.theSurfaceIsLost),
            showsSavePhoto: content.phase.photoTitleToSave != nil,
            showsPlace: content.phase.furnitureGhostShows,
            shirtButtonTitle: shirtButtonTitle,
            accentColor: previewController.loopAccentColor,
            onSavePhoto: { previewController.saveThePhoto() },
            onPlace: { previewController.placeTheFurnitureWhereItsGhostStands() },
            onShirtButton: {
                // A mouse click's own time (`shirtButtonPressTime`), and the time it is handled for a VoiceOver press.
                let currentEvent = NSApp.currentEvent
                previewController.pressTheShirtButton(atUptime: shirtButtonPressTime(
                    currentEventIsAMouseClick: currentEvent.map { event in [.leftMouseUp, .leftMouseDown].contains(event.type) } ?? false,
                    currentEventTimestamp: currentEvent?.timestamp,
                    now: ProcessInfo.processInfo.systemUptime
                ))
            }
        )
    }

    /// Paint it while the camera shows the learner, and Back to live while a painting is made or the painted still shows. Each
    /// does what its spoken phrase does ("paint it", "go back").
    private var shirtButtonTitle: String? {
        switch content.phase.shirtStillVoiceTargets {
        case .readyToPaint: "Paint it"
        case .stepBack, .paintedStill: "Back to live"
        case .none: nil
        }
    }

    /// The handle at the top that moves the panel, a pill on a dark backing so it reads over any room.
    private var moveHandle: some View {
        Capsule()
            .fill(DS.Colors.textPrimary.opacity(moveHandleIsHovered ? 0.85 : 0.45))
            .frame(width: moveHandleIsHovered ? 52 : 44, height: 5)
            .frame(width: 96, height: 22)
            .background(Capsule().fill(DS.Colors.background.opacity(moveHandleIsHovered ? 0.7 : 0.45)))
            .overlay(RoomArtPanelWindowControl(kind: .moveHandle))
            .hoverAndPointer { isHovered in moveHandleIsHovered = isHovered }
            .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: moveHandleIsHovered)
            .accessibilityLabel("Move the panel")
    }

    /// The grip in the bottom right corner that resizes the panel at the camera's shape.
    private var resizeGrip: some View {
        Canvas { context, size in
            for lineIndex in 0..<3 {
                let inset = CGFloat(lineIndex) * 4 + 3
                var line = Path()
                line.move(to: CGPoint(x: size.width - 2, y: inset))
                line.addLine(to: CGPoint(x: inset, y: size.height - 2))
                context.stroke(line, with: .color(DS.Colors.textPrimary.opacity(resizeGripIsHovered ? 0.9 : 0.5)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: roomArtPanelResizeGripSide - 8, height: roomArtPanelResizeGripSide - 8)
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(DS.Colors.background.opacity(resizeGripIsHovered ? 0.7 : 0)))
        .overlay(RoomArtPanelWindowControl(kind: .resizeGrip))
        .hoverAndPointer { isHovered in resizeGripIsHovered = isHovered }
        .padding(roomArtPanelResizeGripEdgeInset)
        .accessibilityLabel("Resize the panel")
    }

    private var closeButton: some View {
        RoomArtPanelButton(systemImageName: "xmark", accessibilityLabel: "Close") { previewController.close() }
    }
}

/// The panel's surface where no video shows: the Card's gradient.
private struct RoomArtPanelSurface: View {
    var body: some View {
        LinearGradient(colors: [DS.Colors.cardSurfaceTop, DS.Colors.cardSurfaceBottom], startPoint: .top, endPoint: .bottom)
    }
}

/// One look for every button on the panel: a solid capsule that dips on the Snap move as it is pressed, shows its hover,
/// and shows the pointing hand. With an accent it is filled with it and set in the ink that reads on that fill, with a ring
/// in that ink on hover, and without one it is a dark surface with an edge that lightens on hover. With no title it is a
/// circle around its icon.
struct RoomArtPanelButton: View {
    var title: String? = nil
    var systemImageName: String? = nil
    var accentColor: Color? = nil
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 32

    var body: some View {
        Button(action: action) {
            RoomArtPanelButtonLook(title: title, systemImageName: systemImageName, accentColor: accentColor, isHovered: isHovered)
                .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: isHovered)
        }
        .buttonStyle(PanelPressStyle())
        .fixedSize()
        .hoverAndPointer { isNowHovered in isHovered = isNowHovered }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// How a panel button looks, resting or hovered, apart from the hover tracking, so a test can draw it hovered.
struct RoomArtPanelButtonLook: View {
    let title: String?
    let systemImageName: String?
    let accentColor: Color?
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let systemImageName {
                Image(systemName: systemImageName)
            }
            if let title {
                Text(title)
            }
        }
        .font(DS.TypeScale.title.font)
        .foregroundStyle(accentColor?.inkOnThisFill ?? DS.Colors.textPrimary)
        .padding(.horizontal, title == nil ? 0 : 14)
        .frame(minWidth: RoomArtPanelButton.height, minHeight: RoomArtPanelButton.height)
        .background(RoomArtPanelButtonFill(accentColor: accentColor, isHovered: isHovered))
        .accentFillHoverRing(Capsule(), ink: accentColor?.inkOnThisFill ?? .clear, isShowing: accentColor != nil && isHovered)
        .overlay {
            if accentColor == nil {
                Capsule().strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0.1), lineWidth: 1)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
        .contentShape(Capsule())
    }
}

/// A panel button's solid capsule. An accent fill stays the same on hover, since its ink was chosen for the fill as it
/// rests, and the button's ring shows the hover instead. The dark surface changes to a lighter one on hover.
struct RoomArtPanelButtonFill: View {
    let accentColor: Color?
    let isHovered: Bool

    var body: some View {
        Capsule()
            .fill(accentColor ?? (isHovered ? DS.Colors.surface4 : DS.Colors.surface2))
    }
}

/// The panel's bottom row. The status line takes the room the buttons leave and wraps to a second line, so at any size the
/// buttons stay whole.
struct RoomArtPanelBottomRow: View {
    let statusText: String
    let statusIsAFailure: Bool
    /// Saves what the panel shows, as "save this photo" does (`RoomArtPreviewController.saveThePhoto`).
    let showsSavePhoto: Bool
    /// Places the piece where its ghost stands, as "right there" does.
    let showsPlace: Bool
    let shirtButtonTitle: String?
    /// The theme's accent, which fills Place and the shirt's button, so each reads at a glance over any room.
    let accentColor: Color
    /// A test passes nil to draw the line with no limit.
    var statusMostLines: Int? = RoomArtStatusPill.mostLines
    var onSavePhoto: () -> Void = {}
    var onPlace: () -> Void = {}
    var onShirtButton: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            if !statusText.isEmpty {
                RoomArtStatusPill(text: statusText, isAFailure: statusIsAFailure, mostLines: statusMostLines)
            }
            Spacer(minLength: 0)
            if showsSavePhoto {
                RoomArtPanelButton(title: "Save photo", systemImageName: "square.and.arrow.down", accessibilityLabel: "Save photo", action: onSavePhoto)
            }
            if showsPlace {
                RoomArtPanelButton(title: "Place", systemImageName: "checkmark", accentColor: accentColor, accessibilityLabel: "Place it here", action: onPlace)
            }
            if let shirtButtonTitle {
                RoomArtPanelButton(title: shirtButtonTitle, accentColor: accentColor, accessibilityLabel: shirtButtonTitle, action: onShirtButton)
            }
        }
    }
}

/// The panel's status line. The request to step aside shows only while the placed piece is arranged. A showing piece keeps
/// its own line, even while a ready render waits for the painting, since the flag can outlive the painting there: a new
/// request in the kept room can return early and leave it set. A new request while the piece is arranged opens the panel
/// again, which clears the flag. A lost room wins over the request, since no painting is made until the room is found, so
/// the learner has to turn back first.
nonisolated func roomArtPanelStatusText(
    phase: RoomArtPhase,
    waitingForTheLearnerToStepAside: Bool,
    theSurfaceIsLost: Bool,
    shirtCoachingLine: String?,
    thePaintedTopIsOutOfReach: Bool
) -> String {
    if case .arranging = phase, waitingForTheLearnerToStepAside, !theSurfaceIsLost { return roomFurnitureStepAsideLine }
    return phase.statusLine(theSurfaceIsLost: theSurfaceIsLost, shirtCoachingLine: shirtCoachingLine, thePaintedTopIsOutOfReach: thePaintedTopIsOutOfReach)
}

/// The panel's status line: its words on a solid pill of the Callout's surface, with no tail, starting at the pill's left
/// padding. It wraps to `mostLines`, and cuts the end of a longer line, never its start. It draws no icon, so anything drawn
/// over its first letters, such as the overlay's cursor, which sits above every window, comes from outside it.
struct RoomArtStatusPill: View {
    let text: String
    let isAFailure: Bool
    var mostLines: Int? = RoomArtStatusPill.mostLines

    static let mostLines = 2
    static let horizontalPadding: CGFloat = 14
    /// Half the height of a one line pill, so one line reads as a capsule and two keep round corners.
    private static let cornerRadius: CGFloat = 16

    private var pillShape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }

    var body: some View {
        Text(text)
            .font(DS.TypeScale.title.font)
            .foregroundStyle(isAFailure ? DS.Colors.destructiveText : DS.Colors.textPrimary)
            .lineLimit(mostLines)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, 8)
            .background(pillShape.fill(DS.Colors.calloutSurface))
            .overlay(pillShape.strokeBorder(DS.Colors.borderSubtle, lineWidth: 1))
            .allowsHitTesting(false)
    }
}

/// The 3-2-1 of the step-back capture, big in the middle of the video. Each number pops in from a larger size, or crossfades
/// at its own size with Reduce Motion on, and the panel never takes the mouse through it.
private struct ShirtCountdownNumberView: View {
    let number: Int
    let accentColor: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(verbatim: "\(number)")
            .font(DS.TypeScale.display.font)
            .foregroundStyle(accentColor)
            .shadow(color: .black.opacity(0.55), radius: 8)
            .id(number)
            // The animation rides on the transition, since a number is a new view each time and takes no animation from its parent.
            .transition(
                .scale(scale: shirtCountdownNumberStartScale(reduceMotionIsOn: reduceMotion)).combined(with: .opacity)
                    .animation(DS.Move.pop.animation(reduceMotionIsOn: reduceMotion))
            )
            .allowsHitTesting(false)
            .accessibilityLabel("\(number)")
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
