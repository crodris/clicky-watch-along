//
//  CursorBodyLanguageTests.swift
//  leanring-buddyTests
//
//  The cursor's Point move (stretch, squash, landing ring), its nod, shake, and hop, their Reduce Motion forms, the glyph's
//  shading, and the ring's handoffs between its cues. Every rule is a pure function of time, and a few renders at 2x read
//  pixels, since a view that decodes fine can still draw nothing.
//

import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Clicky

struct CursorPointFlightTests {
    @Test func speedIsZeroAtBothEndsAndOneInTheMiddle() {
        #expect(CursorPointFlight.speedShare(linearProgress: 0) == 0)
        #expect(CursorPointFlight.speedShare(linearProgress: 1) == 0)
        #expect(CursorPointFlight.speedShare(linearProgress: 0.5) == 1)
        #expect(abs(CursorPointFlight.speedShare(linearProgress: 0.25) - CursorPointFlight.speedShare(linearProgress: 0.75)) < 1e-12)
    }

    @Test func stretchGrowsFromOneToThePointStretchAtFullSpeed() {
        #expect(CursorPointFlight.stretchAlongTheFlight(speedShare: 0) == 1)
        #expect(CursorPointFlight.stretchAlongTheFlight(speedShare: 1) == DS.Move.pointStretch)
        #expect(DS.Move.pointStretch == 1.15)
        // A share outside 0 to 1 never over-stretches.
        #expect(CursorPointFlight.stretchAlongTheFlight(speedShare: 3) == DS.Move.pointStretch)
    }

    @Test func squashDropsToNinetyPercentHoldsForEightyMillisecondsThenSpringsBackToOne() {
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: -0.1) == 1)
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: 0) == 1)
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: 0.015) < 1)
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: 0.04) == DS.Move.pointSquashScale)
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: 0.079) == DS.Move.pointSquashScale)
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: DS.Move.pointSquashSeconds + 0.03) > DS.Move.pointSquashScale)
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: CursorPointFlight.landingSeconds + 0.01) == 1)
    }

    @Test func squashEndsOnExactlyOneSoTheCursorSettlesAtItsNormalSize() {
        #expect(CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: 10) == 1)
        let nearTheEnd = CursorPointFlight.squashAlongTheFlight(secondsSinceLanding: CursorPointFlight.landingSeconds - 0.001)
        #expect(abs(nearTheEnd - 1) < 0.01)
    }

    @Test func theAreaIsKeptWhileTheCursorStretchesOrSquashes() {
        for alongScale in [CGFloat(0.9), 1, 1.15] {
            let acrossScale = CursorPointFlight.scaleAcrossTheFlight(alongScale: alongScale)
            #expect(abs(alongScale * acrossScale - alongScale.squareRoot()) < 1e-9)
            #expect(abs(alongScale * acrossScale * acrossScale - 1) < 1e-9)
        }
    }

    @Test func frameDatesStartAtTheStartAndReachTheEnd() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let dates = cursorMotionFrameDates(startingAt: start, forSeconds: 0.5)
        #expect(dates.first == start)
        #expect(dates.count == 31)
        #expect(dates.last! >= start.addingTimeInterval(0.5))
        #expect(dates == dates.sorted())
    }
}

struct CursorLandingRingTests {
    private func appearance(_ secondsSinceLanding: Double, ended secondsSinceEnd: Double? = nil, reduceMotion: Bool = false) -> (scale: CGFloat, opacity: Double) {
        CursorLandingRingRules.appearance(secondsSinceLanding: secondsSinceLanding, secondsSinceTheRingEnded: secondsSinceEnd, reduceMotionIsOn: reduceMotion)
    }

    @Test func theRingIsInvisibleBeforeTheLanding() {
        #expect(appearance(0).opacity == 0)
        #expect(appearance(-1).opacity == 0)
    }

    @Test func theRingClosesInOnTheTargetAndFadesIn() {
        let justLanded = appearance(0.01)
        #expect(justLanded.scale > 1.5)
        #expect(justLanded.opacity < 1)
        let settled = appearance(DS.Move.pop.curve.seconds() + 0.1)
        #expect(settled.scale == 1)
        #expect(settled.opacity == 1)
    }

    @Test func theRingKeepsItsSizeAndOpacityWhileTheCursorPointsAtTheTarget() {
        #expect(appearance(5).scale == 1)
        #expect(appearance(5).opacity == 1)
    }

    @Test func reduceMotionFadesTheRingInOverTheFlightsFadeTimeAndNeverScalesIt() {
        let fadeSeconds = DS.Move.point.reduceMotionForm.fadeSeconds
        #expect(fadeSeconds == 0.2)
        #expect(appearance(0.01, reduceMotion: true).scale == 1)
        #expect(abs(appearance(fadeSeconds / 2, reduceMotion: true).opacity - 0.5) < 1e-9)
        #expect(appearance(fadeSeconds, reduceMotion: true).opacity == 1)
        #expect(appearance(2, reduceMotion: true).scale == 1)
    }

    @Test func theRingFadesOutOverTheFadeTimeAfterTheCursorLeaves() {
        #expect(appearance(5, ended: 0).opacity == 1)
        #expect(abs(appearance(5, ended: DS.Move.fadeSeconds / 2).opacity - 0.5) < 1e-9)
        #expect(appearance(5, ended: DS.Move.fadeSeconds).opacity == 0)
        #expect(appearance(5, ended: 1, reduceMotion: true).opacity == 0)
    }

    @Test func theRingsOuterEdgeIsTwentyFourPoints() {
        #expect(DS.Move.pointLandingRingDiameter == 24)
    }
}

struct CursorEmoteTests {
    private func pose(_ emote: CursorEmote, _ seconds: Double, reduceMotion: Bool = false) -> CursorEmotePose {
        CursorEmoteRules.pose(of: emote, secondsSinceStart: seconds, reduceMotionIsOn: reduceMotion)
    }

    @Test func everyEmoteIsAtRestBeforeItStartsAndAfterItEnds() {
        for emote in [CursorEmote.nod, .shake, .hop] {
            for reduceMotion in [false, true] {
                let totalSeconds = CursorEmoteRules.seconds(of: emote, reduceMotionIsOn: reduceMotion)
                #expect(pose(emote, 0, reduceMotion: reduceMotion) == .rest)
                #expect(pose(emote, -0.2, reduceMotion: reduceMotion) == .rest)
                #expect(pose(emote, totalSeconds, reduceMotion: reduceMotion) == .rest)
                #expect(pose(emote, totalSeconds + 1, reduceMotion: reduceMotion) == .rest)
            }
        }
    }

    @Test func aNodDipsTwiceAndNeverRisesAboveItsStart() {
        #expect(CursorEmoteRules.seconds(of: .nod, reduceMotionIsOn: false) == 0.36)
        let deepestOfTheFirstDip = pose(.nod, CursorEmoteRules.nodDipSeconds / 2).offset.height
        let deepestOfTheSecondDip = pose(.nod, CursorEmoteRules.nodDipSeconds * 1.5).offset.height
        #expect(abs(deepestOfTheFirstDip - CursorEmoteRules.nodDepthInPoints) < 1e-9)
        #expect(abs(deepestOfTheSecondDip - CursorEmoteRules.nodDepthInPoints) < 1e-9)
        // Back at the start between the dips.
        #expect(abs(pose(.nod, CursorEmoteRules.nodDipSeconds).offset.height) < 1e-9)
        for step in 1..<36 {
            let offset = pose(.nod, Double(step) * 0.01).offset
            #expect(offset.height >= 0)
            #expect(offset.width == 0)
        }
    }

    @Test func aShakeFollowsTheShakeMoveAndStaysWithinItsAmplitude() {
        for step in 1..<45 {
            let seconds = Double(step) * 0.01
            let expectedOffset = DS.Move.shakeAmplitudePoints * CGFloat(DS.Move.shake.curve.progress(atSeconds: seconds))
            #expect(abs(pose(.shake, seconds).offset.width - expectedOffset) < 1e-9)
            #expect(abs(pose(.shake, seconds).offset.width) <= DS.Move.shakeAmplitudePoints)
            #expect(pose(.shake, seconds).offset.height == 0)
        }
        #expect(DS.Move.shakeAmplitudePoints == 7)
        #expect(CursorEmoteRules.seconds(of: .shake, reduceMotionIsOn: false) == 0.45)
    }

    @Test func aShakeIsRedAndAHopIsGreenWhileTheyMoveButANodIsNotTinted() {
        #expect(pose(.shake, 0.2).tintStrength > 0)
        #expect(pose(.hop, 0.25).tintStrength > 0)
        #expect(pose(.nod, 0.18).tintStrength == 0)
        #expect(CursorEmoteRules.tintsWhileMoving(.shake))
        #expect(CursorEmoteRules.tintsWhileMoving(.hop))
        #expect(!CursorEmoteRules.tintsWhileMoving(.nod))
    }

    @Test func aHopRisesTenPointsAndLandsBackAndItsRingOpensAndFades() {
        let peak = pose(.hop, CursorEmoteRules.hopSeconds / 2)
        #expect(abs(peak.offset.height + CursorEmoteRules.hopHeightInPoints) < 1e-9)
        #expect(pose(.hop, 0.45).offset.height == 0)
        let earlyRing = pose(.hop, 0.05)
        let lateRing = pose(.hop, 0.45)
        #expect(earlyRing.ringDiameter >= DS.Move.pointLandingRingDiameter)
        #expect(lateRing.ringDiameter > earlyRing.ringDiameter)
        #expect(lateRing.ringDiameter <= CursorEmoteRules.hopRingEndDiameter)
        #expect(earlyRing.ringOpacity > lateRing.ringOpacity)
        #expect(lateRing.ringOpacity > 0)
    }

    @Test func reduceMotionTakesTheTravelAwayAndKeepsTheMeaningAsATint() {
        for emote in [CursorEmote.nod, .shake, .hop] {
            #expect(CursorEmoteRules.seconds(of: emote, reduceMotionIsOn: true) == CursorEmoteRules.reducedMotionSeconds)
            let holding = pose(emote, 0.25, reduceMotion: true)
            #expect(holding.offset == .zero)
            #expect(abs(holding.tintStrength - CursorEmoteRules.tintPeakStrength) < 1e-9)
        }
    }

    @Test func aFailureStillReadsAsRedWithReduceMotionOn() {
        #expect(pose(.shake, 0.25, reduceMotion: true).tintStrength > 0.4)
        #expect(CursorEmoteRules.tintColor(of: .shake) == DS.Colors.destructive)
        #expect(CursorEmoteRules.tintColor(of: .hop) == DS.Colors.success)
    }

    @Test func theTintRisesAndFallsOverTheFadeTime() {
        let totalSeconds = CursorEmoteRules.reducedMotionSeconds
        #expect(CursorEmoteRules.tintEnvelope(secondsSinceStart: 0, totalSeconds: totalSeconds) == 0)
        #expect(abs(CursorEmoteRules.tintEnvelope(secondsSinceStart: DS.Move.fadeSeconds / 2, totalSeconds: totalSeconds) - 0.5) < 1e-9)
        #expect(CursorEmoteRules.tintEnvelope(secondsSinceStart: totalSeconds / 2, totalSeconds: totalSeconds) == 1)
        #expect(abs(CursorEmoteRules.tintEnvelope(secondsSinceStart: totalSeconds - DS.Move.fadeSeconds / 2, totalSeconds: totalSeconds) - 0.5) < 1e-9)
        #expect(CursorEmoteRules.tintEnvelope(secondsSinceStart: totalSeconds, totalSeconds: totalSeconds) == 0)
    }

    @Test func aRightAnswerHopsAFirstWrongAnswerShakesAndHelpDoesNothing() {
        #expect(cursorEmote(forAnswerOutcome: .celebrateCorrectName) == .hop)
        #expect(cursorEmote(forAnswerOutcome: .shakeAndKeepTheQuestionMark) == .shake)
        #expect(cursorEmote(forAnswerOutcome: .revealWithoutCelebration) == nil)
    }
}

struct CursorGlyphShadeTests {
    private func luminance(of shade: CursorGlyphShade) -> Double {
        0.2126 * shade.red + 0.7152 * shade.green + 0.0722 * shade.blue
    }

    @Test func theTriangleIsLightAtTheTipAndDeeperAtTheBase() throws {
        let shades = try #require(CursorGlyphShade.shades(accentHex: "#3B82F6"))
        #expect(luminance(of: shades.light) > luminance(of: shades.middle))
        #expect(luminance(of: shades.middle) > luminance(of: shades.deep))
        #expect(shades.middle == CursorGlyphShade(red: Double(0x3B) / 255, green: Double(0x82) / 255, blue: Double(0xF6) / 255))
    }

    @Test func aWhiteAccentStaysWhiteAtTheTipAndAnAccentThatIsNotAHexColorHasNoShading() throws {
        let white = try #require(CursorGlyphShade.shades(accentHex: "#FFFFFF"))
        #expect(white.light == .white)
        #expect(CursorGlyphShade.shades(accentHex: "blue") == nil)
    }

    @Test func theGlowStaysAtAQuarterOfTheAccent() {
        #expect(CursorGlyphShade.glowOpacity == 0.25)
    }
}

struct CursorRingHandoffTests {
    @Test func theTicksHandOffToTheDotsAndTheDotsToTheSpeechButNothingElseDoes() {
        #expect(CursorRingHandoff.playedByAChange(from: .listening, to: .thinkingWithDots, reduceMotionIsOn: false) == .ticksIntoDots)
        #expect(CursorRingHandoff.playedByAChange(from: .thinkingWithDots, to: .speaking, reduceMotionIsOn: false) == .dotsIntoSpeech)
        #expect(CursorRingHandoff.playedByAChange(from: .listening, to: .idle, reduceMotionIsOn: false) == nil)
        #expect(CursorRingHandoff.playedByAChange(from: .idle, to: .thinkingWithDots, reduceMotionIsOn: false) == nil)
        #expect(CursorRingHandoff.playedByAChange(from: .thinkingWithDots, to: .listening, reduceMotionIsOn: false) == nil)
        #expect(CursorRingHandoff.playedByAChange(from: .thinkingWithDots, to: .thinkingWithLoop, reduceMotionIsOn: false) == nil)
    }

    @Test func reduceMotionCrossfadesEveryChange() {
        #expect(CursorRingHandoff.playedByAChange(from: .listening, to: .thinkingWithDots, reduceMotionIsOn: true) == nil)
        #expect(CursorRingHandoff.playedByAChange(from: .thinkingWithDots, to: .speaking, reduceMotionIsOn: true) == nil)
    }

    @Test func theHandoffsTakeThreeHundredAndThreeHundredEightyMilliseconds() {
        #expect(CursorRingHandoff.ticksIntoDots.seconds == 0.3)
        #expect(CursorRingHandoff.dotsIntoSpeech.seconds == 0.38)
    }

    private let silentTickLengths = CursorRingGeometry.tickLengths(audioPowerLevel: 0.12, shimmerPhase: 0)

    @Test func atTheStartOfTheHandoffEveryMarkIsItsTick() {
        let marks = CursorRingGeometry.tickMarksTurningIntoDots(tickLengths: silentTickLengths, progress: 0)
        #expect(marks.count == CursorRingGeometry.tickCount)
        for (tickIndex, mark) in marks.enumerated() {
            #expect(abs(mark.angleDegrees - 360 * Double(tickIndex) / 24) < 1e-9)
            #expect(abs(mark.radialLengthInPoints - silentTickLengths[tickIndex]) < 1e-9)
            #expect(mark.thicknessInPoints == CursorRingGeometry.tickWidthInPoints)
            #expect(abs(mark.centerRadiusInPoints - (CursorRingGeometry.tickInnerRadiusInPoints + silentTickLengths[tickIndex] / 2)) < 1e-9)
            #expect(mark.opacity == 1)
        }
    }

    @Test func atTheEndOfTheHandoffTheRingIsExactlyTheDotsFirstFrame() {
        let marks = CursorRingGeometry.tickMarksTurningIntoDots(tickLengths: silentTickLengths, progress: 1)
        let dotsAtTheStart = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: 0)
        let leaderMarks = [marks[0], marks[8], marks[16]]
        for (dotIndex, leaderMark) in leaderMarks.enumerated() {
            // A dot's angle counts from the right turning down, and a mark's from straight up turning clockwise.
            let markAngleInRadians = (leaderMark.angleDegrees - 90) * .pi / 180
            let markCenter = CGPoint(
                x: cos(markAngleInRadians) * leaderMark.centerRadiusInPoints,
                y: sin(markAngleInRadians) * leaderMark.centerRadiusInPoints
            )
            #expect(abs(markCenter.x - dotsAtTheStart[dotIndex].offset.x) < 1e-9)
            #expect(abs(markCenter.y - dotsAtTheStart[dotIndex].offset.y) < 1e-9)
            #expect(leaderMark.radialLengthInPoints == CursorRingGeometry.dotDiameterInPoints)
            #expect(leaderMark.thicknessInPoints == CursorRingGeometry.dotDiameterInPoints)
            #expect(abs(leaderMark.opacity - dotsAtTheStart[dotIndex].opacity) < 1e-9)
        }
        for (tickIndex, mark) in marks.enumerated() where tickIndex % 8 != 0 {
            #expect(mark.opacity == 0)
        }
    }

    @Test func everyOtherTickSlidesToItsNearestDotWithoutCrossingTheRing() {
        let marks = CursorRingGeometry.tickMarksTurningIntoDots(tickLengths: silentTickLengths, progress: 1)
        let leaderAngles = [0.0, 120, 240, 360]
        for mark in marks {
            #expect(leaderAngles.contains { abs($0 - mark.angleDegrees) < 1e-9 })
        }
        // Tick 23 is nearest the first dot, a turn on, so it slides forward 15 degrees and not back 345.
        #expect(abs(marks[23].angleDegrees - 360) < 1e-9)
        let halfway = CursorRingGeometry.tickMarksTurningIntoDots(tickLengths: silentTickLengths, progress: 0.5)
        #expect(halfway[23].angleDegrees > 345 && halfway[23].angleDegrees < 360)
    }

    @Test func theLeaderTicksGrowDimmerAndShrinkMonotonically() {
        var previousLength = CGFloat.infinity
        for step in 0...10 {
            let mark = CursorRingGeometry.tickMarksTurningIntoDots(tickLengths: silentTickLengths, progress: Double(step) / 10)[1]
            #expect(mark.opacity <= 1)
            #expect(mark.radialLengthInPoints <= previousLength + 1e-9)
            previousLength = mark.radialLengthInPoints
        }
    }

    @Test func theDotsFlyFromTheirOrbitIntoTheSpeechTailAndFadeThere() {
        let tail = CursorRingHandoff.defaultSpeechTailOffset
        let orbit = CursorRingGeometry.dotPlacements(secondsSinceTheOrbitBegan: 0.7)
        let atTheStart = CursorRingGeometry.dotsFlyingIntoTheSpeechTail(secondsSinceTheOrbitBegan: 0.7, speechTailOffset: tail, progress: 0)
        let atTheEnd = CursorRingGeometry.dotsFlyingIntoTheSpeechTail(secondsSinceTheOrbitBegan: 0.7, speechTailOffset: tail, progress: 1)
        for dotIndex in 0..<CursorRingGeometry.dotCount {
            #expect(atTheStart[dotIndex].offset == orbit[dotIndex].offset)
            #expect(atTheStart[dotIndex].diameter == CursorRingGeometry.dotDiameterInPoints)
            #expect(atTheStart[dotIndex].opacity == orbit[dotIndex].opacity)
            #expect(abs(atTheEnd[dotIndex].offset.x - tail.x) < 1e-9)
            #expect(abs(atTheEnd[dotIndex].offset.y - tail.y) < 1e-9)
            #expect(atTheEnd[dotIndex].diameter == CursorRingGeometry.dotDiameterInPoints / 2)
            #expect(atTheEnd[dotIndex].opacity == 0)
        }
    }

    @Test func theDotsFlyToWhereTheSpeechCalloutsTailTipIs() {
        let cursorPosition = CGPoint(x: 400, y: 300)
        let calloutSize = CGSize(width: 200, height: 52)
        let calloutCenter = speechCalloutCenter(cursorPosition: cursorPosition, calloutSize: calloutSize, screenSize: CGSize(width: 1200, height: 800))
        let tailTip = TetherCalloutShape.tailTip(inCalloutOfSize: calloutSize)
        let tailTipOnScreen = CGPoint(x: calloutCenter.x - calloutSize.width / 2 + tailTip.x, y: calloutCenter.y - calloutSize.height / 2 + tailTip.y)
        #expect(abs(tailTipOnScreen.x - (cursorPosition.x + CursorRingHandoff.defaultSpeechTailOffset.x)) < 1e-9)
        #expect(abs(tailTipOnScreen.y - (cursorPosition.y + CursorRingHandoff.defaultSpeechTailOffset.y)) < 1e-9)
    }

    @Test func everyDotStaysInsideTheRingsFrameWhileItFlies() {
        let limit = CursorRingGeometry.outerRadiusInPoints
        for step in 0...20 {
            for dot in CursorRingGeometry.dotsFlyingIntoTheSpeechTail(
                secondsSinceTheOrbitBegan: 0.4,
                speechTailOffset: CursorRingHandoff.defaultSpeechTailOffset,
                progress: Double(step) / 20
            ) {
                #expect(abs(dot.offset.x) + dot.diameter / 2 <= limit)
                #expect(abs(dot.offset.y) + dot.diameter / 2 <= limit)
            }
        }
    }
}

@MainActor
struct CursorBodyLanguageRenderTests {
    private func renderedPixels(of view: some View, side: CGFloat) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func clickyBlueTheme() throws -> ClickyTheme {
        try #require(bundledThemesForTests.first { $0.id == "clicky-blue" })
    }

    private func brightness(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
    }

    @Test func theTriangleIsLighterNearItsTipThanAtItsBase() throws {
        let theme = try clickyBlueTheme()
        let pixels = try #require(renderedPixels(
            of: CustomCursorView(customTheme: theme, picture: nil, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0),
            side: 24
        ))
        // The equilateral triangle's tip is at about 2.8 points and its base at about 16.6, so at 2x its rows run from 6 to 33.
        let nearTheTip = try #require(pixels.colorAt(x: 24, y: 14))
        let nearTheBase = try #require(pixels.colorAt(x: 24, y: 30))
        #expect(nearTheTip.alphaComponent > 0.9)
        #expect(nearTheBase.alphaComponent > 0.9)
        #expect(brightness(of: nearTheTip) > brightness(of: nearTheBase))
    }

    @Test func aTintColorsOnlyTheGlyphsOwnPixels() throws {
        let theme = try clickyBlueTheme()
        let glyph = CustomCursorView(customTheme: theme, picture: nil, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
        let untinted = try #require(renderedPixels(of: CursorTintedGlyph(glyph: glyph, tintColor: .red, tintStrength: 0), side: 24))
        let tinted = try #require(renderedPixels(of: CursorTintedGlyph(glyph: glyph, tintColor: .red, tintStrength: 0.5), side: 24))
        let centerBefore = try #require(untinted.colorAt(x: 24, y: 30)?.usingColorSpace(.sRGB))
        let centerAfter = try #require(tinted.colorAt(x: 24, y: 30)?.usingColorSpace(.sRGB))
        #expect(centerAfter.redComponent > centerBefore.redComponent + 0.15)
        // The transparent corner stays transparent, so the tint does not paint a square around the cursor.
        #expect(try #require(tinted.colorAt(x: 1, y: 1)).alphaComponent < 0.02)
    }

    @Test func aTintedVolleyballKeepsItsRoundShape() throws {
        let theme = try #require(bundledThemesForTests.first { $0.id == "school-karasuno" })
        let glyph = CustomCursorView(customTheme: theme, picture: nil, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
        let tinted = try #require(renderedPixels(of: CursorTintedGlyph(glyph: glyph, tintColor: DS.Colors.destructive, tintStrength: 0.5), side: 32))
        #expect(try #require(tinted.colorAt(x: 32, y: 32)).alphaComponent > 0.9)
        #expect(try #require(tinted.colorAt(x: 1, y: 1)).alphaComponent < 0.02)
    }
}

/// Renders the real frame view at known dates, so the motion is checked on pixels and a strip of frames can be saved for a PR.
@MainActor
struct CursorBodyLanguageFrameTests {
    private let startedAt = Date(timeIntervalSinceReferenceDate: 5000)
    private let framePointSide: CGFloat = 48

    private func clickyBlue() throws -> ClickyTheme {
        try #require(bundledThemesForTests.first { $0.id == "clicky-blue" })
    }

    private func glyph(of theme: ClickyTheme) -> some View {
        CustomCursorView(customTheme: theme, picture: nil, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
            .rotationEffect(.degrees(theme.cursorFacing == .pointerAngle ? -35 : 0))
    }

    private func frame(
        theme: ClickyTheme,
        emote: CursorEmote? = nil,
        landed: Bool = false,
        speedShare: Double = 0,
        directionDegrees: Double = 0,
        secondsIn: Double,
        reduceMotion: Bool = false
    ) -> some View {
        CursorBodyLanguageFrameView(
            glyph: glyph(of: theme),
            glowColor: Color(hex: theme.accentHex),
            flightSpeedShare: speedShare,
            flightDirectionDegrees: directionDegrees,
            playingEmote: emote.map { PlayingCursorEmote(emote: $0, startedAt: startedAt) },
            landedAt: landed ? startedAt : nil,
            drawnAt: startedAt.addingTimeInterval(secondsIn),
            reduceMotionIsOn: reduceMotion
        )
        .frame(width: framePointSide, height: framePointSide)
    }

    /// One pixel's channels from 0 to 1.
    struct PixelColor {
        let redComponent: Double
        let greenComponent: Double
        let blueComponent: Double
        let alphaComponent: Double
    }

    /// A rendered frame as plain bytes. Reading each pixel through `NSBitmapImageRep.colorAt` allocates a color per pixel, which
    /// starved the main actor for tens of seconds on a loaded CI runner and failed unrelated tests that wait on it.
    struct RenderedPixels {
        let pixelsWide: Int
        let pixelsHigh: Int
        let bytes: [UInt8]

        func colorAt(x pixelColumn: Int, y pixelRow: Int) -> PixelColor {
            let firstByte = (pixelRow * pixelsWide + pixelColumn) * 4
            // Premultiplied alpha over an opaque background is the color itself, so the background's pixels read as opaque.
            return PixelColor(
                redComponent: Double(bytes[firstByte]) / 255,
                greenComponent: Double(bytes[firstByte + 1]) / 255,
                blueComponent: Double(bytes[firstByte + 2]) / 255,
                alphaComponent: Double(bytes[firstByte + 3]) / 255
            )
        }
    }

    private func pixels(of view: some View, onDark: Bool = true) throws -> RenderedPixels {
        let renderer = ImageRenderer(content: view.background(onDark ? Color(hex: "#101211") : Color.white))
        renderer.scale = 2
        let cgImage = try #require(renderer.cgImage)
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try #require(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return RenderedPixels(pixelsWide: cgImage.width, pixelsHigh: cgImage.height, bytes: bytes)
    }

    /// The center of the pixels that are clearly the cursor's own, not the glow or the background.
    private func centroidOfTheCursor(_ bitmap: RenderedPixels, isCursorPixel: (PixelColor) -> Bool) throws -> CGPoint {
        var sumOfColumns = 0.0, sumOfRows = 0.0, count = 0.0
        for pixelRow in 0..<bitmap.pixelsHigh {
            for pixelColumn in 0..<bitmap.pixelsWide where isCursorPixel(bitmap.colorAt(x: pixelColumn, y: pixelRow)) {
                sumOfColumns += Double(pixelColumn); sumOfRows += Double(pixelRow); count += 1
            }
        }
        try #require(count > 0)
        return CGPoint(x: sumOfColumns / count, y: sumOfRows / count)
    }

    private func isBlue(_ color: PixelColor) -> Bool { color.blueComponent > 0.6 && color.redComponent < 0.5 && color.alphaComponent > 0.9 }
    private func isRedOrBlue(_ color: PixelColor) -> Bool { color.alphaComponent > 0.9 && (color.redComponent > 0.5 || color.blueComponent > 0.6) && color.greenComponent < 0.6 }

    @Test func aShakeMovesTheCursorSidewaysAndAHopMovesItUp() throws {
        let theme = try clickyBlue()
        let rest = try centroidOfTheCursor(try pixels(of: frame(theme: theme, secondsIn: 0)), isCursorPixel: isRedOrBlue)
        // The shake's first swing is at its largest a little after the start.
        let shakeSeconds = (0..<45).map { Double($0) * 0.01 }.max { abs(DS.Move.shake.curve.progress(atSeconds: $0)) < abs(DS.Move.shake.curve.progress(atSeconds: $1)) } ?? 0.1
        let shaken = try centroidOfTheCursor(try pixels(of: frame(theme: theme, emote: .shake, secondsIn: shakeSeconds)), isCursorPixel: isRedOrBlue)
        #expect(abs(shaken.x - rest.x) > 4)
        #expect(abs(shaken.y - rest.y) < 3)
        let hopped = try centroidOfTheCursor(try pixels(of: frame(theme: theme, emote: .hop, secondsIn: 0.2)), isCursorPixel: isRedOrBlue)
        #expect(rest.y - hopped.y > 12)
    }

    @Test func aNodMovesTheCursorDown() throws {
        let theme = try clickyBlue()
        let rest = try centroidOfTheCursor(try pixels(of: frame(theme: theme, secondsIn: 0)), isCursorPixel: isBlue)
        let nodded = try centroidOfTheCursor(try pixels(of: frame(theme: theme, emote: .nod, secondsIn: 0.09)), isCursorPixel: isBlue)
        #expect(nodded.y - rest.y > 4)
    }

    @Test func withReduceMotionAShakeLeavesTheCursorInPlaceButRed() throws {
        let theme = try clickyBlue()
        let rest = try pixels(of: frame(theme: theme, secondsIn: 0))
        let shaken = try pixels(of: frame(theme: theme, emote: .shake, secondsIn: 0.25, reduceMotion: true))
        let restCenter = rest.colorAt(x: 48, y: 58)
        let shakenCenter = shaken.colorAt(x: 48, y: 58)
        #expect(shakenCenter.redComponent > restCenter.redComponent + 0.15)
        #expect(shakenCenter.blueComponent < restCenter.blueComponent)
    }

    @Test func theCursorStretchesAlongItsFlightWhateverWayItFaces() throws {
        let theme = try #require(bundledThemesForTests.first { $0.id == "school-karasuno" })
        func extent(speedShare: Double, directionDegrees: Double) throws -> (width: Int, height: Int) {
            let bitmap = try pixels(of: frame(theme: theme, speedShare: speedShare, directionDegrees: directionDegrees, secondsIn: 5))
            var leftmostColumn = Int.max, rightmostColumn = 0, topRow = Int.max, bottomRow = 0
            for pixelRow in 0..<bitmap.pixelsHigh {
                for pixelColumn in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: pixelColumn, y: pixelRow)
                    guard color.alphaComponent > 0.9, color.redComponent + color.greenComponent + color.blueComponent > 0.9 else { continue }
                    leftmostColumn = min(leftmostColumn, pixelColumn); rightmostColumn = max(rightmostColumn, pixelColumn)
                    topRow = min(topRow, pixelRow); bottomRow = max(bottomRow, pixelRow)
                }
            }
            return (rightmostColumn - leftmostColumn, bottomRow - topRow)
        }
        let atRest = try extent(speedShare: 0, directionDegrees: 0)
        let flyingUp = try extent(speedShare: 1, directionDegrees: 0)
        let flyingSideways = try extent(speedShare: 1, directionDegrees: 90)
        #expect(flyingUp.height > atRest.height)
        #expect(flyingUp.width < atRest.width)
        #expect(flyingSideways.width > atRest.width)
        #expect(flyingSideways.height < atRest.height)
    }

    @Test func theLandingSquashShortensTheCursorAlongItsFlight() throws {
        // A round cursor shows the squash in its height, where a tilted triangle would hide it.
        let theme = try #require(bundledThemesForTests.first { $0.id == "school-karasuno" })
        func height(secondsSinceLanding: Double) throws -> Int {
            let bitmap = try pixels(of: frame(theme: theme, landed: true, directionDegrees: 0, secondsIn: secondsSinceLanding))
            var topRow = Int.max, bottomRow = 0
            for pixelRow in 0..<bitmap.pixelsHigh {
                for pixelColumn in 0..<bitmap.pixelsWide {
                    let color = bitmap.colorAt(x: pixelColumn, y: pixelRow)
                    guard color.alphaComponent > 0.9, color.redComponent + color.greenComponent + color.blueComponent > 0.9 else { continue }
                    topRow = min(topRow, pixelRow); bottomRow = max(bottomRow, pixelRow)
                }
            }
            return bottomRow - topRow
        }
        #expect(try height(secondsSinceLanding: 0.05) < height(secondsSinceLanding: 1) - 2)
    }

    /// Saves a strip of frames for every motion to the folder named in `CLICKY_CURSOR_STRIPS_DIR`, for a PR. It does nothing
    /// when the variable is not set.
    @Test func savesTheFrameStripsWhenAskedTo() throws {
        guard let folderPath = ProcessInfo.processInfo.environment["CLICKY_CURSOR_STRIPS_DIR"] else { return }
        let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        struct StripRow { let label: String; let frames: [AnyView] }
        func row(_ label: String, theme: ClickyTheme, times: [Double], emote: CursorEmote? = nil, landed: Bool = false, reduceMotion: Bool = false,
                 speedShare: (Double) -> Double = { _ in 0 }, direction: Double = 0) -> StripRow {
            StripRow(label: label, frames: times.map { seconds in
                AnyView(frame(theme: theme, emote: emote, landed: landed, speedShare: speedShare(seconds), directionDegrees: direction, secondsIn: seconds, reduceMotion: reduceMotion))
            })
        }
        let blue = try clickyBlue()
        let volleyball = try #require(bundledThemesForTests.first { $0.id == "school-karasuno" })
        for (themeName, theme) in [("triangle", blue), ("volleyball", volleyball)] {
            for onDark in [true, false] {
                let flightTimes = (0...6).map { Double($0) / 6 }
                let rows = [
                    row("flight (stretch)", theme: theme, times: flightTimes, speedShare: { CursorPointFlight.speedShare(linearProgress: $0) }, direction: 60),
                    row("landing squash", theme: theme, times: [0, 0.03, 0.06, 0.09, 0.12, 0.16, 0.22], landed: true, direction: 60),
                    row("nod", theme: theme, times: (0...6).map { Double($0) * 0.06 }, emote: .nod),
                    row("shake", theme: theme, times: (0...6).map { Double($0) * 0.075 }, emote: .shake),
                    row("hop", theme: theme, times: (0...6).map { Double($0) * 0.083 }, emote: .hop),
                    row("shake, Reduce Motion", theme: theme, times: [0, 0.075, 0.15, 0.25, 0.35, 0.425, 0.5], emote: .shake, reduceMotion: true),
                    row("hop, Reduce Motion", theme: theme, times: [0, 0.075, 0.15, 0.25, 0.35, 0.425, 0.5], emote: .hop, reduceMotion: true),
                ]
                let sheet = VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        Text(rows[rowIndex].label).font(.system(size: 11, weight: .medium)).foregroundColor(onDark ? .white.opacity(0.7) : .black.opacity(0.6))
                        HStack(spacing: 0) {
                            ForEach(rows[rowIndex].frames.indices, id: \.self) { frameIndex in rows[rowIndex].frames[frameIndex] }
                        }
                    }
                }
                .padding(12)
                .background(onDark ? Color(hex: "#101211") : Color.white)
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 2
                let cgImage = try #require(renderer.cgImage)
                let pngData = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
                try pngData.write(to: folderURL.appendingPathComponent("\(themeName)-\(onDark ? "dark" : "light").png"))
            }
        }
    }
}
