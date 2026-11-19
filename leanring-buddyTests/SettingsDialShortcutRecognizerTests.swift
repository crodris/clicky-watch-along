//
//  SettingsDialShortcutRecognizerTests.swift
//  leanring-buddyTests
//
//  The shift + option chord that runs the settings dial: when it opens, commits, and cancels the dial, and which
//  other shortcuts and gestures it must never fire on.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Clicky

struct SettingsDialShortcutRecognizerTests {

    @Test func aDragThatBeganBeforeShiftAndOptionNeverOpensTheDial() {
        var recognizer = SettingsDialShortcutRecognizer()
        _ = recognizer.modifiersChanged([.option], at: 10, aMouseButtonIsDown: true)
        _ = recognizer.modifiersChanged([.shift, .option], at: 10.1, aMouseButtonIsDown: true)
        #expect(recognizer.holdCompletesAt == nil)
        #expect(recognizer.timeAdvanced(to: 11) == nil)

        var middleClickRecognizer = SettingsDialShortcutRecognizer()
        _ = middleClickRecognizer.modifiersChanged([.shift, .option], at: 20)
        _ = middleClickRecognizer.pressArrived(ofType: .otherMouseDown)
        #expect(middleClickRecognizer.timeAdvanced(to: 21) == nil)
    }

    @Test func shiftAndOptionHeldForThreeTenthsOfASecondOpensTheDialOnce() {
        var recognizer = SettingsDialShortcutRecognizer()
        _ = recognizer.modifiersChanged([.shift], at: 9.9)
        _ = recognizer.modifiersChanged([.shift, .option], at: 10)
        #expect(recognizer.holdCompletesAt == 10 + 0.3)
        #expect(recognizer.timeAdvanced(to: 10.29) == nil)
        #expect(recognizer.timeAdvanced(to: 10 + 0.3) == .opened)
        #expect(recognizer.timeAdvanced(to: 12) == nil)
        #expect(recognizer.holdCompletesAt == nil)

        // Releasing everything arms it again.
        #expect(recognizer.modifiersChanged([], at: 13) == .released)
        _ = recognizer.modifiersChanged([.shift, .option], at: 14)
        #expect(recognizer.timeAdvanced(to: 14 + 0.3) == .opened)
    }

    @Test func releasingEitherKeyOrBothWhileTheDialIsOpenCommitsOnceAndRearmsAfterEveryModifierIsUp() {
        for keyThatStaysDown in [NSEvent.ModifierFlags.shift, .option, []] {
            var recognizer = SettingsDialShortcutRecognizer()
            _ = recognizer.modifiersChanged([.shift, .option], at: 10)
            #expect(recognizer.timeAdvanced(to: 10.3) == .opened)
            #expect(recognizer.modifiersChanged([.shift, .option], at: 10.5) == nil, "a repeated flags event is not a release")
            #expect(recognizer.modifiersChanged(keyThatStaysDown, at: 11) == .released, "\(keyThatStaysDown)")
            // The second key coming up a moment later is not a second release.
            #expect(recognizer.modifiersChanged([], at: 11.01) == nil)
            _ = recognizer.modifiersChanged([.shift, .option], at: 12)
            #expect(recognizer.timeAdvanced(to: 12.3) == .opened)
        }
    }

    @Test func releasingBeforeThreeTenthsOfASecondDoesNotOpenTheDial() {
        var recognizer = SettingsDialShortcutRecognizer()
        _ = recognizer.modifiersChanged([.shift, .option], at: 10)
        #expect(recognizer.modifiersChanged([.option], at: 10.2) == nil)
        #expect(recognizer.timeAdvanced(to: 10.3) == nil)
        #expect(recognizer.timeAdvanced(to: 11) == nil)
    }

    @Test func aKeyTypedDuringTheHoldDoesNotOpenTheDialEvenWhenItIsReleased() {
        var recognizer = SettingsDialShortcutRecognizer()
        _ = recognizer.modifiersChanged([.shift, .option], at: 10)
        #expect(recognizer.pressArrived(ofType: .keyDown) == nil)
        #expect(recognizer.timeAdvanced(to: 10.3) == nil)

        // Still holding both after the key is let go: this hold stays broken until every modifier is released.
        #expect(recognizer.timeAdvanced(to: 12) == nil)
        _ = recognizer.modifiersChanged([], at: 13)
        _ = recognizer.modifiersChanged([.shift, .option], at: 14)
        #expect(recognizer.timeAdvanced(to: 14.3) == .opened)
    }

    @Test func aClickOrADragStartedDuringTheHoldDoesNotOpenTheDial() {
        // Shift + option + a click or a drag is a command in many apps, so it must not open the dial.
        for mouseButtonPress in [CGEventType.leftMouseDown, .rightMouseDown] {
            var recognizer = SettingsDialShortcutRecognizer()
            _ = recognizer.modifiersChanged([.shift, .option], at: 10)
            _ = recognizer.pressArrived(ofType: mouseButtonPress)
            #expect(recognizer.timeAdvanced(to: 10.3) == nil, "\(mouseButtonPress)")
        }

        // A key let go, or the mouse moving, is not a press.
        var recognizer = SettingsDialShortcutRecognizer()
        _ = recognizer.modifiersChanged([.shift, .option], at: 10)
        _ = recognizer.pressArrived(ofType: .keyUp)
        _ = recognizer.pressArrived(ofType: .mouseMoved)
        #expect(recognizer.timeAdvanced(to: 10.3) == .opened)
    }

    @Test func ordinaryTypingBeforeTheHoldDoesNotBlockIt() {
        var recognizer = SettingsDialShortcutRecognizer()
        #expect(recognizer.pressArrived(ofType: .keyDown) == nil)
        #expect(recognizer.pressArrived(ofType: .leftMouseDown) == nil)
        _ = recognizer.modifiersChanged([.shift, .option], at: 10)
        #expect(recognizer.timeAdvanced(to: 10.3) == .opened)
    }

    @Test func controlOrCommandWithShiftAndOptionNeverOpensTheDialEvenAfterTheyAreReleased() {
        for extraModifier in [NSEvent.ModifierFlags.control, .command] {
            var recognizer = SettingsDialShortcutRecognizer()
            _ = recognizer.modifiersChanged([.shift, .option, extraModifier], at: 10)
            #expect(recognizer.timeAdvanced(to: 11) == nil)
            _ = recognizer.modifiersChanged([.shift, .option], at: 11.1)
            #expect(recognizer.timeAdvanced(to: 12) == nil)
        }

        // Push-to-talk first, then shift joins it: ctrl + option is never the dial.
        var pushToTalkRecognizer = SettingsDialShortcutRecognizer()
        _ = pushToTalkRecognizer.modifiersChanged([.control, .option], at: 10)
        _ = pushToTalkRecognizer.modifiersChanged([.control, .option, .shift], at: 10.1)
        _ = pushToTalkRecognizer.modifiersChanged([.shift, .option], at: 10.2)
        #expect(pushToTalkRecognizer.timeAdvanced(to: 11) == nil)
    }

    @Test func aKeyOrAMouseButtonOrAnotherModifierWhileTheDialIsOpenCancelsItOnce() {
        // Escape is a key press, so it cancels through the same path.
        for pressThatCancels in [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown] {
            var recognizer = SettingsDialShortcutRecognizer()
            _ = recognizer.modifiersChanged([.shift, .option], at: 10)
            #expect(recognizer.timeAdvanced(to: 10.3) == .opened)
            #expect(recognizer.pressArrived(ofType: pressThatCancels) == .cancelled, "\(pressThatCancels)")
            // Letting go afterwards is not a commit, since the dial is already gone.
            #expect(recognizer.modifiersChanged([], at: 11) == nil)
        }

        // A key coming up or the mouse moving does not cancel.
        var recognizer = SettingsDialShortcutRecognizer()
        _ = recognizer.modifiersChanged([.shift, .option], at: 10)
        #expect(recognizer.timeAdvanced(to: 10.3) == .opened)
        #expect(recognizer.pressArrived(ofType: .keyUp) == nil)
        #expect(recognizer.pressArrived(ofType: .mouseMoved) == nil)

        // Control joining is push-to-talk, which takes the keys, so the dial cancels and never commits.
        var pushToTalkRecognizer = SettingsDialShortcutRecognizer()
        _ = pushToTalkRecognizer.modifiersChanged([.shift, .option], at: 20)
        #expect(pushToTalkRecognizer.timeAdvanced(to: 20.3) == .opened)
        #expect(pushToTalkRecognizer.modifiersChanged([.shift, .option, .control], at: 21) == .cancelled)
        #expect(pushToTalkRecognizer.modifiersChanged([.shift, .option], at: 21.1) == nil)
        #expect(pushToTalkRecognizer.modifiersChanged([], at: 22) == nil)
    }
}
