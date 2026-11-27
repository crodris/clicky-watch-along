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

    /// How far outside the window's frame the pointer still counts as near it, so a pointer on the frame's edge does.
    private static let pointerNearDistance: CGFloat = 8

    /// Readable by a test, which checks the window's frame and that a hidden panel leaves the screen.
    private(set) var panel: NonKeyFloatingPanel?
    private var hostingView: PointerWatchingHostingView?
    private var mediaRectOnScreen: CGRect?
    private var visibleFrame: CGRect = .zero
    private var replayChangeSubscription: AnyCancellable?
    /// Reads the mouse 60 times a second, only while the pointer is near the window, to let it pass through the shadow
    /// margin to the page (`letTheMousePassThroughTheShadow`). Readable by a test, which checks that it stops.
    private(set) var clickThroughTimer: Timer?
    /// Where the pointer is on screen. A test sets it, since the real pointer is wherever the learner left it.
    var mouseLocationOnScreen: () -> CGPoint = { NSEvent.mouseLocation }
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
                guard let self, let replayController else { return }
                self.hostingView?.rootView = self.controlView(for: replayController)
                self.placeThePanel()
            }
        }
        placeThePanel()
        // Not makeKeyAndOrderFront, which would take the keyboard from Chrome.
        panel?.orderFrontRegardless()
    }

    private func makeThePanel(showing controlView: InstantReplayControlView) {
        let controlHostingView = PointerWatchingHostingView(rootView: controlView)
        controlHostingView.pointerEntered = { [weak self] in self?.letTheMousePassThroughTheShadow() }
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
        // Watching before the window first shows, not from AppKit's first pass over it.
        controlHostingView.updateTrackingAreas()
        panel = controlPanel
        hostingView = controlHostingView
    }

    /// The control fades out showing what it showed last: it stops following the replay first, since the hide comes with the
    /// replay's end or its stops going away.
    func hide() {
        replayChangeSubscription = nil
        stopReadingTheMouse()
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
        // At once, so the margin of a window that appeared or grew under the pointer never takes a click.
        letTheMousePassThroughTheShadow()
    }

    /// Lets the window pass the mouse to the page while the pointer is in its shadow margin
    /// (`AgentListWindowMargins.windowPassesTheMouseThrough`). The control can stay up for minutes, so the mouse is read
    /// only while the pointer is near the window. Away from it the window takes the mouse, which lets its tracking area
    /// report the pointer's return. A window that ignores the mouse reports nothing.
    private func letTheMousePassThroughTheShadow() {
        guard let panel, let hostingView else { return }
        let mouseLocation = mouseLocationOnScreen()
        let pointerIsNear = panel.frame.insetBy(dx: -Self.pointerNearDistance, dy: -Self.pointerNearDistance).contains(mouseLocation)
        let passesTheMouseThrough = pointerIsNear
            && AgentListWindowMargins.windowPassesTheMouseThrough(at: mouseLocation, windowFrame: panel.frame)
        if panel.ignoresMouseEvents != passesTheMouseThrough {
            panel.ignoresMouseEvents = passesTheMouseThrough
            // The tracking area missed the moves made while the window ignored the mouse, so it starts over.
            if !passesTheMouseThrough { hostingView.updateTrackingAreas() }
            refreshTheRowHovers(in: hostingView, windowPassesTheMouseThrough: passesTheMouseThrough)
        }
        if pointerIsNear {
            startReadingTheMouse()
        } else {
            stopReadingTheMouse()
        }
    }

    private func startReadingTheMouse() {
        guard clickThroughTimer == nil else { return }
        // The run loop keeps the timer, so a timer that outlives this controller ends itself.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.letTheMousePassThroughTheShadow() }
        }
        // The common modes keep it running while a menu or a drag tracks the mouse.
        RunLoop.main.add(timer, forMode: .common)
        clickThroughTimer = timer
    }

    private func stopReadingTheMouse() {
        clickThroughTimer?.invalidate()
        clickThroughTimer = nil
    }
}

/// The control's hosting view, which reports the pointer entering the window.
private final class PointerWatchingHostingView: FirstMouseHostingView<InstantReplayControlView> {
    var pointerEntered: () -> Void = {}
    private var entryTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let entryTrackingArea { removeTrackingArea(entryTrackingArea) }
        // Always active, since the panel is never key.
        let trackingArea = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        entryTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        pointerEntered()
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
        case .accent(let accentHex): return Color(hex: accentHex).opacity(isHovered ? 0.85 : 1)
        case .plain: return isHovered ? DS.Colors.surface4 : DS.Colors.surface3
        }
    }

    private var letterColor: Color {
        switch style {
        // Near-black ink reads on every accent, Clicky blue included, as on the Callout's icon disc.
        case .accent: return DS.Colors.inkOnAccent
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
