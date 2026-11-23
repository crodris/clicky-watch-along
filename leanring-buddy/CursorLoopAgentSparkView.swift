//
//  CursorLoopAgentSparkView.swift
//  leanring-buddy
//
//  Draws the sparks background agents lap around the loop: one spark for each agent working on the video in front,
//  in the agent's color, lapping faster as its progress grows and finishing with a full lap. Under a request's loop
//  around the media the sparks ride the same line. With no such loop, a quiet track of the loop's outline carries them. Reduce Motion
//  has no spark: each agent is a still arc along the line, as long as its progress.
//

import SwiftUI

/// One agent line to draw on one screen, in that screen's overlay coordinates.
struct AgentLoopOnScreen: Equatable {
    /// The rectangle the line runs along, already 4 points outside the media.
    let lineRect: CGRect
    let seed: UInt64
    /// The agents in the order they joined the line.
    let agentIDs: [UUID]
    /// True when no request loop around the media draws the line, so the agents draw a quiet track for their sparks to lap.
    let drawsItsOwnTrack: Bool
    let isFadingOut: Bool
}

/// The phase of each agent's spark, kept between frames. The view advances it as it draws, which is the only way to keep
/// a spark continuous while its pace follows progress, since a frame's place depends on the paces before it.
private final class AgentSparkPhaseBook {
    private var phasesByAgentID: [UUID: AgentSparkPhase] = [:]

    /// The spark's phase at `now`. An agent seen for the first time starts at the place its number gives it.
    func phase(of agentID: UUID, agentNumber: Int, at now: TimeInterval, agentProgress: Double, agentHasFinished: Bool, agentIsPaused: Bool) -> AgentSparkPhase {
        var phase = phasesByAgentID[agentID] ?? AgentSparkPhase(startingLaps: AgentSparkTimeline.startingLaps(forAgentNumber: agentNumber))
        phase.advance(to: now, agentProgress: agentProgress, agentHasFinished: agentHasFinished, agentIsPaused: agentIsPaused)
        phasesByAgentID[agentID] = phase
        return phase
    }
}

struct CursorLoopAgentSparkView: View {
    let agentLoop: AgentLoopOnScreen
    /// Read each frame for each agent's progress and color, so the sparks follow the work without the store redrawing the overlay.
    let agentStore: BackgroundAgentStore
    /// The theme's accent, which the track is drawn in.
    let trackColor: Color
    /// Reduce Motion is passed in, since a test cannot set the environment value.
    let reduceMotionIsOn: Bool
    @State private var sparkPhaseBook = AgentSparkPhaseBook()
    @State private var hasAppeared: Bool

    /// `fadesInWhenItAppears` is false only for a render in a test, where `onAppear` never runs and the line would stay invisible.
    init(agentLoop: AgentLoopOnScreen, agentStore: BackgroundAgentStore, trackColor: Color, reduceMotionIsOn: Bool, fadesInWhenItAppears: Bool = true) {
        self.agentLoop = agentLoop
        self.agentStore = agentStore
        self.trackColor = trackColor
        self.reduceMotionIsOn = reduceMotionIsOn
        _hasAppeared = State(initialValue: !fadesInWhenItAppears)
    }

    private static let trackOpacity: Double = 0.45
    private static let trackWidthInPoints: CGFloat = 2
    private static let sparkRadiusInPoints: CGFloat = 4.5
    private static let sparkOutlineWidthInPoints: CGFloat = 1.5

    var body: some View {
        let outline = CursorLoopOutline.path(along: agentLoop.lineRect, seed: agentLoop.seed)
        Group {
            if reduceMotionIsOn {
                // A still arc moves only when the progress does, so a slow clock is enough.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Canvas { context, _ in drawTheStillArcs(of: agentsOnTheLine(), along: outline, in: &context) }
                }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    // Worked out here, outside the Canvas, for the reason `CursorLoopView` gives: a Canvas redraws only
                    // when a value its closure captured changes.
                    let sparks = sparksOnTheLine(at: ProcessInfo.processInfo.systemUptime)
                    Canvas { context, _ in drawTheSparks(sparks, along: outline, in: &context) }
                }
            }
        }
        .opacity(agentLoop.isFadingOut || !hasAppeared ? 0 : 1)
        .animation(.easeOut(duration: CursorLoopState.fadeOutSeconds), value: agentLoop.isFadingOut)
        .animation(.easeIn(duration: 0.3), value: hasAppeared)
        .allowsHitTesting(false)
        .onAppear { hasAppeared = true }
    }

    // MARK: - What each agent shows

    private func agentsOnTheLine() -> [CursorLoopAgentOnTheLine] {
        cursorLoopAgentsOnTheLine(agentIDs: agentLoop.agentIDs, agents: agentStore.agents, at: Date())
    }

    private struct SparkOnTheLine {
        let color: Color
        let shareAroundTheLine: Double
    }

    /// The agents whose spark still laps: a finished agent's spark goes once its last lap is complete.
    private func sparksOnTheLine(at now: TimeInterval) -> [SparkOnTheLine] {
        agentsOnTheLine().compactMap { (agentOnTheLine: CursorLoopAgentOnTheLine) -> SparkOnTheLine? in
            let phase = sparkPhaseBook.phase(
                of: agentOnTheLine.id,
                agentNumber: agentOnTheLine.agentNumber,
                at: now,
                agentProgress: agentOnTheLine.progress,
                agentHasFinished: agentOnTheLine.hasFinished,
                agentIsPaused: agentOnTheLine.isPaused
            )
            guard !phase.hasCompletedItsLastLap else { return nil }
            return SparkOnTheLine(color: agentOnTheLine.color, shareAroundTheLine: phase.shareAroundTheLine)
        }
    }

    // MARK: - Drawing

    private func drawTheTrackIfTheLoopDoesNot(_ outline: Path, in context: inout GraphicsContext) {
        guard agentLoop.drawsItsOwnTrack else { return }
        context.stroke(
            outline,
            with: .color(trackColor.opacity(Self.trackOpacity)),
            style: StrokeStyle(lineWidth: Self.trackWidthInPoints, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawTheSparks(_ sparks: [SparkOnTheLine], along outline: Path, in context: inout GraphicsContext) {
        drawTheTrackIfTheLoopDoesNot(outline, in: &context)
        for spark in sparks {
            let sparkCenter = outline.trimmedPath(from: 0, to: max(spark.shareAroundTheLine, 0.0005)).currentPoint ?? agentLoop.lineRect.origin
            let sparkPath = Path(ellipseIn: CGRect(
                x: sparkCenter.x - Self.sparkRadiusInPoints,
                y: sparkCenter.y - Self.sparkRadiusInPoints,
                width: Self.sparkRadiusInPoints * 2,
                height: Self.sparkRadiusInPoints * 2
            ))
            // The request loop's spark is white inside the accent, so an agent's is the opposite: its own color inside white.
            context.drawLayer { sparkLayer in
                sparkLayer.addFilter(.shadow(color: spark.color.opacity(0.55), radius: 5))
                sparkLayer.fill(sparkPath, with: .color(spark.color))
                sparkLayer.stroke(sparkPath, with: .color(.white), lineWidth: Self.sparkOutlineWidthInPoints)
            }
        }
    }

    /// Each agent's progress as an arc from the line's start, the longest first so a shorter one shows on top of it.
    private func drawTheStillArcs(of agents: [CursorLoopAgentOnTheLine], along outline: Path, in context: inout GraphicsContext) {
        drawTheTrackIfTheLoopDoesNot(outline, in: &context)
        for agentOnTheLine in agents.sorted(by: { $0.progress > $1.progress }) {
            let arcShare = min(1, max(0, agentOnTheLine.progress))
            guard arcShare > 0 else { continue }
            // The same line the loop and the room art loop draw, so an arc sits on the request loop's line without a seam.
            CursorLoopDrawing.drawTheLine(outline, share: arcShare, color: agentOnTheLine.color, in: &context)
        }
    }
}

// MARK: - What each agent shows

/// One agent on the line, as the view draws it: its color, progress, whether it finished, and whether its spark holds still.
struct CursorLoopAgentOnTheLine: Equatable {
    let id: UUID
    let color: Color
    let progress: Double
    let hasFinished: Bool
    /// True while the learner has paused every agent, which holds the spark still.
    let isPaused: Bool
    let agentNumber: Int
}

/// The agents the line shows, in the order they joined, for the ones the store still has. Each carries the flags the spark
/// reads, the paused flag included, so a test can pin what the view hands each spark.
func cursorLoopAgentsOnTheLine(agentIDs: [UUID], agents: [BackgroundAgent], at now: Date) -> [CursorLoopAgentOnTheLine] {
    agentIDs.enumerated().compactMap { agentNumber, agentID -> CursorLoopAgentOnTheLine? in
        guard let agent = agents.first(where: { $0.id == agentID }) else { return nil }
        return CursorLoopAgentOnTheLine(
            id: agentID,
            color: agent.displayColor.color,
            progress: agent.progress(at: now),
            hasFinished: agent.loopSparkStatus == .finished,
            isPaused: agent.loopSparkIsHeldStill,
            agentNumber: agentNumber
        )
    }
}
