//
//  CustomCursorView.swift
//  leanring-buddy
//
//  The cursor a learner designed in the Theme Studio, drawn in place of the blue triangle: SVG shapes in the 24 point box
//  the volleyball uses, or the picture the learner pointed at (long side 32 points). Its motion rules are pure functions
//  of the voice state and the clock, so tests check them without drawing: a thinking motion (spin, pulse, wobble) that
//  runs only while Clicky thinks, a listening pulse that follows the microphone, and streaks behind it while it moves.
//  Reduce Motion turns every motion and the streaks off.
//

import AppKit
import SwiftUI

// MARK: - Facing

/// How the cursor turns while it follows the mouse and flies to a target.
enum CursorFacing: Equatable {
    /// The blue triangle: it keeps its pointer angle while following, and turns toward its target in flight.
    case pointerAngle
    /// The volleyball, and a custom cursor that turns toward movement: it faces the mouse's movement while following.
    case followsMouseMovement
    /// A custom cursor that does not turn, such as a star or a round picture: it stays upright in every state.
    case upright
}

extension CompanionTheme {
    var cursorFacing: CursorFacing {
        switch self {
        case .clickyBlue, .random: return .pointerAngle
        case .school: return .followsMouseMovement
        case .custom(let customTheme): return customTheme.motion.turnsTowardMovement ? .followsMouseMovement : .upright
        }
    }
}

// MARK: - Motion

/// The turn and the size a custom cursor has at one moment, on top of whatever direction it faces.
struct CustomCursorMotionPose: Equatable {
    var rotationDegrees: Double
    var scale: Double

    static let still = CustomCursorMotionPose(rotationDegrees: 0, scale: 1)
}

enum CustomCursorMotionRules {
    static let secondsPerSpinTurn = 1.2
    static let secondsPerPulse = 0.9
    static let largestPulseScale = 1.12
    static let secondsPerWobble = 0.8
    static let wobbleDegrees = 12.0
    /// The listening pulse reaches this scale at the loudest voice.
    static let largestListeningScale = 1.2

    /// Whether the cursor needs a clock to animate at all. Only a thinking motion runs on time. The listening pulse follows
    /// the microphone level, which redraws the view by itself, so a cursor that only pulses while listening runs no clock.
    static func motionNeedsAClock(motion: CustomCursorMotion, voiceState: CompanionVoiceState, reduceMotionIsOn: Bool) -> Bool {
        !reduceMotionIsOn && voiceState == .processing && motion.whileThinking != .none
    }

    static func pose(
        motion: CustomCursorMotion,
        voiceState: CompanionVoiceState,
        seconds: Double,
        audioPowerLevel: CGFloat,
        reduceMotionIsOn: Bool
    ) -> CustomCursorMotionPose {
        guard !reduceMotionIsOn else { return .still }
        switch voiceState {
        case .processing:
            switch motion.whileThinking {
            case .none:
                return .still
            case .spin:
                let turnShare = seconds.truncatingRemainder(dividingBy: secondsPerSpinTurn) / secondsPerSpinTurn
                return CustomCursorMotionPose(rotationDegrees: 360 * turnShare, scale: 1)
            case .pulse:
                // 0 at the start of each pulse, 1 halfway, and back to 0, so the scale goes 1 to 1.12 and back.
                let pulseShare = 0.5 - 0.5 * cos(2 * .pi * seconds / secondsPerPulse)
                return CustomCursorMotionPose(rotationDegrees: 0, scale: 1 + (largestPulseScale - 1) * pulseShare)
            case .wobble:
                return CustomCursorMotionPose(rotationDegrees: wobbleDegrees * sin(2 * .pi * seconds / secondsPerWobble), scale: 1)
            }
        case .listening:
            guard motion.whileListening == .pulse else { return .still }
            let loudness = Double(CursorRingGeometry.easedAudioPowerLevel(audioPowerLevel))
            return CustomCursorMotionPose(rotationDegrees: 0, scale: 1 + (largestListeningScale - 1) * loudness)
        case .idle, .responding:
            return .still
        }
    }

    /// A picture cursor's long side. A whole wide photo at the 24 point box's size is too small to recognize.
    static let pictureLongSideInPoints: CGFloat = 32
    /// The shortest a picture cursor's short side gets, so a banner shaped picture is still a shape the eye can follow.
    static let pictureShortSideMinimumInPoints: CGFloat = 12
    static let pictureCornerRadiusInPoints: CGFloat = 4
    static let pictureOutlineWidthInPoints: CGFloat = 1.5

    /// The size a picture cursor draws at: a round crop is a square, and a whole picture keeps its shape with the long side
    /// at 32 points. A picture more than 32 by 12 in shape, such as a 1280 by 40 banner, gets a short side of 12 points,
    /// and the view crops its center to fit, since it fills the box.
    static func pictureSize(fit: CursorPictureFit, imageSize: CGSize) -> CGSize {
        switch fit {
        case .circle:
            return CGSize(width: pictureLongSideInPoints, height: pictureLongSideInPoints)
        case .whole:
            guard imageSize.width > 0, imageSize.height > 0 else {
                return CGSize(width: pictureLongSideInPoints, height: pictureLongSideInPoints)
            }
            let scale = pictureLongSideInPoints / max(imageSize.width, imageSize.height)
            // The long side is 32, above the minimum, so only the short side can be raised.
            return CGSize(
                width: max(imageSize.width * scale, pictureShortSideMinimumInPoints),
                height: max(imageSize.height * scale, pictureShortSideMinimumInPoints)
            )
        }
    }
}

// MARK: - View

/// The custom cursor, centered in a frame of its own size: 24 points square for shapes, the picture's size for a picture.
struct CustomCursorView: View {
    let customTheme: CustomTheme
    /// The picture a picture cursor draws: the saved picture.jpg, or the studio's picture while the idea is only previewed.
    let picture: NSImage?
    /// 0 hides the streaks and 1 shows them fully, the same value the volleyball's streaks take.
    let streakOpacity: Double
    /// How far the streaks alone are turned, so they trail behind the movement of a cursor that stays upright. The overlay
    /// turns the whole cursor for one that faces its movement, and passes 0 here then, since its streaks turn with it.
    var streakFacingDegrees: Double = 0
    let voiceState: CompanionVoiceState
    let audioPowerLevel: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let streakLineWidth: CGFloat = 2.0

    var body: some View {
        let motionNeedsAClock = CustomCursorMotionRules.motionNeedsAClock(
            motion: customTheme.motion,
            voiceState: voiceState,
            reduceMotionIsOn: reduceMotion
        )
        TimelineView(.animation(minimumInterval: 1.0 / 36.0, paused: !motionNeedsAClock)) { timelineContext in
            let pose = CustomCursorMotionRules.pose(
                motion: customTheme.motion,
                voiceState: voiceState,
                seconds: timelineContext.date.timeIntervalSinceReferenceDate,
                audioPowerLevel: audioPowerLevel,
                reduceMotionIsOn: reduceMotion
            )
            ZStack {
                streaks
                drawing
                    .scaleEffect(pose.scale)
                    .rotationEffect(.degrees(pose.rotationDegrees))
            }
            .frame(width: drawingSize.width, height: drawingSize.height)
        }
    }

    @ViewBuilder private var streaks: some View {
        if customTheme.motion.trailStreaks > 0, !reduceMotion {
            CursorFlightStreaks(lineCount: customTheme.motion.trailStreaks)
                .stroke(Color(hex: customTheme.accentHex), style: StrokeStyle(lineWidth: streakLineWidth, lineCap: .round))
                .frame(width: CursorDrawingBox.sideLength, height: CursorDrawingBox.sideLength)
                // The streaks start below the 24 point box, so a taller picture pushes them down with its bottom edge.
                .offset(y: (drawingSize.height - CursorDrawingBox.sideLength) / 2)
                // Turned after the offset, so a picture's lower edge stays the streaks' starting point as they turn.
                .rotationEffect(.degrees(streakFacingDegrees))
                .opacity(min(max(streakOpacity, 0), 1))
        }
    }

    private var drawingSize: CGSize {
        Self.drawingSize(of: customTheme, picture: picture)
    }

    /// The size the cursor draws at before any motion: the 24 point box for shapes, the picture's size for a picture. The
    /// settings dial reads it to scale the cursor into a token or a fan slot.
    static func drawingSize(of customTheme: CustomTheme, picture: NSImage?) -> CGSize {
        switch customTheme.cursor {
        case .shapes:
            return CGSize(width: CursorDrawingBox.sideLength, height: CursorDrawingBox.sideLength)
        case .picture(let pictureStyle):
            return CustomCursorMotionRules.pictureSize(fit: pictureStyle.fit, imageSize: picture?.size ?? .zero)
        }
    }

    @ViewBuilder private var drawing: some View {
        switch customTheme.cursor {
        case .shapes(let shapes):
            ZStack {
                ForEach(shapes.indices, id: \.self) { shapeIndex in
                    CustomCursorShapeView(shape: shapes[shapeIndex])
                }
            }
            .frame(width: CursorDrawingBox.sideLength, height: CursorDrawingBox.sideLength)
        case .picture(let pictureStyle):
            if let picture {
                CustomCursorPictureView(picture: picture, pictureStyle: pictureStyle, size: drawingSize)
            } else {
                // The picture file could not be read, so the cursor is the accent triangle instead of nothing.
                Triangle()
                    .fill(Color(hex: customTheme.accentHex))
                    .frame(width: 16, height: 16)
            }
        }
    }
}

private struct CustomCursorShapeView: View {
    let shape: CustomCursorShape

    var body: some View {
        ZStack {
            if let fillHex = shape.fillHex {
                SVGPathShape(pathData: shape.path)
                    .fill(Color(hex: fillHex))
            }
            if let strokeHex = shape.strokeHex, shape.strokeWidth > 0 {
                SVGPathShape(pathData: shape.path)
                    .stroke(Color(hex: strokeHex), style: StrokeStyle(lineWidth: shape.strokeWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

/// The learner's picture as a cursor: the whole image with 4 point corners, or a round crop of its center, with a 1.5 point
/// outline and the tint mixed over it. An image shaped more than 32 by 12 is cropped to its center to fit that shape.
private struct CustomCursorPictureView: View {
    let picture: NSImage
    let pictureStyle: CustomCursorPictureStyle
    let size: CGSize

    var body: some View {
        switch pictureStyle.fit {
        case .whole:
            pictureLayers(clippedTo: RoundedRectangle(cornerRadius: CustomCursorMotionRules.pictureCornerRadiusInPoints, style: .continuous))
        case .circle:
            pictureLayers(clippedTo: Circle())
        }
    }

    private func pictureLayers<ClipShape: InsettableShape>(clippedTo clipShape: ClipShape) -> some View {
        ZStack {
            Image(nsImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
            if let tintHex = pictureStyle.tintHex {
                Color(hex: tintHex).opacity(pictureStyle.tintStrength)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(clipShape)
        .overlay(clipShape.strokeBorder(Color(hex: pictureStyle.outlineHex), lineWidth: CustomCursorMotionRules.pictureOutlineWidthInPoints))
    }
}
