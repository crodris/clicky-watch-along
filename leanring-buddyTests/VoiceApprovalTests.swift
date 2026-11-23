//
//  VoiceApprovalTests.swift
//  leanring-buddyTests
//
//  How a learner answers a task agent's approval request: when the voice tool is offered, the chip after an answer, which
//  agent row shows the request, and the waiting state an agent shows. The harness settles the yes check itself
//  (harness/voiceapproval_test.go). The queue's own rules are in AgentHarnessTests.
//

import CoreGraphics
import Foundation
import Testing
@testable import Clicky

@MainActor
struct VoiceApprovalTests {
    private let firstAgentID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    private let secondAgentID = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

    private func aRequest(_ approvalID: String, agentID: UUID, capability: HarnessCapability = .sends, summary: String = "Open https://example.com") -> HarnessApprovalRequest {
        HarnessApprovalRequest(taskID: agentID, approvalID: approvalID, capability: capability, summary: summary)
    }

    // MARK: - The tool

    @Test func answerApprovalIsOfferedOnlyWhileARequestWaits() {
        var context = AppVoiceTool.Context(sceneIsOnScreen: false, sceneHasLabels: false, videoIsInFront: false, videoIsOnYouTube: false, videoQuizIsRunning: false, quizQuestionIsOpen: false)
        #expect(!AppVoiceTool.available(in: context).contains(.answerApproval))

        context.approvalIsWaiting = true
        #expect(AppVoiceTool.available(in: context).contains(.answerApproval))
        #expect(AppVoiceTool.answerApproval.rawValue == "answer_approval")
    }

    @Test func theRouterTakesEveryCommandWhileARequestWaitsExceptAQuizAnswerOrASceneStillBuilding() {
        let takesTheTranscript = { (approvalIsWaiting: Bool, quizAnswerIsWaiting: Bool, sceneIsBuilding: Bool) in
            voiceCommandRouterTakesTheTranscript(
                sceneIsOnScreen: false,
                videoIsInFront: false,
                approvalIsWaiting: approvalIsWaiting,
                phaseIsWaitingForAQuizAnswer: quizAnswerIsWaiting,
                sceneIsBuilding: sceneIsBuilding
            )
        }
        #expect(!takesTheTranscript(false, false, false), "with nothing live, a plain question keeps the quick path")
        #expect(takesTheTranscript(true, false, false), "a yes or no has no video or scene to ride on")
        #expect(!takesTheTranscript(true, true, false), "a quiz answer still goes to the judge")
        #expect(!takesTheTranscript(true, false, true), "a scene still building keeps its keyword path")
    }

    /// The harness's approval_settled shows the one chip, with the answer its gate took, so the call shows none of its own.
    @Test func theAnswerCallShowsNoChipSinceTheSettlementShowsTheOutcome() {
        #expect(ApprovalVoiceAnswer(approved: true, scope: .once).chipPhrase == "Allowed it")
        #expect(ApprovalVoiceAnswer(approved: true, scope: .always).chipPhrase == "Allowed it for this task")
        #expect(ApprovalVoiceAnswer(approved: false, scope: .once).chipPhrase == "Declined it")

        let answer = VoiceToolCall(id: "answer", name: "answer_approval", input: ["approved": .bool(true), "always": .bool(false), "confirmation": .string("allowed it")])
        #expect(answer.chipPhrase == nil)
        #expect(answer.chipPhraseToShow(at: .beforeTheCall, offeredToolNames: ["answer_approval"]) == nil)
        #expect(answer.chipPhraseToShow(at: .afterTheCall(.changed(state: nil)), offeredToolNames: ["answer_approval"]) == nil)
    }

    // MARK: - The agent list

    @Test func onlyTheOldestRequestsAgentShowsTheButtonsAndALaterAgentWaitsItsTurn() {
        let waitingRequests = [
            aRequest("approval-1", agentID: firstAgentID, capability: .readsPrivate),
            aRequest("approval-2", agentID: secondAgentID, capability: .deletes),
        ]
        #expect(agentListApprovalState(forAgentID: firstAgentID, waitingRequests: waitingRequests) == .needsAnswer(waitingRequests[0]))
        #expect(agentListApprovalState(forAgentID: secondAgentID, waitingRequests: waitingRequests) == .waitsItsTurn(.deletes))
        #expect(agentListApprovalState(forAgentID: UUID(), waitingRequests: waitingRequests) == .none)
        #expect(agentListApprovalState(forAgentID: firstAgentID, waitingRequests: []) == .none)

        let afterTheFirstAnswer = Array(waitingRequests.dropFirst())
        #expect(agentListApprovalState(forAgentID: secondAgentID, waitingRequests: afterTheFirstAnswer) == .needsAnswer(waitingRequests[1]))
    }

    @Test func aRowSaysWhetherItsAgentWaitsForAnAnswer() {
        #expect(AgentListApprovalState.none.rowStatusText == nil)
        #expect(AgentListApprovalState.needsAnswer(aRequest("approval-1", agentID: firstAgentID)).rowStatusText == "Needs your OK")
        #expect(AgentListApprovalState.waitsItsTurn(.sends).rowStatusText == "Needs your OK after the one above")
    }

    @Test func theChipNamesTheAgentAndTheWayToAnswer() {
        let chipTexts = approvalWaitingChipTexts(agentName: "Hinata")
        #expect(chipTexts.primary == "Hinata needs your OK")
        #expect(chipTexts.secondary == "· say yes or no")
    }

    // MARK: - Where the list opens

    @Test func theListOpensForARequestWhereItDoesNotCoverTheMouse() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = CGSize(width: 300, height: 360)
        for mouseLocation in [CGPoint(x: 700, y: 450), CGPoint(x: 1430, y: 10), CGPoint(x: 10, y: 10), CGPoint(x: 1430, y: 890), CGPoint(x: 10, y: 890)] {
            let anchorTopLeft = approvalListAnchorTopLeft(mouseLocation: mouseLocation, panelSize: panelSize, visibleFrame: visibleFrame, gapFromTheMouse: 12)
            let panelOrigin = agentListPanelOrigin(anchorTopLeft: anchorTopLeft, panelSize: panelSize, visibleFrame: visibleFrame)
            #expect(!CGRect(origin: panelOrigin, size: panelSize).contains(mouseLocation), "the list covered the mouse at \(mouseLocation)")
        }
        // In open space it opens below and to the right, as the list always has.
        #expect(approvalListAnchorTopLeft(mouseLocation: CGPoint(x: 700, y: 450), panelSize: panelSize, visibleFrame: visibleFrame, gapFromTheMouse: 12) == CGPoint(x: 712, y: 438))
    }
}
