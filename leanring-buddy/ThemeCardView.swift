//
//  ThemeCardView.swift
//  leanring-buddy
//
//  The menu bar panel's theme cards and their grid. A card draws a theme from its own fields the way the Theme Studio's
//  tiles draw an idea (`ThemeStudioTileView`): the cursor at 1.6 times its size, running its thinking motion and streaks
//  while the card is hovered or holds the keyboard focus, the name, the accent and agent colors as swatches, and a small
//  agent token. Bundled and saved themes are the same cards, and a saved one adds a pencil and a trash can on hover or
//  focus, and the same two actions on a right click.
//
//  A card keeps its size in every state, since the panel's frame follows its content: renaming puts a field where the
//  name was, a refused name shows a short red phrase over the bottom of the tile, and an armed delete shows a red Delete
//  button there for 3 seconds. Return saves a new name, Escape or a click away cancels, and a refused name keeps the field
//  open with "1 to 24 characters".
//
//  In the grid the arrow keys move the keyboard focus between cards (`themeGridCardIndex`) and Return or Space picks.
//

import AppKit
import SwiftUI

/// Where the keyboard focus sits in a grid of theme cards: a card itself, or one of a saved card's two buttons.
enum ThemeGridFocus: Hashable {
    case card(themeID: String)
    case renameButton(themeID: String)
    case deleteButton(themeID: String)
    case designOneCard

    var themeID: String? {
        switch self {
        case .card(let themeID), .renameButton(let themeID), .deleteButton(let themeID): return themeID
        case .designOneCard: return nil
        }
    }
}

/// The cards of a theme grid, three to a row, ending with an optional "Design one" card.
struct ThemeCardGrid: View {
    let themes: [ClickyTheme]
    let selectedTheme: ClickyTheme
    /// Nil hides the "Design one" card.
    let designATheme: (() -> Void)?
    let pick: (ClickyTheme) -> Void
    let rename: (ClickyTheme, String) throws -> Void
    let delete: (ClickyTheme) throws -> Void

    @FocusState private var focus: ThemeGridFocus?

    static let columnCount = 3
    static let spacing: CGFloat = 8

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: Self.spacing, alignment: .top), count: Self.columnCount)
    }

    /// The cards in focus order, the "Design one" card last.
    private var cardFocusOrder: [ThemeGridFocus] {
        themes.map { ThemeGridFocus.card(themeID: $0.id) } + (designATheme == nil ? [] : [.designOneCard])
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: Self.spacing) {
            ForEach(themes, id: \.id) { theme in
                ThemeCard(
                    theme: theme,
                    isSelected: theme == selectedTheme,
                    focus: $focus,
                    pick: { pick(theme) },
                    rename: theme.origin.isSaved ? { typedName in try rename(theme, typedName) } : nil,
                    delete: theme.origin.isSaved ? { try delete(theme) } : nil,
                    moveTheFocus: { arrowKey in moveTheFocus(from: .card(themeID: theme.id), arrowKey: arrowKey) }
                )
            }
            if let designATheme {
                DesignOneThemeCard(
                    focus: $focus,
                    design: designATheme,
                    moveTheFocus: { arrowKey in moveTheFocus(from: .designOneCard, arrowKey: arrowKey) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Themes")
    }

    private func moveTheFocus(from currentFocus: ThemeGridFocus, arrowKey: ThemeGridArrowKey) {
        guard let currentIndex = cardFocusOrder.firstIndex(of: currentFocus) else { return }
        let nextIndex = themeGridCardIndex(afterPressing: arrowKey, from: currentIndex, columnCount: Self.columnCount, cardCount: cardFocusOrder.count)
        focus = cardFocusOrder[nextIndex]
    }
}

extension ThemeOrigin {
    /// A saved theme can be renamed and deleted. A bundled one and a Theme Studio idea cannot.
    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

/// The pill that shows a focused card's whole name. A name too wide for the card wraps inside it, growing the pill upward
/// over the name it repeats, so the pill never reaches past the card's edges into the next card or the panel's edge.
struct ThemeCardFullNamePill: View {
    let name: String

    /// One caption line and its padding, the pill's height for a name that fits on one line.
    static let oneLineHeight: CGFloat = 22

    var body: some View {
        Text(name)
            .font(DS.TypeScale.caption.font)
            .fontWeight(.semibold)
            .foregroundColor(DS.Colors.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minHeight: Self.oneLineHeight)
            .background(RoundedRectangle(cornerRadius: 7).fill(DS.Colors.calloutSurface))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DS.Colors.keyboardFocusRing, lineWidth: 1))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

// MARK: - The card

struct ThemeCard: View {
    let theme: ClickyTheme
    let isSelected: Bool
    var focus: FocusState<ThemeGridFocus?>.Binding
    let pick: () -> Void
    /// Nil for a theme that cannot be renamed, such as a bundled one. Throws when the name is refused or cannot be written.
    let rename: ((String) throws -> Void)?
    /// Nil for a theme that cannot be deleted. Throws when the folder cannot be removed.
    let delete: (() throws -> Void)?
    let moveTheFocus: (ThemeGridArrowKey) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A closed panel sends no mouse exit, so a card it closed over would keep its motion's clock running.
    @Environment(\.menuPanelIsOpen) private var menuPanelIsOpen
    @State private var isHovered = false
    @State private var showsTheFocusRing = false
    @State private var isRenaming = false
    @State private var draftName = ""
    /// Whether the name field ever held the keyboard focus. A field that never got it stays open for a click instead of
    /// cancelling as if the learner had clicked away.
    @State private var nameFieldHasHadFocus = false
    @State private var deleteIsArmed = false
    /// A short plain phrase in red for a refused name, a failed rename, or a failed delete.
    @State private var problemText: String?
    @FocusState private var nameFieldIsFocused: Bool

    static let cornerRadius = DS.CornerRadius.medium
    private static let secondsAnArmedDeleteWaits: Double = 3
    /// Two lines of the title type, so a long name keeps the card's height.
    private static let nameHeight: CGFloat = 34

    private var accentColor: Color { Color(hex: theme.accentHex) }
    private var cardHasTheFocus: Bool { focus.wrappedValue?.themeID == theme.id }
    private var cardItselfHasTheFocus: Bool { focus.wrappedValue == .card(themeID: theme.id) }
    /// The cursor moves while the learner looks at the card: on hover, and while it holds the keyboard focus.
    private var cursorRunsItsMotion: Bool { (isHovered || cardItselfHasTheFocus) && !isRenaming && menuPanelIsOpen }
    private var savedActionsShow: Bool { rename != nil && (isHovered || cardHasTheFocus || deleteIsArmed) && !isRenaming }

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                ThemeCardCursor(theme: theme, runsItsMotion: cursorRunsItsMotion)
                    .frame(width: 56, height: 56)
                nameOrField
                    .frame(height: Self.nameHeight, alignment: .top)
                HStack(spacing: 3) {
                    ForEach(Array(([accentColor] + theme.agentColorsInOrder.prefix(3).map(\.color)).enumerated()), id: \.offset) { _, swatchColor in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(swatchColor)
                            .frame(width: 8, height: 8)
                    }
                    Spacer(minLength: 4)
                    ThemeCardAgentTokenView(theme: theme)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(isHovered ? DS.Colors.surface4 : DS.Colors.surface3))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .stroke(isSelected ? accentColor : DS.Colors.borderSubtle, lineWidth: isSelected ? 1.5 : 1)
            )
            // As on the studio's tiles, the chosen card is the bright one. The pointer and the keyboard focus brighten any card.
            .opacity(isSelected || isHovered || cardHasTheFocus ? 1 : 0.75)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        // Dragging the card out of the panel makes a .clickytheme file where it lands (`ThemeFileDrag`). A drag session
        // takes the mouse, so the card never hears it leave, and the card drops its hover when the drag starts.
        .onDrag {
            isHovered = false
            return ThemeFileDrag.itemProvider(for: theme)
        }
        .hoverAndPointer { isNowHovered in
            isHovered = isNowHovered
            // A failed delete's phrase stays while the pointer is on the card, and a refused name's stays until the field closes.
            if !isNowHovered && !isRenaming { problemText = nil }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .card(themeID: theme.id))
        .onKeyPress(keys: [.return, .space]) { _ in
            guard !isRenaming else { return .ignored }
            pick()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { keyPress in
            guard !isRenaming else { return .ignored }
            switch keyPress.key {
            case .leftArrow: moveTheFocus(.left)
            case .rightArrow: moveTheFocus(.right)
            case .upArrow: moveTheFocus(.up)
            default: moveTheFocus(.down)
            }
            return .handled
        }
        .onChange(of: cardItselfHasTheFocus) { _, isNowFocused in
            showsTheFocusRing = isNowFocused && theKeyboardMovedTheFocus()
        }
        .panelKeyboardFocusRing(isShowing: showsTheFocusRing && cardItselfHasTheFocus, cornerRadius: Self.cornerRadius)
        .overlay(alignment: .topTrailing) { savedActions }
        .overlay(alignment: .bottom) { bottomOfTheTile }
        .overlay(alignment: .bottom) { fullNameOverTheFocusedCard }
        .zIndex(cardHasTheFocus ? 1 : 0)
        .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: isSelected)
        .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: isHovered)
        .help(theme.name)
        .contextMenu {
            if rename != nil {
                Button("Rename") { startRename() }
                Button("Delete", role: .destructive) { deleteIsArmed = true }
            }
        }
        .task(id: deleteIsArmed) {
            // The timer that puts the trash can back, which restarts for each arming and stops when the card goes away.
            guard deleteIsArmed else { return }
            try? await Task.sleep(for: .seconds(Self.secondsAnArmedDeleteWaits))
            deleteIsArmed = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(theme.name)
        .accessibilityValue(isSelected ? "Selected theme" : "Theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { pick() }
        .accessibilityActions {
            if rename != nil {
                Button("Rename") { startRename() }
                Button("Delete") { deleteIsArmed = true }
            }
        }
    }

    @ViewBuilder private var nameOrField: some View {
        if isRenaming {
            renameField
        } else {
            // A name that fits one line keeps the title type. A single long word, such as a school's name, steps down to
            // the caption type on one line instead of breaking mid-word, and a long name of several words takes two lines.
            ViewThatFits(in: .horizontal) {
                Text(theme.name).font(DS.TypeScale.title.font).lineLimit(1).fixedSize()
                Text(theme.name).font(DS.TypeScale.caption.font).fontWeight(.semibold).lineLimit(1).fixedSize()
                Text(theme.name).font(DS.TypeScale.title.font).multilineTextAlignment(.center).lineLimit(2).truncationMode(.tail)
            }
            .foregroundColor(DS.Colors.textPrimary)
        }
    }

    // MARK: Saved theme actions

    @ViewBuilder private var savedActions: some View {
        if rename != nil {
            HStack(spacing: 3) {
                ThemeCardIconButton(
                    systemImageName: "pencil",
                    accessibilityLabel: "Rename \(theme.name)",
                    hoverColor: DS.Colors.textPrimary,
                    focus: focus,
                    focusValue: .renameButton(themeID: theme.id),
                    action: startRename
                )
                ThemeCardIconButton(
                    systemImageName: "trash",
                    accessibilityLabel: "Delete \(theme.name)",
                    hoverColor: DS.Colors.destructiveText,
                    focus: focus,
                    focusValue: .deleteButton(themeID: theme.id),
                    action: { deleteIsArmed = true }
                )
            }
            .padding(4)
            .opacity(savedActionsShow ? 1 : 0)
            .allowsHitTesting(savedActionsShow)
            .animation(.easeOut(duration: DS.Move.fadeSeconds), value: savedActionsShow)
        }
    }

    @ViewBuilder private var bottomOfTheTile: some View {
        if let problemText {
            Text(problemText)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.destructiveText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.destructiveSurface))
                .padding(6)
                .accessibilityAddTraits(.updatesFrequently)
        } else if deleteIsArmed {
            PanelButton(title: "Delete", prominence: .destructive, fillsTheWidth: true, action: confirmDelete)
            .padding(6)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            .accessibilityLabel("Confirm delete \(theme.name)")
        }
    }

    /// The whole name over the bottom of a card that holds the keyboard focus, since a long name is cut to two lines.
    @ViewBuilder private var fullNameOverTheFocusedCard: some View {
        if showsTheFocusRing && cardItselfHasTheFocus {
            ThemeCardFullNamePill(name: theme.name)
                // It sits over the card's own swatch row. Below the card it would sit under the next row's cards, which
                // a grid draws later whatever the focused card's z-index.
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
        }
    }

    // MARK: Renaming

    private var renameField: some View {
        TextField("Theme name", text: $draftName)
            .textFieldStyle(.plain)
            .font(DS.TypeScale.caption.font)
            .fontWeight(.semibold)
            .foregroundColor(DS.Colors.textPrimary)
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(DS.Colors.background))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(problemText == nil ? DS.Colors.borderSubtle : DS.Colors.destructive, lineWidth: 1)
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
            .accessibilityLabel("New name for \(theme.name)")
    }

    private func startRename() {
        draftName = theme.name
        problemText = nil
        deleteIsArmed = false
        nameFieldHasHadFocus = false
        isRenaming = true
    }

    /// Return. A refused name keeps the field open, and a saved one closes it.
    private func commitRename() {
        guard let rename else { return }
        do {
            try rename(draftName)
            problemText = nil
            isRenaming = false
            focus.wrappedValue = .card(themeID: theme.id)
        } catch CustomThemeStoreError.themeNameIsNotValid {
            problemText = "1 to \(ClickyTheme.longestName) characters"
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

    /// The second click. The first one only arms the red Delete button.
    private func confirmDelete() {
        deleteIsArmed = false
        guard let delete else { return }
        do {
            try delete()
        } catch {
            problemText = "Couldn't delete it"
        }
    }
}

/// The card's cursor, drawn the way the Theme Studio's highlighted tile draws an idea's: its thinking motion and its streaks
/// pulsing, while `runsItsMotion`. Otherwise it holds still. With Reduce Motion on the motion and the streaks stay off.
struct ThemeCardCursor: View {
    let theme: ClickyTheme
    let runsItsMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var picture: NSImage? {
        theme.usesPicture ? CustomThemePictureCache.image(forThemeID: theme.id) : nil
    }

    var body: some View {
        Group {
            if runsItsMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || theme.motion.trailStreaks == 0)) { timelineContext in
                    CustomCursorView(
                        customTheme: theme,
                        picture: picture,
                        streakOpacity: reduceMotion ? 0 : 0.55 + 0.45 * sin(timelineContext.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.6),
                        voiceState: .processing,
                        audioPowerLevel: 0
                    )
                }
            } else {
                CustomCursorView(customTheme: theme, picture: picture, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
            }
        }
        // The cursor at about 1.6 times its real size, as on the studio's tiles, and the triangle at its pointer angle, as the
        // header and the settings dial draw it.
        .scaleEffect(1.6)
        .rotationEffect(.degrees(theme.cursorFacing == .pointerAngle ? -35 : 0))
        .accessibilityHidden(true)
    }
}

/// An agent token in the theme's first agent color, as the studio's tiles show: a dark disc with a ring around the picture or
/// a triangle, with the dark edge and soft shadow the real disc has.
private struct ThemeCardAgentTokenView: View {
    let theme: ClickyTheme

    private static let diameter: CGFloat = 18
    private static let ringWidth: CGFloat = 2
    private static let edgeWidth: CGFloat = 1.5
    private var firstAgentColor: Color { theme.agentColorsInOrder.first?.color ?? Color(hex: theme.accentHex) }

    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.agentTokenTrack)
            Circle()
                .stroke(firstAgentColor, lineWidth: Self.ringWidth)
                .padding(Self.ringWidth / 2)
            if theme.agents.faces == .picture, let picture = CustomThemePictureCache.image(forThemeID: theme.id) {
                ThemePictureFaceView(picture: picture, size: Self.diameter - 2 * Self.ringWidth)
            } else {
                Triangle()
                    .fill(firstAgentColor)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(-35))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .overlay(Circle().stroke(Color.black.opacity(0.75), lineWidth: Self.edgeWidth).padding(-Self.edgeWidth / 2))
        .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }
}

/// The pencil and the trash can on a saved card: a 20 point square tile on a dark backing, so it reads over any cursor.
private struct ThemeCardIconButton: View {
    let systemImageName: String
    let accessibilityLabel: String
    /// The icon's color under the pointer.
    let hoverColor: Color
    var focus: FocusState<ThemeGridFocus?>.Binding
    let focusValue: ThemeGridFocus
    let action: () -> Void

    @State private var isHovered = false
    @State private var showsTheFocusRing = false

    private var hasTheFocus: Bool { focus.wrappedValue == focusValue }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? hoverColor : DS.Colors.textSecondary)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DS.Colors.calloutSurface.opacity(isHovered ? 1 : 0.85)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: focusValue)
        .onKeyPress(keys: [.return, .space]) { _ in
            action()
            return .handled
        }
        .onChange(of: hasTheFocus) { _, isNowFocused in
            showsTheFocusRing = isNowFocused && theKeyboardMovedTheFocus()
        }
        .panelKeyboardFocusRing(isShowing: showsTheFocusRing && hasTheFocus, cornerRadius: 6)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The last card of the home's grid, which opens the Theme Studio.
private struct DesignOneThemeCard: View {
    var focus: FocusState<ThemeGridFocus?>.Binding
    let design: () -> Void
    let moveTheFocus: (ThemeGridArrowKey) -> Void

    @State private var isHovered = false
    @State private var showsTheFocusRing = false

    private var hasTheFocus: Bool { focus.wrappedValue == .designOneCard }

    var body: some View {
        Button(action: design) {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                    .foregroundColor(isHovered || hasTheFocus ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundColor(DS.Colors.textSecondary))
                    .frame(width: 56, height: 56)
                Text("Design one")
                    .font(DS.TypeScale.title.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .frame(height: 34, alignment: .top)
                Text("Theme Studio")
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(height: 18)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: ThemeCard.cornerRadius).fill(Color.white.opacity(isHovered ? 0.05 : 0)))
            .overlay(
                RoundedRectangle(cornerRadius: ThemeCard.cornerRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(DS.Colors.borderSubtle)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelPressStyle())
        .hoverAndPointer { isHovered = $0 }
        .focusable()
        .focusEffectDisabled()
        .focused(focus, equals: .designOneCard)
        .onKeyPress(keys: [.return, .space]) { _ in
            design()
            return .handled
        }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { keyPress in
            switch keyPress.key {
            case .leftArrow: moveTheFocus(.left)
            case .rightArrow: moveTheFocus(.right)
            case .upArrow: moveTheFocus(.up)
            default: moveTheFocus(.down)
            }
            return .handled
        }
        .onChange(of: hasTheFocus) { _, isNowFocused in
            showsTheFocusRing = isNowFocused && theKeyboardMovedTheFocus()
        }
        .panelKeyboardFocusRing(isShowing: showsTheFocusRing && hasTheFocus, cornerRadius: ThemeCard.cornerRadius)
        .accessibilityLabel("Design a new theme in the Theme Studio")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Clicking away from a text field

/// While it is in the view tree, calls `onMouseDownOutsideTextFields` whenever the mouse goes down in one of the app's
/// windows anywhere but on a text field. The click still reaches whatever it landed on, so a click on another theme both
/// closes the field and picks that theme.
struct MouseDownOutsideTextFieldsMonitor: NSViewRepresentable {
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
