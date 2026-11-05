//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Foundation
import Testing
@testable import Clicky

struct leanring_buddyTests {

    @MainActor @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @MainActor @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @MainActor @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
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

    @Test func videoQuizVoiceCommandStopsOnAStopWordRightBeforeQuiz() async throws {
        #expect(videoQuizVoiceCommand(for: "Hey Clicky, can we stop the quiz?") == .stop)
        #expect(videoQuizVoiceCommand(for: "end the video quiz") == .stop)
        #expect(videoQuizVoiceCommand(for: "cancel the quiz please") == .stop)
        #expect(videoQuizVoiceCommand(for: "I'm done with the quiz") == .stop)
        #expect(videoQuizVoiceCommand(for: "quiz me at the end of the video") == .start)
        #expect(videoQuizVoiceCommand(for: "Quit") == nil)
        #expect(videoQuizVoiceCommand(for: "Hey Clicky, can we stop the?") == .stop)
        #expect(videoQuizVoiceCommand(for: "let's stop here") == .stop)
        #expect(videoQuizVoiceCommand(for: "the valves stop blood from flowing back") == nil)
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

    @Test func liveSceneAnswerJudgeAcceptsTheHeartAndRejectsTheLungs() async throws {
        let heartAnswerIsCorrect = LiveSceneAnswerJudge.isCorrect(
            transcript: "it's the heart",
            answerLabel: "Heart"
        )
        let lungsAnswerIsCorrect = LiveSceneAnswerJudge.isCorrect(
            transcript: "the lungs",
            answerLabel: "Heart"
        )

        #expect(heartAnswerIsCorrect)
        #expect(lungsAnswerIsCorrect == false)
    }

    @Test func liveSceneQuizGradeCoversNameAndFunctionNameOnlyAndWrong() async throws {
        let heartQuiz = LiveSceneQuiz(
            answerLabel: "Heart",
            question: "What organ is this, and what does it do?",
            functionWords: ["pump", "pumps", "pumping", "blood", "circulate", "circulates", "beats"],
            explanation: "That's the heart, and it pumps blood through the whole body."
        )
        let quizWithNoFunctionWords = LiveSceneQuiz(
            answerLabel: "Heart",
            question: "Which organ is this?",
            functionWords: [],
            explanation: ""
        )

        let nameAndFunctionGrade = LiveSceneAnswerJudge.gradeSpokenAnswer(
            transcript: "it's the heart and it pumps",
            quiz: heartQuiz
        )
        let nameOnlyGrade = LiveSceneAnswerJudge.gradeSpokenAnswer(
            transcript: "the heart",
            quiz: heartQuiz
        )
        let wrongGrade = LiveSceneAnswerJudge.gradeSpokenAnswer(
            transcript: "the lungs",
            quiz: heartQuiz
        )
        let nameWithNoFunctionWordsGrade = LiveSceneAnswerJudge.gradeSpokenAnswer(
            transcript: "the heart",
            quiz: quizWithNoFunctionWords
        )

        #expect(nameAndFunctionGrade == .nameAndFunctionWord)
        #expect(nameOnlyGrade == .nameOnly)
        #expect(wrongGrade == .wrong)
        #expect(nameWithNoFunctionWordsGrade == .nameAndFunctionWord)
    }

    @Test func spokenPartsSplitOnPartTags() async throws {
        let spokenParts = liveSceneSpokenParts(from: "[PART:Aorta] It carries blood. [PART:Heart] It pumps.")

        #expect(spokenParts.map(\.partLabel) == ["Aorta", "Heart"])
        #expect(spokenParts.map(\.spokenText) == ["It carries blood.", "It pumps."])
        #expect(liveSceneSpokenParts(from: "No tags here.").first?.partLabel == nil)
    }

    @Test func onlyAnExplicitQuizRequestStartsTheQuiz() async throws {
        #expect(liveSceneKind(for: "What does this look like inside?") == .explore)
        #expect(liveSceneKind(for: "Can I see that in 3D?") == .explore)
        #expect(liveSceneKind(for: "Can you make a 3-D model of it?") == .explore)
        #expect(liveSceneKind(for: "Can you quiz me on it?") == .quiz)
        #expect(liveSceneKind(for: "Can you kiss me on it?") == .quiz)
        #expect(liveSceneKind(for: "show me inside and test me on it") == .quiz)
        #expect(liveSceneKind(for: "Hey Clicky, can you pop this out?") == .framePopout)
        #expect(liveSceneKind(for: "pop out a render of this") == .framePopout)
        #expect(liveSceneKind(for: "Hey Clicky, can you pop this heart out for me?") == .framePopout)
        #expect(liveSceneKind(for: "pop the whole diagram out") == .framePopout)
        #expect(liveSceneKind(for: "give me a pop-out of this") == .framePopout)
        #expect(liveSceneKind(for: "play some pop without the vocals") == nil)
        #expect(liveSceneKind(for: "that popped up on my screen") == nil)
        #expect(liveSceneKind(for: "what's on the latest menu") == nil)
    }

    @Test func renderAloneStartsA3DScene() async throws {
        #expect(liveSceneKind(for: "Hey Clicky, I've never been to the Colosseum. Could you render this for me?") == .explore)
        #expect(liveSceneKind(for: "can you make a rendering of it") == .explore)
        #expect(liveSceneKind(for: "Could you run this for me?") == nil)
        #expect(liveSceneKind(for: "the heart surrenders nothing") == nil)
    }

    @Test func liveSceneRiseScriptsGoBeforeTheLastBodyClose() async throws {
        let generatedPage = #"<html><body><script>var earlierClose = "</body>";</script></body></html>"#
        let risingPage = liveScenePageThatRisesFromTheSource(
            generatedPageHTML: generatedPage,
            screenJPEGBase64: "AAAA",
            sourceRectInOverlayPage: ["x": 200, "y": 150, "width": 640, "height": 360],
            riseScript: "RISE_SCRIPT_BODY"
        )
        #expect(risingPage.hasPrefix(#"<html><body><script>var earlierClose = "</body>";</script><script>window.__sceneRise = "#))
        #expect(risingPage.hasSuffix("<script>RISE_SCRIPT_BODY</script></body></html>"))
    }

    @Test func liveSceneRiseScriptsAreAppendedWhenThePageHasNoBodyClose() async throws {
        let risingPage = liveScenePageThatRisesFromTheSource(
            generatedPageHTML: "<canvas></canvas>",
            screenJPEGBase64: "AAAA",
            sourceRectInOverlayPage: ["x": 0, "y": 0, "width": 100, "height": 100],
            riseScript: "RISE_SCRIPT_BODY"
        )
        #expect(risingPage.hasPrefix("<canvas></canvas><script>window.__sceneRise = "))
        #expect(risingPage.hasSuffix("<script>RISE_SCRIPT_BODY</script>"))
    }

    @Test func liveSceneRiseDataKeepsTheRectAndCannotCloseTheScriptTag() async throws {
        let risingPage = liveScenePageThatRisesFromTheSource(
            generatedPageHTML: "<body></body>",
            screenJPEGBase64: "ab/cd+ef==",
            sourceRectInOverlayPage: ["x": 200.5, "y": -12, "width": 640, "height": 360.25],
            riseScript: "RISE_SCRIPT_BODY"
        )
        let dataStart = try #require(risingPage.range(of: "window.__sceneRise = "))
        let dataEnd = try #require(risingPage.range(of: ";</script>", range: dataStart.upperBound..<risingPage.endIndex))
        let dataText = String(risingPage[dataStart.upperBound..<dataEnd.lowerBound])
        #expect(!dataText.contains("</"))
        let sceneRiseData = try #require(
            try JSONSerialization.jsonObject(with: Data(dataText.utf8)) as? [String: Any]
        )
        #expect(sceneRiseData["screenDataURL"] as? String == "data:image/jpeg;base64,ab/cd+ef==")
        let sourceRect = try #require(sceneRiseData["sourceRect"] as? [String: Double])
        #expect(sourceRect == ["x": 200.5, "y": -12, "width": 640, "height": 360.25])
    }

}
