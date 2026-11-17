//
//  BackgroundAgentWingmen.swift
//  leanring-buddy
//
//  Each background agent shows as a small triangle, a wingman, that follows Clicky's blue cursor triangle
//  in formation behind it. The triangle is an outline in the agent's color that fills from tail to tip, moving
//  through each step while it runs, by area, so half the work fills half the triangle. The wingman closest to the
//  blue triangle shows the step it is on in a small line to its right. A finished agent's wingman fills, hops ahead of the blue triangle's
//  tip, and shows a green check mark, and a failed one turns into a red outline. Each grows and fades away
//  when it leaves.
//  With a Haikyu!! team theme on, a wingman is the agent's player instead: a round portrait inside a progress ring.
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

    /// A finished agent keeps its color and gets a green check mark, so the learner still sees which agent it was.
    /// A failed one is a red outline. A cancelled one never shows beside the cursor, and in the list it is a gray outline.
    private var color: Color {
        switch agent.phase {
        case .running, .finished: return agent.kind.color
        case .failed: return DS.Colors.destructive
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    var body: some View {
        ZStack {
            // The fill is drawn before the rotation, so it rises along the triangle's own axis from tail to tip.
            AgentProgressView(agent: agent) { shownProgress in
                WingmanTriangleFill(progress: shownProgress)
                    .fill(color)
            }
            Triangle()
                .stroke(color, lineWidth: 1.4)
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(Self.rotationDegrees))
        .overlay(alignment: .bottomTrailing) {
            if agent.finishedResult != nil {
                FinishedCheckMark(size: size * 0.8)
                    .offset(x: size * 0.45, y: size * 0.35)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: agent.phase)
    }
}

/// One agent as a team player: the portrait in a circle, inside a progress ring with a thin dark gap between them.
/// The ring fills in the school's color from 12 o'clock, clockwise, in a straight line with the progress.
struct WingmanAvatarView: View {
    let agent: BackgroundAgent
    let player: HaikyuPlayer
    let size: CGFloat

    private static let ringWidth: CGFloat = 3
    private static let gapWidth: CGFloat = 2
    private static let gapColor = Color(hex: "#0d0f12")

    /// A finished agent keeps its team color. A failed one is red, and a cancelled one gray, as with the triangle.
    private var ringColor: Color {
        switch agent.phase {
        case .running, .finished: return player.school.accentColor
        case .failed: return DS.Colors.destructive
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    /// A failed agent shows a full ring, since the red says the state and its phase does not keep how far it got.
    private func ringProgress(shownProgress: Double) -> Double {
        switch agent.phase {
        case .running, .finished: return shownProgress
        case .failed: return 1
        case .cancelled: return 0
        }
    }

    private var faceDiameter: CGFloat {
        size - 2 * (Self.ringWidth + Self.gapWidth)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.55), lineWidth: Self.ringWidth)
                .padding(Self.ringWidth / 2)
            AgentProgressView(agent: agent) { shownProgress in
                Circle()
                    .trim(from: 0, to: ringProgress(shownProgress: shownProgress))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.ringWidth / 2)
            }
            Circle()
                .fill(Self.gapColor)
                .frame(width: size - 2 * Self.ringWidth, height: size - 2 * Self.ringWidth)
            HaikyuPortraitView(player: player, size: faceDiameter, isGrayscale: agent.phase.isFailed)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if agent.finishedResult != nil {
                FinishedCheckMark(size: size * 0.4)
                    .offset(x: size * 0.08, y: size * 0.08)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: agent.phase)
    }
}

/// Shows an agent's progress as it moves. It starts at progress(at:) and runs one straight-line animation to where the
/// current step heads, timed by the clock, so the wingman and the agent list show the same progress at the same moment,
/// with no looping animation.
struct AgentProgressView<Content: View>: View {
    let agent: BackgroundAgent
    @ViewBuilder let content: (Double) -> Content
    @State private var shownProgress: Double = 0

    var body: some View {
        content(shownProgress)
            .onAppear {
                shownProgress = agent.progress(at: Date())
                followTheProgress()
            }
            .onChange(of: agent.phase) { followTheProgress() }
    }

    private func followTheProgress() {
        let now = Date()
        if let progressHeading = agent.progressHeading(at: now), progressHeading.secondsToGetThere > 0 {
            withAnimation(.linear(duration: progressHeading.secondsToGetThere)) {
                shownProgress = progressHeading.fraction
            }
        } else {
            withAnimation(.easeOut(duration: 0.3)) {
                shownProgress = agent.progress(at: now)
            }
        }
    }
}

/// How high the fill rises, as a share of the triangle's height, so the filled area is the progress. The triangle is
/// widest at its tail, where the fill starts, so filling half its height would cover three quarters of it.
nonisolated func wingmanFillHeightShare(forProgress progress: Double) -> Double {
    1 - (1 - min(1, max(0, progress))).squareRoot()
}

/// The filled part of the wingman's triangle, from the base up. Animatable, so the area follows the progress in every
/// frame of an animation, not just at its ends.
struct WingmanTriangleFill: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // The same points as Triangle(): tip above the center, base below it.
        let size = min(rect.width, rect.height)
        let triangleHeight = size * sqrt(3.0) / 2.0
        let tipY = rect.midY - triangleHeight / 1.5
        let baseY = rect.midY + triangleHeight / 3
        let fillTopY = baseY - triangleHeight * wingmanFillHeightShare(forProgress: progress)
        let halfWidthAtFillTop = (size / 2) * (fillTopY - tipY) / triangleHeight
        var path = Path()
        guard fillTopY < baseY else { return path }
        path.move(to: CGPoint(x: rect.midX - size / 2, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: baseY))
        path.addLine(to: CGPoint(x: rect.midX + halfWidthAtFillTop, y: fillTopY))
        path.addLine(to: CGPoint(x: rect.midX - halfWidthAtFillTop, y: fillTopY))
        path.closeSubpath()
        return path
    }
}

/// The step a working wingman is on, such as "Writing the guide in Notion", in a small pill to its right, so the
/// learner can see what the agent is doing without opening the agent list.
private struct WingmanStepLine: View {
    let text: String
    let textColor: Color
    /// A team player's name, shown before the step in bold: "Hinata · Writing the guide in Notion".
    var playerName: String? = nil

    private var line: Text {
        let stepText = Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(playerName == nil ? textColor : Color(hex: "#374151"))
        guard let playerName else { return stepText }
        let nameText = Text(playerName)
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundColor(Color(hex: "#111827"))
        let separatorText = Text(" · ")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(Color(hex: "#374151"))
        return nameText + separatorText + stepText
    }

    var body: some View {
        line
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.94))
                    .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            )
    }
}

/// A white check on a green dot, at the base of a finished wingman.
struct FinishedCheckMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: size * 0.55, weight: .heavy))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(DS.Colors.success))
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
                let overflowOffset = formation.style.offset(forSlot: WingmanFormation.mostWingmen)
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

    /// Set just before an ended agent's wingman is removed, so it grows and fades out instead of vanishing.
    @State private var isLeaving = false

    /// An agent that started before a team theme was picked has no player and stays a triangle, even in a formation of portraits.
    private var agentStyle: WingmanStyle {
        placement.agent.player == nil ? .triangle : .avatar
    }

    @ViewBuilder private var wingmanBody: some View {
        if let player = placement.agent.player {
            WingmanAvatarView(agent: placement.agent, player: player, size: agentStyle.size(forSlot: placement.slot))
        } else {
            WingmanTriangleView(agent: placement.agent, size: agentStyle.size(forSlot: placement.slot))
        }
    }

    var body: some View {
        let wingmanPosition = CGPoint(
            x: cursorPosition.x + placement.offset.width,
            y: cursorPosition.y + placement.offset.height
        )
        wingmanBody
            // Only the wingman closest to the blue triangle says what it is doing, so lines in a formation never overlap.
            .overlay(alignment: .leading) {
                if placement.slot == 0, let inProgressText = placement.agent.inProgressText {
                    WingmanStepLine(
                        text: inProgressText,
                        textColor: placement.agent.kind.chipTextColor,
                        playerName: placement.agent.player?.displayName
                    )
                    .fixedSize()
                    .offset(x: agentStyle.stepLineOffset)
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: placement.agent.inProgressText)
            // Before .position, so it grows around the triangle, not around the screen's center.
            .scaleEffect(isLeaving ? agentStyle.exitScale : 1)
            .opacity(isLeaving ? 0 : 1)
            .position(wingmanPosition)
            .animation(placement.agent.finishedResult == nil ? Self.followSpring(slot: placement.slot) : Self.hopSpring, value: wingmanPosition)
            .onAppear { leaveOnceTheAgentHasEnded() }
            .onChange(of: placement.agent.endedAt) { leaveOnceTheAgentHasEnded() }
    }

    /// The store removes an ended agent's wingman after it lingers, so the exit starts that long after the end.
    private func leaveOnceTheAgentHasEnded() {
        guard let endedAt = placement.agent.endedAt else { return }
        let exitSeconds = 0.4
        let secondsUntilTheExit = BackgroundAgent.secondsAWingmanLingersAfterItEnds - exitSeconds - Date().timeIntervalSince(endedAt)
        withAnimation(.easeIn(duration: exitSeconds).delay(max(0, secondsUntilTheExit))) {
            isLeaving = true
        }
    }
}
