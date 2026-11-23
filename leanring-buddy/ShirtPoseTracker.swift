//
//  ShirtPoseTracker.swift
//  leanring-buddy
//
//  Finds the learner's torso in the camera frames for the shirt try-on. Vision's body pose request takes several
//  milliseconds, more than a frame can spare next to drawing, so it runs on its own queue at most every 50 ms, and each frame
//  gets the newest result smoothed toward the body, which keeps the overlay from jittering between runs.
//

import CoreMedia
import CoreVideo
import Foundation
import os
import Vision

/// Moves a torso toward the newest pose result a little each frame, so the shirt follows the body without the jitter of
/// each run's small errors. Pure, so a test steps it by hand.
nonisolated struct ShirtTorsoSmoother: Equatable, Sendable {
    /// How fast the shirt follows the body: each step covers `1 - e^(-dt / this)` of the distance left. 60 ms trails a
    /// walking person by about a frame and a half and still takes the edge off each run's noise.
    static let timeConstantSeconds = 0.06
    /// With no pose result for this long, the learner has left, and the torso is dropped. A single run that misses the body,
    /// such as one blurred by a fast turn, never flickers the overlay off.
    static let secondsBeforeTheTorsoIsLost = 0.4
    /// A result farther than this many shoulder widths from the smoothed torso is a new person or a jump, and the torso
    /// snaps to it instead of sliding there.
    static let snapDistanceInShoulderWidths = 0.6

    private(set) var smoothedTorso: BodyTorso?
    private var lastAdvanceTime: TimeInterval?
    private var lastResultTime: TimeInterval?
    /// When each elbow or wrist was last in a result. Vision's elbow confidence flickers around its floor from run to run, and a
    /// sleeve that came and went with it would jump between lying along the arm and not, so an elbow missing from a result
    /// keeps its last place for as long as a missing torso does. A wrist, which a long sleeve's area follows, is held the same
    /// way.
    private var imageLeftElbowSeenAt: TimeInterval?
    private var imageRightElbowSeenAt: TimeInterval?
    private var imageLeftWristSeenAt: TimeInterval?
    private var imageRightWristSeenAt: TimeInterval?

    /// The smoothed torso after moving toward `latestResult`, the newest pose result (nil when the last run found nobody).
    mutating func advance(toward latestResult: BodyTorso?, at time: TimeInterval) -> BodyTorso? {
        defer { lastAdvanceTime = time }
        guard let latestResult else {
            if let lastResultTime, time - lastResultTime > Self.secondsBeforeTheTorsoIsLost { smoothedTorso = nil }
            return smoothedTorso
        }
        lastResultTime = time
        if latestResult.imageLeftElbow != nil { imageLeftElbowSeenAt = time }
        if latestResult.imageRightElbow != nil { imageRightElbowSeenAt = time }
        if latestResult.imageLeftWrist != nil { imageLeftWristSeenAt = time }
        if latestResult.imageRightWrist != nil { imageRightWristSeenAt = time }
        guard let current = smoothedTorso, let lastAdvanceTime else {
            smoothedTorso = latestResult
            return latestResult
        }
        let jump = hypot(latestResult.shoulderMidpoint.x - current.shoulderMidpoint.x, latestResult.shoulderMidpoint.y - current.shoulderMidpoint.y)
        if jump > Self.snapDistanceInShoulderWidths * max(current.shoulderWidth, 1) {
            smoothedTorso = latestResult
            return latestResult
        }
        let share = 1 - exp(-max(0, min(time - lastAdvanceTime, 0.2)) / Self.timeConstantSeconds)
        func moved(_ from: CGPoint, _ to: CGPoint) -> CGPoint { CGPoint(x: from.x + (to.x - from.x) * share, y: from.y + (to.y - from.y) * share) }
        let imageLeftShoulder = moved(current.imageLeftShoulder, latestResult.imageLeftShoulder)
        let imageRightShoulder = moved(current.imageRightShoulder, latestResult.imageRightShoulder)
        // An elbow or wrist in the result moves toward it, or appears there. One missing from it holds while it was seen
        // recently, and moves with its own shoulder: motion blur is what drops it, so the body is moving, and an elbow left at
        // its old pixel while the shoulder moved on read as an arm turned past the painted top's limit.
        func smoothedJoint(current currentJoint: CGPoint?, latest latestJoint: CGPoint?, seenAt: TimeInterval?, shoulderMovedFrom oldShoulder: CGPoint, to newShoulder: CGPoint) -> CGPoint? {
            if let latestJoint { return currentJoint.map { moved($0, latestJoint) } ?? latestJoint }
            guard let seenAt, time - seenAt <= Self.secondsBeforeTheTorsoIsLost else { return nil }
            return currentJoint.map { CGPoint(x: $0.x + newShoulder.x - oldShoulder.x, y: $0.y + newShoulder.y - oldShoulder.y) }
        }
        let smoothed = BodyTorso(
            imageLeftShoulder: imageLeftShoulder, imageRightShoulder: imageRightShoulder,
            imageLeftHip: moved(current.imageLeftHip, latestResult.imageLeftHip), imageRightHip: moved(current.imageRightHip, latestResult.imageRightHip),
            hipsWereEstimated: latestResult.hipsWereEstimated, shouldersAreSeen: latestResult.shouldersAreSeen,
            imageLeftElbow: smoothedJoint(current: current.imageLeftElbow, latest: latestResult.imageLeftElbow, seenAt: imageLeftElbowSeenAt, shoulderMovedFrom: current.imageLeftShoulder, to: imageLeftShoulder),
            imageRightElbow: smoothedJoint(current: current.imageRightElbow, latest: latestResult.imageRightElbow, seenAt: imageRightElbowSeenAt, shoulderMovedFrom: current.imageRightShoulder, to: imageRightShoulder),
            imageLeftWrist: smoothedJoint(current: current.imageLeftWrist, latest: latestResult.imageLeftWrist, seenAt: imageLeftWristSeenAt, shoulderMovedFrom: current.imageLeftShoulder, to: imageLeftShoulder),
            imageRightWrist: smoothedJoint(current: current.imageRightWrist, latest: latestResult.imageRightWrist, seenAt: imageRightWristSeenAt, shoulderMovedFrom: current.imageRightShoulder, to: imageRightShoulder)
        )
        smoothedTorso = smoothed
        return smoothed
    }
}

/// Runs the body pose request off the frame queue and hands every frame the newest smoothed torso. Safe to call from any
/// queue; the panel calls it from its frame processing queue.
nonisolated final class ShirtPoseTracker: @unchecked Sendable {
    /// Pose runs start at least this far apart, so about 20 a second, which keeps a walking person's joints fresh.
    static let minimumSecondsBetweenPoseRuns = 0.05

    private struct State {
        var latestResult: BodyTorso?
        var runIsInFlight = false
        var lastRunStartedAt: TimeInterval?
        var smoother = ShirtTorsoSmoother()
        /// Counts resets, so a run that finishes after one does not bring the last session's torso back.
        var generation = 0

        init(generation: Int = 0) { self.generation = generation }
    }

    private let poseQueue = DispatchQueue(label: "com.crodris.clicky.shirt-try-on.pose", qos: .userInteractive)
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Forgets the torso, for a new try-on session.
    func reset() {
        state.withLock { state in
            state = State(generation: state.generation + 1)
        }
    }

    /// The torso for the frame `cameraFrame` at `time` (seconds on any steady clock, such as `CACurrentMediaTime()`), nil
    /// when nobody is in view. Starts a pose run on this frame when none is running and the last started long enough ago;
    /// the run's result reaches the frames after it.
    func torso(forFrame cameraFrame: CVPixelBuffer, atTime time: TimeInterval) -> BodyTorso? {
        let generationToRun: Int? = state.withLock { state in
            guard !state.runIsInFlight, time - (state.lastRunStartedAt ?? -.infinity) >= Self.minimumSecondsBetweenPoseRuns else { return nil }
            state.runIsInFlight = true
            state.lastRunStartedAt = time
            return state.generation
        }
        if let generationToRun {
            // The camera never writes a frame it has handed out, so the pose queue may read it while the caller does.
            nonisolated(unsafe) let frameToRead = cameraFrame
            poseQueue.async {
                let torso = Self.detectTorso(in: frameToRead)
                self.state.withLock { state in
                    state.runIsInFlight = false
                    guard state.generation == generationToRun else { return }
                    state.latestResult = torso
                }
            }
        }
        return state.withLock { state in
            let latestResult = state.latestResult
            return state.smoother.advance(toward: latestResult, at: time)
        }
    }

    /// The torso in one frame, with no smoothing and no queue, nil when nobody is in view. When several people are in view
    /// the closest one, the one with the widest shoulders among those whose shoulders are seen, is the learner.
    static func detectTorso(in cameraFrame: CVPixelBuffer) -> BodyTorso? {
        let frameSize = CGSize(width: CVPixelBufferGetWidth(cameraFrame), height: CVPixelBufferGetHeight(cameraFrame))
        let request = VNDetectHumanBodyPoseRequest()
        do {
            try VNImageRequestHandler(cvPixelBuffer: cameraFrame, orientation: .up).perform([request])
        } catch {
            print("Shirt try-on: body pose failed: \(error)")
            return nil
        }
        let torsos = (request.results ?? []).compactMap { BodyTorso(observation: $0, frameSize: frameSize) }
        return torsos.max { first, second in
            if first.shouldersAreSeen != second.shouldersAreSeen { return !first.shouldersAreSeen }
            return first.shoulderWidth < second.shoulderWidth
        }
    }
}
