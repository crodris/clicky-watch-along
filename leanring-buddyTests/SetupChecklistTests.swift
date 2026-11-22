//
//  SetupChecklistTests.swift
//  leanring-buddyTests
//
//  The six setup steps: the state each one reads from what macOS reports, which step the checklist points at, the bar's
//  share, when setup counts as done, and which buttons a turned-off step offers.
//

import AVFoundation
import Speech
import Testing

@testable import Clicky

@MainActor
struct SetupChecklistTests {
    /// Everything granted, the test passed, and Chrome control allowed.
    private let everythingDone = SetupFacts(
        microphoneStatus: .authorized,
        speechRecognitionStatus: .authorized,
        hasScreenRecording: true,
        screenTestPassed: true,
        screenTestFailed: false,
        hasAccessibility: true,
        chromeControlStatus: .granted,
        stepsAskedForThisLaunch: []
    )

    /// A fresh Mac: nothing asked for yet, and Chrome closed.
    private let nothingAskedYet = SetupFacts(
        microphoneStatus: .notDetermined,
        speechRecognitionStatus: .notDetermined,
        hasScreenRecording: false,
        screenTestPassed: false,
        screenTestFailed: false,
        hasAccessibility: false,
        chromeControlStatus: .chromeIsNotRunning,
        stepsAskedForThisLaunch: []
    )

    @Test func theSixStepsKeepTheirOrder() {
        #expect(SetupStep.allCases == [.microphone, .speechRecognition, .screenRecording, .screenTest, .accessibility, .chromeControl])
        #expect(SetupStep.allCases.filter { !$0.isRequired } == [.chromeControl])
    }

    @Test func eachStepReadsWhatMacOSReports() {
        var facts = nothingAskedYet
        #expect(setupStepStates(for: facts).map(\.state) == [.toDo, .toDo, .toDo, .toDo, .toDo, .needsChromeOpen])

        facts.microphoneStatus = .denied
        facts.speechRecognitionStatus = .restricted
        facts.chromeControlStatus = .denied
        facts.screenTestFailed = true
        #expect(setupStepState(of: .microphone, facts: facts) == .turnedOff)
        #expect(setupStepState(of: .speechRecognition, facts: facts) == .turnedOff)
        #expect(setupStepState(of: .chromeControl, facts: facts) == .turnedOff)
        #expect(setupStepState(of: .screenTest, facts: facts) == .turnedOff)

        // A provider that does not use Apple's speech recognition needs no step for it.
        facts.speechRecognitionStatus = nil
        #expect(setupStepState(of: .speechRecognition, facts: facts) == .notNeeded)
        #expect(setupStepStates(for: everythingDone).allSatisfy { $0.state == .done })
    }

    @Test func screenRecordingAndAccessibilityReadAsTurnedOffOnlyOnceTheLearnerAsked() {
        var facts = nothingAskedYet
        #expect(setupStepState(of: .screenRecording, facts: facts) == .toDo)
        #expect(setupStepState(of: .accessibility, facts: facts) == .toDo)
        facts.stepsAskedForThisLaunch = [.screenRecording, .accessibility]
        #expect(setupStepState(of: .screenRecording, facts: facts) == .turnedOff)
        #expect(setupStepState(of: .accessibility, facts: facts) == .turnedOff)
        facts.hasScreenRecording = true
        #expect(setupStepState(of: .screenRecording, facts: facts) == .done)
    }

    @Test func theChecklistPointsAtTheFirstStepLeftUnlessThatStepIsTurnedOff() {
        var facts = nothingAskedYet
        #expect(nextSetupStep(in: setupStepStates(for: facts)) == .microphone)
        facts.microphoneStatus = .authorized
        facts.speechRecognitionStatus = nil
        #expect(nextSetupStep(in: setupStepStates(for: facts)) == .screenRecording)
        facts.stepsAskedForThisLaunch = [.screenRecording]
        // The red row says what to do, so nothing points past it.
        #expect(nextSetupStep(in: setupStepStates(for: facts)) == nil)
        // With every required step done, Chrome closed leaves nothing to point at, and Chrome open points at its step.
        var requiredDone = everythingDone
        requiredDone.chromeControlStatus = .chromeIsNotRunning
        #expect(nextSetupStep(in: setupStepStates(for: requiredDone)) == nil)
        requiredDone.chromeControlStatus = .notAskedYet
        #expect(nextSetupStep(in: setupStepStates(for: requiredDone)) == .chromeControl)
        #expect(nextSetupStep(in: setupStepStates(for: everythingDone)) == nil)
    }

    @Test func theBarFillsWithTheShareDoneAndChromeControlNeverHoldsSetupBack() {
        var facts = nothingAskedYet
        #expect(setupProgressFraction(of: setupStepStates(for: facts)) == 0)
        facts.microphoneStatus = .authorized
        facts.speechRecognitionStatus = nil
        #expect(setupProgressFraction(of: setupStepStates(for: facts)) == 2.0 / 6.0)
        #expect(!everyRequiredSetupStepIsDone(setupStepStates(for: facts)))
        #expect(firstRequiredSetupStepThatIsOff(setupStepStates(for: facts)) == .screenRecording)

        var requiredDone = everythingDone
        requiredDone.chromeControlStatus = .denied
        #expect(everyRequiredSetupStepIsDone(setupStepStates(for: requiredDone)))
        #expect(firstRequiredSetupStepThatIsOff(setupStepStates(for: requiredDone)) == nil)
        #expect(setupProgressFraction(of: setupStepStates(for: requiredDone)) == 5.0 / 6.0)
    }

    @Test func aTurnedOffStepOffersTheWayToFixIt() {
        #expect(setupStepButtons(for: .microphone, in: .done).isEmpty)
        #expect(setupStepButtons(for: .speechRecognition, in: .notNeeded).isEmpty)
        #expect(setupStepButtons(for: .microphone, in: .toDo).map(\.title) == ["Allow"])
        #expect(setupStepButtons(for: .screenTest, in: .toDo).map(\.title) == ["Test"])
        #expect(setupStepButtons(for: .screenRecording, in: .turnedOff).map(\.action) == [.openSystemSettings, .quitAndReopen])
        #expect(setupStepButtons(for: .accessibility, in: .turnedOff).map(\.action) == [.openSystemSettings, .findTheApp])
        #expect(setupStepButtons(for: .screenTest, in: .turnedOff).map(\.title) == ["Try again"])
        #expect(setupStepButtons(for: .chromeControl, in: .needsChromeOpen).map(\.action) == [.openChrome])
        #expect(setupTurnedOffCaption(for: .screenRecording).contains("quit and reopen"))
    }

    @Test func theDisclosureNamesEveryCaptureAndEveryPlaceItGoes() {
        for capture in ["every display", "pop-out", "3D build", "experiment", "quiz question", "agent", "Theme Studio"] {
            #expect(setupCaptureDisclosure.contains(capture))
        }
        #expect(setupCaptureDisclosure.contains("Anthropic") && setupCaptureDisclosure.contains("OpenAI"))
        // The room art's camera frames and the furniture's product photo have their own destinations.
        for roomArtWords in ["camera", "depth service", "fal.ai"] {
            #expect(setupCaptureDisclosure.contains(roomArtWords))
        }
        // macOS keeps speech recognition on the Mac only where the Mac supports it, so the step never promises it.
        #expect(!SetupStep.speechRecognition.purpose.lowercased().contains("on-device"))
        #expect(!SetupStep.speechRecognition.purpose.lowercased().contains("on your mac"))
    }
}
