//
//  VoiceCommandTimingTests.swift
//  leanring-buddyTests
//
//  The voice command timing line: each duration runs between its two marks, and a mark the command never reached
//  prints as "-" so a missing mark is never read as zero.
//

import Foundation
import Testing
@testable import Clicky

struct VoiceCommandTimingTests {
    private let released = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func theLineGivesEachStageInMillisecondsAndADashForAMissingMark() {
        let timing = VoiceCommandTiming(
            pushToTalkReleasedAt: released,
            transcriptReadyAt: released.addingTimeInterval(0.7),
            screenStateReadyAt: released.addingTimeInterval(0.3),
            commandSentAt: released.addingTimeInterval(0.72),
            firstToolCallReceivedAt: released.addingTimeInterval(1.5),
            firstLineAudioStartedAt: released.addingTimeInterval(2.1)
        )
        #expect(timing.logLine == "release_to_transcript_ms=700 release_to_screen_state_ms=300 transcript_to_request_ms=20 request_to_first_call_ms=780 first_call_to_first_line_ms=600 release_to_first_line_ms=2100")

        // A hand-off command speaks no line itself, and a command with no press has no release.
        let timingWithMissingMarks = VoiceCommandTiming(
            pushToTalkReleasedAt: nil,
            transcriptReadyAt: released,
            screenStateReadyAt: released.addingTimeInterval(0.1),
            commandSentAt: released.addingTimeInterval(0.11),
            firstToolCallReceivedAt: released.addingTimeInterval(0.9),
            firstLineAudioStartedAt: nil
        )
        #expect(timingWithMissingMarks.logLine == "release_to_transcript_ms=- release_to_screen_state_ms=- transcript_to_request_ms=110 request_to_first_call_ms=790 first_call_to_first_line_ms=- release_to_first_line_ms=-")
    }

    @Test func theReleaseOfAPressIgnoredDuringTheTailStartsNoRead() {
        var acceptance = PushToTalkPressAcceptance()
        // A press the shortcut handler accepted: its release stamps the time and starts the read, once.
        acceptance.pressWasAccepted()
        let acceptedPressRelease = acceptance.releaseEndsAnAcceptedPress()
        // A press that arrived during the microphone's tail was ignored, so its release comes with no accepted press.
        let ignoredPressRelease = acceptance.releaseEndsAnAcceptedPress()
        // The next accepted press counts again.
        acceptance.pressWasAccepted()
        let nextAcceptedPressRelease = acceptance.releaseEndsAnAcceptedPress()
        // A release with no press at all counts for nothing.
        var acceptanceWithNoPress = PushToTalkPressAcceptance()
        let releaseWithNoPress = acceptanceWithNoPress.releaseEndsAnAcceptedPress()
        #expect(acceptedPressRelease)
        #expect(!ignoredPressRelease)
        #expect(nextAcceptedPressRelease)
        #expect(!releaseWithNoPress)
    }

    @MainActor
    @Test func theFirstMarkOfEachKindWins() {
        let recorder = VoiceCommandTimingRecorder(pushToTalkReleasedAt: released, transcriptReadyAt: released.addingTimeInterval(0.7))
        recorder.mark(\.commandSentAt, at: released.addingTimeInterval(0.8))
        // The old path's resend after a refused app secret sends the same command again.
        recorder.mark(\.commandSentAt, at: released.addingTimeInterval(3))
        #expect(recorder.timing.commandSentAt == released.addingTimeInterval(0.8))
    }
}

@MainActor
struct VoiceCommandScreenReadTests {
    private let pageIdentity = VoiceCommandPageIdentity(overlayIsShowingAScene: true, scenesPlayedCount: 3, pageKind: .framePopout)

    private func screenRead(pressCount: Int, pageIdentity: VoiceCommandPageIdentity? = nil, frontVideoState: JSONValue? = .object(["paused": .bool(false)])) -> VoiceCommandScreenRead {
        VoiceCommandScreenRead(
            pressCount: pressCount,
            pageIdentityAtRelease: pageIdentity ?? self.pageIdentity,
            frontVideoState: frontVideoState,
            pageRead: Task {
                VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: Date())
            }
        )
    }

    @Test func aTranscriptUsesOnlyTheReadOfItsOwnPress() {
        #expect(screenReadForTheTranscript(of: 4, from: screenRead(pressCount: 4), currentPageIdentity: pageIdentity)?.pressCount == 4)
        // A read from an older press, or no read, is never used for a newer press's transcript.
        #expect(screenReadForTheTranscript(of: 5, from: screenRead(pressCount: 4), currentPageIdentity: pageIdentity) == nil)
        #expect(screenReadForTheTranscript(of: 4, from: nil, currentPageIdentity: pageIdentity) == nil)
    }

    @Test func aReadOfAPageThatIsGoneIsDropped() {
        let read = screenRead(pressCount: 4)
        // Escape cleared the pop-out, or its return finished, during the microphone's tail.
        let sceneCleared = VoiceCommandPageIdentity(overlayIsShowingAScene: false, scenesPlayedCount: 3, pageKind: .framePopout)
        #expect(screenReadForTheTranscript(of: 4, from: read, currentPageIdentity: sceneCleared) == nil)
        // A new scene started: the overlay shows a scene again, but it is another page.
        let newSceneStarted = VoiceCommandPageIdentity(overlayIsShowingAScene: true, scenesPlayedCount: 4, pageKind: .framePopout)
        #expect(screenReadForTheTranscript(of: 4, from: read, currentPageIdentity: newSceneStarted) == nil)
        // Clicky's own record of the page changed while the overlay still shows a scene.
        let otherKind = VoiceCommandPageIdentity(overlayIsShowingAScene: true, scenesPlayedCount: 3, pageKind: .simulation)
        #expect(screenReadForTheTranscript(of: 4, from: read, currentPageIdentity: otherKind) == nil)
    }

    @Test func aReleaseReadsTheScreenOnlyWhenNoQuizQuestionIsOpenAndNoSceneIsBuilding() {
        #expect(screenReadStartsAtRelease(phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false))
        #expect(!screenReadStartsAtRelease(phaseIsWaitingForAQuizAnswer: true, sceneIsBuilding: false))
        #expect(!screenReadStartsAtRelease(phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: true))
        #expect(!screenReadStartsAtRelease(phaseIsWaitingForAQuizAnswer: true, sceneIsBuilding: true))
    }

    @Test func theFrontVideoStateComesFromTheReleaseOrAFreshReadUnlessAQuizOrABuildHoldsIt() {
        let readWithAVideo = screenRead(pressCount: 4)
        let readWithNoVideo = screenRead(pressCount: 4, frontVideoState: nil)
        // The read of the release wins, and a release that found no video stays "no video" without reading again.
        #expect(frontVideoStateSourceForTheTranscript(phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, screenReadAtRelease: readWithAVideo) == .fromTheRelease(.object(["paused": .bool(false)])))
        #expect(frontVideoStateSourceForTheTranscript(phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, screenReadAtRelease: readWithNoVideo) == .fromTheRelease(nil))
        // With no usable read the video is read now.
        #expect(frontVideoStateSourceForTheTranscript(phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: false, screenReadAtRelease: nil) == .readNow)
        // A quiz answer or a building scene reads no video, whatever the release found.
        #expect(frontVideoStateSourceForTheTranscript(phaseIsWaitingForAQuizAnswer: true, sceneIsBuilding: false, screenReadAtRelease: readWithAVideo) == .noVideoIsRead)
        #expect(frontVideoStateSourceForTheTranscript(phaseIsWaitingForAQuizAnswer: false, sceneIsBuilding: true, screenReadAtRelease: nil) == .noVideoIsRead)
    }
}
