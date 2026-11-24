//
//  ShirtStepBackProcessorCheckTests.swift
//  leanring-buddyTests
//
//  Runs the real frame processor (real body pose, real person segmentation, real debouncer, the wall clock) on a made-up camera
//  of a person who starts too close to the camera and steps back, and checks the step-back capture end to end. It runs only
//  when SHIRT_TRYON_PHOTOS_DIR names a folder that holds standing.jpg (a person standing in a camera frame, a personal photo that
//  is never committed):
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos tools/swift-check.sh --filter ShirtStepBackProcessorCheck
//  The camera is the photo scaled about the shoulders: first too close for the framing, then eased back to the photo's own
//  framing over 2 seconds, then held still. The processor takes its time from the clock, so this check runs in real time, about
//  15 seconds (about 25 for the time out check, which waits out the 18 second limit), which is why the capture's own
//  rules are tested by hand in ShirtStepBackTests.
//  It also checks the painted top following the learner on the same processor: the follow starts after the still, its
//  out of reach hint comes and goes as the learner steps too close and back, and a top handed over after go back is dropped.
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
        // The countdown never starts over: the numbers shown, with the blanks between holds left out, are 3, 2, 1 once.
        let numbersShown = capture.numbers.compactMap { $0 }
        #expect(numbersShown == [3, 2, 1], "numbers \(capture.numbers)")
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
    func theFrameFreezesAsFilmedAndTheMaskReachesTheCoatsHem() async throws {
        let coverage = ShirtCoverage(sleeves: .long, length: .knee)
        let setup = try makeTheSetup()
        let capture = CaptureLog()
        setup.frameProcessor.armTheShirtCapture { capture.record($0) }
        let stillFrame = try setup.frame(zoom: 1)
        let source = DispatchSource.makeTimerSource(queue: setup.frameProcessor.processingQueue)
        source.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
        source.setEventHandler { setup.frameProcessor.process(stillFrame) }
        source.resume()
        defer { source.cancel() }

        try await untilTheCaptureEnds(capture, within: 15)
        let frozen = try #require(capture.frozen, "the capture never froze: \(capture.entries.map { "\($0.seconds) \($0.event)" })")
        // Nothing is drawn on the learner before the painting, so the mask takes the garment's area from the coverage alone.
        let masks = try #require(ShirtPaintMask.make(frame: frozen.frame, bodyParts: shirtPaintBodyParts(in: frozen.frame.cameraImage), coverage: coverage))
        print("Shirt freeze check: the mask covers \(String(format: "%.1f", masks.paintableShare * 100))% of the frame")
        // The loop traces the learner's own top as the frame freezes.
        #expect(setup.frameProcessor.currentLoop()?.closedOutline != nil, "the loop traced no outline")

        // The coat reaches the knee, so the mask reaches down to the frame's bottom row here.
        let torso = frozen.frame.torso
        let frameHeight = Double(frozen.frame.height)
        let torsoLength = hypot(torso.hipMidpoint.x - torso.shoulderMidpoint.x, torso.hipMidpoint.y - torso.shoulderMidpoint.y)
        let kneeRow = torso.shoulderMidpoint.y + ShirtCoverage.hemInTorsoLengths(for: .knee) * torsoLength
        let lowestMaskRow = masks.paintable.indices.last(where: { masks.paintable[$0] > 127 }).map { Double($0 / masks.width) } ?? 0
        print("Shirt freeze check: the mask's lowest row is \(Int(lowestMaskRow)) of \(Int(frameHeight)), the knee hem at \(Int(kneeRow))")
        #expect(lowestMaskRow >= min(kneeRow, frameHeight) * 0.93)
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

    @Test(.enabled(if: processorCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR"))
    func thePaintedTopFollowsTheLearnerAndSaysSoWhenTheyStepOutOfReachAndALateTopAfterGoBackDoesNothing() async throws {
        let coverage = ShirtCoverage(sleeves: .short, length: .hip)
        let setup = try makeTheSetup()
        let capture = CaptureLog()
        setup.frameProcessor.armTheShirtCapture { capture.record($0) }
        let stillFrame = try setup.frame(zoom: 1)
        let tooCloseFrame = try setup.frame(zoom: setup.closeZoom)
        // The source reads which frame to send from here, so the test moves the learner by changing it.
        let learnerIsTooClose = OSAllocatedUnfairLock(initialState: false)
        let source = DispatchSource.makeTimerSource(queue: setup.frameProcessor.processingQueue)
        source.schedule(deadline: .now(), repeating: 1 / framesPerSecond)
        source.setEventHandler { setup.frameProcessor.process(learnerIsTooClose.withLock { $0 } ? tooCloseFrame : stillFrame) }
        source.resume()
        defer { source.cancel() }

        try await untilTheCaptureEnds(capture, within: 15)
        let frozen = try #require(capture.frozen, "the capture never froze: \(capture.entries.map { "\($0.seconds) \($0.event)" })")
        // The frozen camera frame stands in for the painting: only the processor's follow is under test here.
        let masks = try #require(ShirtPaintMask.make(frame: frozen.frame, bodyParts: shirtPaintBodyParts(in: frozen.frame.cameraImage), coverage: coverage))
        let paintedTop = try #require(ShirtLivePaintedTop.make(painted: frozen.frame.cameraImage, masks: masks, frozenTorso: frozen.frame.torso, coverage: coverage))
        let hints = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        setup.frameProcessor.showThePaintedStill(frozen.frame.cameraImage)
        setup.frameProcessor.followTheLearnerWithThePaintedTop(paintedTop) { hintIsShowing in hints.withLock { $0.append(hintIsShowing) } }

        // Standing as in the painting, the top follows and no hint shows. Too close (the shoulders past the painting's reach or
        // out of the frame), the still shows and the hint comes, and back where they stood it goes.
        try await Task.sleep(for: .seconds(2))
        #expect(hints.withLock { $0 }.isEmpty, "hints \(hints.withLock { $0 })")
        learnerIsTooClose.withLock { $0 = true }
        try await until(within: 5, "the out of reach hint never came") { hints.withLock { $0 } == [true] }
        learnerIsTooClose.withLock { $0 = false }
        try await until(within: 5, "the hint never went") { hints.withLock { $0 } == [true, false] }

        // Go back clears the frozen frame, so a top handed over late is dropped and no hint comes for it.
        setup.frameProcessor.resumeTheLiveShirt()
        let lateHints = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        setup.frameProcessor.followTheLearnerWithThePaintedTop(paintedTop) { hintIsShowing in lateHints.withLock { $0.append(hintIsShowing) } }
        learnerIsTooClose.withLock { $0 = true }
        try await Task.sleep(for: .seconds(2))
        #expect(lateHints.withLock { $0 }.isEmpty, "late hints \(lateHints.withLock { $0 })")
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

        let frameProcessor = RoomArtFrameProcessor()
        frameProcessor.startASession(onFirstSegmentedFrame: {}, onTheSurfaceLostOrFound: { _ in })
        frameProcessor.startTheShirtTryOn(onTheFramingSettled: { _ in })
        return Setup(frameProcessor: frameProcessor, standingPhoto: cropped, context: context, closeZoom: closeZoom, shoulderMidpoint: torso.shoulderMidpoint)
    }

    private struct SetupFailure: Error {}

    private func until(within seconds: Double, _ failure: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            try #require(Date() < deadline, "\(failure) in \(seconds) s")
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func untilTheCaptureEnds(_ capture: CaptureLog, within seconds: Double) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while capture.frozen == nil && capture.timedOutAt == nil {
            try #require(Date() < deadline, "the capture neither froze nor timed out in \(seconds) s")
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
