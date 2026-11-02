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

    @Test func watchAlongVoiceCommandStartsOnItsPhrasesAndStopsOnStopWatching() async throws {
        #expect(watchAlongVoiceCommand(for: "Hey Clicky, watch this with me.") == .start)
        #expect(watchAlongVoiceCommand(for: "can we watch along?") == .start)
        #expect(watchAlongVoiceCommand(for: "Okay, stop watching.") == .stop)
        #expect(watchAlongVoiceCommand(for: "what does the heart do") == nil)
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

    @Test func onlyAnExplicitQuizRequestStartsTheQuiz() async throws {
        #expect(fieldTripSceneKind(for: "What does this look like inside?") == .explore)
        #expect(fieldTripSceneKind(for: "Can you quiz me on it?") == .quiz)
        #expect(fieldTripSceneKind(for: "show me inside and test me on it") == .quiz)
        #expect(fieldTripSceneKind(for: "what's on the latest menu") == nil)
    }

}
