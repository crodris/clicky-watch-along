//
//  SettingsDialModel.swift
//  leanring-buddy
//
//  The data and rules of the settings dial that holding shift + option opens under the mouse. Everything here is
//  pure: it takes a pointer offset and returns what is highlighted, so tests check each rule without a screen.
//  Offsets are measured from the dial's center with y growing downward, as SwiftUI and the design mock measure them.
//  SettingsDialPanel.swift draws the dial and turns the real mouse into these offsets.
//

import CoreGraphics
import Foundation

// MARK: - Geometry

/// The dial's sizes in points. The design mock's `dial` and `fan` code is the source of these numbers.
enum SettingsDialGeometry {
    static let plateRadius: CGFloat = 112
    static let tokenRingRadius: CGFloat = 78
    static let tokenDiameter: CGFloat = 44
    static let fanRadius: CGFloat = 152
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
enum SettingsDialPlacement {
    static let reachLeft: CGFloat = 204
    static let reachRight: CGFloat = 204
    static let reachAbove: CGFloat = 196
    static let reachBelow: CGFloat = 160

    static var panelSize: CGSize {
        CGSize(width: reachLeft + reachRight, height: reachAbove + reachBelow)
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

    /// Team and Model fan their choices on the outer arc, and the other slices act on release.
    var fanLayout: SettingsDialFanLayout? {
        switch self {
        case .team:
            // The ten schools, Clicky blue, and Random span 156 degrees across the top, with Clicky blue and Random at the ends.
            let themeCount = CompanionTheme.allChoices.count
            return SettingsDialFanLayout(
                centerAngleDegrees: angleDegrees,
                angleBetweenItemsDegrees: 156 / Double(themeCount - 1),
                itemCount: themeCount
            )
        case .model:
            // Two labeled pills need more room than the balls do.
            return SettingsDialFanLayout(
                centerAngleDegrees: angleDegrees,
                angleBetweenItemsDegrees: 24,
                itemCount: SettingsDialModelChoice.allCases.count
            )
        case .agents, .show, .more:
            return nil
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
    var openFanLayout: SettingsDialFanLayout? { slice?.fanLayout }

    /// The selection after the pointer moves to `pointerOffset`.
    /// Inside the plate the pointer picks the slice at its angle, and the center picks nothing. Once a fan is open,
    /// the pointer beyond the plate picks that fan's items and never changes the slice, even across another slice's
    /// angle, so the learner can travel outward to a far item. The slice changes only when the pointer comes back
    /// inside the plate. With no fan open, a pointer beyond the plate still picks the slice at its angle, so a flick
    /// that overshoots the plate lands. Past the picking radius nothing is highlighted but an open fan stays open.
    func afterPointerMoved(to pointerOffset: CGVector) -> SettingsDialSelection {
        let distanceFromCenter = hypot(pointerOffset.dx, pointerOffset.dy)
        if distanceFromCenter > SettingsDialGeometry.pickingOuterRadius {
            return SettingsDialSelection(slice: openFanLayout == nil ? nil : slice, fanItemIndex: nil)
        }
        if distanceFromCenter <= SettingsDialGeometry.centerDeadZoneRadius {
            return SettingsDialSelection(slice: nil, fanItemIndex: nil)
        }
        let angleDegrees = pointerAngleDegrees(of: pointerOffset)
        if let openFanLayout, distanceFromCenter > SettingsDialGeometry.plateRadius {
            return SettingsDialSelection(slice: slice, fanItemIndex: openFanLayout.nearestItemIndex(toAngleDegrees: angleDegrees))
        }
        return SettingsDialSelection(slice: .nearest(toAngleDegrees: angleDegrees), fanItemIndex: nil)
    }
}

/// Follows the pointer while the dial is open. It starts armed only after the pointer moves, so a dial that an
/// edge shifted off the pointer cannot commit on a release with no movement.
struct SettingsDialPicker {
    private let pointerOffsetWhenOpened: CGVector
    private var pointerHasMovedSinceOpening = false
    private(set) var selection = SettingsDialSelection(slice: nil, fanItemIndex: nil)

    init(pointerOffsetWhenOpened: CGVector) {
        self.pointerOffsetWhenOpened = pointerOffsetWhenOpened
    }

    mutating func pointerMoved(to pointerOffset: CGVector) {
        if !pointerHasMovedSinceOpening {
            let movement = hypot(pointerOffset.dx - pointerOffsetWhenOpened.dx, pointerOffset.dy - pointerOffsetWhenOpened.dy)
            guard movement >= SettingsDialGeometry.pointerMovementBeforePickingBegins else { return }
            pointerHasMovedSinceOpening = true
        }
        selection = selection.afterPointerMoved(to: pointerOffset)
    }
}

// MARK: - Choices

/// What releasing the keys does for the highlighted item.
enum SettingsDialChoice: Equatable {
    case theme(CompanionTheme)
    case model(SettingsDialModelChoice)
    case agents
    case toggleShowClicky
    case more

    /// Nil when the release cancels: in the center, or on Team or Model with no item of their fan highlighted.
    init?(committing selection: SettingsDialSelection) {
        guard let slice = selection.slice else { return nil }
        switch slice {
        case .team:
            guard let themeIndex = selection.fanItemIndex, CompanionTheme.allChoices.indices.contains(themeIndex) else { return nil }
            self = .theme(CompanionTheme.allChoices[themeIndex])
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
