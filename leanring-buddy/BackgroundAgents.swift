//
//  BackgroundAgents.swift
//  leanring-buddy
//
//  The record of work Clicky does in the background while the learner watches a video, such as writing
//  a Notion study guide or building a 3D model. The store is the one source of truth that the wingmen next to the blue cursor
//  and the agent list both read. Nothing here draws or talks to the network.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Agent

/// One step of an agent's work, with about how long it takes, which sets how fast the wingman fills while it runs.
struct BackgroundAgentStep: Equatable {
    /// The step as a checklist item in the agent list, such as "Read the captions".
    let name: String
    /// What the wingman's line says while the step runs, such as "Reading the captions".
    let inProgressText: String
    let expectedSeconds: TimeInterval
}

/// What a background agent does. A new kind adds a case here and fills in its name, color, and steps.
enum BackgroundAgentKind {
    case studyGuide
    /// Rebuilds a guide's page with the newest quiz results after a missed question, keeping the guide's words.
    case studyGuideUpdate
    /// Builds a 3D model of what the video shows while it keeps playing, and lifts it out of the video when it is ready.
    case threeDModel
    /// Works on any task the learner hands it, with web search, the video's captions, and a Notion page, and reports its
    /// own steps, since nobody knows them in advance.
    case task

    var displayName: String {
        switch self {
        case .studyGuide: return "Study guide"
        case .studyGuideUpdate: return "Study guide update"
        case .threeDModel: return "3D model"
        case .task: return "Task"
        }
    }

    /// Both guide kinds work on the same guide, so they share its amber.
    var color: Color {
        switch self {
        case .studyGuide, .studyGuideUpdate: return DS.Colors.backgroundAgentStudyGuideAmber
        case .threeDModel: return DS.Colors.backgroundAgentThreeDModelViolet
        case .task: return DS.Colors.backgroundAgentTaskTeal
        }
    }

    /// A darker shade of the same hue for the chip's letters, since the wingman's color is too light to read
    /// inside a white outline.
    var chipTextColor: Color {
        switch self {
        case .studyGuide, .studyGuideUpdate: return DS.Colors.backgroundAgentStudyGuideAmberText
        case .threeDModel: return DS.Colors.backgroundAgentThreeDModelVioletText
        case .task: return DS.Colors.backgroundAgentTaskTealText
        }
    }

    /// What the chip under the cursor says when the agent finishes.
    var finishedChipText: String {
        switch self {
        case .studyGuide: return "Study guide ready"
        case .studyGuideUpdate: return "Study guide updated"
        case .threeDModel: return "3D model ready"
        case .task: return "Task done"
        }
    }

    /// The steps in order. The agent finishes by finishing its last step, so completeStep never moves past the last one.
    /// Reading the captions with yt-dlp took about 3 seconds, and writing the guide 10 to 14, in the demo recordings.
    /// An update reads the captions the quiz already holds, and rebuilds the page with no model call.
    /// A 3D model's screenshot takes under a second, and `POST /live-scene` about 20 seconds.
    var steps: [BackgroundAgentStep] {
        switch self {
        case .studyGuide:
            return [
                BackgroundAgentStep(name: "Read the captions", inProgressText: "Reading the captions", expectedSeconds: 3),
                BackgroundAgentStep(name: "Write the guide in Notion", inProgressText: "Writing the guide in Notion", expectedSeconds: 12),
            ]
        case .studyGuideUpdate:
            return [
                BackgroundAgentStep(name: "Read the quiz results", inProgressText: "Reading your quiz results", expectedSeconds: 1),
                BackgroundAgentStep(name: "Add the miss to the guide", inProgressText: "Adding your miss to the guide", expectedSeconds: 3),
            ]
        case .threeDModel:
            return [
                BackgroundAgentStep(name: "Grab the frame", inProgressText: "Grabbing the frame", expectedSeconds: 1),
                BackgroundAgentStep(name: "Build the 3D model", inProgressText: "Building the 3D model", expectedSeconds: 20),
            ]
        // A task's steps come from the agent as it works (BackgroundAgent.reportedSteps), so its progress runs as one
        // step. A web search answer took about 11 seconds in a test, and one with a Notion page takes longer.
        case .task:
            return [BackgroundAgentStep(name: "Work on the task", inProgressText: "Getting started", expectedSeconds: 45)]
        }
    }

    var stepNames: [String] {
        steps.map(\.name)
    }
}

/// What a finished agent made. The ending Clicky plays for a finished agent is chosen by switching on this.
enum BackgroundAgentResult: Equatable {
    case notionPage(URL)
    /// The page itself waits in CompanionManager until it rises out of the video.
    case threeDModel
    /// What a task agent found, read aloud when the learner asks, and the Notion page it wrote, if it wrote one.
    case answer(spokenSummary: String, pageURL: URL?)

    var pageURL: URL? {
        switch self {
        case .notionPage(let pageURL): return pageURL
        case .threeDModel: return nil
        case .answer(_, let pageURL): return pageURL
        }
    }
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
    /// What the agent works on, once it knows: the video's title for a guide, and the learner's words for a 3D model.
    var subject: String?
    /// The YouTube video a study guide or update agent works on (`studyGuideVideoKey`), so one video never has two
    /// guide agents at once. Nil for every other kind.
    let studyGuideVideoKey: String?
    let startedAt: Date
    /// When the step that runs now began, which times its share of the progress.
    var currentStepStartedAt: Date
    var endedAt: Date?
    var phase: BackgroundAgentPhase
    /// The steps a task agent said it was on, oldest first. Empty for every other kind, whose steps are fixed.
    var reportedSteps: [String] = []

    /// The steps the agent list shows: a task agent's reported steps, or the kind's fixed steps.
    var stepNames: [String] {
        guard kind == .task else { return kind.stepNames }
        return reportedSteps.isEmpty ? [kind.steps[0].inProgressText] : reportedSteps
    }

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

    /// A running step moves the progress through this much of its share, then waits, so the progress never shows a
    /// step done before it is.
    static let shareOfAStepTheProgressMovesThrough = 0.85

    /// How far the work is, from 0 to 1, which the wingman and the agent list both show. A running step moves in a
    /// straight line from its start toward 85% of its share over its expected seconds, and waits there if it runs long.
    func progress(at now: Date) -> Double {
        guard case .running(let completedStepCount) = phase, kind.steps.indices.contains(completedStepCount) else {
            return filledFraction
        }
        let secondsIntoTheStep = max(0, now.timeIntervalSince(currentStepStartedAt))
        let shareOfTheStepDone = min(1, secondsIntoTheStep / kind.steps[completedStepCount].expectedSeconds)
        return (Double(completedStepCount) + Self.shareOfAStepTheProgressMovesThrough * shareOfTheStepDone) / Double(kind.steps.count)
    }

    /// Where the progress heads while the current step runs, and how many seconds until it gets there.
    /// Nil once the agent has ended.
    func progressHeading(at now: Date) -> (fraction: Double, secondsToGetThere: TimeInterval)? {
        guard case .running(let completedStepCount) = phase, kind.steps.indices.contains(completedStepCount) else { return nil }
        let stepEndsAt = currentStepStartedAt.addingTimeInterval(kind.steps[completedStepCount].expectedSeconds)
        return (
            fraction: (Double(completedStepCount) + Self.shareOfAStepTheProgressMovesThrough) / Double(kind.steps.count),
            secondsToGetThere: max(0, stepEndsAt.timeIntervalSince(now))
        )
    }

    /// The line beside the wingman while it works, or nil once the agent has ended.
    var inProgressText: String? {
        guard case .running(let completedStepCount) = phase, kind.steps.indices.contains(completedStepCount) else { return nil }
        if kind == .task, let latestReportedStep = reportedSteps.last {
            return latestReportedStep
        }
        return kind.steps[completedStepCount].inProgressText
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
        let stepCount = stepNames.count
        switch phase {
        // A task agent is on its latest reported step and has done the ones before it.
        case .running where kind == .task:
            return (0..<stepCount).map { stepIndex in stepIndex == stepCount - 1 ? .current : .done }
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

    /// Running agents are always kept, so one is never dropped while its task can still be cancelled or finish.
    private static let mostEndedAgentsKept = 10

    @discardableResult
    func start(kind: BackgroundAgentKind, studyGuideVideoKey: String? = nil) -> UUID {
        let startedAt = Date()
        let agent = BackgroundAgent(id: UUID(), kind: kind, subject: nil, studyGuideVideoKey: studyGuideVideoKey, startedAt: startedAt, currentStepStartedAt: startedAt, endedAt: nil, phase: .running(completedStepCount: 0))
        agents.insert(agent, at: 0)
        var endedAgentsKept = 0
        agents = agents.filter { agent in
            if agent.isRunning { return true }
            endedAgentsKept += 1
            return endedAgentsKept <= Self.mostEndedAgentsKept
        }
        return agent.id
    }

    /// Two guide agents on one video would write two pages for one guide, or update a page that is about to be replaced.
    func aStudyGuideAgentIsRunning(forVideoKey videoKey: String) -> Bool {
        agents.contains { $0.isRunning && $0.studyGuideVideoKey == videoKey }
    }

    func setSubject(_ subject: String, for agentID: UUID) {
        updateRunningAgent(agentID) { agent in
            agent.subject = subject
        }
    }

    /// A task agent keeps its last few steps, which is all the list has room for.
    func reportStep(_ stepText: String, for agentID: UUID) {
        updateRunningAgent(agentID) { agent in
            agent.reportedSteps = Array((agent.reportedSteps + [stepText]).suffix(Self.mostReportedStepsKept))
        }
    }

    private static let mostReportedStepsKept = 6

    func completeStep(for agentID: UUID) {
        updateRunningAgent(agentID) { agent in
            guard case .running(let completedStepCount) = agent.phase,
                  completedStepCount < agent.kind.stepNames.count - 1 else { return }
            agent.phase = .running(completedStepCount: completedStepCount + 1)
            agent.currentStepStartedAt = Date()
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

// MARK: - 3D model

/// A 3D model page a background agent built, waiting to rise out of the video it was asked about.
struct ReadyThreeDModel {
    let agentID: UUID
    /// The learner's words, which the narration after the tour answers.
    let whatToBuild: String
    let pageHTML: String
    /// The front tab's URL when the build started. The model rises out of the video only while that tab is in front.
    let sourceTabURL: String?
}

enum ThreeDModelBuildError: Error {
    /// Screen Recording was turned off, so there is no frame to build from.
    case noScreenshot
}
