//
//  CustomCursorTests.swift
//  leanring-buddyTests
//
//  The custom cursor's motion rules, its facing, the picture cursor's size, and a render of the cursor itself.
//

import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Clicky

struct CustomCursorMotionTests {
    private func motion(
        whileThinking: CursorThinkingMotion = .none,
        whileListening: CursorListeningMotion = .none,
        turnsTowardMovement: Bool = true,
        trailStreaks: Int = 0
    ) -> CustomCursorMotion {
        CustomCursorMotion(turnsTowardMovement: turnsTowardMovement, trailStreaks: trailStreaks, whileThinking: whileThinking, whileListening: whileListening)
    }

    private func pose(
        _ motion: CustomCursorMotion,
        voiceState: CompanionVoiceState,
        seconds: Double = 0,
        audioPowerLevel: CGFloat = 0,
        reduceMotionIsOn: Bool = false
    ) -> CustomCursorMotionPose {
        CustomCursorMotionRules.pose(motion: motion, voiceState: voiceState, seconds: seconds, audioPowerLevel: audioPowerLevel, reduceMotionIsOn: reduceMotionIsOn)
    }

    @Test func spinMakesOneTurnEveryOnePointTwoSeconds() {
        let spinning = motion(whileThinking: .spin)
        #expect(pose(spinning, voiceState: .processing, seconds: 0).rotationDegrees == 0)
        #expect(abs(pose(spinning, voiceState: .processing, seconds: 0.3).rotationDegrees - 90) < 0.0001)
        #expect(abs(pose(spinning, voiceState: .processing, seconds: 0.6).rotationDegrees - 180) < 0.0001)
        // Back at the start of the next turn.
        #expect(abs(pose(spinning, voiceState: .processing, seconds: 1.2).rotationDegrees) < 0.0001)
        #expect(pose(spinning, voiceState: .processing, seconds: 0.6).scale == 1)
    }

    @Test func pulseGrowsToOnePointOneTwoHalfwayThroughEachPointNineSeconds() {
        let pulsing = motion(whileThinking: .pulse)
        #expect(abs(pose(pulsing, voiceState: .processing, seconds: 0).scale - 1) < 0.0001)
        #expect(abs(pose(pulsing, voiceState: .processing, seconds: 0.45).scale - 1.12) < 0.0001)
        #expect(abs(pose(pulsing, voiceState: .processing, seconds: 0.9).scale - 1) < 0.0001)
        #expect(pose(pulsing, voiceState: .processing, seconds: 0.45).rotationDegrees == 0)
    }

    @Test func wobbleTurnsPlusAndMinusTwelveDegreesEveryPointEightSeconds() {
        let wobbling = motion(whileThinking: .wobble)
        #expect(abs(pose(wobbling, voiceState: .processing, seconds: 0.2).rotationDegrees - 12) < 0.0001)
        #expect(abs(pose(wobbling, voiceState: .processing, seconds: 0.6).rotationDegrees + 12) < 0.0001)
        #expect(abs(pose(wobbling, voiceState: .processing, seconds: 0.4).rotationDegrees) < 0.0001)
    }

    @Test func aThinkingMotionRunsOnlyWhileClickyThinks() {
        let everything = motion(whileThinking: .spin, whileListening: .pulse)
        for voiceState in [CompanionVoiceState.idle, .responding] {
            #expect(pose(everything, voiceState: voiceState, seconds: 0.3, audioPowerLevel: 0.5) == .still)
        }
        #expect(pose(motion(whileThinking: .none), voiceState: .processing, seconds: 0.3) == .still)
    }

    @Test func theListeningPulseScalesWithTheMicrophoneFromOneToAtMostOnePointTwo() {
        let pulsing = motion(whileListening: .pulse)
        #expect(pose(pulsing, voiceState: .listening, audioPowerLevel: 0).scale == 1)
        let quietScale = pose(pulsing, voiceState: .listening, audioPowerLevel: 0.02).scale
        let loudScale = pose(pulsing, voiceState: .listening, audioPowerLevel: 0.2).scale
        #expect(quietScale > 1)
        #expect(loudScale > quietScale)
        #expect(pose(pulsing, voiceState: .listening, audioPowerLevel: 5).scale <= 1.2 + 0.0001)
        #expect(pose(motion(whileListening: .none), voiceState: .listening, audioPowerLevel: 0.2) == .still)
    }

    @Test func reduceMotionTurnsEveryMotionOff() {
        let everything = motion(whileThinking: .spin, whileListening: .pulse)
        #expect(pose(everything, voiceState: .processing, seconds: 0.3, reduceMotionIsOn: true) == .still)
        #expect(pose(everything, voiceState: .listening, audioPowerLevel: 0.2, reduceMotionIsOn: true) == .still)
    }

    @Test func onlyAThinkingMotionNeedsAClock() {
        let thinking = motion(whileThinking: .spin, whileListening: .pulse)
        #expect(CustomCursorMotionRules.motionNeedsAClock(motion: thinking, voiceState: .processing, reduceMotionIsOn: false))
        #expect(!CustomCursorMotionRules.motionNeedsAClock(motion: thinking, voiceState: .listening, reduceMotionIsOn: false))
        #expect(!CustomCursorMotionRules.motionNeedsAClock(motion: thinking, voiceState: .processing, reduceMotionIsOn: true))
        #expect(!CustomCursorMotionRules.motionNeedsAClock(motion: motion(whileThinking: .none), voiceState: .processing, reduceMotionIsOn: false))
    }

    @Test func aPictureCursorHasItsLongSideAtThirtyTwoPoints() {
        let wideSize = CustomCursorMotionRules.pictureSize(fit: .whole, imageSize: CGSize(width: 1280, height: 720))
        #expect(wideSize == CGSize(width: 32, height: 18))
        let tallSize = CustomCursorMotionRules.pictureSize(fit: .whole, imageSize: CGSize(width: 300, height: 600))
        #expect(tallSize == CGSize(width: 16, height: 32))
        // A round crop is a square, whatever the picture's shape.
        #expect(CustomCursorMotionRules.pictureSize(fit: .circle, imageSize: CGSize(width: 1280, height: 720)) == CGSize(width: 32, height: 32))
        // A picture with no size yet still gets a drawable box.
        #expect(CustomCursorMotionRules.pictureSize(fit: .whole, imageSize: .zero) == CGSize(width: 32, height: 32))
    }
}

@MainActor
struct CustomCursorThemeTests {
    private func customTheme(turnsTowardMovement: Bool) throws -> CompanionTheme {
        let idea = replacingField(in: goodThemeIdea, at: ["motion", "turnsTowardMovement"], with: .bool(turnsTowardMovement))
        return .custom(try CustomTheme.parse(idea: idea, id: "idea-1", pictureIsAvailable: false))
    }

    @Test func eachThemeFacesTheWayItsCursorIsMeantTo() throws {
        #expect(CompanionTheme.clickyBlue.cursorFacing == .pointerAngle)
        #expect(CompanionTheme.random.cursorFacing == .pointerAngle)
        #expect(CompanionTheme.school(.karasuno).cursorFacing == .followsMouseMovement)
        #expect(try customTheme(turnsTowardMovement: true).cursorFacing == .followsMouseMovement)
        #expect(try customTheme(turnsTowardMovement: false).cursorFacing == .upright)
    }

    @Test func theFlightStreaksDrawTheLinesTheCursorAsksFor() {
        func lineCount(_ streaks: CursorFlightStreaks) -> Int {
            let box = CGRect(x: 0, y: 0, width: 24, height: 24)
            var moveCount = 0
            streaks.path(in: box).forEach { pathElement in
                if case .move = pathElement { moveCount += 1 }
            }
            return moveCount
        }
        #expect(lineCount(CursorFlightStreaks()) == 3)
        #expect(lineCount(CursorFlightStreaks(lineCount: 0)) == 0)
        #expect(lineCount(CursorFlightStreaks(lineCount: 1)) == 1)
        #expect(lineCount(CursorFlightStreaks(lineCount: 2)) == 2)
        #expect(lineCount(CursorFlightStreaks(lineCount: 3)) == 3)
    }

    /// Renders the cursor at 2x and reads its pixels, since a cursor that decodes fine can still draw nothing.
    private func renderedPixels(of cursorView: some View, side: CGFloat) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(content: cursorView.frame(width: side, height: side))
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    @Test func aShapesCursorDrawsItsStarInTheMiddleAndNothingInTheCorner() throws {
        let theme = try CustomTheme.parse(idea: goodThemeIdea, id: "idea-1", pictureIsAvailable: false)
        let pixels = try #require(renderedPixels(
            of: CustomCursorView(customTheme: theme, picture: nil, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0),
            side: 24
        ))
        let centerAlpha = try #require(pixels.colorAt(x: 24, y: 24)).alphaComponent
        let cornerAlpha = try #require(pixels.colorAt(x: 1, y: 1)).alphaComponent
        #expect(centerAlpha > 0.9)
        #expect(cornerAlpha < 0.05)
    }

    @Test func aPictureCursorDrawsThePictureWithItsTintAndOutline() throws {
        let theme = try CustomTheme.parse(idea: goodPictureCursorThemeIdea, id: "idea-1", pictureIsAvailable: true)
        // A solid red 40 by 20 picture, so a 0.3 tint of #7DD3FC over it turns the middle visibly bluer than the red it started as.
        let picture = NSImage(size: NSSize(width: 40, height: 20), flipped: false) { drawingRect in
            NSColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
            drawingRect.fill()
            return true
        }
        let pixels = try #require(renderedPixels(
            of: CustomCursorView(customTheme: theme, picture: picture, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0),
            side: 32
        ))
        // The picture is 32 by 16 points, so at 2x its middle is at (32, 32).
        let middleColor = try #require(pixels.colorAt(x: 32, y: 32)?.usingColorSpace(.sRGB))
        #expect(middleColor.alphaComponent > 0.95)
        #expect(middleColor.redComponent > 0.6 && middleColor.redComponent < 0.95)
        #expect(middleColor.blueComponent > 0.1)
        // Above and below the 16 point tall picture, the frame is empty.
        #expect(try #require(pixels.colorAt(x: 32, y: 2)).alphaComponent < 0.05)
    }

    @Test func aPictureCursorWithNoReadablePictureFallsBackToTheAccentTriangle() throws {
        let theme = try CustomTheme.parse(idea: goodPictureCursorThemeIdea, id: "idea-1", pictureIsAvailable: true)
        let pixels = try #require(renderedPixels(
            of: CustomCursorView(customTheme: theme, picture: nil, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0),
            side: 32
        ))
        #expect(try #require(pixels.colorAt(x: 32, y: 36)).alphaComponent > 0.9)
    }
}
