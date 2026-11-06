//
//  LiveSceneStatusLine.swift
//  leanring-buddy
//
//  The lines the status label shows while Clicky works. Each line has its own
//  colors, letter style, icon, and looping animation, so the wait for each step
//  looks different. The animation math here takes a time and returns a pose,
//  so tests can check it without drawing anything.
//

import Foundation
import SwiftUI

enum LiveSceneStatusLine {
    case poppingItOut
    case readingYourScreen
    case buildingYourScene
    case almostThere
    case readingTheTranscript
    case pickingQuizSpots

    var text: String {
        switch self {
        case .poppingItOut: return "Popping it out"
        case .readingYourScreen: return "Reading your screen"
        case .buildingYourScene: return "Building your 3D scene"
        case .almostThere: return "Almost there"
        case .readingTheTranscript: return "Reading the transcript"
        case .pickingQuizSpots: return "Picking spots to quiz you on"
        }
    }

    /// The letters as drawn. The screen-reading line is set in capitals, like a terminal.
    var displayedText: String {
        self == .readingYourScreen ? text.uppercased() : text
    }

    var palette: StatusLabelPalette {
        switch self {
        case .poppingItOut: return .poppingItOut
        case .readingYourScreen: return .readingYourScreen
        case .buildingYourScene: return .buildingYourScene
        case .almostThere: return .almostThere
        case .readingTheTranscript: return .readingTheTranscript
        case .pickingQuizSpots: return .pickingQuizSpots
        }
    }

    /// The lines the scene build shows. Only the scene build hides these.
    static let sceneBuildLines: Set<LiveSceneStatusLine> = [.readingYourScreen, .buildingYourScene, .almostThere]
    /// The line the pop-out shows. Only the pop-out hides it.
    static let popOutLines: Set<LiveSceneStatusLine> = [.poppingItOut]
    /// The lines the video quiz shows while it reads and plans. Only the video quiz hides these.
    static let videoQuizPlanningLines: Set<LiveSceneStatusLine> = [.readingTheTranscript, .pickingQuizSpots]

    /// What the label shows (nil when hidden) after one owner swaps its own line for the next.
    /// The swap happens only while `expectedCurrentLine` shows, so a line never comes back
    /// after a push-to-talk press or another owner took the label.
    static func lineShowing(
        afterReplacing expectedCurrentLine: LiveSceneStatusLine,
        with newLine: LiveSceneStatusLine,
        whileShowing currentLine: LiveSceneStatusLine?
    ) -> LiveSceneStatusLine? {
        currentLine == expectedCurrentLine ? newLine : currentLine
    }

    /// What the label shows (nil when hidden) after a hide. A nil `linesToHide` hides whatever shows,
    /// and a set hides only a line in it, so one owner never hides another owner's line.
    static func lineShowing(
        afterHidingOnlyIfShowingOneOf linesToHide: Set<LiveSceneStatusLine>?,
        whileShowing currentLine: LiveSceneStatusLine?
    ) -> LiveSceneStatusLine? {
        guard let linesToHide else { return nil }
        guard let currentLine, !linesToHide.contains(currentLine) else { return nil }
        return currentLine
    }

    /// A moment in the loop where every letter is on screen, shown when the
    /// user has Reduce Motion on, so the label still reads but does not move.
    var stillMomentSeconds: Double {
        switch self {
        case .poppingItOut: return 1.9
        case .readingYourScreen: return 1.35
        case .buildingYourScene: return 1.6
        case .almostThere: return 1.5
        case .readingTheTranscript: return 2.0
        case .pickingQuizSpots: return 1.1
        }
    }
}

/// The colors one status line draws with. Each look is a constant, so reading it for every
/// letter on every frame costs nothing.
struct StatusLabelPalette {
    let iconColor: Color
    let textColor: Color
    let lightColor: Color
    let paleColor: Color
    let washColor: Color
    let highlightColor: Color

    static let poppingItOut = StatusLabelPalette(
        iconColor: DS.Colors.blue600, textColor: DS.Colors.blue600, lightColor: DS.Colors.blue400,
        paleColor: DS.Colors.blue200, washColor: DS.Colors.blue50, highlightColor: DS.Colors.blue400
    )
    static let readingYourScreen = StatusLabelPalette(
        iconColor: DS.Colors.purple500, textColor: DS.Colors.purple700, lightColor: DS.Colors.purple300,
        paleColor: DS.Colors.purple100, washColor: DS.Colors.purple50, highlightColor: DS.Colors.purple400
    )
    static let buildingYourScene = StatusLabelPalette(
        iconColor: DS.Colors.orange500, textColor: DS.Colors.orange700, lightColor: DS.Colors.orange300,
        paleColor: DS.Colors.orange200, washColor: DS.Colors.orange50, highlightColor: DS.Colors.orange400
    )
    static let almostThere = StatusLabelPalette(
        iconColor: DS.Colors.green500, textColor: DS.Colors.green700, lightColor: DS.Colors.green300,
        paleColor: DS.Colors.green100, washColor: DS.Colors.green50, highlightColor: DS.Colors.green400
    )
    static let readingTheTranscript = StatusLabelPalette(
        iconColor: DS.Colors.pink400, textColor: DS.Colors.pink700, lightColor: DS.Colors.pink300,
        paleColor: DS.Colors.pink100, washColor: DS.Colors.pink50, highlightColor: DS.Colors.pink300
    )
    static let pickingQuizSpots = StatusLabelPalette(
        iconColor: DS.Colors.sky500, textColor: DS.Colors.sky700, lightColor: DS.Colors.sky300,
        paleColor: DS.Colors.sky100, washColor: DS.Colors.sky50, highlightColor: DS.Colors.sky400
    )
}

// MARK: - Motion helpers

/// Curves and keyframe lookup shared by every look.
enum StatusLabelMotion {
    static func easeInOut(_ progress: Double) -> Double {
        progress * progress * (3 - 2 * progress)
    }

    static func easeOut(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    /// Goes a little past the target and settles back, which gives the letters their bounce.
    static func easeOutBack(_ progress: Double) -> Double {
        let overshoot = 1.70158
        let shiftedProgress = progress - 1
        return 1 + (overshoot + 1) * pow(shiftedProgress, 3) + overshoot * pow(shiftedProgress, 2)
    }

    static func linear(_ progress: Double) -> Double {
        progress
    }

    /// The value at `loopFraction` (0 to 1), eased between the two keyframes around it.
    /// Keyframes are (fraction of the loop, value) pairs sorted by fraction.
    static func value(
        at loopFraction: Double,
        keyframes: [(fraction: Double, value: Double)],
        easing: (Double) -> Double
    ) -> Double {
        guard let firstKeyframe = keyframes.first, let lastKeyframe = keyframes.last else { return 0 }
        if loopFraction <= firstKeyframe.fraction { return firstKeyframe.value }
        if loopFraction >= lastKeyframe.fraction { return lastKeyframe.value }
        for (earlierKeyframe, laterKeyframe) in zip(keyframes, keyframes.dropFirst()) where loopFraction <= laterKeyframe.fraction {
            let keyframeSpan = laterKeyframe.fraction - earlierKeyframe.fraction
            let progressInSpan = keyframeSpan > 0 ? (loopFraction - earlierKeyframe.fraction) / keyframeSpan : 1
            return earlierKeyframe.value + (laterKeyframe.value - earlierKeyframe.value) * easing(progressInSpan)
        }
        return lastKeyframe.value
    }

    /// How far through its loop an animation is, from 0 to 1, or nil while it waits out its delay.
    static func loopFraction(elapsedSeconds: Double, loopSeconds: Double, delaySeconds: Double = 0) -> Double? {
        let runningSeconds = elapsedSeconds - delaySeconds
        guard runningSeconds >= 0 else { return nil }
        return runningSeconds.truncatingRemainder(dividingBy: loopSeconds) / loopSeconds
    }
}

// MARK: - Letter poses

/// How one letter is drawn at one moment.
struct StatusLetterPose: Equatable {
    var offsetY: Double = 0
    var scale: Double = 1
    var extraVerticalScale: Double = 1
    var rotationDegrees: Double = 0
    var opacity: Double = 1
    /// 0 draws the text color and 1 the highlight color.
    var highlightAmount: Double = 0
    var showsCaret = false
    /// Size of the dot under a picked letter, from 0 (hidden) to 1.
    var spotDotScale: Double = 0
}

extension LiveSceneStatusLine {
    /// The quiz-spots line's dotted letters, found once because every letter asks on every frame.
    private static let quizSpotLetterIndexes = spotLetterIndexes(in: LiveSceneStatusLine.pickingQuizSpots.displayedText)

    /// The letters that get a dot in the quiz-spots line: four spread across the line, skipping spaces.
    private static func spotLetterIndexes(in displayedText: String) -> [Int] {
        let letterIndexes = displayedText.enumerated().compactMap { index, character in
            character == " " ? nil : index
        }
        guard !letterIndexes.isEmpty else { return [] }
        return [0.08, 0.36, 0.62, 0.9].map { fractionAlongTheLine in
            letterIndexes[Int((fractionAlongTheLine * Double(letterIndexes.count - 1)).rounded())]
        }
    }

    func letterPose(letterIndex: Int, letterCount: Int, elapsedSeconds: Double) -> StatusLetterPose {
        switch self {
        case .poppingItOut:
            // Each letter in turn jumps up, grows, tilts, and lands with a squash.
            guard let loopFraction = StatusLabelMotion.loopFraction(
                elapsedSeconds: elapsedSeconds, loopSeconds: 2.0, delaySeconds: Double(letterIndex) * 0.07
            ) else { return StatusLetterPose() }
            let tiltDegrees: Double = letterIndex.isMultiple(of: 2) ? -8 : 8
            return StatusLetterPose(
                offsetY: StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.12, -7), (0.24, 0), (0.40, 0), (1, 0)], easing: StatusLabelMotion.easeOutBack),
                scale: StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 1), (0.12, 1.3), (0.24, 0.95), (0.40, 1), (1, 1)], easing: StatusLabelMotion.easeOutBack),
                rotationDegrees: StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.12, tiltDegrees), (0.24, 0), (1, 0)], easing: StatusLabelMotion.easeOutBack)
            )

        case .readingYourScreen:
            // A bright band runs across the letters, like the scan line on the icon.
            guard let loopFraction = StatusLabelMotion.loopFraction(
                elapsedSeconds: elapsedSeconds, loopSeconds: 1.4, delaySeconds: Double(letterIndex) * 0.05
            ) else { return StatusLetterPose() }
            let bandAmount = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 1), (0.14, 0), (1, 0)], easing: StatusLabelMotion.linear)
            return StatusLetterPose(offsetY: -bandAmount, extraVerticalScale: 1 + 0.18 * bandAmount, highlightAmount: bandAmount)

        case .buildingYourScene:
            // Letters drop in one by one and lock into place, then lift away and the line builds again.
            guard let loopFraction = StatusLabelMotion.loopFraction(
                elapsedSeconds: elapsedSeconds, loopSeconds: 2.6, delaySeconds: Double(letterIndex) * 0.06
            ) else { return StatusLetterPose(offsetY: -14, rotationDegrees: -14, opacity: 0) }
            return StatusLetterPose(
                offsetY: StatusLabelMotion.value(at: loopFraction, keyframes: [(0, -14), (0.10, 0), (0.74, 0), (0.86, -6), (1, -6)], easing: StatusLabelMotion.easeOutBack),
                rotationDegrees: StatusLabelMotion.value(at: loopFraction, keyframes: [(0, -14), (0.10, 0), (1, 0)], easing: StatusLabelMotion.easeOutBack),
                opacity: StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.10, 1), (0.74, 1), (0.86, 0), (1, 0)], easing: StatusLabelMotion.easeOut)
            )

        case .almostThere:
            // The letters fill from light to dark green left to right, as the ring on the icon fills.
            guard let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: 1.8) else {
                return StatusLetterPose()
            }
            let fillFraction = 0.70 * Double(letterIndex) / Double(max(letterCount - 1, 1))
            let unfilledAmount = StatusLabelMotion.value(
                at: loopFraction,
                keyframes: [(0, 1), (fillFraction, 1), (fillFraction + 0.03, 0), (0.90, 0), (0.97, 1), (1, 1)],
                easing: StatusLabelMotion.linear
            )
            return StatusLetterPose(highlightAmount: unfilledAmount)

        case .readingTheTranscript:
            // The line types out behind a caret, the caret goes dark once (0.70 to 0.76 of the loop), shows again until 0.84, and the line clears.
            guard let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: 3.0) else {
                return StatusLetterPose(opacity: 0)
            }
            let typingEndsAt = 0.62
            let appearsAt = typingEndsAt * Double(letterIndex) / Double(letterCount)
            let nextLetterAppearsAt = typingEndsAt * Double(letterIndex + 1) / Double(letterCount)
            let opacity: Double
            if loopFraction < appearsAt {
                opacity = 0
            } else {
                opacity = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 1), (0.86, 1), (0.92, 0), (1, 0)], easing: StatusLabelMotion.linear)
            }
            let isLastLetter = letterIndex == letterCount - 1
            let showsCaret = isLastLetter
                ? (loopFraction >= appearsAt && loopFraction < 0.70) || (loopFraction >= 0.76 && loopFraction < 0.84)
                : loopFraction >= appearsAt && loopFraction < nextLetterAppearsAt
            return StatusLetterPose(opacity: opacity, showsCaret: showsCaret)

        case .pickingQuizSpots:
            // Four letters lift one by one and get a dot under them, like the spots the magnifier lights up.
            guard let spotOrder = Self.quizSpotLetterIndexes.firstIndex(of: letterIndex),
                  let loopFraction = StatusLabelMotion.loopFraction(
                      elapsedSeconds: elapsedSeconds, loopSeconds: 2.4, delaySeconds: Double(spotOrder) * 0.35
                  ) else { return StatusLetterPose() }
            let raisedKeyframes: [(fraction: Double, value: Double)] = [(0, 0), (0.10, 1), (0.70, 1), (0.85, 0), (1, 0)]
            let raisedAmount = StatusLabelMotion.value(at: loopFraction, keyframes: raisedKeyframes, easing: StatusLabelMotion.easeOutBack)
            return StatusLetterPose(offsetY: -3 * raisedAmount, spotDotScale: max(0, raisedAmount))
        }
    }

    /// The whole line's scale, anchored at its leading edge. Only "Almost there" bounces once it fills.
    func wordScale(elapsedSeconds: Double) -> Double {
        guard self == .almostThere,
              let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: 1.8) else { return 1 }
        return StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 1), (0.72, 1), (0.80, 1.07), (1, 1)], easing: StatusLabelMotion.easeInOut)
    }
}

// MARK: - Pop-out cube

/// Where the pop-out icon's cube is at one moment: a flat picture that extrudes into a cube
/// as it lifts, turns once, then flattens back, like the pop-out itself.
struct PopOutCubePose: Equatable {
    /// 0 is a flat picture and 1 a full cube.
    var depth: Double
    var tiltDegrees: Double
    var turnDegrees: Double
    var liftPoints: Double
    var scale: Double

    static let loopSeconds = 3.2

    static func at(elapsedSeconds: Double) -> PopOutCubePose {
        let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: loopSeconds) ?? 0
        // Flat until 12%, extruded and lifted by 35%, one full turn by 80%, flat again at the end.
        func valueAtThisMoment(_ values: [Double]) -> Double {
            let keyframeFractions = [0, 0.12, 0.35, 0.80, 1]
            return StatusLabelMotion.value(
                at: loopFraction,
                keyframes: zip(keyframeFractions, values).map { keyframeFraction, keyframeValue in
                    (fraction: keyframeFraction, value: keyframeValue)
                },
                easing: StatusLabelMotion.easeInOut
            )
        }
        return PopOutCubePose(
            depth: valueAtThisMoment([0, 0, 1, 1, 0]),
            tiltDegrees: valueAtThisMoment([0, 0, -24, -24, 0]),
            turnDegrees: valueAtThisMoment([0, 0, -30, 330, 360]),
            liftPoints: valueAtThisMoment([0, 0, 3, 3, 0]),
            scale: valueAtThisMoment([1, 1, 1.1, 1.1, 1])
        )
    }
}
