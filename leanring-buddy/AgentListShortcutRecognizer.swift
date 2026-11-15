//
//  AgentListShortcutRecognizer.swift
//  leanring-buddy
//
//  Recognizes holding shift + option for 0.3 seconds with nothing else pressed, which opens and closes the agent list.
//  It is fed modifier changes, key downs, and the time, and holds no timer, so tests drive it with made-up times.
//  Ctrl + option is push-to-talk, and shift + option + a key types special characters, so neither may fire it.
//

import AppKit
import Foundation

struct AgentListShortcutRecognizer {
    static let secondsToHold: TimeInterval = 0.3

    private enum State: Equatable {
        case waitingForShiftAndOption
        /// Shift and option are the only modifiers held, since this time.
        case holding(since: TimeInterval)
        /// The hold fired, was broken, or began with something else pressed. Only releasing every modifier ends this.
        case spent
    }

    private static let modifiersThatMatter: NSEvent.ModifierFlags = [.shift, .option, .control, .command]

    private var state = State.waitingForShiftAndOption
    private var heldModifiers: NSEvent.ModifierFlags = []

    /// When a hold in progress would fire, so the caller can wake the recognizer then. Nil when no hold is in progress.
    var holdCompletesAt: TimeInterval? {
        guard case .holding(let heldSince) = state else { return nil }
        return heldSince + Self.secondsToHold
    }

    mutating func modifiersChanged(_ modifierFlags: NSEvent.ModifierFlags, at time: TimeInterval) {
        heldModifiers = modifierFlags.intersection(Self.modifiersThatMatter)
        if heldModifiers.isEmpty {
            state = .waitingForShiftAndOption
        } else if heldModifiers == [.shift, .option] {
            // Only a fresh press starts a hold, so releasing ctrl from ctrl + shift + option does not.
            if state == .waitingForShiftAndOption {
                state = .holding(since: time)
            }
        } else if !heldModifiers.isSubset(of: [.shift, .option]) || state != .waitingForShiftAndOption {
            state = .spent
        }
    }

    /// A key typed while a modifier is held. A key typed with no modifier held is ordinary typing and changes nothing.
    mutating func keyWasPressed() {
        guard !heldModifiers.isEmpty else { return }
        state = .spent
    }

    /// Returns true once, when the hold reaches its time.
    mutating func timeAdvanced(to time: TimeInterval) -> Bool {
        guard let holdCompletesAt, time >= holdCompletesAt else { return false }
        state = .spent
        return true
    }
}
