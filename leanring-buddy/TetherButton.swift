//
//  TetherButton.swift
//  leanring-buddy
//
//  The one button every Tether surface uses. It replaces eleven look-alikes (the menu bar panel's, the Theme Studio's, the
//  room art panel's, the agent list's, the approval card's, the instant replay's, the quiz summary's, and the small icon
//  buttons), which each chose their own size, corner, hover, press, and disabled look.
//
//  It lives apart from `TetherMaterials.swift` because that file is compiled into both Quick Look extensions, and the
//  button reads `hoverAndPointer` from `BackgroundAgentListPanel.swift`.
//

import SwiftUI

/// What a button is for, which sets its fill, its label color, and its hover.
enum TetherButtonRole: Equatable {
    /// The one action the surface wants next: the accent fill, the ink that reads on it (`inkOnThisFill`), and a ring in
    /// that ink on hover. The fill stays the same on hover, since the ink was chosen for the fill as it rests.
    case primary(accent: Color)
    /// A dark surface (`surface3`, `surface4` on hover) with an `edge` that becomes `edgeHover`.
    case secondary
    /// The same dark surface with its label in `destructiveText`, for a Cancel or a trash can that is not the delete itself.
    case secondaryDestructive
    /// Words only: secondary text that turns primary on hover, over a white 8% wash.
    case quiet
    /// The delete itself: `destructive` filled, `destructiveHover` on hover, and the ink that reads on that red.
    case destructive
}

enum TetherButtonShape {
    /// The button's own corner, `DS.CornerRadius.control`.
    case rounded
    case capsule
    /// An icon alone. The width is the size's height.
    case circle
}

enum TetherButtonSize {
    /// Caption type, 24 tall: a Card's rows and the agent list.
    case compact
    /// Title type, 28 tall: a Card's own buttons.
    case standard
    /// Title type, 32 tall: over a video, where a button needs a larger target.
    case prominent

    var height: CGFloat {
        switch self {
        case .compact: return 24
        case .standard: return 28
        case .prominent: return 32
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: return 10
        case .standard: return 12
        case .prominent: return 14
        }
    }

    var labelFont: Font {
        switch self {
        case .compact: return DS.TypeScale.caption.font.weight(.semibold)
        case .standard, .prominent: return DS.TypeScale.title.font
        }
    }
}

/// The outline every button shape draws, as one inset shape so the fill, the edge, the hover ring, and the hit area all
/// follow it.
struct TetherButtonOutline: InsettableShape {
    let shape: TetherButtonShape
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let cornerRadius: CGFloat
        switch shape {
        case .rounded: cornerRadius = DS.CornerRadius.control
        // A capsule and a circle take half the shorter side, which is what DS.CornerRadius.pill clamps to.
        case .capsule, .circle: cornerRadius = min(rect.width, rect.height) / 2
        }
        return RoundedRectangle(cornerRadius: cornerRadius, style: shape == .rounded ? .continuous : .circular)
            .inset(by: insetAmount)
            .path(in: rect)
    }

    func inset(by amount: CGFloat) -> TetherButtonOutline {
        var inset = self
        inset.insetAmount += amount
        return inset
    }
}

/// How a button looks, apart from the hover tracking and the press, so a test draws it hovered or disabled.
struct TetherButtonLook: View {
    var title: String? = nil
    var systemImage: String? = nil
    let role: TetherButtonRole
    var shape: TetherButtonShape = .rounded
    var size: TetherButtonSize = .standard
    var fillsTheWidth = false
    /// The button sits over a camera or a video, where nothing darkens the page behind it, so it takes the Callout's drop
    /// shadow to stay separate from a bright wall.
    var isOverVideo = false
    var isHovered = false
    var isEnabled = true

    /// A disabled button never shows hover.
    private var isShowingHover: Bool { isHovered && isEnabled }

    private var outline: TetherButtonOutline { TetherButtonOutline(shape: shape) }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                // The title says what the button does, so VoiceOver skips the symbol. An icon-only button is labeled by
                // its `accessibilityLabel`.
                Image(systemName: systemImage)
                    .font(size.labelFont)
                    .accessibilityHidden(title != nil)
            }
            if let title {
                Text(verbatim: title)
                    .font(size.labelFont)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(labelColor)
        .fixedSize(horizontal: !fillsTheWidth, vertical: true)
        // A circle is as wide as it is tall. A full-width button takes its width from its container, so it gets no side
        // padding of its own.
        .padding(.horizontal, shape == .circle || fillsTheWidth ? 0 : size.horizontalPadding)
        .frame(minWidth: size.height, maxWidth: shape == .circle ? size.height : (fillsTheWidth ? .infinity : nil))
        .frame(height: size.height)
        .background(outline.fill(fillColor))
        .overlay {
            if let edgeColor {
                outline.strokeBorder(edgeColor, lineWidth: 1)
            }
        }
        .accentFillHoverRing(outline, ink: labelColor, isShowing: isPrimary && isShowingHover)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(outline)
        .modifier(OptionalCalloutDropShadow(isShowing: isOverVideo))
    }

    private var isPrimary: Bool {
        if case .primary = role { return true }
        return false
    }

    private var labelColor: Color {
        switch role {
        case .primary(let accent): return accent.inkOnThisFill
        case .secondary: return DS.Colors.textPrimary
        case .secondaryDestructive: return DS.Colors.destructiveText
        case .quiet: return isShowingHover ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .destructive: return DS.Colors.destructive.inkOnThisFill
        }
    }

    private var fillColor: Color {
        switch role {
        case .primary(let accent): return accent
        case .secondary, .secondaryDestructive: return isShowingHover ? DS.Colors.surface4 : DS.Colors.surface3
        case .quiet: return isShowingHover ? DS.Colors.edge : .clear
        case .destructive: return isShowingHover ? DS.Colors.destructiveHover : DS.Colors.destructive
        }
    }

    private var edgeColor: Color? {
        switch role {
        case .secondary, .secondaryDestructive: return isShowingHover ? DS.Colors.edgeHover : DS.Colors.edge
        case .primary, .quiet, .destructive: return nil
        }
    }
}

/// The Callout's drop shadow when `isShowing`, and no change to the view otherwise.
private struct OptionalCalloutDropShadow: ViewModifier {
    let isShowing: Bool

    func body(content: Content) -> some View {
        if isShowing {
            content.tetherCalloutDropShadow()
        } else {
            content
        }
    }
}

struct TetherButton: View {
    let title: String?
    let systemImage: String?
    let role: TetherButtonRole
    let shape: TetherButtonShape
    let size: TetherButtonSize
    let fillsTheWidth: Bool
    let isOverVideo: Bool
    let isEnabled: Bool
    /// False where the caller owns the button's keyboard focus, such as a card in a grid that moves it with the arrow keys.
    let takesItsOwnKeyboardFocus: Bool
    let accessibilityLabel: String?
    let accessibilityHint: String?
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        _ title: String? = nil,
        systemImage: String? = nil,
        role: TetherButtonRole,
        shape: TetherButtonShape = .rounded,
        size: TetherButtonSize = .standard,
        fillsTheWidth: Bool = false,
        isOverVideo: Bool = false,
        isEnabled: Bool = true,
        takesItsOwnKeyboardFocus: Bool = true,
        accessibilityLabel: String? = nil,
        accessibilityHint: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.shape = shape
        self.size = size
        self.fillsTheWidth = fillsTheWidth
        self.isOverVideo = isOverVideo
        self.isEnabled = isEnabled
        self.takesItsOwnKeyboardFocus = takesItsOwnKeyboardFocus
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.action = action
    }

    /// The keyboard focus ring follows the button's own corner, so a circle or a capsule rings round.
    private var keyboardRingCornerRadius: CGFloat {
        shape == .rounded ? DS.CornerRadius.control : size.height / 2
    }

    var body: some View {
        let button = Button(action: action) {
            TetherButtonLook(
                title: title, systemImage: systemImage, role: role, shape: shape, size: size,
                fillsTheWidth: fillsTheWidth, isOverVideo: isOverVideo, isHovered: isHovered, isEnabled: isEnabled
            )
            .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: isHovered)
        }
        .buttonStyle(PanelPressStyle())
        .disabled(!isEnabled)
        .hoverAndPointer(isEnabled: isEnabled) { isHovered = $0 }
        if takesItsOwnKeyboardFocus {
            button
                .panelKeyboardControl(cornerRadius: keyboardRingCornerRadius, isEnabled: isEnabled, action: action)
                .tetherButtonAccessibility(label: accessibilityLabel ?? title, hint: accessibilityHint)
        } else {
            button.tetherButtonAccessibility(label: accessibilityLabel ?? title, hint: accessibilityHint)
        }
    }
}

private extension View {
    func tetherButtonAccessibility(label: String?, hint: String?) -> some View {
        accessibilityLabel(label ?? "").accessibilityHint(hint ?? "")
    }
}
