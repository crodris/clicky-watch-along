//
//  TetherTokensTests.swift
//  leanring-buddyTests
//
//  The Tether tokens: the type scale's four sizes, each move's curve and Reduce Motion form as the spec gives them, the
//  curves' math, and the Card and Callout drawn at 2x.
//

import AppKit
import SwiftUI
import Testing

@testable import Clicky

@MainActor
struct TetherTokensTests {
    // MARK: - Type scale

    @Test func theSixTypeStylesUseOnlyTheFourSizes() {
        #expect(Set(DS.TypeScale.allCases.map(\.pointSize)) == [17, 15, 13, 11])
        #expect(DS.TypeScale.voice.pointSize == 15 && DS.TypeScale.voice.weight == .bold && DS.TypeScale.voice.design == .rounded)
        #expect(DS.TypeScale.data.design == .monospaced)
    }

    // MARK: - Moves

    @Test func everyMoveHasTheCurveAndReduceMotionFormTheSpecGives() {
        let expected: [DS.Move: (curve: MoveCurve, reduceMotionForm: ReducedMotionForm)] = [
            .send: (.timed(seconds: 0.5, bezier: .smoothstep), .fadeAtTheTargetLeavingAStillRing(seconds: 0.2)),
            .bringBack: (.timed(seconds: 0.6, bezier: .smoothstep), .fadeAtTheTargetLeavingAStillRing(seconds: 0.2)),
            .point: (.pacedByDistance(pointsPerSecond: 800, shortestSeconds: 0.6, longestSeconds: 1.4, bezier: .smoothstep), .fadeAtTheTargetLeavingAStillRing(seconds: 0.2)),
            .rise: (.timed(seconds: 1.6, bezier: .cubicEaseInOut), .crossfade(seconds: 0.15)),
            .returnToSource: (.timed(seconds: 0.8, bezier: .cubicEaseInOut), .crossfade(seconds: 0.15)),
            .pop: (.spring(response: 0.32, dampingFraction: 0.68), .crossfade(seconds: 0.15)),
            .glide: (.spring(response: 0.42, dampingFraction: 0.9), .crossfade(seconds: 0.15)),
            .snap: (.spring(response: 0.18, dampingFraction: 0.86), .crossfade(seconds: 0.15)),
            .recall: (.timed(seconds: 0.18, bezier: .quadraticEaseIn), .crossfade(seconds: 0.15)),
            .shake: (.decayingShake(seconds: 0.45, amplitudePoints: 7, cyclesPerSecond: 3.5, decayPerSecond: 7), .none),
        ]
        #expect(DS.Move.allCases.count == 10)
        for move in DS.Move.allCases {
            #expect(move.curve(using: .standard) == expected[move]?.curve, "\(move)")
            #expect(move.reduceMotionForm == expected[move]?.reduceMotionForm, "\(move)")
        }
    }

    @Test func onlyTheShakeHasNoAnimationAndWithReduceMotionItDoesNothing() {
        for move in DS.Move.allCases where move != .shake {
            #expect(move.animation(reduceMotionIsOn: false) != nil, "\(move)")
            #expect(move.animation(reduceMotionIsOn: true) != nil, "\(move)")
        }
        #expect(DS.Move.shake.animation(reduceMotionIsOn: false) == nil)
        #expect(DS.Move.shake.animation(reduceMotionIsOn: true) == nil)
    }

    @Test func theTimedBeziersAreExactlySmoothstepAndASquare() {
        for linearProgress in stride(from: 0.0, through: 1.0, by: 0.05) {
            #expect(abs(MoveBezier.smoothstep.progress(atLinearProgress: linearProgress) - linearProgress * linearProgress * (3 - 2 * linearProgress)) < 1e-9)
            #expect(abs(MoveBezier.quadraticEaseIn.progress(atLinearProgress: linearProgress) - linearProgress * linearProgress) < 1e-9)
        }
        #expect(abs(MoveBezier.cubicEaseInOut.progress(atLinearProgress: 0.5) - 0.5) < 1e-9)
        #expect(MoveBezier.cubicEaseInOut.progress(atLinearProgress: 0.25) < 0.25)
        #expect(MoveBezier.smoothstep.progress(atLinearProgress: -1) == 0)
        #expect(abs(MoveBezier.smoothstep.progress(atLinearProgress: 2) - 1) < 1e-9)
    }

    @Test func aSpringStartsAtZeroRisesPastHalfwayEarlyAndEndsExactlyAtOne() {
        let glideCurve = DS.Move.glide.curve(using: .standard)
        let glideSeconds = glideCurve.seconds()
        #expect(glideSeconds > 0.4 && glideSeconds < 0.5)
        #expect(glideCurve.progress(atSeconds: 0) == 0)
        #expect(glideCurve.progress(atSeconds: glideSeconds * 0.3) > 0.5)
        #expect(glideCurve.progress(atSeconds: glideSeconds) == 1)
        // Just before the end it is already within the settled share, so the snap to 1 is not visible.
        #expect(abs(glideCurve.progress(atSeconds: glideSeconds - 0.001) - 1) < 0.003)
        // The pop's lower damping overshoots its end before it settles.
        let popCurve = DS.Move.pop.curve(using: .standard)
        let popPeak = stride(from: 0.0, to: popCurve.seconds(), by: 0.005).map { popCurve.progress(atSeconds: $0) }.max() ?? 0
        #expect(popPeak > 1.03)
    }

    @Test func aGlideClosePlaysTheOpenSpringInSevenTenthsOfTheTime() {
        let closeCurve = DS.Move.glide.curve(using: .standard).timeScaled(by: DS.Move.glideCloseTimeFactor)
        #expect(abs(closeCurve.seconds() - DS.Move.glide.curve(using: .standard).seconds() * 0.7) < 1e-9)
        #expect(abs(closeCurve.progress(atSeconds: 0.07) - DS.Move.glide.curve(using: .standard).progress(atSeconds: 0.1)) < 1e-9)
    }

    @Test func aCriticallyDampedSpringRisesWithoutOvershootAndNeverGivesNaN() {
        let criticalCurve = MoveCurve.spring(response: 0.3, dampingFraction: 1)
        let seconds = criticalCurve.seconds()
        let progresses = stride(from: 0.0, through: seconds, by: 0.005).map { criticalCurve.progress(atSeconds: $0) }
        #expect(progresses.allSatisfy { !$0.isNaN && $0 <= 1 })
        #expect(zip(progresses, progresses.dropFirst()).allSatisfy { $0 <= $1 })
        // It settles where its distance left reaches the same 0.2% share an under-damped spring uses, neither before
        // nor long after.
        let distanceLeftJustBeforeTheEnd = 1 - criticalCurve.progress(atSeconds: seconds - 0.001)
        #expect(distanceLeftJustBeforeTheEnd > 0.0015 && distanceLeftJustBeforeTheEnd < 0.0025)
    }

    @Test func swiftUIPlaysADampingAboveOneAsCriticallyDampedLikeTheCarrier() {
        #expect(MoveCurve.spring(response: 0.3, dampingFraction: 1.4).animation() == .spring(response: 0.3, dampingFraction: 1))
        #expect(DS.Move.glide.curve(using: .standard).animation() == .spring(response: 0.42, dampingFraction: 0.9))
    }

    @Test func everyReduceMotionFormSaysHowLongItsFadeTakes() {
        #expect(ReducedMotionForm.crossfade(seconds: 0.15).fadeSeconds == 0.15)
        #expect(ReducedMotionForm.fadeAtTheTargetLeavingAStillRing(seconds: 0.2).fadeSeconds == 0.2)
        #expect(ReducedMotionForm.none.fadeSeconds == 0)
    }

    @Test func thePointFlightIsPacedByItsDistanceBetweenItsShortestAndLongestTime() {
        let pointCurve = DS.Move.point.curve(using: .standard)
        #expect(pointCurve.seconds(travelingPoints: 100) == 0.6)
        #expect(pointCurve.seconds(travelingPoints: 800) == 1)
        #expect(pointCurve.seconds(travelingPoints: 5000) == 1.4)
    }

    @Test func theShakeSwingsBothWaysAndIsStillAtItsStartAndEnd() {
        let shakeCurve = DS.Move.shake.curve
        let offsets = stride(from: 0.0, through: 0.45, by: 0.01).map { shakeCurve.progress(atSeconds: $0) }
        #expect(offsets.first == 0)
        #expect(offsets.max() ?? 0 > 0.3)
        #expect(offsets.min() ?? 0 < -0.1)
        #expect(shakeCurve.progress(atSeconds: 0.45) == 0)
    }

    // MARK: - Materials at 2x

    private func renderedPixels(of view: some View) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.padding(30).background(Color.white))
        renderer.scale = 2
        return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
    }

    /// A pixel's color as `#rrggbb`, from the bitmap's own components, so no color space conversion moves it.
    private func hex(of color: NSColor?) -> String {
        guard let color else { return "none" }
        return String(format: "#%02x%02x%02x", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
    }

    /// Whether a pixel is within `tolerance` of a `#rrggbb` color in every channel, out of 255.
    private func pixel(_ color: NSColor?, matches expectedHex: String, tolerance: Int = 3) -> Bool {
        guard let color, let expected = ThemeRGBColor(hex: expectedHex) else { return false }
        let channelPairs: [(actualComponent: CGFloat, expectedComponent: Double)] = [
            (color.redComponent, expected.red), (color.greenComponent, expected.green), (color.blueComponent, expected.blue),
        ]
        return channelPairs.allSatisfy { channelPair in
            abs(Int((channelPair.actualComponent * 255).rounded()) - Int((channelPair.expectedComponent * 255).rounded())) <= tolerance
        }
    }

    @Test func theCalloutIsSolidDarkWithAnAccentRimAndAnAccentDiscOnAWhitePage() throws {
        let accentHex = "#F2B53A"
        let accent = Color(hex: accentHex)
        let callout = TetherCallout(accent: accent) {
            Image(systemName: "arrow.counterclockwise")
        } content: {
            Text("Turning it left")
        }
        let pixels = try renderedPixels(of: callout)
        // 30 points of white page, then the Callout. Its body is 40 points tall: 7 + the 26 point disc + 7.
        let bodyMiddleY = (30 + 20) * 2
        let discCenterX = (30 + 7 + 13) * 2
        let discEdgeX = (30 + 7 + 2) * 2
        let rimX = 30 * 2 + 1
        // Between the disc and the words, the surface shows.
        let surfaceX = (30 + 7 + 26 + 4) * 2
        #expect(pixel(pixels.colorAt(x: surfaceX, y: bodyMiddleY), matches: "#14171e"), "surface \(hex(of: pixels.colorAt(x: surfaceX, y: bodyMiddleY)))")
        #expect(pixel(pixels.colorAt(x: rimX, y: bodyMiddleY), matches: accentHex, tolerance: 40), "rim \(hex(of: pixels.colorAt(x: rimX, y: bodyMiddleY)))")
        #expect(pixel(pixels.colorAt(x: discEdgeX, y: bodyMiddleY), matches: accentHex), "disc \(hex(of: pixels.colorAt(x: discEdgeX, y: bodyMiddleY)))")
        // The arrow's ink is near-black on the accent, never white.
        let discPixels = (-16...16).flatMap { dx in (-16...16).compactMap { dy in pixels.colorAt(x: discCenterX + dx, y: bodyMiddleY + dy) } }
        let darkestDiscPixel = try #require(discPixels.min { $0.brightnessComponent < $1.brightnessComponent })
        let lightestDiscPixel = try #require(discPixels.max { $0.brightnessComponent < $1.brightnessComponent })
        #expect(darkestDiscPixel.brightnessComponent < 0.15, "ink \(hex(of: darkestDiscPixel))")
        #expect(lightestDiscPixel.redComponent < 0.99 || lightestDiscPixel.blueComponent < 0.99, "no white ink \(hex(of: lightestDiscPixel))")
        // The tail reaches below the pill near its left end, and the white page shows to its right.
        let tailY = (30 + 40 + 4) * 2
        let tailTip = TetherCalloutShape.tailTip(inCalloutOfSize: CGSize(width: 200, height: 49))
        // The accent halo tints the page around the pill, so the page beside the tail is light, not pure white.
        #expect((pixels.colorAt(x: Int((30 + tailTip.x + 4) * 2), y: tailY)?.brightnessComponent ?? 1) < 0.3, "tail")
        #expect((pixels.colorAt(x: (30 + 60) * 2, y: tailY)?.brightnessComponent ?? 0) > 0.6, "page beside the tail")
    }

    @Test func theCardSurfaceRunsFromItsTopColorToItsBottomColor() throws {
        let card = Color.clear.frame(width: 200, height: 120).tetherCard()
        let pixels = try renderedPixels(of: card)
        let topColor = pixels.colorAt(x: (30 + 100) * 2, y: (30 + 4) * 2)
        let bottomColor = pixels.colorAt(x: (30 + 100) * 2, y: (30 + 116) * 2)
        #expect(pixel(topColor, matches: "#121419"), "top \(hex(of: topColor))")
        #expect(pixel(bottomColor, matches: "#171a21"), "bottom \(hex(of: bottomColor))")
    }
}
