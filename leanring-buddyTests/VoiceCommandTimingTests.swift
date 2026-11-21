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

    @MainActor
    @Test func theFirstMarkOfEachKindWins() {
        let recorder = VoiceCommandTimingRecorder(pushToTalkReleasedAt: released, transcriptReadyAt: released.addingTimeInterval(0.7))
        recorder.mark(\.commandSentAt, at: released.addingTimeInterval(0.8))
        // The old path's resend after a refused app secret sends the same command again.
        recorder.mark(\.commandSentAt, at: released.addingTimeInterval(3))
        #expect(recorder.timing.commandSentAt == released.addingTimeInterval(0.8))
    }
}

struct VoiceCommandScreenReadTests {
    private func screenRead(pressCount: Int) -> VoiceCommandScreenRead {
        VoiceCommandScreenRead(
            pressCount: pressCount,
            frontVideoState: .object(["paused": .bool(false)]),
            pageRead: Task {
                VoiceCommandPageRead(pageTools: [], pageState: nil, studyGuideExistsForTheFrontVideo: false, finishedAt: Date())
            }
        )
    }

    @Test func aTranscriptUsesOnlyTheReadOfItsOwnPress() {
        #expect(screenReadForTheTranscript(of: 4, from: screenRead(pressCount: 4))?.pressCount == 4)
        // A read from an older press, or no read, is never used for a newer press's transcript.
        #expect(screenReadForTheTranscript(of: 5, from: screenRead(pressCount: 4)) == nil)
        #expect(screenReadForTheTranscript(of: 4, from: nil) == nil)
    }
}
