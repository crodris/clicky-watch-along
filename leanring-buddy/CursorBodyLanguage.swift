//
//  CursorBodyLanguage.swift
//  leanring-buddy
//
//  How the cursor's body moves, for every cursor kind (the triangle, a theme's shapes, a picture, a school's volleyball):
//  the stretch along its flight and the squash on landing (the Point move), the ring that marks where it landed, and the
//  three emotes: a nod when Clicky hears a command, a shake on a failure, and a hop with a ring on a correct answer.
//  Every rule is a pure function of time, so tests check each without drawing. Each motion has a Reduce Motion form:
//  the flight, the squash, the nod, the hop, and the shake's travel stop, a still ring marks the landing, and a short tint
//  carries the emote's meaning, so a failure still reads through its red.
//

import SwiftUI

// MARK: - Frame schedule

/// The dates a `TimelineView` redraws on for a motion that starts at `startDate` and lasts `seconds`, so the view stops
/// redrawing by itself when the motion ends. The last date is at or past the end.
func cursorMotionFrameDates(startingAt startDate: Date, forSeconds seconds: Double, framesPerSecond: Double = 60) -> [Date] {
    let frameCount = Int((seconds * framesPerSecond).rounded(.up))
    return (0...max(frameCount, 0)).map { frameIndex in
        startDate.addingTimeInterval(Double(frameIndex) / framesPerSecond)
    }
}

// MARK: - Point flight

/// The shape of the cursor during a pointing flight and on landing (`DS.Move.point`).
enum CursorPointFlight {
    /// How fast the cursor is moving, from 0 at the start and the end of the flight to 1 at its middle, in the flight's
    /// share of its time (`linearProgress`, 0 to 1). It is the speed of a smoothstep, which is what the flight eases along.
    static func speedShare(linearProgress: Double) -> Double {
        let clampedProgress = min(max(linearProgress, 0), 1)
        return 4 * clampedProgress * (1 - clampedProgress)
    }

    /// The length of the cursor along its flight, from 1 at rest to `DS.Move.pointStretch` at full speed.
    static func stretchAlongTheFlight(speedShare: Double) -> CGFloat {
        1 + (DS.Move.pointStretch - 1) * CGFloat(min(max(speedShare, 0), 1))
    }

    /// The landing squash: the length along the flight drops to `DS.Move.pointSquashScale` in 30 ms, holds until
    /// `DS.Move.pointSquashSeconds`, then springs back to 1 with Snap. It is 1 before the landing and after the spring settles.
    static func squashAlongTheFlight(secondsSinceLanding: Double) -> CGFloat {
        guard secondsSinceLanding > 0 else { return 1 }
        let secondsToReachTheSquash = 0.03
        let squashDepth = 1 - DS.Move.pointSquashScale
        if secondsSinceLanding < secondsToReachTheSquash {
            return 1 - squashDepth * CGFloat(secondsSinceLanding / secondsToReachTheSquash)
        }
        if secondsSinceLanding < DS.Move.pointSquashSeconds {
            return DS.Move.pointSquashScale
        }
        let secondsIntoTheSpringBack = secondsSinceLanding - DS.Move.pointSquashSeconds
        guard secondsIntoTheSpringBack < totalSquashSpringBackSeconds else { return 1 }
        return DS.Move.pointSquashScale + squashDepth * CGFloat(DS.Move.snap.curve.progress(atSeconds: secondsIntoTheSpringBack))
    }

    static let totalSquashSpringBackSeconds = DS.Move.snap.curve.seconds()

    /// How long the landing squash lasts in all.
    static var landingSeconds: Double { DS.Move.pointSquashSeconds + totalSquashSpringBackSeconds }

    /// The size across the flight that keeps the cursor's area while it stretches or squashes along it.
    static func scaleAcrossTheFlight(alongScale: CGFloat) -> CGFloat {
        1 / alongScale.squareRoot()
    }
}

// MARK: - Landing ring

/// The ring that marks where the cursor landed on a target, so on a busy diagram the eye finds the label it chose.
enum CursorLandingRingRules {
    /// The ring starts this much bigger than its resting size and closes in on the target.
    static let startScale: CGFloat = 1.7

    /// How the ring looks `secondsSinceLanding` after the landing. It closes in with Pop and fades in; with Reduce Motion it
    /// only fades in over the flight's Reduce Motion fade and stays still. `secondsSinceTheRingEnded` is nil while the ring
    /// stays, and counts the fade out after the cursor leaves the target. Not yet landed, it is invisible.
    static func appearance(
        secondsSinceLanding: Double,
        secondsSinceTheRingEnded: Double?,
        reduceMotionIsOn: Bool
    ) -> (scale: CGFloat, opacity: Double) {
        guard secondsSinceLanding > 0 else { return (1, 0) }
        let fadeOutShare: Double
        if let secondsSinceTheRingEnded {
            fadeOutShare = 1 - min(max(secondsSinceTheRingEnded / DS.Move.fadeSeconds, 0), 1)
        } else {
            fadeOutShare = 1
        }
        if reduceMotionIsOn {
            let fadeInSeconds = DS.Move.point.reduceMotionForm.fadeSeconds
            return (1, min(secondsSinceLanding / fadeInSeconds, 1) * fadeOutShare)
        }
        let closingInShare = 1 - CGFloat(DS.Move.pop.curve.progress(atSeconds: secondsSinceLanding))
        return (
            1 + (startScale - 1) * closingInShare,
            min(secondsSinceLanding / DS.Move.popFadeInSeconds, 1) * fadeOutShare
        )
    }

    /// How long a frame schedule should run after the landing, until the ring has finished moving.
    static var arrivingSeconds: Double { max(DS.Move.pop.curve.seconds(), DS.Move.point.reduceMotionForm.fadeSeconds) }
}

/// A landing ring on screen: where it is, when the cursor landed, and when the cursor left, which starts its fade out.
struct CursorLandingRing: Equatable {
    let center: CGPoint
    let landedAt: Date
    var endedAt: Date?
}

// MARK: - Emotes

/// What the cursor does with its body. Each pairs with a short Callout, so no meaning rests on the motion alone.
enum CursorEmote: Equatable, Sendable {
    /// Clicky heard a command.
    case nod
    /// A failure, or a first wrong quiz answer.
    case shake
    /// A correct answer.
    case hop
}

/// A request to play an emote. The number tells two requests for the same emote apart, so the second one plays too.
struct CursorEmoteRequest: Equatable, Sendable {
    let emote: CursorEmote
    let sequenceNumber: Int
}

/// An emote that is playing.
struct PlayingCursorEmote: Equatable {
    let emote: CursorEmote
    let startedAt: Date
}

/// The cursor's offset, the tint over it, and the ring around it at one moment of an emote.
struct CursorEmotePose: Equatable {
    var offset: CGSize
    /// How much of the meaning color covers the cursor, from 0 to 1.
    var tintStrength: Double
    /// The ring that bursts from a correct answer. Its diameter and opacity are 0 when there is none.
    var ringDiameter: CGFloat
    var ringOpacity: Double

    static let rest = CursorEmotePose(offset: .zero, tintStrength: 0, ringDiameter: 0, ringOpacity: 0)
}

enum CursorEmoteRules {
    /// A nod dips twice, this deep, each dip taking `nodDipSeconds`.
    static let nodDepthInPoints: CGFloat = 3.5
    static let nodDipSeconds: Double = 0.18
    static let nodDipCount = 2

    /// A hop rises this high and comes back down in `hopSeconds`, with a ring that opens from `DS.Move.pointLandingRingDiameter`
    /// to `hopRingEndDiameter` and fades over `hopRingSeconds`.
    static let hopHeightInPoints: CGFloat = 10
    static let hopSeconds: Double = 0.4
    static let hopRingSeconds: Double = 0.5
    static let hopRingEndDiameter: CGFloat = 52
    static let hopRingStartOpacity: Double = 0.9

    /// With Reduce Motion every emote is a tint that rises in `DS.Move.fadeSeconds`, holds, and falls the same way.
    static let reducedMotionSeconds: Double = 0.5
    /// The share of the cursor the meaning color covers at its strongest.
    static let tintPeakStrength: Double = 0.5

    /// How long an emote plays.
    static func seconds(of emote: CursorEmote, reduceMotionIsOn: Bool) -> Double {
        if reduceMotionIsOn { return reducedMotionSeconds }
        switch emote {
        case .nod: return Double(nodDipCount) * nodDipSeconds
        case .shake: return DS.Move.shake.curve.seconds()
        case .hop: return max(hopSeconds, hopRingSeconds)
        }
    }

    /// Whether the emote tints the cursor while it moves. A failure and a right answer tint in every mode, so their color
    /// is there with the motion, and a nod tints only when Reduce Motion takes the motion away.
    static func tintsWhileMoving(_ emote: CursorEmote) -> Bool {
        emote != .nod
    }

    /// Rises over `DS.Move.fadeSeconds`, holds, and falls the same way at the end, 0 outside `totalSeconds`.
    static func tintEnvelope(secondsSinceStart: Double, totalSeconds: Double) -> Double {
        guard secondsSinceStart > 0, secondsSinceStart < totalSeconds else { return 0 }
        let rampSeconds = DS.Move.fadeSeconds
        return min(secondsSinceStart / rampSeconds, 1, (totalSeconds - secondsSinceStart) / rampSeconds)
    }

    static func pose(of emote: CursorEmote, secondsSinceStart: Double, reduceMotionIsOn: Bool) -> CursorEmotePose {
        let totalSeconds = seconds(of: emote, reduceMotionIsOn: reduceMotionIsOn)
        guard secondsSinceStart > 0, secondsSinceStart < totalSeconds else { return .rest }
        let tintStrength = tintPeakStrength * tintEnvelope(secondsSinceStart: secondsSinceStart, totalSeconds: totalSeconds)

        if reduceMotionIsOn {
            // The hop's ring stays still at the landing ring's size and fades with the tint.
            let stillRingOpacity = emote == .hop ? hopRingStartOpacity * tintEnvelope(secondsSinceStart: secondsSinceStart, totalSeconds: totalSeconds) : 0
            return CursorEmotePose(
                offset: .zero,
                tintStrength: tintStrength,
                ringDiameter: emote == .hop ? DS.Move.pointLandingRingDiameter : 0,
                ringOpacity: stillRingOpacity
            )
        }

        switch emote {
        case .nod:
            let dipPhase = Double.pi * secondsSinceStart / nodDipSeconds
            return CursorEmotePose(offset: CGSize(width: 0, height: nodDepthInPoints * CGFloat(sin(dipPhase) * sin(dipPhase))), tintStrength: 0, ringDiameter: 0, ringOpacity: 0)
        case .shake:
            let swingShare = DS.Move.shake.curve.progress(atSeconds: secondsSinceStart)
            return CursorEmotePose(offset: CGSize(width: DS.Move.shakeAmplitudePoints * CGFloat(swingShare), height: 0), tintStrength: tintStrength, ringDiameter: 0, ringOpacity: 0)
        case .hop:
            let hopShare = min(secondsSinceStart / hopSeconds, 1)
            let heightShare = CGFloat(4 * hopShare * (1 - hopShare))
            let ringShare = min(secondsSinceStart / hopRingSeconds, 1)
            // Ease out, so the ring opens fast and settles as it fades.
            let ringOpenShare = CGFloat(1 - (1 - ringShare) * (1 - ringShare))
            return CursorEmotePose(
                offset: CGSize(width: 0, height: -hopHeightInPoints * heightShare),
                tintStrength: tintStrength,
                ringDiameter: DS.Move.pointLandingRingDiameter + (hopRingEndDiameter - DS.Move.pointLandingRingDiameter) * ringOpenShare,
                ringOpacity: hopRingStartOpacity * (1 - ringShare)
            )
        }
    }

    /// The color that covers the cursor: red for a failure and green for a right answer, the colors that mean those on every
    /// theme, and a white lift for a nod.
    static func tintColor(of emote: CursorEmote) -> Color {
        switch emote {
        case .nod: return .white
        case .shake: return DS.Colors.destructive
        case .hop: return DS.Colors.success
        }
    }
}

/// The emote a quiz answer's reveal gets: a hop for a right name, a shake for a first wrong answer, and none when the name is
/// revealed on a request for help or a second wrong answer, which is neither a win nor a fresh failure.
func cursorEmote(forAnswerOutcome revealOutcome: LiveSceneRevealOutcome) -> CursorEmote? {
    switch revealOutcome {
    case .celebrateCorrectName: return .hop
    case .shakeAndKeepTheQuestionMark: return .shake
    case .revealWithoutCelebration: return nil
    }
}

// MARK: - Views

/// The cursor's glyph with its body language: the glow and contact shadow, the stretch and squash of a flight and a landing,
/// and the emote that is playing. The glyph is whatever cursor the theme draws, already turned to face its way.
struct CursorBodyLanguageView<Glyph: View>: View {
    let glyph: Glyph
    let glowColor: Color
    /// From `CursorPointFlight.speedShare`: 0 while following or at rest.
    let flightSpeedShare: Double
    /// The direction of travel, in the rotation convention of `triangleRotationDegrees`: 0 is straight up, clockwise.
    let flightDirectionDegrees: Double
    let playingEmote: PlayingCursorEmote?
    let landedAt: Date?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.explicit(frameSchedule)) { timelineContext in
            CursorBodyLanguageFrameView(
                glyph: glyph,
                glowColor: glowColor,
                flightSpeedShare: flightSpeedShare,
                flightDirectionDegrees: flightDirectionDegrees,
                playingEmote: playingEmote,
                landedAt: landedAt,
                drawnAt: timelineContext.date,
                reduceMotionIsOn: reduceMotion
            )
        }
    }

    /// Redraws while an emote or the landing squash plays and stops after, since a past date draws the resting pose.
    private var frameSchedule: [Date] {
        var dates: [Date] = []
        if let playingEmote {
            dates += cursorMotionFrameDates(
                startingAt: playingEmote.startedAt,
                forSeconds: CursorEmoteRules.seconds(of: playingEmote.emote, reduceMotionIsOn: reduceMotion)
            )
        }
        if let landedAt, !reduceMotion {
            dates += cursorMotionFrameDates(startingAt: landedAt, forSeconds: CursorPointFlight.landingSeconds)
        }
        return dates.isEmpty ? [Date.distantPast] : dates.sorted()
    }
}

/// One frame of the cursor's body language at a date. The timeline above hands it the date, and a test hands it any date.
struct CursorBodyLanguageFrameView<Glyph: View>: View {
    let glyph: Glyph
    let glowColor: Color
    let flightSpeedShare: Double
    let flightDirectionDegrees: Double
    let playingEmote: PlayingCursorEmote?
    let landedAt: Date?
    let drawnAt: Date
    let reduceMotionIsOn: Bool

    var body: some View {
        let emotePose = playingEmote.map { emote in
            CursorEmoteRules.pose(
                of: emote.emote,
                secondsSinceStart: drawnAt.timeIntervalSince(emote.startedAt),
                reduceMotionIsOn: reduceMotionIsOn
            )
        } ?? .rest
        let alongScale = alongScale()
        let acrossScale = CursorPointFlight.scaleAcrossTheFlight(alongScale: alongScale)
        CursorTintedGlyph(
            glyph: glyph,
            tintColor: playingEmote.map { CursorEmoteRules.tintColor(of: $0.emote) } ?? .clear,
            tintStrength: emotePose.tintStrength
        )
            // Stretches along the direction of travel whatever way the glyph itself faces: turn the axes to the flight,
            // scale, and turn back.
            .rotationEffect(.degrees(-flightDirectionDegrees))
            .scaleEffect(x: acrossScale, y: alongScale)
            .rotationEffect(.degrees(flightDirectionDegrees))
            .shadow(
                color: glowColor.opacity(CursorGlyphShade.glowOpacity),
                radius: CursorGlyphShade.glowRadiusInPoints + CursorGlyphShade.glowRadiusGrowthAtFullSpeedInPoints * CGFloat(flightSpeedShare)
            )
            .shadow(
                color: .black.opacity(CursorGlyphShade.contactShadowOpacity),
                radius: CursorGlyphShade.contactShadowRadiusInPoints,
                x: 0,
                y: CursorGlyphShade.contactShadowOffsetInPoints
            )
            .offset(emotePose.offset)
            .background {
                if emotePose.ringOpacity > 0, let playingEmote {
                    Circle()
                        .stroke(CursorEmoteRules.tintColor(of: playingEmote.emote).opacity(emotePose.ringOpacity), lineWidth: 2)
                        .frame(width: emotePose.ringDiameter, height: emotePose.ringDiameter)
                }
            }
    }

    /// The glyph's length along the flight: stretched in the air, squashed on landing. Reduce Motion has neither.
    private func alongScale() -> CGFloat {
        guard !reduceMotionIsOn else { return 1 }
        let squash = landedAt.map { CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: drawnAt.timeIntervalSince($0)) } ?? 1
        return CursorPointFlight.stretchAlongTheFlight(speedShare: flightSpeedShare) * squash
    }
}

/// The glyph with the emote's meaning color over only its own pixels, so a failure reads in red on any cursor and the
/// transparent corners stay clear.
struct CursorTintedGlyph<Glyph: View>: View {
    let glyph: Glyph
    let tintColor: Color
    let tintStrength: Double

    var body: some View {
        // Always the same view tree, so a tint starting or ending never rebuilds the glyph and restarts its animations. The
        // wash reaches past the glyph's frame, since a rotated triangle's tips do, and the blend keeps it on the glyph's pixels.
        glyph
            .overlay { tintColor.opacity(tintStrength).padding(-16).blendMode(.sourceAtop) }
            .compositingGroup()
    }
}

/// The ring on the target the cursor landed on, centered on the view's center.
struct CursorLandingRingView: View {
    let landingRing: CursorLandingRing
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let strokeWidth: CGFloat = 2

    var body: some View {
        TimelineView(.explicit(frameSchedule)) { timelineContext in
            let appearance = CursorLandingRingRules.appearance(
                secondsSinceLanding: timelineContext.date.timeIntervalSince(landingRing.landedAt),
                secondsSinceTheRingEnded: landingRing.endedAt.map { timelineContext.date.timeIntervalSince($0) },
                reduceMotionIsOn: reduceMotion
            )
            Circle()
                .stroke(color, lineWidth: strokeWidth)
                .frame(width: DS.Move.pointLandingRingDiameter - strokeWidth, height: DS.Move.pointLandingRingDiameter - strokeWidth)
                .shadow(color: color.opacity(CursorGlyphShade.glowOpacity * 2), radius: 4)
                .scaleEffect(appearance.scale)
                .opacity(appearance.opacity)
        }
        .allowsHitTesting(false)
    }

    private var frameSchedule: [Date] {
        var dates = cursorMotionFrameDates(startingAt: landingRing.landedAt, forSeconds: CursorLandingRingRules.arrivingSeconds)
        if let endedAt = landingRing.endedAt {
            dates += cursorMotionFrameDates(startingAt: endedAt, forSeconds: DS.Move.fadeSeconds)
        }
        return dates.sorted()
    }
}
