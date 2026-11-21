//
//  PanelPermissionStatus.swift
//  leanring-buddy
//
//  The two permissions the menu bar panel lists besides microphone, accessibility, and screen
//  recording: Speech Recognition and Automation of Google Chrome. Each is read here without
//  showing a system prompt, so the panel can poll them.
//

import ApplicationServices
import CoreServices
import Foundation
import Speech

/// Whether Clicky may send Apple Events to Google Chrome, which the video quiz, the voice video
/// tools, and the cursor loop use to read and pause the front tab.
enum ChromeAutomationPermissionStatus: Equatable {
    case granted
    /// The learner has not been asked yet, or the answer was reset. A prompt can still appear.
    case notAskedYet
    /// The learner said no. Only System Settings can change it now.
    case denied
    /// macOS can only answer for a running app, so the status is unknown until Chrome opens.
    case chromeIsNotRunning

    static let chromeBundleIdentifier = "com.google.Chrome"

    /// Maps the `OSStatus` of `AEDeterminePermissionToAutomateTarget` to a status.
    /// Any other error is treated as not asked yet, so the row offers the action instead of hiding it.
    init(osStatus: OSStatus) {
        switch osStatus {
        case noErr:
            self = .granted
        case OSStatus(errAEEventNotPermitted):
            self = .denied
        case OSStatus(procNotFound):
            self = .chromeIsNotRunning
        default:
            self = .notAskedYet
        }
    }

    /// Reads the status without showing the system prompt. Cheap enough to call on the panel's
    /// 1.5 second permission poll.
    static func current() -> ChromeAutomationPermissionStatus {
        ChromeAutomationPermissionStatus(
            osStatus: determineAutomationPermission(askUserIfNeeded: false)
        )
    }

    /// Shows the macOS prompt when the learner has not been asked yet. It blocks until the learner
    /// answers, so call it off the main thread.
    static func requestFromTheLearner() -> ChromeAutomationPermissionStatus {
        ChromeAutomationPermissionStatus(
            osStatus: determineAutomationPermission(askUserIfNeeded: true)
        )
    }

    private static func determineAutomationPermission(askUserIfNeeded: Bool) -> OSStatus {
        let chromeTargetDescriptor = NSAppleEventDescriptor(bundleIdentifier: chromeBundleIdentifier)
        // The wildcard event class and ID ask about every event, not one script command.
        return AEDeterminePermissionToAutomateTarget(
            chromeTargetDescriptor.aeDesc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }
}

/// Whether the permission rows Clicky needs for the shipped voice path are granted.
/// Speech Recognition only counts when the transcription provider uses it.
func speechRecognitionPermissionIsSatisfied(
    providerRequiresSpeechRecognition: Bool,
    authorizationStatus: SFSpeechRecognizerAuthorizationStatus
) -> Bool {
    guard providerRequiresSpeechRecognition else { return true }
    return authorizationStatus == .authorized
}
