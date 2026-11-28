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
import Combine
import SwiftUI

// MARK: - Where a Callout sits

/// The room around a Callout inside its panel, so the panel does not clip the drop shadow (a 5 point blur offset 3 down).
/// 14 points is more than the shadow needs: rendered, it reaches 10.5 points below the Callout, 9 to each side, and 7
/// above.
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

/// Where the tail's tip is in the overlay, as a share of the screen. A Callout placed by `speechCalloutCenter` pivots its Pop
/// about this point, so a Callout that slid left at the screen's edge still grows from its tail. Before the Callout is measured
/// (a size of zero) the tip is taken to be just above the triangle at `cursorPosition`.
func speechCalloutPivot(cursorPosition: CGPoint, calloutSize: CGSize, screenSize: CGSize) -> UnitPoint {
    var tipPoint = CGPoint(x: cursorPosition.x, y: cursorPosition.y - tetherCalloutTipRiseAboveTheCursor)
    if calloutSize != .zero {
        let center = speechCalloutCenter(cursorPosition: cursorPosition, calloutSize: calloutSize, screenSize: screenSize)
        tipPoint = CGPoint(
            x: center.x - calloutSize.width / 2 + TetherCalloutShape.tailTip(inCalloutOfSize: calloutSize).x,
            y: center.y + calloutSize.height / 2
        )
    }
    return UnitPoint(x: tipPoint.x / max(screenSize.width, 1), y: tipPoint.y / max(screenSize.height, 1))
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

struct TetherCalloutPresenceEffect: ViewModifier {
    let pose: TetherCalloutPresencePose
    /// The pivot of the scale as a share of the view's own size, or nil to find the tail's tip from the Callout's width. A
    /// Callout placed with `.position` fills its parent, so it passes the tip's place in the parent instead.
    var pivotInTheView: UnitPoint?

    func body(content: Content) -> some View {
        if let pivotInTheView {
            content
                .scaleEffect(pose.scale, anchor: pivotInTheView)
                .offset(y: pose.riseOffset)
                .opacity(pose.opacity)
        } else {
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
}

/// How the pointing bubble leaves once its narration lets the cursor go. A push-to-talk press during the narration is an
/// interruption, so the bubble shrinks into the cursor (`.recall`), and every other release fades and rises.
/// CompanionManager notes the press, and the overlay takes the note once, when it hides the bubble.
struct PointingBubbleExitRecord: Equatable {
    private var learnerInterruptedThePointing = false

    /// A press while the cursor points, with that pointing's hold, or nil when nothing is pointed at. Only a held pointing
    /// reaches the overlay's release, which takes the note, so a brief one, such as an answer's, leaves no note behind.
    mutating func noteThatTheLearnerInterrupted(pointingHold: BuddyPointingHold?) {
        learnerInterruptedThePointing = pointingHold?.holdsUntilReleased == true
    }

    /// The exit for the bubble leaving now, which clears the note so a later release fades as usual.
    mutating func takeTheExit() -> TetherCalloutExit {
        defer { learnerInterruptedThePointing = false }
        return learnerInterruptedThePointing ? .recall : .fadeRise
    }
}

/// What the buddy does when the turn its Recall waited for comes. A buddy already following the mouse or flying back has
/// nothing left to do. With no new pointing it flies back to the mouse. A new pointing whose target this screen flies to
/// owns the buddy. A new pointing elsewhere, or one this screen refuses, means this buddy gives way, so it never stays
/// stopped next to the new one.
enum PointingBubbleRecallStep: Equatable {
    case nothingLeftToDo
    case flyBackToTheMouse
    case leaveTheBuddyToTheNewPointing
    case giveWayToThePointingElsewhere
}

func pointingBubbleRecallStep(buddyIsAwayFromTheMouse: Bool, aNewPointingIsSet: Bool, thisScreenFliesToTheNewPointing: Bool) -> PointingBubbleRecallStep {
    guard buddyIsAwayFromTheMouse else { return .nothingLeftToDo }
    guard aNewPointingIsSet else { return .flyBackToTheMouse }
    return thisScreenFliesToTheNewPointing ? .leaveTheBuddyToTheNewPointing : .giveWayToThePointingElsewhere
}

extension AnyTransition {
    /// For a Callout that a view's own condition puts in and takes out of the tree: it pops from its tail's tip going in, and
    /// leaves with a 6 point rise and a fade. With Reduce Motion on, both are a fade in place.
    /// `pivotInTheView` is where the tail's tip sits in the view the Callout is placed in.
    static func tetherCalloutPopAndFadeRise(reduceMotionIsOn: Bool, pivotInTheView: UnitPoint) -> AnyTransition {
        tetherCalloutPop(andLeave: .fadeRise, reduceMotionIsOn: reduceMotionIsOn, pivotInTheView: pivotInTheView)
    }

    /// The same Pop going in, and the leave `exit` names going out, so an interrupted Callout can shrink into the cursor.
    static func tetherCalloutPop(andLeave exit: TetherCalloutExit, reduceMotionIsOn: Bool, pivotInTheView: UnitPoint) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: TetherCalloutPresenceEffect(pose: .appearing(reduceMotionIsOn: reduceMotionIsOn), pivotInTheView: pivotInTheView),
                identity: TetherCalloutPresenceEffect(pose: .resting, pivotInTheView: pivotInTheView)
            ),
            removal: .modifier(
                active: TetherCalloutPresenceEffect(pose: .leaving(exit, reduceMotionIsOn: reduceMotionIsOn), pivotInTheView: pivotInTheView),
                identity: TetherCalloutPresenceEffect(pose: .resting, pivotInTheView: pivotInTheView)
            )
        )
    }
}

/// Whether a Callout is on screen, and how it is leaving. The Callout stays in the view tree while it leaves, and its pose
/// (`TetherCalloutPresencePose.leaving`) animates, so the exit style is known when the leave starts and never depends on the
/// order a run loop turn runs in. The model removes the Callout from the tree once the leave has played.
@MainActor
final class TetherCalloutPresence: ObservableObject {
    @Published private(set) var isInTheViewTree = false
    /// How the Callout is leaving, or nil while it stays.
    @Published private(set) var leavingExit: TetherCalloutExit?
    /// Counts each appear and leave, so a removal waiting for a leave to play never removes a Callout that appeared since.
    private var removalGeneration = 0
    /// Runs a removal after the seconds its leave takes. A test passes one it fires by hand, so a removal happens when the
    /// test says and never depends on how soon a busy main queue gets to a timer.
    private let scheduleTheRemoval: (_ afterSeconds: TimeInterval, _ removal: @escaping () -> Void) -> Void

    init(
        scheduleTheRemoval: @escaping (_ afterSeconds: TimeInterval, _ removal: @escaping () -> Void) -> Void = { afterSeconds, removal in
            DispatchQueue.main.asyncAfter(deadline: .now() + afterSeconds, execute: removal)
        }
    ) {
        self.scheduleTheRemoval = scheduleTheRemoval
    }

    /// The Callout pops in, or comes back from a leave that has not finished.
    func appear() {
        removalGeneration += 1
        isInTheViewTree = true
        leavingExit = nil
    }

    /// The Callout leaves the way `exit` says, and leaves the view tree when that has played. Nothing happens when it is not
    /// on screen, and a Recall can take over a fade-rise already under way.
    func leave(_ exit: TetherCalloutExit, reduceMotionIsOn: Bool) {
        guard isInTheViewTree, leavingExit != exit else { return }
        removalGeneration += 1
        let generationOfThisLeave = removalGeneration
        leavingExit = exit
        scheduleTheRemoval(Self.secondsToLeave(exit, reduceMotionIsOn: reduceMotionIsOn)) { [weak self] in
            guard let self, self.removalGeneration == generationOfThisLeave else { return }
            self.isInTheViewTree = false
            self.leavingExit = nil
        }
    }

    /// How long a leave takes: the 150 ms crossfade with Reduce Motion on, else 0.7 of the Pop's time for a fade-rise and the
    /// Recall's 180 ms.
    nonisolated static func secondsToLeave(_ exit: TetherCalloutExit, reduceMotionIsOn: Bool) -> Double {
        if reduceMotionIsOn { return DS.Move.fadeSeconds }
        switch exit {
        case .fadeRise: return DS.Move.pop.curve.seconds() * 0.7
        case .recall: return DS.Move.recall.curve.seconds()
        }
    }
}

extension View {
    /// Draws a Callout with the pose its presence says: the Pop as it comes into the tree, and the leave pose while it leaves.
    func tetherCalloutPose(_ presence: TetherCalloutPresence, reduceMotionIsOn: Bool) -> some View {
        modifier(TetherCalloutPoseModifier(presence: presence, reduceMotionIsOn: reduceMotionIsOn))
    }

    /// Plays the Pop as the Callout comes into the tree and the leave as its presence starts one. Put it on the container that
    /// holds the Callout, since an animation does not play for the insertion of the view it is on.
    func tetherCalloutAnimations(_ presence: TetherCalloutPresence, reduceMotionIsOn: Bool) -> some View {
        self
            .animation(
                tetherCalloutAnimation(isAppearing: true, exit: .fadeRise, reduceMotionIsOn: reduceMotionIsOn),
                value: presence.isInTheViewTree
            )
            .animation(
                tetherCalloutAnimation(isAppearing: presence.leavingExit == nil, exit: presence.leavingExit ?? .fadeRise, reduceMotionIsOn: reduceMotionIsOn),
                value: presence.leavingExit
            )
    }
}

private struct TetherCalloutPoseModifier: ViewModifier {
    @ObservedObject var presence: TetherCalloutPresence
    let reduceMotionIsOn: Bool

    func body(content: Content) -> some View {
        let leavingPose = presence.leavingExit.map { TetherCalloutPresencePose.leaving($0, reduceMotionIsOn: reduceMotionIsOn) }
        content
            .modifier(TetherCalloutPresenceEffect(pose: leavingPose ?? .resting))
            // Only the insertion is a transition. A Callout leaves by changing its pose, so the exit is chosen before it starts.
            .transition(.asymmetric(
                insertion: .modifier(
                    active: TetherCalloutPresenceEffect(pose: .appearing(reduceMotionIsOn: reduceMotionIsOn)),
                    identity: TetherCalloutPresenceEffect(pose: .resting)
                ),
                removal: .identity
            ))
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

        // A line is the slice of the sentence from its first word to its last, so every character of the line sits at its own
        // offset even when the sentence has a double space or a line break between words. A tab or a line break inside a
        // line shows as one space, character for character, so nothing shifts.
        let sentenceCharacters = Array(sentence)
        return wordsOfEachLine.map { lineWords in
            let firstOffset = lineWords[0].startOffset
            let lastWord = lineWords[lineWords.count - 1]
            let endOffset = lastWord.startOffset + lastWord.text.count
            let lineText = String(sentenceCharacters[firstOffset..<endOffset].map { $0.isWhitespace ? " " : $0 })
            return SpeechCalloutLine(text: lineText, startOffset: firstOffset)
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

    /// Part of a line in its colors: spoken characters in white, and characters not yet spoken at 60% white, which is 7.0
    /// contrast on the Callout's surface. `characterRange` is in offsets into the line's own text.
    static func coloredText(of line: SpeechCalloutLine, characterRange: Range<Int>, revealedCharacterCount: Int) -> AttributedString {
        var coloredPart = AttributedString()
        let lineCharacters = Array(line.text)
        for characterIndex in characterRange {
            let sentenceOffset = line.startOffset + characterIndex
            var coloredCharacter = AttributedString(String(lineCharacters[characterIndex]))
            coloredCharacter.swiftUI.foregroundColor = sentenceOffset < revealedCharacterCount ? Color.white : Color.white.opacity(0.6)
            coloredPart.append(coloredCharacter)
        }
        return coloredPart
    }

    /// The line split around the word being spoken, in offsets into the line's own text: the part before it, the word, and
    /// the part after it. A line that does not hold that word is all `before`, with the other two empty.
    static func partsAroundTheSpokenWord(of line: SpeechCalloutLine, currentWordRange: Range<Int>?) -> (before: Range<Int>, word: Range<Int>, after: Range<Int>) {
        let lineLength = line.text.count
        guard let currentWordRange else { return (0..<lineLength, lineLength..<lineLength, lineLength..<lineLength) }
        let wordStart = min(max(currentWordRange.lowerBound - line.startOffset, 0), lineLength)
        let wordEnd = min(max(currentWordRange.upperBound - line.startOffset, wordStart), lineLength)
        return (0..<wordStart, wordStart..<wordEnd, wordEnd..<lineLength)
    }

    /// One line as one `Text`, so it lays out as a single run of words: its colors from `coloredText`, and the word being
    /// spoken marked for its 2 point accent underline (`SpokenWordUnderlineRenderer`). Before macOS 15, which has no text
    /// renderer, the word takes the system underline in the accent color instead, whose thickness the font decides.
    static func lineText(of line: SpeechCalloutLine, revealedCharacterCount: Int, currentWordRange: Range<Int>?, accent: Color) -> Text {
        let parts = partsAroundTheSpokenWord(of: line, currentWordRange: currentWordRange)
        let textBefore = Text(coloredText(of: line, characterRange: parts.before, revealedCharacterCount: revealedCharacterCount))
        let wordText = Text(coloredText(of: line, characterRange: parts.word, revealedCharacterCount: revealedCharacterCount))
        let textAfter = Text(coloredText(of: line, characterRange: parts.after, revealedCharacterCount: revealedCharacterCount))
        let markedWordText: Text
        if #available(macOS 15.0, *) {
            markedWordText = wordText.customAttribute(SpokenWordUnderlineMark())
        } else {
            markedWordText = wordText.underline(true, color: accent)
        }
        return Text("\(textBefore)\(markedWordText)\(textAfter)")
    }
}

/// Marks the word being spoken inside a line's `Text`, so `SpokenWordUnderlineRenderer` draws its underline.
@available(macOS 15.0, *)
struct SpokenWordUnderlineMark: TextAttribute {}

/// Draws a speech line and a 2 point accent bar under the run marked `SpokenWordUnderlineMark`. The system underline takes
/// its thickness from the font, so the spec's 2 points needs its own bar.
@available(macOS 15.0, *)
struct SpokenWordUnderlineRenderer: TextRenderer {
    static let underlineThicknessInPoints: CGFloat = 2
    /// How far below the baseline the bar's top sits, about where the system underline sits.
    static let underlineGapBelowTheBaselineInPoints: CGFloat = 1.5
    let accent: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let displayScale = max(context.environment.displayScale, 1)
        for line in layout {
            for run in line {
                context.draw(run)
                guard run[SpokenWordUnderlineMark.self] != nil else { continue }
                let runBounds = run.typographicBounds
                // On whole pixels, so the bar is exactly 2 points of solid color and not a blurred 3.
                let barTop = ((runBounds.origin.y + Self.underlineGapBelowTheBaselineInPoints) * displayScale).rounded() / displayScale
                let barRect = CGRect(x: runBounds.rect.minX, y: barTop, width: runBounds.width, height: Self.underlineThicknessInPoints)
                context.fill(Path(barRect), with: .color(accent))
            }
        }
    }
}

extension View {
    /// Draws a speech line's spoken word underline at exactly 2 points on macOS 15 and later.
    @ViewBuilder
    func spokenWordUnderline(accent: Color) -> some View {
        if #available(macOS 15.0, *) {
            textRenderer(SpokenWordUnderlineRenderer(accent: accent))
        } else {
            self
        }
    }
}

// MARK: - Views

/// The icon of a speech Callout: the cursor's own triangle, tilted as the cursor and the agent tokens tilt it, in the ink
/// the Callout gives its icon disc.
struct TetherCalloutCursorIcon: View {
    var body: some View {
        Triangle()
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(-35))
    }
}

/// The icon of a failure Callout: a cross, in the ink the Callout gives its red disc. The cross stays with Reduce Motion
/// on, where the shake is dropped, so a failure never rests on color or motion alone.
struct TetherCalloutCrossIcon: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 11, weight: .heavy))
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
                    SpeechCalloutLayout.lineText(of: line, revealedCharacterCount: revealedCharacterCount, currentWordRange: currentWordRange, accent: accent)
                        .spokenWordUnderline(accent: accent)
                        .fixedSize()
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence)
    }
}
