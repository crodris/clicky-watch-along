//
//  BackgroundAgents.swift
//  leanring-buddy
//
//  The record of work Clicky does in the background while the learner watches a video, such as writing
//  a Notion study guide or building a 3D model. The store is the one source of truth that the agent tokens beside the notch
//  and the agent list both read. Nothing here draws or talks to the network.
//

import Combine
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Agent

/// One step of an agent's work, with about how long it takes, which sets how fast the progress ring fills while it runs.
struct BackgroundAgentStep: Equatable {
    /// The step as a checklist item in the agent list, such as "Read the captions".
    let name: String
    let expectedSeconds: TimeInterval
}

/// What a background agent does. A new kind adds a case here and fills in its name, color, and steps.
enum BackgroundAgentKind {
    case studyGuide
    /// Rebuilds a guide's page with the newest quiz results after a missed question, keeping the guide's words.
    case studyGuideUpdate
    /// Builds a 3D model of what the video shows while it keeps playing, and lifts it out of the video when it is ready.
    case threeDModel
    /// Builds a science experiment from what the video or screen shows while the video keeps playing, and lifts it out
    /// of the video when it is ready, like a 3D model. The learner then guesses, tries it, and takes a challenge.
    case experiment
    /// Works on any task the learner hands it, with web search, the video's captions, and a Notion page, and reports its
    /// own steps, since nobody knows them in advance.
    case task

    var displayName: String {
        switch self {
        case .studyGuide: return "Study guide"
        case .studyGuideUpdate: return "Study guide update"
        case .threeDModel: return "3D model"
        case .experiment: return "Experiment"
        case .task: return "Task"
        }
    }

    /// The color a new agent of this kind takes when no other running or waiting agent has it. Both guide kinds work on
    /// the same guide, so they share its amber.
    var preferredPaletteColor: AgentPaletteColor {
        switch self {
        case .studyGuide, .studyGuideUpdate: return .amber
        case .threeDModel: return .violet
        case .experiment: return .lime
        case .task: return .teal
        }
    }

    /// What the chip above the cursor says when the agent finishes.
    var finishedChipText: String {
        switch self {
        case .studyGuide: return "Study guide ready"
        case .studyGuideUpdate: return "Study guide updated"
        case .threeDModel: return "3D model ready"
        case .experiment: return "Experiment ready"
        case .task: return "Task done"
        }
    }

    /// What a scene agent calls its page in a failure line and in the log. The other kinds build no scene and never read it.
    var builtThingName: String {
        self == .experiment ? "experiment" : "3D model"
    }

    /// What the learner says to show a scene agent's finished page when the screen was busy. The other kinds never read it.
    var waitingPhrase: String {
        self == .experiment ? "show the experiment" : "show the model"
    }

    /// The steps in order. The agent finishes by finishing its last step, so completeStep never moves past the last one.
    /// Reading the captions with yt-dlp took about 3 seconds, and writing the guide 10 to 14, in the demo recordings.
    /// An update reads the captions the quiz already holds, and rebuilds the page with no model call.
    /// A 3D model's screenshot takes under a second, and `POST /live-scene` about 20 seconds, an experiment's about 30.
    var steps: [BackgroundAgentStep] {
        switch self {
        case .studyGuide:
            return [
                BackgroundAgentStep(name: "Read the captions", expectedSeconds: 3),
                BackgroundAgentStep(name: "Write the guide in Notion", expectedSeconds: 12),
            ]
        case .studyGuideUpdate:
            return [
                BackgroundAgentStep(name: "Read the quiz results", expectedSeconds: 1),
                BackgroundAgentStep(name: "Add the miss to the guide", expectedSeconds: 3),
            ]
        case .threeDModel:
            return [
                BackgroundAgentStep(name: "Grab the frame", expectedSeconds: 1),
                BackgroundAgentStep(name: "Build the 3D model", expectedSeconds: 20),
            ]
        case .experiment:
            return [
                BackgroundAgentStep(name: "Grab the frame", expectedSeconds: 1),
                // GPT-6.2 Sol builds an experiment in about 30 to 40 seconds at Ultrafast (bench, 2026-11-19).
                BackgroundAgentStep(name: "Build the experiment", expectedSeconds: 40),
            ]
        // A task's steps come from the agent as it works (BackgroundAgent.reportedSteps), so its progress runs as one
        // step. A web search answer took about 11 seconds in a test, and one with a Notion page takes longer.
        case .task:
            return [BackgroundAgentStep(name: "Getting started", expectedSeconds: 45)]
        }
    }

    #if DEBUG
    /// The kind a name from `debug_seed_agents` stands for, such as "task" or "threeDModel".
    static func kindNamedForSeeding(_ kindName: String) -> BackgroundAgentKind? {
        switch kindName {
        case "studyGuide": return .studyGuide
        case "studyGuideUpdate": return .studyGuideUpdate
        case "threeDModel": return .threeDModel
        case "experiment": return .experiment
        case "task": return .task
        default: return nil
        }
    }
    #endif

    /// The page `POST /live-scene` builds for a scene agent, and nil for an agent that builds no scene.
    var liveSceneKindToBuild: LiveSceneKind? {
        switch self {
        case .threeDModel: return .explore
        case .experiment: return .simulation
        case .studyGuide, .studyGuideUpdate, .task: return nil
        }
    }

    var stepNames: [String] {
        steps.map(\.name)
    }
}

/// What a finished agent made. The ending Clicky plays for a finished agent is chosen by switching on this.
enum BackgroundAgentResult: Equatable {
    case notionPage(URL)
    /// A 3D model or an experiment. The page itself waits in CompanionManager until it rises out of the video.
    case readyScene
    /// What a task agent found, read aloud when the learner asks, and the Notion page it wrote, if it wrote one.
    case answer(spokenSummary: String, pageURL: URL?)

    var pageURL: URL? {
        switch self {
        case .notionPage(let pageURL): return pageURL
        case .readyScene: return nil
        case .answer(_, let pageURL): return pageURL
        }
    }
}

enum BackgroundAgentPhase: Equatable {
    case running(completedStepCount: Int)
    case finished(BackgroundAgentResult)
    case failed(reason: String)
    case cancelled

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
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
    /// The site the agent is reading with one of the app's tools, such as the video's site for its captions or the link it
    /// opened, which the agent list shows after the agent's own step text. Cleared by the agent's next step, since the next
    /// step may read somewhere else. A web search or fetch runs on Anthropic's side and never tells the app its site.
    var readingHost: String? = nil
    /// True while the app can start this agent's work again, so a failed agent's row offers "Try again" once.
    var canBeTriedAgain = false
    /// True while a finished agent's result still waits for the learner, such as a 3D model not yet shown or a task answer
    /// not yet heard. Its token stays beside the notch until the result is delivered or `secondsAWaitingResultKeepsItsToken`
    /// pass. A result delivered at once, such as a study guide page, never waits.
    var resultIsWaitingToBeDelivered = false
    /// The color this agent has, picked from its theme when it started (`newAgentLook`) and kept for its whole life, so
    /// changing the theme only affects later agents and two agents of one kind never look alike under Clicky blue.
    var tokenColor: AgentPaletteColor? = nil
    /// What fills the agent's token, chip, and list row besides its color, picked with its color and kept as long.
    var face: AgentFace = .triangle

    /// The color the agent shows: its token ring and triangle, its ending chip, and its row in the agent list.
    var displayColor: AgentPaletteColor { tokenColor ?? kind.preferredPaletteColor }

    /// The player this agent is, under a theme with a roster.
    var rosterFace: AgentRosterFace? {
        if case .rosterFace(let rosterFace) = face { return rosterFace }
        return nil
    }

    /// What the chip and the list call the agent: its player's name, or its kind's name.
    var displayName: String { rosterFace?.player.name ?? kind.displayName }

    /// The steps the agent list shows: a task agent's reported steps, or the kind's fixed steps.
    var stepNames: [String] {
        guard kind == .task, !reportedSteps.isEmpty else { return kind.stepNames }
        return reportedSteps
    }

    /// How much of the agent's triangle is filled, from its tail to its tip.
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

    /// How far the work is, from 0 to 1, which the token's ring and the agent list both show. A running step moves in a
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

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var finishedResult: BackgroundAgentResult? {
        if case .finished(let result) = phase { return result }
        return nil
    }

    /// How long an ended agent's token stays beside the notch, and its chip stays at the cursor, so the learner sees how it went.
    static let secondsAnEndedAgentsTokenStays: TimeInterval = 4

    /// How long a finished agent's token waits for its result to be delivered before it leaves. The result stays in the list.
    static let secondsAWaitingResultKeepsItsToken: TimeInterval = 600

    /// Where this agent's token ranks when slots are scarce, or nil when it has no token at `now`.
    /// A running agent has one. A finished agent whose result waits keeps one for ten minutes. Any other finished or failed
    /// agent keeps one for the few seconds its chip shows. A cancelled agent has none, since the learner asked for that.
    func tokenRank(at now: Date) -> AgentTokenRank? {
        switch phase {
        case .running:
            return .running
        case .finished, .failed:
            guard let endedAt else { return nil }
            let secondsSinceItEnded = now.timeIntervalSince(endedAt)
            if resultIsWaitingToBeDelivered, secondsSinceItEnded < Self.secondsAWaitingResultKeepsItsToken {
                return .waitingResult
            }
            return secondsSinceItEnded < Self.secondsAnEndedAgentsTokenStays ? .ending : nil
        case .cancelled:
            return nil
        }
    }

    /// Seconds from start to the end, or to `now` while it runs.
    func elapsedSeconds(at now: Date) -> TimeInterval {
        max(0, (endedAt ?? now).timeIntervalSince(startedAt))
    }
}

/// What an agent shows as its face: a roster player's portrait, a saved theme's picture, or the agent's triangle.
enum AgentFace: Equatable {
    case triangle
    case rosterFace(AgentRosterFace)
    case themePicture(themeID: String)
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

    /// Whether a video quiz question is open, which `CompanionManager` sets. The agent list reads it to hold its Show
    /// and Hear buttons (`agentListMayDeliverAWaitingResult`), and it is published so an open list redraws when a
    /// question opens or closes.
    @Published var aVideoQuizQuestionIsOpen = false

    /// The agents with a request in the approval desk, which `CompanionManager` keeps in step with the desk. Their tokens
    /// show the "!" badge and a notch in the ring.
    @Published var agentIDsWaitingForApproval: Set<UUID> = []

    /// The capability of each waiting agent's oldest request, which the disc's peek card names. It never holds the request's
    /// summary, since a page or a server may have written that.
    @Published var approvalCapabilitiesByAgentID: [UUID: HarnessCapability] = [:]

    /// Read when an agent starts, to pick its color and face. Changing the theme later never changes a running agent.
    private let themeSettings: CompanionThemeSettings

    init(themeSettings: CompanionThemeSettings) {
        self.themeSettings = themeSettings
    }

    /// Running agents are always kept, so one is never dropped while its task can still be cancelled or finish.
    private static let mostEndedAgentsKept = 10

    @discardableResult
    func start(kind: BackgroundAgentKind, studyGuideVideoKey: String? = nil) -> UUID {
        var systemRandomNumberGenerator = SystemRandomNumberGenerator()
        return startAgent(kind: kind, studyGuideVideoKey: studyGuideVideoKey, look: nextLook(for: kind, randomNumberGenerator: &systemRandomNumberGenerator))
    }

    /// The theme a new agent takes its look from: the saved theme, never the studio's preview, so an agent started while
    /// the learner only tries an idea does not keep that idea's look after the card closes. With Shuffle on, a theme picked
    /// at random from every installed theme.
    private func themeForANewAgent(randomNumberGenerator: inout some RandomNumberGenerator) -> ClickyTheme {
        guard themeSettings.shufflesAgentThemes else { return themeSettings.theme }
        return themeSettings.themesAgentsMayShuffleThrough.randomElement(using: &randomNumberGenerator) ?? themeSettings.theme
    }

    /// The look the next agent of `kind` takes. `extraRunningAgentLooks` counts agents about to start in the same seed.
    private func nextLook(
        for kind: BackgroundAgentKind,
        extraRunningAgentLooks: [NewAgentLook] = [],
        randomNumberGenerator: inout some RandomNumberGenerator
    ) -> NewAgentLook {
        let now = Date()
        // Only running agents and agents with a waiting result hold a color. An agent in its 4 second ending has given its color up.
        let colorsInUse = agents.compactMap { existingAgent -> AgentPaletteColor? in
            guard let tokenRank = existingAgent.tokenRank(at: now), tokenRank != .ending else { return nil }
            return existingAgent.tokenColor
        } + extraRunningAgentLooks.map(\.tokenColor)
        let extraRosterFaces = extraRunningAgentLooks.compactMap { look -> AgentRosterFace? in
            if case .rosterFace(let rosterFace) = look.face { return rosterFace }
            return nil
        }
        return newAgentLook(
            kind: kind,
            theme: themeForANewAgent(randomNumberGenerator: &randomNumberGenerator),
            colorsInUse: colorsInUse,
            rosterFacesOfRunningAgents: agents.filter(\.isRunning).compactMap(\.rosterFace) + extraRosterFaces,
            rosterFacesOfEndedAgentsStillListed: agents.filter { !$0.isRunning }.compactMap(\.rosterFace)
        )
    }

    #if DEBUG
    /// For screenshots and demo takes (`debug_seed_agents`): up to three running agents, one finished with a result that
    /// waits to be heard, and one failed, with volleyball subjects. `runningAgentCount` below 3 leaves room beside the
    /// notch for the finished and failed tokens too. The agent list puts the newest agent first, so the team's
    /// best-known player, who the theme hands out first, starts last and leads. Returns the finished agent's id, for
    /// its ending chip.
    @discardableResult
    func seedAgentsForScreenshots(runningAgentCount: Int = 3) -> UUID {
        var systemRandomNumberGenerator = SystemRandomNumberGenerator()
        // Agents already in the store count too, so a second seed follows the same rule as any new agent (`newAgentLook`)
        // instead of handing out the first five players again. Each look counts the ones picked before it.
        let seedKinds: [BackgroundAgentKind] = [.task, .threeDModel, .studyGuide, .task, .experiment]
        var seedLooks: [NewAgentLook] = []
        for seedKind in seedKinds {
            seedLooks.append(nextLook(for: seedKind, extraRunningAgentLooks: seedLooks, randomNumberGenerator: &systemRandomNumberGenerator))
        }
        if runningAgentCount >= 3 {
            let studyGuideAgentID = startAgent(kind: .studyGuide, studyGuideVideoKey: nil, look: seedLooks[2])
            setSubject("HAIKYU!! The Dumpster Battle trailer", for: studyGuideAgentID)
            completeStep(for: studyGuideAgentID)
        }
        let failedAgentID = startAgent(kind: .experiment, studyGuideVideoKey: nil, look: seedLooks[4])
        setSubject("The spin on a jump serve", for: failedAgentID)
        fail(failedAgentID, reason: "The experiment could not be built. Ask again to try once more.")
        let finishedAgentID = startAgent(kind: .task, studyGuideVideoKey: nil, look: seedLooks[3])
        setSubject("Who won the Spring High final", for: finishedAgentID)
        finish(finishedAgentID, with: .answer(spokenSummary: "Karasuno won 2 sets to 1.", pageURL: nil))
        if runningAgentCount >= 2 {
            let threeDModelAgentID = startAgent(kind: .threeDModel, studyGuideVideoKey: nil, look: seedLooks[1])
            setSubject("The volleyball court with the net", for: threeDModelAgentID)
        }
        if runningAgentCount >= 1 {
            let taskAgentID = startAgent(kind: .task, studyGuideVideoKey: nil, look: seedLooks[0])
            setSubject("Karasuno vs Nekoma at nationals", for: taskAgentID)
            reportStep("Reading the Haikyuu wiki", for: taskAgentID)
        }
        return finishedAgentID
    }
    #endif

    #if DEBUG
    /// For a take that needs several running agents of one kind, such as three task agents with three colors
    /// (`debug_seed_agents` with `kinds`): one running agent for each kind named, in order.
    /// Returns the new agents' ids in order, so a take can serve their tokens from the cursor.
    @discardableResult
    func seedRunningAgentsForScreenshots(kinds: [BackgroundAgentKind]) -> [UUID] {
        kinds.map { kind in
            let agentID = start(kind: kind)
            setSubject("A seeded \(kind.displayName.lowercased()) agent", for: agentID)
            return agentID
        }
    }
    #endif

    private func startAgent(kind: BackgroundAgentKind, studyGuideVideoKey: String?, look: NewAgentLook) -> UUID {
        let startedAt = Date()
        let agent = BackgroundAgent(
            id: UUID(),
            kind: kind,
            subject: nil,
            studyGuideVideoKey: studyGuideVideoKey,
            startedAt: startedAt,
            currentStepStartedAt: startedAt,
            endedAt: nil,
            phase: .running(completedStepCount: 0),
            tokenColor: look.tokenColor,
            face: look.face
        )
        agents.insert(agent, at: 0)
        var endedAgentsKept = 0
        agents = agents.filter { existingAgent in
            if existingAgent.isRunning { return true }
            endedAgentsKept += 1
            return endedAgentsKept <= Self.mostEndedAgentsKept
        }
        return agent.id
    }

    /// The face of an agent, for the ending chip.
    func face(for agentID: UUID) -> AgentFace {
        agents.first { $0.id == agentID }?.face ?? .triangle
    }

    /// The color of an agent, for the ending chip.
    func displayColor(for agentID: UUID) -> AgentPaletteColor? {
        agents.first { $0.id == agentID }?.displayColor
    }

    func anAgentIsRunning(ofKind agentKind: BackgroundAgentKind) -> Bool {
        agents.contains { $0.isRunning && $0.kind == agentKind }
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
            agent.readingHost = nil
        }
    }

    /// The site a running agent reads now (`BackgroundAgent.readingHost`). Nil for a link with no host.
    func setReadingHost(_ readingHost: String?, for agentID: UUID) {
        updateRunningAgent(agentID) { agent in
            agent.readingHost = readingHost
        }
    }

    /// Records that the app can start this agent's work again if it fails. Set when the agent starts.
    func allowTryingAgain(_ agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[agentIndex].canBeTriedAgain = true
    }

    /// A failed agent that was tried again offers no second "Try again", since the new agent has its own row.
    func markTriedAgain(_ agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }) else { return }
        agents[agentIndex].canBeTriedAgain = false
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

    /// A 3D model or experiment waits to be shown, and a task answer waits to be heard. A guide's page opens at once.
    func finish(_ agentID: UUID, with result: BackgroundAgentResult) {
        endRunningAgent(agentID, in: .finished(result))
        switch result {
        case .readyScene, .answer: setResultIsWaiting(true, for: agentID)
        case .notionPage: break
        }
    }

    /// Set to false when the result reaches the learner, or a newer result replaces it, and to true again when a scene
    /// that was about to rise has to wait for "show the model" after all. The token follows.
    func setResultIsWaiting(_ resultIsWaiting: Bool, for agentID: UUID) {
        guard let agentIndex = agents.firstIndex(where: { $0.id == agentID }), agents[agentIndex].finishedResult != nil else { return }
        agents[agentIndex].resultIsWaitingToBeDelivered = resultIsWaiting
        guard resultIsWaiting else { return }
        // The token leaves on its own when the ten minutes pass, so the views that show it need one more refresh then.
        Task {
            try? await Task.sleep(for: .seconds(BackgroundAgent.secondsAWaitingResultKeepsItsToken + 0.05))
            objectWillChange.send()
        }
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
        // The token of a finished or failed agent leaves on its own, so the views that show it need one more refresh then.
        Task {
            try? await Task.sleep(for: .seconds(BackgroundAgent.secondsAnEndedAgentsTokenStays + 0.05))
            objectWillChange.send()
        }
    }
}

// MARK: - Ready scene

/// A 3D model or experiment page a background agent built, waiting to rise out of the video it was asked about.
struct ReadyBackgroundScene {
    let agentID: UUID
    let agentKind: BackgroundAgentKind
    /// The learner's words, which a 3D model's narration after the tour answers.
    let whatToBuild: String
    let pageHTML: String
    /// The front tab's URL when the build started. A 3D model rises out of the video only while that tab is in front.
    let sourceTabURL: String?
    /// The guess, trials, and challenge of an experiment, set when its page plays. Nil for a 3D model.
    let simulationLesson: SimulationLesson?
}

/// Whether a ready scene may rise onto the screen now, given the tab it was built from and the tab in front.
/// An experiment built with no video tab in front may rise anywhere, since "let me try it" also works on a screen that
/// is not a video. A 3D model needs the video it was built from.
func aReadyBackgroundSceneMayRiseOverTheFrontTab(
    agentKind: BackgroundAgentKind,
    sourceTabURL: String?,
    frontTabURL: String?
) -> Bool {
    guard let sourceTabURL else { return agentKind == .experiment }
    return frontTabURL == sourceTabURL
}

/// A scene rises at once only onto a free screen: Clicky is not listening, thinking, or talking, no scene or pop-out
/// is building or showing, no video quiz question is open, the room art panel is closed, and the tab rule above allows
/// it. Otherwise it would cover something the learner is looking at, so it waits for "show the model" or "show the
/// experiment". The front tab is read last, since reading it is an Apple Event a busy screen does not need.
func backgroundSceneMayRiseNow(
    _ readyBackgroundScene: ReadyBackgroundScene,
    clickyIsIdleAndDoneSpeaking: Bool,
    aSceneOrPopOutIsBuildingOrShowing: Bool,
    aVideoQuizQuestionIsOpen: Bool,
    theRoomArtPanelIsOpen: Bool,
    readFrontTabURL: () -> String?
) -> Bool {
    guard clickyIsIdleAndDoneSpeaking, !aSceneOrPopOutIsBuildingOrShowing, !aVideoQuizQuestionIsOpen, !theRoomArtPanelIsOpen else { return false }
    return aReadyBackgroundSceneMayRiseOverTheFrontTab(
        agentKind: readyBackgroundScene.agentKind,
        sourceTabURL: readyBackgroundScene.sourceTabURL,
        frontTabURL: readFrontTabURL()
    )
}

/// What a request for an experiment does. One experiment builds at a time, since each build is a paid `POST /live-scene`
/// call and a newer one would replace the older, and a learner who repeats "let me try it" over a ready one wants to see it.
enum ExperimentRequestStep: Equatable {
    case showTheReadyExperiment
    case sayItIsStillBuilding
    case startBuilding
}

func experimentRequestStep(anExperimentIsReady: Bool, anExperimentIsBuilding: Bool) -> ExperimentRequestStep {
    if anExperimentIsReady { return .showTheReadyExperiment }
    if anExperimentIsBuilding { return .sayItIsStillBuilding }
    return .startBuilding
}

enum BackgroundSceneBuildError: Error {
    /// Screen Recording was turned off, so there is no frame to build from.
    case noScreenshot
}
