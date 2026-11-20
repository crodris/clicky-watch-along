//
//  VoiceToolCallChip.swift
//  leanring-buddy
//
//  A small chip under the cursor that names each voice tool call, such as
//  rotate_model(yawDegrees: -45), then fades out. It uses the status label's look:
//  an icon on a white rounded-square tile, or a round portrait with no tile, and colored letters with a white outline.
//  A background agent that ends shows its line here too, in the agent's own color with its triangle as the icon,
//  so the learner sees which agent it speaks for. It has a quieter second part and a longer stay.
//

import AppKit
import Combine
import SwiftUI

/// Who the chip speaks for, which sets its icon and letter color.
enum VoiceToolCallChipSender: Equatable {
    case voiceToolCall
    /// `color` is the agent's own color, which tints the triangle and the letters. `player` is the Haikyu!! player the
    /// agent was, so the chip shows the portrait instead of the triangle.
    case backgroundAgent(color: AgentPaletteColor, player: HaikyuPlayer?)
}

/// The shape the chip's icon has, which is also the shape of whatever sits behind it. A white rounded square behind a
/// round portrait shows its corners around the circle, so a portrait gets no tile.
enum VoiceToolCallChipIconShape: Equatable {
    case roundedSquareTile
    case circularPortrait
}

extension VoiceToolCallChipSender {
    var iconShape: VoiceToolCallChipIconShape {
        switch self {
        case .backgroundAgent(_, player: .some): return .circularPortrait
        case .voiceToolCall, .backgroundAgent(_, player: nil): return .roundedSquareTile
        }
    }
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
                    VoiceToolCallChipIcon(sender: chipModel.sender)
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

    private var chipTextColor: Color {
        switch chipModel.sender {
        case .voiceToolCall: return DS.Colors.blue700
        // Dark gray, readable inside the white outline whatever the team's color is.
        case .backgroundAgent(_, player: .some): return DS.Colors.backgroundAgentPlayerNameText
        case .backgroundAgent(let agentColor, nil): return agentColor.chipTextColor
        }
    }
}

/// The chip's icon with whatever backs it, 22 points square. The backing follows the icon's shape (`iconShape`), so no
/// white shows outside a round portrait.
struct VoiceToolCallChipIcon: View {
    let sender: VoiceToolCallChipSender
    private static let iconSize: CGFloat = 22
    private static let shadowColor = Color.black.opacity(0.3)

    var body: some View {
        switch sender.iconShape {
        case .roundedSquareTile:
            symbolOrTriangle
                .frame(width: Self.iconSize, height: Self.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white)
                        .shadow(color: Self.shadowColor, radius: 3, x: 0, y: 2)
                )
        case .circularPortrait:
            portrait
        }
    }

    @ViewBuilder private var symbolOrTriangle: some View {
        switch sender {
        case .voiceToolCall:
            Image(systemName: "hand.point.up.left.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.blue600)
        case .backgroundAgent(let agentColor, _):
            // The cursor triangle's tilt, so the icon reads as the agent's triangle.
            Triangle()
                .fill(agentColor.color)
                .frame(width: 11, height: 11)
                .rotationEffect(.degrees(-35))
        }
    }

    @ViewBuilder private var portrait: some View {
        if case .backgroundAgent(_, let player?) = sender {
            // The ring is drawn inside the portrait's circle, and the shadow follows that circle, so nothing else shows.
            HaikyuPortraitView(player: player, size: Self.iconSize)
                .overlay(Circle().strokeBorder(player.school.accentColor, lineWidth: 2))
                .shadow(color: Self.shadowColor, radius: 3, x: 0, y: 2)
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

    nonisolated static let panelSize = CGSize(width: 520, height: 34)
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

    /// Hides the chip now, but only while it still shows `chipText`, so a newer chip is never cut short.
    func hide(ifShowing chipText: String) {
        guard chipModel.isVisible, chipModel.chipText == chipText else { return }
        hideWorkItem?.cancel()
        chipModel.isVisible = false
    }

    private func placeChipUnderTheCursor(_ panel: NSPanel) {
        guard let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        panel.setFrameOrigin(voiceToolCallChipOrigin(mouseLocation: NSEvent.mouseLocation, screenFrame: screenFrame))
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

/// The chip panel's bottom-left corner in AppKit screen points. It sits under the spot where Clicky's triangle and the
/// status label sit, so neither covers it, and stays inside the screen.
func voiceToolCallChipOrigin(mouseLocation: CGPoint, screenFrame: CGRect) -> CGPoint {
    let underTheCursor = CGPoint(x: 35 - 19, y: -25 - 30 - 34)
    return CGPoint(
        x: min(mouseLocation.x + underTheCursor.x, screenFrame.maxX - VoiceToolCallChip.panelSize.width),
        y: min(max(mouseLocation.y + underTheCursor.y, screenFrame.minY), screenFrame.maxY - VoiceToolCallChip.panelSize.height)
    )
}
