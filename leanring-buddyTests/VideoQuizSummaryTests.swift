//
//  VideoQuizSummaryTests.swift
//  leanring-buddyTests
//
//  The end of a video quiz: the score and the questions to look at again, the timestamps they show, where the Card sits
//  and Glides from, the hint offer after a first wrong answer, the scene stylesheet's user script, and the Card at 2x.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct VideoQuizSummaryTests {
    private func quizResult(_ question: String, at askedAtSeconds: Double, _ outcome: StudyGuideQuizOutcome) -> StudyGuideQuizResult {
        StudyGuideQuizResult(question: question, answerLabel: "vent", explanation: "Lava rises through it.", askedAtSeconds: askedAtSeconds, result: outcome)
    }

    // MARK: - The summary

    @Test func aQuizWithNoFinishedQuestionHasNoSummary() {
        #expect(VideoQuizSummary(quizResults: []) == nil)
    }

    @Test func theSummaryCountsTheRightAnswersAndListsMissesAndSkipsInVideoOrder() throws {
        let summary = try #require(VideoQuizSummary(quizResults: [
            quizResult("What is the chamber called?", at: 200, .missed),
            quizResult("What does the crater do?", at: 40, .gotIt),
            quizResult("What does the vent do?", at: 134, .skipped),
            quizResult("What is the ash cloud?", at: 300, .gotIt),
        ]))
        #expect(summary.scoreText == "2 of 4 right")
        #expect(summary.missedQuestions.map(\.question) == ["What does the vent do?", "What is the chamber called?"])
        #expect(summary.missedQuestions.map(\.timestampText) == ["2:14", "3:20"])
        #expect(summary.captionText == "2 to look at again. Click one to jump back to it.")
    }

    @Test func theCaptionSaysWhenEveryAnswerWasRightOrOneWasMissed() throws {
        let allRight = try #require(VideoQuizSummary(quizResults: [quizResult("A?", at: 30, .gotIt), quizResult("B?", at: 90, .gotIt)]))
        #expect(allRight.captionText == "You got every one right.")
        #expect(allRight.missedQuestions.isEmpty)
        let oneRight = try #require(VideoQuizSummary(quizResults: [quizResult("A?", at: 30, .gotIt)]))
        #expect(oneRight.captionText == "You got it right.")
        let oneMissed = try #require(VideoQuizSummary(quizResults: [quizResult("A?", at: 30, .missed)]))
        #expect(oneMissed.captionText == "One to look at again. Click it to jump back to it.")
    }

    @Test func aTimestampIsWrittenAsYouTubeWritesIt() {
        #expect(videoTimestampText(seconds: 0) == "0:00")
        #expect(videoTimestampText(seconds: 9.9) == "0:09")
        #expect(videoTimestampText(seconds: 134) == "2:14")
        #expect(videoTimestampText(seconds: 3725) == "1:02:05")
        #expect(videoTimestampText(seconds: -4) == "0:00")
        #expect(videoTimestampText(seconds: .nan) == "0:00")
    }

    // MARK: - Where the Card sits

    @Test func theCardIsCenteredOnTheVideoAndKeptInsideTheVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let cardSize = CGSize(width: 320, height: 200)
        let centered = videoQuizSummaryCardFrame(cardSize: cardSize, videoRect: CGRect(x: 200, y: 300, width: 800, height: 450), visibleFrame: visibleFrame)
        #expect(centered == CGRect(x: 440, y: 425, width: 320, height: 200))
        // A video in the top right corner still leaves the whole Card on screen, 12 points in.
        let nearTheCorner = videoQuizSummaryCardFrame(cardSize: cardSize, videoRect: CGRect(x: 1300, y: 800, width: 300, height: 200), visibleFrame: visibleFrame)
        #expect(nearTheCorner == CGRect(x: 1108, y: 663, width: 320, height: 200))
        let noVideo = videoQuizSummaryCardFrame(cardSize: cardSize, videoRect: nil, visibleFrame: visibleFrame)
        #expect(noVideo == CGRect(x: 560, y: 337.5, width: 320, height: 200))
    }

    @Test func theCardGlidesOutOfTheVideosTopEdgeOrTheMouseWithNoVideo() {
        let mouseLocation = CGPoint(x: 50, y: 60)
        #expect(videoQuizSummaryGlideOrigin(videoRect: CGRect(x: 200, y: 300, width: 800, height: 450), mouseLocation: mouseLocation) == CGPoint(x: 600, y: 750))
        #expect(videoQuizSummaryGlideOrigin(videoRect: nil, mouseLocation: mouseLocation) == mouseLocation)
    }

    @Test func aChromeRectIsFlippedIntoAppKitCoordinates() {
        let chromeRect = ScreenRectInChromeCoordinates(rectX: 100, rectY: 50, rectWidth: 640, rectHeight: 360)
        #expect(appKitRect(of: chromeRect, mainDisplayHeight: 900) == CGRect(x: 100, y: 490, width: 640, height: 360))
    }

    // MARK: - The hint offer

    @Test func aFirstWrongAnswerOffersAHintByNamingTheWordToSay() {
        #expect(firstWrongAnswerSpokenLine(judgeSpokenReply: "Not quite, that part sits under the volcano.")
            == "Not quite, that part sits under the volcano. Say hint if you want a clue.")
        #expect(firstWrongAnswerSpokenLine(judgeSpokenReply: "  ") == "Say hint if you want a clue.")
        // A sentence that already offers a hint or a clue is kept as it is.
        #expect(firstWrongAnswerSpokenLine(judgeSpokenReply: "Close. Want a Hint?") == "Close. Want a Hint?")
        #expect(firstWrongAnswerSpokenLine(judgeSpokenReply: "Close. Want a clue?") == "Close. Want a clue?")
    }

    // MARK: - The scene stylesheet

    @Test func theStylesheetScriptSetsTheAccentAndAddsTheStyleAheadOfThePage() {
        let script = sceneStyleUserScriptSource(
            styleSheet: ":root .scene-label { color: #fff; } /* \"</script> */",
            accentHex: "#E0313B"
        )
        #expect(script.contains(##"root.style.setProperty("--clicky-accent", "#E0313B");"##))
        // Text on the accent keeps the stylesheet's Tether ink, so the script never sets it from the theme.
        #expect(!script.contains("--clicky-accent-ink"))
        #expect(script.contains("root.prepend(style);"))
        // The stylesheet is a JSON string, so its quotes cannot end the script's string.
        #expect(script.contains(##"style.textContent = ":root .scene-label { color: #fff; } \/* \"<\/script> *\/";"##))
    }

    // MARK: - The panel

    @Test func theCardCountsAsShowingWhileItGlidesInSoEscapeCanCloseIt() throws {
        // The panel orders front only when the Glide lands, so a check on the window's visibility missed Escape during the Glide.
        try #require(!NSScreen.screens.isEmpty, "the test host has no screen to show the Card on")
        let summary = try #require(VideoQuizSummary(quizResults: [quizResult("What does the vent do?", at: 134, .missed)]))
        let controller = VideoQuizSummaryPanelController()
        #expect(!controller.isShowing)
        controller.show(summary: summary, videoRect: CGRect(x: 200, y: 300, width: 800, height: 450), accentColor: Color(hex: "#3380FF"), goBackToTheMissedQuestion: { _ in })
        #expect(controller.isShowing)
        controller.close(animated: false)
        #expect(!controller.isShowing)
    }

    // MARK: - The Card at 2x

    @Test func theCardIsDarkAndThreeHundredTwentyPointsWideOnAWhitePage() throws {
        let summary = try #require(VideoQuizSummary(quizResults: [
            quizResult("What does the vent do when the pressure under the volcano builds up for a long time?", at: 134, .missed),
            quizResult("What is this?", at: 40, .gotIt),
        ]))
        let card = VideoQuizSummaryCardView(summary: summary, accentColor: Color(hex: "#3380FF"), goBackToTheMissedQuestion: { _ in }, close: {})
        let renderer = ImageRenderer(content: card.padding(30).background(Color.white))
        renderer.scale = 2
        let pixels = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        #expect(pixels.pixelsWide == (30 + 320 + 30) * 2)
        let pageCorner = try #require(pixels.colorAt(x: 4, y: 4))
        #expect(pageCorner.redComponent > 0.98 && pageCorner.greenComponent > 0.98 && pageCorner.blueComponent > 0.98)
        // Just inside the Card's left edge, below its rounded corner, the surface is the Card's near black.
        let cardSurface = try #require(pixels.colorAt(x: (30 + 4) * 2, y: pixels.pixelsHigh / 2))
        #expect(cardSurface.redComponent < 0.12 && cardSurface.greenComponent < 0.12 && cardSurface.blueComponent < 0.15)
        // The Card ends inside the page's 30 point margin, so a long question wraps instead of widening it.
        let rightMargin = try #require(pixels.colorAt(x: pixels.pixelsWide - 20, y: pixels.pixelsHigh / 2))
        #expect(rightMargin.redComponent > 0.9)
    }
}
