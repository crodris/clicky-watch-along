//
//  ShirtStepBackProcessorCheckTests.swift
//  leanring-buddyTests
//
//  Runs the real frame processor (real body pose, real person segmentation, real debouncer, the wall clock) on a made-up camera
//  of a person who starts too close to the camera and steps back, and checks the step-back capture end to end. It runs only
//  when SHIRT_TRYON_PHOTOS_DIR names a folder that holds standing.jpg (a person standing in a camera frame, a personal photo that
//  is never committed) and one or more uE*.jpg flat lay product photos, the folder ShirtTryOnPhotoCheckTests reads:
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos tools/swift-check.sh --filter ShirtStepBackProcessorCheck
//  The camera is the photo scaled about the shoulders: first too close for the framing, then eased back to the photo's own
//  framing over 2 seconds, then held still. The processor takes its time from the clock, so this check runs in real time, about
//  15 seconds (about 25 for the time out check, which waits out the 18 second limit), which is why the capture's own
//  rules are tested by hand in ShirtStepBackTests.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import os
import Testing
@testable import Clicky

private let processorCheckEnvironment = ProcessInfo.processInfo.environment

/// What the armed capture reported, with the seconds since it was armed.
private final class CaptureLog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[(seconds: Double, event: ShirtCaptureEvent)]>(initialState: [])
    private let armedAt = Date()

    func record(_ event: ShirtCaptureEvent) {
        let seconds = Date().timeIntervalSince(armedAt)
        lock.withLock { $0.append((seconds, event)) }
    }

    var entries: [(seconds: Double, event: ShirtCaptureEvent)] { lock.withLock { $0 } }

    var numbers: [Int?] {
        entries.compactMap { if case .countdown(let number) = $0.event { return number } else { return nil } }
    }

    var frozen: (seconds: Double, frame: ShirtFrozenFrame)? {
        for entry in entries { if case .frozen(let frame) = entry.event { return (entry.seconds, frame) } }
        return nil
    }

    var timedOutAt: Double? {
        for entry in entries { if case .timedOut = entry.event { return entry.seconds } }
        return nil
    }
}

private func pixelBuffer(of image: CIImage, context: CIContext) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
    let created = try #require(buffer)
    context.render(image, to: created, bounds: image.extent, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    return created
}

struct ShirtStepBackProcessorCheckTests {
    private let framesPerSecond = 30.0
    private let secondsStepping = 2.0

    @Test(.enabled(if: processorCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR"))
    func aLearnerWhoStepsBackAndHoldsStillIsFrozenOnTheTorsoOfThatFrameAfterTheCountdown() async throws {
        let setup = try makeTheSetup()
        let capture = CaptureLog()
        setup.frameProcessor.armTheShirtCapture { capture.record($0) }

        // Too close for 2 seconds, eased back over the next 2, then still.
        let secondsTooClose = 2.0
        let cameraFrames = try (0..<Int((secondsTooClose + secondsStepping) * framesPerSecond)).map { frameNumber in
            let secondsIn = Double(frameNumber) / framesPerSecond
            let progress = min(1, max(0, (secondsIn - secondsTooClose) / secondsStepping))
            let eased = progress * progress * (3 - 2 * progress)
            return try setup.frame(zoom: setup.closeZoom + (1 - setup.closeZoom) * eased)
        }
        let stillFrame = try setup.frame(zoom: 1)
        let sourceStartedAt = Date()
        let source = DispatchSource.makeTimerSource(queue: setup.frameProcessor.processingQueue)
        source.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
        source.setEventHandler {
            let frameNumber = Int(Date().timeIntervalSince(sourceStartedAt) * framesPerSecond)
            setup.frameProcessor.process(frameNumber < cameraFrames.count ? cameraFrames[frameNumber] : stillFrame)
        }
        source.resume()
        defer { source.cancel() }

        // The hold is 1.5 s after the framing settles (0.5 s) in the held frames, which start at 4 s.
        try await untilTheCaptureEnds(capture, within: 15)
        let frozen = try #require(capture.frozen, "the capture never froze: \(capture.entries.map { "\($0.seconds) \($0.event)" })")
        print("Shirt step back check: froze \(String(format: "%.2f", frozen.seconds)) s after arming, numbers \(capture.numbers)")

        // It never froze while the learner was too close or still moving back, and the countdown ran 3, 2, 1 before the freeze.
        #expect(frozen.seconds > secondsTooClose + secondsStepping)
        let numbersShown = capture.numbers.compactMap { $0 }
        #expect(Array(numbersShown.suffix(3)) == [3, 2, 1], "numbers \(capture.numbers)")
        // The frozen frame is the held one, and its torso is the one found for it.
        let torsoFoundForTheFrozenFrame = try #require(ShirtPoseTracker.detectTorso(in: pixelBuffer(of: CIImage(cgImage: frozen.frame.cameraImage), context: setup.context)))
        let shoulderWidth = frozen.frame.torso.shoulderWidth
        let shift = hypot(
            frozen.frame.torso.shoulderMidpoint.x - torsoFoundForTheFrozenFrame.shoulderMidpoint.x,
            frozen.frame.torso.shoulderMidpoint.y - torsoFoundForTheFrozenFrame.shoulderMidpoint.y
        )
        print("Shirt step back check: the frozen torso is \(String(format: "%.3f", shift / shoulderWidth)) shoulder widths from the torso found in the frozen image")
        #expect(shift < 0.05 * shoulderWidth)
        #expect(abs(shoulderWidth - torsoFoundForTheFrozenFrame.shoulderWidth) < 0.05 * shoulderWidth)
        setup.frameProcessor.endTheSession()
    }

    @Test(.enabled(if: processorCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR"))
    func aLearnerWhoStaysTooCloseGetsTheTimeOutAndNothingFreezes() async throws {
        let setup = try makeTheSetup()
        let capture = CaptureLog()
        setup.frameProcessor.armTheShirtCapture { capture.record($0) }
        let closeFrame = try setup.frame(zoom: setup.closeZoom)
        let source = DispatchSource.makeTimerSource(queue: setup.frameProcessor.processingQueue)
        source.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
        source.setEventHandler { setup.frameProcessor.process(closeFrame) }
        source.resume()
        defer { source.cancel() }

        try await untilTheCaptureEnds(capture, within: 30)
        print("Shirt step back check: timed out \(String(describing: capture.timedOutAt)) s after arming")
        let timedOutAt = try #require(capture.timedOutAt, "no time out: \(capture.entries.map { "\($0.seconds) \($0.event)" })")
        #expect(timedOutAt >= ShirtStepBackCapture.secondsBeforeGivingUp && timedOutAt < ShirtStepBackCapture.secondsBeforeGivingUp + 1.5)
        #expect(capture.frozen == nil)
        setup.frameProcessor.endTheSession()
    }

    // MARK: Setup

    private struct Setup {
        let frameProcessor: RoomArtFrameProcessor
        let standingPhoto: CGImage
        let context: CIContext
        /// The zoom that leaves the shoulders over 70 percent of the frame width, too close for the framing.
        let closeZoom: Double
        let shoulderMidpoint: CGPoint

        /// The photo scaled about the shoulders, so the person stays in the frame as they come closer.
        func frame(zoom: Double) throws -> CVPixelBuffer {
            let photo = CIImage(cgImage: standingPhoto)
            let extent = photo.extent
            // CIImage's origin is the bottom left, and the torso's points are y down.
            let pivot = CGPoint(x: shoulderMidpoint.x, y: extent.height - shoulderMidpoint.y)
            let zoomed = photo
                .transformed(by: CGAffineTransform(translationX: -pivot.x, y: -pivot.y))
                .transformed(by: CGAffineTransform(scaleX: zoom, y: zoom))
                .transformed(by: CGAffineTransform(translationX: pivot.x, y: pivot.y))
                .cropped(to: extent)
            return try pixelBuffer(of: zoomed, context: context)
        }
    }

    private func makeTheSetup() throws -> Setup {
        let photosFolder = URL(fileURLWithPath: try #require(processorCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let context = CIContext()
        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        // The top 1280 by 720 of the photo, which keeps the head and the chest, as the panel's own frame size.
        let cropped = try #require(standingPhoto.cropping(to: CGRect(x: 80, y: 0, width: 1280, height: 720)))
        let frameBuffer = try pixelBuffer(of: CIImage(cgImage: cropped), context: context)
        let torso = try #require(ShirtPoseTracker.detectTorso(in: frameBuffer))
        let frameSize = CGSize(width: cropped.width, height: cropped.height)
        let ownFraming = ShirtFraming.assess(torso: torso, frameSize: frameSize)
        guard case .ready = ownFraming else {
            Issue.record("The photo's own framing is not ready: \(ownFraming)")
            throw SetupFailure()
        }
        let closeZoom = max(1.5, 0.7 * frameSize.width / torso.shoulderWidth)

        let flatLayName = try #require(try FileManager.default.contentsOfDirectory(atPath: photosFolder.path).filter { $0.hasPrefix("uE") && $0.hasSuffix(".jpg") }.sorted().first)
        let productPhoto = try loadImage(at: photosFolder.appendingPathComponent(flatLayName))
        let garment = try #require(ShirtGarment.make(productPhoto: productPhoto, itemCorners: RoomArtCorners(
            topLeft: .zero, topRight: CGPoint(x: productPhoto.width, y: 0), bottomRight: CGPoint(x: productPhoto.width, y: productPhoto.height), bottomLeft: CGPoint(x: 0, y: productPhoto.height))))

        let frameProcessor = RoomArtFrameProcessor()
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        frameProcessor.startTheShirtTryOn(onTheFramingSettled: { _ in })
        frameProcessor.wearTheGarment(garment)
        return Setup(frameProcessor: frameProcessor, standingPhoto: cropped, context: context, closeZoom: closeZoom, shoulderMidpoint: torso.shoulderMidpoint)
    }

    private struct SetupFailure: Error {}

    private func untilTheCaptureEnds(_ capture: CaptureLog, within seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while capture.frozen == nil && capture.timedOutAt == nil {
            try #require(Date() < deadline, "the capture neither froze nor timed out in \(seconds) s")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
