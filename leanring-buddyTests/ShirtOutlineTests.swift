//
//  ShirtOutlineTests.swift
//  leanring-buddyTests
//
//  The outline Clicky's loop traces around a shirt: the contour of a generated T-shirt mask, cut to 40 to 80 points and
//  smoothed, keeping the sleeves and the neckline's dip, and drawn as a closed line.
//

import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Clicky

/// A 200 by 200 T-shirt: a torso from x 60 to 140 and y 50 to 180, a short sleeve on each side reaching out 35 pixels, and a
/// round neckline 18 pixels deep cut out of the top middle.
private let tShirtSize = 200
private func tShirtMask() -> [Bool] {
    var mask = [Bool](repeating: false, count: tShirtSize * tShirtSize)
    for row in 0..<tShirtSize {
        for column in 0..<tShirtSize {
            let inTheTorso = (60..<140).contains(column) && (50..<180).contains(row)
            // Each sleeve slopes down and out from the shoulder.
            let leftSleeve = (25..<60).contains(column) && row >= 50 + (60 - column) / 3 && row < 95
            let rightSleeve = (140..<175).contains(column) && row >= 50 + (column - 140) / 3 && row < 95
            let inTheNeckline = pow(Double(column) - 100, 2) + pow(Double(row) - 50, 2) < 18 * 18
            mask[row * tShirtSize + column] = (inTheTorso || leftSleeve || rightSleeve) && !inTheNeckline
        }
    }
    return mask
}

struct ShirtOutlineTests {
    private let mask = tShirtMask()

    private func distanceToTheMasksEdge(_ point: CGPoint) -> Double {
        // The nearest pixel center whose set state differs from a neighbor's.
        var nearest = Double.infinity
        for row in 1..<(tShirtSize - 1) {
            for column in 1..<(tShirtSize - 1) where mask[row * tShirtSize + column] {
                let isEdge = !mask[row * tShirtSize + column - 1] || !mask[row * tShirtSize + column + 1] || !mask[(row - 1) * tShirtSize + column] || !mask[(row + 1) * tShirtSize + column]
                guard isEdge else { continue }
                nearest = min(nearest, hypot(Double(point.x) - (Double(column) + 0.5), Double(point.y) - (Double(row) + 0.5)))
            }
        }
        return nearest
    }

    @Test func theContourWalksTheWholeEdgeFromTheTopLeftPixel() {
        let contour = ShirtOutline.outerContour(of: mask, width: tShirtSize, height: tShirtSize)
        #expect(contour.count > 400)
        #expect(contour.first.map { $0.y } == 50.5)
        // Every contour point is a pixel of the shirt on its edge, and the contour reaches both sleeves and the hem.
        for point in contour.prefix(200) { #expect(distanceToTheMasksEdge(point) < 0.01) }
        #expect(contour.map(\.x).min() == 25.5 && contour.map(\.x).max() == 174.5)
        #expect(contour.map(\.y).max() == 179.5)
    }

    @Test func theOutlineHasFortyToEightyPointsHugTheShirtAndKeepItsShape() throws {
        let outline = try #require(ShirtOutline.outline(of: mask, width: tShirtSize, height: tShirtSize))
        #expect((ShirtOutline.fewestPoints...ShirtOutline.mostPoints).contains(outline.count), "\(outline.count) points")
        // Smoothed, it stays within a few pixels of the shirt's edge.
        for point in outline { #expect(distanceToTheMasksEdge(point) < 4, "\(point)") }
        // Both sleeves are traced, not cut across.
        #expect(outline.contains { $0.x < 32 } && outline.contains { $0.x > 168 })
        // The neckline dips in at the top middle, below the shoulders' top edge.
        let neckPoints = outline.filter { (94...106).contains($0.x) && $0.y < 120 }
        #expect(!neckPoints.isEmpty && neckPoints.allSatisfy { $0.y > 60 }, "\(neckPoints)")
        // The shoulders' top edge, beside the neckline, is traced at its own height.
        #expect(outline.contains { (55...85).contains($0.x) && $0.y < 57 })
        // The hem runs along the bottom.
        #expect(outline.contains { $0.y > 176 })
    }

    @Test func aContourWithFewPointsIsLeftAsItIs() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        #expect(ShirtOutline.simplified(square) == square)
        #expect(ShirtOutline.outline(of: [Bool](repeating: false, count: 16), width: 4, height: 4) == nil)
    }

    @Test func smoothingKeepsTheCountAndTheMiddle() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let smoothed = ShirtOutline.smoothed(square, passes: 2)
        #expect(smoothed.count == 4)
        let meanX: CGFloat = smoothed.map(\.x).reduce(0, +) / 4
        let meanY: CGFloat = smoothed.map(\.y).reduce(0, +) / 4
        #expect(abs(meanX - 5) < 1e-9 && abs(meanY - 5) < 1e-9)
        // Corners round inward.
        #expect(smoothed[0].x > 0 && smoothed[0].y > 0)
    }

    @Test func theOutlineFollowsTheShouldersTurnScaleAndShift() {
        let traced = BodyTorso(imageLeftShoulder: CGPoint(x: 100, y: 100), imageRightShoulder: CGPoint(x: 200, y: 100), imageLeftHip: CGPoint(x: 110, y: 250), imageRightHip: CGPoint(x: 190, y: 250), hipsWereEstimated: false, shouldersAreSeen: true)
        let current = BodyTorso(imageLeftShoulder: CGPoint(x: 140, y: 120), imageRightShoulder: CGPoint(x: 340, y: 120), imageLeftHip: CGPoint(x: 160, y: 420), imageRightHip: CGPoint(x: 320, y: 420), hipsWereEstimated: false, shouldersAreSeen: true)
        let moved = ShirtOutline.moved([CGPoint(x: 150, y: 100), CGPoint(x: 150, y: 200)], from: traced, to: current)
        #expect(hypot(moved[0].x - 240, moved[0].y - 120) < 1e-9)
        #expect(hypot(moved[1].x - 240, moved[1].y - 320) < 1e-9)
        #expect(ShirtOutline.scaled([CGPoint(x: 10, y: 20)], fromMaskScale: 0.5) == [CGPoint(x: 20, y: 40)])
    }

    @Test func aLoopTracesTheOutlineAsASmoothClosedLine() throws {
        let outline = [CGPoint(x: 10, y: 10), CGPoint(x: 90, y: 12), CGPoint(x: 88, y: 70), CGPoint(x: 12, y: 68)]
        let snapshot = try #require(RoomArtLoopSnapshot(tracing: outline))
        #expect(snapshot.keyframeCorners == RoomArtCorners(rect: CGRect(x: 10, y: 10, width: 80, height: 60)))
        #expect(RoomArtLoopSnapshot(tracing: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)]) == nil)

        let fit = RoomArtVideoFit(cameraSize: CGSize(width: 100, height: 80), viewSize: CGSize(width: 200, height: 160))
        let path = try #require(RoomArtLoopOutline.path(for: snapshot, fit: fit))
        // Drawn at the panel's scale, through the outline's points, starting at the first.
        #expect(path.trimmedPath(from: 0, to: 0.0005).currentPoint.map { hypot($0.x - 20, $0.y - 20) < 1 } == true)
        // The line itself, not its control points, stays near the outline.
        let box = path.cgPath.boundingBoxOfPath
        #expect(box.minX > 10 && box.maxX < 190 && box.minY > 10 && box.maxY < 150, "\(box)")
        #expect(box.width > 150 && box.height > 110)
        #expect(RoomArtLoopOutline.closedPath(through: Array(outline.prefix(2))) == nil)
    }

    @Test func thePaintMasksOutlineIsInTheFramesPixels() throws {
        // A 400 by 300 mask with a rectangle, traced on a copy scaled to 200 wide and scaled back.
        var paintable = [UInt8](repeating: 0, count: 400 * 300)
        for row in 60..<240 { for column in 100..<300 { paintable[row * 400 + column] = 255 } }
        let masks = ShirtPaintMasks(width: 400, height: 300, paintable: paintable, protected: [UInt8](repeating: 0, count: 400 * 300), oldShirt: paintable)
        let outline = try #require(ShirtPaintMask.outlineOfThePaintableArea(masks))
        #expect(abs((outline.map(\.x).min() ?? 0) - 100) < 6 && abs((outline.map(\.x).max() ?? 0) - 300) < 6)
        #expect(abs((outline.map(\.y).min() ?? 0) - 60) < 6 && abs((outline.map(\.y).max() ?? 0) - 240) < 6)
    }
}
