//
//  LiveSceneStatusLabelViews.swift
//  leanring-buddy
//
//  Draws one status line: an animated icon on a white tile, then the line's
//  letters in its own style. Every view here takes the seconds since the line
//  appeared, so a TimelineView above it drives the loop and nothing animates
//  once the label leaves the screen.
//

import AppKit
import SwiftUI

struct LiveSceneStatusLabelContent: View {
    let statusLine: LiveSceneStatusLine
    let elapsedSeconds: Double
    /// Near a screen's right edge the letters come first, so the icon stays on the triangle's spot.
    let textSide: StatusLabelTextSide

    var body: some View {
        HStack(spacing: 10) {
            if textSide == .leftOfIcon {
                StatusLetters(statusLine: statusLine, elapsedSeconds: elapsedSeconds)
            }
            StatusIconTile(statusLine: statusLine, elapsedSeconds: elapsedSeconds)
            if textSide == .rightOfIcon {
                StatusLetters(statusLine: statusLine, elapsedSeconds: elapsedSeconds)
            }
        }
    }
}

// MARK: - Letters

private struct StatusLetters: View {
    let statusLine: LiveSceneStatusLine
    let elapsedSeconds: Double

    var body: some View {
        let characters = Array(statusLine.displayedText)
        HStack(spacing: statusLine == .readingYourScreen ? 0.8 : 0) {
            ForEach(characters.indices, id: \.self) { letterIndex in
                StatusLetter(
                    character: String(characters[letterIndex]),
                    statusLine: statusLine,
                    pose: statusLine.letterPose(letterIndex: letterIndex, letterCount: characters.count, elapsedSeconds: elapsedSeconds)
                )
            }
        }
        .scaleEffect(statusLine.wordScale(elapsedSeconds: elapsedSeconds), anchor: .leading)
    }
}

private struct StatusLetter: View {
    let character: String
    let statusLine: LiveSceneStatusLine
    let pose: StatusLetterPose

    /// A white outline lets colored letters read on light and dark pages without a pill behind them.
    private var outlineOffsets: [CGSize] {
        let outlineWidth: CGFloat = statusLine == .poppingItOut ? 2 : 1.5
        let diagonal = outlineWidth * 0.75
        return [
            CGSize(width: outlineWidth, height: 0), CGSize(width: -outlineWidth, height: 0),
            CGSize(width: 0, height: outlineWidth), CGSize(width: 0, height: -outlineWidth),
            CGSize(width: diagonal, height: diagonal), CGSize(width: -diagonal, height: diagonal),
            CGSize(width: diagonal, height: -diagonal), CGSize(width: -diagonal, height: -diagonal),
        ]
    }

    private var letterFont: Font {
        switch statusLine {
        case .poppingItOut, .buildingYourScene: return .system(size: 19, weight: .black, design: .rounded)
        case .animatingIt: return .system(size: 19, weight: .heavy, design: .rounded).italic()
        case .readingYourScreen: return .system(size: 16, weight: .heavy, design: .monospaced)
        case .almostThere: return .system(size: 19, weight: .black).italic()
        case .readingTheTranscript: return .system(size: 18, weight: .bold, design: .serif)
        case .pickingQuizSpots: return .system(size: 17, weight: .bold)
        }
    }

    var body: some View {
        let palette = statusLine.palette
        let glyph = Text(character).font(letterFont)
        ZStack {
            // A darker copy under the outline gives the letters depth: a deep 3D extrude for the
            // scene being built, a soft drop for the pop-out.
            if statusLine == .buildingYourScene {
                glyph.foregroundColor(.black.opacity(0.25)).offset(x: 4, y: 4)
                glyph.foregroundColor(palette.textColor).offset(x: 3, y: 3)
                glyph.foregroundColor(palette.textColor).offset(x: 2, y: 2)
            } else if statusLine == .poppingItOut {
                glyph.foregroundColor(DS.Colors.blue900.opacity(0.3)).offset(y: 4)
            }
            ForEach(outlineOffsets.indices, id: \.self) { outlineIndex in
                glyph.foregroundColor(.white).offset(outlineOffsets[outlineIndex])
            }
            glyph.foregroundColor(palette.textColor)
            // macOS 14 has no Color.mix, so the highlight is a second copy faded in on top.
            if pose.highlightAmount > 0 {
                glyph.foregroundColor(palette.highlightColor).opacity(pose.highlightAmount)
            }
        }
        .overlay(alignment: .trailing) {
            if pose.showsCaret {
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.textColor)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.white, lineWidth: 1))
                    .offset(x: 2.5)
            }
        }
        .overlay(alignment: .bottom) {
            if pose.spotDotScale > 0 {
                Circle()
                    .fill(palette.iconColor)
                    .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                    .frame(width: 5, height: 5)
                    .scaleEffect(pose.spotDotScale)
                    .offset(y: 7)
            }
        }
        .scaleEffect(x: pose.scale, y: pose.scale * pose.extraVerticalScale)
        .rotationEffect(.degrees(pose.rotationDegrees))
        .offset(y: pose.offsetY)
        .opacity(pose.opacity)
    }
}

// MARK: - Icon tile

/// The line's icon, drawn on a 26-point grid inside a white 32-point tile.
private struct StatusIconTile: View {
    let statusLine: LiveSceneStatusLine
    let elapsedSeconds: Double

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 26, y: size.height / 26)
            let palette = statusLine.palette
            switch statusLine {
            case .poppingItOut: StatusIconDrawing.drawPopOutCube(in: &context, elapsedSeconds: elapsedSeconds)
            case .animatingIt: StatusIconDrawing.drawFlowingStreams(in: &context, palette: palette, elapsedSeconds: elapsedSeconds)
            case .readingYourScreen: StatusIconDrawing.drawScanningScreen(in: &context, palette: palette, elapsedSeconds: elapsedSeconds)
            case .buildingYourScene: StatusIconDrawing.drawAssemblingCube(in: &context, palette: palette, elapsedSeconds: elapsedSeconds)
            case .almostThere: StatusIconDrawing.drawFillingRing(in: &context, palette: palette, elapsedSeconds: elapsedSeconds)
            case .readingTheTranscript: StatusIconDrawing.drawHighlightedPage(in: &context, palette: palette, elapsedSeconds: elapsedSeconds)
            case .pickingQuizSpots: StatusIconDrawing.drawMagnifierSweep(in: &context, palette: palette, elapsedSeconds: elapsedSeconds)
            }
        }
        .frame(width: 26, height: 26)
        .frame(width: 32, height: 32)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        )
    }
}

private enum StatusIconDrawing {

    // MARK: Popping it out: a flat picture that extrudes into a cube, turns once, and flattens

    private struct CubeFace {
        /// Corners as seen from outside the face: top left, top right, bottom right, bottom left.
        let corners: [CubePoint]
        let color: Color
        let isFront: Bool
    }

    /// A point in the cube's space. The unit cube's corners sit at -1 or 1 on each axis.
    private struct CubePoint {
        let horizontalPosition: Double
        /// Grows downward, like the screen.
        let verticalPosition: Double
        let depthTowardViewer: Double
    }

    private struct PlacedCubeFace {
        let face: CubeFace
        let placedCorners: [CubePoint]
        var averageDepth: Double {
            placedCorners.map(\.depthTowardViewer).reduce(0, +) / Double(placedCorners.count)
        }
    }

    private static let popOutCubeFaces: [CubeFace] = [
        CubeFace(
            corners: [
                CubePoint(horizontalPosition: -1, verticalPosition: -1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: 1, verticalPosition: -1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: 1, verticalPosition: 1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: -1, verticalPosition: 1, depthTowardViewer: 1),
            ],
            color: DS.Colors.blue600, isFront: true
        ),
        CubeFace(
            corners: [
                CubePoint(horizontalPosition: 1, verticalPosition: -1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: -1, verticalPosition: -1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: -1, verticalPosition: 1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: 1, verticalPosition: 1, depthTowardViewer: -1),
            ],
            color: DS.Colors.blue700, isFront: false
        ),
        CubeFace(
            corners: [
                CubePoint(horizontalPosition: 1, verticalPosition: -1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: 1, verticalPosition: -1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: 1, verticalPosition: 1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: 1, verticalPosition: 1, depthTowardViewer: 1),
            ],
            color: DS.Colors.blue800, isFront: false
        ),
        CubeFace(
            corners: [
                CubePoint(horizontalPosition: -1, verticalPosition: -1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: -1, verticalPosition: -1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: -1, verticalPosition: 1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: -1, verticalPosition: 1, depthTowardViewer: -1),
            ],
            color: DS.Colors.blue400, isFront: false
        ),
        CubeFace(
            corners: [
                CubePoint(horizontalPosition: -1, verticalPosition: -1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: 1, verticalPosition: -1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: 1, verticalPosition: -1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: -1, verticalPosition: -1, depthTowardViewer: 1),
            ],
            color: DS.Colors.blue200, isFront: false
        ),
        CubeFace(
            corners: [
                CubePoint(horizontalPosition: -1, verticalPosition: 1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: 1, verticalPosition: 1, depthTowardViewer: 1),
                CubePoint(horizontalPosition: 1, verticalPosition: 1, depthTowardViewer: -1),
                CubePoint(horizontalPosition: -1, verticalPosition: 1, depthTowardViewer: -1),
            ],
            color: DS.Colors.blue900, isFront: false
        ),
    ]

    static func drawPopOutCube(in context: inout GraphicsContext, elapsedSeconds: Double) {
        let cubePose = PopOutCubePose.at(elapsedSeconds: elapsedSeconds)
        let halfEdge = 8.0
        let perspectiveDistance = 110.0
        let turnRadians = cubePose.turnDegrees * .pi / 180
        let tiltRadians = cubePose.tiltDegrees * .pi / 180

        // The shadow under the cube grows as it lifts off the tile.
        let shadowWidth = 16 * (0.6 + 0.4 * cubePose.depth)
        context.fill(
            Path(ellipseIn: CGRect(x: 13 - shadowWidth / 2, y: 23, width: shadowWidth, height: 3)),
            with: .color(DS.Colors.blue900.opacity(0.3 * cubePose.depth))
        )

        // Scale, turn about the vertical axis, tilt about the horizontal one, then lift.
        func placedPoint(_ cubePoint: CubePoint) -> CubePoint {
            let scaledX: Double = cubePoint.horizontalPosition * cubePose.scale
            let scaledY: Double = cubePoint.verticalPosition * cubePose.scale
            let scaledZ: Double = cubePoint.depthTowardViewer * cubePose.scale
            let turnedX: Double = scaledX * cos(turnRadians) + scaledZ * sin(turnRadians)
            let turnedZ: Double = scaledZ * cos(turnRadians) - scaledX * sin(turnRadians)
            let tiltedY: Double = scaledY * cos(tiltRadians) - turnedZ * sin(tiltRadians)
            let tiltedZ: Double = scaledY * sin(tiltRadians) + turnedZ * cos(tiltRadians)
            return CubePoint(horizontalPosition: turnedX, verticalPosition: tiltedY - cubePose.liftPoints, depthTowardViewer: tiltedZ)
        }
        func projected(_ point: CubePoint) -> CGPoint {
            let perspectiveFactor: Double = perspectiveDistance / (perspectiveDistance - point.depthTowardViewer)
            return CGPoint(
                x: 13 + point.horizontalPosition * perspectiveFactor,
                y: 13 + point.verticalPosition * perspectiveFactor
            )
        }
        // A face is visible when its corners still wind clockwise on screen. Edge-on faces have no area.
        func faceIsVisible(_ placedCorners: [CubePoint]) -> Bool {
            let screenCorners: [CGPoint] = placedCorners.map(projected)
            var twiceSignedArea: Double = 0
            for cornerIndex in screenCorners.indices {
                let corner = screenCorners[cornerIndex]
                let nextCorner = screenCorners[(cornerIndex + 1) % screenCorners.count]
                twiceSignedArea += corner.x * nextCorner.y - nextCorner.x * corner.y
            }
            return twiceSignedArea > 0.01
        }

        var facesToDraw: [PlacedCubeFace] = []
        for face in popOutCubeFaces {
            let placedCorners: [CubePoint] = face.corners.map { corner in
                placedPoint(CubePoint(
                    horizontalPosition: corner.horizontalPosition * halfEdge,
                    verticalPosition: corner.verticalPosition * halfEdge,
                    depthTowardViewer: corner.depthTowardViewer * halfEdge * cubePose.depth
                ))
            }
            if faceIsVisible(placedCorners) {
                facesToDraw.append(PlacedCubeFace(face: face, placedCorners: placedCorners))
            }
        }
        // Farther faces first, so nearer ones paint over them.
        facesToDraw.sort { fartherFace, nearerFace in fartherFace.averageDepth < nearerFace.averageDepth }

        for faceToDraw in facesToDraw {
            var facePath = Path()
            facePath.addLines(faceToDraw.placedCorners.map(projected))
            facePath.closeSubpath()
            context.fill(facePath, with: .color(faceToDraw.face.color))

            if faceToDraw.face.isFront {
                // The picture on the front face: a small white mountain range.
                let topLeft = faceToDraw.placedCorners[0]
                let topRight = faceToDraw.placedCorners[1]
                let bottomLeft = faceToDraw.placedCorners[3]
                func pointOnFrontFace(across: Double, down: Double) -> CGPoint {
                    let horizontalPosition: Double = topLeft.horizontalPosition
                        + across * (topRight.horizontalPosition - topLeft.horizontalPosition)
                        + down * (bottomLeft.horizontalPosition - topLeft.horizontalPosition)
                    let verticalPosition: Double = topLeft.verticalPosition
                        + across * (topRight.verticalPosition - topLeft.verticalPosition)
                        + down * (bottomLeft.verticalPosition - topLeft.verticalPosition)
                    let depthTowardViewer: Double = topLeft.depthTowardViewer
                        + across * (topRight.depthTowardViewer - topLeft.depthTowardViewer)
                        + down * (bottomLeft.depthTowardViewer - topLeft.depthTowardViewer)
                    return projected(CubePoint(
                        horizontalPosition: horizontalPosition,
                        verticalPosition: verticalPosition,
                        depthTowardViewer: depthTowardViewer
                    ))
                }
                let mountainPeaks: [(across: Double, down: Double)] = [(0, 1), (0.3, 0.3), (0.5, 0.62), (0.72, 0.18), (1, 1)]
                var mountainPath = Path()
                mountainPath.addLines(mountainPeaks.map { mountainPeak in
                    pointOnFrontFace(
                        across: 3.0 / 16 + mountainPeak.across * 10.0 / 16,
                        down: 5.0 / 16 + mountainPeak.down * 8.0 / 16
                    )
                })
                mountainPath.closeSubpath()
                context.fill(mountainPath, with: .color(.white))
            }
        }
    }

    // MARK: Reading your screen: a scan line sweeping a little screen

    static func drawScanningScreen(in context: inout GraphicsContext, palette: StatusLabelPalette, elapsedSeconds: Double) {
        let screenFrame = Path(roundedRect: CGRect(x: 3.5, y: 4.5, width: 19, height: 14), cornerRadius: 2.5)
        context.fill(screenFrame, with: .color(palette.washColor))
        context.stroke(screenFrame, with: .color(palette.textColor), lineWidth: 1.6)
        var standPath = Path()
        standPath.move(to: CGPoint(x: 10, y: 22)); standPath.addLine(to: CGPoint(x: 16, y: 22))
        standPath.move(to: CGPoint(x: 13, y: 18.5)); standPath.addLine(to: CGPoint(x: 13, y: 22))
        context.stroke(standPath, with: .color(palette.textColor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))

        // Down and back up, easing at each end.
        let halfTripsDone = (elapsedSeconds / 1.4).truncatingRemainder(dividingBy: 2)
        let sweepProgress = StatusLabelMotion.easeInOut(halfTripsDone < 1 ? halfTripsDone : 2 - halfTripsDone)
        var screenContext = context
        screenContext.clip(to: Path(roundedRect: CGRect(x: 4.5, y: 5.5, width: 17, height: 12), cornerRadius: 1.5))
        screenContext.fill(Path(CGRect(x: 4.5, y: 6 + 10 * sweepProgress, width: 17, height: 2)), with: .color(palette.iconColor))
    }

    // MARK: Building your 3D scene: three faces fly in and lock into a cube

    static func drawAssemblingCube(in context: inout GraphicsContext, palette: StatusLabelPalette, elapsedSeconds: Double) {
        let faces: [(corners: [CGPoint], color: Color, flyInFrom: CGSize, delaySeconds: Double)] = [
            ([CGPoint(x: 13, y: 3.5), CGPoint(x: 21.5, y: 8.2), CGPoint(x: 13, y: 12.9), CGPoint(x: 4.5, y: 8.2)], palette.paleColor, CGSize(width: 0, height: -6), 0),
            ([CGPoint(x: 4.5, y: 8.2), CGPoint(x: 13, y: 12.9), CGPoint(x: 13, y: 22.5), CGPoint(x: 4.5, y: 17.8)], palette.iconColor, CGSize(width: -6, height: 3), 0.3),
            ([CGPoint(x: 13, y: 12.9), CGPoint(x: 21.5, y: 8.2), CGPoint(x: 21.5, y: 17.8), CGPoint(x: 13, y: 22.5)], palette.textColor, CGSize(width: 6, height: 3), 0.6),
        ]
        for face in faces {
            guard let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: 2.6, delaySeconds: face.delaySeconds) else { continue }
            let arrivedAmount = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.15, 1), (1, 1)], easing: StatusLabelMotion.easeOutBack)
            let opacity = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.15, 1), (0.75, 1), (0.90, 0), (1, 0)], easing: StatusLabelMotion.easeOut)
            var facePath = Path()
            facePath.addLines(face.corners.map { corner in
                CGPoint(x: corner.x + face.flyInFrom.width * (1 - arrivedAmount), y: corner.y + face.flyInFrom.height * (1 - arrivedAmount))
            })
            facePath.closeSubpath()
            context.fill(facePath, with: .color(face.color.opacity(opacity)))
        }
    }

    // MARK: Animating it: particles stream along three curved paths, like the flows on the pop-out

    static func drawFlowingStreams(in context: inout GraphicsContext, palette: StatusLabelPalette, elapsedSeconds: Double) {
        for (streamIndex, streamY) in [7.0, 13, 19].enumerated() {
            // Each stream bends the other way from its neighbor, so the three read as flowing, not as lines of text.
            let bend = streamIndex.isMultiple(of: 2) ? -3.0 : 3.0
            let streamStart = CGPoint(x: 3, y: streamY), streamControl = CGPoint(x: 13, y: streamY + bend), streamEnd = CGPoint(x: 23, y: streamY)
            var streamPath = Path()
            streamPath.move(to: streamStart)
            streamPath.addQuadCurve(to: streamEnd, control: streamControl)
            context.stroke(streamPath, with: .color(palette.paleColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))

            for particleIndex in 0..<2 {
                let travelFraction = (elapsedSeconds / 1.2 + Double(particleIndex) * 0.5 + Double(streamIndex) * 0.21).truncatingRemainder(dividingBy: 1)
                // A point on the quadratic curve, so the particle follows the bend.
                let oneMinus = 1 - travelFraction
                let particleX = oneMinus * oneMinus * streamStart.x + 2 * oneMinus * travelFraction * streamControl.x + travelFraction * travelFraction * streamEnd.x
                let particleY = oneMinus * oneMinus * streamStart.y + 2 * oneMinus * travelFraction * streamControl.y + travelFraction * travelFraction * streamEnd.y
                // Particles fade in at the start of a stream and out at its end.
                let edgeFade = min(1, travelFraction / 0.15, oneMinus / 0.15)
                var particleContext = context
                particleContext.opacity = edgeFade
                particleContext.fill(Path(ellipseIn: CGRect(x: particleX - 2.2, y: particleY - 2.2, width: 4.4, height: 4.4)), with: .color(palette.iconColor))
            }
        }
    }

    // MARK: Almost there: a progress ring nearly closes and a star pops in the middle

    static func drawFillingRing(in context: inout GraphicsContext, palette: StatusLabelPalette, elapsedSeconds: Double) {
        let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: 1.8) ?? 0
        let ringCenter = CGPoint(x: 13, y: 13)
        context.stroke(Path(ellipseIn: CGRect(x: 4, y: 4, width: 18, height: 18)), with: .color(palette.paleColor), lineWidth: 3.2)
        let filledFraction = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0.65), (0.70, 0.95), (1, 0.95)], easing: StatusLabelMotion.easeOut)
        var arcPath = Path()
        arcPath.addArc(center: ringCenter, radius: 9, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * filledFraction), clockwise: false)
        context.stroke(arcPath, with: .color(palette.iconColor), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))

        let starScale = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.55, 0), (0.75, 1.15), (1, 1)], easing: StatusLabelMotion.easeOutBack)
        let starTurnDegrees = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.55, 0), (0.75, 45), (1, 90)], easing: StatusLabelMotion.easeOutBack)
        guard starScale > 0 else { return }
        var starContext = context
        starContext.translateBy(x: ringCenter.x, y: ringCenter.y)
        starContext.rotate(by: .degrees(starTurnDegrees))
        starContext.scaleBy(x: starScale, y: starScale)
        starContext.fill(fourPointStar(radius: 4, innerPull: 0.4), with: .color(palette.textColor))
    }

    /// A four-point sparkle centered on the origin, with curved sides pulled toward the middle.
    private static func fourPointStar(radius: Double, innerPull: Double) -> Path {
        var starPath = Path()
        let tips = [CGPoint(x: 0, y: -radius), CGPoint(x: radius, y: 0), CGPoint(x: 0, y: radius), CGPoint(x: -radius, y: 0)]
        starPath.move(to: tips[0])
        for (tip, nextTip) in zip(tips, tips.dropFirst() + [tips[0]]) {
            let pulledControl = CGPoint(x: (tip.x + nextTip.x) * innerPull / 2, y: (tip.y + nextTip.y) * innerPull / 2)
            starPath.addQuadCurve(to: nextTip, control: pulledControl)
        }
        starPath.closeSubpath()
        return starPath
    }

    // MARK: Reading the transcript: lines on a page get highlighted one by one

    static func drawHighlightedPage(in context: inout GraphicsContext, palette: StatusLabelPalette, elapsedSeconds: Double) {
        let page = Path(roundedRect: CGRect(x: 5.5, y: 2.5, width: 15, height: 21), cornerRadius: 2.5)
        context.fill(page, with: .color(.white))
        context.stroke(page, with: .color(palette.lightColor), lineWidth: 1.4)
        for (lineIndex, lineTop) in [7.5, 11.5, 15.5, 19.5].enumerated() {
            let isLastLine = lineIndex == 3
            context.fill(
                Path(roundedRect: CGRect(x: 8.5, y: lineTop, width: isLastLine ? 5.5 : 9, height: 1.8), cornerRadius: 0.9),
                with: .color(palette.paleColor)
            )
            guard let loopFraction = StatusLabelMotion.loopFraction(
                elapsedSeconds: elapsedSeconds, loopSeconds: 2.4, delaySeconds: Double(lineIndex) * 0.35
            ) else { continue }
            let drawnFraction = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.14, 1), (1, 1)], easing: StatusLabelMotion.easeOut)
            let opacity = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0.6), (0.70, 0.6), (0.85, 0), (1, 0)], easing: StatusLabelMotion.linear)
            let fullWidth = isLastLine ? 6.5 : 10
            context.fill(
                Path(roundedRect: CGRect(x: 8, y: lineTop - 1.1, width: fullWidth * drawnFraction, height: 4), cornerRadius: 1),
                with: .color(palette.iconColor.opacity(opacity))
            )
        }
    }

    // MARK: Picking spots to quiz you on: a magnifier slides along a timeline and lights up spots

    static func drawMagnifierSweep(in context: inout GraphicsContext, palette: StatusLabelPalette, elapsedSeconds: Double) {
        var timelinePath = Path()
        timelinePath.move(to: CGPoint(x: 3, y: 20)); timelinePath.addLine(to: CGPoint(x: 23, y: 20))
        context.stroke(timelinePath, with: .color(palette.paleColor), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        let loopSeconds = 2.4
        let sweepEndsAt = 0.66
        for spotX in [5.0, 10, 16, 21] {
            // A spot lights up the moment the lens reaches it, then dims before the next sweep.
            let reachedAfterSeconds = loopSeconds * sweepEndsAt * (spotX - 5) / 16
            var spotColor = palette.paleColor
            var spotScale = 1.0
            if let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: loopSeconds, delaySeconds: reachedAfterSeconds) {
                let litAmount = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 1), (0.55, 1), (0.65, 0), (1, 0)], easing: StatusLabelMotion.linear)
                spotScale = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 1.6), (0.10, 1), (1, 1)], easing: StatusLabelMotion.easeOut)
                spotColor = litAmount > 0.5 ? palette.iconColor : palette.paleColor
            }
            let spotRadius = 1.8 * spotScale
            context.fill(Path(ellipseIn: CGRect(x: spotX - spotRadius, y: 20 - spotRadius, width: spotRadius * 2, height: spotRadius * 2)), with: .color(spotColor))
        }

        let loopFraction = StatusLabelMotion.loopFraction(elapsedSeconds: elapsedSeconds, loopSeconds: loopSeconds) ?? 0
        let lensShift = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (sweepEndsAt, 16), (1, 16)], easing: StatusLabelMotion.linear)
        let lensOpacity = StatusLabelMotion.value(at: loopFraction, keyframes: [(0, 0), (0.08, 1), (sweepEndsAt, 1), (0.80, 0), (1, 0)], easing: StatusLabelMotion.linear)
        var lensContext = context
        lensContext.opacity = lensOpacity
        lensContext.translateBy(x: lensShift, y: 0)
        let lensRing = Path(ellipseIn: CGRect(x: 0.6, y: 5.6, width: 8.8, height: 8.8))
        lensContext.fill(lensRing, with: .color(palette.washColor.opacity(0.75)))
        lensContext.stroke(lensRing, with: .color(palette.textColor), lineWidth: 2)
        var handlePath = Path()
        handlePath.move(to: CGPoint(x: 8.2, y: 13.2)); handlePath.addLine(to: CGPoint(x: 11, y: 16))
        lensContext.stroke(handlePath, with: .color(palette.textColor), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }
}
