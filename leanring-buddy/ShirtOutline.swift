//
//  ShirtOutline.swift
//  leanring-buddy
//
//  The line Clicky's loop draws around a shirt: the outline of the learner's own top while the try-on is prepared, and of
//  the area being painted while "Putting it on you…" shows, instead of a box over the body. The outline is the outer contour
//  of a mask (`ShirtPaintMask`), smoothed and simplified to about 40 to 80 points, so it reads as a hand-drawn line around
//  the shoulders, sleeves, sides, and hem, with the neckline dipping in at the top. Every step is a pure function.
//

import CoreGraphics
import Foundation
import simd

nonisolated enum ShirtOutline {
    /// The outline keeps from `fewestPoints` to `mostPoints` points: fewer loses the sleeves, and more follows the mask's
    /// pixel steps, which reads as a trace, not a drawn line.
    static let fewestPoints = 40
    static let mostPoints = 80
    /// The pixel contour is smoothed this many times before it is simplified, which rounds off its pixel steps. Smoothing
    /// after simplifying pulled a sleeve's tip and the hem's corners in by up to 24 pixels, since the points are far apart
    /// by then. The closed line drawn through the points (`RoomArtLoopOutline.closedPath`) is what makes it curve.
    static let smoothingPasses = 4

    /// The outline of the largest piece of `mask`, smoothed and simplified, in the mask's pixels with y down, clockwise on
    /// screen. Nil when the mask has no piece with an area.
    static func outline(of mask: [Bool], width: Int, height: Int) -> [CGPoint]? {
        let contour = outerContour(of: mask, width: width, height: height)
        guard contour.count >= 3 else { return nil }
        return simplified(smoothed(contour, passes: smoothingPasses))
    }

    // MARK: The contour

    /// The outer boundary of the mask's largest 8-connected piece, as the centers of its boundary pixels in order (Moore
    /// neighbor tracing), first point the piece's top left pixel. Holes inside the piece are not traced.
    static func outerContour(of mask: [Bool], width: Int, height: Int) -> [CGPoint] {
        guard width > 0, height > 0, mask.count == width * height, let start = topLeftPixelOfTheLargestPiece(of: mask, width: width, height: height) else { return [] }
        func isSet(_ column: Int, _ row: Int) -> Bool { column >= 0 && row >= 0 && column < width && row < height && mask[row * width + column] }
        // The eight neighbors clockwise on screen (y down), starting west.
        let neighborOffsets = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        var contour = [CGPoint(x: Double(start.column) + 0.5, y: Double(start.row) + 0.5)]
        var current = start
        // The start is the top left pixel, so the pixel west of it is outside: the search begins there.
        var backtrackDirection = 0
        let mostSteps = 4 * width * height
        for _ in 0..<mostSteps {
            var foundNext = false
            for turn in 0..<8 {
                let direction = (backtrackDirection + 1 + turn) % 8
                let candidate = (column: current.column + neighborOffsets[direction].0, row: current.row + neighborOffsets[direction].1)
                guard isSet(candidate.column, candidate.row) else { continue }
                // The next search starts from the neighbor just before the one found, as seen from the new pixel.
                backtrackDirection = (direction + 4 + 1) % 8
                current = candidate
                foundNext = true
                break
            }
            // A single pixel has no neighbor to walk to.
            guard foundNext, !(current == start) else { break }
            contour.append(CGPoint(x: Double(current.column) + 0.5, y: Double(current.row) + 0.5))
        }
        return contour
    }

    private static func topLeftPixelOfTheLargestPiece(of mask: [Bool], width: Int, height: Int) -> (column: Int, row: Int)? {
        var visited = [Bool](repeating: false, count: mask.count)
        var best: (size: Int, topLeft: Int)?
        var pending: [Int] = []
        for start in mask.indices where mask[start] && !visited[start] {
            visited[start] = true
            pending.append(start)
            var size = 0
            var topLeft = start
            while let index = pending.popLast() {
                size += 1
                topLeft = min(topLeft, index)
                let row = index / width, column = index % width
                for rowOffset in -1...1 {
                    for columnOffset in -1...1 where rowOffset != 0 || columnOffset != 0 {
                        let neighborRow = row + rowOffset, neighborColumn = column + columnOffset
                        guard neighborRow >= 0, neighborRow < height, neighborColumn >= 0, neighborColumn < width else { continue }
                        let neighbor = neighborRow * width + neighborColumn
                        if mask[neighbor] && !visited[neighbor] {
                            visited[neighbor] = true
                            pending.append(neighbor)
                        }
                    }
                }
            }
            if size > (best?.size ?? 0) { best = (size, topLeft) }
        }
        // The smallest index in reading order is the top row's leftmost pixel, whose west neighbor is outside.
        return best.map { (column: $0.topLeft % width, row: $0.topLeft / width) }
    }

    // MARK: Simplifying

    /// The closed contour cut to `fewestPoints` to `mostPoints` points by Douglas-Peucker, with the tolerance searched so
    /// the count lands in that range when the contour has enough points. The two points farthest apart anchor the split,
    /// so the result does not depend on where the contour starts.
    static func simplified(_ contour: [CGPoint]) -> [CGPoint] {
        guard contour.count > mostPoints else { return contour }
        var lowTolerance = 0.0, highTolerance = 1.0
        let maximumSpan = contour.map { simd_length(vector($0) - vector(contour[0])) }.max() ?? 1
        highTolerance = max(1, maximumSpan)
        var best = douglasPeuckerClosed(contour, tolerance: highTolerance)
        for _ in 0..<40 {
            let tolerance = (lowTolerance + highTolerance) / 2
            let candidate = douglasPeuckerClosed(contour, tolerance: tolerance)
            if candidate.count > mostPoints {
                lowTolerance = tolerance
            } else {
                best = candidate
                highTolerance = tolerance
                if candidate.count >= fewestPoints { break }
            }
        }
        return best
    }

    private static func vector(_ point: CGPoint) -> SIMD2<Double> { SIMD2(Double(point.x), Double(point.y)) }

    private static func douglasPeuckerClosed(_ contour: [CGPoint], tolerance: Double) -> [CGPoint] {
        let first = vector(contour[0])
        let farthestIndex = contour.indices.max { simd_length(vector(contour[$0]) - first) < simd_length(vector(contour[$1]) - first) } ?? 0
        guard farthestIndex > 0 else { return contour }
        let firstHalf = douglasPeucker(Array(contour[0...farthestIndex]), tolerance: tolerance)
        let secondHalf = douglasPeucker(Array(contour[farthestIndex...]) + [contour[0]], tolerance: tolerance)
        // Each half ends where the other starts, so the shared points are kept once.
        return Array(firstHalf.dropLast()) + Array(secondHalf.dropLast())
    }

    private static func douglasPeucker(_ points: [CGPoint], tolerance: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var spans = [(0, points.count - 1)]
        while let (startIndex, endIndex) = spans.popLast() {
            guard endIndex > startIndex + 1 else { continue }
            let start = vector(points[startIndex]), end = vector(points[endIndex])
            let segment = end - start
            let segmentLength = simd_length(segment)
            var farthest = (index: startIndex, distance: -1.0)
            for index in (startIndex + 1)..<endIndex {
                let offset = vector(points[index]) - start
                let distance = segmentLength > 0 ? abs(offset.x * segment.y - offset.y * segment.x) / segmentLength : simd_length(offset)
                if distance > farthest.distance { farthest = (index, distance) }
            }
            if farthest.distance > tolerance {
                keep[farthest.index] = true
                spans.append((startIndex, farthest.index))
                spans.append((farthest.index, endIndex))
            }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    // MARK: Smoothing

    /// Each point moved halfway toward the middle of its two neighbors, `passes` times, around the closed line. The count
    /// stays the same, the corners round off, and a large shape such as the neckline keeps its dip.
    static func smoothed(_ points: [CGPoint], passes: Int) -> [CGPoint] {
        guard points.count >= 3, passes > 0 else { return points }
        var current = points
        for _ in 0..<passes {
            current = current.indices.map { index in
                let previous = current[(index + current.count - 1) % current.count], next = current[(index + 1) % current.count]
                return CGPoint(
                    x: 0.5 * current[index].x + 0.25 * (previous.x + next.x),
                    y: 0.5 * current[index].y + 0.25 * (previous.y + next.y)
                )
            }
        }
        return current
    }

    // MARK: Following the body

    /// The outline moved from the torso it was traced on to `currentTorso`: the turn, scale, and shift that carry the first
    /// torso's shoulders onto the current one's, so the line keeps up with the learner between traces.
    static func moved(_ outline: [CGPoint], from tracedTorso: BodyTorso, to currentTorso: BodyTorso) -> [CGPoint] {
        let tracedLeft = vector(tracedTorso.imageLeftShoulder), tracedRight = vector(tracedTorso.imageRightShoulder)
        let currentLeft = vector(currentTorso.imageLeftShoulder), currentRight = vector(currentTorso.imageRightShoulder)
        let tracedSpan = tracedRight - tracedLeft, currentSpan = currentRight - currentLeft
        let tracedLength = simd_length(tracedSpan)
        guard tracedLength > 0 else { return outline }
        let scale = simd_length(currentSpan) / tracedLength
        let angle = atan2(currentSpan.y, currentSpan.x) - atan2(tracedSpan.y, tracedSpan.x)
        let cosine = cos(angle) * scale, sine = sin(angle) * scale
        let tracedMiddle = (tracedLeft + tracedRight) / 2, currentMiddle = (currentLeft + currentRight) / 2
        return outline.map { point in
            let offset = vector(point) - tracedMiddle
            let moved = currentMiddle + SIMD2(cosine * offset.x - sine * offset.y, sine * offset.x + cosine * offset.y)
            return CGPoint(x: moved.x, y: moved.y)
        }
    }

    /// The outline scaled from a mask's pixels to the frame's, where the mask was `scale` times the frame's size.
    static func scaled(_ outline: [CGPoint], fromMaskScale scale: Double) -> [CGPoint] {
        guard scale > 0 else { return outline }
        return outline.map { CGPoint(x: Double($0.x) / scale, y: Double($0.y) / scale) }
    }
}

nonisolated extension ShirtPaintMask {
    /// The long side the learner's own top is traced at for the loop, small enough to trace twice a second.
    static let outlineLongestSide = 200

    /// The learner's own top while the try-on is prepared, at `outlineLongestSide`: the old top, the torso, closed and with
    /// its holes filled, without the neck, the head, and bare skin (`workingMasks` with no new top landed yet). `rgba` and
    /// `personMask` are at `width` by `height`, and so is the result. Nil when the old top's color cannot be read.
    static func oldGarmentArea(rgba: [UInt8], personMask: [UInt8], torso: BodyTorso, width: Int, height: Int) -> [Bool]? {
        guard width >= 3, height >= 3, rgba.count == width * height * 4, personMask.count == width * height,
              (0..<Double(width)).contains(Double(torso.shoulderMidpoint.x)), (0..<Double(height)).contains(Double(torso.shoulderMidpoint.y)) else { return nil }
        return workingMasks(rgba: rgba, personMask: personMask, previewGarmentCoverage: [UInt8](repeating: 0, count: width * height), torso: torso, width: width, height: height)?.paintable
    }

    /// The paint mask's outline in the frame's pixels, traced on a copy scaled down to `outlineLongestSide`.
    static func outlineOfThePaintableArea(_ masks: ShirtPaintMasks) -> [CGPoint]? {
        let scale = min(1, Double(outlineLongestSide) / Double(max(masks.width, masks.height)))
        let smallWidth = max(3, Int((Double(masks.width) * scale).rounded())), smallHeight = max(3, Int((Double(masks.height) * scale).rounded()))
        guard let small = resizedGrayBytes(masks.paintable, width: masks.width, height: masks.height, toWidth: smallWidth, toHeight: smallHeight),
              let outline = ShirtOutline.outline(of: small.map { $0 > 127 }, width: smallWidth, height: smallHeight) else { return nil }
        return ShirtOutline.scaled(outline, fromMaskScale: Double(smallWidth) / Double(masks.width))
    }
}
