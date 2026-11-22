//
//  AgentTokenViews.swift
//  leanring-buddy
//
//  What an agent token looks like. Each background agent that runs, or whose result waits, is a 22 point disc beside
//  the notch: a progress ring (an opaque dark track, filled in the team's color or the agent's own color) around a face,
//  which is a roster player's portrait, a theme's picture, or a triangle in the agent's color. The state shows by shape, so
//  a theme may use any ring color: a finished agent gets a green check badge, a failed one a cross badge on a gray face in
//  a red ring, and one that waits for the learner's OK a "!" face and a notch in its ring (`agentTokenBadge` still names
//  that badge, which no surface draws now). The "+N" disc counts the agents with no position of their own, and the open
//  slot is the dashed outline a new agent's token flies to.
//  Motion is one-shot, except two loops that run on Core Animation (`AgentTokenLoopView`), so the render server plays them
//  and the main thread draws nothing per frame, since a SwiftUI loop pegs the GPU on high-refresh displays: a running agent's
//  bright dot orbits its ring every 3 seconds, so a slow agent still looks alive, and a waiting approval's disc pulses
//  once every 1.6 seconds. With Reduce Motion on, the dot only fades in and out at the top of the ring and the pulse
//  is a still halo, so the shape of the state still shows.
//  The agent list's rows draw the same disc at its own size.
//

import AppKit
import SwiftUI

// MARK: - Token disc

/// One agent's disc. The ring fills in a straight line with the agent's progress, from 12 o'clock, clockwise.
struct AgentTokenDiscView: View {
    let agent: BackgroundAgent
    /// Whether the agent has a request in the approval desk.
    var isWaitingForApproval = false
    /// Set by the dock while the mouse is over the disc.
    var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotionIsOn

    /// The gap the "!" badge's notch cuts in the ring at 12 o'clock, as a share of the ring.
    private static let approvalNotchShareOfTheRing = 0.12

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
        if isWaitingForApproval {
            // The "!" is the state's shape, so amber is never the only signal.
            Circle()
                .fill(DS.Colors.agentTokenFace)
                .frame(width: faceDiameter, height: faceDiameter)
                .overlay(
                    Text("!")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundColor(DS.Colors.warning)
                )
        } else if case .rosterFace(let rosterFace) = agent.face {
            RosterFaceView(rosterFace: rosterFace, size: faceDiameter, isGrayscale: agent.phase.isFailed)
        } else if case .themePicture(let themeID) = agent.face, let themePicture = CustomThemePictureCache.image(forThemeID: themeID) {
            ThemePictureFaceView(picture: themePicture, size: faceDiameter, isGrayscale: agent.phase.isFailed)
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
            if isWaitingForApproval {
                // The notch: the track's color drawn over the ring, centered on 12 o'clock.
                Circle()
                    .trim(from: 0, to: Self.approvalNotchShareOfTheRing)
                    .stroke(DS.Colors.agentTokenTrack, style: StrokeStyle(lineWidth: Self.ringWidth + 0.5, lineCap: .butt))
                    .rotationEffect(.degrees(-90 - 180 * Self.approvalNotchShareOfTheRing))
                    .padding(Self.ringWidth / 2)
            }
            face
            if agent.isRunning && !isWaitingForApproval {
                AgentTokenLoopView(loop: .orbitingDot, reduceMotionIsOn: reduceMotionIsOn)
            }
            if isWaitingForApproval {
                AgentTokenLoopView(loop: .approvalPulse, reduceMotionIsOn: reduceMotionIsOn)
            }
        }
        .frame(width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter)
        .agentTokenEdgeAndShadow(isHovered: isHovered, edgeWidth: Self.edgeWidth)
        .overlay(alignment: .bottomTrailing) {
            if let badge = agentTokenBadgeOnTheDisc(phase: agent.phase, isWaitingForApproval: isWaitingForApproval) {
                // Dark rim and the same size as the design's badge, so the badge reads on a light menu bar too.
                // The 2 point offset keeps the whole rim inside the disc's panel, which is as tall as the menu bar. A screenshot of
                // a 1080p display's bar showed a 3 point offset cutting the rim's bottom, and 2 points leaving it whole.
                AgentTokenBadgeView(badge: badge, size: 11)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .offset(x: 2, y: 2)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        // The badge pops in and the ring settles, as the moves say a disc's phase and check do.
        .animation(DS.Move.pop.animation(reduceMotionIsOn: reduceMotionIsOn), value: agent.phase)
        .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotionIsOn), value: isWaitingForApproval)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let kindName = agent.kind.displayName
        if isWaitingForApproval { return "\(kindName) agent needs your OK" }
        switch agent.phase {
        case .running: return "\(kindName) agent running"
        case .finished: return agent.resultIsWaitingToBeDelivered ? "\(kindName) agent done, result ready" : "\(kindName) agent done"
        case .failed: return "\(kindName) agent failed"
        case .cancelled: return "\(kindName) agent cancelled"
        }
    }
}

/// A custom theme's picture as an agent's round face, where a team theme shows a player's portrait.
struct ThemePictureFaceView: View {
    let picture: NSImage
    let size: CGFloat
    /// Failed agents show a gray face, as a failed player's portrait does.
    var isGrayscale = false

    var body: some View {
        Image(nsImage: picture)
            .resizable()
            .scaledToFill()
            .grayscale(isGrayscale ? 1 : 0)
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

/// How the "+N" text fits the 22 point disc. Two digits use smaller type than one, and the text keeps a margin on each
/// side, so "+10" and "+99" stay clear of the 1.5 point edge. A count past two digits shrinks to fit.
enum AgentOverflowDiscText {
    static let horizontalPadding: CGFloat = 2

    static func fontSize(overflowCount: Int) -> CGFloat {
        overflowCount >= 10 ? 8 : 9
    }
}

/// The "+N" disc for the agents that have no position of their own, in the same dark disc as a face.
struct AgentOverflowDiscView: View {
    let overflowCount: Int
    var isHovered = false

    var body: some View {
        Text("+\(overflowCount)")
            .font(.system(size: AgentOverflowDiscText.fontSize(overflowCount: overflowCount), weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)
            // A three digit count is cut down to fit instead of touching the edge.
            .minimumScaleFactor(0.7)
            .padding(.horizontal, AgentOverflowDiscText.horizontalPadding)
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

extension View {
    /// A 1.5 point dark edge outside the disc and a soft shadow, so the disc reads on a light menu bar and a bright
    /// wallpaper whatever its face color. Hovering grows the disc a little, which tells the learner it takes a click.
    func agentTokenEdgeAndShadow(isHovered: Bool, edgeWidth: CGFloat) -> some View {
        modifier(AgentTokenEdgeAndShadow(isHovered: isHovered, edgeWidth: edgeWidth))
    }
}

private struct AgentTokenEdgeAndShadow: ViewModifier {
    let isHovered: Bool
    let edgeWidth: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotionIsOn

    func body(content: Content) -> some View {
        content
            .overlay(Circle().stroke(Color.black.opacity(0.75), lineWidth: edgeWidth).padding(-edgeWidth / 2))
            .shadow(color: .black.opacity(0.55), radius: 2, x: 0, y: 1.5)
            // Under Reduce Motion the Snap move is a fade, so the disc keeps its size and the peek card carries the hover.
            .scaleEffect(isHovered && !reduceMotionIsOn ? 1.08 : 1)
            .animation(DS.Move.snap.animation(reduceMotionIsOn: reduceMotionIsOn), value: isHovered)
    }
}

// MARK: - Looping motion on Core Animation

/// The two loops a disc runs. Core Animation plays them, so the main thread draws nothing per frame.
enum AgentTokenLoop {
    /// A bright dot that circles the ring clockwise once every `secondsPerTurn`, on a running agent's disc.
    case orbitingDot
    /// A soft ring that grows out of the disc and fades once every `secondsPerPulse`, on a disc that waits for the learner's OK.
    case approvalPulse

    static let secondsPerTurn: TimeInterval = 3
    static let secondsPerPulse: TimeInterval = 1.6
    /// How much larger than the disc the pulse's ring gets. A disc sits in a menu bar only a little taller than itself on
    /// a display with no notch, so the pulse stays small enough to show whole there.
    static let pulseEndScale: CGFloat = 1.12
    /// With Reduce Motion on, the dot fades between these opacities over `secondsPerTurn` at the top of the ring.
    static let reducedMotionDotOpacities: (dim: Float, bright: Float) = (0.25, 1)
    /// With Reduce Motion on, the pulse is a ring that stays at this opacity and scale.
    static let reducedMotionPulseOpacity: Float = 0.5
    static let reducedMotionPulseScale: CGFloat = 1.06
}

/// Hosts one loop in a layer, sized to a disc. SwiftUI sizes it to a disc, and the layers follow its bounds.
struct AgentTokenLoopView: NSViewRepresentable {
    let loop: AgentTokenLoop
    let reduceMotionIsOn: Bool

    func makeNSView(context: Context) -> AgentTokenLoopHostView {
        AgentTokenLoopHostView(loop: loop, reduceMotionIsOn: reduceMotionIsOn)
    }

    func updateNSView(_ hostView: AgentTokenLoopHostView, context: Context) {
        hostView.update(reduceMotionIsOn: reduceMotionIsOn)
    }
}

final class AgentTokenLoopHostView: NSView {
    private let loop: AgentTokenLoop
    private var reduceMotionIsOn: Bool
    private let loopLayer = CALayer()

    init(loop: AgentTokenLoop, reduceMotionIsOn: Bool) {
        self.loop = loop
        self.reduceMotionIsOn = reduceMotionIsOn
        super.init(frame: NSRect(x: 0, y: 0, width: AgentTokenMetrics.discDiameter, height: AgentTokenMetrics.discDiameter))
        wantsLayer = true
        layer?.addSublayer(loopLayer)
        rebuildLoopLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Created in code only") }

    /// The loop never takes a click, since the disc under it does.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        loopLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        loopLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func update(reduceMotionIsOn newReduceMotionIsOn: Bool) {
        guard newReduceMotionIsOn != reduceMotionIsOn else { return }
        reduceMotionIsOn = newReduceMotionIsOn
        rebuildLoopLayers()
    }

    /// Builds the loop's layers and animation again, which Reduce Motion changing needs.
    private func rebuildLoopLayers() {
        loopLayer.sublayers = nil
        loopLayer.removeAllAnimations()
        loopLayer.transform = CATransform3DIdentity
        loopLayer.opacity = 1
        let diameter = AgentTokenMetrics.discDiameter
        loopLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        loopLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)

        switch loop {
        case .orbitingDot:
            let dotDiameter: CGFloat = 3.4
            let dotLayer = CALayer()
            dotLayer.backgroundColor = NSColor.white.cgColor
            dotLayer.cornerRadius = dotDiameter / 2
            dotLayer.bounds = CGRect(x: 0, y: 0, width: dotDiameter, height: dotDiameter)
            // At 12 o'clock on the ring's center line. Layer y grows upward, so the top is the larger y.
            dotLayer.position = CGPoint(x: diameter / 2, y: diameter - 1.25 - dotDiameter / 2)
            dotLayer.shadowColor = NSColor.black.cgColor
            dotLayer.shadowOpacity = 0.5
            dotLayer.shadowRadius = 1
            dotLayer.shadowOffset = .zero
            loopLayer.addSublayer(dotLayer)
            if reduceMotionIsOn {
                let breathing = CABasicAnimation(keyPath: "opacity")
                breathing.fromValue = AgentTokenLoop.reducedMotionDotOpacities.dim
                breathing.toValue = AgentTokenLoop.reducedMotionDotOpacities.bright
                breathing.duration = AgentTokenLoop.secondsPerTurn / 2
                breathing.autoreverses = true
                breathing.repeatCount = .infinity
                breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dotLayer.add(breathing, forKey: "dot.breathing")
            } else {
                let turning = CABasicAnimation(keyPath: "transform.rotation.z")
                // A negative turn is clockwise, since the layer's y grows upward.
                turning.fromValue = 0
                turning.toValue = -2 * Double.pi
                turning.duration = AgentTokenLoop.secondsPerTurn
                turning.repeatCount = .infinity
                loopLayer.add(turning, forKey: "dot.turn")
            }
        case .approvalPulse:
            let pulseLayer = CAShapeLayer()
            pulseLayer.path = CGPath(ellipseIn: CGRect(x: 0.75, y: 0.75, width: diameter - 1.5, height: diameter - 1.5), transform: nil)
            pulseLayer.fillColor = nil
            pulseLayer.strokeColor = NSColor(DS.Colors.warning).cgColor
            pulseLayer.lineWidth = 1.5
            pulseLayer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            pulseLayer.position = CGPoint(x: diameter / 2, y: diameter / 2)
            loopLayer.addSublayer(pulseLayer)
            if reduceMotionIsOn {
                pulseLayer.opacity = AgentTokenLoop.reducedMotionPulseOpacity
                pulseLayer.transform = CATransform3DMakeScale(AgentTokenLoop.reducedMotionPulseScale, AgentTokenLoop.reducedMotionPulseScale, 1)
            } else {
                let growing = CABasicAnimation(keyPath: "transform.scale")
                growing.fromValue = 1
                growing.toValue = AgentTokenLoop.pulseEndScale
                let fading = CABasicAnimation(keyPath: "opacity")
                fading.fromValue = 0.8
                fading.toValue = 0
                let pulse = CAAnimationGroup()
                pulse.animations = [growing, fading]
                pulse.duration = AgentTokenLoop.secondsPerPulse
                pulse.repeatCount = .infinity
                pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
                pulseLayer.add(pulse, forKey: "pulse")
            }
        }
    }
}

// MARK: - Agent triangle

/// One agent's triangle. No surface draws it now, since the agent list's rows draw the agent's disc.
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
            // A pause stops the ring where it is, and a resume heads it on from there.
            .onChange(of: agent.pausedAt) { followTheProgress() }
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

/// The badge at a token's lower right, which says the agent's state by its shape, so no ring color has to.
enum AgentTokenBadge: Equatable {
    case done
    case failed
    /// The agent waits for the learner's OK. It wins over the others, since it is the one state that needs the learner.
    case needsYourOK
}

/// The badge a token shows, or nil for a running or cancelled agent with nothing waiting.
func agentTokenBadge(phase: BackgroundAgentPhase, isWaitingForApproval: Bool) -> AgentTokenBadge? {
    if isWaitingForApproval { return .needsYourOK }
    switch phase {
    case .finished: return .done
    case .failed: return .failed
    case .running, .cancelled: return nil
    }
}

/// The badge a disc draws at its lower right. A waiting approval is the "!" face and the notch instead, so only a finished or
/// failed agent gets a badge on its disc.
func agentTokenBadgeOnTheDisc(phase: BackgroundAgentPhase, isWaitingForApproval: Bool) -> AgentTokenBadge? {
    let badge = agentTokenBadge(phase: phase, isWaitingForApproval: isWaitingForApproval)
    return badge == .needsYourOK ? nil : badge
}

struct AgentTokenBadgeView: View {
    let badge: AgentTokenBadge
    let size: CGFloat

    var body: some View {
        switch badge {
        case .done:
            FinishedCheckMark(size: size)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: size * 0.5, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(DS.Colors.destructive))
        case .needsYourOK:
            Text("!")
                .font(.system(size: size * 0.72, weight: .heavy, design: .rounded))
                .foregroundColor(.black)
                .frame(width: size, height: size)
                .background(Circle().fill(DS.Colors.warning))
        }
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
