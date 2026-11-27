//
//  LiveSceneStatusLine.swift
//  leanring-buddy
//
//  The lines the status label shows while Clicky works. Each line is a Callout (see TetherMaterials.swift) with its own
//  fixed hue, which says what kind of work runs, and its own animated icon inside the Callout's disc. Every line sets its
//  words the same way: each letter rises 6 points, 18 ms after the one before, then holds still. The animation math here
//  takes a time and returns a pose, so tests can check it without drawing anything.
//

import Foundation
import SwiftUI

enum LiveSceneStatusLine: CaseIterable {
    case poppingItOut
    case animatingIt
    case readingYourScreen
    case buildingYourScene
    case almostThere
    case readingTheTranscript
    case pickingQuizSpots

    var text: String {
        switch self {
        case .poppingItOut: return "Popping it out"
        case .animatingIt: return "Animating it"
        case .readingYourScreen: return "Reading your screen"
        case .buildingYourScene: return "Building your 3D scene"
        case .almostThere: return "Almost there"
        case .readingTheTranscript: return "Reading the transcript"
        case .pickingQuizSpots: return "Picking spots to quiz you on"
        }
    }

    /// The line's own hue, on the Callout's rim, halo, and icon disc. The hue says what kind of work runs, so it does not
    /// follow the theme. Each is the 400 step of its color, bright enough for a 3:1 rim on the dark Callout.
    var calloutAccent: Color {
        switch self {
        case .poppingItOut: return DS.Colors.blue400
        case .animatingIt: return DS.Colors.teal400
        case .readingYourScreen: return DS.Colors.purple400
        case .buildingYourScene: return DS.Colors.orange400
        case .almostThere: return DS.Colors.green400
        case .readingTheTranscript: return DS.Colors.pink400
        case .pickingQuizSpots: return DS.Colors.sky400
        }
    }

    /// The colors the line's icon draws with: ink on the accent disc.
    var palette: StatusLabelPalette { .onDisc(accent: calloutAccent) }

    /// The lines the scene build shows. Only the scene build hides these.
    static let sceneBuildLines: Set<LiveSceneStatusLine> = [.readingYourScreen, .buildingYourScene, .almostThere]
    /// The lines the pop-out shows: "Animating it" when the learner asked to animate, while the pop-out builds
    /// or while the flows for a pop-out already on screen come back. Only the pop-out hides these.
    static let popOutLines: Set<LiveSceneStatusLine> = [.poppingItOut, .animatingIt]
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
        case .animatingIt: return 0
        case .readingYourScreen: return 1.35
        case .buildingYourScene: return 1.6
        case .almostThere: return 1.5
        case .readingTheTranscript: return 2.0
        case .pickingQuizSpots: return 1.1
        }
    }
}

/// The colors a status icon draws with on the Callout's accent disc: the ink that reads on that accent
/// (`Color.inkOnThisFill`) at several strengths, and the accent itself for what the icon cuts out of its drawing.
struct StatusLabelPalette {
    let iconColor: Color
    let textColor: Color
    let lightColor: Color
    let paleColor: Color
    let washColor: Color
    let highlightColor: Color
    /// The disc's own fill, for the parts of an icon that show the disc through it.
    let discColor: Color

    static func onDisc(accent: Color) -> StatusLabelPalette {
        let ink = accent.inkOnThisFill
        return StatusLabelPalette(
            iconColor: ink,
            textColor: ink,
            lightColor: ink.opacity(0.7),
            paleColor: ink.opacity(0.3),
            washColor: ink.opacity(0.12),
            highlightColor: ink,
            discColor: accent
        )
    }
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

// MARK: - Letters

/// How a line's letters appear: one motion for every line. Each letter rises 6 points into place and fades in, starting
/// 18 ms after the letter before it, and then everything holds still.
enum StatusLineLetterRise {
    static let risePoints = 6.0
    static let secondsBetweenLetters = 0.018
    /// How long one letter takes to settle.
    static let secondsPerLetter = 0.22

    /// How one letter is drawn `elapsedSeconds` after the line appeared.
    static func pose(letterIndex: Int, elapsedSeconds: Double) -> (offsetY: Double, opacity: Double) {
        let letterProgress = min(max((elapsedSeconds - Double(letterIndex) * secondsBetweenLetters) / secondsPerLetter, 0), 1)
        let easedProgress = StatusLabelMotion.easeOut(letterProgress)
        return (offsetY: risePoints * (1 - easedProgress), opacity: easedProgress)
    }

    /// When the last letter has settled, so the line can draw as one still piece of text.
    static func secondsUntilEveryLetterHasSettled(letterCount: Int) -> Double {
        Double(max(letterCount - 1, 0)) * secondsBetweenLetters + secondsPerLetter
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
