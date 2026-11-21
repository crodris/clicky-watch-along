//
//  TetherCalloutTests.swift
//  leanring-buddyTests
//
//  The Callout surfaces of Tether PR 4: where a Callout sits so its tail lands on the cursor, how it appears and leaves, how
//  a spoken sentence breaks into lines and which words are spoken, the status lines' letter motion, the chip's senders, and
//  every surface drawn at 2x.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct TetherCalloutTests {
    // MARK: - Placement

    @Test func aCalloutPanelPutsTheTailsTipOnTheTipPoint() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1710, height: 1107)
        let tipPoint = CGPoint(x: 600, y: 400)
        let panelOrigin = tetherCalloutPanelOrigin(tipPoint: tipPoint, calloutWidth: 200, panelHeight: 77, screenFrame: screenFrame)
        #expect(panelOrigin.x + tetherCalloutPanelMargin + tetherSingleLineCalloutTailTipX == tipPoint.x)
        #expect(panelOrigin.y + tetherCalloutPanelMargin == tipPoint.y)
    }

    @Test func aCalloutPanelSlidesLeftToStayOnTheScreenAndDownFromTheTop() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let nearTheRightEdge = tetherCalloutPanelOrigin(tipPoint: CGPoint(x: 990, y: 400), calloutWidth: 200, panelHeight: 77, screenFrame: screenFrame)
        #expect(nearTheRightEdge.x + tetherCalloutPanelMargin + 200 == screenFrame.maxX)
        let nearTheTop = tetherCalloutPanelOrigin(tipPoint: CGPoint(x: 500, y: 790), calloutWidth: 200, panelHeight: 77, screenFrame: screenFrame)
        #expect(nearTheTop.y + 77 == screenFrame.maxY)
        let nearTheBottom = tetherCalloutPanelOrigin(tipPoint: CGPoint(x: 500, y: 2), calloutWidth: 200, panelHeight: 77, screenFrame: screenFrame)
        #expect(nearTheBottom.y == screenFrame.minY)
    }

    @Test func theSpeechCalloutsTailPointsAtTheTriangleAndTheCalloutStaysOnTheScreen() {
        let screenSize = CGSize(width: 1000, height: 800)
        let calloutSize = CGSize(width: 200, height: 49)
        let cursorPosition = CGPoint(x: 400, y: 300)
        let center = speechCalloutCenter(cursorPosition: cursorPosition, calloutSize: calloutSize, screenSize: screenSize)
        // Overlay coordinates grow down: the tail's tip, at the callout's bottom, is just above the triangle.
        #expect(center.y + calloutSize.height / 2 == cursorPosition.y - tetherCalloutTipRiseAboveTheCursor)
        #expect(center.x - calloutSize.width / 2 + TetherCalloutShape.tailTip(inCalloutOfSize: calloutSize).x == cursorPosition.x)

        let nearTheRightEdge = speechCalloutCenter(cursorPosition: CGPoint(x: 980, y: 300), calloutSize: calloutSize, screenSize: screenSize)
        #expect(nearTheRightEdge.x + calloutSize.width / 2 <= screenSize.width)
        let nearTheTop = speechCalloutCenter(cursorPosition: CGPoint(x: 400, y: 20), calloutSize: calloutSize, screenSize: screenSize)
        #expect(nearTheTop.y - calloutSize.height / 2 >= 0)
    }

    // MARK: - Presence

    @Test func aCalloutPopsFromTheSpecsStartScaleAndLeavesByRiseOrRecall() {
        #expect(TetherCalloutPresencePose.appearing(reduceMotionIsOn: false) == TetherCalloutPresencePose(scale: DS.Move.popStartScale, opacity: 0, riseOffset: 0))
        #expect(TetherCalloutPresencePose.leaving(.fadeRise, reduceMotionIsOn: false) == TetherCalloutPresencePose(scale: 1, opacity: 0, riseOffset: -6))
        #expect(TetherCalloutPresencePose.leaving(.recall, reduceMotionIsOn: false).scale == DS.Move.recallEndScale)
    }

    @Test func withReduceMotionACalloutOnlyFadesInPlace() {
        let fadedPose = TetherCalloutPresencePose(scale: 1, opacity: 0, riseOffset: 0)
        #expect(TetherCalloutPresencePose.appearing(reduceMotionIsOn: true) == fadedPose)
        #expect(TetherCalloutPresencePose.leaving(.fadeRise, reduceMotionIsOn: true) == fadedPose)
        #expect(TetherCalloutPresencePose.leaving(.recall, reduceMotionIsOn: true) == fadedPose)
        for exit in [TetherCalloutExit.fadeRise, .recall] {
            #expect(tetherCalloutAnimation(isAppearing: true, exit: exit, reduceMotionIsOn: true) == DS.Move.pop.animation(reduceMotionIsOn: true))
            #expect(tetherCalloutAnimation(isAppearing: false, exit: exit, reduceMotionIsOn: true) == DS.Move.pop.animation(reduceMotionIsOn: true))
        }
    }

    @Test func theFailureShakeStartsAndEndsAtRestAndSwingsInBetween() {
        #expect(TetherCalloutShake.offsetPoints(secondsSinceTheShakeStarted: 0) == 0)
        #expect(TetherCalloutShake.offsetPoints(secondsSinceTheShakeStarted: DS.Move.shake.curve.seconds()) == 0)
        let swings = stride(from: 0.02, to: 0.4, by: 0.02).map { TetherCalloutShake.offsetPoints(secondsSinceTheShakeStarted: $0) }
        #expect(swings.contains { $0 > 1 } && swings.contains { $0 < -1 })
        #expect(swings.allSatisfy { abs($0) <= 7 })
    }

    // MARK: - Speech words

    /// A width of 10 points per character, so a test reads the wrap off the character count.
    private func tenPointsPerCharacter(_ text: String) -> CGFloat { CGFloat(text.count) * 10 }

    @Test func aSentenceWrapsAtWholeWordsWithOffsetsIntoTheSentence() {
        let sentence = "one two three four five"
        let lines = SpeechCalloutLayout.lines(of: sentence, wrapWidth: 130, measuredWidth: tenPointsPerCharacter)
        #expect(lines.map(\.text) == ["one two three", "four five"])
        for line in lines {
            #expect(tenPointsPerCharacter(line.text) <= 130)
            let sentenceCharacters = Array(sentence)
            #expect(String(sentenceCharacters[line.startOffset..<line.endOffset]) == line.text)
        }
    }

    @Test func aLastLineOfOneWordTakesTheWordAboveItWhenTheTwoFit() {
        // Greedy wrapping at 34 characters alone would leave "legs" alone under "the booster lands on the pad using".
        let lines = SpeechCalloutLayout.lines(of: "the booster lands on the pad using legs", wrapWidth: 340, measuredWidth: tenPointsPerCharacter)
        #expect(lines.map(\.text) == ["the booster lands on the pad", "using legs"])
        // When the two would not fit together within the width, the word stays where it is.
        let unmovable = SpeechCalloutLayout.lines(of: "a b ccc dddddddddd", wrapWidth: 100, measuredWidth: tenPointsPerCharacter)
        #expect(unmovable.map(\.text) == ["a b ccc", "dddddddddd"])
    }

    @Test func aSingleLongWordIsKeptWholeOnItsOwnLine() {
        let lines = SpeechCalloutLayout.lines(of: "pneumonoultramicroscopic ok", wrapWidth: 100, measuredWidth: tenPointsPerCharacter)
        #expect(lines.first?.text == "pneumonoultramicroscopic")
        #expect(SpeechCalloutLayout.lines(of: "   ", wrapWidth: 100, measuredWidth: tenPointsPerCharacter).isEmpty)
    }

    @Test func theRealFontWrapsALongSentenceAtThreeHundredPoints() {
        let sentence = "This giant fan pulls in huge amounts of air, and most of it flows around the engine core to push the plane forward."
        let lines = SpeechCalloutLayout.lines(of: sentence)
        #expect(lines.count >= 2)
        #expect(lines.allSatisfy { SpeechCalloutLayout.widthOnOneLine($0.text) <= SpeechCalloutLayout.wrapWidth })
        #expect(SpeechCalloutLayout.lines(of: "right here!").count == 1)
    }

    private func linesOfFiveWords() -> [SpeechCalloutLine] {
        (0..<5).map { SpeechCalloutLine(text: "line \($0)", startOffset: $0 * 7) }
    }

    @Test func aSentenceOfThreeLinesShowsWholeAndALongerOneScrollsKeepingTheLastCompleteLine() {
        let threeLines = Array(linesOfFiveWords().prefix(3))
        #expect(SpeechCalloutLayout.visibleLineRange(lines: threeLines, revealedCharacterCount: 1) == 0..<3)

        let fiveLines = linesOfFiveWords()
        #expect(SpeechCalloutLayout.visibleLineRange(lines: fiveLines, revealedCharacterCount: 1) == 0..<3)
        // Speaking the third line (offset 14 on): the second, which is complete, stays above it.
        #expect(SpeechCalloutLayout.visibleLineRange(lines: fiveLines, revealedCharacterCount: 16) == 1..<4)
        // Speaking the last line keeps the line above it.
        #expect(SpeechCalloutLayout.visibleLineRange(lines: fiveLines, revealedCharacterCount: 30) == 2..<5)
    }

    @Test func theUnderlinedWordIsTheOneHoldingTheLastSpokenCharacter() {
        let sentence = "the fan spins"
        #expect(SpeechCalloutLayout.currentWordRange(in: sentence, revealedCharacterCount: 0) == nil)
        #expect(SpeechCalloutLayout.currentWordRange(in: sentence, revealedCharacterCount: 1) == 0..<3)
        #expect(SpeechCalloutLayout.currentWordRange(in: sentence, revealedCharacterCount: 6) == 4..<7)
        // Just after a word's last letter is spoken, the space has been reached, so no word is underlined for that moment.
        #expect(SpeechCalloutLayout.currentWordRange(in: sentence, revealedCharacterCount: 4) == nil)
        // A finished sentence underlines nothing.
        #expect(SpeechCalloutLayout.currentWordRange(in: sentence, revealedCharacterCount: sentence.count) == nil)
    }

    @Test func spokenWordsAreWhiteAndUnspokenWordsAreSixtyPercentWhite() {
        let line = SpeechCalloutLine(text: "ab cd", startOffset: 0)
        let styledLine = SpeechCalloutLayout.styledText(of: line, revealedCharacterCount: 2, currentWordRange: 0..<2, accent: .red)
        let characters = Array(styledLine.characters)
        func color(at characterIndex: Int) -> Color? {
            let start = styledLine.index(styledLine.startIndex, offsetByCharacters: characterIndex)
            return styledLine[start..<styledLine.index(afterCharacter: start)].swiftUI.foregroundColor
        }
        func underline(at characterIndex: Int) -> Text.LineStyle? {
            let start = styledLine.index(styledLine.startIndex, offsetByCharacters: characterIndex)
            return styledLine[start..<styledLine.index(afterCharacter: start)].swiftUI.underlineStyle
        }
        #expect(characters.count == 5)
        #expect(color(at: 0) == Color.white)
        #expect(color(at: 3) == Color.white.opacity(0.6))
        #expect(underline(at: 1) != nil)
        #expect(underline(at: 3) == nil)
    }

    // MARK: - Status line letters

    @Test func everyStatusLineRisesLetterByLetterThenHoldsStill() {
        let start = StatusLineLetterRise.pose(letterIndex: 0, elapsedSeconds: 0)
        #expect(start.offsetY == 6 && start.opacity == 0)
        // Letter 10 has not started when letter 0 is half done: 18 ms per letter.
        let later = StatusLineLetterRise.pose(letterIndex: 10, elapsedSeconds: 0.1)
        #expect(later.offsetY == 6 && later.opacity == 0)
        let settled = StatusLineLetterRise.pose(letterIndex: 3, elapsedSeconds: StatusLineLetterRise.secondsUntilEveryLetterHasSettled(letterCount: 4))
        #expect(settled.offsetY == 0 && settled.opacity == 1)
        #expect(abs(StatusLineLetterRise.secondsUntilEveryLetterHasSettled(letterCount: 11) - (10 * 0.018 + StatusLineLetterRise.secondsPerLetter)) < 1e-9)
    }

    @Test func everyStatusLineHasItsOwnHueAndAnInkIconThatReadsOnIt() {
        let hues = LiveSceneStatusLine.allCases.map { $0.calloutAccent }
        #expect(Set(hues.map { "\($0)" }).count == hues.count)
        for statusLine in LiveSceneStatusLine.allCases {
            #expect(statusLine.palette.iconColor == DS.Colors.inkOnAccent)
            #expect(statusLine.palette.discColor == statusLine.calloutAccent)
        }
    }

    // MARK: - Chip senders

    @Test func aVoiceToolChipTakesTheThemeAccentAnAgentTakesItsColorAndAFailureIsRed() {
        let themeAccent = Color(hex: "#F2B53A")
        #expect(VoiceToolCallChipSender.voiceToolCall.accent(themeAccent: themeAccent) == themeAccent)
        #expect(VoiceToolCallChipSender.backgroundAgent(color: .teal, face: .triangle).accent(themeAccent: themeAccent) == AgentPaletteColor.teal.color)
        #expect(VoiceToolCallChipSender.failure.accent(themeAccent: themeAccent) == DS.Colors.destructiveText)
        // Only a failure shakes, and the cross is its icon, so Reduce Motion drops the shake and the failure still reads.
        #expect(VoiceToolCallChipSender.failure.shakesOnAppearing)
        #expect(!VoiceToolCallChipSender.voiceToolCall.shakesOnAppearing)
    }

    // MARK: - Drawn at 2x

    private func renderedPixels(of view: some View, onPage pageColor: Color = .white) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.padding(30).background(pageColor))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    /// Whether a pixel is within 3 of a `#rrggbb` color in every channel, so a color space conversion does not fail a render.
    private func pixel(_ color: NSColor?, isCloseTo expectedHex: String) -> Bool {
        guard let color, let expected = ThemeRGBColor(hex: expectedHex) else { return false }
        let pairs: [(CGFloat, Double)] = [(color.redComponent, expected.red), (color.greenComponent, expected.green), (color.blueComponent, expected.blue)]
        return pairs.allSatisfy { abs(Int(($0.0 * 255).rounded()) - Int(($0.1 * 255).rounded())) <= 3 }
    }

    /// The size a view takes at 2x, in points, found from its own render.
    private func size(of view: some View) -> CGSize {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { CGSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2) } ?? .zero
    }

    @Test func everyStatusLineFitsItsPanelAndShowsItsOwnHueInTheRimAndDisc() throws {
        let panelContentWidth = StatusLabelPlacement.panelSize.width - 2 * tetherCalloutPanelMargin
        for statusLine in LiveSceneStatusLine.allCases {
            let callout = LiveSceneStatusLabelContent(statusLine: statusLine, elapsedSeconds: statusLine.stillMomentSeconds, lettersAreStill: true)
            let calloutSize = size(of: callout)
            #expect(calloutSize.width <= panelContentWidth, "\(statusLine.text) is \(calloutSize.width) wide")
            #expect(calloutSize.height == tetherSingleLineCalloutHeight, "\(statusLine.text) is \(calloutSize.height) tall")

            let pixels = try renderedPixels(of: callout)
            // The Callout's own surface right of the disc, and the white page around it.
            let surface = pixels.colorAt(x: Int((30 + 7 + 26 + 4) * 2), y: Int((30 + 3) * 2))
            #expect(pixel(surface, isCloseTo: "#14171e"), "\(statusLine.text)")
            #expect(pixel(pixels.colorAt(x: 4, y: 4), isCloseTo: "#ffffff"))
            // The disc, a few points in from its left edge where no icon reaches, is the line's own hue.
            let disc = pixels.colorAt(x: Int((30 + 7 + 2) * 2), y: Int((30 + 7 + 13) * 2))
            #expect(disc != nil && !pixel(disc, isCloseTo: "#14171e"), "\(statusLine.text)")
        }
    }

    @Test func theThemeAddedChipRendersOnTheCalloutWithItsThemeNameInGray() throws {
        let accentHex = "#F2B53A"
        let chip = VoiceToolCallChipCallout(
            chipText: themeAddedChipPhrase,
            secondaryChipText: "Moonlit",
            sender: .voiceToolCall,
            themeAccent: Color(hex: accentHex)
        )
        let chipSize = size(of: chip)
        #expect(chipSize.height == tetherSingleLineCalloutHeight)
        #expect(chipSize.width < VoiceToolCallChip.panelSize.width - 2 * tetherCalloutPanelMargin)

        let pixels = try renderedPixels(of: chip)
        // A Callout surface sits right of the 26 point disc, and the page around it stays white.
        #expect(pixel(pixels.colorAt(x: Int((30 + 7 + 26 + 4) * 2), y: Int((30 + 3) * 2)), isCloseTo: "#14171e"))
        #expect(pixel(pixels.colorAt(x: 4, y: 4), isCloseTo: "#ffffff"))
        // The disc is the theme accent.
        #expect(pixel(pixels.colorAt(x: Int((30 + 7 + 3) * 2), y: Int((30 + 7 + 13) * 2)), isCloseTo: accentHex))
    }

    @Test func aFailureChipIsRedWithACrossAndAnAgentChipTakesItsColor() throws {
        let failure = VoiceToolCallChipCallout(chipText: "Couldn't build that one", sender: .failure, themeAccent: .blue)
        let failurePixels = try renderedPixels(of: failure)
        #expect(pixel(failurePixels.colorAt(x: Int((30 + 7 + 3) * 2), y: Int((30 + 7 + 13) * 2)), isCloseTo: "#ff6369"))

        let agent = VoiceToolCallChipCallout(
            chipText: "Task done",
            secondaryChipText: "· say what did you find",
            sender: .backgroundAgent(color: .teal, face: .triangle),
            themeAccent: .blue
        )
        let agentPixels = try renderedPixels(of: agent)
        #expect(pixel(agentPixels.colorAt(x: Int((30 + 7 + 3) * 2), y: Int((30 + 7 + 13) * 2)), isCloseTo: "#2dd4bf"))
    }

    @Test func aSpeechCalloutKeepsItsSizeWhileItsWordsBrightenAndStaysUnderThreeLines() throws {
        let sentence = "This giant fan pulls in huge amounts of air, and most of it flows around the engine core to push the plane forward."
        let accent = Color(hex: "#3380FF")
        let justStarted = SpeechCalloutView(sentence: sentence, revealedCharacterCount: 4, accent: accent)
        let nearlyDone = SpeechCalloutView(sentence: sentence, revealedCharacterCount: sentence.count - 3, accent: accent)
        #expect(size(of: justStarted) == size(of: nearlyDone))
        let speechSize = size(of: justStarted)
        // Wrapped at 300 points of words: the icon, its gap, and the padding add 7 + 26 + 8 + 15.
        #expect(speechSize.width <= SpeechCalloutLayout.wrapWidth + 56 + 1)
        let pixels = try renderedPixels(of: justStarted)
        #expect(pixel(pixels.colorAt(x: Int((30 + 7 + 26 + 4) * 2), y: Int((30 + 3) * 2)), isCloseTo: "#14171e"))
    }
}
