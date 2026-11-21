//
//  InstantReplayPanel.swift
//  leanring-buddy
//
//  The small control under a narrated pop-out: Replay before a replay, and Back, Replay, Next, the count, and End
//  during one. With Reduce Motion on it also lists every stop's sentence, the current one in bold. It is a borderless
//  nonactivating panel that never becomes key, like the agent list, so the page under it keeps the keyboard, and its
//  buttons take the first click.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class InstantReplayPanelController {
    /// Above the pop-out's scene window and with the cursor overlay windows, so the control draws over the lifted model.
    private static let panelLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    private var panel: NonKeyFloatingPanel?
    private var hostingView: NSView?
    private var mediaRectOnScreen: CGRect?
    private var visibleFrame: CGRect = .zero
    private var replayChangeSubscription: AnyCancellable?

    /// Shows the control under the media. A second call moves it to the newest media rect.
    func show(
        for replayController: InstantReplayController,
        stopWhatClickyIsSaying: @escaping () -> Void,
        accentHex: String,
        mediaRectOnScreen: CGRect,
        visibleFrame: CGRect
    ) {
        self.mediaRectOnScreen = mediaRectOnScreen
        self.visibleFrame = visibleFrame
        if panel == nil {
            let controlView = InstantReplayControlView(replay: replayController, stopWhatClickyIsSaying: stopWhatClickyIsSaying, accentHex: accentHex)
            let firstMouseHostingView = FirstMouseHostingView(rootView: controlView)
            firstMouseHostingView.wantsLayer = true
            firstMouseHostingView.layer?.backgroundColor = .clear
            let controlPanel = NonKeyFloatingPanel(
                contentRect: CGRect(origin: .zero, size: firstMouseHostingView.fittingSize),
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
            controlPanel.contentView = firstMouseHostingView
            panel = controlPanel
            hostingView = firstMouseHostingView
            // The content grows from Replay alone to the full row and the Reduce Motion list, so the frame follows it.
            // objectWillChange fires before the new value is stored, so the frame is measured on the next turn.
            replayChangeSubscription = replayController.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.placeThePanel() }
            }
        }
        placeThePanel()
        // Not makeKeyAndOrderFront, which would take the keyboard from Chrome.
        panel?.orderFrontRegardless()
    }

    func hide() {
        replayChangeSubscription = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
        mediaRectOnScreen = nil
    }

    private func placeThePanel() {
        guard let panel, let hostingView, let mediaRectOnScreen else { return }
        let windowSize = hostingView.fittingSize
        let origin = instantReplayControlOrigin(
            windowSize: windowSize,
            shadowMargin: InstantReplayControlView.shadowMargin,
            mediaRectOnScreen: mediaRectOnScreen,
            visibleFrame: visibleFrame
        )
        panel.setFrame(CGRect(origin: origin, size: windowSize), display: true)
    }
}

private struct InstantReplayControlView: View {
    /// The Card's shadow needs room inside the window, or the window edge clips it.
    static let shadowMargin: CGFloat = 12

    @ObservedObject var replay: InstantReplayController
    /// Each click first stops an answer Clicky is still giving, so the replay never moves the camera under its words.
    let stopWhatClickyIsSaying: () -> Void
    let accentHex: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if replay.isOpen {
                    InstantReplayButton(title: "Back", style: .plain) { stopWhatClickyIsSaying(); replay.step(.back) }
                    InstantReplayButton(title: "Replay", style: .accent(accentHex: accentHex)) { stopWhatClickyIsSaying(); replay.playFromTheStart() }
                    InstantReplayButton(title: "Next", style: .plain) { stopWhatClickyIsSaying(); replay.step(.next) }
                } else {
                    InstantReplayButton(title: "Replay", style: .accent(accentHex: accentHex)) { stopWhatClickyIsSaying(); replay.playFromTheStart() }
                }
                Text(verbatim: instantReplayCountText(phase: replay.phase, stopCount: replay.stops.count))
                    .font(DS.TypeScale.caption.font)
                    .monospacedDigit()
                    .foregroundColor(DS.Colors.textSecondary)
                    .padding(.horizontal, 6)
                    .fixedSize()
                if replay.isOpen {
                    InstantReplayButton(title: "✕", style: .plain, accessibilityLabel: "End replay") { stopWhatClickyIsSaying(); replay.step(.end) }
                }
            }
            .padding(4)
            if replay.isOpen && replay.showsTheReduceMotionList {
                InstantReplayStopList(stops: replay.stops, currentStopIndex: replay.phase.openStopIndex)
            }
        }
        .fixedSize()
        .tetherCard()
        .padding(Self.shadowMargin)
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

private struct InstantReplayButton: View {
    let title: String
    let style: InstantReplayButtonStyle
    var accessibilityLabel: String?
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
            Text(verbatim: title)
                .font(DS.TypeScale.title.font)
                .foregroundColor(letterColor)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(fillColor))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? title)
        .hoverAndPointer { isHovered = $0 }
    }
}
