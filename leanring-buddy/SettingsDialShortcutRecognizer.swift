//
//  SettingsDialShortcutRecognizer.swift
//  leanring-buddy
//
//  Recognizes the shift + option chord that runs the settings dial: holding both for 0.3 seconds with nothing else
//  pressed opens it, letting go of either key commits the highlighted item, and any press or another modifier
//  while it is open cancels it, as does the event tap stopping, since the release may never arrive. It is fed modifier changes, key and mouse button presses, and the time, and holds
//  no timer, so tests drive it with made-up times. Ctrl + option is push-to-talk, shift + option + a key types
//  special characters, and shift + option + a click or a drag is a command in many apps, so none of them may open it.
//

import AppKit
import Foundation

struct SettingsDialShortcutRecognizer {
    static let secondsToHold: TimeInterval = 0.3
    /// The presses that break a hold or cancel an open dial, which the event tap listens for besides modifier changes.
    static let pressEventTypesThatBreakAHold: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]

    /// What the chord asks of the dial. Each one is sent once.
    enum Event: Equatable {
        /// The hold reached its time.
        case opened
        /// Shift or option was let go while the dial was open.
        case released
        /// A key, a mouse button, or another modifier arrived while the dial was open. Escape is a key.
        case cancelled
    }

    private enum State: Equatable {
        case waitingForShiftAndOption
        /// Shift and option are the only modifiers held, since this time.
        case holding(since: TimeInterval)
        /// The hold reached its time and the dial is open, until the chord is let go or broken.
        case dialOpen
        /// The hold fired, was broken, or began with something else pressed. Only releasing every modifier ends this.
        case spent
    }

    private static let modifiersThatMatter: NSEvent.ModifierFlags = [.shift, .option, .control, .command]

    private var state = State.waitingForShiftAndOption
    private var heldModifiers: NSEvent.ModifierFlags = []

    /// When a hold in progress would open the dial, so the caller can wake the recognizer then. Nil when no hold is in progress.
    var holdCompletesAt: TimeInterval? {
        guard case .holding(let heldSince) = state else { return nil }
        return heldSince + Self.secondsToHold
    }

    /// aMouseButtonIsDown covers a drag that began before shift and option, which sends no press during the hold.
    mutating func modifiersChanged(_ modifierFlags: NSEvent.ModifierFlags, at time: TimeInterval, aMouseButtonIsDown: Bool = false) -> Event? {
        heldModifiers = modifierFlags.intersection(Self.modifiersThatMatter)
        if state == .dialOpen {
            return modifiersChangedWhileTheDialIsOpen()
        }
        if heldModifiers.isEmpty {
            state = .waitingForShiftAndOption
        } else if heldModifiers == [.shift, .option] {
            // Only a fresh press starts a hold, so releasing ctrl from ctrl + shift + option does not.
            if state == .waitingForShiftAndOption {
                state = aMouseButtonIsDown ? .spent : .holding(since: time)
            }
        } else if !heldModifiers.isSubset(of: [.shift, .option]) || state != .waitingForShiftAndOption {
            state = .spent
        }
        return nil
    }

    /// A key or mouse button pressed while a modifier is held. One pressed with no modifier held is ordinary typing or
    /// clicking and changes nothing, and so is any other event the tap passes on.
    mutating func pressArrived(ofType eventType: CGEventType) -> Event? {
        guard Self.pressEventTypesThatBreakAHold.contains(eventType), !heldModifiers.isEmpty else { return nil }
        let dialWasOpen = state == .dialOpen
        state = .spent
        return dialWasOpen ? .cancelled : nil
    }

    /// Opens the dial once, when the hold reaches its time.
    mutating func timeAdvanced(to time: TimeInterval) -> Event? {
        guard let holdCompletesAt, time >= holdCompletesAt else { return nil }
        state = .dialOpen
        return .opened
    }

    /// The event tap stopped, was cut off by macOS, or lost its Accessibility grant, so the release or press the dial is
    /// waiting for may never arrive. An open dial is cancelled, and every state is forgotten, so the next hold starts fresh.
    mutating func eventTapStopped() -> Event? {
        let dialWasOpen = state == .dialOpen
        self = SettingsDialShortcutRecognizer()
        return dialWasOpen ? .cancelled : nil
    }

    private mutating func modifiersChangedWhileTheDialIsOpen() -> Event? {
        if heldModifiers == [.shift, .option] { return nil }
        if heldModifiers.isSubset(of: [.shift, .option]) {
            // Shift or option, or both, came up: the learner released the chord.
            state = heldModifiers.isEmpty ? .waitingForShiftAndOption : .spent
            return .released
        }
        // Control or command joined, which is push-to-talk or a command shortcut, never a pick.
        state = .spent
        return .cancelled
    }
}
