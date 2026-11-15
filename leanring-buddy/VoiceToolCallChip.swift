//
//  VoiceToolCallChip.swift
//  leanring-buddy
//
//  A small chip under the cursor that names each voice tool call, such as
//  rotate_model(yawDegrees: -45), then fades out. It uses the status label's look:
//  an icon on a white tile and colored letters with a white outline.
//  A background agent that ends shows its line here too, in the agent's color with its triangle as the icon,
//  so the learner sees which wingman it speaks for. It has a quieter second part and a longer stay.
//

import AppKit
import Combine
import SwiftUI

/// Who the chip speaks for, which sets its icon and letter color.
enum VoiceToolCallChipSender: Equatable {
    case voiceToolCall
    case backgroundAgent(BackgroundAgentKind)
}

@MainActor
private final class VoiceToolCallChipModel: ObservableObject {
    @Published var chipText = ""
    @Published var sender = VoiceToolCallChipSender.voiceToolCall
    /// A quieter second part after the main text, such as "· opened in a new tab".
    @Published var secondaryChipText: String?
    /// The call as code, set in a monospaced face, instead of a plain phrase.
    @Published var chipTextIsCode = false
    @Published var isVisible = false
}

private struct VoiceToolCallChipView: View {
    @ObservedObject var chipModel: VoiceToolCallChipModel

    var body: some View {
        ZStack(alignment: .leading) {
            if chipModel.isVisible {
                HStack(spacing: 6) {
                    chipIcon
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                        )
                    OutlinedChipText(chipText: chipModel.chipText, chipTextIsCode: chipModel.chipTextIsCode, textColor: chipTextColor)
                    if let secondaryChipText = chipModel.secondaryChipText {
                        OutlinedChipText(chipText: secondaryChipText, chipTextIsCode: false, textColor: DS.Colors.textTertiary)
                    }
                }
                .padding(.leading, 8)
                // A fade only, so it is the same with Reduce Motion on.
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chipModel.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder private var chipIcon: some View {
        switch chipModel.sender {
        case .voiceToolCall:
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.blue600)
        case .backgroundAgent(let agentKind):
            // The wingman's tilt, so the icon reads as the triangle beside the cursor.
            Triangle()
                .fill(agentKind.color)
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(-35))
        }
    }

    private var chipTextColor: Color {
        switch chipModel.sender {
        case .voiceToolCall: return DS.Colors.blue700
        case .backgroundAgent(let agentKind): return agentKind.chipTextColor
        }
    }
}

/// A white outline lets the letters read on light and dark pages without a pill behind them, like the status label.
private struct OutlinedChipText: View {
    let chipText: String
    let chipTextIsCode: Bool
    let textColor: Color

    private let outlineOffsets: [CGSize] = [
        CGSize(width: 1.5, height: 0), CGSize(width: -1.5, height: 0),
        CGSize(width: 0, height: 1.5), CGSize(width: 0, height: -1.5),
        CGSize(width: 1.1, height: 1.1), CGSize(width: -1.1, height: -1.1),
        CGSize(width: 1.1, height: -1.1), CGSize(width: -1.1, height: 1.1),
    ]

    var body: some View {
        let glyphs = Text(chipText).font(.system(size: chipTextIsCode ? 13 : 14, weight: .bold, design: chipTextIsCode ? .monospaced : .rounded))
        ZStack {
            ForEach(outlineOffsets.indices, id: \.self) { outlineIndex in
                glyphs.foregroundColor(.white).offset(outlineOffsets[outlineIndex])
            }
            glyphs.foregroundColor(textColor)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

@MainActor
final class VoiceToolCallChip {
    static let shared = VoiceToolCallChip()

    private static let panelSize = CGSize(width: 520, height: 34)
    /// Under the spot where Clicky's triangle and the status label sit, so neither covers the chip.
    private static let distanceFromCursor = CGPoint(x: 35 - 19, y: -25 - 30 - 34)
    nonisolated static let defaultSecondsOnScreen: TimeInterval = 1.4

    private let chipModel = VoiceToolCallChipModel()
    private var chipPanel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    /// A second call while a chip shows swaps the text and restarts its time on screen.
    func show(
        _ chipText: String,
        sender: VoiceToolCallChipSender = .voiceToolCall,
        secondaryChipText: String? = nil,
        chipTextIsCode: Bool = false,
        secondsOnScreen: TimeInterval = VoiceToolCallChip.defaultSecondsOnScreen
    ) {
        let panel = chipPanel ?? makeChipPanel()
        chipPanel = panel
        placeChipUnderTheCursor(panel)
        chipModel.chipText = chipText
        chipModel.sender = sender
        chipModel.secondaryChipText = secondaryChipText
        chipModel.chipTextIsCode = chipTextIsCode
        panel.orderFrontRegardless()
        chipModel.isVisible = true

        hideWorkItem?.cancel()
        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.chipModel.isVisible = false
        }
        self.hideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsOnScreen, execute: hideWorkItem)
    }

    private func placeChipUnderTheCursor(_ panel: NSPanel) {
        guard let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        let mouseLocation = NSEvent.mouseLocation
        let origin = CGPoint(
            x: min(mouseLocation.x + Self.distanceFromCursor.x, screenFrame.maxX - Self.panelSize.width),
            y: max(mouseLocation.y + Self.distanceFromCursor.y, screenFrame.minY)
        )
        panel.setFrameOrigin(origin)
    }

    private func makeChipPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: VoiceToolCallChipView(chipModel: chipModel))
        return panel
    }
}
