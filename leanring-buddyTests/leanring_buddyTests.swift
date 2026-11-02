//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func videoQuizVoiceCommandNeedsAVideoWordAndAQuizWordToStart() async throws {
        #expect(videoQuizVoiceCommand(for: "Hey Clicky, can you watch this video with me and quiz me on the important parts?") == .start)
        #expect(videoQuizVoiceCommand(for: "quiz me on this video") == .start)
        #expect(videoQuizVoiceCommand(for: "test me on the video") == .start)
        #expect(videoQuizVoiceCommand(for: "Hey Clicky, watch this with me.") == nil)
        #expect(videoQuizVoiceCommand(for: "can we watch along?") == nil)
        #expect(videoQuizVoiceCommand(for: "quiz me on the heart") == nil)
        #expect(videoQuizVoiceCommand(for: "what does the heart do") == nil)
    }

    @Test func videoQuizVoiceCommandStopsOnStopQuizzingOrStopWatching() async throws {
        #expect(videoQuizVoiceCommand(for: "Okay, stop quizzing.") == .stop)
        #expect(videoQuizVoiceCommand(for: "stop watching") == .stop)
        #expect(videoQuizVoiceCommand(for: "stop watching the video and quizzing me") == .stop)
    }

    @Test func videoQuizAsksAMomentOnlyWhenTheVideoIsJustPastItAndItIsNotAnswered() async throws {
        let pauseAtSecondsPerMoment: [Double] = [30, 90, 150]

        #expect(videoQuizMomentIndexToAsk(currentSeconds: 29.9, pauseAtSecondsPerMoment: pauseAtSecondsPerMoment, askedMomentIndices: []) == nil)
        #expect(videoQuizMomentIndexToAsk(currentSeconds: 30.3, pauseAtSecondsPerMoment: pauseAtSecondsPerMoment, askedMomentIndices: []) == 0)
        #expect(videoQuizMomentIndexToAsk(currentSeconds: 34.9, pauseAtSecondsPerMoment: pauseAtSecondsPerMoment, askedMomentIndices: []) == 0)
        #expect(videoQuizMomentIndexToAsk(currentSeconds: 35.1, pauseAtSecondsPerMoment: pauseAtSecondsPerMoment, askedMomentIndices: []) == nil)
        #expect(videoQuizMomentIndexToAsk(currentSeconds: 30.3, pauseAtSecondsPerMoment: pauseAtSecondsPerMoment, askedMomentIndices: [0]) == nil)
        #expect(videoQuizMomentIndexToAsk(currentSeconds: 91, pauseAtSecondsPerMoment: pauseAtSecondsPerMoment, askedMomentIndices: [0]) == 1)
    }

    @Test func videoQuizTranscriptLinesKeepTextEventsAndDropEmptyAndAppendEvents() async throws {
        let captionsJSON3Data = Data("""
        {"events":[{"tStartMs":0,"segs":[{"utf8":"\\n"}]},{"tStartMs":6495,"segs":[{"utf8":"For most of history,"}]},{"tStartMs":8485,"segs":[{"utf8":"humans had "},{"utf8":"no idea"}]},{"tStartMs":9000,"aAppend":1,"segs":[{"utf8":"extra"}]},{"tStartMs":9100}]}
        """.utf8)

        let transcriptLines = try videoQuizTranscriptLines(fromCaptionsJSON3Data: captionsJSON3Data)

        #expect(transcriptLines == [
            VideoQuizTranscriptLine(seconds: 6.5, text: "For most of history,"),
            VideoQuizTranscriptLine(seconds: 8.5, text: "humans had no idea"),
        ])
    }

    @Test func fieldTripAnswerJudgeAcceptsTheHeartAndRejectsTheLungs() async throws {
        let heartAnswerIsCorrect = FieldTripAnswerJudge.isCorrect(
            transcript: "it's the heart",
            answerLabel: "Heart"
        )
        let lungsAnswerIsCorrect = FieldTripAnswerJudge.isCorrect(
            transcript: "the lungs",
            answerLabel: "Heart"
        )

        #expect(heartAnswerIsCorrect)
        #expect(lungsAnswerIsCorrect == false)
    }

    @Test func fieldTripQuizGradeCoversNameAndFunctionNameOnlyAndWrong() async throws {
        let heartQuiz = FieldTripQuiz(
            answerLabel: "Heart",
            question: "What organ is this, and what does it do?",
            functionWords: ["pump", "pumps", "pumping", "blood", "circulate", "circulates", "beats"],
            explanation: "That's the heart, and it pumps blood through the whale's whole body."
        )
        let quizWithNoFunctionWords = FieldTripQuiz(
            answerLabel: "Heart",
            question: "Which organ is this?",
            functionWords: [],
            explanation: ""
        )

        let nameAndFunctionGrade = FieldTripAnswerJudge.gradeSpokenAnswer(
            transcript: "it's the heart and it pumps",
            quiz: heartQuiz
        )
        let nameOnlyGrade = FieldTripAnswerJudge.gradeSpokenAnswer(
            transcript: "the heart",
            quiz: heartQuiz
        )
        let wrongGrade = FieldTripAnswerJudge.gradeSpokenAnswer(
            transcript: "the lungs",
            quiz: heartQuiz
        )
        let nameWithNoFunctionWordsGrade = FieldTripAnswerJudge.gradeSpokenAnswer(
            transcript: "the heart",
            quiz: quizWithNoFunctionWords
        )

        #expect(nameAndFunctionGrade == .nameAndFunctionWord)
        #expect(nameOnlyGrade == .nameOnly)
        #expect(wrongGrade == .wrong)
        #expect(nameWithNoFunctionWordsGrade == .nameAndFunctionWord)
    }

    @Test func spokenPartsSplitOnPartTags() async throws {
        let spokenParts = fieldTripSpokenParts(from: "[PART:Aorta] It carries blood. [PART:Heart] It pumps.")

        #expect(spokenParts.map(\.partLabel) == ["Aorta", "Heart"])
        #expect(spokenParts.map(\.spokenText) == ["It carries blood.", "It pumps."])
        #expect(fieldTripSpokenParts(from: "No tags here.").first?.partLabel == nil)
    }

    @Test func onlyAnExplicitQuizRequestStartsTheQuiz() async throws {
        #expect(fieldTripSceneKind(for: "What does this look like inside?") == .explore)
        #expect(fieldTripSceneKind(for: "Can I see that in 3D?") == .explore)
        #expect(fieldTripSceneKind(for: "Can you make a 3-D model of it?") == .explore)
        #expect(fieldTripSceneKind(for: "Can you quiz me on it?") == .quiz)
        #expect(fieldTripSceneKind(for: "Can you kiss me on it?") == .quiz)
        #expect(fieldTripSceneKind(for: "show me inside and test me on it") == .quiz)
        #expect(fieldTripSceneKind(for: "what's on the latest menu") == nil)
    }

}
