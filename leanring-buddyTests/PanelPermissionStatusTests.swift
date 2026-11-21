//
//  PanelPermissionStatusTests.swift
//  leanring-buddyTests
//
//  Pins how the menu bar panel reads Speech Recognition and Chrome control, so a Chrome that is
//  closed is never shown as granted and a provider that needs no speech permission is never blocked on it.
//

import Foundation
import Speech
import Testing

@testable import Clicky

struct PanelPermissionStatusTests {
    @Test func chromeAutomationStatusMapsEachSystemAnswer() {
        #expect(ChromeAutomationPermissionStatus(osStatus: noErr) == .granted)
        #expect(ChromeAutomationPermissionStatus(osStatus: OSStatus(errAEEventNotPermitted)) == .denied)
        #expect(ChromeAutomationPermissionStatus(osStatus: OSStatus(procNotFound)) == .chromeIsNotRunning)
        #expect(ChromeAutomationPermissionStatus(osStatus: OSStatus(errAEEventWouldRequireUserConsent)) == .notAskedYet)
    }

    @Test func speechRecognitionOnlyBlocksWhenTheProviderUsesIt() {
        #expect(speechRecognitionPermissionIsSatisfied(providerRequiresSpeechRecognition: false, authorizationStatus: .denied))
        #expect(speechRecognitionPermissionIsSatisfied(providerRequiresSpeechRecognition: true, authorizationStatus: .authorized))
        #expect(!speechRecognitionPermissionIsSatisfied(providerRequiresSpeechRecognition: true, authorizationStatus: .notDetermined))
        #expect(!speechRecognitionPermissionIsSatisfied(providerRequiresSpeechRecognition: true, authorizationStatus: .denied))
    }
}
