//
//  CursorCue.swift
//  leanring-buddy
//
//  The ring around the cursor, which gives Clicky's voice states one home: a ring of ticks that follows
//  your voice while you speak, and three dots orbiting the cursor while Clicky thinks. Speaking hides the
//  ring, because the speech Callout brightens its words with the voice. A status line's Callout sits above the cursor and
//  does not hide the ring, so the ring keeps showing, and while it shows the dots orbit closer in (17 points instead of
//  24), so a dot at the top of its orbit stays under the Callout's body and crosses only its tail. While a loop shows
//  around the media Clicky is looking at, the loop's shimmer is the thinking light instead, and the dots stay away.
//
//  The cues hand off to one another instead of cutting: on release the ticks shrink into the dots (0.3 s), and when speech
//  starts the dots fly into the speech Callout's tail (0.38 s). Reduce Motion crossfades every cue change.
//

import CoreGraphics
import SwiftUI

/// What is moving at the cursor. One cue at a time: ticks while listening, the dots or the loop's shimmer
/// while thinking, and the speech Callout while speaking.
enum CursorCue: Equatable {
    /// Nothing moves at the cursor.
    case idle
    case listening
    case thinkingWithDots
    /// The loop's shimmer is the thinking light, so the ring shows nothing.
    case thinkingWithLoop
    case speaking
}

func cursorCue(voiceState: CompanionVoiceState, loopIsShowing: Bool) -> CursorCue {
    if loopIsShowing { return .thinkingWithLoop }
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
    /// How far above the cursor's center a status line's Callout body starts: its tail's tip, then the tail.
    static let statusLineCalloutBodyRiseAboveTheCursorInPoints: CGFloat = tetherCalloutTipRiseAboveTheCursor + TetherCalloutShape.tailHeight
    /// The orbit while a status line shows: a dot at the top stays 1 point under the Callout's body.
    static let dotOrbitRadiusUnderAStatusLineInPoints: CGFloat = statusLineCalloutBodyRiseAboveTheCursorInPoints - dotDiameterInPoints / 2 - 1

    /// How far out the dots orbit. A status line's Callout sits above the cursor, so its dots orbit closer in.
    static func dotOrbitRadius(aStatusLineShows: Bool) -> CGFloat {
        aStatusLineShows ? dotOrbitRadiusUnderAStatusLineInPoints : dotOrbitRadiusInPoints
    }
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
    static func dotPlacements(
        secondsSinceTheOrbitBegan secondsSinceBegan: TimeInterval,
        orbitRadius: CGFloat = dotOrbitRadiusInPoints
    ) -> [(offset: CGPoint, opacity: Double)] {
        let degreesTurned = 360 * secondsSinceBegan / secondsPerDotOrbit
        return (0..<dotCount).map { dotIndex in
            let angleInRadians = (dotStartingAnglesInDegrees[dotIndex] + degreesTurned) * .pi / 180
            return (
                offset: CGPoint(x: cos(angleInRadians) * orbitRadius, y: sin(angleInRadians) * orbitRadius),
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

/// One mark of the ring while it hands off: a rounded bar at an angle (clockwise from straight up) and a distance from
/// the cursor's center. A tick is a long thin one, and a dot is a short, fat one.
struct CursorRingMark: Equatable {
    var angleDegrees: Double
    /// Distance from the cursor's center to the middle of the mark.
    var centerRadiusInPoints: CGFloat
    /// The mark's size along the radius.
    var radialLengthInPoints: CGFloat
    /// The mark's size across the radius.
    var thicknessInPoints: CGFloat
    var opacity: Double
}

/// How one cue hands its marks to the next.
enum CursorRingHandoff: Equatable {
    /// On release: the ticks shrink into the three dots.
    case ticksIntoDots
    /// When speech starts: the dots fly into the speech Callout's tail.
    case dotsIntoSpeech

    static let ticksIntoDotsSeconds: TimeInterval = 0.3
    static let dotsIntoSpeechSeconds: TimeInterval = 0.38

    /// Where the speech Callout's tail tip touches, from the cursor's center: just above the triangle (`speechCalloutCenter`).
    static let defaultSpeechTailOffset = CGPoint(x: 0, y: -tetherCalloutTipRiseAboveTheCursor)

    var seconds: TimeInterval {
        switch self {
        case .ticksIntoDots: return Self.ticksIntoDotsSeconds
        case .dotsIntoSpeech: return Self.dotsIntoSpeechSeconds
        }
    }

    /// The handoff a change of cue plays. Nil for every other change, which crossfades, and for all of them under Reduce Motion.
    static func playedByAChange(from previousCue: CursorCue, to newCue: CursorCue, reduceMotionIsOn: Bool) -> CursorRingHandoff? {
        guard !reduceMotionIsOn else { return nil }
        switch (previousCue, newCue) {
        case (.listening, .thinkingWithDots): return .ticksIntoDots
        case (.thinkingWithDots, .speaking): return .dotsIntoSpeech
        default: return nil
        }
    }
}

extension CursorRingGeometry {
    /// The marks of the ticks while they shrink into the dots, `progress` of the way from 0 to 1. The ticks at 0, 120, and 240
    /// degrees become the three dots, and each other tick slides to its nearest dot while it shrinks and fades out, so at 1
    /// the ring is exactly the dots' first frame (`dotPlacements(secondsSinceTheOrbitBegan: 0)`).
    static func tickMarksTurningIntoDots(tickLengths: [CGFloat], progress: Double) -> [CursorRingMark] {
        let easedProgress = MoveBezier.smoothstep.progress(atLinearProgress: progress)
        let ticksPerDot = tickCount / dotCount
        return tickLengths.enumerated().map { tickIndex, tickLength in
            let nearestDotNumber = Int((Double(tickIndex) / Double(ticksPerDot)).rounded())
            let startAngle = 360 * Double(tickIndex) / Double(tickCount)
            // The last ticks are nearest the first dot a full turn on, so the angle is not wrapped back to 0.
            let endAngle = 360 * Double(nearestDotNumber * ticksPerDot) / Double(tickCount)
            let isTheTickThatBecomesADot = tickIndex % ticksPerDot == 0
            let dotOpacity = dotOpacities[(tickIndex / ticksPerDot) % dotCount]
            let startOpacity = 1.0
            let endOpacity = isTheTickThatBecomesADot ? dotOpacity : 0
            let startCenterRadius = tickInnerRadiusInPoints + tickLength / 2
            return CursorRingMark(
                angleDegrees: startAngle + (endAngle - startAngle) * easedProgress,
                centerRadiusInPoints: startCenterRadius + (dotOrbitRadiusInPoints - startCenterRadius) * easedProgress,
                radialLengthInPoints: tickLength + (dotDiameterInPoints - tickLength) * easedProgress,
                thicknessInPoints: tickWidthInPoints + (dotDiameterInPoints - tickWidthInPoints) * easedProgress,
                opacity: startOpacity + (endOpacity - startOpacity) * easedProgress
            )
        }
    }

    /// Where the dots are while they fly from their orbit into the speech Callout's tail, `progress` of the way from 0 to 1.
    /// They start where the orbit had them (`secondsSinceTheOrbitBegan`), shrink to half their size, and fade out at the tail,
    /// where the Callout pops in.
    static func dotsFlyingIntoTheSpeechTail(
        secondsSinceTheOrbitBegan: TimeInterval,
        orbitRadius: CGFloat = dotOrbitRadiusInPoints,
        speechTailOffset: CGPoint,
        progress: Double
    ) -> [(offset: CGPoint, diameter: CGFloat, opacity: Double)] {
        let easedProgress = MoveBezier.smoothstep.progress(atLinearProgress: progress)
        return dotPlacements(secondsSinceTheOrbitBegan: secondsSinceTheOrbitBegan, orbitRadius: orbitRadius).map { orbitPlacement in
            (
                offset: CGPoint(
                    x: orbitPlacement.offset.x + (speechTailOffset.x - orbitPlacement.offset.x) * easedProgress,
                    y: orbitPlacement.offset.y + (speechTailOffset.y - orbitPlacement.offset.y) * easedProgress
                ),
                diameter: dotDiameterInPoints * (1 - 0.5 * easedProgress),
                opacity: orbitPlacement.opacity * (1 - easedProgress * easedProgress)
            )
        }
    }
}

/// The ring, centered on the point it is given. It shows only for the two cues that use it. A change between cues crossfades,
/// except the two handoffs of `CursorRingHandoff`, which move the marks from one cue to the next.
struct CursorRingView: View {
    let cue: CursorCue
    let audioPowerLevel: CGFloat
    let color: Color
    /// Whether a status line's Callout shows above the cursor, which pulls the dots' orbit in under it.
    var aStatusLineShows = false
    /// Where the dots fly when speech starts, from the cursor's center.
    var speechTailOffset: CGPoint = CursorRingHandoff.defaultSpeechTailOffset
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The handoff that is playing, and what it needs from the cue it replaced.
    @State private var playingHandoff: PlayingRingHandoff?
    /// When the dots began to orbit, so a handoff out of them starts where the orbit is.
    @State private var dotsBeganOrbitingAt = Date()
    /// The cue `onChange` last saw. Until it catches up with `cue`, the view is drawing the render a cue change started, which
    /// is too early for the dots: the handoff or the orbit's start time is not set yet.
    @State private var lastSeenCue: CursorCue?

    var body: some View {
        ZStack {
            if let playingHandoff {
                CursorRingHandoffView(playingHandoff: playingHandoff, speechTailOffset: speechTailOffset, color: color)
            }
            if cue == .listening {
                ListeningTicksView(audioPowerLevel: audioPowerLevel, color: color)
                    .transition(.opacity)
            }
            if cue == .thinkingWithDots, playingHandoff == nil, lastSeenCue == nil || lastSeenCue == cue {
                ThinkingDotsView(color: color, orbitBeganAt: dotsBeganOrbitingAt, orbitRadius: CursorRingGeometry.dotOrbitRadius(aStatusLineShows: aStatusLineShows))
                    // After the ticks turned into the dots, the dots are already on screen, so they do not fade in again.
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .opacity))
            }
        }
        .frame(width: CursorRingGeometry.outerRadiusInPoints * 2, height: CursorRingGeometry.outerRadiusInPoints * 2)
        .animation(.easeOut(duration: DS.Move.fadeSeconds), value: cue)
        // The orbit eases in and out as a status line comes and goes. With Reduce Motion on the dots move to the new radius
        // with no travel.
        .animation(reduceMotion ? nil : DS.Move.snap.animation(reduceMotionIsOn: false), value: aStatusLineShows)
        .allowsHitTesting(false)
        .onAppear { lastSeenCue = cue }
        .onChange(of: cue) { previousCue, newCue in
            beginAHandoffIfTheChangePlaysOne(from: previousCue, to: newCue)
            lastSeenCue = newCue
        }
    }

    private func beginAHandoffIfTheChangePlaysOne(from previousCue: CursorCue, to newCue: CursorCue) {
        let now = Date()
        guard let handoff = CursorRingHandoff.playedByAChange(from: previousCue, to: newCue, reduceMotionIsOn: reduceMotion) else {
            playingHandoff = nil
            if newCue == .thinkingWithDots { dotsBeganOrbitingAt = now }
            return
        }
        let handoffToPlay = PlayingRingHandoff(
            handoff: handoff,
            startedAt: now,
            // The ticks keep the lengths they had at the release, so the voice dying away does not shrink them early.
            tickLengthsAtTheStart: CursorRingGeometry.tickLengths(
                audioPowerLevel: audioPowerLevel,
                shimmerPhase: now.timeIntervalSinceReferenceDate * 5
            ),
            // The ticks may have turned into the dots only a moment ago, so the orbit may not have begun: it starts at the top.
            secondsTheDotsHadOrbitedAtTheStart: max(now.timeIntervalSince(dotsBeganOrbitingAt), 0),
            dotOrbitRadiusAtTheStart: CursorRingGeometry.dotOrbitRadius(aStatusLineShows: aStatusLineShows)
        )
        playingHandoff = handoffToPlay
        // The dots start orbiting at the top where the ticks left them.
        if handoff == .ticksIntoDots { dotsBeganOrbitingAt = now.addingTimeInterval(handoff.seconds) }
        Task {
            try? await Task.sleep(for: .seconds(handoff.seconds))
            // A newer cue change replaced this handoff, so it clears the state itself.
            if playingHandoff?.startedAt == handoffToPlay.startedAt { playingHandoff = nil }
        }
    }
}

/// One handoff in progress.
private struct PlayingRingHandoff: Equatable {
    let handoff: CursorRingHandoff
    let startedAt: Date
    let tickLengthsAtTheStart: [CGFloat]
    let secondsTheDotsHadOrbitedAtTheStart: TimeInterval
    let dotOrbitRadiusAtTheStart: CGFloat
}

/// Draws a handoff frame by frame, from its start to its end.
private struct CursorRingHandoffView: View {
    let playingHandoff: PlayingRingHandoff
    let speechTailOffset: CGPoint
    let color: Color

    var body: some View {
        TimelineView(.explicit(cursorMotionFrameDates(startingAt: playingHandoff.startedAt, forSeconds: playingHandoff.handoff.seconds))) { timelineContext in
            let progress = min(max(timelineContext.date.timeIntervalSince(playingHandoff.startedAt) / playingHandoff.handoff.seconds, 0), 1)
            Canvas { context, size in
                let ringCenter = CGPoint(x: size.width / 2, y: size.height / 2)
                switch playingHandoff.handoff {
                case .ticksIntoDots:
                    for mark in CursorRingGeometry.tickMarksTurningIntoDots(tickLengths: playingHandoff.tickLengthsAtTheStart, progress: progress) {
                        var turnedContext = context
                        turnedContext.translateBy(x: ringCenter.x, y: ringCenter.y)
                        turnedContext.rotate(by: .degrees(mark.angleDegrees))
                        // The mark is drawn pointing up from the center, then turned around it, as a tick is.
                        let markRect = CGRect(
                            x: -mark.thicknessInPoints / 2,
                            y: -(mark.centerRadiusInPoints + mark.radialLengthInPoints / 2),
                            width: mark.thicknessInPoints,
                            height: mark.radialLengthInPoints
                        )
                        turnedContext.fill(
                            Path(roundedRect: markRect, cornerRadius: min(markRect.width, markRect.height) / 2),
                            with: .color(color.opacity(mark.opacity))
                        )
                    }
                case .dotsIntoSpeech:
                    for dot in CursorRingGeometry.dotsFlyingIntoTheSpeechTail(
                        secondsSinceTheOrbitBegan: playingHandoff.secondsTheDotsHadOrbitedAtTheStart,
                        orbitRadius: playingHandoff.dotOrbitRadiusAtTheStart,
                        speechTailOffset: speechTailOffset,
                        progress: progress
                    ) {
                        let dotRect = CGRect(
                            x: ringCenter.x + dot.offset.x - dot.diameter / 2,
                            y: ringCenter.y + dot.offset.y - dot.diameter / 2,
                            width: dot.diameter,
                            height: dot.diameter
                        )
                        context.fill(Path(ellipseIn: dotRect), with: .color(color.opacity(dot.opacity)))
                    }
                }
            }
            .shadow(color: color.opacity(0.55), radius: 5)
        }
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

/// Three dots orbiting the cursor once every 1.2 seconds. With Reduce Motion they stay put and breathe. The orbit's radius
/// animates, so the dots ease in under a status line's Callout and back out when it goes.
private struct ThinkingDotsView: View, Animatable {
    let color: Color
    /// The orbit and the breath both count from here, so they always start at the top. It is the moment the dots appear, or
    /// the moment the ticks finished turning into them.
    let orbitBeganAt: Date
    var orbitRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var animatableData: CGFloat {
        get { orbitRadius }
        set { orbitRadius = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 / 10.0 : 1.0 / 36.0)) { timelineContext in
            let secondsSinceAppearing = max(timelineContext.date.timeIntervalSince(orbitBeganAt), 0)
            let dotPlacements = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: reduceMotion ? 0 : secondsSinceAppearing, orbitRadius: orbitRadius)
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
