//
//  ShirtLivePaintedTopStillLearnerCheckTests.swift
//  leanring-buddyTests
//
//  A learner who stands still for the painting and then moves about must keep the live painted top, never flip between it
//  and the painted still. A webcam never gives two equal frames, so this check makes them from the standing photo: each frame
//  has its own sensor noise (about 7 levels a channel) and a slow sway and tilt of a few pixels, and from 2.5 seconds on the
//  learner sways sideways about 60 pixels each way with the motion blur a webcam's 1/30 s exposure gives that move. It runs
//  the real body pose request at the pose tracker's pace through the real smoother, freezes the painting's torso at 2
//  seconds, and steps the real follower on every frame up to 8 seconds. It runs only with SHIRT_TRYON_PHOTOS_DIR (a folder
//  with standing.jpg, a personal photo that is never committed):
//  SHIRT_TRYON_PHOTOS_DIR=/path/photos tools/swift-check.sh --filter ShirtLivePaintedTopStillLearnerCheck
//
//  It prints each pose run's hip and elbow confidences. With SHIRT_POSE_FIXTURE_OUT set, it writes the 16 pixel blur run's
//  pose results in the form of ShirtMotionBlurredPoseRecording.swift, which the ungated replay test reads.
//  Under 16 pixels of blur the elbows' confidence sits at 0.2 to 0.35, around Vision's 0.3 floor, and before the follower
//  held the arm verdict through frames that miss an elbow, the still flashed in 4 times. At 24 pixels the shoulders
//  themselves drop out for seconds, so the still shows then by design (nothing anchors the top), and that blur is left out.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
import Vision
@testable import Clicky

private let stillLearnerCheckEnvironment = ProcessInfo.processInfo.environment

@MainActor
struct ShirtLivePaintedTopStillLearnerCheckTests {
    @Test(.enabled(if: stillLearnerCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"] != nil, "Set SHIRT_TRYON_PHOTOS_DIR"), arguments: [0.0, 8.0, 16.0])
    func aLearnerWhoMovesAboutKeepsTheLiveTop(motionBlur: Double) async throws {
        let photosFolder = URL(fileURLWithPath: try #require(stillLearnerCheckEnvironment["SHIRT_TRYON_PHOTOS_DIR"]))
        let standingPhoto = try loadImage(at: photosFolder.appendingPathComponent("standing.jpg"))
        let report = await Task.detached { Self.stepALearner(standingPhoto: standingPhoto, motionBlur: motionBlur) }.value
        if let fixturePath = stillLearnerCheckEnvironment["SHIRT_POSE_FIXTURE_OUT"], motionBlur == 16 {
            try report.poseRuns.joined(separator: "\n").write(toFile: fixturePath, atomically: true, encoding: .utf8)
        }
        print(report.lines.map { "[blur \(motionBlur)] \($0)" }.joined(separator: "\n"))
        #expect(report.hasFollowed)
        #expect(report.problemsAfterFollowing.isEmpty, "The still came back for \(report.problemsAfterFollowing)")
    }

    struct Report: Sendable {
        var lines: [String] = []
        var poseRuns: [String] = []
        var hasFollowed = false
        var problemsAfterFollowing: [String] = []
    }

    nonisolated static func stepALearner(standingPhoto: CGImage, motionBlur: Double) -> Report {
        var report = Report()
        let context = CIContext()
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let photo = CIImage(cgImage: standingPhoto)
        let extent = photo.extent
        var generator = SeededGenerator(seed: 7)
        let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!

        func frame(at time: Double) -> CVPixelBuffer {
            // A body that sways and breathes, plus a pixel of jitter, and from 2.5 seconds a sideways sway with motion blur.
            let moving = time >= 2.5
            let swayX = (moving ? 60 : 3) * sin(time * 1.3) + Double.random(in: -1...1, using: &generator)
            let swayY = 1.5 * sin(time * 1.7 + 1) + Double.random(in: -1...1, using: &generator)
            let tilt = 0.6 * .pi / 180 * sin(time * 0.9)
            let breath = 1 + 0.004 * sin(time * 1.6)
            let shake = CGAffineTransform(translationX: -extent.midX, y: -extent.midY)
                .concatenating(CGAffineTransform(rotationAngle: tilt).scaledBy(x: breath, y: breath))
                .concatenating(CGAffineTransform(translationX: extent.midX + swayX, y: extent.midY + swayY))
            let gain = Double.random(in: 0.97...1.03, using: &generator)
            // Sensor noise: the random image's 0 to 1 moved to -0.05 to 0.05, added.
            let noiseOffset = CGAffineTransform(translationX: Double.random(in: 0...4000, using: &generator), y: Double.random(in: 0...4000, using: &generator))
            let signedNoise = noise.transformed(by: noiseOffset).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.1, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: -0.05, y: -0.05, z: -0.05, w: 0),
            ])
            let image = photo.clampedToExtent().transformed(by: shake)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
                ])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: signedNoise])
                .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: moving ? motionBlur : 0, kCIInputAngleKey: 0])
                .cropped(to: extent)
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(extent.width), Int(extent.height), kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
            context.render(image, to: buffer!, bounds: extent, colorSpace: sRGB)
            return buffer!
        }

        // The pose tracker's pace: a run starts at most every 50 ms, and its result reaches the frames after it.
        let frameSeconds = 1.0 / 30
        var smoother = ShirtTorsoSmoother()
        var latestResult: BodyTorso?
        var lastRunAt = -Double.infinity
        func torso(atFrame index: Int) -> BodyTorso? {
            let time = Double(index) * frameSeconds
            let torsoNow = smoother.advance(toward: latestResult, at: time)
            guard time - lastRunAt >= ShirtPoseTracker.minimumSecondsBetweenPoseRuns else { return torsoNow }
            lastRunAt = time
            let cameraFrame = frame(at: time)
            let request = VNDetectHumanBodyPoseRequest()
            try? VNImageRequestHandler(cvPixelBuffer: cameraFrame, orientation: .up).perform([request])
            let confidences = [VNHumanBodyPoseObservation.JointName.leftHip, .rightHip, .leftElbow, .rightElbow].map { name in
                (try? request.results?.first?.recognizedPoint(name)).map { String(format: "%.2f", $0.confidence) } ?? "-"
            }.joined(separator: "/")
            let result = ShirtPoseTracker.detectTorso(in: cameraFrame)
            report.lines.append(String(format: "run t=%.2f hip and elbow confidences %@, elbows seen %@%@", time, confidences,
                                       result?.imageLeftElbow == nil ? "-" : "L", result?.imageRightElbow == nil ? "-" : "R"))
            func formatted(_ point: CGPoint?) -> String { point.map { String(format: "%.1f %.1f", $0.x, $0.y) } ?? "- -" }
            report.poseRuns.append(result.map { torso in
                [String(format: "%.3f", time), formatted(torso.imageLeftShoulder), formatted(torso.imageRightShoulder), formatted(torso.imageLeftHip), formatted(torso.imageRightHip),
                 torso.hipsWereEstimated ? "1" : "0", torso.shouldersAreSeen ? "1" : "0",
                 formatted(torso.imageLeftElbow), formatted(torso.imageRightElbow), formatted(torso.imageLeftWrist), formatted(torso.imageRightWrist)].joined(separator: " ")
            } ?? String(format: "%.3f none", time))
            latestResult = result
            return torsoNow
        }

        let torsos = (0..<240).map { torso(atFrame: $0) }
        guard let frozenTorso = torsos[60] else { report.lines.append("No torso to freeze"); return report }
        let clear = CIImage(color: .clear).cropped(to: extent)
        var follower = ShirtLivePaintedTopFollower(top: ShirtLivePaintedTop(layer: clear, still: clear, paintedArea: clear, frozenTorso: frozenTorso, followsTheForearms: false))
        for frameIndex in 61..<240 {
            _ = follower.advance(currentTorso: torsos[frameIndex], at: Double(frameIndex) * frameSeconds)
            if follower.reach == .follows {
                report.hasFollowed = true
            } else if report.hasFollowed, report.problemsAfterFollowing.last != String(describing: follower.reach) {
                report.problemsAfterFollowing.append(String(describing: follower.reach))
                report.lines.append(String(format: "reach t=%.2f %@", Double(frameIndex) * frameSeconds, String(describing: follower.reach)))
            }
        }
        return report
    }
}

/// SplitMix64, so each run makes the same frames.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
