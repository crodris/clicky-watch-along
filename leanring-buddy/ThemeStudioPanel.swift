//
//  ThemeStudioPanel.swift
//  leanring-buddy
//
//  The Theme Studio card: a borderless, nonactivating panel next to the cursor that shows three theme ideas. It never
//  becomes key, so Chrome keeps the keyboard, and it sits one level below the cursor overlay windows, so the real cursor,
//  which previews the highlighted idea, draws over it. A tile click picks an idea, and Save and Close are buttons. The
//  learner can do all of it by voice too (the router's pick_theme_idea, save_theme, and close_theme_studio tools).
//
//  The card is a Tether Card that Glides out of the cursor on the carrier panel and closes back into it. A save stamps the
//  saved tile, flies that idea's cursor into the real cursor, and then closes the card into it. With Reduce Motion on, the
//  card crossfades in place and no cursor flies. The window is larger than the Card by the agent list's transparent margin
//  (`AgentListWindowMargins`), where the Card's shadow draws.
//

import AppKit
import SwiftUI

// MARK: - Panel

@MainActor
final class ThemeStudioPanelController {
    static let cardWidth: CGFloat = 440
    /// The card at its tallest, which keeps it clear of the pointer when it opens before the ideas arrive.
    static let tallestCardHeight: CGFloat = 420
    /// Far enough from the mouse that the cursor glyph, which sits 35 points right of the pointer and 25 below it, and the
    /// tool chip above that glyph ("Trying idea 2"), which reaches about 40 points above the pointer, both show clear of the card.
    private static let gapFromTheMouse: CGFloat = 96
    /// Below the cursor overlay windows (one level above screen saver), so the previewed cursor is never under the card.
    /// The carrier's moves draw above the cursor, on their own panel.
    private static let panelLevel = NSWindow.Level.screenSaver
    /// How long the saved tile's stamp shows before its cursor leaves it.
    private static let secondsTheStampShowsBeforeTheCursorFlies = 0.15

    /// Called with what a click on Save did, so the app can say so the way it does for the voice tool.
    private let onSaveClicked: (ThemeStudioController.SaveOutcome) -> Void

    private var panel: NonKeyFloatingPanel?
    /// Where the Card's top-left corner sits, fixed when it opens so a taller card grows downward.
    private var anchorTopLeft: CGPoint = .zero
    private var visibleFrame: CGRect = .zero
    private var resizeObserver: NSObjectProtocol?
    /// The center of the highlighted tile's cursor in the window's coordinates (y grows down), which a save flies from.
    private var highlightedTileCursorCenterInTheWindow: CGPoint?
    private var openingFlight: CarrierFlight?
    /// The studio whose card this is, which a card that closes plays its move with.
    private weak var studio: ThemeStudioController?

    init(onSaveClicked: @escaping (ThemeStudioController.SaveOutcome) -> Void) {
        self.onSaveClicked = onSaveClicked
    }

    private var reduceMotionIsOn: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where the real cursor's glyph is, which the card Glides out of and closes into.
    private var cursorGlyphPoint: CGPoint { agentTokenServeStartPoint(mouseLocation: NSEvent.mouseLocation) }

    func show(studio: ThemeStudioController) {
        guard panel == nil else { return }
        self.studio = studio
        let mouseLocation = NSEvent.mouseLocation
        let screen = screenUnderTheMouseCursor()
        visibleFrame = screen?.visibleFrame ?? .zero
        anchorTopLeft = approvalListAnchorTopLeft(
            mouseLocation: mouseLocation,
            panelSize: CGSize(width: Self.cardWidth, height: Self.tallestCardHeight),
            visibleFrame: visibleFrame,
            gapFromTheMouse: Self.gapFromTheMouse
        )

        let hostingView = FirstMouseHostingView(rootView: makeCardView(studio: studio, landsTilesIn: true, reportsItsSize: true))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let initialSize = CGSize(
            width: Self.cardWidth + AgentListWindowMargins.horizontal,
            height: min(hostingView.fittingSize.height, Self.tallestCardHeight + AgentListWindowMargins.vertical)
        )

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
            (
                AgentListWindowMargins.windowTopLeft(forCardTopLeft: self?.anchorTopLeft ?? .zero),
                AgentListWindowMargins.frameToKeepTheWindowIn(forCardVisibleFrame: self?.visibleFrame ?? .zero)
            )
        }
        resizePanel(to: initialSize)
        showThePanel(cardPanel, studio: studio, screen: screen)
    }

    /// Glides the card out of the cursor on the carrier, with the real panel appearing at the landing, or crossfades it in
    /// place with Reduce Motion on. Never makeKeyAndOrderFront, which would take the keyboard from Chrome.
    private func showThePanel(_ cardPanel: NonKeyFloatingPanel, studio: ThemeStudioController, screen: NSScreen?) {
        guard let screen, !reduceMotionIsOn else {
            cardPanel.alphaValue = 0
            cardPanel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { animationContext in
                animationContext.duration = DS.Move.fadeSeconds
                cardPanel.animator().alphaValue = 1
            }
            return
        }
        let panelFrame = cardPanel.frame
        openingFlight = TetherCarrier.shared.play(
            .glideFromOrigin(cursorGlyphPoint, into: panelFrame),
            carrying: makeCardView(studio: studio, landsTilesIn: false, reportsItsSize: false)
                .frame(width: panelFrame.width, height: panelFrame.height, alignment: .top),
            onDisplay: screen.displayID,
            tetherColor: NSColor(studio.themeSettings.shownTheme.cursorColor),
            onLanded: { [weak self, weak cardPanel] in
                // A card closed before the landing is no longer this panel.
                guard let self, let cardPanel, self.panel === cardPanel else { return }
                self.openingFlight = nil
                cardPanel.orderFrontRegardless()
            }
        )
    }

    private func makeCardView(studio: ThemeStudioController, landsTilesIn: Bool, reportsItsSize: Bool) -> ThemeStudioCardView {
        ThemeStudioCardView(
            studio: studio,
            landsTilesIn: landsTilesIn,
            onSaveClicked: onSaveClicked,
            onHighlightedCursorCenterChange: { [weak self] cursorCenter in
                self?.highlightedTileCursorCenterInTheWindow = cursorCenter
            },
            onContentSizeChange: { [weak self] contentSize in
                guard reportsItsSize else { return }
                self?.resizePanel(to: contentSize)
            }
        )
    }

    func hide(because reason: ThemeStudioCardClosing) {
        guard let studio else { return }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
            self.resizeObserver = nil
        }
        let flightToEnd = openingFlight
        openingFlight = nil
        let closingPanel = panel
        let cursorCenterInTheWindow = highlightedTileCursorCenterInTheWindow
        panel = nil
        highlightedTileCursorCenterInTheWindow = nil
        flightToEnd?.landAtOnce()
        guard let closingPanel else { return }
        // The card stays on screen for the stamp and the flight, and a click on it then must not reach its buttons.
        closingPanel.ignoresMouseEvents = true

        switch reason {
        case .dismissed:
            closeIntoTheCursor(closingPanel, studio: studio)
        case .saved(let savedIdea, let pictureJPEG):
            guard !reduceMotionIsOn, let cursorCenterInTheWindow else {
                closeIntoTheCursor(closingPanel, studio: studio)
                return
            }
            flyTheSavedCursorIntoTheRealCursor(
                from: closingPanel,
                cursorCenterInTheWindow: cursorCenterInTheWindow,
                savedIdea: savedIdea,
                picture: pictureJPEG.flatMap { NSImage(data: $0) },
                studio: studio
            )
        }
    }

    /// Save: the stamp shows on the saved tile, then that idea's cursor flies from the tile into the real cursor on the
    /// carrier, and then the card closes into it.
    private func flyTheSavedCursorIntoTheRealCursor(
        from closingPanel: NonKeyFloatingPanel,
        cursorCenterInTheWindow: CGPoint,
        savedIdea: ClickyTheme,
        picture: NSImage?,
        studio: ThemeStudioController
    ) {
        let panelFrame = closingPanel.frame
        let tileCursorPoint = CGPoint(x: panelFrame.minX + cursorCenterInTheWindow.x, y: panelFrame.maxY - cursorCenterInTheWindow.y)
        let cursorSize = CustomCursorView.drawingSize(of: savedIdea, picture: picture)
        let screen = closingPanel.screen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsTheStampShowsBeforeTheCursorFlies) { [self] in
            guard let screen else {
                closeIntoTheCursor(closingPanel, studio: studio)
                return
            }
            TetherCarrier.shared.play(
                .send(along: agentTokenServePath(from: tileCursorPoint, to: cursorGlyphPoint), carriedSize: cursorSize),
                carrying: CustomCursorView(customTheme: savedIdea, picture: picture, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
                    .frame(width: cursorSize.width, height: cursorSize.height),
                onDisplay: screen.displayID,
                tetherColor: NSColor(Color(hex: savedIdea.accentHex)),
                onLanded: { [self] in closeIntoTheCursor(closingPanel, studio: studio) }
            )
        }
    }

    /// The Glide close: the card shrinks into the cursor at 0.7x with the tether line, or, with Reduce Motion on, fades out
    /// in place.
    private func closeIntoTheCursor(_ closingPanel: NonKeyFloatingPanel, studio: ThemeStudioController) {
        let closingFrame = closingPanel.frame
        guard !reduceMotionIsOn, let screen = closingPanel.screen else {
            NSAnimationContext.runAnimationGroup({ animationContext in
                animationContext.duration = DS.Move.fadeSeconds
                closingPanel.animator().alphaValue = 0
            }, completionHandler: {
                closingPanel.orderOut(nil)
                closingPanel.contentView = nil
            })
            return
        }
        // The carrier draws the Card for the move, so the real panel goes at once.
        closingPanel.orderOut(nil)
        closingPanel.contentView = nil
        TetherCarrier.shared.play(
            .glideClose(from: closingFrame, into: cursorGlyphPoint),
            carrying: makeCardView(studio: studio, landsTilesIn: false, reportsItsSize: false)
                .frame(width: closingFrame.width, height: closingFrame.height, alignment: .top),
            onDisplay: screen.displayID,
            tetherColor: NSColor(studio.themeSettings.shownTheme.cursorColor),
            onLanded: {}
        )
    }

    private func resizePanel(to contentSize: CGSize) {
        guard let panel else { return }
        let windowSize = CGSize(
            width: Self.cardWidth + AgentListWindowMargins.horizontal,
            height: min(contentSize.height, Self.tallestCardHeight + AgentListWindowMargins.vertical)
        )
        panel.setFrame(AgentListWindowMargins.windowFrame(cardTopLeft: anchorTopLeft, windowSize: windowSize, visibleFrame: visibleFrame), display: true)
    }
}

// MARK: - Card

private struct ThemeStudioCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The highlighted tile's cursor center in the window's coordinates, which a save flies from.
private struct HighlightedTileCursorCenterPreferenceKey: PreferenceKey {
    static var defaultValue: CGPoint?
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) {
        value = nextValue() ?? value
    }
}

private let themeStudioCardCoordinateSpaceName = "themeStudioCard"

struct ThemeStudioCardView: View {
    @ObservedObject var studio: ThemeStudioController
    /// Whether the tiles land 90 ms apart with a Pop when ideas arrive. The copy that plays on the carrier shows tiles in
    /// place, since its tiles already landed.
    let landsTilesIn: Bool
    let onSaveClicked: (ThemeStudioController.SaveOutcome) -> Void
    let onHighlightedCursorCenterChange: (CGPoint?) -> Void
    let onContentSizeChange: (CGSize) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let hint = "Say one, two, or three · or what to change · say save it"

    /// The state the card draws: the studio's, or its last open one while the card closes on the carrier.
    private var shownState: ThemeStudioState {
        studio.state.isOpen ? studio.state : studio.lastOpenState
    }

    private var ideasOnTheCard: ThemeStudioIdeas? { shownState.ideasOnTheCard }

    private var highlightedIdea: ClickyTheme? {
        guard case .showingIdeas(let ideas) = shownState else { return nil }
        return ideas.highlightedIdea
    }

    private var pictureForTheCard: NSImage? {
        ideasOnTheCard?.picture.flatMap { NSImage(data: $0.jpegData) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let pictureForTheCard {
                fromThePictureRow(picture: pictureForTheCard)
            }
            tiles
            if let highlightedIdea {
                ThemeStudioTagsView(tags: themeStudioTags(for: highlightedIdea))
            }
            if studio.showsTheDesignFailedNotice {
                TetherCallout(accent: DS.Colors.destructive, rim: .chip) {
                    Image(systemName: "xmark")
                } content: {
                    Text("Couldn't design that. Your ideas are still here.")
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
            Text(Self.hint)
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            buttons
        }
        .padding(14)
        .frame(width: ThemeStudioPanelController.cardWidth)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous))
        .tetherCard()
        .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotion), value: studio.showsTheDesignFailedNotice)
        // The window is larger than the Card, so the Card's shadow has room to draw.
        .padding(EdgeInsets(
            top: AgentListWindowMargins.top,
            leading: AgentListWindowMargins.leading,
            bottom: AgentListWindowMargins.bottom,
            trailing: AgentListWindowMargins.trailing
        ))
        .background(
            GeometryReader { geometryProxy in
                Color.clear.preference(key: ThemeStudioCardSizePreferenceKey.self, value: geometryProxy.size)
            }
        )
        .onPreferenceChange(ThemeStudioCardSizePreferenceKey.self) { contentSize in
            onContentSizeChange(contentSize)
        }
        .onPreferenceChange(HighlightedTileCursorCenterPreferenceKey.self) { cursorCenter in
            onHighlightedCursorCenterChange(cursorCenter)
        }
        .coordinateSpace(name: themeStudioCardCoordinateSpaceName)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(ideasOnTheCard?.title ?? "Designing your theme")
                .font(DS.TypeScale.title.font)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if shownState.isDesigning {
                Text("Designing…")
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
            } else if case .showingIdeas(let ideas) = shownState {
                Text("Trying \(ideas.highlightedIdeaIndex + 1) of \(ideas.ideas.count)")
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        }
    }

    /// A design from a picture says so, with the picture small beside the words.
    private func fromThePictureRow(picture: NSImage) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: picture)
                .resizable()
                .scaledToFill()
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            Text("From your picture")
                .font(DS.TypeScale.caption.font)
                .foregroundColor(DS.Colors.textSecondary)
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
                        ideaIndex: ideaIndex,
                        picture: pictureForTheCard,
                        isHighlighted: ideaIndex == ideasOnTheCard.highlightedIdeaIndex,
                        isDimmedWhileDesigning: shownState.isDesigning,
                        isStamped: studio.isStampingTheSavedIdea && ideaIndex == ideasOnTheCard.highlightedIdeaIndex,
                        landsIn: landsTilesIn,
                        pick: { studio.pickIdea(number: ideaIndex + 1) },
                        playSounds: { studio.playTheHighlightedIdeasSounds() }
                    )
                    // Each arrival of ideas is a new set of tiles, so they land again, even over ideas that were on show.
                    .id("\(studio.ideasArrivalCount)-\(ideaIndex)")
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
                isEnabled: shownState.isShowingIdeas
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

/// One idea: its cursor running its real thinking motion and streaks while it is the highlighted one, its name, its colors
/// as swatches, a small agent token in its first agent color, and, on the highlighted tile, a speaker button that plays the
/// idea's three sounds in a row.
/// The size of a tile: a tile that is not highlighted sits a little smaller, so picking it springs it up with its own idea's
/// Pop. With Reduce Motion on the size never changes.
nonisolated func themeStudioTileScale(isHighlighted: Bool, reduceMotionIsOn: Bool) -> CGFloat {
    isHighlighted || reduceMotionIsOn ? 1 : 0.92
}

private struct ThemeStudioTileView: View {
    let idea: ClickyTheme
    let ideaIndex: Int
    let picture: NSImage?
    let isHighlighted: Bool
    let isDimmedWhileDesigning: Bool
    /// True from a save until the card is gone: the tile shows a check stamp while its cursor flies out.
    let isStamped: Bool
    let landsIn: Bool
    let pick: () -> Void
    let playSounds: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var hasLanded: Bool

    /// The gap between one tile's landing and the next one's.
    private static let secondsBetweenLandings = 0.09
    private static let tileWidth: CGFloat = (ThemeStudioPanelController.cardWidth - 28 - 20) / 3
    /// A tile lands from this scale. It is larger than a Callout's Pop start (`DS.Move.popStartScale`), since a tile is
    /// large and a Pop from 0.4 would sweep over its neighbors.
    private static let landingStartScale: CGFloat = 0.85
    private var accentColor: Color { Color(hex: idea.accentHex) }

    /// Pop under this idea's own springs, not the shown theme's, so each tile previews the motion it would give the app.
    private var ideasOwnPop: Animation? {
        DS.Move.pop.animation(reduceMotionIsOn: reduceMotion, springs: idea.moveSprings)
    }

    init(
        idea: ClickyTheme,
        ideaIndex: Int,
        picture: NSImage?,
        isHighlighted: Bool,
        isDimmedWhileDesigning: Bool,
        isStamped: Bool,
        landsIn: Bool,
        pick: @escaping () -> Void,
        playSounds: @escaping () -> Void
    ) {
        self.idea = idea
        self.ideaIndex = ideaIndex
        self.picture = picture
        self.isHighlighted = isHighlighted
        self.isDimmedWhileDesigning = isDimmedWhileDesigning
        self.isStamped = isStamped
        self.landsIn = landsIn
        self.pick = pick
        self.playSounds = playSounds
        _hasLanded = State(initialValue: !landsIn)
    }

    /// The highlighted idea's cursor moves as it will on the real cursor: its thinking motion, and its streaks pulsing the
    /// way they do when the cursor moves. The others stay still.
    @ViewBuilder private var cursorOnTheTile: some View {
        if isHighlighted && !isDimmedWhileDesigning {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || idea.motion.trailStreaks == 0)) { timelineContext in
                let secondsIntoThePulse = timelineContext.date.timeIntervalSinceReferenceDate
                CustomCursorView(
                    customTheme: idea,
                    picture: picture,
                    streakOpacity: 0.55 + 0.45 * sin(secondsIntoThePulse * 2 * .pi / 1.6),
                    voiceState: .processing,
                    audioPowerLevel: 0
                )
            }
        } else {
            CustomCursorView(customTheme: idea, picture: picture, streakOpacity: 0, voiceState: .idle, audioPowerLevel: 0)
        }
    }

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                // The cursor at about 1.6 times its real size, so a learner can see what it is.
                cursorOnTheTile
                    .scaleEffect(1.6)
                    .frame(width: 56, height: 56)
                    .background(
                        GeometryReader { cursorProxy in
                            let cursorFrame = cursorProxy.frame(in: .named(themeStudioCardCoordinateSpaceName))
                            Color.clear.preference(
                                key: HighlightedTileCursorCenterPreferenceKey.self,
                                value: isHighlighted ? CGPoint(x: cursorFrame.midX, y: cursorFrame.midY) : nil
                            )
                        }
                    )
                Text(idea.name)
                    .font(DS.TypeScale.title.font)
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
        .overlay(alignment: .topTrailing) {
            if isHighlighted && !isDimmedWhileDesigning {
                SoundPreviewButton(accentColor: accentColor, playSounds: playSounds)
                    .padding(6)
            }
        }
        .overlay(alignment: .topLeading) {
            if isStamped {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(DS.Colors.inkOnAccent, accentColor)
                    .padding(6)
                    .transition(reduceMotion ? .opacity : .scale(scale: DS.Move.popStartScale).combined(with: .opacity))
            }
        }
        .animation(ideasOwnPop, value: isStamped)
        // A tile that is not the highlighted one sits a little smaller, and picking it springs it up with its own idea's Pop,
        // so a bouncy idea visibly overshoots and a calm one settles. With Reduce Motion the size never changes.
        .scaleEffect(themeStudioTileScale(isHighlighted: isHighlighted, reduceMotionIsOn: reduceMotion))
        .animation(ideasOwnPop, value: isHighlighted)
        // Each tile lands with a Pop, 90 ms after the one before it. With Reduce Motion it only fades in.
        .opacity(hasLanded ? 1 : 0)
        .scaleEffect(hasLanded || reduceMotion ? 1 : Self.landingStartScale)
        .onAppear {
            guard !hasLanded else { return }
            withAnimation(ideasOwnPop?.delay(Double(ideaIndex) * Self.secondsBetweenLandings)) {
                hasLanded = true
            }
        }
        .accessibilityLabel("\(idea.name), idea")
    }
}

/// The highlighted tile's speaker button, which plays the idea's three sounds in a row.
private struct SoundPreviewButton: View {
    let accentColor: Color
    let playSounds: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: playSounds) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isHovered ? accentColor : DS.Colors.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(isHovered ? DS.Colors.surface4 : DS.Colors.surface2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverAndPointer { isHovered = $0 }
        .accessibilityLabel("Hear this theme's sounds")
    }
}

/// An agent token in the idea's first agent color: a dark disc with a ring, and the picture or a triangle for its face,
/// with the dark edge and soft shadow the real disc has.
private struct ThemeStudioAgentTokenView: View {
    let idea: ClickyTheme
    let picture: NSImage?

    private static let diameter: CGFloat = 18
    private static let ringWidth: CGFloat = 2
    private static let edgeWidth: CGFloat = 1.5
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
        .overlay(Circle().stroke(Color.black.opacity(0.75), lineWidth: Self.edgeWidth).padding(-Self.edgeWidth / 2))
        .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1.5)
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

enum ThemeStudioButtonStyle {
    /// Filled with the highlighted idea's accent, with letters that read on it. With no idea yet, a neutral fill.
    case primary(accentHex: String?)
    case plain
}

struct ThemeStudioButton: View {
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
