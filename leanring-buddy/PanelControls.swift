//
//  PanelControls.swift
//  leanring-buddy
//
//  The controls the menu bar panel is built from, each reachable by keyboard. The panel is the only Clicky window that
//  takes the keyboard, so it is the keyboard and VoiceOver home for Clicky: Tab walks every control, Return or Space runs
//  the focused one, and a light blue ring shows where the focus is.
//
//  A SwiftUI button on macOS joins the Tab order only with Full Keyboard Access on, which is off by default. Plain
//  `.focusable()` puts it in the order either way (the phase-zero approval prototype measured this), and `onKeyPress` runs
//  it, since a focusable button does not run on Return by itself. The ring shows only when the keyboard moved the focus, so
//  a click never leaves a ring behind.
//

import AppKit
import SwiftUI

// MARK: - Keyboard focus

extension View {
    /// Puts this control in the panel's Tab order, runs `action` on Return or Space, and rings it while the keyboard holds
    /// its focus. `cornerRadius` is the control's own, so the ring follows its shape 3 points outside it.
    func panelKeyboardControl(cornerRadius: CGFloat, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        modifier(PanelKeyboardControl(cornerRadius: cornerRadius, isEnabled: isEnabled, action: action))
    }

    /// The light blue ring a keyboard-focused control shows, for a control that tracks its own focus, such as a theme card.
    func panelKeyboardFocusRing(isShowing: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                .strokeBorder(DS.Colors.keyboardFocusRing, lineWidth: 2)
                .padding(-3)
                .opacity(isShowing ? 1 : 0)
                .allowsHitTesting(false)
        }
    }
}

/// Whether the event that moved the focus came from the keyboard, so a click that focuses a control shows no ring.
@MainActor
func theKeyboardMovedTheFocus(currentEventType: NSEvent.EventType? = NSApp.currentEvent?.type) -> Bool {
    currentEventType == .keyDown
}

private struct PanelKeyboardControl: ViewModifier {
    let cornerRadius: CGFloat
    let isEnabled: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool
    @State private var showsTheRing = false

    func body(content: Content) -> some View {
        content
            .focusable(isEnabled)
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.return, .space]) { _ in
                guard isEnabled else { return .ignored }
                action()
                return .handled
            }
            .onChange(of: isFocused) { _, isNowFocused in
                showsTheRing = isNowFocused && theKeyboardMovedTheFocus()
            }
            .panelKeyboardFocusRing(isShowing: showsTheRing && isFocused, cornerRadius: cornerRadius)
    }
}

// MARK: - Buttons

/// How a panel button reads.
enum PanelButtonProminence {
    /// Filled with the theme's accent: the one action the panel wants next.
    case primary
    /// A dark surface with an edge.
    case secondary
    /// Text only, for the footer.
    case quiet
    /// Red: a delete that waits for a second click.
    case destructive
}

/// A button of the panel: hover, the pointing hand, the keyboard, and a press that dips on the Snap move.
struct PanelButton: View {
    let title: String
    var systemImageName: String? = nil
    let prominence: PanelButtonProminence
    /// The shown theme's accent, which only a primary button uses.
    var accentColor: Color = DS.Colors.overlayCursorBlue
    var accessibilityHint: String? = nil
    /// Stretches the button's fill across its container, as a card's armed Delete bar does.
    var fillsTheWidth = false
    let action: () -> Void

    @State private var isHovered = false

    private static let cornerRadius: CGFloat = 8

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImageName {
                    Image(systemName: systemImageName)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(DS.TypeScale.caption.font)
                    .fontWeight(prominence == .quiet ? .medium : .semibold)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(foregroundColor)
            .padding(.horizontal, prominence == .quiet ? 6 : 10)
            .padding(.vertical, prominence == .quiet ? 4 : 6)
            .frame(maxWidth: fillsTheWidth ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(backgroundColor))
            .overlay {
                if prominence == .secondary {
                    RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(isHovered ? 0.18 : 0.1), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .panelKeyboardControl(cornerRadius: Self.cornerRadius, action: action)
        .accessibilityHint(accessibilityHint ?? "")
    }

    private var foregroundColor: Color {
        switch prominence {
        case .primary: return accentColor.inkOnThisFill
        case .secondary: return DS.Colors.textPrimary
        case .quiet: return isHovered ? DS.Colors.textPrimary : DS.Colors.textSecondary
        case .destructive: return .white
        }
    }

    private var backgroundColor: Color {
        switch prominence {
        case .primary: return accentColor.opacity(isHovered ? 0.88 : 1)
        case .secondary: return isHovered ? DS.Colors.surface4 : DS.Colors.surface2
        case .quiet: return Color.white.opacity(isHovered ? 0.08 : 0)
        case .destructive: return isHovered ? DS.Colors.destructiveHover : DS.Colors.destructive
        }
    }
}

/// A press dips the control to `DS.Move.snapPressScale` on the Snap move, and holds still with Reduce Motion on.
struct PanelPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? DS.Move.snapPressScale : 1)
            .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: configuration.isPressed)
    }
}

/// A switch in the panel, reachable by Tab, toggled by Space or Return, with its label read by VoiceOver.
struct PanelSwitch: View {
    let accessibilityLabel: String
    @Binding var isOn: Bool
    var accentColor: Color = DS.Colors.overlayCursorBlue

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(accentColor)
            .controlSize(.small)
            .hoverAndPointer { _ in }
            .panelKeyboardControl(cornerRadius: 9) { isOn.toggle() }
            .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Key caps

/// One key drawn as a small cap, as in "hold ⌃ ⌥ to talk".
struct PanelKeyCap: View {
    let key: String

    var body: some View {
        Text(verbatim: key)
            .font(DS.TypeScale.caption.font)
            .fontWeight(.semibold)
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Colors.surface3))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// A shortcut hint for the footer: its keys as caps, then what they do.
struct PanelShortcutHint: View {
    let keys: [String]
    let meaning: String
    let spokenKeys: String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(keys, id: \.self) { PanelKeyCap(key: $0) }
            Text(meaning)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
                .padding(.leading, 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(spokenKeys): \(meaning)")
    }
}

// MARK: - VoiceOver announcements

/// Asks VoiceOver to read a line now, for a surface that never takes the keyboard, such as a chip at the cursor. It does
/// nothing while VoiceOver is off.
@MainActor
func announceForVoiceOver(_ line: String) {
    guard !line.isEmpty else { return }
    NSAccessibility.post(
        element: NSApp as Any,
        notification: .announcementRequested,
        userInfo: [
            NSAccessibility.NotificationUserInfoKey.announcement: line,
            NSAccessibility.NotificationUserInfoKey.priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
    )
}
