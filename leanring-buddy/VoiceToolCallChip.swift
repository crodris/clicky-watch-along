//
//  VoiceToolCallChip.swift
//  leanring-buddy
//
//  A small chip under the cursor that names each voice tool call, such as
//  rotate_model(yawDegrees: -45), then fades out. It uses the status label's look:
//  an icon on a white tile and colored letters with a white outline.
//

import AppKit
import Combine
import SwiftUI

@MainActor
private final class VoiceToolCallChipModel: ObservableObject {
    @Published var chipText = ""
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
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Colors.blue600)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
                        )
                    OutlinedChipText(chipText: chipModel.chipText, chipTextIsCode: chipModel.chipTextIsCode)
                }
                .padding(.leading, 8)
                // A fade only, so it is the same with Reduce Motion on.
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chipModel.isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A white outline lets the letters read on light and dark pages without a pill behind them, like the status label.
private struct OutlinedChipText: View {
    let chipText: String
    let chipTextIsCode: Bool

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
            glyphs.foregroundColor(DS.Colors.blue700)
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
    private static let secondsOnScreen: TimeInterval = 1.4

    private let chipModel = VoiceToolCallChipModel()
    private var chipPanel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?

    /// A second call while a chip shows swaps the text and restarts its time on screen.
    func show(_ chipText: String, chipTextIsCode: Bool = false) {
        let panel = chipPanel ?? makeChipPanel()
        chipPanel = panel
        placeChipUnderTheCursor(panel)
        chipModel.chipText = chipText
        chipModel.chipTextIsCode = chipTextIsCode
        panel.orderFrontRegardless()
        chipModel.isVisible = true

        hideWorkItem?.cancel()
        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.chipModel.isVisible = false
        }
        self.hideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondsOnScreen, execute: hideWorkItem)
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
