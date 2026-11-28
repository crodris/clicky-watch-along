//
//  InstantReplayPanel.swift
//  leanring-buddy
//
//  The small control under a narrated pop-out: Replay before a replay, and Back, Replay, Next, the count, and End
//  during one. With Reduce Motion on it also lists every stop's sentence, the current one in bold. It is a borderless
//  nonactivating panel that never becomes key, like the agent list, so the page under it keeps the keyboard, and its
//  buttons take the first click. Like the "Add theme?" card, it grows in place with the Glide spring, or fades in with
//  Reduce Motion on, and fades out.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class InstantReplayPanelController {
    /// Above the pop-out's scene window and with the cursor overlay windows, so the control draws over the lifted model.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    /// Readable by a test, which checks the window's frame and that a hidden panel leaves the screen.
    private(set) var panel: NonKeyFloatingPanel?
    private var hostingView: FirstMouseHostingView<InstantReplayControlView>?
    private var mediaRectOnScreen: CGRect?
    private var visibleFrame: CGRect = .zero
    private var replayChangeSubscription: AnyCancellable?
    /// Bumped by every show and hide. An update queued for an earlier one, which may be another replay controller's,
    /// draws nothing.
    private var showGeneration = 0
    /// Lets the window pass the mouse to the page through its shadow margin (`ShadowMarginMousePassThrough`). The control can
    /// stay up for minutes, and the helper reads the mouse only while the pointer is near the window.
    private var shadowMarginMouse: ShadowMarginMousePassThrough?
    /// Readable by a test, which checks that the timer runs only while the pointer is near the window and that it stops.
    var clickThroughTimer: Timer? { shadowMarginMouse?.clickThroughTimer }
    /// The view that reports the pointer entering the window, which a test reads.
    var pointerEntryView: PointerEntryNSView? { shadowMarginMouse?.pointerEntryView }
    /// Where the pointer is on screen. A test sets it, since the real pointer is wherever the learner left it.
    var mouseLocationOnScreen: () -> CGPoint = { NSEvent.mouseLocation } {
        didSet { shadowMarginMouse?.mouseLocationOnScreen = mouseLocationOnScreen }
    }
    private var stopWhatClickyIsSaying: () -> Void = {}
    private var accentHex = ""

    /// Shows the control under the media. A second call moves it to the newest media rect and takes the newest replay
    /// controller, accent, and stop closure.
    func show(
        for replayController: InstantReplayController,
        stopWhatClickyIsSaying: @escaping () -> Void,
        accentHex: String,
        mediaRectOnScreen: CGRect,
        visibleFrame: CGRect
    ) {
        showGeneration += 1
        let generationOfThisShow = showGeneration
        self.mediaRectOnScreen = mediaRectOnScreen
        self.visibleFrame = visibleFrame
        self.stopWhatClickyIsSaying = stopWhatClickyIsSaying
        self.accentHex = accentHex
        if let hostingView {
            hostingView.rootView = controlView(for: replayController)
        } else {
            makeThePanel(showing: controlView(for: replayController))
        }
        // The content grows from Replay alone to the full row and the Reduce Motion list, so the view and the frame follow
        // it. objectWillChange fires before the new value is stored, so both are read on the next turn.
        replayChangeSubscription = replayController.objectWillChange.sink { [weak self, weak replayController] _ in
            DispatchQueue.main.async {
                guard let self, let replayController, generationOfThisShow == self.showGeneration else { return }
                self.hostingView?.rootView = self.controlView(for: replayController)
                self.placeThePanel()
            }
        }
        placeThePanel()
        // Not makeKeyAndOrderFront, which would take the keyboard from Chrome.
        panel?.orderFrontRegardless()
    }

    private func makeThePanel(showing controlView: InstantReplayControlView) {
        let controlHostingView = FirstMouseHostingView(rootView: controlView)
        controlHostingView.wantsLayer = true
        controlHostingView.layer?.backgroundColor = .clear
        let controlPanel = NonKeyFloatingPanel(
            contentRect: CGRect(origin: .zero, size: controlHostingView.fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlPanel.isOpaque = false
        controlPanel.backgroundColor = .clear
        controlPanel.hasShadow = false
        controlPanel.level = Self.panelLevel
        controlPanel.hidesOnDeactivate = false
        controlPanel.isReleasedWhenClosed = false
        controlPanel.isExcludedFromWindowsMenu = true
        controlPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        controlPanel.contentView = controlHostingView
        panel = controlPanel
        hostingView = controlHostingView
        let mousePassThrough = ShadowMarginMousePassThrough(panel: controlPanel, mouseLocationOnScreen: mouseLocationOnScreen)
        mousePassThrough.start()
        shadowMarginMouse = mousePassThrough
    }

    /// The control fades out showing what it showed last: it stops following the replay first, since the hide comes with the
    /// replay's end or its stops going away.
    func hide() {
        showGeneration += 1
        replayChangeSubscription = nil
        shadowMarginMouse?.stop()
        shadowMarginMouse = nil
        mediaRectOnScreen = nil
        hostingView = nil
        guard let closingPanel = panel else { return }
        panel = nil
        // The control fades for a moment, and a click on it then must not reach its buttons.
        closingPanel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = DS.Move.fadeSeconds
            closingPanel.animator().alphaValue = 0
        }, completionHandler: {
            closingPanel.orderOut(nil)
            closingPanel.contentView = nil
        })
    }

    /// Each click first stops an answer Clicky is still giving, so the replay never moves the camera under its words.
    private func controlView(for replayController: InstantReplayController) -> InstantReplayControlView {
        InstantReplayControlView(
            phase: replayController.phase,
            stops: replayController.stops,
            showsTheReduceMotionList: replayController.showsTheReduceMotionList,
            accentHex: accentHex,
            playFromTheStart: { [stopWhatClickyIsSaying, weak replayController] in
                stopWhatClickyIsSaying()
                replayController?.playFromTheStart()
            },
            step: { [stopWhatClickyIsSaying, weak replayController] replayStep in
                stopWhatClickyIsSaying()
                replayController?.step(replayStep)
            }
        )
    }

    private func placeThePanel() {
        guard let panel, let hostingView, let mediaRectOnScreen else { return }
        let windowSize = hostingView.fittingSize
        let cardOrigin = instantReplayControlOrigin(
            cardSize: CGSize(width: windowSize.width - AgentListWindowMargins.horizontal, height: windowSize.height - AgentListWindowMargins.vertical),
            mediaRectOnScreen: mediaRectOnScreen,
            visibleFrame: visibleFrame
        )
        let windowOrigin = CGPoint(x: cardOrigin.x - AgentListWindowMargins.leading, y: cardOrigin.y - AgentListWindowMargins.bottom)
        panel.setFrame(CGRect(origin: windowOrigin, size: windowSize), display: true)
        // At once, so the margin of a window that appeared or grew under the pointer never takes a click. A resize reports it
        // too, and a window that kept its frame still gets this check on each show.
        shadowMarginMouse?.update()
    }
}

/// The control as values, so a control that is fading out keeps showing what it showed.
struct InstantReplayControlView: View {
    let phase: InstantReplayPhase
    let stops: [ReplayStop]
    let showsTheReduceMotionList: Bool
    let accentHex: String
    let playFromTheStart: () -> Void
    let step: (InstantReplayStep) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    /// The control grows in place from this scale, as the "Add theme?" card does.
    private static let entranceStartScale: CGFloat = 0.97

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if phase.isOpen {
                    InstantReplayButton(label: .words("Back"), style: .plain) { step(.back) }
                    InstantReplayButton(label: .words("Replay"), style: .accent(accentHex: accentHex), action: playFromTheStart)
                    InstantReplayButton(label: .words("Next"), style: .plain) { step(.next) }
                } else {
                    InstantReplayButton(label: .words("Replay"), style: .accent(accentHex: accentHex), action: playFromTheStart)
                }
                Text(verbatim: instantReplayCountText(phase: phase, stopCount: stops.count))
                    .font(DS.TypeScale.caption.font)
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .fixedSize()
                if phase.isOpen {
                    InstantReplayButton(label: .symbol(systemName: "xmark", accessibilityLabel: "End replay"), style: .plain) { step(.end) }
                }
            }
            .padding(4)
            if phase.isOpen && showsTheReduceMotionList {
                InstantReplayStopList(stops: stops, currentStopIndex: phase.openStopIndex)
            }
        }
        .fixedSize()
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
    }
}

/// The Reduce Motion form: every stop's sentence in order, numbered like its label, with the current stop in bold.
private struct InstantReplayStopList: View {
    let stops: [ReplayStop]
    let currentStopIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(stops.enumerated()), id: \.offset) { stopIndex, stop in
                let isCurrentStop = stopIndex == currentStopIndex
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "\(stopIndex + 1)")
                        .font(DS.TypeScale.caption.font)
                        .monospacedDigit()
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(verbatim: stop.sentence)
                        .font(isCurrentStop ? DS.TypeScale.title.font : DS.TypeScale.body.font)
                        .foregroundColor(isCurrentStop ? DS.Colors.textPrimary : DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(width: 320, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

private enum InstantReplayButtonStyle {
    case accent(accentHex: String)
    case plain
}

private enum InstantReplayButtonLabel {
    case words(String)
    /// A symbol alone, which VoiceOver reads by the label.
    case symbol(systemName: String, accessibilityLabel: String)
}

private struct InstantReplayButton: View {
    let label: InstantReplayButtonLabel
    let style: InstantReplayButtonStyle
    let action: () -> Void

    @State private var isHovered = false

    private var fillColor: Color {
        switch style {
        case .accent(let accentHex): return Color(hex: accentHex)
        case .plain: return isHovered ? DS.Colors.surface4 : DS.Colors.surface3
        }
    }

    private var isFilledWithAnAccent: Bool {
        if case .accent = style { return true }
        return false
    }

    private var letterColor: Color {
        switch style {
        case .accent(let accentHex): return Color(hex: ThemeRGBColor.inkHex(onFillHex: accentHex))
        case .plain: return DS.Colors.textPrimary
        }
    }

    var body: some View {
        Button(action: action) {
            labelContent
                .foregroundColor(letterColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(fillColor))
                .accentFillHoverRing(Capsule(), ink: letterColor, isShowing: isFilledWithAnAccent && isHovered)
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenLabel)
        .hoverAndPointer { isHovered = $0 }
    }

    @ViewBuilder private var labelContent: some View {
        switch label {
        case .words(let words):
            Text(verbatim: words)
                .font(DS.TypeScale.title.font)
        case .symbol(let systemName, _):
            // The blank line of title type keeps this capsule as tall as the buttons with words.
            ZStack {
                Text(verbatim: " ")
                    .font(DS.TypeScale.title.font)
                Image(systemName: systemName)
                    .font(DS.TypeScale.caption.font)
            }
        }
    }

    private var spokenLabel: String {
        switch label {
        case .words(let words): return words
        case .symbol(_, let accessibilityLabel): return accessibilityLabel
        }
    }
}
