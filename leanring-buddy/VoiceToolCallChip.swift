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
//  A new chip with other words pushes the one on screen up one step, so two chips stack: the newest has its tail on the
//  cursor, and the one above it keeps its own time on screen (`VoiceToolCallChipStack`). Each chip has its own panel.
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
    /// Whether the Callout is on screen and how it is leaving.
    let presence = TetherCalloutPresence()
    /// True while this slot holds the chip that was pushed up, which draws one step above the bottom.
    @Published var isInTheUpperSlot = false
    /// Counts each chip that pops into this slot, so a new chip pops in even when the slot's Callout is still on screen.
    @Published var shownChipCount = 0
    /// The Callout's measured width, which places the panel so the tail stays on the cursor. Not published, since the
    /// cursor-follow timer reads it 30 times a second.
    var contentWidth: CGFloat = 0
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
    @ObservedObject var presence: TetherCalloutPresence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if presence.isInTheViewTree {
                VoiceToolCallChipCallout(
                    chipText: chipModel.chipText,
                    secondaryChipText: chipModel.secondaryChipText,
                    chipTextIsCode: chipModel.chipTextIsCode,
                    sender: chipModel.sender,
                    themeAccent: chipModel.themeAccent
                )
                .onGeometryChange(for: CGFloat.self) { calloutGeometry in
                    calloutGeometry.size.width
                } action: { measuredCalloutWidth in
                    chipModel.contentWidth = measuredCalloutWidth
                }
                .modifier(TetherCalloutShake(startedAt: chipModel.sender.shakesOnAppearing ? chipModel.shownDate : nil))
                .tetherCalloutPose(presence, reduceMotionIsOn: reduceMotion)
                .id(chipModel.shownChipCount)
                .offset(y: chipModel.isInTheUpperSlot ? -VoiceToolCallChip.stackStepHeight : 0)
                // A chip pushed up moves with the Snap, and with Reduce Motion on it appears one step up with no travel. A slot
                // that takes a new chip goes back to the bottom with no move.
                .animation(chipModel.isInTheUpperSlot && !reduceMotion ? DS.Move.snap.animation(reduceMotionIsOn: false) : nil, value: chipModel.isInTheUpperSlot)
            }
        }
        .padding(tetherCalloutPanelMargin)
        .tetherCalloutAnimations(presence, reduceMotionIsOn: reduceMotion)
        .animation(tetherCalloutAnimation(isAppearing: true, exit: .fadeRise, reduceMotionIsOn: reduceMotion), value: chipModel.shownChipCount)
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

/// One of the two places a chip can show: its model, its panel, and the time its chip stays.
@MainActor
private final class VoiceToolCallChipSlot {
    let chipModel = VoiceToolCallChipModel()
    var panel: NSPanel?
    var hideWorkItem: DispatchWorkItem?
}

@MainActor
final class VoiceToolCallChip {
    static let shared = VoiceToolCallChip()

    /// The space between a chip and the chip it pushed up.
    nonisolated static let gapBetweenStackedChips: CGFloat = 4
    /// How far a chip rises when a new one pushes it up: the Callout's height with its tail (49) and the gap.
    nonisolated static let stackStepHeight: CGFloat = tetherSingleLineCalloutHeight + gapBetweenStackedChips
    /// The panel holds a Callout with its tail (49), the margin for its shadow on both sides (28), and one step
    /// for the upper slot's chip to rise into.
    nonisolated static let panelSize = CGSize(width: 520, height: tetherSingleLineCalloutHeight + 2 * tetherCalloutPanelMargin + stackStepHeight)
    nonisolated static let defaultSecondsOnScreen: TimeInterval = 1.4

    /// The theme's accent for a voice tool call's chip. `CompanionManager` sets it to follow the shown theme.
    var themeAccentProvider: () -> Color = { DS.Colors.overlayCursorBlue }

    private static let cursorFollowInterval: TimeInterval = 1.0 / 30.0

    /// What shows now. A slot's panel changes role when a push moves its chip up, so the stack says what shows and the two
    /// slots below say where.
    private var chipStack = VoiceToolCallChipStack()
    private var bottomSlot = VoiceToolCallChipSlot()
    private var upperSlot = VoiceToolCallChipSlot()
    private var cursorFollowTimer: Timer?

    /// A second call with other words while a chip shows pushes that chip up one step and pops the new chip below it, and the
    /// chip above goes away, unless it waits for the learner's answer, when the new chip replaces the bottom one instead. The
    /// same words from the same sender update the chip in place and restart its time on screen, and the words of the chip
    /// above send it away, so they show once. `voiceToolCallChipStackingStep` decides each case.
    /// - `survivesARecall`: a push-to-talk press leaves this chip up, for a chip that waits for an answer.
    func show(
        _ chipText: String,
        sender: VoiceToolCallChipSender = .voiceToolCall,
        secondaryChipText: String? = nil,
        chipTextIsCode: Bool = false,
        survivesARecall: Bool = false,
        secondsOnScreen: TimeInterval = VoiceToolCallChip.defaultSecondsOnScreen
    ) {
        let stackingStep = chipStack.show(VoiceToolCallChipStack.Chip(
            identity: VoiceToolCallChipIdentity(chipText: chipText, sender: sender),
            survivesARecall: survivesARecall
        ))
        if stackingStep.visibleBottomChipRisesToTheUpperSlot {
            // The slot that held the bottom chip keeps it and moves up. The slot of the chip that goes away takes the new one.
            (bottomSlot, upperSlot) = (upperSlot, bottomSlot)
            upperSlot.chipModel.isInTheUpperSlot = true
            bottomSlot.chipModel.isInTheUpperSlot = false
        } else if stackingStep.upperChipIsSentAway {
            // The new chip says what the chip above says, so that one leaves and the words show once, at the bottom.
            playTheLeave(of: upperSlot, .fadeRise)
        }
        let slot = bottomSlot
        let chipModel = slot.chipModel
        let panel = slot.panel ?? makeChipPanel(for: slot)
        slot.panel = panel
        chipModel.chipText = chipText
        chipModel.themeAccent = themeAccentProvider()
        chipModel.sender = sender
        chipModel.secondaryChipText = secondaryChipText
        chipModel.chipTextIsCode = chipTextIsCode
        if stackingStep.bottomChipStep == .popTheNewChip {
            chipModel.shownDate = Date()
            chipModel.shownChipCount += 1
        }
        placeTheChipsAboveTheCursor()
        panel.orderFrontRegardless()
        chipModel.presence.appear()
        // The chip's panel never takes the keyboard, so VoiceOver would never reach it: it reads the chip's words aloud instead.
        if !chipTextIsCode {
            announceForVoiceOver([chipText, secondaryChipText].compactMap { $0 }.joined(separator: " "))
        }
        // Runs only while a chip is up, so the tails keep pointing at the cursor as it moves.
        if cursorFollowTimer == nil {
            cursorFollowTimer = Timer.scheduledTimer(withTimeInterval: Self.cursorFollowInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.placeTheChipsAboveTheCursor()
                }
            }
        }

        slot.hideWorkItem?.cancel()
        let hideWorkItem = DispatchWorkItem { [weak self, weak slot] in
            guard let self, let slot else { return }
            self.leaveWhenItsTimeEnds(slot)
        }
        slot.hideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + secondsOnScreen, execute: hideWorkItem)
    }

    /// A push-to-talk press: each chip shrinks into the cursor in 180 ms (a Recall), and the press starts the next request.
    /// A chip that waits for the learner's answer stays.
    func recall() {
        for recalledSlotRole in chipStack.recall() {
            playTheLeave(of: slot(in: recalledSlotRole), .recall)
        }
        stopFollowingTheCursorWhenNoChipShows()
    }

    /// Hides the chip now, whichever slot it is in, but only while it still shows `chipText`, so a newer chip is never cut short.
    func hide(ifShowing chipText: String) {
        for hiddenSlotRole in chipStack.hide(ifShowing: chipText) {
            playTheLeave(of: slot(in: hiddenSlotRole), .fadeRise)
        }
        stopFollowingTheCursorWhenNoChipShows()
    }

    private func slot(in slotRole: VoiceToolCallChipSlotRole) -> VoiceToolCallChipSlot {
        switch slotRole {
        case .bottom: return bottomSlot
        case .upper: return upperSlot
        }
    }

    /// The chip's time on screen ended. The chip above stays where it is when the bottom one leaves.
    private func leaveWhenItsTimeEnds(_ slot: VoiceToolCallChipSlot) {
        let slotRole: VoiceToolCallChipSlotRole = slot === bottomSlot ? .bottom : .upper
        guard chipStack.chip(in: slotRole) != nil else { return }
        chipStack.leave(slotRole)
        playTheLeave(of: slot, .fadeRise)
        stopFollowingTheCursorWhenNoChipShows()
    }

    private func playTheLeave(of slot: VoiceToolCallChipSlot, _ exit: TetherCalloutExit) {
        slot.hideWorkItem?.cancel()
        slot.chipModel.presence.leave(exit, reduceMotionIsOn: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func stopFollowingTheCursorWhenNoChipShows() {
        guard chipStack.isEmpty else { return }
        cursorFollowTimer?.invalidate()
        cursorFollowTimer = nil
    }

    /// Both panels share one origin, each placed from its own Callout's width, so the tails stay on the cursor and the chip
    /// that was pushed up sits one step above the new one.
    private func placeTheChipsAboveTheCursor() {
        guard let screenFrame = screenUnderTheMouseCursor()?.frame else { return }
        for slot in [bottomSlot, upperSlot] {
            guard let panel = slot.panel else { continue }
            panel.setFrameOrigin(voiceToolCallChipOrigin(
                mouseLocation: NSEvent.mouseLocation,
                screenFrame: screenFrame,
                calloutWidth: slot.chipModel.contentWidth,
                aStatusLabelIsShowing: LiveSceneStatusLabel.shared.statusLabelModel.presence.isInTheViewTree
            ))
        }
    }

    private func makeChipPanel(for slot: VoiceToolCallChipSlot) -> NSPanel {
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
        panel.contentView = NSHostingView(rootView: VoiceToolCallChipView(chipModel: slot.chipModel, presence: slot.chipModel.presence))
        return panel
    }
}

/// The chip panel's bottom-left corner in AppKit screen points. The chip's tail points at Clicky's triangle, so it sits
/// above the triangle. While a status line shows at the same spot, the chip sits above that line instead, so neither covers
/// the other. It stays inside the screen. The panel is one step taller than a chip, for the chip pushed up, so both chip
/// panels use this origin, each with its own `calloutWidth`.
/// `calloutWidth` is the measured width of the chip's Callout, and 0 before the first measure, which places the chip as a
/// full width one so it never starts past the screen's edge.
func voiceToolCallChipOrigin(mouseLocation: CGPoint, screenFrame: CGRect, calloutWidth: CGFloat = 0, aStatusLabelIsShowing: Bool = false) -> CGPoint {
    let triangleSpotFromTheMouse = StatusLabelPlacement.trianglesSpotFromTheMouse
    let heightOfTheStatusLineBelow = aStatusLabelIsShowing ? tetherSingleLineCalloutHeight + 4 : 0
    let tipPoint = CGPoint(
        x: mouseLocation.x + triangleSpotFromTheMouse.x,
        y: mouseLocation.y + triangleSpotFromTheMouse.y + tetherCalloutTipRiseAboveTheCursor + heightOfTheStatusLineBelow
    )
    return tetherCalloutPanelOrigin(
        tipPoint: tipPoint,
        calloutWidth: calloutWidth > 0 ? calloutWidth : VoiceToolCallChip.panelSize.width - 2 * tetherCalloutPanelMargin,
        panelHeight: VoiceToolCallChip.panelSize.height,
        screenFrame: screenFrame
    )
}

/// Whether a push-to-talk press recalls the chip. A chip that is up waits to be recalled unless it waits for the learner's
/// answer, such as an agent's request for the learner's OK, which stays until the learner answers it.
func chipIsRecalledByAPress(isShowing: Bool, survivesARecall: Bool) -> Bool {
    isShowing && !survivesARecall
}
