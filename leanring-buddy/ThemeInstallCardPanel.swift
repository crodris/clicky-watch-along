//
//  ThemeInstallCardPanel.swift
//  leanring-buddy
//
//  The "Add theme?" card: a Tether Card on a borderless, nonactivating panel near the top of the screen under the mouse. It
//  shows the theme's cursor, asks `Add "Moonlit" to Clicky?`, says how the theme moves, and has Cancel and Add theme buttons.
//  The panel never becomes key, so the app the learner was in keeps the keyboard, and Escape cancels it through the app's
//  Escape handling. The card has no origin to Glide out of, since a double-click in Finder gives the app no position, so it
//  grows in place with the Glide spring, or fades in with Reduce Motion on.
//

import AppKit
import SwiftUI

@MainActor
final class ThemeInstallCardPanelController: ThemeInstallCardPresenting {
    static let cardWidth: CGFloat = 340
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
    /// How far down the screen the card's top edge sits, as a share of the visible height.
    private static let shareOfTheScreenAboveTheCard: CGFloat = 0.2

    /// Readable by a test, which checks the window's frame and its mouse state.
    private(set) var panel: NonKeyFloatingPanel?
    /// Lets the mouse pass through the window's shadow margin to the app under it (`ShadowMarginMousePassThrough`).
    private var shadowMarginMouse: ShadowMarginMousePassThrough?
    /// Where the pointer is on screen. A test sets it, since the real pointer is wherever the learner left it.
    var mouseLocationOnScreen: () -> CGPoint = { NSEvent.mouseLocation } {
        didSet { shadowMarginMouse?.mouseLocationOnScreen = mouseLocationOnScreen }
    }
    /// A test sets this to put the card in a frame far off every screen, so no one sees it.
    var visibleFrameForTests: CGRect?

    func show(_ pendingInstall: PendingThemeInstall, decide: @escaping (Bool) -> Void) {
        hide()
        let visibleFrame = visibleFrameForTests ?? screenUnderTheMouseCursor()?.visibleFrame ?? .zero
        let hostingView = FirstMouseHostingView(rootView: ThemeInstallCardView(pendingInstall: pendingInstall, decide: decide))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        let windowSize = hostingView.fittingSize
        let cardTopLeft = CGPoint(
            x: visibleFrame.midX - Self.cardWidth / 2,
            y: visibleFrame.maxY - visibleFrame.height * Self.shareOfTheScreenAboveTheCard
        )
        let windowFrame = AgentListWindowMargins.windowFrame(cardTopLeft: cardTopLeft, windowSize: windowSize, visibleFrame: visibleFrame)

        let cardPanel = NonKeyFloatingPanel(contentRect: windowFrame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        // Not makeKeyAndOrderFront, which would take the keyboard from the app the learner was in.
        cardPanel.orderFrontRegardless()
        let mousePassThrough = ShadowMarginMousePassThrough(panel: cardPanel, mouseLocationOnScreen: mouseLocationOnScreen)
        mousePassThrough.start()
        shadowMarginMouse = mousePassThrough
    }

    func hide() {
        shadowMarginMouse?.stop()
        shadowMarginMouse = nil
        guard let closingPanel = panel else { return }
        panel = nil
        // The card fades for a moment, and a click on it then must not reach its buttons.
        closingPanel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = DS.Move.fadeSeconds
            closingPanel.animator().alphaValue = 0
        }, completionHandler: {
            closingPanel.orderOut(nil)
            closingPanel.contentView = nil
        })
    }
}

struct ThemeInstallCardView: View {
    let pendingInstall: PendingThemeInstall
    let decide: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false
    @State private var buttonsAcceptClicks = false

    private var theme: ClickyTheme { pendingInstall.theme }

    /// The card grows in place from this scale, since a double-click in Finder gives it no origin to Glide out of.
    private static let entranceStartScale: CGFloat = 0.97
    /// How long the buttons ignore clicks after the card appears, so the second click of a double-click that answered the
    /// card before cannot answer this one.
    private static let secondsTheButtonsIgnoreClicks = 0.4

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle().fill(DS.Colors.surface1)
                Circle().stroke(Color(hex: theme.accentHex), lineWidth: 1.5)
                SettingsDialCustomCursor(
                    customTheme: theme,
                    picture: pendingInstall.pictureJPEG.flatMap { NSImage(data: $0) },
                    longestSide: 36
                )
            }
            .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                Text(verbatim: themeInstallCardTitle(for: theme))
                    .font(DS.TypeScale.headline.font)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: themeInstallCardSummary(for: theme))
                    .font(DS.TypeScale.caption.font)
                    .foregroundColor(DS.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TetherButton("Cancel", role: .secondary, isEnabled: buttonsAcceptClicks) { decide(false) }
                TetherButton("Add theme", role: .primary(accent: Color(hex: theme.accentHex)), isEnabled: buttonsAcceptClicks) { decide(true) }
            }
            // The buttons dim while they wait, and come up to full strength with the same fade as every crossfade.
            .animation(.easeOut(duration: DS.Move.fadeSeconds), value: buttonsAcceptClicks)
        }
        .padding(20)
        .frame(width: ThemeInstallCardPanelController.cardWidth)
        .fixedSize(horizontal: false, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.card, style: .continuous))
        .tetherCard()
        .scaleEffect(hasAppeared || reduceMotion ? 1 : Self.entranceStartScale, anchor: .top)
        .opacity(hasAppeared ? 1 : 0)
        // The window is larger than the Card, so the Card's shadow has room to draw.
        .padding(EdgeInsets(
            top: AgentListWindowMargins.top,
            leading: AgentListWindowMargins.leading,
            bottom: AgentListWindowMargins.bottom,
            trailing: AgentListWindowMargins.trailing
        ))
        .onAppear {
            withAnimation(DS.Move.glide.animation(reduceMotionIsOn: reduceMotion)) { hasAppeared = true }
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.secondsTheButtonsIgnoreClicks))
            buttonsAcceptClicks = true
        }
    }
}
