//
//  VoiceApprovals.swift
//  leanring-buddy
//
//  The pure rules around a task agent's approval request: the words of the chip that says how it was answered, which
//  agent row shows the request, and the chip while it waits. The queue itself is `HarnessApprovalDesk` in
//  AgentHarness.swift. Nothing here draws or talks to the network.
//
//  The harness settles a voice `answer_approval` itself (harness/brainloop.go, harness/voiceapproval.go) and never sends
//  it to the app, so the app reads only the settlement (`approval_settled`).
//
//  An approval summary is built by the harness from the call's own input, so it can hold text that a web page or an MCP
//  server wrote. The summary is shown to the learner in full, and it never reaches the voice command router, which could
//  be talked into approving by it.
//

import Foundation

// MARK: - The voice answer

/// How a request was answered, by a click or by voice, as the harness's gate settled it. "Always" only means something
/// with a yes, since a no is never remembered (harness/approval.go).
nonisolated struct ApprovalVoiceAnswer: Equatable, Sendable {
    let approved: Bool
    let scope: HarnessApprovalScope

    init(approved: Bool, scope: HarnessApprovalScope) {
        self.approved = approved
        self.scope = scope
    }

    /// What the chip above the cursor says once the answer went through.
    var chipPhrase: String {
        guard approved else { return "Declined it" }
        return scope == .always ? "Allowed it for this task" : "Allowed it"
    }
}

// MARK: - The agent list

/// What an agent's row in the agent list shows about approvals.
nonisolated enum AgentListApprovalState: Equatable, Sendable {
    case none
    /// The agent list's approval card shows this request with its Don't allow, Allow once, and For this task buttons.
    case needsAnswer(HarnessApprovalRequest)
    /// The agent has a request, but an older one from another agent comes first, so the row says it waits.
    case waitsItsTurn(HarnessCapability)
}

/// Only the oldest waiting request is shown for an answer, so a "yes" and a click always mean the same request. An
/// agent whose request is not the oldest shows that it waits its turn.
nonisolated func agentListApprovalState(forAgentID agentID: UUID, waitingRequests: [HarnessApprovalRequest]) -> AgentListApprovalState {
    if let oldestRequest = waitingRequests.first, oldestRequest.taskID == agentID {
        return .needsAnswer(oldestRequest)
    }
    if let requestOfThisAgent = waitingRequests.first(where: { $0.taskID == agentID }) {
        return .waitsItsTurn(requestOfThisAgent.capability)
    }
    return .none
}

/// What the wingman's line and the row's status say while the agent waits for an answer.
nonisolated let approvalWaitingStatusText = "Needs your OK"

// MARK: - The chip

/// The chip above the cursor while a request waits: "Hinata needs your OK" with the way to answer after it, in the
/// agent's color. `agentName` is the agent's player under a team theme, and the kind's name otherwise.
nonisolated func approvalWaitingChipTexts(agentName: String) -> (primary: String, secondary: String) {
    ("\(agentName) needs your OK", "· say yes or no")
}

extension AgentListApprovalState {
    /// The line under the row's subject, or nil for a row that waits for nothing.
    var rowStatusText: String? {
        switch self {
        case .none: return nil
        case .needsAnswer: return approvalWaitingStatusText
        case .waitsItsTurn: return "\(approvalWaitingStatusText) after the one above"
        }
    }
}
