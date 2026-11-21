//
//  TetherCarrierTests.swift
//  leanring-buddyTests
//
//  The carrier's plans for Send, Glide from origin, and Return to source, the layer transform that places a pose, and the
//  tether line's keyframes. The panel itself only plays these.
//

import CoreGraphics
import Foundation
import Testing

@testable import Clicky

@MainActor
struct TetherCarrierTests {
    private let cursorPoint = CGPoint(x: 700, y: 400)
    private let slotPoint = CGPoint(x: 900, y: 880)
    private let tokenSize = CGSize(width: 28, height: 28)

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    // MARK: - Send

    @Test func aSendFollowsTheServeArcAtFullSizeAndTethersTheCursorToTheToken() {
        let path = agentTokenServePath(from: cursorPoint, to: slotPoint)
        let plan = CarrierFlightPlan.send(along: path, carriedSize: tokenSize)
        #expect(plan.seconds == 0.5)
        #expect(plan.poses.first?.pivot == cursorPoint)
        #expect(plan.poses.last?.pivot == slotPoint)
        #expect(distance(plan.poses[plan.poses.count / 2].pivot, path.point(atFlightProgress: 0.5)) < 0.001)
        #expect(plan.poses.allSatisfy { $0.scale == 1 && $0.opacity == 1 })
        #expect(plan.restingFrame == CGRect(x: 886, y: 866, width: 28, height: 28))
        #expect(plan.pivotAtRest == slotPoint)
        #expect(plan.tetherOrigin == cursorPoint)
        // About one keyframe per frame on a 120 Hz display.
        #expect(plan.poses.count == 61)
    }

    // MARK: - Glide and Return to source

    private let disc = CGPoint(x: 1000, y: 880)
    private let cardFrame = CGRect(x: 900, y: 500, width: 340, height: 360)

    @Test func aGlideGrowsOutOfTheOriginIntoTheNearestPointOfTheCard() throws {
        let plan = CarrierFlightPlan.glideFromOrigin(disc, into: cardFrame)
        // The disc is above the card, so the card grows from the middle of its top edge under the disc.
        #expect(plan.pivotAtRest == CGPoint(x: 1000, y: 860))
        let firstPose = try #require(plan.poses.first)
        let lastPose = try #require(plan.poses.last)
        #expect(firstPose == CarrierPose(pivot: disc, scale: DS.Move.glideStartScale, opacity: 0))
        #expect(lastPose == CarrierPose(pivot: plan.pivotAtRest, scale: 1, opacity: 1))
        #expect(plan.seconds == DS.Move.glide.curve.seconds())
        #expect(plan.tetherOrigin == disc)
        #expect(plan.restingFrame == cardFrame)
    }

    @Test func aCardBesideItsOriginGrowsFromItsNearestCorner() {
        let plan = CarrierFlightPlan.glideFromOrigin(CGPoint(x: 800, y: 900), into: cardFrame)
        #expect(plan.pivotAtRest == CGPoint(x: 900, y: 860))
    }

    @Test func aReturnToSourceClosesBackIntoTheOriginFasterAndEndsHidden() {
        let openPlan = CarrierFlightPlan.glideFromOrigin(disc, into: cardFrame)
        let closePlan = CarrierFlightPlan.returnToSource(from: cardFrame, into: disc)
        #expect(closePlan.poses.first == CarrierPose(pivot: closePlan.pivotAtRest, scale: 1, opacity: 1))
        #expect(closePlan.poses.last == CarrierPose(pivot: disc, scale: DS.Move.glideStartScale, opacity: 0))
        #expect(abs(closePlan.seconds - openPlan.seconds * DS.Move.glideCloseTimeFactor) < 1e-9)
        #expect(closePlan.pivotAtRest == openPlan.pivotAtRest)
    }

    // MARK: - Placing a pose

    /// Where a layer's point lands under the carrier's transform for `pose`: scale about the anchor, then translate.
    private func placed(_ pointInLayer: CGPoint, by pose: CarrierPose, in plan: CarrierFlightPlan, anchorInLayer: CGPoint) -> CGPoint {
        let translation = carrierLayerTranslation(for: pose, restingFrame: plan.restingFrame, pivotAtRest: plan.pivotAtRest, anchorInLayer: anchorInLayer)
        let position = CGPoint(x: plan.restingFrame.minX + anchorInLayer.x, y: plan.restingFrame.minY + anchorInLayer.y)
        return CGPoint(
            x: position.x + pose.scale * (pointInLayer.x - anchorInLayer.x) + translation.dx,
            y: position.y + pose.scale * (pointInLayer.y - anchorInLayer.y) + translation.dy
        )
    }

    @Test func aPosePutsThePivotOnItsPointAndScalesTheViewAboutItWhereverTheLayersAnchorIs() throws {
        let plan = CarrierFlightPlan.glideFromOrigin(disc, into: cardFrame)
        let pose = CarrierPose(pivot: CGPoint(x: 1010, y: 870), scale: 0.5, opacity: 1)
        let pivotInLayer = CGPoint(x: plan.pivotAtRest.x - cardFrame.minX, y: plan.pivotAtRest.y - cardFrame.minY)
        for anchorInLayer in [CGPoint.zero, CGPoint(x: 170, y: 180)] {
            #expect(distance(placed(pivotInLayer, by: pose, in: plan, anchorInLayer: anchorInLayer), pose.pivot) < 1e-9)
            // The card's bottom-left corner is half as far from the pivot as it is at rest.
            let corner = placed(.zero, by: pose, in: plan, anchorInLayer: anchorInLayer)
            #expect(distance(corner, CGPoint(x: pose.pivot.x - pivotInLayer.x / 2, y: pose.pivot.y - pivotInLayer.y / 2)) < 1e-9)
        }
        // The last pose of a Glide is the view at rest, which is what it shows once its animations are removed.
        let restingTranslation = carrierLayerTranslation(for: try #require(plan.poses.last), restingFrame: plan.restingFrame, pivotAtRest: plan.pivotAtRest, anchorInLayer: .zero)
        #expect(abs(restingTranslation.dx) < 1e-9 && abs(restingTranslation.dy) < 1e-9)
    }

    // MARK: - Tether

    @Test func theTetherRunsFromTheOriginToEachPivotAndTurnsTheShortWayPastStraightLeft() {
        let origin = CGPoint(x: 0, y: 0)
        let lines = carrierTetherLines(from: origin, to: [CGPoint(x: -10, y: 1), CGPoint(x: -10, y: -1), CGPoint(x: 0, y: -10)])
        #expect(abs(lines[0].length - hypot(10, 1)) < 1e-9)
        // atan2 jumps from about +π to about -π here, and the unwrapped angle keeps going past π instead.
        #expect(lines[1].angle > .pi)
        #expect(abs(lines[1].angle - lines[0].angle) < 0.3)
        #expect(abs(lines[2].angle - 1.5 * .pi) < 1e-9)
    }
}
