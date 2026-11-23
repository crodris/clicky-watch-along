//
//  ShirtStepBack.swift
//  leanring-buddy
//
//  The step-back countdown of the shirt try-on's painted still. Push-to-talk keeps the learner leaning in at the keyboard
//  when they say "right there", too close for the framing (`ShirtFraming.assess` would say stand back), so the panel no
//  longer freezes at once. "Right there" and Paint it arm a capture, Clicky says to step back and hold still, and the
//  capture freezes the first frame where the debounced framing has settled on ready and the torso has held still for
//  `secondsToHoldStill`, with a 3-2-1 countdown on the panel (one number per half second of the hold, and a soft tick as
//  each number appears). No hold starts in the first `secondsBeforeAHoldMayStart` after arming, so a learner already in
//  frame at the keyboard does not freeze while Clicky still says to step back. Moving, or leaving the ready framing,
//  restarts the hold. A capture that has not frozen within `secondsBeforeGivingUp` disarms.
//
//  Everything here is pure: the caller passes each frame's time, so a test steps the capture by hand and never sleeps.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - The lines

/// What Clicky says, and the status line shows, when "right there" arms the capture. Not a failure.
nonisolated let roomArtShirtStepBackLine = "Step back and hold still."
/// What Clicky says when the capture gave up. Not a failure, so the cursor does not shake.
nonisolated let roomArtShirtStepBackTimeoutLine = "I can't see your shoulders yet. Say paint it when you're ready."

// MARK: - The sounds

/// The two short sounds of the countdown, macOS system sounds that no bundled theme uses for done, correct, or needs your
/// OK, so under those themes a countdown is not mistaken for an agent finishing or a quiz answer. A saved theme may pick
/// any system sound, these two included. The countdown itself is on screen and is not spoken.
nonisolated enum ShirtCountdownSound: Equatable, Sendable {
    /// A soft tick as each number appears.
    case tick
    /// A short sound when the frame freezes.
    case freeze

    var systemSoundName: String {
        switch self {
        case .tick: "Morse"
        case .freeze: "Bottle"
        }
    }

    func play() {
        NSSound(named: NSSound.Name(systemSoundName))?.play()
    }
}

/// The sound an event of the armed capture makes, if any: a tick when a number appears, a different sound when the frame
/// freezes. A hold restarting (no number), and a time out, are silent.
nonisolated func shirtCountdownSound(for event: ShirtCaptureEvent) -> ShirtCountdownSound? {
    switch event {
    case .countdown(let number): number == nil ? nil : .tick
    case .frozen: .freeze
    case .timedOut: nil
    }
}

// MARK: - What the frame processor reports

/// What an armed capture tells the main actor, in the order it happens.
nonisolated enum ShirtCaptureEvent: Sendable {
    /// The number to show, 3 then 2 then 1, or nil when the hold restarted and no number shows.
    case countdown(Int?)
    /// The first frame where the learner held still in the ready framing, frozen with the torso found for that same frame.
    case frozen(ShirtFrozenFrame)
    /// No hold completed within `ShirtStepBackCapture.secondsBeforeGivingUp`, so the capture is disarmed.
    case timedOut
}

// MARK: - The capture

nonisolated struct ShirtStepBackCapture: Equatable, Sendable {
    /// How long the torso must stay still in the ready framing before the frame freezes. The countdown shows
    /// `countdownNumbers` numbers over it, one per half second, which reads as a countdown on video and not as a flash.
    static let secondsToHoldStill = 1.5
    static let countdownNumbers = 3
    /// No hold starts in this long after the capture is armed, since a learner already in frame at the keyboard would
    /// otherwise freeze while Clicky still says "Step back and hold still."
    static let secondsBeforeAHoldMayStart = 0.75
    /// An armed capture that has not frozen within this long disarms, unless a hold is under way, which finishes first.
    /// Standing up from a desk and backing away takes most of ten seconds, so it is longer.
    static let secondsBeforeGivingUp = 18.0
    /// The torso is still while its shoulder midpoint and its shoulder width stay within this many shoulder widths of where
    /// the hold began. Pose estimates jitter by a fraction of that, and a learner stepping back moves far more.
    static let stillnessInShoulderWidths = 0.04

    enum Step: Equatable, Sendable {
        /// Not in the ready framing, or still moving: no number shows.
        case keepWaiting
        /// The torso has held still for part of the hold: show this number, 3 then 2 then 1.
        case counting(number: Int)
        /// The hold completed on this frame: freeze it.
        case freezeNow
        /// Nothing froze in time.
        case giveUp
    }

    /// Where the torso stood when the hold began, which every later frame is compared against.
    private struct Hold: Equatable, Sendable {
        let shoulderMidpoint: CGPoint
        let shoulderWidth: Double
        let startedAt: TimeInterval

        init(torso: BodyTorso, startedAt: TimeInterval) {
            shoulderMidpoint = torso.shoulderMidpoint
            shoulderWidth = torso.shoulderWidth
            self.startedAt = startedAt
        }

        func holds(still torso: BodyTorso) -> Bool {
            let midpointShift = hypot(torso.shoulderMidpoint.x - shoulderMidpoint.x, torso.shoulderMidpoint.y - shoulderMidpoint.y)
            let widthChange = abs(torso.shoulderWidth - shoulderWidth)
            return midpointShift < ShirtStepBackCapture.stillnessInShoulderWidths * shoulderWidth
                && widthChange < ShirtStepBackCapture.stillnessInShoulderWidths * shoulderWidth
        }
    }

    let armedAt: TimeInterval
    private var hold: Hold?

    init(armedAt: TimeInterval) {
        self.armedAt = armedAt
    }

    /// Takes one frame. `framingKind` is the debounced kind and `torso` the smoothed one the renderer draws on this frame,
    /// nil when no one is in view. A hold counts only in the ready framing, so a learner still leaning in never freezes.
    mutating func advance(framingKind: ShirtFramingKind?, torso: BodyTorso?, at time: TimeInterval) -> Step {
        let torsoInTheReadyFraming: BodyTorso? = framingKind == .ready ? torso : nil
        if let hold, let torsoInTheReadyFraming, hold.holds(still: torsoInTheReadyFraming) {
            let secondsHeld = time - hold.startedAt
            if secondsHeld >= Self.secondsToHoldStill { return .freezeNow }
            return .counting(number: Self.countdownNumber(afterHolding: secondsHeld))
        }
        // No hold is under way, or the torso moved or left the ready framing, which restarts it.
        hold = nil
        if time - armedAt >= Self.secondsBeforeGivingUp { return .giveUp }
        guard time - armedAt >= Self.secondsBeforeAHoldMayStart else { return .keepWaiting }
        guard let torsoInTheReadyFraming, torsoInTheReadyFraming.shoulderWidth > 0 else { return .keepWaiting }
        hold = Hold(torso: torsoInTheReadyFraming, startedAt: time)
        return .counting(number: Self.countdownNumbers)
    }

    /// A freeze that found nothing to freeze (no person mask yet) starts the hold over, so the countdown never sits on 1.
    mutating func restartTheHold() {
        hold = nil
    }

    /// 3 at the start of the hold, then 2 after half a second, then 1 after a whole second.
    static func countdownNumber(afterHolding secondsHeld: TimeInterval) -> Int {
        let secondsPerNumber = secondsToHoldStill / Double(countdownNumbers)
        let numbersAlreadyShown = Int((secondsHeld / secondsPerNumber).rounded(.down))
        return max(1, countdownNumbers - numbersAlreadyShown)
    }
}

// MARK: - The countdown on the panel

/// The scale a countdown number pops in from. Reduce Motion shows each number at its own size with no scale animation.
nonisolated func shirtCountdownNumberStartScale(reduceMotionIsOn: Bool) -> CGFloat {
    reduceMotionIsOn ? 1 : 1.5
}
