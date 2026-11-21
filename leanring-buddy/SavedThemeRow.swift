//
//  SavedThemeRow.swift
//  leanring-buddy
//
//  One saved custom theme in the menu bar panel's "Team theme" section. A click on the name picks the theme. Hovering the
//  row shows a pencil, which turns the name into a text field, and a trash can, which asks once before it deletes.
//
//  The row keeps its height in every state, since the panel's frame is fitted to its content once, when the panel opens.
//  A problem is therefore a short red phrase in the row's trailing space instead of a second line.
//

import AppKit
import SwiftUI

struct SavedThemeRow: View {
    let customTheme: CustomTheme
    let isSelected: Bool
    let select: () -> Void
    /// Renames the theme to what the learner typed. Throws when the name is refused or the file cannot be written.
    let rename: (String) throws -> Void
    /// Deletes the theme. Throws when the folder cannot be removed.
    let delete: () throws -> Void

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var draftName = ""
    /// Whether the name field ever held the keyboard focus. A field that never got it, such as when the panel was not key,
    /// stays open for a click instead of cancelling as if the learner had clicked away.
    @State private var nameFieldHasHadFocus = false
    @State private var deleteIsArmed = false
    /// A short plain phrase in red for a refused name, a failed rename, or a failed delete.
    @State private var problemText: String?
    @FocusState private var nameFieldIsFocused: Bool

    private static let secondsAnArmedDeleteWaits: Double = 3
    private static let rowHeight: CGFloat = 44

    private var rowShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 8) {
            if isRenaming {
                TeamThemeSwatch(theme: .custom(customTheme))
                    .frame(width: 18, height: 18)
                renameField
                if let problemText {
                    problemLabel(problemText)
                }
            } else {
                selectButton
                if let problemText {
                    problemLabel(problemText)
                } else if isHovered || deleteIsArmed {
                    actionButtons
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .background(rowShape.fill(Color.white.opacity(isHovered ? 0.1 : 0.06)))
        .overlay(
            rowShape.stroke(
                isSelected ? CompanionTheme.custom(customTheme).cursorColor : DS.Colors.borderSubtle,
                lineWidth: isSelected ? 1.5 : 0.5
            )
        )
        .onHover { isNowHovered in
            isHovered = isNowHovered
            // A failed delete's phrase stays while the pointer is on the row, and a refused name's stays until the field closes.
            if !isNowHovered && !isRenaming {
                problemText = nil
            }
        }
        // The timer that puts the Delete button back, which restarts for each arming and stops when the row goes away.
        .task(id: deleteIsArmed) {
            guard deleteIsArmed else { return }
            try? await Task.sleep(for: .seconds(Self.secondsAnArmedDeleteWaits))
            deleteIsArmed = false
        }
    }

    // MARK: - Picking

    private var selectButton: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                TeamThemeSwatch(theme: .custom(customTheme))
                    .frame(width: 18, height: 18)
                Text(customTheme.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    // MARK: - Renaming

    private var renameField: some View {
        TextField("Theme name", text: $draftName)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(
                        problemText == nil ? DS.Colors.borderSubtle : DS.Colors.destructive,
                        lineWidth: problemText == nil ? 0.5 : 1
                    )
            )
            .focused($nameFieldIsFocused)
            .onSubmit(commitRename)
            // Escape reaches the field as the exit command, since the panel is key and the field holds the keyboard.
            .onExitCommand(perform: cancelRename)
            .task { nameFieldIsFocused = true }
            .onChange(of: nameFieldIsFocused) { _, fieldIsNowFocused in
                if fieldIsNowFocused {
                    nameFieldHasHadFocus = true
                } else if nameFieldHasHadFocus {
                    // The panel closed or another control took the keyboard, so the learner is done with the field.
                    cancelRename()
                }
            }
            // A click on a SwiftUI button or empty space does not take the keyboard from a text field on macOS, so the
            // focus change above misses most clicks away from the field.
            .background(MouseDownOutsideTextFieldsMonitor(onMouseDownOutsideTextFields: cancelRename))
            .accessibilityLabel("Theme name")
    }

    private func startRename() {
        draftName = customTheme.name
        problemText = nil
        deleteIsArmed = false
        nameFieldHasHadFocus = false
        isRenaming = true
    }

    /// Return. A refused name keeps the field open, and a saved one closes it.
    private func commitRename() {
        do {
            try rename(draftName)
            problemText = nil
            isRenaming = false
        } catch CustomThemeStoreError.themeNameIsNotValid {
            problemText = "1 to \(CustomTheme.longestName) characters"
        } catch {
            problemText = "Couldn't rename it"
        }
    }

    /// Escape, a click away, or the field losing the keyboard. The theme keeps its old name.
    private func cancelRename() {
        guard isRenaming else { return }
        problemText = nil
        isRenaming = false
    }

    // MARK: - Deleting

    private var actionButtons: some View {
        HStack(spacing: 4) {
            SavedThemeIconButton(
                systemImageName: "pencil",
                accessibilityLabel: "Rename \(customTheme.name)",
                hoverColor: DS.Colors.textPrimary,
                action: startRename
            )
            if deleteIsArmed {
                SavedThemeDeleteConfirmButton(accessibilityLabel: "Delete \(customTheme.name)", action: confirmDelete)
            } else {
                SavedThemeIconButton(
                    systemImageName: "trash",
                    accessibilityLabel: "Delete \(customTheme.name)",
                    hoverColor: DS.Colors.destructiveText,
                    action: { deleteIsArmed = true }
                )
            }
        }
    }

    /// The second click. The first one only turns the trash can into the Delete button.
    private func confirmDelete() {
        deleteIsArmed = false
        do {
            try delete()
        } catch {
            problemText = "Couldn't delete it"
        }
    }

    private func problemLabel(_ problem: String) -> some View {
        Text(problem)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(DS.Colors.destructiveText)
            .lineLimit(1)
            .fixedSize()
    }
}

/// The pencil and the trash can: a 24 point square tile, as square as the icon, that lights up under the pointer.
private struct SavedThemeIconButton: View {
    let systemImageName: String
    let accessibilityLabel: String
    /// The icon's color under the pointer.
    let hoverColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? hoverColor : DS.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(Color.white.opacity(isHovered ? 0.14 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityLabel(accessibilityLabel)
    }
}

/// What the trash can turns into for 3 seconds after the first click, in red, so the second click is a clear choice.
private struct SavedThemeDeleteConfirmButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text("Delete")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textOnAccent)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                        .fill(isHovered ? DS.Colors.destructiveHover : DS.Colors.destructive)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .pointerCursor()
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Clicking away from a text field

/// While it is in the view tree, calls `onMouseDownOutsideTextFields` whenever the mouse goes down in one of the app's
/// windows anywhere but on a text field. The click still reaches whatever it landed on, so a click on another theme both
/// closes the field and picks that theme.
private struct MouseDownOutsideTextFieldsMonitor: NSViewRepresentable {
    let onMouseDownOutsideTextFields: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMouseDownOutsideTextFields: onMouseDownOutsideTextFields)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.startMonitoring()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMouseDownOutsideTextFields = onMouseDownOutsideTextFields
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var onMouseDownOutsideTextFields: () -> Void
        private var eventMonitor: Any?

        init(onMouseDownOutsideTextFields: @escaping () -> Void) {
            self.onMouseDownOutsideTextFields = onMouseDownOutsideTextFields
        }

        func startMonitoring() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] mouseDownEvent in
                let clickedView = mouseDownEvent.window?.contentView?.hitTest(mouseDownEvent.locationInWindow)
                // A text field is an NSTextField, and one being edited puts its NSTextView in front of it.
                var clickWasOnATextField = false
                var viewUnderTheClick = clickedView
                while let view = viewUnderTheClick {
                    if view is NSTextField || view is NSTextView {
                        clickWasOnATextField = true
                        break
                    }
                    viewUnderTheClick = view.superview
                }
                if !clickWasOnATextField {
                    self?.onMouseDownOutsideTextFields()
                }
                return mouseDownEvent
            }
        }

        func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }
            eventMonitor = nil
        }
    }
}
