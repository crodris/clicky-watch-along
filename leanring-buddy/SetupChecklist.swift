//
//  SetupChecklist.swift
//  leanring-buddy
//
//  The six steps of Clicky's setup, as pure data: each step's words, the state macOS reports for it, and which step is
//  next. The menu bar panel draws them (`SetupChecklistView` in `CompanionPanelView.swift`), and `CompanionManager` runs
//  a step's button (`runSetupStep`). A step the learner asked for and macOS still refuses reads as turned off, with the way
//  to fix it, since macOS shows most of these prompts only once.
//

import AVFoundation
import Speech

/// One step of setup, in the order the checklist shows them.
enum SetupStep: CaseIterable, Equatable, Hashable {
    case microphone
    case speechRecognition
    case screenRecording
    /// Not a permission: one test capture through the macOS screen picker, which Clicky's captures need to pass.
    case screenTest
    case accessibility
    /// Optional: only the video features use it.
    case chromeControl

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        case .screenTest: return "Screen test"
        case .accessibility: return "Accessibility"
        case .chromeControl: return "Chrome control"
        }
    }

    /// The one-line job of the step. Speech Recognition does not promise on-device transcription, since macOS keeps it on
    /// the Mac only where the Mac supports it.
    var purpose: String {
        switch self {
        case .microphone: return "Hears you only while you hold the keys"
        case .speechRecognition: return "Apple's speech recognition turns your words into text"
        case .screenRecording: return "Takes the captures described above"
        case .screenTest: return "One test capture to check the screen picker"
        case .accessibility: return "Hears ⌃ ⌥ and finds the video you mean in Chrome"
        case .chromeControl: return "Optional: pauses, plays, and reads the video in Chrome"
        }
    }

    /// What the banner says stops working when a required step is turned off after setup.
    var whatStopsWorkingWhenItIsOff: String {
        switch self {
        case .microphone: return "Clicky can't hear you."
        case .speechRecognition: return "Clicky can't turn your words into text."
        case .screenRecording, .screenTest: return "Clicky can't see your screen."
        case .accessibility: return "Clicky can't hear ⌃ ⌥ or find videos in Chrome."
        case .chromeControl: return "Video quizzes and pop-outs can't control Chrome."
        }
    }

    /// Whether setup is finished without it. Only Chrome control is optional.
    var isRequired: Bool { self != .chromeControl }
}

/// What one step's row shows.
enum SetupStepState: Equatable {
    case done
    /// The speech provider in Info.plist does not use Apple's speech recognition.
    case notNeeded
    /// Not done yet, and nothing has refused it.
    case toDo
    /// The learner asked and macOS refuses, or the answer was no: the row turns red with the way to fix it.
    case turnedOff
    /// Chrome control can be read or asked for only while Chrome runs.
    case needsChromeOpen

    var countsAsDone: Bool { self == .done || self == .notNeeded }
}

/// What macOS says about each step, read without showing a prompt, plus which steps the learner pressed this launch.
struct SetupFacts: Equatable {
    var microphoneStatus: AVAuthorizationStatus
    /// Nil when the speech provider does not use Apple's speech recognition.
    var speechRecognitionStatus: SFSpeechRecognizerAuthorizationStatus?
    var hasScreenRecording: Bool
    var screenTestPassed: Bool
    /// The last test capture failed, such as when the learner cancelled the screen picker.
    var screenTestFailed: Bool
    var hasAccessibility: Bool
    var chromeControlStatus: ChromeAutomationPermissionStatus
    /// Screen Recording and Accessibility report only granted or not, so a step the learner already pressed and that is
    /// still not granted reads as turned off.
    var stepsAskedForThisLaunch: Set<SetupStep>
}

/// The state of every step, in the checklist's order.
func setupStepStates(for facts: SetupFacts) -> [(step: SetupStep, state: SetupStepState)] {
    SetupStep.allCases.map { step in (step, setupStepState(of: step, facts: facts)) }
}

func setupStepState(of step: SetupStep, facts: SetupFacts) -> SetupStepState {
    switch step {
    case .microphone:
        switch facts.microphoneStatus {
        case .authorized: return .done
        case .notDetermined: return .toDo
        default: return .turnedOff
        }
    case .speechRecognition:
        switch facts.speechRecognitionStatus {
        case nil: return .notNeeded
        case .authorized?: return .done
        case .notDetermined?: return .toDo
        default: return .turnedOff
        }
    case .screenRecording:
        if facts.hasScreenRecording { return .done }
        return facts.stepsAskedForThisLaunch.contains(.screenRecording) ? .turnedOff : .toDo
    case .screenTest:
        if facts.screenTestPassed { return .done }
        return facts.screenTestFailed ? .turnedOff : .toDo
    case .accessibility:
        if facts.hasAccessibility { return .done }
        return facts.stepsAskedForThisLaunch.contains(.accessibility) ? .turnedOff : .toDo
    case .chromeControl:
        switch facts.chromeControlStatus {
        case .granted: return .done
        case .notAskedYet: return .toDo
        case .denied: return .turnedOff
        case .chromeIsNotRunning: return .needsChromeOpen
        }
    }
}

/// The step whose button the checklist points at: the first step that is not done, when it waits to be done. A step that
/// is turned off stops the pointing, since its red row already says what to do, and so does Chrome that is not open.
func nextSetupStep(in stepStates: [(step: SetupStep, state: SetupStepState)]) -> SetupStep? {
    guard let firstStepNotDone = stepStates.first(where: { !$0.state.countsAsDone }) else { return nil }
    return firstStepNotDone.state == .toDo ? firstStepNotDone.step : nil
}

/// The share of the six steps that are done, which fills the bar.
func setupProgressFraction(of stepStates: [(step: SetupStep, state: SetupStepState)]) -> Double {
    guard !stepStates.isEmpty else { return 0 }
    return Double(stepStates.filter { $0.state.countsAsDone }.count) / Double(stepStates.count)
}

/// Every required step is done, so Clicky can start. Chrome control does not count.
func everyRequiredSetupStepIsDone(_ stepStates: [(step: SetupStep, state: SetupStepState)]) -> Bool {
    stepStates.allSatisfy { !$0.step.isRequired || $0.state.countsAsDone }
}

/// The first required step that is not done, which the banner names after setup finished.
func firstRequiredSetupStepThatIsOff(_ stepStates: [(step: SetupStep, state: SetupStepState)]) -> SetupStep? {
    stepStates.first { $0.step.isRequired && !$0.state.countsAsDone }?.step
}

/// The words at the top of the checklist, said before any macOS prompt: every capture Clicky takes and where it goes.
let setupCaptureDisclosure = "When you ask a question, Clicky captures every display. It also captures the frame or picture for a pop-out, a 3D build, an experiment, or a quiz question, the video area an agent looks at, any screenshot an agent takes with your OK, and a picture you give the Theme Studio. The captures go through Clicky's own server to Anthropic, and to OpenAI for 3D scenes and experiments. Showing art, furniture, or a shirt uses your camera. Reading the store page also sends its text and up to four of its pictures through Clicky's own server to Anthropic. A camera frame goes to the depth service on this Mac to measure the wall or floor. For furniture, a camera frame and the product photo go through Clicky's own server to OpenAI, and the product photo also goes to fal.ai. A shirt's live preview stays on this Mac, and painting a shirt on you sends one camera frame and the product photo through Clicky's own server to OpenAI. Each step below is for one job."

/// What a turned-off row says instead of its purpose.
func setupTurnedOffCaption(for step: SetupStep) -> String {
    switch step {
    case .screenRecording: return "Off, or waiting for a relaunch. Turn it on, then quit and reopen Clicky."
    case .screenTest: return "The test capture didn't go through. Try it again."
    case .accessibility: return "Off. Turn Clicky on in System Settings, or find the app to add it."
    case .chromeControl: return "Turned off for Clicky. Video features need it."
    case .microphone, .speechRecognition: return "Off. Turn it on for Clicky in System Settings."
    }
}

/// What a setup row's button does.
enum SetupStepAction: Equatable {
    /// Shows the macOS prompt, or runs the screen test.
    case allow
    case openSystemSettings
    /// Shows Clicky in Finder and opens the Accessibility list, for a build that is missing from the list.
    case findTheApp
    /// Screen Recording applies only to a fresh launch.
    case quitAndReopen
    case openChrome
}

/// The buttons a setup row offers, in order, with their titles. A done row offers none.
func setupStepButtons(for step: SetupStep, in state: SetupStepState) -> [(action: SetupStepAction, title: String)] {
    switch state {
    case .done, .notNeeded:
        return []
    case .toDo:
        return [(.allow, step == .screenTest ? "Test" : "Allow")]
    case .needsChromeOpen:
        return [(.openChrome, "Open Chrome")]
    case .turnedOff:
        switch step {
        case .screenTest: return [(.allow, "Try again")]
        case .screenRecording: return [(.openSystemSettings, "Open Settings"), (.quitAndReopen, "Quit and reopen")]
        case .accessibility: return [(.openSystemSettings, "Open Settings"), (.findTheApp, "Find App")]
        case .microphone, .speechRecognition, .chromeControl: return [(.openSystemSettings, "Open Settings")]
        }
    }
}
