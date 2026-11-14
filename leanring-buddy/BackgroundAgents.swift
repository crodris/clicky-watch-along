//
//  BackgroundAgents.swift
//  leanring-buddy
//
//  The record of work Clicky does in the background while the learner watches a video, such as writing
//  a Notion study guide. The store is the one source of truth that the wingmen next to the blue cursor
//  and the agent list both read. Nothing here draws or talks to the network.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Agent

/// What a background agent does. A new kind adds a case here and fills in its name, color, and steps.
enum BackgroundAgentKind {
    case studyGuide

    var displayName: String {
        switch self {
        case .studyGuide: return "Study guide"
        }
    }

    var color: Color {
        switch self {
        case .studyGuide: return DS.Colors.backgroundAgentStudyGuideAmber
        }
    }

    /// The steps in order. The agent finishes by finishing its last step, so completeStep never moves past the last one.
    var stepNames: [String] {
        switch self {
        case .studyGuide: return ["Read the captions", "Write the guide in Notion"]
        }
    }
}

/// What a finished agent made. The ending Clicky plays for a finished agent is chosen by switching on this.
enum BackgroundAgentResult: Equatable {
    case notionPage(URL)
}

enum BackgroundAgentPhase: Equatable {
    case running(completedStepCount: Int)
    case finished(BackgroundAgentResult)
    case failed(reason: String)
    case cancelled
}

struct BackgroundAgent: Identifiable, Equatable {
    let id: UUID
    let kind: BackgroundAgentKind
    /// The video's title, set once the agent knows which video it works on.
    var subject: String?
    let startedAt: Date
    var endedAt: Date?
    var phase: BackgroundAgentPhase

    /// How much of the wingman's triangle is filled, from its tail to its tip.
    /// A failed or cancelled agent shows an empty outline, because its phase does not keep how far it got.
    var filledFraction: Double {
        switch phase {
        case .running(let completedStepCount):
            return Double(completedStepCount) / Double(kind.stepNames.count)
        case .finished:
            return 1
        case .failed, .cancelled:
            return 0
        }
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var finishedResult: BackgroundAgentResult? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    /// How long a finished or failed agent stays beside the cursor after it ends, so the learner sees how it went.
    static let secondsAWingmanLingersAfterItEnds: TimeInterval = 4

    /// A running agent shows. A finished or failed one shows for a few seconds after it ends.
    /// A cancelled one leaves at once, since the learner asked for that.
    func isShownAsAWingman(at now: Date) -> Bool {
        switch phase {
        case .running:
            return true
        case .finished, .failed:
            guard let endedAt else { return false }
            return now.timeIntervalSince(endedAt) < Self.secondsAWingmanLingersAfterItEnds
        case .cancelled:
            return false
        }
    }

    /// Seconds from start to the end, or to `now` while it runs.
    func elapsedSeconds(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

enum BackgroundAgentStepStatus: Equatable {
    case done
    case current
    case pending

    var symbol: String {
        switch self {
        case .done: return "✓"
        case .current: return "●"
        case .pending: return "○"
        }
    }
}

extension BackgroundAgent {
    /// One status per step, in order, for the list's expanded row. A failed or cancelled agent has none,
    /// because its phase does not keep how far it got, and the list shows its reason instead.
    var stepStatuses: [BackgroundAgentStepStatus] {
        let stepCount = kind.stepNames.count
        switch phase {
        case .running(let completedStepCount):
            return (0..<stepCount).map { stepIndex in
                if stepIndex < completedStepCount { return .done }
                return stepIndex == completedStepCount ? .current : .pending
            }
        case .finished:
            return Array(repeating: .done, count: stepCount)
        case .failed, .cancelled:
            return []
        }
    }
}

/// "0:42" or "12:05".
func backgroundAgentElapsedTimeText(seconds: TimeInterval) -> String {
    let wholeSeconds = Int(seconds)
    return "\(wholeSeconds / 60):" + String(format: "%02d", wholeSeconds % 60)
}

// MARK: - Store

@MainActor
final class BackgroundAgentStore: ObservableObject {
    /// Newest first.
    @Published private(set) var agents: [BackgroundAgent] = []

    private static let mostAgentsKept = 10

    @discardableResult
    func start(kind: BackgroundAgentKind) -> UUID {
        let agent = BackgroundAgent(id: UUID(), kind: kind, subject: nil, startedAt: Date(), endedAt: nil, phase: .running(completedStepCount: 0))
        agents.insert(agent, at: 0)
        agents = Array(agents.prefix(Self.mostAgentsKept))
        return agent.id
    }

    func setSubject(_ subject: String, for agentID: UUID) {
        updateRunningAgent(agentID) { agent in
            agent.subject = subject
        }
    }

    func completeStep(for agentID: UUID) {
        updateRunningAgent(agentID) { agent in
            guard case .running(let completedStepCount) = agent.phase,
                  completedStepCount < agent.kind.stepNames.count - 1 else { return }
            agent.phase = .running(completedStepCount: completedStepCount + 1)
        }
    }

    func finish(_ agentID: UUID, with result: BackgroundAgentResult) {
        endRunningAgent(agentID, in: .finished(result))
    }

    func fail(_ agentID: UUID, reason: String) {
        endRunningAgent(agentID, in: .failed(reason: reason))
    }

    func cancel(_ agentID: UUID) {
        endRunningAgent(agentID, in: .cancelled)
    }

    /// Only a running agent changes. A step, a result, or a cancel that arrives after the agent ended does nothing.
    /// Returns whether the agent changed.
    @discardableResult
    private func updateRunningAgent(_ agentID: UUID, _ change: (inout BackgroundAgent) -> Void) -> Bool {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }), agents[agentIndex].isRunning else { return false }
        change(&agents[agentIndex])
        return true
    }

    private func endRunningAgent(_ agentID: UUID, in endPhase: BackgroundAgentPhase) {
        let agentEnded = updateRunningAgent(agentID) { agent in
            agent.phase = endPhase
            agent.endedAt = Date()
        }
        guard agentEnded else { return }
        // The wingman of a finished or failed agent leaves on its own, so the views that show it need one more refresh then.
        Task {
            try? await Task.sleep(for: .seconds(BackgroundAgent.secondsAWingmanLingersAfterItEnds + 0.05))
            objectWillChange.send()
        }
    }
}

// MARK: - Formation

/// Where each wingman sits behind the blue triangle. The wingmen of the three newest agents trail down and to the right,
/// along the triangle's tail, and the rest are counted in the overflow.
struct WingmanFormation: Equatable {
    struct Placement: Equatable {
        let agent: BackgroundAgent
        /// Position in the trail, counted from the blue triangle. It sets how loosely the wingman follows the cursor.
        let slot: Int
        /// From the blue triangle's center, in points.
        let offset: CGSize
    }

    static let mostWingmen = 3

    /// A finished agent's wingman hops from its slot to just ahead of the blue triangle's tip, which points up and to the left.
    static let aheadOfTheTipOffset = CGSize(width: -14, height: -20)

    static func offset(forSlot slot: Int) -> CGSize {
        CGSize(width: 15 * CGFloat(slot + 1), height: 18 * CGFloat(slot + 1))
    }

    let placements: [Placement]
    let overflowCount: Int
}

/// `agentsToShow` is newest first. A finished agent takes the spot ahead of the tip and no slot in the trail,
/// so the trail has no gap while it waits to leave.
func wingmanFormation(for agentsToShow: [BackgroundAgent]) -> WingmanFormation {
    let agentsInTheTrail = agentsToShow.filter { $0.finishedResult == nil }
    let finishedPlacements = agentsToShow.filter { $0.finishedResult != nil }.map { finishedAgent in
        WingmanFormation.Placement(agent: finishedAgent, slot: 0, offset: WingmanFormation.aheadOfTheTipOffset)
    }
    let trailPlacements = agentsInTheTrail.prefix(WingmanFormation.mostWingmen).enumerated().map { slot, agent in
        WingmanFormation.Placement(agent: agent, slot: slot, offset: WingmanFormation.offset(forSlot: slot))
    }
    return WingmanFormation(
        placements: finishedPlacements + trailPlacements,
        overflowCount: max(0, agentsInTheTrail.count - WingmanFormation.mostWingmen)
    )
}
