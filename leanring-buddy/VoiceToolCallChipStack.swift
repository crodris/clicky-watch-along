//
//  VoiceToolCallChipStack.swift
//  leanring-buddy
//
//  Which chips show, and where, when voice tool chips stack. The bottom slot holds the newest chip, with its tail on the
//  cursor. A new chip that differs from it pushes it up into the upper slot, and a chip already in the upper slot goes
//  away, so at most two chips show. Each rule is a pure function or a mutation of a value, so a test checks it without a
//  window. `VoiceToolCallChip` does what each step says to its two panels.
//

import Foundation

/// What a chip says and who says it. Showing the same identity again updates the bottom chip in place.
struct VoiceToolCallChipIdentity: Equatable {
    let chipText: String
    let sender: VoiceToolCallChipSender
}

/// A chip slot. The bottom one has the tail on the cursor, and the upper one holds the chip that was pushed up.
enum VoiceToolCallChipSlotRole: Equatable {
    case bottom
    case upper
}

/// What showing a chip does to the two slots.
struct VoiceToolCallChipStackingStep: Equatable {
    enum BottomChipStep: Equatable {
        /// The same chip shows again, so it keeps its place and its time on screen starts over.
        case updateInPlace
        /// The new chip pops into the bottom slot.
        case popTheNewChip
    }

    let bottomChipStep: BottomChipStep
    /// The chip that was in the bottom slot moves into the upper slot and keeps its own remaining time on screen.
    let visibleBottomChipRisesToTheUpperSlot: Bool
    /// The chip that was in the upper slot goes away: the bottom chip takes its slot, or the new chip says the same words.
    let upperChipIsSentAway: Bool
}

/// How far the chip in the upper slot sits above the bottom chip, tip to tip: the height of the bottom chip with its tail, and
/// the gap between stacked chips. A Callout is one line tall (`tetherSingleLineCalloutHeight`), and the Save photo receipt is
/// taller (`PaperPhotoReceipt.height`), so the rise follows the chip that arrives below, whichever chip is above it. The upper
/// chip's own height does not matter here, since the rise is measured from the bottom chip's top edge up to the upper chip's tail.
func voiceToolCallChipRise(overTheBottomChipSentBy sender: VoiceToolCallChipSender) -> CGFloat {
    let bottomChipHeight = sender == .photoReceipt ? PaperPhotoReceipt.height : tetherSingleLineCalloutHeight
    return bottomChipHeight + VoiceToolCallChip.gapBetweenStackedChips
}

/// What showing `newChip` does, given the chip in the bottom slot (nil when that slot is empty) and the chip in the upper
/// slot (nil when it is empty).
/// - A bottom slot that is empty takes the new chip with no push. A chip above with the same words leaves, so the same
///   words never show twice, and any other chip above stays until its own time ends.
/// - The same chip as the bottom one updates it in place.
/// - A chip above that waits for the learner's answer, such as an agent's request for the learner's OK, is never sent
///   away: the new chip takes the bottom slot and the bottom chip goes, as a lone chip was replaced before chips stacked.
/// - Otherwise the bottom chip rises to the upper slot, and a chip already there goes.
func voiceToolCallChipStackingStep(
    visibleBottomChip: VoiceToolCallChipIdentity?,
    upperChip: VoiceToolCallChipStack.Chip?,
    newChip: VoiceToolCallChipIdentity
) -> VoiceToolCallChipStackingStep {
    guard let visibleBottomChip else {
        return VoiceToolCallChipStackingStep(bottomChipStep: .popTheNewChip, visibleBottomChipRisesToTheUpperSlot: false, upperChipIsSentAway: upperChip?.identity == newChip)
    }
    if visibleBottomChip == newChip {
        return VoiceToolCallChipStackingStep(bottomChipStep: .updateInPlace, visibleBottomChipRisesToTheUpperSlot: false, upperChipIsSentAway: false)
    }
    if upperChip?.survivesARecall == true {
        return VoiceToolCallChipStackingStep(bottomChipStep: .popTheNewChip, visibleBottomChipRisesToTheUpperSlot: false, upperChipIsSentAway: false)
    }
    return VoiceToolCallChipStackingStep(bottomChipStep: .popTheNewChip, visibleBottomChipRisesToTheUpperSlot: true, upperChipIsSentAway: upperChip != nil)
}

/// The chips on screen. The slots hold what the learner sees, and each mutation returns what the panels must do.
struct VoiceToolCallChipStack: Equatable {
    struct Chip: Equatable {
        let identity: VoiceToolCallChipIdentity
        /// True for a chip a push-to-talk press must leave up, such as an agent's request for the learner's OK.
        let survivesARecall: Bool
    }

    private(set) var bottomChip: Chip?
    private(set) var upperChip: Chip?

    var isEmpty: Bool { bottomChip == nil && upperChip == nil }

    func chip(in slotRole: VoiceToolCallChipSlotRole) -> Chip? {
        switch slotRole {
        case .bottom: return bottomChip
        case .upper: return upperChip
        }
    }

    /// Puts `newChip` in the bottom slot, moving the bottom chip up when it differs.
    mutating func show(_ newChip: Chip) -> VoiceToolCallChipStackingStep {
        let stackingStep = voiceToolCallChipStackingStep(
            visibleBottomChip: bottomChip?.identity,
            upperChip: upperChip,
            newChip: newChip.identity
        )
        if stackingStep.upperChipIsSentAway { upperChip = nil }
        if stackingStep.visibleBottomChipRisesToTheUpperSlot { upperChip = bottomChip }
        bottomChip = newChip
        return stackingStep
    }

    /// A push-to-talk press: every chip that does not wait for an answer leaves. Returns the slots that were recalled.
    mutating func recall() -> [VoiceToolCallChipSlotRole] {
        var recalledSlotRoles: [VoiceToolCallChipSlotRole] = []
        for slotRole in [VoiceToolCallChipSlotRole.bottom, .upper] {
            guard let chipInTheSlot = chip(in: slotRole),
                  chipIsRecalledByAPress(isShowing: true, survivesARecall: chipInTheSlot.survivesARecall) else { continue }
            leave(slotRole)
            recalledSlotRoles.append(slotRole)
        }
        return recalledSlotRoles
    }

    /// Hides each chip that shows `chipText`, so a newer chip with other words is never cut short. Returns the slots hidden.
    mutating func hide(ifShowing chipText: String) -> [VoiceToolCallChipSlotRole] {
        var hiddenSlotRoles: [VoiceToolCallChipSlotRole] = []
        for slotRole in [VoiceToolCallChipSlotRole.bottom, .upper] {
            guard chip(in: slotRole)?.identity.chipText == chipText else { continue }
            leave(slotRole)
            hiddenSlotRoles.append(slotRole)
        }
        return hiddenSlotRoles
    }

    /// The chip in `slotRole` has left. The other slot keeps its chip where it is.
    mutating func leave(_ slotRole: VoiceToolCallChipSlotRole) {
        switch slotRole {
        case .bottom: bottomChip = nil
        case .upper: upperChip = nil
        }
    }
}
