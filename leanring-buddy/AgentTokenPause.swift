//
//  AgentTokenPause.swift
//  leanring-buddy
//
//  The pure rules for the discs beside the notch while the learner has paused every agent ("hold on"): every disc folds
//  into one paused disc, and "go ahead" sends each disc back to its place. `AgentTokenDockController` plays the moves,
//  and `BackgroundAgentStore.agentsArePaused` is the state they follow.
//

import CoreGraphics
import QuartzCore
import SwiftUI

/// The discs one display shows, left to right. While every agent is paused they fold into one paused disc, and the
/// layout's own positions wait underneath, so "go ahead" puts each token back where it was.
func agentTokenSlotsLeftToRight(layout: AgentTokenLayout, agentsArePaused: Bool) -> [AgentTokenSlot] {
    let agentSlots = layout.shownAgentIDs.map(AgentTokenSlot.agent)
    let slots = layout.overflowCount > 0 ? agentSlots + [.overflow] : agentSlots
    guard agentsArePaused else { return slots }
    return slots.isEmpty ? [] : [.paused]
}

/// How the discs move when every agent pauses or goes on. Nil when the pause did not change since the last refresh.
enum AgentTokenPauseMove: Equatable {
    /// Every disc grays, then slides into the paused disc's place as it shrinks and fades, and the paused disc shows there.
    case gatherIntoThePausedDisc
    /// Reduce Motion's form of the gather: every disc fades out where it is, and the paused disc fades in.
    case crossfadeToThePausedDisc
    /// Each disc is sent from the paused disc back to its place along the menu bar, with a tether in its color.
    case sendBackToTheirPlaces
    /// Reduce Motion's form of the send: each disc fades in at its place, and the paused disc fades out.
    case crossfadeBackToTheirPlaces
}

func agentTokenPauseMove(agentsWerePaused: Bool, agentsArePaused: Bool, reduceMotionIsOn: Bool) -> AgentTokenPauseMove? {
    switch (agentsWerePaused, agentsArePaused) {
    case (false, true): return reduceMotionIsOn ? .crossfadeToThePausedDisc : .gatherIntoThePausedDisc
    case (true, false): return reduceMotionIsOn ? .crossfadeBackToTheirPlaces : .sendBackToTheirPlaces
    default: return nil
    }
}

/// The gather's timing: the discs gray over the crossfade time, then slide and shrink on the Recall move's curve, the
/// move that shrinks an interrupted Callout into the cursor.
enum AgentTokenGather {
    static let graySeconds = DS.Move.fadeSeconds
    static var slideSeconds: Double { DS.Move.recall.curve.seconds() }
    /// The Recall move's bezier, as Core Animation takes it.
    static var slideTimingFunction: CAMediaTimingFunction {
        let bezier = MoveBezier.quadraticEaseIn
        return CAMediaTimingFunction(controlPoints: Float(bezier.x1), Float(bezier.y1), Float(bezier.x2), Float(bezier.y2))
    }

    /// Where a gathered disc's panel ends: the paused disc's panel shrunk to the Recall end scale about its center.
    static func endFrame(intoPausedDiscPanelFrame pausedDiscPanelFrame: CGRect) -> CGRect {
        let endWidth = pausedDiscPanelFrame.width * DS.Move.recallEndScale
        let endHeight = pausedDiscPanelFrame.height * DS.Move.recallEndScale
        return CGRect(x: pausedDiscPanelFrame.midX - endWidth / 2, y: pausedDiscPanelFrame.midY - endHeight / 2, width: endWidth, height: endHeight)
    }
}

/// The running agents a pause holds, which the paused disc's badge and peek count. A finished agent whose result waits
/// folds into the disc too, but nothing of it is held.
func pausedAgentCount(of agents: [BackgroundAgent]) -> Int {
    agents.filter(\.isRunning).count
}

/// What a paused disc's peek card says. While one of the agents waits for the learner's OK, "go ahead" answers that
/// request (`resume_agents` is not offered then), so the card asks for the answer first.
func agentTokenPausedPeekContent(pausedAgentCount: Int, anApprovalWaits: Bool) -> AgentTokenPeekContent {
    AgentTokenPeekContent(
        title: "\(pausedAgentCount) \(pausedAgentCount == 1 ? "agent" : "agents") paused",
        caption: anApprovalWaits ? "Answer the request first, then say go ahead" : "Say go ahead to let them go on",
        captionStyle: .plain,
        hint: nil,
        meter: nil
    )
}

/// The one disc every paused agent folds into: a gray ring around two pause bars, with the count of paused agents in a
/// badge when there is more than one. Gray carries no state color, and the pause bars carry the state, so color is never
/// the only signal.
struct AgentPausedDiscView: View {
    let pausedAgentCount: Int
    var isHovered = false

    private static let ringWidth: CGFloat = 2.5
    private static let barWidth: CGFloat = 2.5
    private static let barHeight: CGFloat = 8
    private static let gapBetweenBars: CGFloat = 2.5
    private static let badgeDiameter: CGFloat = 11

    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.agentTokenTrack)
            Circle()
                .strokeBorder(DS.Colors.textTertiary, lineWidth: Self.ringWidth)
            Circle()
                .fill(DS.Colors.agentTokenFace)
                .padding(Self.ringWidth)
            HStack(spacing: Self.gapBetweenBars) {
                Capsule().frame(width: Self.barWidth, height: Self.barHeight)
                Capsule().frame(width: Self.barWidth, height: Self.barHeight)
            }
            .foregroundColor(DS.Colors.textSecondary)
        }
        .frame(width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter)
        .overlay(alignment: .bottomTrailing) {
            if pausedAgentCount > 1 {
                // A capsule, so two digits fit. Its right edge stays on the panel's edge, and it grows to the left.
                Text("\(min(pausedAgentCount, 99))")
                    .font(.system(size: 7.5, weight: .bold, design: .rounded))
                    .foregroundColor(DS.Colors.agentTokenFace)
                    .padding(.horizontal, 2.5)
                    .frame(minWidth: Self.badgeDiameter, minHeight: Self.badgeDiameter, maxHeight: Self.badgeDiameter)
                    .background(Capsule().fill(DS.Colors.textSecondary))
                    .overlay(Capsule().strokeBorder(DS.Colors.agentTokenTrack, lineWidth: 1))
                    .fixedSize()
                    .offset(x: 3, y: 3)
            }
        }
        .agentTokenEdgeAndShadow(isHovered: isHovered, edgeWidth: 1.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pausedAgentCount) \(pausedAgentCount == 1 ? "agent" : "agents") paused")
    }
}
