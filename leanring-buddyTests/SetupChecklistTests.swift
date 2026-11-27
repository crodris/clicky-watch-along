//
//  SetupChecklistTests.swift
//  leanring-buddyTests
//
//  The six setup steps: the state each one reads from what macOS reports, which step the checklist points at, the bar's
//  share, when setup counts as done, which buttons a turned-off step offers, and the capture disclosure: two sentences
//  that show, and the full detail that stays closed until asked for.
//

import AVFoundation
import Speech
import SwiftUI
import Testing

@testable import Clicky

/// Serialized, since the accessibility tests turn an app-wide switch on and off around an await.
@MainActor
@Suite(.serialized)
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

    @Test func theShownSummaryIsTwoSentencesThatNameTheCapturesAndEveryPlaceTheyGo() {
        let sentences = setupCaptureSummary.components(separatedBy: ". ")
        #expect(sentences.count == 2)
        for words in ["screen", "camera", "Clicky's own server", "depth service on this Mac", "Anthropic", "OpenAI", "fal.ai"] {
            #expect(setupCaptureSummary.contains(words), "\(words)")
        }
        // fal.ai gets no capture.
        #expect(setupCaptureSummary.contains("fal.ai receives only the product photo of anything you try that stands on a surface, also through Clicky's own server."))
    }

    @Test func voiceOverReadsTheDisclosureButtonByItsWordsAndItsState() async throws {
        let closed = try await accessibilityElements(of: SetupWhatGetsSent())
        #expect(closed.map(\.role) == ["AXButton"])
        #expect(closed.map(\.label) == ["What gets sent"])
        #expect(closed.map(\.value) == ["Hidden"])
        let open = try await accessibilityElements(of: SetupWhatGetsSent(isOpen: true))
        #expect(open.map(\.role) == ["AXButton", "AXStaticText"])
        #expect(open.map(\.value) == ["Shown", setupCaptureDisclosure])
    }

    @Test func theLineAboveTheStepsShowsWhileTheDisclosureIsClosed() async throws {
        let checklist = SetupChecklistView(
            stepStates: setupStepStates(for: everythingDone),
            isAFirstRun: false,
            isRequestingTheScreenTest: false,
            shownTheme: try #require(bundledThemesForTests.first),
            runStep: { _, _ in },
            start: {}
        )
        let elements = try await accessibilityElements(of: checklist)
        let introduction = "Each step below is for one job."
        #expect(elements.filter { $0.value == introduction }.count == 1)
        #expect(!elements.contains { $0.value == setupCaptureDisclosure })
        #expect(!setupCaptureDisclosure.contains(introduction))
    }

    @Test func readingTheAccessibilityTreeLeavesTheAppWideSwitchAsItFoundIt() async throws {
        setEnhancedUserInterface(false)
        _ = try await accessibilityElements(of: SetupWhatGetsSent())
        #expect(!enhancedUserInterfaceIsOn())
    }

    private static let enhancedUserInterface = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    private func enhancedUserInterfaceIsOn() -> Bool {
        NSApplication.shared.accessibilityAttributeValue(Self.enhancedUserInterface) as? Bool ?? false
    }

    private func setEnhancedUserInterface(_ isOn: Bool) {
        NSApplication.shared.accessibilitySetValue(isOn, forAttribute: Self.enhancedUserInterface)
    }

    private struct AccessibilityElement {
        let role: String
        let label: String?
        let value: String?
    }

    /// What VoiceOver finds in a view: every element under the hosting view, in order. The window is never shown.
    private func accessibilityElements(of view: some View) async throws -> [AccessibilityElement] {
        let hostingView = NSHostingView(rootView: view.frame(width: 300))
        hostingView.frame = CGRect(origin: .zero, size: hostingView.fittingSize)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        // SwiftUI builds its accessibility tree only for an assistive client, which this stands in for. The switch is the
        // whole app's, and every test shares the app, so it goes back to what it was.
        let enhancedUserInterfaceWasOn = enhancedUserInterfaceIsOn()
        defer { setEnhancedUserInterface(enhancedUserInterfaceWasOn) }
        setEnhancedUserInterface(true)
        // SwiftUI's accessibility nodes do not conform to NSAccessibilityProtocol, so each is asked by selector.
        func read(_ object: NSObject, _ attribute: String) -> Any? {
            let selector = NSSelectorFromString(attribute)
            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
        }
        func elements(under element: Any) -> [AccessibilityElement] {
            guard let object = element as? NSObject else { return [] }
            return ((read(object, "accessibilityChildren") as? [Any]) ?? []).flatMap { child -> [AccessibilityElement] in
                guard let childObject = child as? NSObject else { return [] }
                let found = AccessibilityElement(
                    role: read(childObject, "accessibilityRole") as? String ?? "",
                    label: read(childObject, "accessibilityLabel") as? String,
                    value: read(childObject, "accessibilityValue") as? String
                )
                return [found] + elements(under: childObject)
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while elements(under: hostingView).isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return elements(under: hostingView)
    }

    @Test func theFullDisclosureStaysClosedUntilTheLearnerOpensIt() {
        func height(of view: SetupWhatGetsSent) -> CGFloat {
            NSHostingController(rootView: view).sizeThatFits(in: CGSize(width: 300, height: 10_000)).height
        }
        // Closed, only the button shows. Open, the long disclosure wraps under it.
        #expect(height(of: SetupWhatGetsSent()) < 40)
        #expect(height(of: SetupWhatGetsSent(isOpen: true)) > 150)
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
        // The shirt try-on uses the camera too. One frame goes to the depth service during the page read, before the kind is
        // known. After that its camera view stays on this Mac, and painting the shirt sends one frame out.
        #expect(setupCaptureDisclosure.contains("Showing an item in your room, or clothing on you, uses your camera."))
        #expect(setupCaptureDisclosure.contains("one camera frame also goes to the depth service to measure the wall, before Clicky knows the item is clothing"))
        #expect(setupCaptureDisclosure.contains("After that, clothing's camera view stays on this Mac until you say paint it, which sends one camera frame and the product photo through Clicky's own server to OpenAI."))
        #expect(!setupCaptureDisclosure.contains("A shirt's camera frames stay on this Mac."))
        // Reading the store page sends its text and its product photos to Anthropic, which the disclosure names too.
        #expect(setupCaptureDisclosure.contains("Reading the store page also sends its text and up to four of its pictures through Clicky's own server to Anthropic."))
        #expect(setupCaptureDisclosure.contains("Save photo keeps the panel's picture only in the Clicky folder of your Pictures, on this Mac."))
        // macOS keeps speech recognition on the Mac only where the Mac supports it, so the step never promises it.
        #expect(!SetupStep.speechRecognition.purpose.lowercased().contains("on-device"))
        #expect(!SetupStep.speechRecognition.purpose.lowercased().contains("on your mac"))
    }
}
