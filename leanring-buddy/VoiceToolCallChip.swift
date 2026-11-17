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
    /// `player` is the Haikyu!! player the agent was, so the chip shows the portrait instead of the triangle.
    case backgroundAgent(BackgroundAgentKind, player: HaikyuPlayer?)
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
        case .backgroundAgent(_, let player?):
            HaikyuPortraitView(player: player, size: 22)
                .overlay(Circle().stroke(player.school.accentColor, lineWidth: 2))
        case .backgroundAgent(let agentKind, nil):
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
        // Dark gray, readable inside the white outline whatever the team's color is.
        case .backgroundAgent(_, player: .some): return DS.Colors.backgroundAgentPlayerNameText
        case .backgroundAgent(let agentKind, nil): return agentKind.chipTextColor
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

    /// Whether team player wingmen trail the cursor now. CompanionManager sets it, since it owns the agent store.
    var avatarWingmenAreShowing: () -> Bool = { false }

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
        panel.setFrameOrigin(voiceToolCallChipOrigin(
            mouseLocation: NSEvent.mouseLocation,
            screenFrame: screenFrame,
            avatarWingmenAreShowing: avatarWingmenAreShowing()
        ))
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
/// status label sit, so neither covers it. While team player wingmen show, their portraits trail down and to the right
/// through that spot, so the chip moves above and to the right of the cursor, which the trail and the finished
/// player's hop up and to the left both leave empty. Where the screen's top edge leaves no room above, it goes below
/// the whole trail, past the "+N" label, instead of being pushed down onto the cursor.
func voiceToolCallChipOrigin(mouseLocation: CGPoint, screenFrame: CGRect, avatarWingmenAreShowing: Bool) -> CGPoint {
    let aboveTheCursor = CGPoint(x: 16, y: 12)
    let belowThePlayerTrail = CGPoint(x: 16, y: -lowestPlayerTrailPointBelowTheMouse - 6 - VoiceToolCallChip.panelSize.height)
    let underTheCursor = CGPoint(x: 35 - 19, y: -25 - 30 - 34)
    let distanceFromCursor: CGPoint
    if !avatarWingmenAreShowing {
        distanceFromCursor = underTheCursor
    } else if mouseLocation.y + aboveTheCursor.y + VoiceToolCallChip.panelSize.height <= screenFrame.maxY {
        distanceFromCursor = aboveTheCursor
    } else {
        distanceFromCursor = belowThePlayerTrail
    }
    return CGPoint(
        x: min(mouseLocation.x + distanceFromCursor.x, screenFrame.maxX - VoiceToolCallChip.panelSize.width),
        y: min(max(mouseLocation.y + distanceFromCursor.y, screenFrame.minY), screenFrame.maxY - VoiceToolCallChip.panelSize.height)
    )
}

/// How far below the mouse the player trail reaches: the bottom of the "+N" label, which sits in the slot after the
/// last wingman. The blue triangle's center is 25 points below the mouse (OverlayWindow's cursor offset), and every
/// wingman offset counts from that center.
var lowestPlayerTrailPointBelowTheMouse: CGFloat {
    let blueTriangleCenterBelowTheMouse: CGFloat = 25
    let overflowLabelHalfHeight: CGFloat = 8
    return blueTriangleCenterBelowTheMouse
        + WingmanStyle.avatar.offset(forSlot: WingmanFormation.mostWingmen).height
        + overflowLabelHalfHeight
}
