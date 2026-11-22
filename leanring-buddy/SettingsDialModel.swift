//
//  SettingsDialModel.swift
//  leanring-buddy
//
//  The data and rules of the settings dial that holding shift + option opens under the mouse. Everything here is
//  pure: it takes a pointer offset and returns what is highlighted, so tests check each rule without a screen.
//  Offsets are measured from the dial's center with y growing downward, as SwiftUI and the design mock measure them.
//  SettingsDialPanel.swift draws the dial and turns the real mouse into these offsets.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// The dial's sizes in points. The design mock's `dial` and `fan` code is the source of these numbers.
enum SettingsDialGeometry {
    static let plateRadius: CGFloat = 112
    static let tokenRingRadius: CGFloat = 78
    static let tokenDiameter: CGFloat = 44
    static let fanRadius: CGFloat = 152
    /// A Team fan ball, and the one under the pointer. The tests check that the gaps between balls leave room for both.
    static let fanBallDiameter: CGFloat = 21
    static let emphasizedFanBallDiameter: CGFloat = 30
    /// Releasing inside this circle around the cursor glyph cancels, so a hold with no movement changes nothing.
    static let centerDeadZoneRadius: CGFloat = 32
    /// Past this distance nothing is highlighted, so releasing after the pointer wandered off cancels instead of
    /// committing whatever item sits at that angle.
    static let pickingOuterRadius: CGFloat = 230
    /// A dial shifted away from the pointer by a screen edge starts with the pointer off center. Nothing is
    /// highlighted until the pointer has moved this far, so releasing at once never commits by accident.
    static let pointerMovementBeforePickingBegins: CGFloat = 10
}

/// How far the dial's window reaches from the dial's center, wide enough for the plate, both fans with their labels,
/// and the first-run hint. One fixed size keeps the window from resizing as a fan opens.
/// The sides reach past the Team fan's widest built-in label pill, "Clicky blue" at the fan's left end, and the top reaches
/// past the pills above the fan's top balls. A saved theme's name can be longer than any built-in one, so a fan label that
/// would stick out is cut to fit (`SettingsDialLabel.fanLabelText`), and the right side reaches farther than the left, since
/// the saved themes sit at the fan's right end. `SettingsDialTests` checks that every pill fits.
enum SettingsDialPlacement {
    static let reachLeft: CGFloat = 252
    static let reachRight: CGFloat = 300
    static let reachAbove: CGFloat = 200
    static let reachBelow: CGFloat = 160

    static var panelSize: CGSize {
        CGSize(width: reachLeft + reachRight, height: reachAbove + reachBelow)
    }

    /// The window as offsets from the dial's center, with y growing down like every other offset here.
    static var windowOffsetsFromTheDialCenter: CGRect {
        CGRect(x: -reachLeft, y: -reachAbove, width: panelSize.width, height: panelSize.height)
    }

    /// Where the dial's center goes for a mouse at `mouseLocation`, moved inward so the whole window stays inside
    /// `visibleFrame`. Both are in AppKit screen coordinates, where y grows upward. On a screen smaller than the
    /// window the dial centers on the screen.
    static func dialCenter(forMouseLocation mouseLocation: CGPoint, visibleFrame: CGRect) -> CGPoint {
        CGPoint(
            x: clamped(mouseLocation.x, lowest: visibleFrame.minX + reachLeft, highest: visibleFrame.maxX - reachRight),
            y: clamped(mouseLocation.y, lowest: visibleFrame.minY + reachBelow, highest: visibleFrame.maxY - reachAbove)
        )
    }

    private static func clamped(_ value: CGFloat, lowest: CGFloat, highest: CGFloat) -> CGFloat {
        guard lowest <= highest else { return (lowest + highest) / 2 }
        return min(max(value, lowest), highest)
    }
}

// MARK: - Closing

/// How the dial leaves, from the move that closes it (`DS.Move`). The dial's window never leaves its place, so every form is
/// drawn inside it.
enum SettingsDialClosingForm: Equatable {
    /// The chosen item flies into the center while the dial shrinks into the cursor: the Glide close, at 0.7x.
    case flyTheChosenItemIntoTheCursor(seconds: Double)
    /// The dial fades out in place: a cancel, a release over nothing, and every close with Reduce Motion on.
    case fadeOut(seconds: Double)

    /// How the dial of a release that `committedAChoice` or not, closes.
    static func form(committedAChoice: Bool, reduceMotionIsOn: Bool) -> SettingsDialClosingForm {
        if reduceMotionIsOn {
            return .fadeOut(seconds: DS.Move.fadeSeconds)
        }
        if committedAChoice {
            return .flyTheChosenItemIntoTheCursor(seconds: DS.Move.glide.curve.timeScaled(by: DS.Move.glideCloseTimeFactor).seconds())
        }
        return .fadeOut(seconds: cancelFadeSeconds)
    }

    /// A cancel fades the dial in 120 ms.
    static let cancelFadeSeconds = 0.12

    var seconds: Double {
        switch self {
        case .flyTheChosenItemIntoTheCursor(let seconds), .fadeOut(let seconds): return seconds
        }
    }
}

// MARK: - Labels

/// The dial's text labels. Text never sits on the bare page: every label is drawn on its own dark pill that is sized to
/// the text with padding, so the text shows inside its background however long it is.
enum SettingsDialLabel {
    static let fontSize: CGFloat = 11
    static let horizontalPadding: CGFloat = 8
    static let verticalPadding: CGFloat = 3
    /// The space between a token or fan ball and the pill of its label.
    static let gapFromItem: CGFloat = 3
    /// How far inside the dial's window a fan pill stays, since its hairline edge is drawn half outside the pill.
    static let windowEdgeMargin: CGFloat = 2

    /// The pill that holds `text`, measured with the same font the dial draws it in.
    static func pillSize(forText text: String) -> CGSize {
        let measuredText = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
        return CGSize(
            width: ceil(measuredText.width) + 2 * horizontalPadding,
            height: ceil(measuredText.height) + 2 * verticalPadding
        )
    }

    /// How far a token label's pill center sits from the token's center, vertically. The design puts Team's label above
    /// its token and the others below.
    static func tokenLabelCenterOffsetY(for slice: SettingsDialSlice, labelPillHeight: CGFloat) -> CGFloat {
        let distance = SettingsDialGeometry.tokenDiameter / 2 + gapFromItem + labelPillHeight / 2
        return slice == .team ? -distance : distance
    }

    /// Where the pill of the highlighted fan ball goes, as an offset from the dial's center. The pill sits just outside
    /// the ball, in the direction away from the dial's center. Balls sit side by side along the arc, so a pill outside
    /// the arc never covers the next ball the pointer is about to reach.
    static func fanLabelCenterOffset(ballCenterOffset: CGPoint, ballRadius: CGFloat, labelPillSize: CGSize) -> CGPoint {
        let distanceFromDialCenter = hypot(ballCenterOffset.x, ballCenterOffset.y)
        guard distanceFromDialCenter > 0 else { return ballCenterOffset }
        let outwardX = ballCenterOffset.x / distanceFromDialCenter
        let outwardY = ballCenterOffset.y / distanceFromDialCenter
        // How far a rectangle reaches along the outward direction from its own center.
        let pillReachAlongOutward = abs(outwardX) * labelPillSize.width / 2 + abs(outwardY) * labelPillSize.height / 2
        let distanceFromBallCenter = ballRadius + gapFromItem + pillReachAlongOutward
        return CGPoint(
            x: ballCenterOffset.x + outwardX * distanceFromBallCenter,
            y: ballCenterOffset.y + outwardY * distanceFromBallCenter
        )
    }

    /// What a fan ball's pill says for `fullText`: all of it when the pill fits inside the dial's window, else the longest
    /// start of it that fits, with "…" after. The built-in names all fit. A saved theme's name runs to 24 characters, wider
    /// than the window has room for at the fan's right end, where the saved themes sit. The check places the
    /// pill with `fanLabelCenterOffset`, the way the view does, so a text that passes here is drawn inside the window.
    static func fanLabelText(_ fullText: String, ballCenterOffset: CGPoint, ballRadius: CGFloat) -> String {
        let roomForPills = SettingsDialPlacement.windowOffsetsFromTheDialCenter
            .insetBy(dx: windowEdgeMargin, dy: windowEdgeMargin)
        for keptCharacterCount in stride(from: fullText.count, through: 1, by: -1) {
            let candidateText = keptCharacterCount == fullText.count
                ? fullText
                : String(fullText.prefix(keptCharacterCount)).trimmingCharacters(in: .whitespaces) + "…"
            let candidatePillSize = pillSize(forText: candidateText)
            let candidatePillCenter = fanLabelCenterOffset(
                ballCenterOffset: ballCenterOffset,
                ballRadius: ballRadius,
                labelPillSize: candidatePillSize
            )
            let candidatePillRect = CGRect(
                x: candidatePillCenter.x - candidatePillSize.width / 2,
                y: candidatePillCenter.y - candidatePillSize.height / 2,
                width: candidatePillSize.width,
                height: candidatePillSize.height
            )
            if roomForPills.contains(candidatePillRect) { return candidateText }
        }
        return "…"
    }
}

// MARK: - Slices and fans

/// The two choices the Model fan offers.
enum SettingsDialModelChoice: CaseIterable, Equatable {
    case sonnet
    case opus

    var modelID: String {
        switch self {
        case .sonnet: return ClaudeVoiceModel.sonnetModelID
        case .opus: return ClaudeVoiceModel.opusModelID
        }
    }

    var displayName: String {
        switch self {
        case .sonnet: return "Sonnet"
        case .opus: return "Opus"
        }
    }
}

/// Where a fan's items sit on its outer arc, as angles around the dial's center.
struct SettingsDialFanLayout: Equatable {
    let centerAngleDegrees: Double
    let angleBetweenItemsDegrees: Double
    let itemCount: Int

    func angleDegrees(ofItemAt itemIndex: Int) -> Double {
        centerAngleDegrees + (Double(itemIndex) - Double(itemCount - 1) / 2) * angleBetweenItemsDegrees
    }

    /// The item whose angle is closest to `angleDegrees`, or nil when the angle is more than half the gap past
    /// the first or last item, where no item is under the pointer.
    func nearestItemIndex(toAngleDegrees angleDegrees: Double) -> Int? {
        let itemIndexesWithAngleGaps = (0..<itemCount).map { itemIndex in
            (itemIndex, abs(angleDifferenceInDegrees(from: self.angleDegrees(ofItemAt: itemIndex), to: angleDegrees)))
        }
        guard let nearestItem = itemIndexesWithAngleGaps.min(by: { $0.1 < $1.1 }),
              nearestItem.1 <= angleBetweenItemsDegrees / 2 else { return nil }
        return nearestItem.0
    }
}

/// The five tokens on the dial. Each owns an angle, and the pointer picks the slice nearest its own angle.
enum SettingsDialSlice: CaseIterable, Equatable {
    case team
    case model
    case agents
    case show
    case more

    var angleDegrees: Double {
        switch self {
        case .team: return -90
        case .model: return -18
        case .agents: return 54
        case .show: return 126
        case .more: return 198
        }
    }

    static func nearest(toAngleDegrees angleDegrees: Double) -> SettingsDialSlice {
        let slicesWithAngleGaps = allCases.map { slice in
            (slice, abs(angleDifferenceInDegrees(from: slice.angleDegrees, to: angleDegrees)))
        }
        // allCases is never empty, and `min` keeps the first of two equal gaps.
        return slicesWithAngleGaps.min(by: { $0.1 < $1.1 })!.0
    }
}

/// What the two fans offer, fixed when the dial opens. Team and Model fan their choices on the outer arc, and the other
/// slices act on release. The Team fan's size depends on how many themes the learner saved, so every pick goes through
/// this value instead of a constant.
struct SettingsDialFans: Equatable {
    /// How many saved themes the Team fan lists after the bundled ones. Eleven bundled themes plus three is the most the
    /// ring holds.
    static let mostSavedThemesInTheTeamFan = 3
    /// The Team fan always spans this many degrees across the top, whatever it holds: the first item at -168 degrees, where
    /// its label has room, and the last item at -12 degrees. More items only narrow the gaps, from 15.6 degrees at 11 items
    /// to 12 at 14, a chord of 31.8 points at the 152 point fan radius. That is wider than the 25.5 points an enlarged ball
    /// (30 points) next to an ordinary one (21 points) needs, so no ball touches the next. A wider span would push the
    /// right end, where the saved themes' long names sit, nearer the window's edge.
    static let teamFanSpanDegrees = 156.0

    /// The Team fan's items in order: the bundled themes (Clicky blue first), then up to 3 saved themes, the newest first.
    let teamThemes: [ClickyTheme]

    /// `savedCustomThemes` in any order. The newest by saved date go after the bundled themes, and a tie keeps the order of
    /// the theme ids, so the fan never reshuffles between two openings.
    init(bundledThemes: [ClickyTheme], savedCustomThemes: [SavedCustomTheme]) {
        let newestSavedThemes = savedCustomThemes
            .sorted { firstSavedTheme, secondSavedTheme in
                firstSavedTheme.savedDate == secondSavedTheme.savedDate
                    ? firstSavedTheme.theme.id < secondSavedTheme.theme.id
                    : firstSavedTheme.savedDate > secondSavedTheme.savedDate
            }
            .prefix(Self.mostSavedThemesInTheTeamFan)
        teamThemes = bundledThemes + newestSavedThemes.map(\.theme)
    }

    func layout(of slice: SettingsDialSlice) -> SettingsDialFanLayout? {
        switch slice {
        case .team:
            return SettingsDialFanLayout(
                centerAngleDegrees: slice.angleDegrees,
                angleBetweenItemsDegrees: Self.teamFanSpanDegrees / Double(teamThemes.count - 1),
                itemCount: teamThemes.count
            )
        case .model:
            // Two labeled pills need more room than the balls do.
            return SettingsDialFanLayout(
                centerAngleDegrees: slice.angleDegrees,
                angleBetweenItemsDegrees: 24,
                itemCount: SettingsDialModelChoice.allCases.count
            )
        case .agents, .show, .more:
            return nil
        }
    }
}

/// The signed turn from one angle to another, in -180 through 180 degrees.
func angleDifferenceInDegrees(from startAngle: Double, to endAngle: Double) -> Double {
    var difference = (endAngle - startAngle).truncatingRemainder(dividingBy: 360)
    if difference > 180 { difference -= 360 }
    if difference < -180 { difference += 360 }
    return difference
}

/// The pointer's angle around the dial's center in degrees, with 0 pointing right and 90 pointing down.
func pointerAngleDegrees(of pointerOffset: CGVector) -> Double {
    atan2(Double(pointerOffset.dy), Double(pointerOffset.dx)) * 180 / .pi
}

// MARK: - Picking

/// What the pointer highlights now. `slice` is nil in the center, and `fanItemIndex` is set only while the pointer
/// is on an item of the open fan.
struct SettingsDialSelection: Equatable {
    var slice: SettingsDialSlice?
    var fanItemIndex: Int?

    /// The fan that is open, which is the highlighted slice's fan.
    func openFanLayout(in fans: SettingsDialFans) -> SettingsDialFanLayout? {
        slice.flatMap { fans.layout(of: $0) }
    }

    /// The selection after the pointer moves to `pointerOffset`.
    /// Inside the plate the pointer picks the slice at its angle, and the center picks nothing. Once a fan is open,
    /// the pointer beyond the plate picks that fan's items and never changes the slice, even across another slice's
    /// angle, so the learner can travel outward to a far item. The slice changes only when the pointer comes back
    /// inside the plate. With no fan open, a pointer beyond the plate still picks the slice at its angle, so a flick
    /// that overshoots the plate lands. Past the picking radius nothing is highlighted but an open fan stays open.
    func afterPointerMoved(to pointerOffset: CGVector, fans: SettingsDialFans) -> SettingsDialSelection {
        let layoutOfTheOpenFan = openFanLayout(in: fans)
        let distanceFromCenter = hypot(pointerOffset.dx, pointerOffset.dy)
        if distanceFromCenter > SettingsDialGeometry.pickingOuterRadius {
            return SettingsDialSelection(slice: layoutOfTheOpenFan == nil ? nil : slice, fanItemIndex: nil)
        }
        if distanceFromCenter <= SettingsDialGeometry.centerDeadZoneRadius {
            return SettingsDialSelection(slice: nil, fanItemIndex: nil)
        }
        let angleDegrees = pointerAngleDegrees(of: pointerOffset)
        if let layoutOfTheOpenFan, distanceFromCenter > SettingsDialGeometry.plateRadius {
            return SettingsDialSelection(slice: slice, fanItemIndex: layoutOfTheOpenFan.nearestItemIndex(toAngleDegrees: angleDegrees))
        }
        return SettingsDialSelection(slice: .nearest(toAngleDegrees: angleDegrees), fanItemIndex: nil)
    }
}

/// Follows the pointer while the dial is open. It starts armed only after the pointer moves, so a dial that an
/// edge shifted off the pointer cannot commit on a release with no movement.
struct SettingsDialPicker {
    private let pointerOffsetWhenOpened: CGVector
    private let fans: SettingsDialFans
    private var pointerHasMovedSinceOpening = false
    private(set) var selection = SettingsDialSelection(slice: nil, fanItemIndex: nil)

    init(pointerOffsetWhenOpened: CGVector, fans: SettingsDialFans) {
        self.pointerOffsetWhenOpened = pointerOffsetWhenOpened
        self.fans = fans
    }

    mutating func pointerMoved(to pointerOffset: CGVector) {
        if !pointerHasMovedSinceOpening {
            let movement = hypot(pointerOffset.dx - pointerOffsetWhenOpened.dx, pointerOffset.dy - pointerOffsetWhenOpened.dy)
            guard movement >= SettingsDialGeometry.pointerMovementBeforePickingBegins else { return }
            pointerHasMovedSinceOpening = true
        }
        selection = selection.afterPointerMoved(to: pointerOffset, fans: fans)
    }
}

// MARK: - Choices

/// What releasing the keys does for the highlighted item.
enum SettingsDialChoice: Equatable {
    case theme(ClickyTheme)
    case model(SettingsDialModelChoice)
    case agents
    case toggleShowClicky
    case more

    /// Nil when the release cancels: in the center, or on Team or Model with no item of their fan highlighted.
    init?(committing selection: SettingsDialSelection, fans: SettingsDialFans) {
        guard let slice = selection.slice else { return nil }
        switch slice {
        case .team:
            guard let themeIndex = selection.fanItemIndex, fans.teamThemes.indices.contains(themeIndex) else { return nil }
            self = .theme(fans.teamThemes[themeIndex])
        case .model:
            guard let modelIndex = selection.fanItemIndex, SettingsDialModelChoice.allCases.indices.contains(modelIndex) else { return nil }
            self = .model(SettingsDialModelChoice.allCases[modelIndex])
        case .agents:
            self = .agents
        case .show:
            self = .toggleShowClicky
        case .more:
            self = .more
        }
    }
}
