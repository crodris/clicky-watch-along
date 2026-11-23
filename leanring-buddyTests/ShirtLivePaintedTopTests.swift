//
//  ShirtLivePaintedTopTests.swift
//  leanring-buddyTests
//
//  The painted top that follows the learner after the painted still arrives: the reach rule and its hysteresis, the follower's
//  fades and hint, the layer cut out of a painted still (the neck and the face left clear, a hand on the top filled), the
//  motion that carries the frozen torso onto the current one, and the composite. None of it needs Vision, so it runs in CI's
//  background session. The real photos are in ShirtLivePaintedTopPhotoCheckTests.swift.
//

import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import Clicky

// MARK: - Torsos

/// A torso facing the camera, standing at ease: the shoulders 200 pixels apart, the hips 140 apart and 300 below, and both
/// arms hanging with an elbow and a wrist.
private func frozenTorso(hipsWereEstimated: Bool = false) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: CGPoint(x: 200, y: 200), imageRightShoulder: CGPoint(x: 400, y: 200),
        imageLeftHip: CGPoint(x: 230, y: 500), imageRightHip: CGPoint(x: 370, y: 500), hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: true,
        imageLeftElbow: CGPoint(x: 185, y: 350), imageRightElbow: CGPoint(x: 415, y: 350),
        imageLeftWrist: CGPoint(x: 175, y: 500), imageRightWrist: CGPoint(x: 425, y: 500)
    )
}

/// `torso` with every point moved by `transform`, as the camera would see the same body moved.
private func moved(_ torso: BodyTorso, by transform: CGAffineTransform) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: torso.imageLeftShoulder.applying(transform), imageRightShoulder: torso.imageRightShoulder.applying(transform),
        imageLeftHip: torso.imageLeftHip.applying(transform), imageRightHip: torso.imageRightHip.applying(transform),
        hipsWereEstimated: torso.hipsWereEstimated, shouldersAreSeen: torso.shouldersAreSeen,
        imageLeftElbow: torso.imageLeftElbow?.applying(transform), imageRightElbow: torso.imageRightElbow?.applying(transform),
        imageLeftWrist: torso.imageLeftWrist?.applying(transform), imageRightWrist: torso.imageRightWrist?.applying(transform)
    )
}

/// A turn of `degrees` and a scale of `scale` about `pivot`, in camera pixels with y down.
private func turnAndScale(about pivot: CGPoint, degrees: Double = 0, scale: Double = 1) -> CGAffineTransform {
    CGAffineTransform(translationX: -pivot.x, y: -pivot.y)
        .concatenating(CGAffineTransform(rotationAngle: degrees * .pi / 180))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
}

/// `point` turned by `degrees` about `pivot`.
private func turned(_ point: CGPoint, about pivot: CGPoint, degrees: Double) -> CGPoint {
    point.applying(turnAndScale(about: pivot, degrees: degrees))
}

/// `torso` with the image left elbow replaced, or taken away with nil.
private func replacingTheLeftElbow(of torso: BodyTorso, with elbow: CGPoint?) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: torso.imageLeftShoulder, imageRightShoulder: torso.imageRightShoulder,
        imageLeftHip: torso.imageLeftHip, imageRightHip: torso.imageRightHip, hipsWereEstimated: torso.hipsWereEstimated, shouldersAreSeen: torso.shouldersAreSeen,
        imageLeftElbow: elbow, imageRightElbow: torso.imageRightElbow, imageLeftWrist: torso.imageLeftWrist, imageRightWrist: torso.imageRightWrist
    )
}

/// `torso` with the image left wrist replaced, or taken away with nil.
private func replacingTheLeftWrist(of torso: BodyTorso, with wrist: CGPoint?) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: torso.imageLeftShoulder, imageRightShoulder: torso.imageRightShoulder,
        imageLeftHip: torso.imageLeftHip, imageRightHip: torso.imageRightHip, hipsWereEstimated: torso.hipsWereEstimated, shouldersAreSeen: torso.shouldersAreSeen,
        imageLeftElbow: torso.imageLeftElbow, imageRightElbow: torso.imageRightElbow, imageLeftWrist: wrist, imageRightWrist: torso.imageRightWrist
    )
}

/// `torso` with both hips replaced.
private func replacingTheHips(of torso: BodyTorso, leftHip: CGPoint, rightHip: CGPoint, hipsWereEstimated: Bool) -> BodyTorso {
    BodyTorso(
        imageLeftShoulder: torso.imageLeftShoulder, imageRightShoulder: torso.imageRightShoulder,
        imageLeftHip: leftHip, imageRightHip: rightHip, hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: torso.shouldersAreSeen,
        imageLeftElbow: torso.imageLeftElbow, imageRightElbow: torso.imageRightElbow, imageLeftWrist: torso.imageLeftWrist, imageRightWrist: torso.imageRightWrist
    )
}

// MARK: - The reach rule

struct ShirtLivePaintedTopReachTests {
    private func decide(
        _ current: BodyTorso?, frozen: BodyTorso = frozenTorso(), followsTheForearms: Bool = false, wasFollowing: Bool = true
    ) -> ShirtLivePaintedTopReach {
        ShirtLivePaintedTopReach.decide(frozenTorso: frozen, currentTorso: current, followsTheForearms: followsTheForearms, wasFollowing: wasFollowing)
    }

    private let shoulderMiddle = CGPoint(x: 300, y: 200)

    @Test func theFrozenPoseItselfFollowsFromEitherSideOfTheHysteresis() {
        #expect(decide(frozenTorso(), wasFollowing: true) == .follows)
        #expect(decide(frozenTorso(), wasFollowing: false) == .follows)
    }

    @Test func noTorsoOrShouldersOutOfTheFrameAreOutOfReach() {
        #expect(decide(nil) == .outOfReach(.noTorso))
        let shouldersNotSeen = BodyTorso(
            imageLeftShoulder: CGPoint(x: 200, y: 200), imageRightShoulder: CGPoint(x: 400, y: 200),
            imageLeftHip: CGPoint(x: 230, y: 500), imageRightHip: CGPoint(x: 370, y: 500), hipsWereEstimated: false, shouldersAreSeen: false
        )
        #expect(decide(shouldersNotSeen) == .outOfReach(.noTorso))
    }

    @Test func theShouldersMayChangeSizeBetweenSevenTenthsAndOneAndFourTenths() {
        let tooFar = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 0.65))
        let tooClose = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 1.45))
        #expect(decide(tooFar) == .outOfReach(.shouldersChangedSize))
        #expect(decide(tooClose) == .outOfReach(.shouldersChangedSize))
        let farButHeld = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 0.72))
        let closeButHeld = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 1.38))
        #expect(decide(farButHeld) == .follows && decide(closeButHeld) == .follows)
    }

    @Test func comingBackInSizeTakesBeingWithinSevenTenthsOfTheLimit() {
        // Following, 1.35 is inside the 1.4 limit. Out of reach, it must be within 0.7 of the way there, which is 1.28.
        let close = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 1.35))
        #expect(decide(close, wasFollowing: true) == .follows)
        #expect(decide(close, wasFollowing: false) == .outOfReach(.shouldersChangedSize))
        let far = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 0.75))
        #expect(decide(far, wasFollowing: true) == .follows)
        #expect(decide(far, wasFollowing: false) == .outOfReach(.shouldersChangedSize))
        let nearlyBack = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, scale: 1.25))
        #expect(decide(nearlyBack, wasFollowing: false) == .follows)
    }

    @Test func theShouldersMayRollTwentyFiveDegreesAndComingBackTakesSeventeenAndAHalf() {
        let rolledTooFar = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, degrees: 30))
        #expect(decide(rolledTooFar) == .outOfReach(.shouldersRolled))
        let rolledTheOtherWay = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, degrees: -30))
        #expect(decide(rolledTheOtherWay) == .outOfReach(.shouldersRolled))
        let rolledTwenty = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, degrees: 20))
        #expect(decide(rolledTwenty, wasFollowing: true) == .follows)
        #expect(decide(rolledTwenty, wasFollowing: false) == .outOfReach(.shouldersRolled))
        let rolledFifteen = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, degrees: 15))
        #expect(decide(rolledFifteen, wasFollowing: false) == .follows)
    }

    @Test func aTurnToTheSideNarrowsTheShouldersAgainstTheTorsoAndNeedsRealHips() {
        func narrowed(hipsWereEstimated: Bool) -> BodyTorso {
            BodyTorso(
                imageLeftShoulder: CGPoint(x: 225, y: 200), imageRightShoulder: CGPoint(x: 375, y: 200),
                imageLeftHip: CGPoint(x: 230, y: 500), imageRightHip: CGPoint(x: 370, y: 500), hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: true,
                imageLeftElbow: CGPoint(x: 210, y: 350), imageRightElbow: CGPoint(x: 390, y: 350),
                imageLeftWrist: CGPoint(x: 200, y: 500), imageRightWrist: CGPoint(x: 400, y: 500)
            )
        }
        #expect(decide(narrowed(hipsWereEstimated: false)) == .outOfReach(.turnedSideways))
        // Estimated hips are always 1.45 shoulder widths down, so their ratio says nothing, and the painting's own hips do not count either.
        #expect(decide(narrowed(hipsWereEstimated: true)) == .follows)
        #expect(decide(narrowed(hipsWereEstimated: false), frozen: frozenTorso(hipsWereEstimated: true)) == .follows)
    }

    @Test func aBendTowardTheCameraShortensTheTorsoAndGoesOutOfReach() {
        func hipsAt(y hipsY: Double, hipsWereEstimated: Bool = false) -> BodyTorso { replacingTheHips(of: frozenTorso(), leftHip: CGPoint(x: 230, y: hipsY), rightHip: CGPoint(x: 370, y: hipsY), hipsWereEstimated: hipsWereEstimated) }
        // The frozen torso is 300 pixels from shoulders to hips. At 220 the shoulders are 1.36 times as wide for its length.
        #expect(decide(hipsAt(y: 420)) == .outOfReach(.torsoShortened))
        // At 250 (1.2) it follows, and coming back takes being within 0.7 of the way to 1.25, which is 1.175.
        #expect(decide(hipsAt(y: 450), wasFollowing: true) == .follows)
        #expect(decide(hipsAt(y: 450), wasFollowing: false) == .outOfReach(.torsoShortened))
        #expect(decide(hipsAt(y: 460), wasFollowing: false) == .follows)
        // Estimated hips say nothing about a bend.
        #expect(decide(hipsAt(y: 420, hipsWereEstimated: true)) == .follows)
    }

    @Test func hipsThatSwaySidewaysUnderTheShouldersGoOutOfReach() {
        func hipsShifted(by shift: Double, hipsWereEstimated: Bool = false) -> BodyTorso {
            replacingTheHips(of: frozenTorso(), leftHip: CGPoint(x: 230 + shift, y: 500), rightHip: CGPoint(x: 370 + shift, y: 500), hipsWereEstimated: hipsWereEstimated)
        }
        // The shoulders are 200 pixels apart, so the 0.2 shoulder width limit is 40 pixels.
        #expect(decide(hipsShifted(by: 50)) == .outOfReach(.hipsSwayed))
        #expect(decide(hipsShifted(by: -50)) == .outOfReach(.hipsSwayed))
        #expect(decide(hipsShifted(by: 35), wasFollowing: true) == .follows)
        #expect(decide(hipsShifted(by: 35), wasFollowing: false) == .outOfReach(.hipsSwayed))
        #expect(decide(hipsShifted(by: 25), wasFollowing: false) == .follows)
        #expect(decide(hipsShifted(by: 50, hipsWereEstimated: true)) == .follows)
    }

    @Test func anUpperArmMayTurnFifteenDegreesFromTheShoulderLineAndComingBackTakesTenAndAHalf() {
        let leftShoulder = CGPoint(x: 200, y: 200)
        func armTurned(by degrees: Double) -> BodyTorso { replacingTheLeftElbow(of: frozenTorso(), with: turned(CGPoint(x: 185, y: 350), about: leftShoulder, degrees: degrees)) }
        #expect(decide(armTurned(by: 20)) == .outOfReach(.upperArmMoved))
        #expect(decide(armTurned(by: -20)) == .outOfReach(.upperArmMoved))
        #expect(decide(armTurned(by: 12), wasFollowing: true) == .follows)
        #expect(decide(armTurned(by: 12), wasFollowing: false) == .outOfReach(.upperArmMoved))
        #expect(decide(armTurned(by: 9), wasFollowing: false) == .follows)
    }

    @Test func aRolledBodyKeepsItsArmAnglesBecauseTheyAreMeasuredFromTheShoulderLine() {
        let rolledTwenty = moved(frozenTorso(), by: turnAndScale(about: shoulderMiddle, degrees: 20))
        #expect(decide(rolledTwenty, followsTheForearms: true, wasFollowing: true) == .follows)
    }

    @Test func anElbowThePaintingSawMustBeSeenNowAndOneItNeverSawIsNotHeldToAnything() {
        #expect(decide(replacingTheLeftElbow(of: frozenTorso(), with: nil)) == .outOfReach(.upperArmMoved))
        #expect(decide(frozenTorso(), frozen: replacingTheLeftElbow(of: frozenTorso(), with: nil)) == .follows)
    }

    @Test func aForearmCountsOnlyUnderALongSleeve() {
        let elbow = CGPoint(x: 185, y: 350)
        func forearmTurned(by degrees: Double) -> BodyTorso { replacingTheLeftWrist(of: frozenTorso(), with: turned(CGPoint(x: 175, y: 500), about: elbow, degrees: degrees)) }
        // A short sleeve stands off the arm, so a forearm that swings changes nothing.
        #expect(decide(forearmTurned(by: 40), followsTheForearms: false) == .follows)
        #expect(decide(forearmTurned(by: 25), followsTheForearms: true) == .outOfReach(.forearmMoved))
        #expect(decide(forearmTurned(by: 17), followsTheForearms: true, wasFollowing: true) == .follows)
        #expect(decide(forearmTurned(by: 17), followsTheForearms: true, wasFollowing: false) == .outOfReach(.forearmMoved))
        // A wrist the painting saw must be seen now, under a long sleeve.
        #expect(decide(replacingTheLeftWrist(of: frozenTorso(), with: nil), followsTheForearms: true) == .outOfReach(.forearmMoved))
        #expect(decide(replacingTheLeftWrist(of: frozenTorso(), with: nil), followsTheForearms: false) == .follows)
    }
}

// MARK: - The follower

struct ShirtLivePaintedTopFollowerTests {
    private func follower(followsTheForearms: Bool = false) -> ShirtLivePaintedTopFollower {
        let frame = CGRect(x: 0, y: 0, width: 640, height: 640)
        let clearImage = CIImage(color: .clear).cropped(to: frame)
        return ShirtLivePaintedTopFollower(top: ShirtLivePaintedTop(layer: clearImage, still: clearImage, paintedArea: clearImage, frozenTorso: frozenTorso(), followsTheForearms: followsTheForearms))
    }

    @Test func itStartsOnThePaintedStillWithNoHintAndNoStepTaken() {
        let follower = follower()
        #expect(follower.visibility == 0 && !follower.hintIsShowing && !follower.hasStarted)
        #expect(follower.reach == .outOfReach(.noTorso))
    }

    @Test func theLiveTopFadesInOverThreeTenthsOfASecondAndStaysAtOne() {
        var follower = follower()
        #expect(follower.advance(currentTorso: frozenTorso(), at: 10.0) == nil)
        #expect(follower.reach == .follows && follower.visibility == 0)
        _ = follower.advance(currentTorso: frozenTorso(), at: 10.1)
        #expect(abs(follower.visibility - 1.0 / 3) < 1e-9)
        _ = follower.advance(currentTorso: frozenTorso(), at: 10.2)
        #expect(abs(follower.visibility - 2.0 / 3) < 1e-9)
        _ = follower.advance(currentTorso: frozenTorso(), at: 10.3)
        // The clock's steps are not exactly a tenth of a second apart, so the third step lands a hair short of 1.
        #expect(abs(follower.visibility - 1) < 1e-9)
        _ = follower.advance(currentTorso: frozenTorso(), at: 10.4)
        #expect(follower.visibility == 1)
    }

    @Test func aStalledFrameMovesTheFadeByNoMoreThanAFrameOfRealTime() {
        var follower = follower()
        _ = follower.advance(currentTorso: frozenTorso(), at: 0)
        _ = follower.advance(currentTorso: frozenTorso(), at: 5)
        #expect(abs(follower.visibility - 1.0 / 3) < 1e-9)
    }

    @Test func leavingReachFadesBackToTheStillAndTheHintComesOnlyAfterHalfASecond() {
        var follower = follower()
        for step in 0...4 { _ = follower.advance(currentTorso: frozenTorso(), at: Double(step) * 0.1) }
        #expect(follower.visibility == 1)
        // The learner leaves the view at 1.0 s.
        #expect(follower.advance(currentTorso: nil, at: 1.0) == nil)
        #expect(follower.reach == .outOfReach(.noTorso) && abs(follower.visibility - 2.0 / 3) < 1e-9)
        _ = follower.advance(currentTorso: nil, at: 1.1)
        _ = follower.advance(currentTorso: nil, at: 1.2)
        _ = follower.advance(currentTorso: nil, at: 1.3)
        #expect(follower.visibility == 0)
        #expect(follower.advance(currentTorso: nil, at: 1.4) == nil && !follower.hintIsShowing)
        #expect(follower.advance(currentTorso: nil, at: 1.5) == true && follower.hintIsShowing)
        // The hint is reported once, not on every frame.
        #expect(follower.advance(currentTorso: nil, at: 1.6) == nil)
        // The learner comes back, and the hint goes at once.
        #expect(follower.advance(currentTorso: frozenTorso(), at: 1.7) == false && !follower.hintIsShowing)
        #expect(follower.reach == .follows)
    }

    @Test func aBriefStepPastALimitShowsNoHint() {
        var follower = follower()
        for step in 0...3 { _ = follower.advance(currentTorso: frozenTorso(), at: Double(step) * 0.1) }
        let tooClose = moved(frozenTorso(), by: turnAndScale(about: CGPoint(x: 300, y: 200), scale: 1.5))
        #expect(follower.advance(currentTorso: tooClose, at: 0.4) == nil)
        #expect(follower.reach == .outOfReach(.shouldersChangedSize))
        #expect(follower.advance(currentTorso: frozenTorso(), at: 0.6) == nil)
        #expect(follower.reach == .follows && !follower.hintIsShowing)
    }

    @Test func noHintShowsBeforeTheFirstPoseArrives() {
        var follower = follower()
        #expect(follower.advance(currentTorso: nil, at: 0) == nil)
        #expect(follower.advance(currentTorso: nil, at: 0.1) == nil)
        #expect(follower.advance(currentTorso: frozenTorso(), at: 0.2) == nil)
        #expect(!follower.hintIsShowing)
    }

    @Test func comingBackFromOutOfReachTakesMoreThanStayingInReachDoes() {
        var follower = follower()
        let atTheLimit = moved(frozenTorso(), by: turnAndScale(about: CGPoint(x: 300, y: 200), scale: 1.35))
        // From the frozen pose they walk closer to 1.35 and still follow.
        for step in 0...3 { _ = follower.advance(currentTorso: frozenTorso(), at: Double(step) * 0.1) }
        _ = follower.advance(currentTorso: atTheLimit, at: 0.4)
        #expect(follower.reach == .follows)
        // Past the limit, out of reach, and 1.35 is no longer enough to come back.
        let pastTheLimit = moved(frozenTorso(), by: turnAndScale(about: CGPoint(x: 300, y: 200), scale: 1.45))
        _ = follower.advance(currentTorso: pastTheLimit, at: 0.5)
        _ = follower.advance(currentTorso: atTheLimit, at: 0.6)
        #expect(follower.reach == .outOfReach(.shouldersChangedSize))
    }

    @Test func withNoPersonMaskTheStillShowsEvenWhileTheLiveTopIsVisible() {
        let stillCanvas = ShirtTestCanvas(width: 64, height: 64, color: (40, 200, 40))
        let layerCanvas = ShirtTestCanvas(width: 64, height: 64, color: (200, 40, 40))
        var follower = ShirtLivePaintedTopFollower(top: ShirtLivePaintedTop(
            layer: CIImage(cgImage: layerCanvas.cgImage), still: CIImage(cgImage: stillCanvas.cgImage), paintedArea: CIImage(color: .clear), frozenTorso: frozenTorso(), followsTheForearms: false
        ))
        for step in 0...4 { _ = follower.advance(currentTorso: frozenTorso(), at: Double(step) * 0.1) }
        #expect(follower.visibility == 1)
        let frame = ShirtTestCanvas(width: 64, height: 64, color: (120, 120, 120)).ciImage
        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        CIContext().render(follower.image(frame: frame, personMask: nil), toBitmap: &pixels, rowBytes: 64 * 4, bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let middle = (32 * 64 + 32) * 4
        #expect(abs(Int(pixels[middle]) - 40) <= 2 && abs(Int(pixels[middle + 1]) - 200) <= 2 && abs(Int(pixels[middle + 2]) - 40) <= 2)
    }
}

// MARK: - The layer

struct ShirtLivePaintedTopLayerTests {
    private static let width = 160, height = 120

    /// The masks of a top painted on a person whose shoulders are at (40, 30) and (120, 30), 80 pixels apart, so a hand rests
    /// on the top from 12 pixels (0.15 of a shoulder width) below the shoulder line: rows from 42. The top covers columns 30 to
    /// 129 and rows 28 to 109, less these protected places: a collar hole just below the shoulder line, a hand on the belly,
    /// and a hand at the left edge that is outside the top's outline. The neck above the top is not paintable, and the mask
    /// protects it, as the real mask does.
    private func masks() -> ShirtPaintMasks {
        var paintable = [UInt8](repeating: 0, count: Self.width * Self.height)
        var protected = paintable
        for row in 28..<110 {
            for column in 30..<130 { paintable[row * Self.width + column] = 255 }
        }
        func protect(centerColumn: Int, centerRow: Int, radius: Int) {
            for row in (centerRow - radius)...(centerRow + radius) {
                for column in (centerColumn - radius)...(centerColumn + radius) where (column - centerColumn) * (column - centerColumn) + (row - centerRow) * (row - centerRow) <= radius * radius {
                    paintable[row * Self.width + column] = 0
                    protected[row * Self.width + column] = 255
                }
            }
        }
        for row in 8..<28 {
            for column in 70..<90 { protected[row * Self.width + column] = 255 }
        }
        protect(centerColumn: 80, centerRow: 33, radius: 4)
        protect(centerColumn: 80, centerRow: 70, radius: 8)
        protect(centerColumn: 30, centerRow: 95, radius: 8)
        // The mask protects the ring around a hand only partly, as its feather does, and the ring is still the painted top.
        protected[79 * Self.width + 80] = 100
        return ShirtPaintMasks(width: Self.width, height: Self.height, paintable: paintable, protected: protected, oldShirt: [UInt8](repeating: 0, count: Self.width * Self.height))
    }

    private let torsoAtTheShoulders = BodyTorso(
        imageLeftShoulder: CGPoint(x: 40, y: 30), imageRightShoulder: CGPoint(x: 120, y: 30),
        imageLeftHip: CGPoint(x: 50, y: 100), imageRightHip: CGPoint(x: 110, y: 100), hipsWereEstimated: false, shouldersAreSeen: true
    )

    /// The painted still: a red top, blue where the hands are, and skin on the neck.
    private func paintedStill(of masks: ShirtPaintMasks) -> ShirtTestCanvas {
        var canvas = ShirtTestCanvas(width: Self.width, height: Self.height, color: (90, 90, 90))
        canvas.fill(columns: 30..<130, rows: 28..<110, color: (200, 40, 40))
        canvas.fill(columns: 70..<90, rows: 8..<28, color: (200, 150, 120))
        for index in 0..<(Self.width * Self.height) where masks.protected[index] == 255 {
            canvas.fill(columns: (index % Self.width)..<(index % Self.width + 1), rows: (index / Self.width)..<(index / Self.width + 1), color: (0, 0, 255))
        }
        // One pixel in the ring around the belly hand has a color of its own, which a blur of its neighbors would not give.
        canvas.fill(columns: 80..<81, rows: 79..<80, color: (150, 150, 40))
        return canvas
    }

    private func layerBytes() throws -> [UInt8] {
        let masks = masks()
        let pasteWeights = try #require(ShirtLivePaintedTop.pasteWeights(of: masks))
        return try #require(ShirtLivePaintedTop.premultipliedLayerBytes(stillRGBA: paintedStill(of: masks).bytes, masks: masks, pasteWeights: pasteWeights, frozenTorso: torsoAtTheShoulders))
    }

    private func pixel(_ bytes: [UInt8], column: Int, row: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let index = (row * Self.width + column) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]), Int(bytes[index + 3]))
    }

    @Test func theTopIsOpaqueAndKeepsItsPaintedColorsAwayFromTheEdgesAndTheHoles() throws {
        let bytes = try layerBytes()
        let middleOfTheTop = pixel(bytes, column: 50, row: 60)
        #expect(middleOfTheTop.alpha == 255 && middleOfTheTop.red == 200 && middleOfTheTop.green == 40 && middleOfTheTop.blue == 40)
    }

    @Test func theLayerReachesAsFarPastTheMaskAsThePasteDidSoTheOldTopsEdgeIsCovered() throws {
        let bytes = try layerBytes()
        // The top starts at column 30, and the paste grows it by 24 pixels and feathers that over 4.
        #expect(pixel(bytes, column: 16, row: 60).alpha == 255)
        #expect(pixel(bytes, column: 6, row: 60).alpha > 0 && pixel(bytes, column: 6, row: 60).alpha < 255)
        #expect(pixel(bytes, column: 1, row: 60).alpha < pixel(bytes, column: 6, row: 60).alpha)
        // The painted still's own pixels there, which the paste took from the painting.
        #expect(pixel(bytes, column: 16, row: 60).red == 90)
    }

    @Test func theNeckAndAHoleAtTheCollarStayClearSoTheLiveOnesShow() throws {
        let bytes = try layerBytes()
        // The neck is above the top, and the hole at (80, 33) is inside it but above the line 12 pixels below the shoulders.
        #expect(pixel(bytes, column: 80, row: 15).alpha == 0)
        #expect(pixel(bytes, column: 80, row: 33).alpha == 0)
    }

    @Test func aHandOnTheBellyIsFilledWithThePaintedTopsOwnColorAndNotTheHands() throws {
        let bytes = try layerBytes()
        let handCenter = pixel(bytes, column: 80, row: 70)
        #expect(handCenter.alpha >= 250)
        // Straight color, not the blue of the hand: the surrounding top is red, whatever the blur's radius.
        #expect(abs(handCenter.red - 200) <= 3 && abs(handCenter.green - 40) <= 3 && abs(handCenter.blue - 40) <= 3)
        // The ring around the hand is the painted top itself, with its own pixels.
        let ringAroundTheHand = pixel(bytes, column: 80, row: 70 + 9)
        #expect(ringAroundTheHand.alpha >= 250 && ringAroundTheHand.red == 150 && ringAroundTheHand.green == 150 && ringAroundTheHand.blue == 40)
    }

    @Test func aHandOutsideTheTopsOutlineIsNotFilledSoItsLiveColorsShow() throws {
        let bytes = try layerBytes()
        // This hand is a hole in the mask that joins the room outside the top, as a hand hanging at the side does. Not enclosed.
        #expect(pixel(bytes, column: 30, row: 95).alpha == 0)
    }

    @Test func aHoleTooBigForTheBlurIsFilledOnlyWhereTheTopIsNear() throws {
        // The shoulders are 8 pixels apart, so the blur reaches 2 pixels, and the hole is 20 pixels across.
        var paintable = [UInt8](repeating: 0, count: 60 * 60)
        var protected = paintable
        for row in 10..<50 { for column in 10..<50 { paintable[row * 60 + column] = 255 } }
        for row in 20..<40 { for column in 20..<40 { paintable[row * 60 + column] = 0; protected[row * 60 + column] = 255 } }
        let masks = ShirtPaintMasks(width: 60, height: 60, paintable: paintable, protected: protected, oldShirt: [UInt8](repeating: 0, count: 3600))
        let torso = BodyTorso(
            imageLeftShoulder: CGPoint(x: 22, y: 0), imageRightShoulder: CGPoint(x: 30, y: 0), imageLeftHip: CGPoint(x: 24, y: 50), imageRightHip: CGPoint(x: 28, y: 50),
            hipsWereEstimated: false, shouldersAreSeen: true
        )
        let still = ShirtTestCanvas(width: 60, height: 60, color: (200, 40, 40))
        let pasteWeights = try #require(ShirtLivePaintedTop.pasteWeights(of: masks))
        let bytes = try #require(ShirtLivePaintedTop.premultipliedLayerBytes(stillRGBA: still.bytes, masks: masks, pasteWeights: pasteWeights, frozenTorso: torso))
        // Next to the top, the hole takes the top's color, softened at the edge of the band the blur reached. At its middle
        // there is no top within reach, so it stays clear.
        let nextToTheTop = (alpha: Float(bytes[(30 * 60 + 20) * 4 + 3]), red: Float(bytes[(30 * 60 + 20) * 4]))
        #expect(nextToTheTop.alpha > 100 && abs(nextToTheTop.red / nextToTheTop.alpha * 255 - 200) < 4)
        #expect(bytes[(30 * 60 + 30) * 4 + 3] == 0)
    }

    @Test func theTopIsMadeForTheStillAndKnowsWhetherItsSleevesAreLong() throws {
        let masks = masks()
        let painted = paintedStill(of: masks).cgImage
        let shortSleeved = try #require(ShirtLivePaintedTop.make(painted: painted, masks: masks, frozenTorso: torsoAtTheShoulders, coverage: ShirtCoverage(sleeves: .short, length: .hip)))
        let longSleeved = try #require(ShirtLivePaintedTop.make(painted: painted, masks: masks, frozenTorso: torsoAtTheShoulders, coverage: ShirtCoverage(sleeves: .long, length: .hip)))
        #expect(!shortSleeved.followsTheForearms && longSleeved.followsTheForearms)
        #expect(shortSleeved.layer.extent == CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        #expect(shortSleeved.still.extent == shortSleeved.layer.extent)
        #expect(shortSleeved.frozenTorso == torsoAtTheShoulders)
    }

    @Test func aStillOfAnotherSizeThanTheMasksMakesNoTop() {
        let masks = masks()
        let otherSize = ShirtTestCanvas(width: Self.width + 1, height: Self.height, color: (200, 40, 40)).cgImage
        #expect(ShirtLivePaintedTop.make(painted: otherSize, masks: masks, frozenTorso: torsoAtTheShoulders, coverage: ShirtCoverage(sleeves: .short, length: .hip)) == nil)
        let noShoulders = BodyTorso(
            imageLeftShoulder: CGPoint(x: 40, y: 30), imageRightShoulder: CGPoint(x: 41, y: 30), imageLeftHip: CGPoint(x: 50, y: 100), imageRightHip: CGPoint(x: 51, y: 100),
            hipsWereEstimated: false, shouldersAreSeen: true
        )
        #expect(ShirtLivePaintedTop.make(painted: paintedStill(of: masks).cgImage, masks: masks, frozenTorso: noShoulders, coverage: ShirtCoverage(sleeves: .short, length: .hip)) == nil)
    }

    @Test func aBoxMeanKeepsAFlatImageFlatAndSpreadsAnImpulseOverItsWindow() {
        #expect(boxMeanFiltered([Float](repeating: 1, count: 25), width: 5, height: 5, radius: 2) == [Float](repeating: 1, count: 25))
        var impulse = [Float](repeating: 0, count: 81)
        impulse[4 * 9 + 4] = 1
        let spread = boxMeanFiltered(impulse, width: 9, height: 9, radius: 1)
        #expect(abs(spread[4 * 9 + 4] - 1.0 / 9) < 1e-6 && abs(spread[3 * 9 + 3] - 1.0 / 9) < 1e-6 && abs(spread[5 * 9 + 5] - 1.0 / 9) < 1e-6)
        #expect(spread[2 * 9 + 2] == 0 && spread[6 * 9 + 6] == 0)
    }
}

// MARK: - The motion and the composite

struct ShirtLivePaintedTopCompositeTests {
    private static let width = 100, height = 60

    /// A top made of a red rectangle, columns 20 to 59 and rows 10 to 49, clear elsewhere, over a green still, with the frozen
    /// torso of `frozenTorso()`.
    /// With no painted area, the whole layer is the band past the mask and is clipped to the person.
    private func top(paintedArea: CIImage = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))) -> ShirtLivePaintedTop {
        var layer = ShirtTestCanvas(width: Self.width, height: Self.height, color: (0, 0, 0))
        for row in 0..<Self.height {
            for column in 0..<Self.width {
                let inside = (20..<60).contains(column) && (10..<50).contains(row)
                let index = (row * Self.width + column) * 4
                layer.bytes[index] = inside ? 200 : 0
                layer.bytes[index + 1] = inside ? 40 : 0
                layer.bytes[index + 2] = inside ? 40 : 0
                layer.bytes[index + 3] = inside ? 255 : 0
            }
        }
        let still = ShirtTestCanvas(width: Self.width, height: Self.height, color: (40, 200, 40))
        return ShirtLivePaintedTop(
            layer: CIImage(cgImage: layer.cgImage), still: CIImage(cgImage: still.cgImage), paintedArea: paintedArea, frozenTorso: frozenTorso(), followsTheForearms: false
        )
    }

    private func frame() -> ShirtTestCanvas { ShirtTestCanvas(width: Self.width, height: Self.height, color: (120, 120, 120)) }

    /// White where the person is: the left half of the frame, columns 0 to 49.
    private func personMask() -> CIImage {
        var canvas = ShirtTestCanvas(width: Self.width, height: Self.height, color: (0, 0, 0))
        canvas.fill(columns: 0..<50, rows: 0..<Self.height, color: (255, 255, 255))
        return CIImage(bitmapData: Data(canvas.bytes), bytesPerRow: Self.width * 4, size: CGSize(width: Self.width, height: Self.height), format: .RGBA8, colorSpace: nil)
    }

    private func render(_ image: CIImage) -> ShirtTestCanvas {
        var canvas = ShirtTestCanvas(width: Self.width, height: Self.height, color: (0, 0, 0))
        canvas.bytes.withUnsafeMutableBytes { buffer in
            CIContext().render(image, toBitmap: buffer.baseAddress!, rowBytes: Self.width * 4, bounds: CGRect(x: 0, y: 0, width: Self.width, height: Self.height), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return canvas
    }

    private func isClose(_ pixel: (red: Int, green: Int, blue: Int), to color: (Int, Int, Int)) -> Bool {
        abs(pixel.red - color.0) <= 2 && abs(pixel.green - color.1) <= 2 && abs(pixel.blue - color.2) <= 2
    }

    @Test func atVisibilityZeroTheCompositeIsThePaintedStill() {
        let composite = render(top().composite(frame: frame().ciImage, personMask: personMask(), transform: .identity, visibility: 0))
        for (column, row) in [(5, 5), (30, 30), (55, 30), (90, 50)] {
            #expect(isClose(composite.pixel(column: column, row: row), to: (40, 200, 40)))
        }
    }

    @Test func atVisibilityOneTheTopIsClippedToThePersonAndTheFrameShowsElsewhere() {
        let composite = render(top().composite(frame: frame().ciImage, personMask: personMask(), transform: .identity, visibility: 1))
        // Inside the top and the person: the painted color.
        #expect(isClose(composite.pixel(column: 30, row: 30), to: (200, 40, 40)))
        // Inside the top but outside the person, columns 50 and up: the live frame, whose person mask has the learner gone.
        #expect(isClose(composite.pixel(column: 55, row: 30), to: (120, 120, 120)))
        // On the person but outside the top, and far from both: the live frame.
        #expect(isClose(composite.pixel(column: 10, row: 30), to: (120, 120, 120)))
        #expect(isClose(composite.pixel(column: 90, row: 55), to: (120, 120, 120)))
    }

    @Test func thePaintedAreaDrawsEvenWhereTheLivePersonMaskIsNotSoABulkySleeveKeepsItsShape() {
        // The painted area is columns 50 to 59 of the top, past the person's edge at 50: the sleeve's bulk.
        var area = ShirtTestCanvas(width: Self.width, height: Self.height, color: (0, 0, 0))
        area.fill(columns: 50..<60, rows: 10..<50, color: (255, 255, 255))
        let composite = render(top(paintedArea: CIImage(cgImage: area.cgImage, options: [.colorSpace: NSNull()])).composite(
            frame: frame().ciImage, personMask: personMask(), transform: .identity, visibility: 1
        ))
        #expect(isClose(composite.pixel(column: 55, row: 30), to: (200, 40, 40)))
        // Outside the painted area and the person, the live frame still shows.
        #expect(isClose(composite.pixel(column: 90, row: 55), to: (120, 120, 120)))
    }

    @Test func theTopMovesWithTheYDownTransformItIsGiven() {
        // 10 right and 8 down: the top's rectangle is columns 30 to 69 and rows 18 to 57.
        let composite = render(top().composite(frame: frame().ciImage, personMask: personMask(), transform: CGAffineTransform(translationX: 10, y: 8), visibility: 1))
        #expect(isClose(composite.pixel(column: 35, row: 30), to: (200, 40, 40)))
        #expect(isClose(composite.pixel(column: 40, row: 55), to: (200, 40, 40)))
        // Where the top was, and is no more, the live frame shows. Rows 10 to 17 were the top's, and are now above it.
        #expect(isClose(composite.pixel(column: 25, row: 30), to: (120, 120, 120)))
        #expect(isClose(composite.pixel(column: 40, row: 13), to: (120, 120, 120)))
    }

    @Test func halfwayBetweenTheStillAndTheLiveTopTheCompositeIsBetweenThem() {
        let composite = render(top().composite(frame: frame().ciImage, personMask: personMask(), transform: .identity, visibility: 0.5))
        let middle = composite.pixel(column: 30, row: 30)
        #expect(middle.red > 45 && middle.red < 195 && middle.green > 45 && middle.green < 195)
    }

    @Test func theMotionCarriesTheFrozenShouldersAndHipsOntoTheCurrentOnes() {
        let top = ShirtLivePaintedTop(layer: CIImage(color: .clear), still: CIImage(color: .clear), paintedArea: CIImage(color: .clear), frozenTorso: frozenTorso(), followsTheForearms: false)
        // A shift, a turn of 8 degrees, and a scale of 0.9, about the shoulders' middle.
        let motion = turnAndScale(about: CGPoint(x: 300, y: 200), degrees: 8, scale: 0.9).concatenating(CGAffineTransform(translationX: 30, y: -12))
        let current = moved(frozenTorso(), by: motion)
        let transform = top.transform(to: current)
        for (frozenPoint, currentPoint) in [
            (frozenTorso().imageLeftShoulder, current.imageLeftShoulder), (frozenTorso().imageRightShoulder, current.imageRightShoulder),
            (frozenTorso().hipMidpoint, current.hipMidpoint),
        ] {
            let carried = frozenPoint.applying(transform)
            #expect(abs(carried.x - currentPoint.x) < 1e-6 && abs(carried.y - currentPoint.y) < 1e-6)
        }
    }

    @Test func theMotionIsTheShouldersTurnScaleAndShiftAloneWhateverTheHipsDo() {
        func torso(hipsY: Double, hipsWereEstimated: Bool) -> BodyTorso {
            BodyTorso(
                imageLeftShoulder: CGPoint(x: 200, y: 200), imageRightShoulder: CGPoint(x: 400, y: 200),
                imageLeftHip: CGPoint(x: 230, y: hipsY), imageRightHip: CGPoint(x: 370, y: hipsY), hipsWereEstimated: hipsWereEstimated, shouldersAreSeen: true
            )
        }
        func top(frozen: BodyTorso) -> ShirtLivePaintedTop {
            ShirtLivePaintedTop(layer: CIImage(color: .clear), still: CIImage(color: .clear), paintedArea: CIImage(color: .clear), frozenTorso: frozen, followsTheForearms: false)
        }
        // The shoulders have not moved and the hips have, whether each is seen or estimated: a hip flag that flickers from
        // frame to frame never moves the top.
        for (frozenHipsEstimated, currentHipsEstimated) in [(false, false), (false, true), (true, false), (true, true)] {
            let transform = top(frozen: torso(hipsY: 500, hipsWereEstimated: frozenHipsEstimated)).transform(to: torso(hipsY: 400, hipsWereEstimated: currentHipsEstimated))
            #expect(abs(transform.a - 1) < 1e-9 && abs(transform.d - 1) < 1e-9 && abs(transform.b) < 1e-9 && abs(transform.c) < 1e-9)
            #expect(abs(transform.tx) < 1e-9 && abs(transform.ty) < 1e-9)
        }
        // A turn and a scale of the shoulders is a similarity: no shear, and the same scale along both axes.
        let turned = moved(frozenTorso(), by: turnAndScale(about: CGPoint(x: 300, y: 200), degrees: 6, scale: 1.1))
        let similarity = top(frozen: frozenTorso()).transform(to: turned)
        #expect(abs(similarity.a - similarity.d) < 1e-9 && abs(similarity.b + similarity.c) < 1e-9)
        for (frozenPoint, currentPoint) in [(frozenTorso().imageLeftShoulder, turned.imageLeftShoulder), (frozenTorso().imageRightShoulder, turned.imageRightShoulder)] {
            let carried = frozenPoint.applying(similarity)
            #expect(abs(carried.x - currentPoint.x) < 1e-6 && abs(carried.y - currentPoint.y) < 1e-6)
        }
    }
}
