//
//  RoomCamera.swift
//  leanring-buddy
//
//  The frames the room art panel shows: the built-in camera at 1280 by 720, or, in Debug builds launched with
//  `--room-camera-file <path>`, a video file looped at its own frame rate, so verification can drive the panel with no
//  camera. Both deliver full-range 420 frames (the luma plane is the grayscale the tracker reads) on the queue they are given.
//  The built-in camera holds its first frames back while auto exposure and white balance settle (`RoomCameraWarmUp`), since
//  the first frame with a person mask becomes the room keyframe and the wall's light is read from it.
//

@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

nonisolated enum RoomCameraError: Error, Equatable {
    case cameraAccessDenied
    case noCamera
    case couldNotStart(String)
}

/// A source of camera frames. `start` returns once frames are on their way, and each frame arrives on `deliveryQueue`.
nonisolated protocol RoomFrameSource: AnyObject, Sendable {
    func start(deliveringFramesOn deliveryQueue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws
    func stop()
}

/// The pixel format both sources deliver: full-range 420, whose first plane is the frame's grayscale.
nonisolated let roomCameraPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

// MARK: - Waiting for exposure and white balance

/// Decides when the built-in camera starts handing frames on. A MacBook camera often starts dark or tinted and takes 0.3 to
/// 1 second to settle, and the room art's early keyframe (taken from the first frame with a person mask during the page
/// read) fixes the wall's light and the tracker's reference for the whole session. So frames are held back until the
/// device reports that it is no longer adjusting exposure or white balance, or until `longestWaitSeconds` have passed since
/// the first frame, whichever comes first. A device that never settles (a dim room) must not stall the panel.
/// The settled flags count only after `shortestWaitSeconds`, since a session that just started can report both flags false
/// before auto exposure has begun, and its dark first frame would then pass at once.
/// Pure, with the clock and the device's two flags passed in, so a test steps it by hand.
nonisolated struct RoomCameraWarmUp: Equatable, Sendable {
    static let shortestWaitSeconds = 0.35
    static let longestWaitSeconds = 0.75

    /// When the first frame arrived, nil before it.
    private var firstFrameAt: TimeInterval?
    private var hasStartedDelivering = false

    /// Whether this frame should go on to the panel. Once frames are delivered, every later frame is too.
    mutating func shouldDeliverAFrame(now: TimeInterval, isAdjustingExposure: Bool, isAdjustingWhiteBalance: Bool) -> Bool {
        if hasStartedDelivering { return true }
        let firstFrameAt = firstFrameAt ?? now
        self.firstFrameAt = firstFrameAt
        let secondsSinceTheFirstFrame = now - firstFrameAt
        let deviceHasSettled = !isAdjustingExposure && !isAdjustingWhiteBalance && secondsSinceTheFirstFrame >= Self.shortestWaitSeconds
        let waitedLongEnough = secondsSinceTheFirstFrame >= Self.longestWaitSeconds
        guard deviceHasSettled || waitedLongEnough else { return false }
        hasStartedDelivering = true
        return true
    }
}

// MARK: - The built-in camera

nonisolated final class BuiltInRoomCamera: NSObject, RoomFrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let captureSession = AVCaptureSession()
    /// Set before the session starts and read on the delivery queue only.
    private var onFrame: (@Sendable (CVPixelBuffer) -> Void)?
    /// Set before the session starts. Its exposure and white balance flags are readable from any thread.
    private var cameraDevice: AVCaptureDevice?
    /// Read and changed on the delivery queue only.
    private var warmUp = RoomCameraWarmUp()

    func start(deliveringFramesOn deliveryQueue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw RoomCameraError.cameraAccessDenied }
        default:
            throw RoomCameraError.cameraAccessDenied
        }
        guard let camera = AVCaptureDevice.default(for: .video) else { throw RoomCameraError.noCamera }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        do {
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(cameraInput) else { throw RoomCameraError.couldNotStart("the camera input was refused") }
            captureSession.addInput(cameraInput)
        } catch let cameraError as RoomCameraError {
            captureSession.commitConfiguration()
            throw cameraError
        } catch {
            captureSession.commitConfiguration()
            throw RoomCameraError.couldNotStart(error.localizedDescription)
        }
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: roomCameraPixelFormat]
        // A frame that arrives while the last one is still being drawn is dropped, so the panel shows the newest frame.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        self.onFrame = onFrame
        cameraDevice = camera
        videoOutput.setSampleBufferDelegate(self, queue: deliveryQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            throw RoomCameraError.couldNotStart("the video output was refused")
        }
        captureSession.addOutput(videoOutput)
        captureSession.commitConfiguration()
        // startRunning blocks until the camera is on, so it runs off the caller's thread.
        let captureSession = captureSession
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                captureSession.startRunning()
                continuation.resume()
            }
        }
        guard captureSession.isRunning else { throw RoomCameraError.couldNotStart("the camera did not start") }
    }

    func stop() {
        let captureSession = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            captureSession.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // Frames from a camera still settling its exposure and white balance are dropped for up to 0.75 seconds, so the
        // panel's first frame, which becomes the room keyframe, is a well exposed one.
        let frameShouldGoOnToThePanel = warmUp.shouldDeliverAFrame(
            now: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            isAdjustingExposure: cameraDevice?.isAdjustingExposure ?? false,
            isAdjustingWhiteBalance: cameraDevice?.isAdjustingWhiteBalance ?? false
        )
        guard frameShouldGoOnToThePanel else { return }
        onFrame?(pixelBuffer)
    }
}

// MARK: - A video file, for verification

#if DEBUG
/// Loops a video file at its own frame rate in place of the camera. Debug builds only.
nonisolated final class LoopingVideoFileRoomCamera: RoomFrameSource, @unchecked Sendable {
    private let videoFileURL: URL
    /// Read and changed on the delivery queue only.
    private var assetReader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    private var frameTimer: DispatchSourceTimer?

    init(videoFileURL: URL) {
        self.videoFileURL = videoFileURL
    }

    func start(deliveringFramesOn deliveryQueue: DispatchQueue, onFrame: @escaping @Sendable (CVPixelBuffer) -> Void) async throws {
        let videoAsset = AVURLAsset(url: videoFileURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw RoomCameraError.couldNotStart("\(videoFileURL.lastPathComponent) has no video track")
        }
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let framesPerSecond = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        try deliveryQueue.sync { try self.openTheReader(videoAsset: videoAsset, videoTrack: videoTrack) }

        // Each tick reads and delivers one frame on the delivery queue, so reading never runs ahead of drawing.
        let frameTimer = DispatchSource.makeTimerSource(queue: deliveryQueue)
        frameTimer.schedule(deadline: .now(), repeating: 1 / framesPerSecond, leeway: .milliseconds(2))
        frameTimer.setEventHandler { [weak self] in
            guard let self, let pixelBuffer = self.nextFrame(videoAsset: videoAsset, videoTrack: videoTrack) else { return }
            onFrame(pixelBuffer)
        }
        deliveryQueue.sync { self.frameTimer = frameTimer }
        frameTimer.resume()
    }

    func stop() {
        frameTimer?.cancel()
    }

    private func openTheReader(videoAsset: AVURLAsset, videoTrack: AVAssetTrack) throws {
        let assetReader = try AVAssetReader(asset: videoAsset)
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: roomCameraPixelFormat])
        trackOutput.alwaysCopiesSampleData = false
        guard assetReader.canAdd(trackOutput) else { throw RoomCameraError.couldNotStart("the video's frames cannot be read") }
        assetReader.add(trackOutput)
        guard assetReader.startReading() else { throw RoomCameraError.couldNotStart(assetReader.error?.localizedDescription ?? "the video did not start") }
        self.assetReader = assetReader
        self.trackOutput = trackOutput
    }

    /// The next frame, starting the file over at its end.
    private func nextFrame(videoAsset: AVURLAsset, videoTrack: AVAssetTrack) -> CVPixelBuffer? {
        if let sampleBuffer = trackOutput?.copyNextSampleBuffer(), let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            return pixelBuffer
        }
        assetReader?.cancelReading()
        do {
            try openTheReader(videoAsset: videoAsset, videoTrack: videoTrack)
        } catch {
            print("Room art: could not loop \(videoFileURL.lastPathComponent): \(error)")
            frameTimer?.cancel()
            return nil
        }
        guard let sampleBuffer = trackOutput?.copyNextSampleBuffer() else { return nil }
        return CMSampleBufferGetImageBuffer(sampleBuffer)
    }
}
#endif

/// The video file a Debug build was launched to use in place of the camera (`--room-camera-file <path>`), or nil.
nonisolated func roomCameraFilePath(launchArguments: [String]) -> String? {
    guard let flagIndex = launchArguments.firstIndex(of: "--room-camera-file"), launchArguments.indices.contains(flagIndex + 1) else { return nil }
    return launchArguments[flagIndex + 1]
}

/// The camera, or in a Debug build launched with `--room-camera-file <path>`, that file looped. A Release build ignores the flag.
nonisolated func makeRoomFrameSource(launchArguments: [String] = CommandLine.arguments) -> RoomFrameSource {
    #if DEBUG
    if let videoFilePath = roomCameraFilePath(launchArguments: launchArguments) {
        print("Room art: using \(videoFilePath) in place of the camera")
        return LoopingVideoFileRoomCamera(videoFileURL: URL(fileURLWithPath: videoFilePath))
    }
    #endif
    return BuiltInRoomCamera()
}
