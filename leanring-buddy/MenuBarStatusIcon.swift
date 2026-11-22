//
//  MenuBarStatusIcon.swift
//  leanring-buddy
//
//  Clicky's icon in the menu bar. It is 26 points wide in every state, so the neighbors never move, and it mirrors what
//  Clicky is doing: the cursor shape at rest, the cursor with sound waves while the learner talks, and a small cursor with a
//  dot orbiting it while Clicky thinks. An amber badge sits on top of any state while an approval waits for the learner's OK,
//  and a red one while a required permission is off after setup or the Worker cannot be reached, which the panel's banner
//  explains. The icon is a template image, so macOS tints it for a light or dark menu bar. The one exception is the state
//  with a badge, which is not a template, since a template has no color: it is drawn in the menu bar's own foreground color,
//  read from the button's appearance, with the badge in its top right. macOS draws only a status item's image, never a subview
//  of its button (a badge view there never showed), so the badge has to be part of the image. The cursor is the shown theme's: a theme
//  with a drawn cursor draws it as a silhouette, with its open seams cut out, and a theme with a picture cursor falls back to
//  Clicky's triangle, since a photo makes no readable template shape.
//
//  The icon is never the only signal, since macOS can hide a status item behind the notch when the menu bar is full: the
//  cursor ring, the agent discs, and the chips say the same things elsewhere. States and the badge crossfade in 150 ms (one
//  fade, which is also the Reduce Motion form of every move, so the badge fades in and never pops). The orbiting dot is the
//  one loop, ten frames a second, and with Reduce Motion on it holds still at the top.
//
//  This file is the pure state rule and the drawing, plus `MenuBarStatusIconController`, which keeps the status item's button
//  in step with the voice state, the theme, the approval desk, the permissions, and the Worker's reachability.
//

import AppKit
import Combine
import SwiftUI

// MARK: - State

/// What the icon says Clicky is doing.
enum MenuBarIconState: Equatable {
    case idle
    case listening
    case thinking
}

/// The icon state for a voice state. Speaking shows the idle icon: the answer is audible, and the cursor ring hides then too.
func menuBarIconState(for voiceState: CompanionVoiceState) -> MenuBarIconState {
    switch voiceState {
    case .idle, .responding: return .idle
    case .listening: return .listening
    case .processing: return .thinking
    }
}

// MARK: - Badge

/// The dot on the icon's top right, over any state.
enum MenuBarIconBadge: Equatable {
    /// An approval waits for the learner's OK: amber.
    case needsYourOK
    /// A required permission was turned off after setup, or the Worker cannot be reached: red, the panel's problem banner.
    case problem
}

/// The badge for this moment, in the panel banner's order (`panelBanner`): a waiting approval first, since its request times
/// out, then a problem. A permission that is off counts only after setup, since setup itself lists it until then.
func menuBarIconBadge(
    approvalIsWaiting: Bool,
    setupIsFinished: Bool,
    aRequiredPermissionIsOff: Bool,
    workerIsUnreachable: Bool
) -> MenuBarIconBadge? {
    if approvalIsWaiting { return .needsYourOK }
    if (setupIsFinished && aRequiredPermissionIsOff) || workerIsUnreachable { return .problem }
    return nil
}

// MARK: - Drawing

enum MenuBarIconArt {
    /// The icon's size. Its width is the status item's length.
    static let size = CGSize(width: 26, height: 18)
    /// The frames of one turn of the thinking dot.
    static let thinkingFrameCount = 12
    static let secondsPerThinkingFrame: TimeInterval = 0.1

    private static let center = CGPoint(x: size.width / 2, y: size.height / 2)
    /// The cursor's square in each state, in points. Idle fills most of the 18 point height, listening is 85 percent of it
    /// and moves left to make room for the waves, and thinking is smaller so the orbiting dot has room around it.
    private static let idleCursorSide: CGFloat = 14
    private static let listeningCursorSide: CGFloat = 11.9
    private static let listeningCursorShiftLeft: CGFloat = 3
    private static let thinkingCursorSide: CGFloat = 10
    /// The thinking dot's orbit radius and size: the orbit passes just inside the icon's top and bottom edges.
    private static let thinkingDotOrbitRadius: CGFloat = 7.6
    private static let thinkingDotDiameter: CGFloat = 3.4
    /// The cursor's tilt, the same as the blue cursor's resting pose, in the flipped drawing space (y down).
    private static let triangleTiltRadians = -35.0 * Double.pi / 180

    /// The icon for a state as a template image, so only its shape and opacity count and macOS picks the color.
    /// - `thinkingFrame`: which frame of the orbit to draw, from 0, used only by `thinking`.
    /// - `badge`: with a badge, the icon is drawn in `foreground`, the menu bar's own foreground color, with the badge, and is
    ///   not a template. Nil draws the plain template, whose color macOS picks.
    static func image(
        for state: MenuBarIconState,
        thinkingFrame: Int = 0,
        cursor: CustomCursorDrawing,
        badge: MenuBarIconBadge? = nil,
        foreground: NSColor = .black
    ) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let markColor = badge == nil ? NSColor.black : foreground
            context.setFillColor(markColor.cgColor)
            context.setStrokeColor(markColor.cgColor)
            switch state {
            case .idle:
                drawCursor(cursor, center: center, side: idleCursorSide, in: context)
            case .listening:
                let listeningCursorCenter = CGPoint(x: center.x - listeningCursorShiftLeft, y: center.y)
                drawCursor(cursor, center: listeningCursorCenter, side: listeningCursorSide, in: context)
                // The two waves bulge to the right of the shifted cursor. Their circle centers sit where their ends meet the
                // cursor's right side: 3 points right of its center for the inner one, and 3.71 for the outer one, whose radius is larger.
                drawSoundWave(centerX: listeningCursorCenter.x + 3, radius: 5, halfHeight: 4, in: context)
                drawSoundWave(centerX: listeningCursorCenter.x + 3.71, radius: 8, halfHeight: 6, in: context)
            case .thinking:
                drawCursor(cursor, center: center, side: thinkingCursorSide, in: context)
                let angle = 2 * Double.pi * Double(thinkingFrame % thinkingFrameCount) / Double(thinkingFrameCount)
                // The dot starts at the top and turns clockwise, which is increasing angle in this space.
                let dotCenter = CGPoint(x: center.x + thinkingDotOrbitRadius * sin(angle), y: center.y - thinkingDotOrbitRadius * cos(angle))
                context.fillEllipse(in: CGRect(x: dotCenter.x - thinkingDotDiameter / 2, y: dotCenter.y - thinkingDotDiameter / 2, width: thinkingDotDiameter, height: thinkingDotDiameter))
            }
            if let badge { drawBadge(badge, in: context) }
            return true
        }
        image.isTemplate = badge == nil
        return image
    }

    /// Where the badge's center sits, 5.5 points right of the icon's center and 5 up.
    static let badgeCenter = CGPoint(x: size.width / 2 + 5.5, y: size.height / 2 - 5)
    static let badgeDiameter: CGFloat = 7.5

    /// The amber or red dot with a dark rim, so it reads on a light menu bar too.
    private static func drawBadge(_ badge: MenuBarIconBadge, in context: CGContext) {
        let badgeRect = CGRect(x: badgeCenter.x - badgeDiameter / 2, y: badgeCenter.y - badgeDiameter / 2, width: badgeDiameter, height: badgeDiameter)
        context.saveGState()
        context.setBlendMode(.normal)
        context.setFillColor(NSColor.black.cgColor)
        context.fillEllipse(in: badgeRect.insetBy(dx: -1, dy: -1))
        let badgeColor = switch badge {
        case .needsYourOK: DS.Colors.warning
        case .problem: DS.Colors.destructive
        }
        context.setFillColor(NSColor(badgeColor).cgColor)
        context.fillEllipse(in: badgeRect)
        context.restoreGState()
    }

    /// Draws the theme's cursor as a silhouette in a square of `side` points around `center`.
    private static func drawCursor(_ cursor: CustomCursorDrawing, center: CGPoint, side: CGFloat, in context: CGContext) {
        let square = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        switch cursor {
        case .triangle, .picture:
            // A picture cursor makes no readable template shape, so it falls back to the triangle.
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: triangleTiltRadians)
            context.translateBy(x: -center.x, y: -center.y)
            context.addPath(Triangle().path(in: square).cgPath)
            context.fillPath()
            context.restoreGState()
        case .shapes(let shapes):
            let strokeScale = side / CursorDrawingBox.sideLength
            for shape in shapes {
                let shapePath = SVGPathShape(pathData: shape.path).path(in: square).cgPath
                if shape.fillHex != nil {
                    context.addPath(shapePath)
                    context.fillPath()
                } else if shape.strokeHex != nil {
                    // A closed outline or ring keeps its line. An open line, such as a ball's seams, is cut out of the fill
                    // under it, since a template has only opacity to tell a seam from the ball.
                    let isAnOpenLine = !shape.pathText.contains(where: { $0 == "Z" || $0 == "z" })
                    context.saveGState()
                    if isAnOpenLine { context.setBlendMode(.clear) }
                    context.setLineWidth(max(0.6, shape.strokeWidth * strokeScale))
                    context.addPath(shapePath)
                    context.strokePath()
                    context.restoreGState()
                }
            }
        }
    }

    /// An arc bulging to the right, from `halfHeight` above the middle to `halfHeight` below it.
    private static func drawSoundWave(centerX: CGFloat, radius: CGFloat, halfHeight: CGFloat, in context: CGContext) {
        let sweepRadians = asin(halfHeight / radius)
        let steps = 8
        context.saveGState()
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        for step in 0...steps {
            let angle = -sweepRadians + 2 * sweepRadians * Double(step) / Double(steps)
            let point = CGPoint(x: centerX + radius * cos(angle), y: center.y + radius * sin(angle))
            if step == 0 { context.move(to: point) } else { context.addLine(to: point) }
        }
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Controller

/// Keeps the status item's button in step with what Clicky is doing: the icon for the voice state and the shown theme's
/// cursor, the thinking dot's turn, and the badge.
@MainActor
final class MenuBarStatusIconController {
    private let button: NSStatusBarButton
    private let voiceState: () -> CompanionVoiceState
    private let shownCursor: () -> CustomCursorDrawing
    private let badge: () -> MenuBarIconBadge?
    private var subscriptions: Set<AnyCancellable> = []
    private var thinkingTimer: Timer?
    private var thinkingFrame = 0
    /// What the button shows now, so an update that changes nothing draws nothing.
    private var shownIcon: (state: MenuBarIconState, cursor: CustomCursorDrawing, badge: MenuBarIconBadge?, appearanceIsDark: Bool)?
    private var appearanceObservation: NSKeyValueObservation?

    private var reduceMotionIsOn: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// - Parameters:
    ///   - changes: fires when the voice state, the shown theme, or anything the badge reads changes. It may fire before the
    ///     change lands, so the controller reads the values on the next turn of the main run loop.
    init(
        button: NSStatusBarButton,
        changes: AnyPublisher<Void, Never>,
        voiceState: @escaping () -> CompanionVoiceState,
        shownCursor: @escaping () -> CustomCursorDrawing,
        badge: @escaping () -> MenuBarIconBadge?
    ) {
        self.button = button
        self.voiceState = voiceState
        self.shownCursor = shownCursor
        self.badge = badge

        changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
        // The badge's foreground follows the menu bar's appearance, which can change under a shown icon.
        appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.update() }
        }
        update()
    }

    deinit {
        thinkingTimer?.invalidate()
    }

    /// Redraws what changed.
    private func update() {
        let state = menuBarIconState(for: voiceState())
        let cursor = shownCursor()
        let badge = badge()
        // The appearance only matters under the badge, which is drawn in the menu bar's foreground color.
        let appearanceIsDark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let newIcon = (state: state, cursor: cursor, badge: badge, appearanceIsDark: badge != nil && appearanceIsDark)
        guard shownIcon.map({ $0 != newIcon }) ?? true else { return }
        // A change of state or of the badge crossfades, and a new theme cursor swaps at once.
        let isCrossfading = shownIcon.map { $0.state != state || $0.badge != badge } ?? false
        shownIcon = newIcon
        thinkingFrame = 0
        showTheIcon(crossfading: isCrossfading)
        updateTheThinkingTimer(for: state)
    }

    private func showTheIcon(crossfading: Bool) {
        guard let shownIcon else { return }
        if crossfading {
            let crossfade = CATransition()
            crossfade.type = .fade
            crossfade.duration = DS.Move.fadeSeconds
            button.layer?.add(crossfade, forKey: "icon.crossfade")
        }
        button.image = MenuBarIconArt.image(
            for: shownIcon.state,
            thinkingFrame: thinkingFrame,
            cursor: shownIcon.cursor,
            badge: shownIcon.badge,
            foreground: shownIcon.appearanceIsDark ? .white : .black
        )
    }

    /// The dot's turn runs only while Clicky thinks, from a timer of ten frames a second. A timer that only redraws a 26 by
    /// 18 template image costs next to nothing, and Reduce Motion holds the dot at the top by drawing no new frame.
    private func updateTheThinkingTimer(for state: MenuBarIconState) {
        thinkingTimer?.invalidate()
        thinkingTimer = nil
        guard state == .thinking else { return }
        thinkingTimer = Timer.scheduledTimer(withTimeInterval: MenuBarIconArt.secondsPerThinkingFrame, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.reduceMotionIsOn else { return }
                self.thinkingFrame = (self.thinkingFrame + 1) % MenuBarIconArt.thinkingFrameCount
                self.showTheIcon(crossfading: false)
            }
        }
    }
}
