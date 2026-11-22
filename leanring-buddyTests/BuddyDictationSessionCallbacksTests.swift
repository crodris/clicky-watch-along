//
//  BuddyDictationSessionCallbacksTests.swift
//  leanring-buddyTests
//
//  A dictation session ends at most once: with its final transcript, or with none when the final transcript comes back
//  empty or the session is cancelled. A voice command started on the press's partial transcript waits for one of the two.
//

import Testing
@testable import Clicky

@MainActor
struct BuddyDictationSessionCallbacksTests {
    private final class Endings {
        var submitted: [String] = []
        var endedWithNoTranscript = 0
    }

    private func sessionCallbacks(recordingInto endings: Endings) -> BuddyDictationSessionCallbacks {
        BuddyDictationSessionCallbacks(
            updateDraftText: { _ in },
            submitDraftText: { finalDraftText in endings.submitted.append(finalDraftText) },
            endWithNoTranscript: { endings.endedWithNoTranscript += 1 }
        )
    }

    @Test func anEmptyFinalTranscriptEndsTheSessionWithNoTranscriptOnce() {
        let endings = Endings()
        let callbacks = sessionCallbacks(recordingInto: endings)
        callbacks.endWithTheFinalTranscript(finalDraftText: "", finalTranscriptText: "")
        // A recognition error that arrives after the session finished cancels nothing more.
        callbacks.endCancelled()
        callbacks.endWithTheFinalTranscript(finalDraftText: "", finalTranscriptText: "")
        #expect(endings.endedWithNoTranscript == 1)
        #expect(endings.submitted.isEmpty)
    }

    @Test func aFinalTranscriptIsSubmittedOnceAndACancelAfterItSaysNothing() {
        let endings = Endings()
        let callbacks = sessionCallbacks(recordingInto: endings)
        callbacks.endWithTheFinalTranscript(finalDraftText: "Turn it left", finalTranscriptText: "Turn it left")
        callbacks.endCancelled()
        #expect(endings.submitted == ["Turn it left"])
        #expect(endings.endedWithNoTranscript == 0)
    }

    @Test func aCancelledSessionEndsWithNoTranscriptOnce() {
        let endings = Endings()
        let callbacks = sessionCallbacks(recordingInto: endings)
        callbacks.endCancelled()
        callbacks.endCancelled()
        #expect(endings.endedWithNoTranscript == 1)
    }
}
