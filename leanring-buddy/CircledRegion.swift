//
//  CircledRegion.swift
//  leanring-buddy
//
//  Circle to select: while push-to-talk is held, the mouse's path is recorded, and a path that closes a loop around a
//  real area on release names "the picture" for that request. The Theme Studio reads it instead of the largest image or
//  video in Chrome's front tab, so a design can start from anything on screen, such as an inline SVG logo, text, a canvas,
//  or another app. The detection is pure, so tests drive it with made-up paths.
//

import AppKit
import CoreGraphics
import Foundation

/// A closed loop the learner drew with the mouse while holding push-to-talk. The points are in global points with the
/// origin at the top left of the main display, the space Chrome reports rects in and ScreenCaptureKit captures in.
struct CircledRegion: Equatable {
    /// The learner's loop, smoothed and cut to at most `ShirtOutline.mostPoints` points, in the order it was drawn.
    let outline: [CGPoint]

    /// The rectangle around the loop, which is what gets captured as the picture.
    var boundingRect: ScreenRectInChromeCoordinates {
        let outlineXValues = outline.map(\.x), outlineYValues = outline.map(\.y)
        let minX = outlineXValues.min() ?? 0, minY = outlineYValues.min() ?? 0
        return ScreenRectInChromeCoordinates(
            rectX: Double(minX),
            rectY: Double(minY),
            rectWidth: Double((outlineXValues.max() ?? 0) - minX),
            rectHeight: Double((outlineYValues.max() ?? 0) - minY)
        )
    }

    /// The fewest mouse samples a loop is drawn from, so a flick is never one.
    static let fewestSamples = 8
    /// A loop narrower or shorter than this frames nothing worth reading. A loop around one line of text is about 30 tall.
    static let smallestSideInPoints: CGFloat = 20
    /// The path must come back this close to its start, or this share of its box's diagonal when that is larger, since a
    /// hand drawn loop rarely closes exactly.
    static let closingGapInPoints: CGFloat = 30
    static let closingGapShareOfTheDiagonal: CGFloat = 0.2
    /// The path's heading must have turned this far before it may close: 300 degrees, most of a full turn, which a hand
    /// drawn loop reaches a little before its start, and a line drawn out and back (half a turn) never does.
    static let headingTurnToCloseInRadians = CGFloat.pi * 5 / 3
    /// The loop must enclose this share of its box. A jiggle back and forth, or a line drawn out and back, encloses almost
    /// nothing, while a hand drawn circle encloses about 0.78 of its box and a rough one well over 0.5.
    static let smallestShareOfTheBoxEnclosed: CGFloat = 0.3

    /// The loop the path closes, or nil when it does not close one around a real area. The learner often moves to the
    /// picture first and circles it after, and may overshoot the start or wander off before letting go, so the loop may
    /// start anywhere in the path: each sample is tried as the start, and the loop that encloses the most area wins. The path
    /// is in global points with the origin at the top left of the main display.
    static func closedLoop(fromMousePath path: [CGPoint]) -> CircledRegion? {
        guard path.count >= fewestSamples else { return nil }
        var largestLoop: (points: [CGPoint], enclosedArea: CGFloat)?
        for startIndex in 0...(path.count - fewestSamples) {
            guard let loop = loopClosingBack(toTheSampleAt: startIndex, of: path) else { continue }
            if loop.enclosedArea > (largestLoop?.enclosedArea ?? 0) { largestLoop = loop }
        }
        guard let largestLoop else { return nil }
        return CircledRegion(outline: ShirtOutline.smoothed(ShirtOutline.simplified(largestLoop.points), passes: 2))
    }

    /// The loop that starts at `startIndex` and comes back to it, or nil. The loop closes at the first sample within the
    /// closing gap of the start once the path's heading has turned most of a full turn, so a wide, short loop around a line
    /// of text never closes on its bottom pass under its start, and an overshoot or a wander after the close is dropped.
    private static func loopClosingBack(toTheSampleAt startIndex: Int, of path: [CGPoint]) -> (points: [CGPoint], enclosedArea: CGFloat)? {
        let start = path[startIndex]
        func distanceFromTheStart(_ index: Int) -> CGFloat { hypot(path[index].x - start.x, path[index].y - start.y) }
        var box = CGRect(origin: start, size: .zero)
        var headingTurnedInRadians: CGFloat = 0
        var previousStep: CGVector?
        var closingIndex: Int?
        var index = startIndex + 1
        while index < path.count, closingIndex == nil {
            box = box.union(CGRect(origin: path[index], size: .zero))
            let step = CGVector(dx: path[index].x - path[index - 1].x, dy: path[index].y - path[index - 1].y)
            if let previousStep {
                // The signed angle from the last step's heading to this one's, so turns one way add and turns back cancel.
                headingTurnedInRadians += atan2(previousStep.dx * step.dy - previousStep.dy * step.dx, previousStep.dx * step.dx + previousStep.dy * step.dy)
            }
            previousStep = step
            if abs(headingTurnedInRadians) >= headingTurnToCloseInRadians,
               distanceFromTheStart(index) <= max(closingGapInPoints, closingGapShareOfTheDiagonal * hypot(box.width, box.height)) {
                closingIndex = index
            }
            index += 1
        }
        guard let closingIndex else { return nil }
        let loopPoints = Array(path[startIndex...closingIndex])
        guard loopPoints.count >= fewestSamples else { return nil }
        let loopXValues = loopPoints.map(\.x), loopYValues = loopPoints.map(\.y)
        guard let minX = loopXValues.min(), let maxX = loopXValues.max(), let minY = loopYValues.min(), let maxY = loopYValues.max() else { return nil }
        let boxWidth = maxX - minX, boxHeight = maxY - minY
        guard boxWidth >= smallestSideInPoints, boxHeight >= smallestSideInPoints else { return nil }
        let area = enclosedArea(of: loopPoints)
        guard area >= smallestShareOfTheBoxEnclosed * boxWidth * boxHeight else { return nil }
        return (loopPoints, area)
    }

    /// The area a closed polygon encloses, by the shoelace formula, whichever way it was drawn. A figure eight's two halves
    /// cancel, so it encloses little, as it should.
    static func enclosedArea(of polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        var twiceTheSignedArea: CGFloat = 0
        for index in polygon.indices {
            let point = polygon[index], next = polygon[(index + 1) % polygon.count]
            twiceTheSignedArea += point.x * next.y - next.x * point.y
        }
        return abs(twiceTheSignedArea) / 2
    }

    /// The learner's loop in an overlay's coordinates: the overlay's screen has its top left at the origin and y grows down.
    func outlineInOverlayCoordinates(overlayScreenFrame: CGRect, mainDisplayHeight: CGFloat) -> [CGPoint] {
        let overlayTopInChromeCoordinates = mainDisplayHeight - overlayScreenFrame.maxY
        return outline.map { CGPoint(x: $0.x - overlayScreenFrame.minX, y: $0.y - overlayTopInChromeCoordinates) }
    }
}

/// The picture a theme design reads: a loop the learner drew while asking names the picture whatever the words say about
/// one, since closing a loop is deliberate, so "make my theme from this logo" reads it too. Without one, the words decide.
func themePictureChoice(requested requestedPictureChoice: ThemeStudioPictureChoice, aRegionWasCircled: Bool) -> ThemeStudioPictureChoice {
    aRegionWasCircled ? .captureAgain : requestedPictureChoice
}

/// Records the mouse's path while push-to-talk is held, 60 times a second, in global points with the origin at the top
/// left of the main display. A timer reads `NSEvent.mouseLocation`, since the push-to-talk event tap does not hear mouse
/// moves, and reading the location also catches a move posted by a rehearsal.
@MainActor
final class MousePathRecorder {
    private var samplingTimer: Timer?
    private(set) var path: [CGPoint] = []
    /// About 4 seconds of moving, so a press held for a long time never grows the path, or the search for a loop in it,
    /// without bound. The oldest samples go first, since the circle usually comes last.
    static let mostSamples = 240

    func start() {
        stopTimer()
        path = []
        sampleTheMouse()
        // The timer runs on the main run loop in the common modes, so it keeps sampling while a menu or a drag tracks the mouse.
        let samplingTimer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleTheMouse() }
        }
        RunLoop.main.add(samplingTimer, forMode: .common)
        self.samplingTimer = samplingTimer
    }

    /// Stops recording and returns the loop the path closed, or nil.
    func stop() -> CircledRegion? {
        guard samplingTimer != nil else { return nil }
        sampleTheMouse()
        stopTimer()
        let circledRegion = CircledRegion.closedLoop(fromMousePath: path)
        path = []
        return circledRegion
    }

    private func stopTimer() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func sampleTheMouse() {
        let mouseLocation = NSEvent.mouseLocation
        let mainDisplayHeight = NSScreen.screens.first?.frame.height ?? 0
        let pointInChromeCoordinates = CGPoint(x: mouseLocation.x, y: mainDisplayHeight - mouseLocation.y)
        // A still mouse adds nothing, so a press held without moving keeps a short path.
        guard path.last != pointInChromeCoordinates else { return }
        path.append(pointInChromeCoordinates)
        if path.count > Self.mostSamples { path.removeFirst() }
    }
}

#if DEBUG
/// A rehearsal "@" step circles a region before it speaks: "@x,y,width,height words", with the rect in global points with
/// the origin at the top left of the main display. Returns the rect and the words, or nil for a step with no usable rect.
func rehearsalCircledRect(_ transcriptAfterThePrefix: String) -> (rect: CGRect, words: String)? {
    guard let spaceIndex = transcriptAfterThePrefix.firstIndex(of: " ") else { return nil }
    let numbers = transcriptAfterThePrefix[..<spaceIndex].split(separator: ",").compactMap { Double($0) }
    guard numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else { return nil }
    let words = String(transcriptAfterThePrefix[transcriptAfterThePrefix.index(after: spaceIndex)...]).trimmingCharacters(in: .whitespaces)
    return (CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]), words)
}

/// The points a rehearsal moves the mouse through to circle `rect`: an ellipse around it, 12 points outside, starting at
/// its top middle and running clockwise, with a small overshoot past the start, as a hand drawn circle has.
func rehearsalCirclePath(around rect: CGRect, pointCount: Int) -> [CGPoint] {
    let radiusX = rect.width / 2 + 12, radiusY = rect.height / 2 + 12
    let overshootShare = 0.06
    return (0...pointCount).map { index in
        let share = Double(index) / Double(pointCount) * (1 + overshootShare)
        // Angle 0 is the top middle, and the angle grows clockwise on a screen whose y grows down.
        let angle = share * 2 * Double.pi
        return CGPoint(x: rect.midX + radiusX * CGFloat(sin(angle)), y: rect.midY - radiusY * CGFloat(cos(angle)))
    }
}
#endif
