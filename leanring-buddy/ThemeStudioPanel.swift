//
//  ThemeStudioPanel.swift
//  leanring-buddy
//
//  The Theme Studio card: a borderless, nonactivating panel next to the cursor that shows three theme ideas. It never
//  becomes key, so Chrome keeps the keyboard, and it sits one level below the cursor overlay windows, so the real cursor,
//  which previews the highlighted idea, draws over it. A tile click picks an idea, and Save and Close are buttons. The
//  learner can do all of it by voice too (the router's pick_theme_idea, save_theme, and close_theme_studio tools).
//

import AppKit
import SwiftUI

// MARK: - Panel

@MainActor
final class ThemeStudioPanelController {
    static let cardWidth: CGFloat = 440
    /// The card at its tallest, which keeps it clear of the pointer when it opens before the ideas arrive.
    static let tallestCardHeight: CGFloat = 360
    /// Far enough from the mouse that the cursor glyph, which sits 35 points right of the pointer and 25 below it, and the
    /// tool chip under it ("Trying idea 2"), which ends about 82 points below the pointer, both show above the card.
    private static let gapFromTheMouse: CGFloat = 96
    /// Below the cursor overlay windows (one level above screen saver), so the previewed cursor is never under the card.
    private static let panelLevel = NSWindow.Level.screenSaver

    /// Called with what a click on Save did, so the app can say so the way it does for the voice tool.
    private let onSaveClicked: (ThemeStudioController.SaveOutcome) -> Void

    private var panel: NonKeyFloatingPanel?
    /// Where the card's top-left corner sits, fixed when it opens so a taller card grows downward.
    private var anchorTopLeft: CGPoint = .zero
    private var visibleFrame: CGRect = .zero
    private var resizeObserver: NSObjectProtocol?

    init(onSaveClicked: @escaping (ThemeStudioController.SaveOutcome) -> Void) {
        self.onSaveClicked = onSaveClicked
    }

    func show(studio: ThemeStudioController) {
        guard panel == nil else { return }
        let mouseLocation = NSEvent.mouseLocation
        visibleFrame = screenUnderTheMouseCursor()?.visibleFrame ?? .zero
        anchorTopLeft = approvalListAnchorTopLeft(
            mouseLocation: mouseLocation,
            panelSize: CGSize(width: Self.cardWidth, height: Self.tallestCardHeight),
            visibleFrame: visibleFrame,
            gapFromTheMouse: Self.gapFromTheMouse
        )

        let cardView = ThemeStudioCardView(
            studio: studio,
            onSaveClicked: onSaveClicked,
            onContentSizeChange: { [weak self] contentSize in
                self?.resizePanel(to: contentSize)
            }
        )
        let hostingView = FirstMouseHostingView(rootView: cardView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let initialSize = CGSize(width: Self.cardWidth, height: min(hostingView.fittingSize.height, Self.tallestCardHeight))

        let cardPanel = NonKeyFloatingPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        cardPanel.isOpaque = false
        cardPanel.backgroundColor = .clear
        cardPanel.hasShadow = false
        cardPanel.level = Self.panelLevel
        cardPanel.hidesOnDeactivate = false
        cardPanel.isReleasedWhenClosed = false
        cardPanel.isExcludedFromWindowsMenu = true
        cardPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        cardPanel.contentView = hostingView
        panel = cardPanel
        resizeObserver = keepThePanelOnScreenAsItResizes(cardPanel) { [weak self] in
            (self?.anchorTopLeft ?? .zero, self?.visibleFrame ?? .zero)
        }
        resizePanel(to: initialSize)
        // Not makeKeyAndOrderFront, which would take the keyboard from Chrome.
        cardPanel.orderFrontRegardless()
    }

    func hide() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func resizePanel(to contentSize: CGSize) {
        guard let panel else { return }
        let panelSize = CGSize(width: Self.cardWidth, height: min(contentSize.height, Self.tallestCardHeight))
        let panelOrigin = agentListPanelOrigin(anchorTopLeft: anchorTopLeft, panelSize: panelSize, visibleFrame: visibleFrame)
        panel.setFrame(CGRect(origin: panelOrigin, size: panelSize), display: true)
    }
}

// MARK: - Card

private struct ThemeStudioCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct ThemeStudioCardView: View {
    @ObservedObject var studio: ThemeStudioController
    let onSaveClicked: (ThemeStudioController.SaveOutcome) -> Void
    let onContentSizeChange: (CGSize) -> Void

    private static let hint = "Say one, two, or three · or what to change · say save it"

    private var ideasOnTheCard: ThemeStudioIdeas? { studio.state.ideasOnTheCard }

    private var highlightedIdea: ClickyTheme? {
        guard case .showingIdeas(let ideas) = studio.state else { return nil }
        return ideas.highlightedIdea
    }

    private var pictureForTheCard: NSImage? {
        ideasOnTheCard?.picture.flatMap { NSImage(data: $0.jpegData) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            tiles
            if let highlightedIdea {
                ThemeStudioTagsView(tags: themeStudioTags(for: highlightedIdea))
            }
            Text(Self.hint)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            buttons
        }
        .padding(14)
        .frame(width: ThemeStudioPanelController.cardWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Colors.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: ThemeStudioCardSizePreferenceKey.self, value: geometryProxy.size)
            }
        )
        .onPreferenceChange(ThemeStudioCardSizePreferenceKey.self) { contentSize in
            onContentSizeChange(contentSize)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(ideasOnTheCard?.title ?? "Designing your theme")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if studio.state.isDesigning {
                Text("Designing…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            } else if case .showingIdeas(let ideas) = studio.state {
                Text("\(ideas.highlightedIdeaIndex + 1) / \(ideas.ideas.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    /// Three tiles in a row. With no ideas yet they are shimmering placeholders, and while a new design runs the old ideas
    /// stay in their places, dimmed.
    private var tiles: some View {
        HStack(alignment: .top, spacing: 10) {
            if let ideasOnTheCard {
                ForEach(Array(ideasOnTheCard.ideas.enumerated()), id: \.offset) { ideaIndex, idea in
                    ThemeStudioTileView(
                        idea: idea,
                        picture: pictureForTheCard,
                        isHighlighted: ideaIndex == ideasOnTheCard.highlightedIdeaIndex,
                        isDimmedWhileDesigning: studio.state.isDesigning,
                        pick: { studio.pickIdea(number: ideaIndex + 1) }
                    )
                }
            } else {
                ForEach(0..<3, id: \.self) { _ in
                    ThemeStudioPlaceholderTileView()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            ThemeStudioButton(
                title: "Save",
                style: .primary(accentHex: highlightedIdea?.accentHex),
                isEnabled: studio.state.isShowingIdeas
            ) {
                onSaveClicked(studio.saveTheHighlightedIdea())
            }
            ThemeStudioButton(title: "Close", style: .plain, isEnabled: true) {
                studio.close()
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Tiles

/// One idea: its cursor, its name, its colors as swatches, and a small agent token in its first agent color.
private struct ThemeStudioTileView: View {
    let idea: ClickyTheme
    let picture: NSImage?
    let isHighlighted: Bool
    let isDimmedWhileDesigning: Bool
    let pick: () -> Void

    @State private var isHovered = false

    private static let tileWidth: CGFloat = (ThemeStudioPanelController.cardWidth - 28 - 20) / 3
    private var accentColor: Color { Color(hex: idea.accentHex) }

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                // The cursor at about 1.6 times its real size, so a learner can see what it is.
                CustomCursorView(customTheme: idea, picture: picture, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
                    .scaleEffect(1.6)
                    .frame(width: 56, height: 56)
                Text(idea.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 3) {
                    ForEach(Array(([Color(hex: idea.accentHex)] + idea.agentColorsInOrder.prefix(3).map(\.color)).enumerated()), id: \.offset) { _, swatchColor in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(swatchColor)
                            .frame(width: 8, height: 8)
                    }
                    Spacer(minLength: 4)
                    ThemeStudioAgentTokenView(idea: idea, picture: picture)
                }
            }
            .padding(10)
            .frame(width: Self.tileWidth)
            .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(isHovered && !isDimmedWhileDesigning ? DS.Colors.surface4 : DS.Colors.surface3))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium)
                    .stroke(isHighlighted ? accentColor : DS.Colors.borderSubtle, lineWidth: isHighlighted ? 1.5 : 1)
            )
            .opacity(isDimmedWhileDesigning ? 0.4 : (isHighlighted ? 1 : 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDimmedWhileDesigning)
        .hoverAndPointer(isEnabled: !isDimmedWhileDesigning) { isHovered = $0 }
        .accessibilityLabel("\(idea.name), idea")
    }
}

/// An agent token in the idea's first agent color: a dark disc with a ring, and the picture or a triangle for its face.
private struct ThemeStudioAgentTokenView: View {
    let idea: ClickyTheme
    let picture: NSImage?

    private static let diameter: CGFloat = 18
    private static let ringWidth: CGFloat = 2
    private var firstAgentColor: Color { idea.agentColorsInOrder.first?.color ?? Color(hex: idea.accentHex) }

    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.agentTokenTrack)
            Circle()
                .stroke(firstAgentColor, lineWidth: Self.ringWidth)
                .padding(Self.ringWidth / 2)
            if idea.agents.faces == .picture, let picture {
                ThemePictureFaceView(picture: picture, size: Self.diameter - 2 * Self.ringWidth)
            } else {
                Triangle()
                    .fill(firstAgentColor)
                    .frame(width: 8, height: 8)
                    .rotationEffect(.degrees(-35))
            }
        }
        .frame(width: Self.diameter, height: Self.diameter)
    }
}

/// A tile that is waiting for the Worker's ideas: three gray bars that shimmer. With Reduce Motion it holds still.
private struct ThemeStudioPlaceholderTileView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let tileWidth: CGFloat = (ThemeStudioPanelController.cardWidth - 28 - 20) / 3

    var body: some View {
        VStack(spacing: 8) {
            ShimmerBar(reduceMotion: reduceMotion, cornerRadius: 28).frame(width: 56, height: 56)
            ShimmerBar(reduceMotion: reduceMotion, cornerRadius: 3).frame(width: 60, height: 10)
            ShimmerBar(reduceMotion: reduceMotion, cornerRadius: 2).frame(width: 52, height: 8)
        }
        .padding(10)
        .frame(width: Self.tileWidth)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(DS.Colors.surface3))
        .overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).stroke(DS.Colors.borderSubtle, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

private struct ShimmerBar: View {
    let reduceMotion: Bool
    let cornerRadius: CGFloat

    var body: some View {
        if reduceMotion {
            RoundedRectangle(cornerRadius: cornerRadius).fill(DS.Colors.surface4)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timelineContext in
                // A lighter band sweeps across every 1.4 seconds.
                let sweep = timelineContext.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: DS.Colors.surface4, location: max(0, sweep - 0.3)),
                                .init(color: DS.Colors.borderSubtle, location: sweep),
                                .init(color: DS.Colors.surface4, location: min(1, sweep + 0.3)),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
    }
}

// MARK: - Tags

private struct ThemeStudioTagsView: View {
    let tags: [String]

    var body: some View {
        WrappingTagsLayout(spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(DS.Colors.surface3))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays its children out left to right and wraps to a new line when the next one would pass the width it is offered.
private struct WrappingTagsLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(in: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrangement(in: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, arrangement.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrangement(in width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var rowOrigin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let subviewSize = subview.sizeThatFits(.unspecified)
            if rowOrigin.x > 0 && rowOrigin.x + subviewSize.width > width {
                rowOrigin = CGPoint(x: 0, y: rowOrigin.y + rowHeight + spacing)
                rowHeight = 0
            }
            origins.append(rowOrigin)
            rowOrigin.x += subviewSize.width + spacing
            rowHeight = max(rowHeight, subviewSize.height)
            widestRow = max(widestRow, rowOrigin.x - spacing)
        }
        return (CGSize(width: widestRow, height: rowOrigin.y + rowHeight), origins)
    }
}

// MARK: - Buttons

private enum ThemeStudioButtonStyle {
    /// Filled with the highlighted idea's accent, with letters that read on it. With no idea yet, a neutral fill.
    case primary(accentHex: String?)
    case plain
}

private struct ThemeStudioButton: View {
    let title: String
    let style: ThemeStudioButtonStyle
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var fillColor: Color {
        switch style {
        case .primary(let accentHex?): return Color(hex: accentHex).opacity(isHovered && isEnabled ? 0.85 : 1)
        case .primary(nil), .plain: return isHovered && isEnabled ? DS.Colors.surface4 : DS.Colors.surface3
        }
    }

    private var letterColor: Color {
        switch style {
        case .primary(let accentHex?):
            let accentReadsBetterWithDarkInk = ThemeRGBColor(hex: accentHex)?.readsBetterWithDarkInk ?? false
            return accentReadsBetterWithDarkInk ? Color(hex: "#111111") : .white
        case .primary(nil), .plain:
            return DS.Colors.textPrimary
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(letterColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium).fill(fillColor))
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .hoverAndPointer(isEnabled: isEnabled) { isHovered = $0 }
    }
}
