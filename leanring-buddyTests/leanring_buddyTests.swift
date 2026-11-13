//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Clicky

@MainActor
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

    @Test func clickyHoldsAVideoPauseOnlyWhenItPausedTheVideoOrAlreadyHeldThePause() async throws {
        #expect(clickyHoldsTheVideoPauseAfterASceneRequest(videoIsPlaying: true, clickyAlreadyHoldsThePause: false))
        #expect(clickyHoldsTheVideoPauseAfterASceneRequest(videoIsPlaying: false, clickyAlreadyHoldsThePause: true))
        #expect(!clickyHoldsTheVideoPauseAfterASceneRequest(videoIsPlaying: false, clickyAlreadyHoldsThePause: false))
    }

    @Test func stoppingTheQuizPlaysTheVideoOnlyForAQuestionPauseClickyHolds() async throws {
        #expect(shouldPlayTheVideoWhenTheQuizStops(pauseHeldByClicky: .quizQuestion))
        #expect(!shouldPlayTheVideoWhenTheQuizStops(pauseHeldByClicky: .requestedScene))
        #expect(!shouldPlayTheVideoWhenTheQuizStops(pauseHeldByClicky: nil))
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

    @Test func imagePopoutCapturesTheDisplayUnderTheImageAtFullDensity() async throws {
        // A Retina main display, and a 1x display to its left that sits 200 points higher.
        let capturableDisplays = [
            CapturableDisplay(displayID: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixelsPerPoint: 2),
            CapturableDisplay(displayID: 2, frame: CGRect(x: -1920, y: -200, width: 1920, height: 1080), pixelsPerPoint: 1),
        ]

        let imageHangingOffTheLeftDisplay = ScreenRectInChromeCoordinates(rectX: -1950, rectY: 100, rectWidth: 600, rectHeight: 400)
        #expect(displayCaptureRegion(for: imageHangingOffTheLeftDisplay, on: capturableDisplays, longestSideLimitInPixels: 1280) == DisplayCaptureRegion(
            displayID: 2,
            sourceRectInDisplayPoints: CGRect(x: 0, y: 300, width: 570, height: 400),
            outputWidthInPixels: 570,
            outputHeightInPixels: 400,
            capturedScreenRect: ScreenRectInChromeCoordinates(rectX: -1920, rectY: 100, rectWidth: 570, rectHeight: 400)
        ))

        let largeImageOnTheRetinaDisplay = ScreenRectInChromeCoordinates(rectX: 100, rectY: 200, rectWidth: 800, rectHeight: 400)
        let retinaRegion = displayCaptureRegion(for: largeImageOnTheRetinaDisplay, on: capturableDisplays, longestSideLimitInPixels: 1280)
        #expect(retinaRegion?.sourceRectInDisplayPoints == CGRect(x: 100, y: 200, width: 800, height: 400))
        #expect(retinaRegion?.outputWidthInPixels == 1280)
        #expect(retinaRegion?.outputHeightInPixels == 640)

        // The center (-100, 1000) falls below the left display, in the gap beside the main display,
        // so the display holding the larger part of the image is chosen instead.
        let imageWithItsCenterInTheGapBetweenDisplays = ScreenRectInChromeCoordinates(rectX: -400, rectY: 900, rectWidth: 600, rectHeight: 200)
        #expect(displayCaptureRegion(for: imageWithItsCenterInTheGapBetweenDisplays, on: capturableDisplays, longestSideLimitInPixels: 1280) == DisplayCaptureRegion(
            displayID: 1,
            sourceRectInDisplayPoints: CGRect(x: 0, y: 900, width: 200, height: 200),
            outputWidthInPixels: 400,
            outputHeightInPixels: 400,
            capturedScreenRect: ScreenRectInChromeCoordinates(rectX: 0, rectY: 900, rectWidth: 200, rectHeight: 200)
        ))

        let imageOffEveryDisplay = ScreenRectInChromeCoordinates(rectX: 5000, rectY: 5000, rectWidth: 300, rectHeight: 200)
        #expect(displayCaptureRegion(for: imageOffEveryDisplay, on: capturableDisplays, longestSideLimitInPixels: 1280) == nil)
    }

    @Test func pageZoomScalesTheImageRectAndDockedDevToolsGiveNoRect() async throws {
        // A 1400x900 point window on a 2x screen with 100 points of tab strip and toolbar above the page.
        func pageGeometry(devicePixelRatio: Double, innerWidth: Double, innerHeight: Double, left: Double, top: Double) -> ChromePageGeometry {
            ChromePageGeometry(
                screenX: 100, screenY: 50, outerWidth: 1400, outerHeight: 900,
                innerWidth: innerWidth, innerHeight: innerHeight, devicePixelRatio: devicePixelRatio,
                left: left, top: top, width: 400, height: 200
            )
        }

        // At 125% zoom a CSS pixel is 1.25 points, so the 1120x640 CSS viewport fills 1400x800 points.
        let zoomedGeometry = pageGeometry(devicePixelRatio: 2.5, innerWidth: 1120, innerHeight: 640, left: 80, top: 40)
        #expect(screenRectInChromeCoordinates(from: zoomedGeometry, backingScaleFactor: 2) == ScreenRectInChromeCoordinates(
            rectX: 200, rectY: 200, rectWidth: 500, rectHeight: 250
        ))

        // At zoom 1 the result is window origin + (outer - inner) + offset, the math before zoom was handled.
        let unzoomedGeometry = pageGeometry(devicePixelRatio: 2, innerWidth: 1400, innerHeight: 800, left: 80, top: 40)
        #expect(screenRectInChromeCoordinates(from: unzoomedGeometry, backingScaleFactor: 2) == ScreenRectInChromeCoordinates(
            rectX: 100 + (1400 - 1400) + 80, rectY: 50 + (900 - 800) + 40, rectWidth: 400, rectHeight: 200
        ))

        // DevTools docked to the right take 500 points of the window width.
        let sideDockedDevToolsGeometry = pageGeometry(devicePixelRatio: 2, innerWidth: 900, innerHeight: 800, left: 80, top: 40)
        #expect(screenRectInChromeCoordinates(from: sideDockedDevToolsGeometry, backingScaleFactor: 2) == nil)

        // DevTools docked to the bottom take 400 points of the window height.
        let bottomDockedDevToolsGeometry = pageGeometry(devicePixelRatio: 2, innerWidth: 1400, innerHeight: 400, left: 80, top: 40)
        #expect(screenRectInChromeCoordinates(from: bottomDockedDevToolsGeometry, backingScaleFactor: 2) == nil)

        // A backing scale factor of 1 for a 2x page doubles the zoom, so the viewport is wider than the window
        // and the browser frame comes out negative.
        #expect(screenRectInChromeCoordinates(from: unzoomedGeometry, backingScaleFactor: 1) == nil)
    }

    @Test func webAreaPlacesTheImageRectWithPanelsOnEitherSideOfThePage() async throws {
        // A 1400x900 point window at (100, 50). The page itself is 880x800 CSS pixels.
        func pageGeometry(devicePixelRatio: Double, innerWidth: Double, innerHeight: Double) -> ChromePageGeometry {
            ChromePageGeometry(
                screenX: 100, screenY: 50, outerWidth: 1400, outerHeight: 900,
                innerWidth: innerWidth, innerHeight: innerHeight, devicePixelRatio: devicePixelRatio,
                left: 80, top: 40, width: 400, height: 200
            )
        }

        // Vertical tabs take 200 points on the left and a side panel takes 320 on the right, so the web area
        // is narrower than the window and offset only on the left. The window-frame math cannot place this.
        let pageWebArea = CGRect(x: 300, y: 150, width: 880, height: 800)
        let pageBesideVerticalTabsAndSidePanel = pageGeometry(devicePixelRatio: 2, innerWidth: 880, innerHeight: 800)
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: [pageWebArea]) == ScreenRectInChromeCoordinates(
            rectX: 300 + 80, rectY: 150 + 40, rectWidth: 400, rectHeight: 200
        ))

        // At 125% zoom the 1120x640 CSS viewport fills a 1400x800 point web area, so a CSS pixel is 1.25 points.
        let zoomedWebArea = CGRect(x: 100, y: 150, width: 1400, height: 800)
        let zoomedPage = pageGeometry(devicePixelRatio: 2.5, innerWidth: 1120, innerHeight: 640)
        #expect(screenRectInChromeCoordinates(from: zoomedPage, matchingWebAreaFrames: [zoomedWebArea]) == ScreenRectInChromeCoordinates(
            rectX: 100 + 80 * 1.25, rectY: 150 + 40 * 1.25, rectWidth: 500, rectHeight: 250
        ))

        // Docked DevTools are a tall, narrow web area of their own, listed before the page's.
        let devToolsWebArea = CGRect(x: 1180, y: 150, width: 320, height: 800)
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: [devToolsWebArea, pageWebArea]) == ScreenRectInChromeCoordinates(
            rectX: 300 + 80, rectY: 150 + 40, rectWidth: 400, rectHeight: 200
        ))

        // The closest shape wins even when a near match is listed first, and a shape 3.5 percent away never matches.
        let webAreaTwoPercentWider = CGRect(x: 0, y: 0, width: 880 * 1.02, height: 800)
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: [webAreaTwoPercentWider, pageWebArea]) == ScreenRectInChromeCoordinates(
            rectX: 300 + 80, rectY: 150 + 40, rectWidth: 400, rectHeight: 200
        ))
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: [pageWebArea, webAreaTwoPercentWider]) == ScreenRectInChromeCoordinates(
            rectX: 300 + 80, rectY: 150 + 40, rectWidth: 400, rectHeight: 200
        ))
        let webAreaThreeAndAHalfPercentWider = CGRect(x: 0, y: 0, width: 880 * 1.035, height: 800)
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: [webAreaThreeAndAHalfPercentWider]) == nil)

        // With only the DevTools shape, or no web area at all, nothing matches the page.
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: [devToolsWebArea]) == nil)
        #expect(screenRectInChromeCoordinates(from: pageBesideVerticalTabsAndSidePanel, matchingWebAreaFrames: []) == nil)
    }

    @Test func popoutPlaysOnTheScreenShowingTheImageNotTheMouseScreen() async throws {
        // AppKit frames: the main display first, a display to its right that sits 200 points lower,
        // and a display above it, where Chrome's y is negative.
        let screenFramesInAppKitCoordinates = [
            CGRect(x: 0, y: 0, width: 1728, height: 1117),
            CGRect(x: 1728, y: -200, width: 1920, height: 1080),
            CGRect(x: 0, y: 1117, width: 1920, height: 1080),
        ]

        let imageMostlyOnTheRightDisplay = ScreenRectInChromeCoordinates(rectX: 1500, rectY: 400, rectWidth: 800, rectHeight: 400)
        #expect(indexOfTheScreenFrameHolding(imageMostlyOnTheRightDisplay, screenFramesInAppKitCoordinates: screenFramesInAppKitCoordinates) == 1)

        let imageOnTheDisplayAbove = ScreenRectInChromeCoordinates(rectX: 100, rectY: -700, rectWidth: 400, rectHeight: 400)
        #expect(indexOfTheScreenFrameHolding(imageOnTheDisplayAbove, screenFramesInAppKitCoordinates: screenFramesInAppKitCoordinates) == 2)

        // The center (1900, 200) sits above the right display, in the gap beside the main display,
        // but most of the image is on the main display.
        let imageWithItsCenterInTheGapBetweenScreens = ScreenRectInChromeCoordinates(rectX: 1500, rectY: 100, rectWidth: 800, rectHeight: 200)
        #expect(indexOfTheScreenFrameHolding(imageWithItsCenterInTheGapBetweenScreens, screenFramesInAppKitCoordinates: screenFramesInAppKitCoordinates) == 0)

        let imageOnTheMainDisplay = ScreenRectInChromeCoordinates(rectX: 100, rectY: 100, rectWidth: 400, rectHeight: 300)
        #expect(indexOfTheScreenFrameHolding(imageOnTheMainDisplay, screenFramesInAppKitCoordinates: screenFramesInAppKitCoordinates) == 0)

        let imageOffEveryScreen = ScreenRectInChromeCoordinates(rectX: 9000, rectY: 100, rectWidth: 400, rectHeight: 300)
        #expect(indexOfTheScreenFrameHolding(imageOffEveryScreen, screenFramesInAppKitCoordinates: screenFramesInAppKitCoordinates) == nil)
    }

    @Test func paintedScenePopoutLiftsTheWholePictureInItsBox() async throws {
        let pictureBox = VideoFramePopout.SubjectBox(left: 10, top: 20, right: 109, bottom: 69)
        let pictureMask = try #require(VideoFrameSubjectMask.wholePictureMask(frameWidth: 120, frameHeight: 80, pictureBox: pictureBox))
        #expect(pictureMask.boundingBox.left == 10 && pictureMask.boundingBox.bottom == 69)

        let maskImageSource = try #require(CGImageSourceCreateWithData(pictureMask.pngData as CFData, nil))
        let maskImage = try #require(CGImageSourceCreateImageAtIndex(maskImageSource, 0, nil))
        let maskPixelData = try #require(maskImage.dataProvider?.data) as Data
        func maskValue(x: Int, y: Int) -> UInt8 { maskPixelData[y * maskImage.bytesPerRow + x] }
        #expect(maskValue(x: 10, y: 20) == 255 && maskValue(x: 109, y: 69) == 255 && maskValue(x: 60, y: 45) == 255)
        #expect(maskValue(x: 9, y: 20) == 0 && maskValue(x: 110, y: 69) == 0 && maskValue(x: 10, y: 19) == 0 && maskValue(x: 10, y: 70) == 0)

        let boxPastTheFrame = VideoFramePopout.SubjectBox(left: 10, top: 20, right: 120, bottom: 69)
        #expect(VideoFrameSubjectMask.wholePictureMask(frameWidth: 120, frameHeight: 80, pictureBox: boxPastTheFrame) == nil)
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

    @Test func popOutCubeIsFlatAtEachEndOfItsLoopAndFullWhileTurning() async throws {
        let loopStart = PopOutCubePose.at(elapsedSeconds: 0)
        let midTurn = PopOutCubePose.at(elapsedSeconds: PopOutCubePose.loopSeconds * 0.5)
        let justBeforeTheLoopRepeats = PopOutCubePose.at(elapsedSeconds: PopOutCubePose.loopSeconds - 0.001)

        #expect(loopStart.depth == 0 && loopStart.turnDegrees == 0)
        #expect(midTurn.depth == 1)
        // The cube ends one full turn later and flat, so the repeat has no jump.
        #expect(justBeforeTheLoopRepeats.depth < 0.01)
        #expect(abs(justBeforeTheLoopRepeats.turnDegrees - 360) < 0.5)
    }

    @Test func transcriptLineIsFullyTypedWithTheCaretAtTheEndBeforeItClears() async throws {
        let statusLine = LiveSceneStatusLine.readingTheTranscript
        let letterCount = statusLine.displayedText.count
        func poses(atSeconds elapsedSeconds: Double) -> [StatusLetterPose] {
            (0..<letterCount).map { statusLine.letterPose(letterIndex: $0, letterCount: letterCount, elapsedSeconds: elapsedSeconds) }
        }

        let fullyTyped = poses(atSeconds: 2.0)
        #expect(fullyTyped.allSatisfy { $0.opacity == 1 })
        #expect(fullyTyped.indices.filter { fullyTyped[$0].showsCaret } == [letterCount - 1])

        let cleared = poses(atSeconds: 2.85)
        #expect(cleared.allSatisfy { $0.opacity == 0 })
    }

    @Test func statusLabelOwnersSwapAndHideOnlyTheirOwnLines() async throws {
        // A delayed swap after a press hid the label does not bring the label back.
        #expect(LiveSceneStatusLine.lineShowing(afterReplacing: .buildingYourScene, with: .almostThere, whileShowing: nil) == nil)
        // A swap does not take over another owner's line.
        #expect(LiveSceneStatusLine.lineShowing(afterReplacing: .buildingYourScene, with: .almostThere, whileShowing: .poppingItOut) == .poppingItOut)
        #expect(LiveSceneStatusLine.lineShowing(afterReplacing: .buildingYourScene, with: .almostThere, whileShowing: .buildingYourScene) == .almostThere)

        // A push-to-talk press passes no set and hides whatever shows.
        #expect(LiveSceneStatusLine.lineShowing(afterHidingOnlyIfShowingOneOf: nil, whileShowing: .pickingQuizSpots) == nil)
        // An owner hides its own lines and leaves other owners' lines up.
        #expect(LiveSceneStatusLine.lineShowing(afterHidingOnlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines, whileShowing: .almostThere) == nil)
        #expect(LiveSceneStatusLine.lineShowing(afterHidingOnlyIfShowingOneOf: LiveSceneStatusLine.sceneBuildLines, whileShowing: .poppingItOut) == .poppingItOut)
        #expect(LiveSceneStatusLine.lineShowing(afterHidingOnlyIfShowingOneOf: LiveSceneStatusLine.videoQuizPlanningLines, whileShowing: .readingYourScreen) == .readingYourScreen)

        // Each owner's set holds every line that owner shows, so none of its lines can be left up.
        #expect(LiveSceneStatusLine.popOutLines == [.poppingItOut])
        #expect(LiveSceneStatusLine.sceneBuildLines == [.readingYourScreen, .buildingYourScene, .almostThere])
        #expect(LiveSceneStatusLine.videoQuizPlanningLines == [.readingTheTranscript, .pickingQuizSpots])
    }


    @Test func gradesMapToTheRevealOutcomeTheQuizLabelPlays() async throws {
        #expect(LiveSceneRevealOutcome(grade: .nameAndFunctionWord, wrongAnswerCount: 0) == .celebrateCorrectName)
        #expect(LiveSceneRevealOutcome(grade: .nameOnly, wrongAnswerCount: 0) == .celebrateCorrectName)
        // A name that is right on the second try still celebrates.
        #expect(LiveSceneRevealOutcome(grade: .nameAndFunctionWord, wrongAnswerCount: 1) == .celebrateCorrectName)
        #expect(LiveSceneRevealOutcome(grade: .askedForHelp, wrongAnswerCount: 0) == .revealWithoutCelebration)
        // The first wrong answer keeps the "?", and the second reveals the name without a celebration.
        #expect(LiveSceneRevealOutcome(grade: .wrong, wrongAnswerCount: 0) == .shakeAndKeepTheQuestionMark)
        #expect(LiveSceneRevealOutcome(grade: .wrong, wrongAnswerCount: 1) == .revealWithoutCelebration)
        // The page receives these exact strings.
        #expect(LiveSceneRevealOutcome.celebrateCorrectName.rawValue == "celebrateCorrectName")
        #expect(LiveSceneRevealOutcome.shakeAndKeepTheQuestionMark.rawValue == "shakeAndKeepTheQuestionMark")
        #expect(LiveSceneRevealOutcome.revealWithoutCelebration.rawValue == "revealWithoutCelebration")
    }

    @Test func clearingAFramePopoutPlaysTheReturnAndASecondClearHidesAtOnce() async throws {
        var overlayPhase = LiveSceneOverlayPhase.showing(isFramePopout: true)
        #expect(overlayPhase.requestClear() == .playReturnThenHide)
        #expect(overlayPhase == .returningToSource)
        // A second Escape during the return hides immediately.
        #expect(overlayPhase.requestClear() == .hideNow)
        #expect(overlayPhase == .hidden)
        // A repeated clear does nothing.
        #expect(overlayPhase.requestClear() == .nothingToClear)
        #expect(overlayPhase == .hidden)
    }

    @Test func clearingAnyOtherPageHidesAtOnceWithNoReturn() async throws {
        var overlayPhase = LiveSceneOverlayPhase.showing(isFramePopout: false)
        #expect(overlayPhase.requestClear() == .hideNow)
        #expect(overlayPhase == .hidden)
    }

    @Test func theReturnHidesTheWindowOnceAndOnlyWhileItIsPlaying() async throws {
        var overlayPhase = LiveSceneOverlayPhase.showing(isFramePopout: true)
        #expect(!overlayPhase.finishReturn())
        _ = overlayPhase.requestClear()
        #expect(overlayPhase.finishReturn())
        #expect(overlayPhase == .hidden)
        // The fallback timer firing after returnFinished finds nothing to do.
        #expect(!overlayPhase.finishReturn())
        // A late returnFinished does not hide a scene that replaced the return.
        var replacedPhase = LiveSceneOverlayPhase.showing(isFramePopout: true)
        #expect(!replacedPhase.finishReturn())
        #expect(replacedPhase == .showing(isFramePopout: true))
    }

}
