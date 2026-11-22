//
//  AgentTokenMenu.swift
//  leanring-buddy
//
//  The right-click menu of an agent's disc in the menu bar: the same actions the agent list's row offers, one click from the
//  disc. This file is the pure rule for which items a disc offers, and the closures the dock needs to run them. The dock
//  builds the NSMenu from it.
//

import Foundation

/// One item of a disc's right-click menu.
enum AgentDiscMenuItem: Equatable {
    /// Opens the agent list with the approval card, which is where the learner answers. Offered while an approval waits.
    case reviewRequest
    /// Shows the 3D model or experiment that waits, titled for what it is.
    case showReadyScene(title: String)
    case hearAnswer
    case openPage
    case cancelAgent
    /// What the "+N" disc, and an agent with nothing else to offer, opens.
    case openAgentList

    var title: String {
        switch self {
        case .reviewRequest: return "Review request"
        case .showReadyScene(let title): return title
        case .hearAnswer: return "Hear answer"
        case .openPage: return "Open page"
        case .cancelAgent: return "Cancel agent"
        case .openAgentList: return "Open agent list"
        }
    }
}

/// What a disc's right-click menu offers, in order. Cancel comes last, after a separator the dock adds.
///
/// - `agent`: the agent the disc stands for, or nil for the "+N" disc.
/// - `aVideoQuizQuestionIsOpen`: a waiting result is held while a quiz question is open, as the list's own buttons are
///   (`agentListMayDeliverAWaitingResult`).
func agentDiscMenuItems(for agent: BackgroundAgent?, isWaitingForApproval: Bool, aVideoQuizQuestionIsOpen: Bool) -> [AgentDiscMenuItem] {
    guard let agent else { return [.openAgentList] }
    var menuItems: [AgentDiscMenuItem] = []
    if isWaitingForApproval { menuItems.append(.reviewRequest) }
    if let finishedResult = agent.finishedResult {
        let resultMayBeDelivered = agentListMayDeliverAWaitingResult(aVideoQuizQuestionIsOpen: aVideoQuizQuestionIsOpen)
        switch finishedResult {
        case .readyScene where agent.resultIsWaitingToBeDelivered && resultMayBeDelivered:
            menuItems.append(.showReadyScene(title: agent.kind == .experiment ? "Show experiment" : "Show model"))
        case .answer where agent.resultIsWaitingToBeDelivered && resultMayBeDelivered:
            menuItems.append(.hearAnswer)
        default:
            break
        }
        if finishedResult.pageURL != nil { menuItems.append(.openPage) }
    }
    if agent.isRunning { menuItems.append(.cancelAgent) }
    return menuItems.isEmpty ? [.openAgentList] : menuItems
}

/// What a disc's menu items run, which `CompanionManager` fills in with the same closures the agent list uses.
struct AgentDiscMenuActions {
    let cancelAgent: (UUID) -> Void
    let showReadyScene: () -> Void
    let hearTaskAnswer: () -> Void
}
