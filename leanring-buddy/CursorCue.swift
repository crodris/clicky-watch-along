//
//  CursorCue.swift
//  leanring-buddy
//
//  The ring around the cursor, which gives Clicky's voice states one home: a ring of ticks that follows
//  your voice while you speak, and three dots orbiting the cursor while Clicky thinks. Speaking hides the
//  ring, because the response bubble types with the voice. While a loop shows around the media Clicky is
//  looking at, the loop's spark is the thinking light instead, and the dots stay away.
//

import CoreGraphics
import SwiftUI

/// What is moving at the cursor. One cue at a time: ticks while listening, the dots or the loop's spark
/// while thinking, and the response bubble while speaking.
enum CursorCue: Equatable {
    /// Nothing moves at the cursor. A status label such as "Building your 3D scene" counts, since the ring hides under it.
    case idle
    case listening
    case thinkingWithDots
    /// The loop's spark is the thinking light, so the ring shows nothing.
    case thinkingWithLoop
    case speaking
}

func cursorCue(voiceState: CompanionVoiceState, loopIsShowing: Bool, aStatusLabelIsShowing: Bool) -> CursorCue {
    if loopIsShowing { return .thinkingWithLoop }
    if aStatusLabelIsShowing { return .idle }
    switch voiceState {
    case .idle: return .idle
    case .listening: return .listening
    case .processing: return .thinkingWithDots
    case .responding: return .speaking
    }
}

/// The ring's sizes and motion as pure functions, so tests check them without drawing.
enum CursorRingGeometry {
    static let tickCount = 24
    /// Each tick starts this far from the cursor's center and grows outward.
    static let tickInnerRadiusInPoints: CGFloat = 20
    static let tickWidthInPoints: CGFloat = 2.5
    static let shortestTickLengthInPoints: CGFloat = 5
    static let longestTickLengthInPoints: CGFloat = 16
    /// The ticks' outer edge at their longest, which sizes the view that holds them.
    static var outerRadiusInPoints: CGFloat { tickInnerRadiusInPoints + longestTickLengthInPoints }

    static let dotCount = 3
    static let dotOrbitRadiusInPoints: CGFloat = 24
    static let dotDiameterInPoints: CGFloat = 6
    static let secondsPerDotOrbit: TimeInterval = 1.2
    /// The dots trail one another, so the leading one is the brightest.
    static let dotOpacities: [Double] = [1, 0.7, 0.45]
    /// Three dots a third of the way round from one another, starting at the top of the orbit.
    static let dotStartingAnglesInDegrees: [Double] = [-90, 30, 150]

    /// How loud the voice looks, from 0 to 1. A level too quiet to be speech reads as silence, and the curve
    /// lifts the middle so ordinary speech reaches most of the ticks' range.
    static func easedAudioPowerLevel(_ audioPowerLevel: CGFloat) -> CGFloat {
        let levelAboveTheNoiseFloor = max(audioPowerLevel - 0.008, 0)
        return pow(min(levelAboveTheNoiseFloor * 2.85, 1), 0.76)
    }

    /// One length per tick. Silence gives every tick the shortest length, and the loudest voice lets the
    /// tallest ticks reach the longest. `shimmerPhase` moves which ticks are tall, so the ring stays alive
    /// while the level holds steady.
    static func tickLengths(audioPowerLevel: CGFloat, shimmerPhase: Double) -> [CGFloat] {
        let loudness = easedAudioPowerLevel(audioPowerLevel)
        let lengthRange = longestTickLengthInPoints - shortestTickLengthInPoints
        return (0..<tickCount).map { tickIndex in
            // From 0.25 to 1, so even the quietest tick of a loud voice still grows.
            let tallnessShare = CGFloat(0.625 + 0.375 * sin(Double(tickIndex) * 1.3 + shimmerPhase))
            return shortestTickLengthInPoints + lengthRange * loudness * tallnessShare
        }
    }

    /// With Reduce Motion the ticks hold still at a fixed medium length.
    static let stillTickLengths = tickLengths(audioPowerLevel: 0.12, shimmerPhase: 0)

    /// Where each dot is relative to the cursor's center, and how bright, a given time into its orbit.
    static func dotPlacements(secondsSinceTheOrbitBegan secondsSinceBegan: TimeInterval) -> [(offset: CGPoint, opacity: Double)] {
        let degreesTurned = 360 * secondsSinceBegan / secondsPerDotOrbit
        return (0..<dotCount).map { dotIndex in
            let angleInRadians = (dotStartingAnglesInDegrees[dotIndex] + degreesTurned) * .pi / 180
            return (
                offset: CGPoint(x: cos(angleInRadians) * dotOrbitRadiusInPoints, y: sin(angleInRadians) * dotOrbitRadiusInPoints),
                opacity: dotOpacities[dotIndex]
            )
        }
    }

    /// With Reduce Motion the dots stay in place and breathe, between about a third and full brightness.
    static func stillDotBrightness(secondsSinceTheBreathBegan secondsSinceBegan: TimeInterval) -> Double {
        let secondsPerBreath = 2.4
        return 0.65 + 0.35 * sin(2 * .pi * secondsSinceBegan / secondsPerBreath)
    }
}

/// The ring, centered on the point it is given. It shows only for the two cues that use it, and fades between them.
struct CursorRingView: View {
    let cue: CursorCue
    let audioPowerLevel: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            if cue == .listening {
                ListeningTicksView(audioPowerLevel: audioPowerLevel, color: color)
                    .transition(.opacity)
            }
            if cue == .thinkingWithDots {
                ThinkingDotsView(color: color)
                    .transition(.opacity)
            }
        }
        .frame(width: CursorRingGeometry.outerRadiusInPoints * 2, height: CursorRingGeometry.outerRadiusInPoints * 2)
        .animation(.easeOut(duration: 0.15), value: cue)
        .allowsHitTesting(false)
    }
}

/// 24 ticks around the cursor, growing outward with the microphone level.
private struct ListeningTicksView: View {
    let audioPowerLevel: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            ticks(lengths: CursorRingGeometry.stillTickLengths)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 36.0)) { timelineContext in
                ticks(lengths: CursorRingGeometry.tickLengths(
                    audioPowerLevel: audioPowerLevel,
                    shimmerPhase: timelineContext.date.timeIntervalSinceReferenceDate * 5
                ))
            }
        }
    }

    private func ticks(lengths: [CGFloat]) -> some View {
        Canvas { context, size in
            let ringCenter = CGPoint(x: size.width / 2, y: size.height / 2)
            for (tickIndex, tickLength) in lengths.enumerated() {
                // A tick is drawn pointing up from the ring's inner radius, then turned around the center.
                var turnedContext = context
                turnedContext.translateBy(x: ringCenter.x, y: ringCenter.y)
                turnedContext.rotate(by: .degrees(360 * Double(tickIndex) / Double(CursorRingGeometry.tickCount)))
                let tickRect = CGRect(
                    x: -CursorRingGeometry.tickWidthInPoints / 2,
                    y: -(CursorRingGeometry.tickInnerRadiusInPoints + tickLength),
                    width: CursorRingGeometry.tickWidthInPoints,
                    height: tickLength
                )
                turnedContext.fill(Path(roundedRect: tickRect, cornerRadius: CursorRingGeometry.tickWidthInPoints / 2), with: .color(color))
            }
        }
        .shadow(color: color.opacity(0.55), radius: 5)
    }
}

/// Three dots orbiting the cursor once every 1.2 seconds. With Reduce Motion they stay put and breathe.
private struct ThinkingDotsView: View {
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The orbit and the breath both count from the moment the dots appear, so they always start at the top.
    @State private var appearedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 10.0 : 1.0 / 36.0)) { timelineContext in
            let secondsSinceAppearing = timelineContext.date.timeIntervalSince(appearedAt)
            let dotPlacements = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: reduceMotion ? 0 : secondsSinceAppearing)
            let breathShare = reduceMotion ? CursorRingGeometry.stillDotBrightness(secondsSinceTheBreathBegan: secondsSinceAppearing) : 1
            Canvas { context, size in
                let ringCenter = CGPoint(x: size.width / 2, y: size.height / 2)
                let dotRadius = CursorRingGeometry.dotDiameterInPoints / 2
                for dotPlacement in dotPlacements {
                    let dotRect = CGRect(
                        x: ringCenter.x + dotPlacement.offset.x - dotRadius,
                        y: ringCenter.y + dotPlacement.offset.y - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(color.opacity(dotPlacement.opacity * breathShare)))
                }
            }
            .shadow(color: color.opacity(0.55), radius: 6)
        }
    }
}
