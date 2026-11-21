//
//  VoiceToolCallChip.swift
//  leanring-buddy
//
//  A Callout above the cursor that names each voice tool call, such as "Turning it left", then leaves. It has a 1 point
//  rim, an accent disc with its icon in ink, and a tail that points at the cursor's triangle. A voice tool call uses the
//  theme's accent. A background agent that ends shows its line here too, in the agent's own color with its face in the
//  disc, a quieter second part in gray, and a longer stay, so the learner sees which agent it speaks for. A failure uses
//  red with a cross and one small shake, and with Reduce Motion on the red and the cross carry it. The chip pops in
//  from its tail's tip, leaves with a 6 point rise and a fade, and shrinks into the cursor when the learner interrupts.
//

import AppKit
import Combine
import SwiftUI

/// Who the chip speaks for, which sets its accent and icon.
enum VoiceToolCallChipSender: Equatable {
    case voiceToolCall
    /// `color` is the agent's own color, which fills the disc and the rim. `face` is the roster player the agent was, or
    /// the picture of its theme, so the chip shows that round face in the disc instead of the triangle.
    case backgroundAgent(color: AgentPaletteColor, face: AgentFace)
    /// Something did not work: a red Callout with a cross, paired with the shake and the spoken line.
    case failure
}

/// What fills the chip's icon disc. A round portrait covers the whole disc, and anything else is a symbol in ink on it.
enum VoiceToolCallChipIconContent: Equatable {
    case symbolOnDisc
    case circularPortrait
}

extension VoiceToolCallChipSender {
    var iconContent: VoiceToolCallChipIconContent {
        switch self {
        case .backgroundAgent(_, face: .rosterFace), .backgroundAgent(_, face: .themePicture): return .circularPortrait
        case .voiceToolCall, .backgroundAgent(_, face: .triangle), .failure: return .symbolOnDisc
        }
    }

    /// The Callout's accent: the theme's for a voice tool call, the agent's own for an agent, and red for a failure.
    func accent(themeAccent: Color) -> Color {
        switch self {
        case .voiceToolCall: return themeAccent
        case .backgroundAgent(let agentColor, _): return agentColor.color
        case .failure: return DS.Colors.destructiveText
        }
    }

    /// Whether the chip shakes once as it appears.
    var shakesOnAppearing: Bool { self == .failure }
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
    /// How the chip leaves, set one turn before `isVisible` goes false, since a view's removal transition is the one it had
    /// in its last drawing.
    @Published var exit: TetherCalloutExit = .fadeRise
    /// The theme's accent, read when the chip is shown.
    @Published var themeAccent = DS.Colors.overlayCursorBlue
    /// When the chip appeared, which a failure's shake counts from.
    var shownDate = Date()
}

/// The chip as drawn: the Callout with its icon, its words, and the quieter second part. It has no model, so a test can
/// render it.
struct VoiceToolCallChipCallout: View {
    let chipText: String
    var secondaryChipText: String?
    var chipTextIsCode = false
    let sender: VoiceToolCallChipSender
    let themeAccent: Color

    var body: some View {
        TetherCallout(accent: sender.accent(themeAccent: themeAccent), rim: .chip) {
            VoiceToolCallChipIcon(sender: sender)
        } content: {
            HStack(spacing: 6) {
                Text(verbatim: chipText)
                    .font(chipTextIsCode ? .system(size: DS.TypeScale.title.pointSize, weight: .bold, design: .monospaced) : DS.TypeScale.voice.font)
                if let secondaryChipText {
                    // 60% white reads at 7.0 contrast on the Callout's surface.
                    Text(verbatim: secondaryChipText)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
        .fixedSize()
    }
}

private struct VoiceToolCallChipView: View {
    @ObservedObject var chipModel: VoiceToolCallChipModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if chipModel.isVisible {
                VoiceToolCallChipCallout(
                    chipText: chipModel.chipText,
                    secondaryChipText: chipModel.secondaryChipText,
                    chipTextIsCode: chipModel.chipTextIsCode,
                    sender: chipModel.sender,
                    themeAccent: chipModel.themeAccent
                )
                .modifier(TetherCalloutShake(startedAt: chipModel.sender.shakesOnAppearing ? chipModel.shownDate : nil))
                .transition(.tetherCallout(exit: chipModel.exit, reduceMotionIsOn: reduceMotion))
            }
        }
        .padding(tetherCalloutPanelMargin)
        .animation(
            tetherCalloutAnimation(isAppearing: chipModel.isVisible, exit: chipModel.exit, reduceMotionIsOn: reduceMotion),
            value: chipModel.isVisible
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// The chip's icon, drawn inside the Callout's 26 point accent disc: a symbol in ink, or a round portrait that fills the disc
/// and leaves the agent's color as a ring around it.
struct VoiceToolCallChipIcon: View {
    let sender: VoiceToolCallChipSender
    private static let portraitSize: CGFloat = TetherCallout<EmptyView, EmptyView>.iconDiscDiameter - 4

    var body: some View {
        switch sender {
        case .voiceToolCall:
            Image(systemName: "hand.point.up.left.fill")
        case .failure:
            TetherCalloutCrossIcon()
        case .backgroundAgent(_, face: .triangle):
            TetherCalloutCursorIcon()
        case .backgroundAgent(_, face: .rosterFace(let rosterFace)):
            RosterFaceView(rosterFace: rosterFace, size: Self.portraitSize)
        case .backgroundAgent(_, face: .themePicture(let themeID)):
            if let themePicture = CustomThemePictureCache.image(forThemeID: themeID) {
                ThemePictureFaceView(picture: themePicture, size: Self.portraitSize)
            } else {
                // The picture file could not be read, so the disc shows the agent's color and its triangle.
                TetherCalloutCursorIcon()
            }
        }
    }
}

@MainActor
final class VoiceToolCallChip {
    static let shared = VoiceToolCallChip()

    /// The Callout's height with its tail (49) and the margin for its halo and shadow on both sides (28).
    nonisolated static let panelSize = CGSize(width: 520, height: 49 + 28)
    nonisolated static let defaultSecondsOnScreen: TimeInterval = 1.4

    /// The theme's accent for a voice tool call's chip. `CompanionManager` sets it to follow the shown theme.
    var themeAccentProvider: () -> Color = { DS.Colors.overlayCursorBlue }

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
        chipModel.themeAccent = themeAccentProvider()
        chipModel.sender = sender
        chipModel.secondaryChipText = secondaryChipText
        chipModel.chipTextIsCode = chipTextIsCode
        panel.orderFrontRegardless()
        if !chipModel.isVisible { chipModel.shownDate = Date() }
        chipModel.exit = .fadeRise
        chipModel.isVisible = true

        hideWorkItem?.cancel()
        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.chipModel.isVisible = false
        }
        self.hideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsOnScreen, execute: hideWorkItem)
    }

    /// A push-to-talk press: the chip shrinks into the cursor in 180 ms (a Recall), and the press starts the next request.
    func recall() {
        guard chipModel.isVisible else { return }
        hideWorkItem?.cancel()
        chipModel.exit = .recall
        // One turn later, so the view's removal transition is the Recall.
        DispatchQueue.main.async { [weak self] in
            self?.chipModel.isVisible = false
        }
    }

    /// Hides the chip now, but only while it still shows `chipText`, so a newer chip is never cut short.
    func hide(ifShowing chipText: String) {
        guard chipModel.isVisible, chipModel.chipText == chipText else { return }
        hideWorkItem?.cancel()
        chipModel.exit = .fadeRise
        chipModel.isVisible = false
    }

    private func placeChipUnderTheCursor(_ panel: NSPanel) {
        guard let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        panel.setFrameOrigin(voiceToolCallChipOrigin(
            mouseLocation: NSEvent.mouseLocation,
            screenFrame: screenFrame,
            aStatusLabelIsShowing: LiveSceneStatusLabel.shared.statusLabelModel.isVisible
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

/// The chip panel's bottom-left corner in AppKit screen points. The chip's tail points at Clicky's triangle, so it sits
/// above the triangle. While a status line shows at the same spot, the chip sits above that line instead, so neither covers
/// the other. It stays inside the screen.
func voiceToolCallChipOrigin(mouseLocation: CGPoint, screenFrame: CGRect, aStatusLabelIsShowing: Bool = false) -> CGPoint {
    let triangleSpotFromTheMouse = StatusLabelPlacement.trianglesSpotFromTheMouse
    let heightOfTheStatusLineBelow = aStatusLabelIsShowing ? tetherSingleLineCalloutHeight + 4 : 0
    let tipPoint = CGPoint(
        x: mouseLocation.x + triangleSpotFromTheMouse.x,
        y: mouseLocation.y + triangleSpotFromTheMouse.y + tetherCalloutTipRiseAboveTheCursor + heightOfTheStatusLineBelow
    )
    return tetherCalloutPanelOrigin(
        tipPoint: tipPoint,
        calloutWidth: VoiceToolCallChip.panelSize.width - 2 * tetherCalloutPanelMargin,
        panelHeight: VoiceToolCallChip.panelSize.height,
        screenFrame: screenFrame
    )
}
