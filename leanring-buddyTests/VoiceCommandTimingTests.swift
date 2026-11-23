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
        #expect(timing.logLine == "release_to_transcript_ms=700 release_to_screen_state_ms=300 transcript_to_request_ms=20 request_to_first_call_ms=780 first_call_to_first_line_ms=600 release_to_first_line_ms=2100 line_audio=- speculation=none")

        // A hand-off command speaks no line itself, and a command with no press has no release.
        let timingWithMissingMarks = VoiceCommandTiming(
            pushToTalkReleasedAt: nil,
            transcriptReadyAt: released,
            screenStateReadyAt: released.addingTimeInterval(0.1),
            commandSentAt: released.addingTimeInterval(0.11),
            firstToolCallReceivedAt: released.addingTimeInterval(0.9),
            firstLineAudioStartedAt: nil
        )
        #expect(timingWithMissingMarks.logLine == "release_to_transcript_ms=- release_to_screen_state_ms=- transcript_to_request_ms=110 request_to_first_call_ms=790 first_call_to_first_line_ms=- release_to_first_line_ms=- line_audio=- speculation=none")
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
        // A second mark of the same kind, such as the one a later tool call makes, changes nothing.
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

    // The rehearsal's `^` step presses only after the command's line has gone to the harness, so a press during the release
    // read is pinned here, on the function the command awaits that read through.
    private func slowPageRead() -> (read: Task<VoiceCommandPageRead, Never>, finishTheRead: () -> Void, readHasStarted: AsyncStream<Void>) {
        let (readIsAllowedToFinish, finishTheRead) = AsyncStream<Void>.makeStream()
        let (readHasStarted, readStarted) = AsyncStream<Void>.makeStream()
        let read = Task {
            readStarted.yield()
            // The stream ends when the read is cancelled, as the study guide check's wait does. The deadline keeps a command
            // whose cancel never reaches the read from hanging the test run, so it fails on `isCancelled` instead.
            let deadline = Task { try? await Task.sleep(for: .seconds(2)); finishTheRead.yield() }
            for await _ in readIsAllowedToFinish { break }
            deadline.cancel()
            return VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: Date())
        }
        return (read, { finishTheRead.yield() }, readHasStarted)
    }

    @Test func aPressDuringTheReleaseReadSendsNoCommand() async {
        let (read, _, readHasStarted) = slowPageRead()
        let command = Task { await pageReadForTheVoiceCommand(startedAtRelease: read, readNow: { fatalError("the release read exists") }) }
        // The press comes while the command is waiting on a read that is running, as a press during a hung study guide
        // check does, so the read must have started and the command must have reached its wait before the cancel.
        for await _ in readHasStarted { break }
        await Task.yield()
        command.cancel()
        #expect(await command.value == nil)
        #expect(read.isCancelled, "the press must stop the read too, since a hung study guide check would hold the command up")
    }

    @Test func aPressDuringAFreshReadSendsNoCommand() async {
        let command = Task {
            await pageReadForTheVoiceCommand(startedAtRelease: nil, readNow: {
                // The command is cancelled before or during the fresh read, and the check after it returns nil either way.
                while !Task.isCancelled { await Task.yield() }
                return VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: Date())
            })
        }
        command.cancel()
        #expect(await command.value == nil)
    }

    @Test func aCommandNobodyCancelledGetsTheReleaseReadOrAFreshOne() async {
        let (read, finishTheRead, _) = slowPageRead()
        let commandWithARead = Task { await pageReadForTheVoiceCommand(startedAtRelease: read, readNow: { fatalError("the release read exists") }) }
        finishTheRead()
        #expect(await commandWithARead.value != nil)
        let freshReadTime = Date(timeIntervalSince1970: 42)
        let commandWithNoRead = await pageReadForTheVoiceCommand(startedAtRelease: nil, readNow: {
            VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: freshReadTime)
        })
        #expect(commandWithNoRead?.finishedAt == freshReadTime)
    }
}
