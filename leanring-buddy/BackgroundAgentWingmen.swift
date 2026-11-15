//
//  BackgroundAgentWingmen.swift
//  leanring-buddy
//
//  Each background agent shows as a small triangle, a wingman, that follows Clicky's blue cursor triangle
//  in formation behind it. The triangle is an outline in the agent's color that fills from tail to tip as
//  its steps finish. A finished agent's wingman hops ahead of the blue triangle's tip and turns green,
//  and a failed one turns into a red outline.
//  Motion here is one-shot only. Nothing pulses or spins, because a looping animation pegs the GPU on
//  high-refresh displays.
//

import SwiftUI

/// One agent's triangle, drawn the same small in the formation and in the agent list.
struct WingmanTriangleView: View {
    let agent: BackgroundAgent
    var size: CGFloat = 11

    /// The same tilt as the blue cursor triangle's resting pose.
    private static let rotationDegrees = -35.0

    /// A finished agent is green and a failed one is a red outline. A cancelled one never shows beside the cursor,
    /// and in the list it is a gray outline.
    private var color: Color {
        switch agent.phase {
        case .running: return agent.kind.color
        case .finished: return DS.Colors.success
        case .failed: return DS.Colors.destructive
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    var body: some View {
        let triangleHeight = size * sqrt(3) / 2
        let fillHeight = agent.filledFraction * triangleHeight
        // Triangle() is drawn around the frame's center, so its base sits below the center and above the frame's
        // bottom edge. The fill's bottom edge goes on the base, not on the frame.
        let baseBelowCenter = size * sqrt(3) / 6
        ZStack {
            Triangle()
                .fill(color)
                // The fill is cut before the rotation, so it rises along the triangle's own axis from tail to tip.
                .mask(
                    Rectangle()
                        .frame(width: size * 2, height: fillHeight)
                        .offset(y: baseBelowCenter - fillHeight / 2)
                )
            Triangle()
                .stroke(color, lineWidth: 1.4)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(Self.rotationDegrees))
        .animation(.easeOut(duration: 0.3), value: agent.filledFraction)
        .animation(.easeOut(duration: 0.25), value: agent.phase)
    }
}

/// All the wingmen of one screen's cursor overlay, placed from the cursor's position.
struct WingmenView: View {
    @ObservedObject var store: BackgroundAgentStore
    /// The blue triangle's center, where each wingman's offset starts.
    let cursorPosition: CGPoint
    /// Whether the blue triangle shows on this screen, so there is one formation on screen, not one per display.
    let buddyIsVisibleOnThisScreen: Bool
    let cursorOpacity: Double

    var body: some View {
        let formation = wingmanFormation(for: store.agents.filter { $0.isShownAsAWingman(at: Date()) })
        ZStack {
            ForEach(formation.placements, id: \.agent.id) { placement in
                WingmanView(placement: placement, cursorPosition: cursorPosition)
                    .transition(.opacity)
            }
            if formation.overflowCount > 0 {
                let overflowOffset = WingmanFormation.offset(forSlot: WingmanFormation.mostWingmen)
                Text("+\(formation.overflowCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .position(x: cursorPosition.x + overflowOffset.width, y: cursorPosition.y + overflowOffset.height)
                    .animation(WingmanView.followSpring(slot: WingmanFormation.mostWingmen), value: cursorPosition)
                    .transition(.opacity)
            }
        }
        .opacity(buddyIsVisibleOnThisScreen ? cursorOpacity : 0)
        .animation(.easeOut(duration: 0.25), value: formation.placements.map(\.agent.id))
        .animation(.easeOut(duration: 0.25), value: formation.overflowCount)
        .animation(.easeOut(duration: 0.25), value: buddyIsVisibleOnThisScreen)
        .allowsHitTesting(false)
    }
}

private struct WingmanView: View {
    let placement: WingmanFormation.Placement
    let cursorPosition: CGPoint

    /// A slow spring, so a wingman visibly trails the blue triangle on a move and catches up after it stops, instead
    /// of moving locked to it. Farther wingmen use a softer one, so the line stretches on a fast move and closes at rest.
    static func followSpring(slot: Int) -> Animation {
        .spring(response: 0.5 + 0.15 * Double(slot + 1), dampingFraction: 0.75, blendDuration: 0)
    }

    /// One bouncy hop, played when the wingman goes ahead of the tip.
    private static let hopSpring = Animation.spring(response: 0.35, dampingFraction: 0.55, blendDuration: 0)

    var body: some View {
        let wingmanPosition = CGPoint(
            x: cursorPosition.x + placement.offset.width,
            y: cursorPosition.y + placement.offset.height
        )
        WingmanTriangleView(agent: placement.agent)
            .position(wingmanPosition)
            .animation(placement.agent.finishedResult == nil ? Self.followSpring(slot: placement.slot) : Self.hopSpring, value: wingmanPosition)
    }
}
