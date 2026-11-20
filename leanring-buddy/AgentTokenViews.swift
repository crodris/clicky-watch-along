//
//  AgentTokenViews.swift
//  leanring-buddy
//
//  What an agent token looks like. Each background agent that runs, or whose result waits, is a 22 point disc beside
//  the notch: a progress ring (an opaque dark track, filled in the team's color or the agent's own color) around a face,
//  which is the team player's portrait or a triangle in the agent's color. A finished agent gets a green check mark, and a failed one
//  a gray face in a red ring. The "+N" disc counts the agents with no position of their own, and the open slot is the dashed
//  outline a new agent's token flies to.
//  Motion here is one-shot only. Nothing pulses or spins, because a looping animation pegs the GPU on high-refresh displays.
//  The same triangle and progress view also draw the agent list's rows.
//

import SwiftUI

// MARK: - Token disc

/// One agent's disc. The ring fills in a straight line with the agent's progress, from 12 o'clock, clockwise.
struct AgentTokenDiscView: View {
    let agent: BackgroundAgent
    /// Set by the dock while the mouse is over the disc.
    var isHovered = false

    private static let ringWidth: CGFloat = 2.5
    private static let edgeWidth: CGFloat = 1.5

    /// A finished agent keeps its ring color and a full ring. A failed agent's ring is full and red, since the red says the
    /// state and its phase does not keep how far it got.
    private func ringProgress(shownProgress: Double) -> Double {
        switch agent.phase {
        case .running, .finished: return shownProgress
        case .failed: return 1
        case .cancelled: return 0
        }
    }

    private var faceDiameter: CGFloat {
        AgentTokenMetrics.discDiameter - 2 * Self.ringWidth
    }

    @ViewBuilder private var face: some View {
        if let player = agent.player {
            HaikyuPortraitView(player: player, size: faceDiameter, isGrayscale: agent.phase.isFailed)
        } else {
            Circle()
                .fill(DS.Colors.agentTokenFace)
                .frame(width: faceDiameter, height: faceDiameter)
                .overlay(
                    Triangle()
                        .fill(agent.displayColor.color)
                        .frame(width: 11, height: 11)
                        .rotationEffect(.degrees(-35))
                )
                .grayscale(agent.phase.isFailed ? 1 : 0)
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(DS.Colors.agentTokenTrack)
            AgentProgressView(agent: agent) { shownProgress in
                Circle()
                    .trim(from: 0, to: ringProgress(shownProgress: shownProgress))
                    .stroke(agentTokenRingColorChoice(for: agent).color, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .padding(Self.ringWidth / 2)
            }
            face
        }
        .frame(width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter)
        .agentTokenEdgeAndShadow(isHovered: isHovered, edgeWidth: Self.edgeWidth)
        .overlay(alignment: .bottomTrailing) {
            if agent.finishedResult != nil {
                // Dark rim and the same size as the design's badge, so the check reads on a light menu bar too.
                // The 2 point offset keeps the whole rim inside the disc's panel, which is as tall as the menu bar. A screenshot of
                // a 1080p display's bar showed a 3 point offset cutting the rim's bottom, and 2 points leaving it whole.
                FinishedCheckMark(size: 11)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .offset(x: 2, y: 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: agent.phase)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let kindName = agent.kind.displayName
        switch agent.phase {
        case .running: return "\(kindName) agent running"
        case .finished: return agent.resultIsWaitingToBeDelivered ? "\(kindName) agent done, result ready" : "\(kindName) agent done"
        case .failed: return "\(kindName) agent failed"
        case .cancelled: return "\(kindName) agent cancelled"
        }
    }
}

/// The "+N" disc for the agents that have no position of their own, in the same dark disc as a face.
struct AgentOverflowDiscView: View {
    let overflowCount: Int
    var isHovered = false

    var body: some View {
        Text("+\(overflowCount)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter)
            .background(Circle().fill(DS.Colors.agentTokenFace))
            .agentTokenEdgeAndShadow(isHovered: isHovered, edgeWidth: 1.5)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(overflowCount) more agents")
    }
}

/// The open slot a token is about to land in: a dashed outline the size of a disc, shown while the token flies there from
/// the cursor. A faint dark fill keeps the white dashes readable on a light menu bar.
struct AgentOpenSlotView: View {
    var body: some View {
        Circle()
            .fill(Color.black.opacity(0.3))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])))
            .frame(width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter)
            .accessibilityHidden(true)
    }
}

private extension View {
    /// A 1.5 point dark edge outside the disc and a soft shadow, so the disc reads on a light menu bar and a bright
    /// wallpaper whatever its face color. Hovering grows the disc a little, which tells the learner it takes a click.
    func agentTokenEdgeAndShadow(isHovered: Bool, edgeWidth: CGFloat) -> some View {
        overlay(Circle().stroke(Color.black.opacity(0.75), lineWidth: edgeWidth).padding(-edgeWidth / 2))
            .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1.5)
            .scaleEffect(isHovered ? 1.08 : 1)
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

// MARK: - Agent triangle

/// One agent's triangle, drawn small in the agent list's rows.
struct AgentTriangleView: View {
    let agent: BackgroundAgent
    var size: CGFloat = 11

    /// The same tilt as the blue cursor triangle's resting pose.
    private static let rotationDegrees = -35.0

    /// A finished agent keeps its color and gets a green check mark, so the learner still sees which agent it was.
    /// A failed one is a red outline, and a cancelled one is a gray outline.
    private var color: Color {
        switch agent.phase {
        case .running, .finished: return agent.displayColor.color
        case .failed: return DS.Colors.destructive
        case .cancelled: return DS.Colors.textTertiary
        }
    }

    var body: some View {
        ZStack {
            // The fill is drawn before the rotation, so it rises along the triangle's own axis from tail to tip.
            AgentProgressView(agent: agent) { shownProgress in
                AgentTriangleFill(progress: shownProgress)
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

/// Shows an agent's progress as it moves. It starts at progress(at:) and runs one straight-line animation to where the
/// current step heads, timed by the clock, so the token and the agent list show the same progress at the same moment,
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
nonisolated func agentTriangleFillHeightShare(forProgress progress: Double) -> Double {
    1 - (1 - min(1, max(0, progress))).squareRoot()
}

/// The filled part of the agent's triangle, from the base up. Animatable, so the area follows the progress in every
/// frame of an animation, not just at its ends.
struct AgentTriangleFill: Shape {
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
        let fillTopY = baseY - triangleHeight * agentTriangleFillHeightShare(forProgress: progress)
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

/// A white check on a green dot, at the base of a finished agent's token or triangle.
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
