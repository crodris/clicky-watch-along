//
//  VoiceApprovals.swift
//  leanring-buddy
//
//  The pure rules for answering a task agent's approval request: what the voice tool `answer_approval` means, what the
//  voice command router may read about a waiting request, which agent row shows the request, and the chip's words.
//  The queue itself is `HarnessApprovalDesk` in AgentHarness.swift. Nothing here draws or talks to the network.
//
//  An approval summary is built by the harness from the call's own input, so it can hold text that a web page or an MCP
//  server wrote. The summary is shown to the learner in full, and it never reaches the voice command router, which could
//  be talked into approving by it.
//

import Foundation

// MARK: - What the router may read

extension HarnessCapability {
    /// The one word the voice command router reads about a waiting request. A capability this app does not know reads as
    /// "unknown", so a word the harness made up never reaches the router.
    nonisolated var routerWord: String {
        switch self {
        case .sends: return "sends"
        case .deletes: return "deletes"
        case .spends: return "spends"
        case .readsPrivate: return "reads_private"
        case .unknown: return "unknown"
        }
    }
}

/// The router's `approvalWaiting` value: the capability word of the request a "yes" or "no" would answer, or nil when
/// none waits. It takes the request but reads only its capability, so the summary, the tool's input, and an MCP tool's
/// name stay out of the router's scene state.
nonisolated func voiceCommandApprovalWaitingState(oldestWaitingRequest: HarnessApprovalRequest?) -> String? {
    oldestWaitingRequest?.capability.routerWord
}

// MARK: - The voice answer

/// The router's `answer_approval` call, read at the boundary. "Always" only means something with a yes, since a no is
/// never remembered (harness/approval.go), so a no with always set stays a plain no.
nonisolated struct ApprovalVoiceAnswer: Equatable, Sendable {
    let approved: Bool
    let scope: HarnessApprovalScope

    /// Nil when `approved` is missing or is not a boolean, so a malformed call never answers by guessing.
    init?(toolInput: [String: JSONValue]) {
        guard let approved = toolInput["approved"]?.boolValue else { return nil }
        self.approved = approved
        self.scope = approved && toolInput["always"]?.boolValue == true ? .always : .once
    }

    /// What the chip under the cursor says once the answer went through.
    var chipPhrase: String {
        guard approved else { return "Declined it" }
        return scope == .always ? "Allowed it, always" : "Allowed it"
    }
}

// MARK: - What the learner said

/// Words that say yes, and phrases of two words that do.
private let approvalYesWords: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "allow", "approve", "approved", "fine", "alright"]
private let approvalYesPhrases = ["go ahead", "do it", "all right"]
/// Words that say no. "Not" covers "do not" and "don't allow".
private let approvalNoWords: Set<String> = ["no", "nope", "nah", "not", "don't", "dont", "stop", "cancel", "decline", "deny", "never"]
/// The other words a short yes may hold, such as "yes please", "go ahead and do it", or "always allow that, thanks".
private let approvalAnswerFillerWords: Set<String> = [
    "go", "ahead", "do", "it", "that", "this", "one", "please", "always", "all", "right", "and", "thanks", "thank", "you", "hey", "clicky", "of", "course",
]

/// The model's answer when the learner's own words support it, or nil when they do not. The router model also reads
/// text a page wrote, such as a video title, which could talk it into a yes, so a yes counts only when the whole
/// transcript is a short answer: it says yes, holds no word of no, and has no word outside the answer's vocabulary, so
/// "okay, what is this video about" is not a yes. An "always" counts only when the learner said always. A no needs no check, since
/// declining is always safe. The answer is refused rather than changed, so the chip, which reads the model's input,
/// never names an answer the learner did not give.
nonisolated func approvalVoiceAnswerTheLearnerSaid(_ modelAnswer: ApprovalVoiceAnswer, transcript: String) -> ApprovalVoiceAnswer? {
    guard modelAnswer.approved else { return modelAnswer }
    let transcriptWords = transcript
        .lowercased()
        .replacingOccurrences(of: "\u{2019}", with: "'")
        .split(whereSeparator: { !$0.isLetter && $0 != "'" })
        .map(String.init)
    let spacedTranscript = " " + transcriptWords.joined(separator: " ") + " "
    let saysNo = transcriptWords.contains(where: approvalNoWords.contains)
    // A bare "always" is a yes too, when the model heard it as one.
    let saysYes = transcriptWords.contains(where: approvalYesWords.contains)
        || approvalYesPhrases.contains { spacedTranscript.contains(" \($0) ") }
        || (modelAnswer.scope == .always && transcriptWords.contains("always"))
    let isAShortAnswer = transcriptWords.allSatisfy { approvalYesWords.contains($0) || approvalAnswerFillerWords.contains($0) }
    guard saysYes && !saysNo && isAShortAnswer else { return nil }
    if modelAnswer.scope == .always && !transcriptWords.contains("always") { return nil }
    return modelAnswer
}

// MARK: - The agent list

/// What an agent's row in the agent list shows about approvals.
nonisolated enum AgentListApprovalState: Equatable, Sendable {
    case none
    /// The row shows the request and the Yes, Always, and No buttons.
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

/// The chip under the cursor while a request waits: "Hinata needs your OK" with the way to answer after it, in the
/// agent's color. `agentName` is the agent's player under a team theme, and the kind's name otherwise.
nonisolated func approvalWaitingChipTexts(agentName: String) -> (primary: String, secondary: String) {
    ("\(agentName) needs your OK", "· say yes or no")
}

extension AgentListApprovalState {
    var needsAnAnswer: Bool {
        if case .needsAnswer = self { return true }
        return false
    }

    /// The line under the row's subject, or nil for a row that waits for nothing.
    var rowStatusText: String? {
        switch self {
        case .none: return nil
        case .needsAnswer: return approvalWaitingStatusText
        case .waitsItsTurn: return "\(approvalWaitingStatusText) after the one above"
        }
    }
}
