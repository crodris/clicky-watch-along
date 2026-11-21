//
//  TetherCalloutViews.swift
//  leanring-buddy
//
//  What every surface that speaks near the cursor shares: where a Callout sits so its tail lands on the cursor, how its
//  presence animates in and out (the Pop, the fade-rise, and the Recall), how a spoken sentence is broken into lines and
//  which words are spoken, and the speech Callout itself. The status label, the chips, and the pointing bubble all draw
//  on `TetherCallout`, so the look is one place (`TetherMaterials.swift`) and the behavior is here.
//
//  Each rule is a pure function, so a test checks it without a window.
//

import AppKit
import SwiftUI

// MARK: - Where a Callout sits

/// The room around a Callout inside its panel, for the accent halo and the drop shadow (a 9 point blur and a 5 point blur
/// offset 3 down), so the panel does not clip either.
let tetherCalloutPanelMargin: CGFloat = 14

/// The height of a Callout whose words fit on one line: the 26 point icon disc, 7 points of padding above and below it, and
/// the tail.
let tetherSingleLineCalloutHeight: CGFloat = TetherCallout<EmptyView, EmptyView>.iconDiscDiameter + 14 + TetherCalloutShape.tailHeight

/// How far the tail's tip sits from the left edge of a one-line Callout. A Callout of more lines has taller corners, so
/// it has its own tip (`TetherCalloutShape.tailTip`).
let tetherSingleLineCalloutTailTipX: CGFloat = TetherCalloutShape.tailTip(inCalloutOfSize: CGSize(width: 100, height: tetherSingleLineCalloutHeight)).x

/// How far above the cursor's triangle the tail's tip lands, so the tail points at the triangle and does not cover it.
let tetherCalloutTipRiseAboveTheCursor: CGFloat = 12

/// The bottom-left corner of a Callout panel in AppKit screen points (y grows up), so the tail's tip lands on `tipPoint`.
/// The Callout sits at the panel's bottom left, `tetherCalloutPanelMargin` in from each edge. A Callout that would run past
/// the screen's right edge moves left, and the tail then points at the cursor from a little to its right.
func tetherCalloutPanelOrigin(tipPoint: CGPoint, calloutWidth: CGFloat, panelHeight: CGFloat, screenFrame: CGRect) -> CGPoint {
    let calloutLeftEdge = min(
        max(tipPoint.x - tetherSingleLineCalloutTailTipX, screenFrame.minX),
        max(screenFrame.maxX - calloutWidth, screenFrame.minX)
    )
    let panelBottom = min(tipPoint.y - tetherCalloutPanelMargin, screenFrame.maxY - panelHeight)
    return CGPoint(x: calloutLeftEdge - tetherCalloutPanelMargin, y: max(panelBottom, screenFrame.minY))
}

/// The center of a Callout in the cursor overlay's coordinates (y grows down), so its tail's tip sits just above the
/// triangle at `cursorPosition`. It slides left to stay inside the screen and down if it would pass the top.
func speechCalloutCenter(cursorPosition: CGPoint, calloutSize: CGSize, screenSize: CGSize) -> CGPoint {
    let tipX = cursorPosition.x
    let tipY = cursorPosition.y - tetherCalloutTipRiseAboveTheCursor
    let tailTipX = TetherCalloutShape.tailTip(inCalloutOfSize: calloutSize).x
    let screenEdgeMargin: CGFloat = 8
    let leftEdge = min(max(tipX - tailTipX, screenEdgeMargin), max(screenSize.width - screenEdgeMargin - calloutSize.width, screenEdgeMargin))
    let centerY = max(tipY - calloutSize.height / 2, calloutSize.height / 2)
    return CGPoint(x: leftEdge + calloutSize.width / 2, y: centerY)
}

// MARK: - Presence: Pop in, fade-rise out, Recall

/// How a Callout leaves.
enum TetherCalloutExit: Equatable {
    /// It finishes or times out: a 6 point rise and a fade, in 0.7 of the Pop's time.
    case fadeRise
    /// The learner interrupts: it shrinks into the cursor in 180 ms (`DS.Move.recall`).
    case recall
}

/// One pose of a Callout while it appears or leaves, drawn about the tail's tip so the tail stays on the cursor.
struct TetherCalloutPresencePose: Equatable {
    var scale: CGFloat
    var opacity: Double
    var riseOffset: CGFloat

    static let resting = TetherCalloutPresencePose(scale: 1, opacity: 1, riseOffset: 0)

    /// The pose a Callout pops in from.
    static let popStart = TetherCalloutPresencePose(scale: DS.Move.popStartScale, opacity: 0, riseOffset: 0)

    /// How far a leaving Callout rises.
    static let risePoints: CGFloat = 6

    /// The pose a Callout leaves to. With Reduce Motion on nothing moves, so the Callout only fades.
    static func leaving(_ exit: TetherCalloutExit, reduceMotionIsOn: Bool) -> TetherCalloutPresencePose {
        if reduceMotionIsOn { return TetherCalloutPresencePose(scale: 1, opacity: 0, riseOffset: 0) }
        switch exit {
        case .fadeRise: return TetherCalloutPresencePose(scale: 1, opacity: 0, riseOffset: -risePoints)
        case .recall: return TetherCalloutPresencePose(scale: DS.Move.recallEndScale, opacity: 0, riseOffset: 0)
        }
    }

    /// The pose a Callout appears from. With Reduce Motion on it fades in place.
    static func appearing(reduceMotionIsOn: Bool) -> TetherCalloutPresencePose {
        reduceMotionIsOn ? TetherCalloutPresencePose(scale: 1, opacity: 0, riseOffset: 0) : popStart
    }
}

/// The animation a Callout plays as it appears (`isAppearing`) or leaves. A Pop is a spring, and a leave is the Pop's time
/// times 0.7, or the Recall's 180 ms. Reduce Motion gives the one 150 ms crossfade both ways.
func tetherCalloutAnimation(isAppearing: Bool, exit: TetherCalloutExit, reduceMotionIsOn: Bool) -> Animation? {
    if reduceMotionIsOn { return DS.Move.pop.animation(reduceMotionIsOn: true) }
    if isAppearing { return DS.Move.pop.animation(reduceMotionIsOn: false) }
    switch exit {
    case .fadeRise:
        return .easeIn(duration: DS.Move.pop.curve.seconds() * 0.7)
    case .recall:
        return DS.Move.recall.animation(reduceMotionIsOn: false)
    }
}

private struct TetherCalloutPresenceEffect: ViewModifier {
    let pose: TetherCalloutPresencePose

    func body(content: Content) -> some View {
        content
            // The pivot is the tail's tip, found from the Callout's own width, so a Pop or a Recall keeps the tail where it is.
            .visualEffect { calloutContent, geometry in
                let tipX = TetherCalloutShape.tailTip(inCalloutOfSize: geometry.size).x
                return calloutContent
                    .scaleEffect(pose.scale, anchor: UnitPoint(x: tipX / max(geometry.size.width, 1), y: 1))
            }
            .offset(y: pose.riseOffset)
            .opacity(pose.opacity)
    }
}

extension AnyTransition {
    /// How a Callout enters and leaves the view tree: a Pop out of its tail's tip, and a fade-rise or Recall out. With
    /// Reduce Motion on, both are a fade in place.
    static func tetherCallout(exit: TetherCalloutExit, reduceMotionIsOn: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: TetherCalloutPresenceEffect(pose: .appearing(reduceMotionIsOn: reduceMotionIsOn)),
                identity: TetherCalloutPresenceEffect(pose: .resting)
            ),
            removal: .modifier(
                active: TetherCalloutPresenceEffect(pose: .leaving(exit, reduceMotionIsOn: reduceMotionIsOn)),
                identity: TetherCalloutPresenceEffect(pose: .resting)
            )
        )
    }
}

/// A failure's one small shake: the Callout swings sideways and settles (`DS.Move.shake`). Reduce Motion drops the shake, so
/// the red accent and the cross in the icon disc carry the failure.
struct TetherCalloutShake: ViewModifier {
    /// When the shake started, or nil when the Callout does not shake.
    let startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let startedAt, !reduceMotion {
            let shake = DS.Move.shake.curve
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: Date().timeIntervalSince(startedAt) > shake.seconds())) { timeline in
                content.offset(x: Self.offsetPoints(secondsSinceTheShakeStarted: timeline.date.timeIntervalSince(startedAt)))
            }
        } else {
            content
        }
    }

    /// The sideways offset `secondsSinceTheShakeStarted` after it began.
    static func offsetPoints(secondsSinceTheShakeStarted: Double) -> CGFloat {
        guard case .decayingShake(_, let amplitudePoints, _, _) = DS.Move.shake.curve else { return 0 }
        return CGFloat(DS.Move.shake.curve.progress(atSeconds: secondsSinceTheShakeStarted) * amplitudePoints)
    }
}

// MARK: - The speech Callout's words

/// One line of a spoken sentence: the characters it holds, as offsets into the sentence.
struct SpeechCalloutLine: Equatable {
    let text: String
    /// The offset of the line's first character in the whole sentence.
    let startOffset: Int

    var endOffset: Int { startOffset + text.count }
}

/// How the speech Callout breaks a sentence into lines, which lines show, and which word is being spoken.
enum SpeechCalloutLayout {
    /// The words wrap by measured width at this many points.
    static let wrapWidth: CGFloat = 300
    /// A longer sentence scrolls: the Callout shows this many lines at a time.
    static let mostVisibleLines = 3

    /// The 15 point bold rounded face the Callout sets its words in, so a line measures as it draws.
    static let measuringFont: NSFont = {
        let boldFont = NSFont.systemFont(ofSize: DS.TypeScale.voice.pointSize, weight: .bold)
        guard let roundedDescriptor = boldFont.fontDescriptor.withDesign(.rounded),
              let roundedFont = NSFont(descriptor: roundedDescriptor, size: DS.TypeScale.voice.pointSize) else { return boldFont }
        return roundedFont
    }()

    /// The sentence broken into lines at `wrapWidth`, words kept whole. A last line of one word would sit alone, so when the
    /// line above has a second word to spare and the two fit together, that word moves down to keep the last line company.
    static func lines(of sentence: String, wrapWidth: CGFloat = SpeechCalloutLayout.wrapWidth, measuredWidth: (String) -> CGFloat = SpeechCalloutLayout.widthOnOneLine) -> [SpeechCalloutLine] {
        var words: [(text: String, startOffset: Int)] = []
        var currentWordStart: Int?
        for (characterOffset, character) in sentence.enumerated() {
            if character.isWhitespace {
                if let wordStart = currentWordStart {
                    words.append((String(sentence.dropFirst(wordStart).prefix(characterOffset - wordStart)), wordStart))
                    currentWordStart = nil
                }
            } else if currentWordStart == nil {
                currentWordStart = characterOffset
            }
        }
        if let wordStart = currentWordStart {
            words.append((String(sentence.dropFirst(wordStart)), wordStart))
        }
        guard !words.isEmpty else { return [] }

        var wordsOfEachLine: [[(text: String, startOffset: Int)]] = [[]]
        for word in words {
            let candidateWords = wordsOfEachLine[wordsOfEachLine.count - 1] + [word]
            let candidateLine = candidateWords.map(\.text).joined(separator: " ")
            if wordsOfEachLine[wordsOfEachLine.count - 1].isEmpty || measuredWidth(candidateLine) <= wrapWidth {
                wordsOfEachLine[wordsOfEachLine.count - 1] = candidateWords
            } else {
                wordsOfEachLine.append([word])
            }
        }

        if wordsOfEachLine.count >= 2, wordsOfEachLine[wordsOfEachLine.count - 1].count == 1 {
            let lineAboveIndex = wordsOfEachLine.count - 2
            if wordsOfEachLine[lineAboveIndex].count >= 3 {
                let wordToMoveDown = wordsOfEachLine[lineAboveIndex][wordsOfEachLine[lineAboveIndex].count - 1]
                let companyLine = [wordToMoveDown.text, wordsOfEachLine[wordsOfEachLine.count - 1][0].text].joined(separator: " ")
                if measuredWidth(companyLine) <= wrapWidth {
                    wordsOfEachLine[lineAboveIndex].removeLast()
                    wordsOfEachLine[wordsOfEachLine.count - 1].insert(wordToMoveDown, at: 0)
                }
            }
        }

        return wordsOfEachLine.map { lineWords in
            SpeechCalloutLine(text: lineWords.map(\.text).joined(separator: " "), startOffset: lineWords[0].startOffset)
        }
    }

    static func widthOnOneLine(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: measuringFont]).width
    }

    /// The lines on screen when `revealedCharacterCount` characters are spoken. A sentence of up to 3 lines shows whole. A
    /// longer one shows the line being spoken, the last complete line above it, which stays for rereading, and the next
    /// line, and scrolls a line at a time.
    static func visibleLineRange(lines: [SpeechCalloutLine], revealedCharacterCount: Int) -> Range<Int> {
        guard lines.count > mostVisibleLines else { return 0..<lines.count }
        let spokenCharacterOffset = max(revealedCharacterCount - 1, 0)
        let currentLineIndex = lines.lastIndex { $0.startOffset <= spokenCharacterOffset } ?? 0
        let firstVisibleLineIndex = min(max(currentLineIndex - 1, 0), lines.count - mostVisibleLines)
        return firstVisibleLineIndex..<(firstVisibleLineIndex + mostVisibleLines)
    }

    /// The word being spoken, as offsets into the sentence: the word holding the last spoken character. Nil before any word
    /// is spoken and once the whole sentence is, since an underline under the last word of a finished line says nothing.
    static func currentWordRange(in sentence: String, revealedCharacterCount: Int) -> Range<Int>? {
        let characters = Array(sentence)
        guard revealedCharacterCount > 0, revealedCharacterCount < characters.count else { return nil }
        let lastSpokenOffset = revealedCharacterCount - 1
        guard !characters[lastSpokenOffset].isWhitespace else { return nil }
        var wordStart = lastSpokenOffset
        while wordStart > 0, !characters[wordStart - 1].isWhitespace { wordStart -= 1 }
        var wordEnd = lastSpokenOffset + 1
        while wordEnd < characters.count, !characters[wordEnd].isWhitespace { wordEnd += 1 }
        return wordStart..<wordEnd
    }

    /// One line as styled words: spoken words in white, the word being spoken in white with a 2 point accent underline, and
    /// words not yet spoken at 60% white, which is 7.0 contrast on the Callout's surface.
    static func styledText(of line: SpeechCalloutLine, revealedCharacterCount: Int, currentWordRange: Range<Int>?, accent: Color) -> AttributedString {
        var styledLine = AttributedString()
        for (characterIndex, character) in line.text.enumerated() {
            let sentenceOffset = line.startOffset + characterIndex
            var styledCharacter = AttributedString(String(character))
            styledCharacter.swiftUI.foregroundColor = sentenceOffset < revealedCharacterCount ? Color.white : Color.white.opacity(0.6)
            if let currentWordRange, currentWordRange.contains(sentenceOffset) {
                styledCharacter.swiftUI.underlineStyle = Text.LineStyle(pattern: .solid, color: accent)
            }
            styledLine.append(styledCharacter)
        }
        return styledLine
    }
}

// MARK: - Views

/// The icon of a speech Callout: the cursor's own triangle, tilted as the cursor and the agent tokens tilt it, in ink on the
/// accent disc.
struct TetherCalloutCursorIcon: View {
    var body: some View {
        Triangle()
            .fill(DS.Colors.inkOnAccent)
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(-35))
    }
}

/// The icon of a failure Callout: a cross, in ink on the red disc. The cross stays with Reduce Motion on, where the shake
/// is dropped, so a failure never rests on color or motion alone.
struct TetherCalloutCrossIcon: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(DS.Colors.inkOnAccent)
    }
}

/// What Clicky says near the cursor: the sentence on a Callout with a 1.5 point rim. `revealedCharacterCount` characters
/// are spoken, so the words brighten as the voice reaches them (`ElevenLabsTTSClient.spokenFraction(ofLine:)` drives the
/// count), and a 2 point accent underline sits under the word being spoken. The Callout keeps its size as the words
/// brighten, since every word is there from the start.
struct SpeechCalloutView: View {
    let sentence: String
    let revealedCharacterCount: Int
    let accent: Color

    var body: some View {
        let lines = SpeechCalloutLayout.lines(of: sentence)
        let visibleRange = SpeechCalloutLayout.visibleLineRange(lines: lines, revealedCharacterCount: revealedCharacterCount)
        let currentWordRange = SpeechCalloutLayout.currentWordRange(in: sentence, revealedCharacterCount: revealedCharacterCount)
        TetherCallout(accent: accent, rim: .speech) {
            TetherCalloutCursorIcon()
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines[visibleRange].enumerated()), id: \.element.startOffset) { _, line in
                    Text(SpeechCalloutLayout.styledText(of: line, revealedCharacterCount: revealedCharacterCount, currentWordRange: currentWordRange, accent: accent))
                        .fixedSize()
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence)
    }
}
