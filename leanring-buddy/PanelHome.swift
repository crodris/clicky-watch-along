//
//  PanelHome.swift
//  leanring-buddy
//
//  The pure rules of the menu bar panel's home: the state line under the header, the one banner slot for what needs the
//  learner, the agents row, which theme cards the home shows, and how the arrow keys move between theme cards. Nothing here
//  draws or reads a window, so each rule is tested on its own (`PanelHomeTests.swift`).
//

import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Pages

/// What the panel shows. Each open starts at `home`, or at `setup` while setup is not finished.
enum PanelPage: Equatable {
    case home
    case allThemes
    case setup
}

// MARK: - The state line

/// The line under "Clicky" in the header: what Clicky is doing now, or what is wrong.
enum PanelHeaderStatus: Equatable {
    /// "Ready · hold ⌃ ⌥ to talk".
    case ready
    /// "Ready · 1 request needs you".
    case readyWithRequestsWaiting(count: Int)
    case listening
    case thinking
    case speaking
    /// A video quiz question waits for the learner's spoken answer.
    case quizQuestion
    /// A video quiz runs between its questions: "Quiz · 3 of 4 right", with a Stop quiz button.
    case quizRunning(VideoQuizProgress)
    /// Setup is not finished.
    case settingUp
    /// A required permission was turned off after setup.
    case needsAttention
    case offline
}

/// The header's state line. A problem wins over what Clicky is doing, since the learner cannot fix it any other way.
func panelHeaderStatus(
    setupIsFinished: Bool,
    aRequiredPermissionIsOff: Bool,
    workerIsUnreachable: Bool,
    voiceState: CompanionVoiceState,
    aVideoQuizQuestionIsOpen: Bool,
    videoQuizProgress: VideoQuizProgress?,
    approvalRequestsWaiting: Int
) -> PanelHeaderStatus {
    guard setupIsFinished else { return .settingUp }
    if aRequiredPermissionIsOff { return .needsAttention }
    if workerIsUnreachable { return .offline }
    switch voiceState {
    case .listening: return .listening
    case .processing: return .thinking
    case .responding: return .speaking
    case .idle: break
    }
    if aVideoQuizQuestionIsOpen { return .quizQuestion }
    if let videoQuizProgress { return .quizRunning(videoQuizProgress) }
    if approvalRequestsWaiting > 0 { return .readyWithRequestsWaiting(count: approvalRequestsWaiting) }
    return .ready
}

extension PanelHeaderStatus {
    /// The words of the line. `ready` draws its keys as key caps after "Ready · hold", so its text here is what VoiceOver reads.
    var spokenText: String {
        switch self {
        case .ready: return "Ready. Hold control and option to talk."
        case .readyWithRequestsWaiting(let count): return count == 1 ? "Ready · 1 request needs you" : "Ready · \(count) requests need you"
        case .listening: return "Listening"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking · esc stops it"
        case .quizQuestion: return "Quiz question · answer out loud"
        case .quizRunning(let progress): return progress.stateLineText
        case .settingUp: return "Finish setup to start"
        case .needsAttention: return "Needs attention"
        case .offline: return "Offline"
        }
    }

    /// Whether the line holds a button, the running quiz's Stop quiz.
    var hasAButton: Bool {
        if case .quizRunning = self { return true }
        return false
    }

    /// Whether the line reads as a problem, in the warning color.
    var isAProblem: Bool {
        switch self {
        case .needsAttention, .offline: return true
        default: return false
        }
    }
}

// MARK: - The banner slot

/// The one thing that needs the learner, shown under the header. Only one shows at a time.
enum PanelBanner: Equatable {
    /// The approval card (`ApprovalCardView`), on its own `menuPanel` surface, so the keyboard can read and answer it here.
    /// It also shows for a moment after its request ends, to say how it ended.
    case approvalCard
    /// A permission that setup needs was turned off after setup finished.
    case permissionOff(SetupStep)
    case workerUnreachable
}

/// The banner for this moment. The approval card comes first, since its request times out in 120 seconds, then a
/// permission that was turned off, then the Worker being unreachable, which a permission off would hide anyway.
///
/// - `anApprovalCardShows`: the desk has a card for the panel's surface (`HarnessApprovalDesk.cardToShow`).
/// - `firstRequiredStepThatIsOff`: the first required setup step that is not done, read only after setup finished.
func panelBanner(
    anApprovalCardShows: Bool,
    setupIsFinished: Bool,
    firstRequiredStepThatIsOff: SetupStep?,
    workerIsUnreachable: Bool
) -> PanelBanner? {
    if anApprovalCardShows { return .approvalCard }
    if setupIsFinished, let firstRequiredStepThatIsOff { return .permissionOff(firstRequiredStepThatIsOff) }
    if workerIsUnreachable { return .workerUnreachable }
    return nil
}

/// The words and button of a problem banner. The approval card draws itself, so it has none.
struct PanelProblemBannerWords: Equatable {
    let title: String
    let caption: String
    let buttonTitle: String
}

func panelProblemBannerWords(for banner: PanelBanner) -> PanelProblemBannerWords? {
    switch banner {
    case .approvalCard:
        return nil
    case .permissionOff(let step):
        return PanelProblemBannerWords(title: "\(step.title) is off", caption: step.whatStopsWorkingWhenItIsOff, buttonTitle: "Fix")
    case .workerUnreachable:
        return PanelProblemBannerWords(
            title: "Can't reach Clicky's server",
            caption: "Answers and agents wait until it is back. Checking every 10 seconds.",
            buttonTitle: "Retry"
        )
    }
}

// MARK: - The agents row

/// The agents row's words: "2 working · 1 result waiting". Nil when nothing runs and no result waits, so the row hides.
struct PanelAgentsSummary: Equatable {
    let workingCount: Int
    let resultsWaitingCount: Int

    var mainText: String { workingCount == 0 ? "No agents working" : "\(workingCount) working" }
    var secondaryText: String? {
        switch resultsWaitingCount {
        case 0: return nil
        case 1: return "1 result waiting"
        default: return "\(resultsWaitingCount) results waiting"
        }
    }
}

/// The row shows while any agent runs or any finished result still waits, even with nothing running.
func panelAgentsSummary(agents: [BackgroundAgent], at now: Date) -> PanelAgentsSummary? {
    let workingCount = agents.filter(\.isRunning).count
    let resultsWaitingCount = agents.filter { $0.tokenRank(at: now) == .waitingResult }.count
    guard workingCount + resultsWaitingCount > 0 else { return nil }
    return PanelAgentsSummary(workingCount: workingCount, resultsWaitingCount: resultsWaitingCount)
}

// MARK: - Theme cards

/// How many theme cards the home shows before its "Design one" card, so the two rows of three stay full.
let panelHomeThemeCardCount = 5

/// The themes the home's cards show, in a fixed order, so a click never moves the card under the pointer: the three newest
/// saved themes, then the bundled themes in their order, cut to `panelHomeThemeCardCount`. The selected theme always shows,
/// taking the last card when it would not.
func panelHomeThemes(selectedTheme: ClickyTheme, bundledThemes: [ClickyTheme], savedThemesNewestFirst: [ClickyTheme]) -> [ClickyTheme] {
    var homeThemes = Array((Array(savedThemesNewestFirst.prefix(3)) + bundledThemes).prefix(panelHomeThemeCardCount))
    if !homeThemes.contains(selectedTheme) {
        if homeThemes.count == panelHomeThemeCardCount { homeThemes.removeLast() }
        homeThemes.append(selectedTheme)
    }
    return homeThemes
}

/// Every theme the all-themes grid shows: the bundled ones in their order, then the saved ones by name, as the same cards.
func panelAllThemes(bundledThemes: [ClickyTheme], savedThemesByName: [ClickyTheme]) -> [ClickyTheme] {
    bundledThemes + savedThemesByName
}

/// An arrow key in a grid of theme cards.
enum ThemeGridArrowKey {
    case left, right, up, down
}

/// The card an arrow key moves the keyboard focus to, in a grid filled row by row. Left and right stop at the ends of the
/// whole list, up and down move a row and stay put at the top and bottom rows, and down from a row above a short last row
/// lands on its last card.
func themeGridCardIndex(afterPressing arrowKey: ThemeGridArrowKey, from cardIndex: Int, columnCount: Int, cardCount: Int) -> Int {
    guard cardCount > 0 else { return 0 }
    switch arrowKey {
    case .left: return max(0, cardIndex - 1)
    case .right: return min(cardCount - 1, cardIndex + 1)
    case .up: return cardIndex - columnCount >= 0 ? cardIndex - columnCount : cardIndex
    case .down:
        let lastRowStartIndex = ((cardCount - 1) / columnCount) * columnCount
        guard cardIndex < lastRowStartIndex else { return cardIndex }
        return min(cardCount - 1, cardIndex + columnCount)
    }
}

// MARK: - VoiceOver

/// What VoiceOver reads for an agent's disc or its chip in the panel: the peek card's title and caption, and its hint when
/// it has one, such as what to say. Nil content, for an agent that just left, reads only the agent's name.
func agentDiscAccessibilityLabel(agentName: String, peekContent: AgentTokenPeekContent?) -> String {
    guard let peekContent else { return agentName }
    return [peekContent.title, peekContent.caption, peekContent.hint].compactMap { $0 }.joined(separator: ". ")
}

// MARK: - Keyboard focus on a disc

/// The disc that takes the panel's keyboard focus for an agent: the agent's disc on the display with the mouse, else its
/// disc on any display, else none, as for an agent counted in "+N".
func agentDiscIDTakingTheKeyboardFocus(among discIDs: [AgentTokenDiscID], agentID: UUID, mouseDisplayID: CGDirectDisplayID?) -> AgentTokenDiscID? {
    let discIDsOfTheAgent = discIDs.filter { $0.tokenSlot == .agent(agentID) }
    return discIDsOfTheAgent.first { $0.displayID == mouseDisplayID } ?? discIDsOfTheAgent.first
}

// MARK: - Escape and height

/// How long after the panel closed on Escape the app's own Escape handler still counts that Escape as the panel's. The
/// panel and the app's event tap both see the key, in either order.
let secondsAnEscapeStaysThePanels: TimeInterval = 0.5

/// Whether an Escape belongs to the menu bar panel: it holds the keyboard, or it just closed on that Escape. The app's
/// Escape handler then skips no quiz question and clears no scene.
func menuPanelTookTheEscape(panelIsKey: Bool, panelClosedOnEscapeAt: Date?, now: Date) -> Bool {
    if panelIsKey { return true }
    guard let panelClosedOnEscapeAt else { return false }
    return now.timeIntervalSince(panelClosedOnEscapeAt) < secondsAnEscapeStaysThePanels
}

/// The header's height, which stays above the scrolling page.
let panelHeaderHeight: CGFloat = 76

/// The tallest a page under the header may be on a screen whose visible part is this tall: the screen less the gap under
/// the menu bar, the shadow margin, and the header. A page past it scrolls.
func panelTallestPageHeight(visibleScreenHeight: CGFloat, shadowMargin: EdgeInsets) -> CGFloat {
    let gapUnderTheMenuBar: CGFloat = 4
    return max(200, visibleScreenHeight - gapUnderTheMenuBar - shadowMargin.top - shadowMargin.bottom - panelHeaderHeight)
}
