//
//  SettingsDialPanel.swift
//  leanring-buddy
//
//  The settings dial that holding shift + option opens under the mouse: a round plate with five tokens (Team, Model,
//  Agents, Show, More) and, for Team and Model, a fan of choices on an outer arc. It is a borderless, nonactivating
//  panel that never becomes key and ignores the mouse, so the app under it keeps the keyboard and every click.
//  The rules for what the pointer picks live in SettingsDialModel.swift. This file draws the dial and turns the real
//  mouse into offsets from the dial's center.
//

import AppKit
import Combine
import SwiftUI

// MARK: - State

/// What the dial shows about the settings at the moment it opens. The dial lives for a few seconds, so it never
/// needs to follow later changes.
struct SettingsDialSnapshot {
    let theme: ClickyTheme
    /// The picture `theme`'s cursor uses, which a preview holds in memory and a saved theme keeps in picture.jpg.
    let themePicture: NSImage?
    let modelID: String
    let isClickyCursorEnabled: Bool
    let runningAgentCount: Int
    /// What the Team and Model fans offer, including the saved themes the learner designed.
    let fans: SettingsDialFans
}

@MainActor
final class SettingsDialViewModel: ObservableObject {
    let snapshot: SettingsDialSnapshot
    let showsTheFirstRunHint: Bool
    /// Read once when the dial opens. With Reduce Motion on, the dial and its fans appear with no scale or stagger.
    let reduceMotion: Bool
    @Published var isPresented = false
    @Published var selection = SettingsDialSelection(slice: nil, fanItemIndex: nil)

    init(snapshot: SettingsDialSnapshot, showsTheFirstRunHint: Bool, reduceMotion: Bool) {
        self.snapshot = snapshot
        self.showsTheFirstRunHint = showsTheFirstRunHint
        self.reduceMotion = reduceMotion
    }
}

// MARK: - Controller

private final class SettingsDialPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SettingsDialController {
    /// One level above the cursor overlay windows, the same as the agent list, so the dial draws over the cursor.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    private static let hintWasShownDefaultsKey = "settingsDialHintWasShown"
    private static let secondsBetweenPointerReads: TimeInterval = 1.0 / 60

    private let userDefaults: UserDefaults
    private var panel: SettingsDialPanel?
    private var viewModel: SettingsDialViewModel?
    private var picker: SettingsDialPicker?
    /// The dial's center in AppKit screen coordinates, fixed when it opens.
    private var dialCenter: CGPoint = .zero
    private var pointerReadTimer: Timer?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var isOpen: Bool { panel != nil }

    /// Opens the dial centered on the mouse, moved inward when a screen edge would cut it off.
    func open(snapshot: SettingsDialSnapshot) {
        guard panel == nil, let screen = screenUnderTheMouseCursor() else { return }
        let mouseLocation = NSEvent.mouseLocation
        dialCenter = SettingsDialPlacement.dialCenter(forMouseLocation: mouseLocation, visibleFrame: screen.visibleFrame)

        let showsTheFirstRunHint = !userDefaults.bool(forKey: Self.hintWasShownDefaultsKey)
        userDefaults.set(true, forKey: Self.hintWasShownDefaultsKey)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let viewModel = SettingsDialViewModel(snapshot: snapshot, showsTheFirstRunHint: showsTheFirstRunHint, reduceMotion: reduceMotion)
        self.viewModel = viewModel
        picker = SettingsDialPicker(pointerOffsetWhenOpened: pointerOffsetFromTheDialCenter(for: mouseLocation), fans: snapshot.fans)

        let panelSize = SettingsDialPlacement.panelSize
        let hostingView = NSHostingView(rootView: SettingsDialView(viewModel: viewModel))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let panelOrigin = CGPoint(x: dialCenter.x - SettingsDialPlacement.reachLeft, y: dialCenter.y - SettingsDialPlacement.reachBelow)
        let settingsDialPanel = SettingsDialPanel(
            contentRect: CGRect(origin: panelOrigin, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        settingsDialPanel.isOpaque = false
        settingsDialPanel.backgroundColor = .clear
        settingsDialPanel.hasShadow = false
        settingsDialPanel.level = Self.panelLevel
        settingsDialPanel.hidesOnDeactivate = false
        settingsDialPanel.isReleasedWhenClosed = false
        settingsDialPanel.isExcludedFromWindowsMenu = true
        // The dial only looks at the mouse. Every click goes through to the app under it.
        settingsDialPanel.ignoresMouseEvents = true
        settingsDialPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        settingsDialPanel.contentView = hostingView
        panel = settingsDialPanel
        // Not makeKeyAndOrderFront, which would take the keyboard from the app under the dial.
        settingsDialPanel.orderFrontRegardless()
        if reduceMotion {
            viewModel.isPresented = true
        } else {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) { viewModel.isPresented = true }
        }
        startReadingThePointer()
    }

    /// The learner let go of the chord: returns what the highlighted item commits, or nil when it cancels, and closes the dial.
    func releaseAndReturnTheChoice() -> SettingsDialChoice? {
        guard isOpen else { return nil }
        // Read the pointer once more, since it may have moved since the last timer tick.
        readThePointer()
        let choice = viewModel.flatMap { SettingsDialChoice(committing: $0.selection, fans: $0.snapshot.fans) }
        close()
        return choice
    }

    func close() {
        pointerReadTimer?.invalidate()
        pointerReadTimer = nil
        panel?.orderOut(nil)
        // Dropping the view stops its animations.
        panel?.contentView = nil
        panel = nil
        viewModel = nil
        picker = nil
    }

    /// A timer reads the mouse instead of a global mouse-moved monitor, since a monitor skips events that go to this
    /// app's own windows, and the dial must follow the pointer wherever it is.
    private func startReadingThePointer() {
        pointerReadTimer = Timer.scheduledTimer(withTimeInterval: Self.secondsBetweenPointerReads, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, where this class lives.
            MainActor.assumeIsolated { self?.readThePointer() }
        }
    }

    private func readThePointer() {
        guard var picker, let viewModel else { return }
        picker.pointerMoved(to: pointerOffsetFromTheDialCenter(for: NSEvent.mouseLocation))
        self.picker = picker
        if viewModel.selection != picker.selection {
            viewModel.selection = picker.selection
        }
    }

    /// AppKit's y grows upward and the dial's offsets grow downward, so y flips.
    private func pointerOffsetFromTheDialCenter(for mouseLocation: CGPoint) -> CGVector {
        CGVector(dx: mouseLocation.x - dialCenter.x, dy: dialCenter.y - mouseLocation.y)
    }
}

// MARK: - View

struct SettingsDialView: View {
    @ObservedObject var viewModel: SettingsDialViewModel

    private var theme: ClickyTheme { viewModel.snapshot.theme }
    private var accentColor: Color { theme.cursorColor }
    /// The team's ink color, for line icons drawn on the accent color so they stay visible on it.
    private var inkColor: Color { theme.cursorContrastColor }
    private let tokenFillColor = DS.Colors.settingsDialToken
    private var centerInView: CGPoint {
        CGPoint(x: SettingsDialPlacement.reachLeft, y: SettingsDialPlacement.reachAbove)
    }
    private var fans: SettingsDialFans { viewModel.snapshot.fans }
    private var openFanSlice: SettingsDialSlice? {
        viewModel.selection.openFanLayout(in: fans) == nil ? nil : viewModel.selection.slice
    }

    var body: some View {
        ZStack {
            dial
                .scaleEffect(viewModel.isPresented ? 1 : 0.9, anchor: UnitPoint(
                    x: centerInView.x / SettingsDialPlacement.panelSize.width,
                    y: centerInView.y / SettingsDialPlacement.panelSize.height
                ))
                .opacity(viewModel.isPresented ? 1 : 0)
            if let openFanSlice {
                fan(of: openFanSlice)
            }
            if viewModel.showsTheFirstRunHint {
                hint
                    .opacity(viewModel.isPresented ? 1 : 0)
            }
        }
        .frame(width: SettingsDialPlacement.panelSize.width, height: SettingsDialPlacement.panelSize.height)
        .animation(viewModel.reduceMotion ? nil : .easeOut(duration: 0.14), value: openFanSlice)
    }

    // MARK: Plate and tokens

    private var dial: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.settingsDialPlate.opacity(0.76))
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                .frame(width: SettingsDialGeometry.plateRadius * 2, height: SettingsDialGeometry.plateRadius * 2)
                .position(centerInView)
            ForEach(SettingsDialSlice.allCases, id: \.self) { slice in
                token(for: slice)
            }
            cursorGlyph
                .position(centerInView)
        }
    }

    private func point(atAngleDegrees angleDegrees: Double, radius: CGFloat) -> CGPoint {
        let angleInRadians = angleDegrees * .pi / 180
        return CGPoint(
            x: centerInView.x + cos(angleInRadians) * radius,
            y: centerInView.y + sin(angleInRadians) * radius
        )
    }

    private func token(for slice: SettingsDialSlice) -> some View {
        let isSelected = viewModel.selection.slice == slice
        let tokenCenter = point(atAngleDegrees: slice.angleDegrees, radius: SettingsDialGeometry.tokenRingRadius)
        let labelText = tokenTitle(for: slice)
        let labelOffsetY = SettingsDialLabel.tokenLabelCenterOffsetY(
            for: slice,
            labelPillHeight: SettingsDialLabel.pillSize(forText: labelText).height
        )
        return ZStack {
            Circle()
                .fill(isSelected ? accentColor : tokenFillColor)
            Circle()
                .stroke(isSelected ? Color.clear : Color.white.opacity(0.14), lineWidth: 1)
            tokenIcon(for: slice, isSelected: isSelected)
        }
        .frame(width: SettingsDialGeometry.tokenDiameter, height: SettingsDialGeometry.tokenDiameter)
        .shadow(color: isSelected ? accentColor.opacity(0.55) : .clear, radius: 7)
        .overlay(alignment: .topTrailing) {
            if slice == .agents, viewModel.snapshot.runningAgentCount > 0 {
                Text("\(viewModel.snapshot.runningAgentCount)")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundColor(DS.Colors.settingsDialDarkInk)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white))
                    .offset(x: 6, y: -6)
            }
        }
        .position(tokenCenter)
        .overlay {
            labelPill(labelText)
                .position(x: tokenCenter.x, y: tokenCenter.y + labelOffsetY)
        }
        .animation(viewModel.reduceMotion ? nil : .easeOut(duration: 0.1), value: isSelected)
    }

    private func tokenTitle(for slice: SettingsDialSlice) -> String {
        switch slice {
        case .team: return "Team"
        case .model: return "Model"
        case .agents: return "Agents"
        case .show: return "Show"
        case .more: return "More"
        }
    }

    /// Line icons are white, or the team's ink color on the selected token's accent fill.
    @ViewBuilder private func tokenIcon(for slice: SettingsDialSlice, isSelected: Bool) -> some View {
        let lineColor = isSelected ? inkColor : Color.white
        switch slice {
        case .team:
            // The theme's own cursor. Its shapes are often filled in the accent color, so on the selected token's accent fill
            // it would vanish. A dark disc inside the accent ring keeps it readable.
            ZStack {
                if isSelected {
                    Circle()
                        .fill(tokenFillColor)
                        .frame(width: Self.customCursorBackingDiameterOnTheSelectedToken, height: Self.customCursorBackingDiameterOnTheSelectedToken)
                }
                SettingsDialCustomCursor(customTheme: theme, picture: viewModel.snapshot.themePicture, longestSide: 22)
            }
        case .model:
            Image(systemName: "sparkle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(lineColor)
        case .agents:
            // Two rings, the look of two agents' progress rings. A theme whose agents wear its accent shows the accent.
            let agentsWearTheAccent = theme.agents.ring == .accent
            let firstRingColor = isSelected ? inkColor : (agentsWearTheAccent ? accentColor : DS.Colors.backgroundAgentThreeDModelViolet)
            let secondRingColor = isSelected ? inkColor : (agentsWearTheAccent ? accentColor : DS.Colors.backgroundAgentTaskTeal)
            ZStack {
                Circle().stroke(firstRingColor, lineWidth: 2).frame(width: 9, height: 9).offset(x: -5)
                Circle().stroke(secondRingColor, lineWidth: 2).frame(width: 9, height: 9).offset(x: 5)
            }
        case .show:
            Image(systemName: viewModel.snapshot.isClickyCursorEnabled ? "eye" : "eye.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(lineColor)
        case .more:
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(lineColor)
        }
    }

    /// The dial's center glyph, the cursor the learner is using, drawn still, with no motion and no streaks, at its natural
    /// size.
    @ViewBuilder private var cursorGlyph: some View {
        let naturalDrawingSize = CustomCursorView.drawingSize(of: theme, picture: viewModel.snapshot.themePicture)
        SettingsDialCustomCursor(
            customTheme: theme,
            picture: viewModel.snapshot.themePicture,
            longestSide: max(naturalDrawingSize.width, naturalDrawingSize.height)
        )
        .shadow(color: accentColor, radius: 8)
    }

    // MARK: Fans

    @ViewBuilder private func fan(of slice: SettingsDialSlice) -> some View {
        switch slice {
        case .team:
            teamFan
        case .model:
            modelFan
        case .agents, .show, .more:
            EmptyView()
        }
    }

    /// The item drawn large with a glow and a label: the one under the pointer, or the current choice before the
    /// pointer reaches any.
    private func emphasizedItemIndex(currentItemIndex: Int?) -> Int? {
        viewModel.selection.fanItemIndex ?? currentItemIndex
    }

    private func fanItemTransition(forItemAt itemIndex: Int) -> AnyTransition {
        guard !viewModel.reduceMotion else { return .identity }
        return AnyTransition.scale(scale: 0.3).combined(with: .opacity)
            .animation(.spring(response: 0.26, dampingFraction: 0.72).delay(Double(itemIndex) * 0.014))
    }

    private var teamFan: some View {
        let themes = fans.teamThemes
        let fanLayout = fans.layout(of: .team)
        let emphasizedIndex = emphasizedItemIndex(currentItemIndex: themes.firstIndex(of: theme))
        return ZStack {
            ForEach(Array(themes.enumerated()), id: \.offset) { itemIndex, itemTheme in
                let isEmphasized = emphasizedIndex == itemIndex
                SettingsDialThemeBall(
                    theme: itemTheme,
                    size: isEmphasized ? SettingsDialGeometry.emphasizedFanBallDiameter : SettingsDialGeometry.fanBallDiameter
                )
                    .shadow(color: isEmphasized ? accentColor.opacity(0.7) : .clear, radius: 8)
                    .position(fanBallCenter(angleDegrees: fanLayout?.angleDegrees(ofItemAt: itemIndex) ?? 0))
                    // The enlarged ball draws over the smaller balls next to it.
                    .zIndex(isEmphasized ? 1 : 0)
                    .animation(viewModel.reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.8), value: isEmphasized)
                    .transition(fanItemTransition(forItemAt: itemIndex))
            }
            if let emphasizedIndex, themes.indices.contains(emphasizedIndex) {
                let ballCenter = fanBallCenter(angleDegrees: fanLayout?.angleDegrees(ofItemAt: emphasizedIndex) ?? 0)
                let ballCenterOffset = CGPoint(x: ballCenter.x - centerInView.x, y: ballCenter.y - centerInView.y)
                let ballRadius = SettingsDialGeometry.emphasizedFanBallDiameter / 2
                // A saved theme's long name is cut to fit inside the window, so the pill is never clipped at the edge.
                let labelText = SettingsDialLabel.fanLabelText(
                    themes[emphasizedIndex].name,
                    ballCenterOffset: ballCenterOffset,
                    ballRadius: ballRadius
                )
                let labelCenterOffset = SettingsDialLabel.fanLabelCenterOffset(
                    ballCenterOffset: ballCenterOffset,
                    ballRadius: ballRadius,
                    labelPillSize: SettingsDialLabel.pillSize(forText: labelText)
                )
                labelPill(labelText)
                    .position(x: centerInView.x + labelCenterOffset.x, y: centerInView.y + labelCenterOffset.y)
                    .zIndex(2)
                    .transition(.opacity)
            }
        }
    }

    /// The accent ring's inner disc on the selected Team token when it shows a custom cursor.
    private static let customCursorBackingDiameterOnTheSelectedToken: CGFloat = 32

    private func fanBallCenter(angleDegrees: Double) -> CGPoint {
        point(atAngleDegrees: angleDegrees, radius: SettingsDialGeometry.fanRadius)
    }

    private var modelFan: some View {
        let modelChoices = SettingsDialModelChoice.allCases
        let fanLayout = fans.layout(of: .model)
        let currentIndex = modelChoices.firstIndex { $0.modelID == viewModel.snapshot.modelID }
        let emphasizedIndex = emphasizedItemIndex(currentItemIndex: currentIndex)
        return ZStack {
            ForEach(Array(modelChoices.enumerated()), id: \.offset) { itemIndex, modelChoice in
                let isEmphasized = emphasizedIndex == itemIndex
                Text(modelChoice.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isEmphasized ? inkColor : Color.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(isEmphasized ? accentColor : tokenFillColor))
                    .overlay(Capsule().stroke(isEmphasized ? Color.clear : Color.white.opacity(0.14), lineWidth: 1))
                    .shadow(color: isEmphasized ? accentColor.opacity(0.55) : .clear, radius: 7)
                    .scaleEffect(isEmphasized ? 1.08 : 1)
                    .position(point(atAngleDegrees: fanLayout?.angleDegrees(ofItemAt: itemIndex) ?? 0, radius: SettingsDialGeometry.fanRadius))
                    .animation(viewModel.reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.8), value: isEmphasized)
                    .transition(fanItemTransition(forItemAt: itemIndex))
            }
        }
    }

    // MARK: Labels

    /// Text on its own dark pill, sized to the text, so a label never shows outside its background.
    private func labelPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: SettingsDialLabel.fontSize, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.92))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, SettingsDialLabel.horizontalPadding)
            .padding(.vertical, SettingsDialLabel.verticalPadding)
            .background(Capsule().fill(DS.Colors.settingsDialPlate.opacity(0.92)))
            .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    // MARK: Hint

    private var hint: some View {
        Text("hold ⇧⌥ · flick, release to pick")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.82))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).fill(DS.Colors.settingsDialPlate.opacity(0.84)))
            .fixedSize()
            // The mock puts the hint's top edge 16 points under the plate.
            .position(x: centerInView.x, y: centerInView.y + SettingsDialGeometry.plateRadius + 16 + 12)
    }
}

// MARK: - Balls

/// A theme's cursor drawn still, with no motion and no streaks, scaled so its longest side is at most `longestSide` points.
/// Shapes draw in the 24 point box and a picture in its own size, so the scale brings both to the same footprint. The
/// triangle keeps its 16 points, since a bigger one reads as a different cursor, and its pointer angle.
struct SettingsDialCustomCursor: View {
    let customTheme: ClickyTheme
    let picture: NSImage?
    let longestSide: CGFloat

    var body: some View {
        let naturalDrawingSize = CustomCursorView.drawingSize(of: customTheme, picture: picture)
        let naturalLongestSide = max(naturalDrawingSize.width, naturalDrawingSize.height)
        let drawnLongestSide = customTheme.cursor == .triangle ? min(longestSide, naturalLongestSide) : longestSide
        CustomCursorView(customTheme: customTheme, picture: picture, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
            .scaleEffect(drawnLongestSide / naturalLongestSide)
            .rotationEffect(.degrees(customTheme.cursorFacing == .pointerAngle ? -35 : 0))
            .frame(width: longestSide, height: longestSide)
    }
}

/// A theme in the Team fan: its own cursor, drawn still on a dark disc. The fan sits past the plate, over whatever page is
/// behind the dial, so the cursor gets a dark disc like the tokens have, and a pale cursor still reads over a light page.
private struct SettingsDialThemeBall: View {
    let theme: ClickyTheme
    let size: CGFloat

    /// How much of the disc a theme's cursor spans. A wide picture's corners stay inside the circle at this size.
    private static let cursorShareOfTheDisc: CGFloat = 0.72

    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.settingsDialToken)
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 1)
            SettingsDialCustomCursor(
                customTheme: theme,
                picture: theme.usesPicture ? CustomThemePictureCache.image(forThemeID: theme.id) : nil,
                longestSide: size * Self.cursorShareOfTheDisc
            )
        }
        .frame(width: size, height: size)
    }
}
