//
//  AgentHarnessTests.swift
//  leanring-buddyTests
//
//  The messages between the app and the Go agent harness. The lines below are the ones harness/loop_test.go asserts
//  the harness writes, so the two sides agree on the wire format. The loop's own rules are tested in Go.
//

import AppKit
import Foundation
import Testing
@testable import Clicky

@MainActor
struct AgentHarnessTests {
    private let firstTaskID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    private let secondTaskID = UUID(uuidString: "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D")!

    // MARK: - Messages from the harness

    @Test func everyMessageTheHarnessWritesParsesIntoItsType() throws {
        #expect(try HarnessMessage(line: #"{"type":"ready"}"#) == .ready)

        let toolCallLine = #"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_report","name":"report_step","input":{"step":"Searching for the booster catch"}}"#
        #expect(try HarnessMessage(line: toolCallLine) == .toolCall(
            taskID: firstTaskID,
            HarnessToolCall(toolUseID: "toolu_report", toolName: "report_step", input: ["step": .string("Searching for the booster catch")])
        ))

        // A tool with no input still carries an object.
        let lookCallLine = #"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_look","name":"look_at_video","input":{}}"#
        #expect(try HarnessMessage(line: lookCallLine) == .toolCall(taskID: firstTaskID, HarnessToolCall(toolUseID: "toolu_look", toolName: "look_at_video", input: [:])))

        #expect(try HarnessMessage(line: #"{"type":"task_finished","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenSummary":"It was caught."}"#)
            == .taskFinished(taskID: firstTaskID, spokenSummary: "It was caught."))
        #expect(try HarnessMessage(line: #"{"type":"task_failed","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","reason":"the agent used all 14 turns without finishing"}"#)
            == .taskFailed(taskID: firstTaskID, reason: "the agent used all 14 turns without finishing"))
        #expect(try HarnessMessage(line: #"{"type":"log","message":"Task agent: finished in 12 s after 2 turns"}"#)
            == .log(message: "Task agent: finished in 12 s after 2 turns"))
    }

    @Test func aToolNameTheAppDoesNotKnowStillParsesSoTheTaskCanAnswerItWithAnError() throws {
        let line = #"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_new","name":"a_newer_tool","input":{}}"#
        guard case .toolCall(_, let toolCall) = try HarnessMessage(line: line) else {
            Issue.record("the line did not parse as a tool call")
            return
        }
        #expect(toolCall.toolName == "a_newer_tool")
        #expect(TaskAgentTool(rawValue: toolCall.toolName) == nil)
        #expect(TaskAgentTool(rawValue: "write_notion_page") == .writeNotionPage)
    }

    @Test func aLineThatIsNotAWholeHarnessMessageIsRefused() {
        let refusedLines: [(line: String, error: HarnessMessage.ParseError)] = [
            ("harness: could not write", .notAJSONObject),
            ("[1,2]", .notAJSONObject),
            (#"{"taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}"#, .unknownType("")),
            (#"{"type":"unheard_of"}"#, .unknownType("unheard_of")),
            (#"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"report_step","input":{}}"#, .missingField(messageType: "tool_call", fieldName: "toolUseID")),
            (#"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"t","name":"report_step","input":"x"}"#, .missingField(messageType: "tool_call", fieldName: "input")),
            (#"{"type":"task_finished","taskID":"task-1","spokenSummary":"Done."}"#, .missingField(messageType: "task_finished", fieldName: "taskID")),
            (#"{"type":"task_failed","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}"#, .missingField(messageType: "task_failed", fieldName: "reason")),
            (#"{"type":"log"}"#, .missingField(messageType: "log", fieldName: "message")),
        ]
        for refusedLine in refusedLines {
            #expect(throws: refusedLine.error, "\(refusedLine.line)") {
                try HarnessMessage(line: refusedLine.line)
            }
        }
    }

    // MARK: - Messages to the harness

    private func decodedJSON(of commandLine: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: commandLine)
    }

    @Test func eachCommandIsOneLineOfJSONWithTheFieldsTheHarnessReads() throws {
        let startWithATab = HarnessCommand.startTask(taskID: firstTaskID, goal: "compare the catches", frontTabTitle: "SpaceX catch", frontTabURL: "https://www.youtube.com/watch?v=abc", skill: nil)
        #expect(try decodedJSON(of: startWithATab.line) == .object([
            "type": .string("start_task"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            "goal": .string("compare the catches"),
            "frontTabTitle": .string("SpaceX catch"),
            "frontTabURL": .string("https://www.youtube.com/watch?v=abc"),
            "skill": .null,
        ]))

        let startWithNoTab = HarnessCommand.startTask(taskID: firstTaskID, goal: "compare", frontTabTitle: nil, frontTabURL: nil, skill: "flashcards")
        #expect(try decodedJSON(of: startWithNoTab.line)["frontTabTitle"] == .null)
        #expect(try decodedJSON(of: startWithNoTab.line)["frontTabURL"] == .null)
        #expect(try decodedJSON(of: startWithNoTab.line)["skill"] == .string("flashcards"))
        #expect(try decodedJSON(of: startWithNoTab.line)["startsPaused"] == nil)

        // A task started while the learner paused every agent waits for resume_task, and the two lines name the task.
        let startPaused = HarnessCommand.startTask(taskID: firstTaskID, goal: "compare", frontTabTitle: nil, frontTabURL: nil, skill: nil, startsPaused: true)
        #expect(try decodedJSON(of: startPaused.line)["startsPaused"] == .bool(true))
        #expect(try decodedJSON(of: HarnessCommand.pauseTask(taskID: firstTaskID).line) == .object([
            "type": .string("pause_task"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
        ]))
        #expect(try decodedJSON(of: HarnessCommand.resumeTask(taskID: firstTaskID).line) == .object([
            "type": .string("resume_task"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
        ]))

        let textResult = HarnessCommand.toolResult(taskID: firstTaskID, toolUseID: "toolu_report", content: .string("shown"), isError: false)
        #expect(try decodedJSON(of: textResult.line) == .object([
            "type": .string("tool_result"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            "toolUseID": .string("toolu_report"),
            "content": .string("shown"),
            "isError": .bool(false),
        ]))

        // look_at_video returns an image block, which goes through as the content array.
        let imageBlock: JSONValue = .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/jpeg"), "data": .string("QUJD")])])
        let imageResult = HarnessCommand.toolResult(taskID: firstTaskID, toolUseID: "toolu_look", content: .array([imageBlock]), isError: true)
        #expect(try decodedJSON(of: imageResult.line)["content"] == .array([imageBlock]))
        #expect(try decodedJSON(of: imageResult.line)["isError"] == .bool(true))

        // The video link rides in its own field and is left out of every other result, so the harness reads it from there
        // alone.
        #expect(try decodedJSON(of: textResult.line)["sourceURL"] == nil)
        let captionsResult = HarnessCommand.toolResult(taskID: firstTaskID, toolUseID: "toolu_captions", content: .string("Title: A video"), isError: false, sourceURL: "https://www.youtube.com/watch?v=abc")
        #expect(try decodedJSON(of: captionsResult.line)["sourceURL"] == .string("https://www.youtube.com/watch?v=abc"))

        #expect(try decodedJSON(of: HarnessCommand.cancelTask(taskID: firstTaskID).line) == .object([
            "type": .string("cancel_task"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
        ]))
        #expect(try decodedJSON(of: HarnessCommand.cancelTask(taskID: firstTaskID, runningToolUseID: "toolu_zoom").line) == .object([
            "type": .string("cancel_task"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            "runningToolUseID": .string("toolu_zoom"),
        ]))
    }

    // MARK: - Voice commands on the brain

    @Test func aVoiceCommandsFinishedLineAndATurnIndexParse() throws {
        // The lines harness/brainloop_test.go asserts the harness writes.
        let finishedLine = #"{"type":"voice_command_finished","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenLine":"turned it left zoomed in","gaveUp":false}"#
        #expect(try HarnessMessage(line: finishedLine) == .voiceCommandFinished(taskID: firstTaskID, spokenLine: "turned it left zoomed in", gaveUp: false))
        let gaveUpLine = #"{"type":"voice_command_finished","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenLine":"","gaveUp":true}"#
        #expect(try HarnessMessage(line: gaveUpLine) == .voiceCommandFinished(taskID: firstTaskID, spokenLine: "", gaveUp: true))
        #expect(throws: HarnessMessage.ParseError.missingField(messageType: "voice_command_finished", fieldName: "gaveUp")) {
            try HarnessMessage(line: #"{"type":"voice_command_finished","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenLine":""}"#)
        }

        let secondTurnCallLine = #"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_seek","name":"seek_to_time","input":{"seconds":95},"turnIndex":1}"#
        #expect(try HarnessMessage(line: secondTurnCallLine) == .toolCall(
            taskID: firstTaskID,
            HarnessToolCall(toolUseID: "toolu_seek", toolName: "seek_to_time", input: ["seconds": .number(95)], turnIndex: 1)
        ))
        // A task's call carries no turn.
        let taskCallLine = #"{"type":"tool_call","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_look","name":"look_at_video","input":{}}"#
        guard case .toolCall(_, let taskCall) = try HarnessMessage(line: taskCallLine) else {
            Issue.record("the task's call did not parse")
            return
        }
        #expect(taskCall.turnIndex == nil)
    }

    @Test func theRouterEndsAVoiceCommandsStreamWithItsFinishedLine() async {
        let router = HarnessTaskRouter()
        let commandEvents = router.register(taskID: firstTaskID)
        router.route(.voiceCommandFinished(taskID: firstTaskID, spokenLine: "zoomed in", gaveUp: false))

        var events: [HarnessTaskEvent] = []
        for await event in commandEvents { events.append(event) }
        #expect(events == [.voiceCommandFinished(spokenLine: "zoomed in", gaveUp: false)])
        #expect(!router.isTracking(taskID: firstTaskID))
    }

    @Test func theBrainsPlanningLineReachesOnlyTheCommandItNamesAsAnEvent() async throws {
        let planningLine = #"{"type":"log","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","message":"Brain: planning on claude-sonnet-5-5"}"#
        let planningMessage = try HarnessMessage(line: planningLine)
        #expect(planningMessage == .log(taskID: firstTaskID, message: "Brain: planning on claude-sonnet-5-5"))

        let router = HarnessTaskRouter()
        let firstCommandEvents = router.register(taskID: firstTaskID)
        let secondCommandEvents = router.register(taskID: secondTaskID)
        router.route(planningMessage)
        // A log line with no command, or about another thing, is only printed.
        router.route(.log(message: "Brain: planning on claude-sonnet-5-5"))
        router.route(.log(taskID: secondTaskID, message: "Brain: turn 1 on claude-haiku-5-5 stopped for tool_use"))
        router.route(.voiceCommandFinished(taskID: firstTaskID, spokenLine: "", gaveUp: false))
        router.route(.voiceCommandFinished(taskID: secondTaskID, spokenLine: "", gaveUp: false))

        var firstEvents: [HarnessTaskEvent] = []
        for await event in firstCommandEvents { firstEvents.append(event) }
        var secondEvents: [HarnessTaskEvent] = []
        for await event in secondCommandEvents { secondEvents.append(event) }
        #expect(firstEvents == [.planningTurnStarted, .voiceCommandFinished(spokenLine: "", gaveUp: false)])
        #expect(secondEvents == [.voiceCommandFinished(spokenLine: "", gaveUp: false)])
    }

    @Test func aVoiceCommandAndItsToolResultAreEachOneLineWithTheFieldsTheBrainReads() throws {
        let rotateTool = VoiceToolDescriptor(
            name: "rotate_model",
            description: "Turns it.",
            inputSchema: .object(["type": .string("object"), "properties": .object(["yawDegrees": .object(["type": .string("number")])])]),
            readOnly: false
        )
        let voiceCommand = HarnessCommand.voiceCommand(
            taskID: firstTaskID,
            transcript: "turn it left",
            sceneState: .object(["page": .string("framePopout")]),
            tools: [rotateTool],
            approvalAtPress: nil
        )
        #expect(try decodedJSON(of: voiceCommand.line) == .object([
            "type": .string("voice_command"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            "transcript": .string("turn it left"),
            "sceneState": .object(["page": .string("framePopout")]),
            "tools": .array([rotateTool.workerRequestJSON]),
            "approvalIDWaitingAtPress": .null,
            "approvalIDSeenAtPress": .null,
        ]))
        // The request the card showed at the press rides in the same line, for the harness to check, and it is named as
        // seen only when a card had shown its whole summary for a second, since only then may a yes answer it.
        let answeringCommand = HarnessCommand.voiceCommand(
            taskID: firstTaskID,
            transcript: "yes",
            sceneState: .object([:]),
            tools: [rotateTool],
            approvalAtPress: ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: true)
        )
        #expect(try decodedJSON(of: answeringCommand.line)["approvalIDWaitingAtPress"] == .string("approval-1"))
        #expect(try decodedJSON(of: answeringCommand.line)["approvalIDSeenAtPress"] == .string("approval-1"))
        let unreadCommand = HarnessCommand.voiceCommand(
            taskID: firstTaskID,
            transcript: "no",
            sceneState: .object([:]),
            tools: [rotateTool],
            approvalAtPress: ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: false)
        )
        #expect(try decodedJSON(of: unreadCommand.line)["approvalIDWaitingAtPress"] == .string("approval-1"))
        #expect(try decodedJSON(of: unreadCommand.line)["approvalIDSeenAtPress"] == .null, "a no may answer it, a yes may not")
        #expect(String(decoding: voiceCommand.line, as: UTF8.self).dropLast().contains("\n") == false)

        // harness/protocol_test.go parses this exact line.
        let handedOffResult = HarnessCommand.voiceToolResult(taskID: firstTaskID, toolUseID: "toolu_pop", outcome: .handedOff)
        #expect(String(decoding: handedOffResult.line, as: UTF8.self)
            == #"{"content":"{\"ok\":true}","isError":false,"outcome":"handedOff","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_pop","type":"tool_result"}"# + "\n")
        let failedResult = HarnessCommand.voiceToolResult(taskID: firstTaskID, toolUseID: "toolu_seek", outcome: .failed(error: "no video", state: nil))
        #expect(try decodedJSON(of: failedResult.line)["outcome"] == .string("failed"))
        #expect(try decodedJSON(of: failedResult.line)["isError"] == .bool(true))
        #expect(try decodedJSON(of: HarnessCommand.voiceToolResult(taskID: firstTaskID, toolUseID: "t", outcome: .changed(state: nil)).line)["outcome"] == .string("changed"))
        #expect(try decodedJSON(of: HarnessCommand.voiceToolResult(taskID: firstTaskID, toolUseID: "t", outcome: .lookedUp(result: .null)).line)["outcome"] == .string("lookedUp"))
    }

    @Test func aCommandWithNewlinesInItsTextStillTakesOneLine() {
        let command = HarnessCommand.toolResult(taskID: firstTaskID, toolUseID: "toolu_captions", content: .string("[0:01] first\n[0:05] second\r\n"), isError: false)
        let lineText = String(decoding: command.line, as: UTF8.self)

        #expect(lineText.hasSuffix("\n"))
        #expect(lineText.dropLast().contains("\n") == false)
        #expect(lineText.dropLast().contains("\r") == false)
    }

    // MARK: - The harness's environment

    @Test func theHarnessGetsOnlyTheVariablesItReadsWithTheLearnersSkillsBeforeTheBundledOnes() {
        let learnerSkills = URL(fileURLWithPath: "/Users/me/Library/Application Support/Clicky/Skills")
        // Xcode copies leanring-buddy/Skills/flashcards.md to the top of Resources, with no Skills folder.
        let bundledSkills = URL(fileURLWithPath: "/Applications/Clicky.app/Contents/Resources")

        let parentEnvironment = ["PATH": "/usr/bin", "HOME": "/Users/me", "ANTHROPIC_API_KEY": "sk-ant", "CLICKY_APP_SECRET": "stale"]
        let environment = agentHarnessEnvironment(
            workerBaseURL: "http://localhost:8787",
            appSecret: "secret",
            skillsDirectoryURLs: [learnerSkills, bundledSkills],
            mcpConfigURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/Clicky/mcp.json"),
            parentEnvironment: parentEnvironment
        )
        // A credential in the app's own environment never reaches the harness, and the app's secret is the defaults one.
        #expect(environment == [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "CLICKY_WORKER_BASE_URL": "http://localhost:8787",
            "CLICKY_APP_SECRET": "secret",
            "CLICKY_SKILLS_DIRS": "/Users/me/Library/Application Support/Clicky/Skills:/Applications/Clicky.app/Contents/Resources",
            "CLICKY_MCP_CONFIG": "/Users/me/Library/Application Support/Clicky/mcp.json",
        ])
        #expect(agentHarnessEnvironment(workerBaseURL: "http://localhost:8787", appSecret: "", skillsDirectoryURLs: [])
            == ["CLICKY_WORKER_BASE_URL": "http://localhost:8787"])

        let folders = TaskAgentFolders.skillsDirectoryURLs(
            bundleResourceURL: URL(fileURLWithPath: "/Applications/Clicky.app/Contents/Resources"),
            clickyApplicationSupportURL: URL(fileURLWithPath: "/Users/me/Library/Application Support/Clicky")
        )
        #expect(folders.map(\.path) == [learnerSkills.path, bundledSkills.path])
    }

    // MARK: - Approvals

    @Test func anApprovalSettledParsesWithTheAnswerTheGateTook() throws {
        // harness/voiceapproval_test.go writes these exact lines.
        #expect(try HarnessMessage(line: #"{"type":"approval_settled","approvalID":"approval-1","approved":true,"scope":"always"}"#)
            == .approvalSettled(approvalID: "approval-1", approved: true, scope: .always))
        #expect(try HarnessMessage(line: #"{"type":"approval_settled","approvalID":"approval-2","approved":false,"scope":"once"}"#)
            == .approvalSettled(approvalID: "approval-2", approved: false, scope: .once))
        // A scope this app does not know reads as once, the narrower of the two.
        #expect(try HarnessMessage(line: #"{"type":"approval_settled","approvalID":"approval-3","approved":true,"scope":"forever"}"#)
            == .approvalSettled(approvalID: "approval-3", approved: true, scope: .once))
        #expect(throws: HarnessMessage.ParseError.missingField(messageType: "approval_settled", fieldName: "approved")) {
            try HarnessMessage(line: #"{"type":"approval_settled","approvalID":"approval-1","scope":"once"}"#)
        }
    }

    @Test func anApprovalRequestParsesWithEveryCapabilityTheHarnessSends() throws {
        let capabilityNames = ["sends": HarnessCapability.sends, "deletes": .deletes, "spends": .spends, "reads_private": .readsPrivate, "teleports": .unknown("teleports")]
        for (wireName, expectedCapability) in capabilityNames {
            let line = #"{"type":"approval_request","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","approvalID":"approval-1","capability":"\#(wireName)","summary":"Read the text on your clipboard."}"#
            #expect(try HarnessMessage(line: line) == .approvalRequest(HarnessApprovalRequest(
                taskID: firstTaskID, approvalID: "approval-1", capability: expectedCapability, summary: "Read the text on your clipboard."
            )))
        }
        #expect(throws: HarnessMessage.ParseError.missingField(messageType: "approval_request", fieldName: "summary")) {
            try HarnessMessage(line: #"{"type":"approval_request","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","approvalID":"approval-1","capability":"sends"}"#)
        }
    }

    @Test func anApprovalAnswerIsOneLineWithTheFieldsTheHarnessReads() throws {
        let answer = HarnessCommand.approvalResult(approvalID: "approval-1", approved: true, scope: .always)
        #expect(try decodedJSON(of: answer.line) == .object([
            "type": .string("approval_result"),
            "approvalID": .string("approval-1"),
            "approved": .bool(true),
            "scope": .string("always"),
        ]))
    }

    private func anApprovalRequest(_ approvalID: String, taskID: UUID? = nil, capability: HarnessCapability = .readsPrivate) -> HarnessApprovalRequest {
        HarnessApprovalRequest(taskID: taskID ?? firstTaskID, approvalID: approvalID, capability: capability, summary: "Read the text on your clipboard.")
    }

    @Test func theDeskHoldsRequestsInArrivalOrderAndTheLearnerAnswersTheOldestFirst() {
        var answers: [(approvalID: String, approved: Bool, scope: HarnessApprovalScope)] = []
        let desk = HarnessApprovalDesk { approvalID, approved, scope in answers.append((approvalID, approved, scope)) }

        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-2", taskID: secondTaskID, capability: .sends))
        desk.receive(anApprovalRequest("approval-3"))
        #expect(answers.isEmpty, "a request waits for the learner instead of being declined")
        #expect(desk.waitingRequests.map(\.approvalID) == ["approval-1", "approval-2", "approval-3"])
        #expect(desk.oldestWaitingRequest?.approvalID == "approval-1")

        #expect(desk.answer(approvalID: "approval-1", approved: true, scope: .always))
        #expect(desk.oldestWaitingRequest?.approvalID == "approval-1", "the card stays until the harness settles the request")
        desk.settle(approvalID: "approval-1", approved: true, scope: .always)
        #expect(desk.oldestWaitingRequest?.approvalID == "approval-2", "a settlement moves on to the next request")
        #expect(desk.answer(approvalID: "approval-2", approved: false, scope: .once))
        desk.settle(approvalID: "approval-2", approved: false, scope: .once)
        #expect(answers.map(\.approvalID) == ["approval-1", "approval-2"])
        #expect(answers.map(\.approved) == [true, false])
        #expect(answers.map(\.scope) == [.always, .once])
    }

    /// The learner's click goes to the harness, whose gate may take a voice answer first. The card stays, marked as
    /// answering, and the outcome shown is the one in `approval_settled`, so a decline the gate did not take is never shown.
    @Test func aClickThenAnApprovalSettledForAVoiceYesShowsTheVoiceAnswer() {
        var answers: [(approvalID: String, approved: Bool)] = []
        var now = Date(timeIntervalSince1970: 1_000)
        let desk = HarnessApprovalDesk(currentDate: { now }) { approvalID, approved, _ in answers.append((approvalID, approved)) }
        var shownOutcomes: [(approved: Bool, scope: HarnessApprovalScope)] = []
        desk.onApprovalSettled = { approved, scope in shownOutcomes.append((approved, scope)) }
        desk.receive(anApprovalRequest("approval-1"))
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .agentList)
        now += 2

        // The learner clicks No, and the click is on its way to the harness.
        #expect(desk.answerByClick(approvalID: "approval-1", approved: false, scope: .once, on: .agentList))
        #expect(desk.answeringApprovalIDs == ["approval-1"])
        #expect(desk.waitingRequests.map(\.approvalID) == ["approval-1"], "the card stays until the harness settles the request")
        #expect(shownOutcomes.isEmpty, "a click shows no outcome of its own")
        #expect(!desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once, on: .agentList), "a second click while answering changes nothing")

        // The gate had already taken the voice yes, so the settlement says yes.
        desk.settle(approvalID: "approval-1", approved: true, scope: .once)
        #expect(shownOutcomes.map(\.approved) == [true])
        #expect(ApprovalVoiceAnswer(approved: shownOutcomes[0].approved, scope: shownOutcomes[0].scope).chipPhrase == "Allowed it")
        #expect(desk.waitingRequests.isEmpty)
        #expect(desk.answeringApprovalIDs.isEmpty)
        #expect(answers.map(\.approvalID) == ["approval-1"])
    }

    @Test func anApprovalSettledThenALateClickChangesNothing() {
        var answers: [String] = []
        var shownOutcomeCount = 0
        var now = Date(timeIntervalSince1970: 1_000)
        let desk = HarnessApprovalDesk(currentDate: { now }) { approvalID, _, _ in answers.append(approvalID) }
        desk.onApprovalSettled = { _, _ in shownOutcomeCount += 1 }
        desk.receive(anApprovalRequest("approval-1"))
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .agentList)
        now += 2

        desk.settle(approvalID: "approval-1", approved: true, scope: .always)
        #expect(shownOutcomeCount == 1)
        #expect(ApprovalVoiceAnswer(approved: true, scope: .always).chipPhrase == "Allowed it for this task")
        #expect(ApprovalVoiceAnswer(approved: false, scope: .once).chipPhrase == "Declined it")

        #expect(!desk.answerByClick(approvalID: "approval-1", approved: false, scope: .once, on: .agentList))
        desk.settle(approvalID: "approval-1", approved: false, scope: .once)
        #expect(answers.isEmpty, "the late click sent nothing")
        #expect(shownOutcomeCount == 1, "a second settlement for a request the desk dropped shows nothing")
    }

    @Test func aRequestIsAnsweredOnceAndARepeatedIDIsNotQueuedTwice() {
        var answers: [String] = []
        let desk = HarnessApprovalDesk { approvalID, _, _ in answers.append(approvalID) }

        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-1"))
        #expect(desk.waitingRequests.count == 1)
        #expect(desk.answer(approvalID: "approval-1", approved: true, scope: .once))
        #expect(!desk.answer(approvalID: "approval-1", approved: false, scope: .once), "a request is answered once")
        #expect(!desk.answer(approvalID: "approval-404", approved: true, scope: .once))
        #expect(answers == ["approval-1"])
    }

    /// Records each delay the desk schedules and runs one only when a test says, so no desk test waits on a clock.
    @MainActor private final class ScheduledDelays {
        private var scheduled: [(afterSeconds: Double, work: @MainActor () -> Void, hasRun: Bool)] = []

        func schedule(afterSeconds: Double, work: @escaping @MainActor () -> Void) {
            scheduled.append((afterSeconds, work, false))
        }

        /// Runs the earliest scheduled delay of this length that has not run, and says whether there was one.
        @discardableResult
        func runTheNext(afterSeconds: Double) -> Bool {
            guard let index = scheduled.firstIndex(where: { $0.afterSeconds == afterSeconds && !$0.hasRun }) else { return false }
            scheduled[index].hasRun = true
            scheduled[index].work()
            return true
        }
    }

    @Test func aRequestNoOneAnswersIsDeclinedAfterTheTimeoutAndAnAnsweredOneIsNot() {
        var answers: [(approvalID: String, approved: Bool)] = []
        let delays = ScheduledDelays()
        let desk = HarnessApprovalDesk(timeoutSeconds: 1, answerSettleGraceSeconds: 2, scheduleAfter: delays.schedule) { approvalID, approved, _ in answers.append((approvalID, approved)) }

        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-2"))
        #expect(answers.isEmpty, "a request waits before the timeout")
        #expect(desk.answer(approvalID: "approval-1", approved: true, scope: .always))

        // The first request's timeout finds it already answered, and the second's declines it.
        #expect(delays.runTheNext(afterSeconds: 1))
        #expect(delays.runTheNext(afterSeconds: 1))
        #expect(!delays.runTheNext(afterSeconds: 1), "one timeout per request")
        #expect(answers.map(\.approvalID) == ["approval-1", "approval-2"])
        #expect(answers.map(\.approved) == [true, false], "the learner's answer stands and the unanswered request is declined")
        #expect(desk.answeringApprovalIDs == ["approval-1", "approval-2"], "both wait for the harness to settle them")
        #expect(HarnessApprovalDesk.defaultTimeoutSeconds == 120)
    }

    /// The desk's own timeout declines the request, and "Declined it" under the cursor would come with no context.
    @Test func aSettlementTheDesksOwnTimeoutCausedShowsNoOutcomeUnlessTheAnswerWasYes() {
        var shownOutcomes: [Bool] = []
        let delays = ScheduledDelays()
        let desk = HarnessApprovalDesk(timeoutSeconds: 1, answerSettleGraceSeconds: 2, scheduleAfter: delays.schedule) { _, _, _ in }
        desk.onApprovalSettled = { approved, _ in shownOutcomes.append(approved) }
        desk.receive(anApprovalRequest("approval-timed-out"))
        desk.receive(anApprovalRequest("approval-raced"))
        desk.receive(anApprovalRequest("approval-answered"))
        #expect(desk.answer(approvalID: "approval-answered", approved: false, scope: .once))

        #expect(delays.runTheNext(afterSeconds: 1))
        #expect(delays.runTheNext(afterSeconds: 1))
        #expect(delays.runTheNext(afterSeconds: 1))
        #expect(desk.answeringApprovalIDs.count == 3, "the timeout declined the two requests no one answered")

        desk.settle(approvalID: "approval-timed-out", approved: false, scope: .once)
        #expect(shownOutcomes.isEmpty, "the timeout's own decline shows no chip")
        #expect(!desk.waitingRequests.contains { $0.approvalID == "approval-timed-out" }, "the card still goes")
        desk.settle(approvalID: "approval-raced", approved: true, scope: .once)
        #expect(shownOutcomes == [true], "a yes that beat the timeout's decline to the gate still shows")
        desk.settle(approvalID: "approval-answered", approved: false, scope: .once)
        #expect(shownOutcomes == [true, false], "a decline the learner chose shows")
    }

    /// A harness that hung after it took an answer never sends approval_settled, which would leave the card stuck on
    /// "Sending your answer..." for as long as the task lives, since `answer` refuses an ID that is already answering.
    @Test func anAnsweredRequestTheHarnessNeverSettlesIsDroppedAfterTheGracePeriodWithNoOutcome() {
        var shownOutcomeCount = 0
        var changedQueues: [[String]] = []
        let delays = ScheduledDelays()
        let desk = HarnessApprovalDesk(answerSettleGraceSeconds: 2, scheduleAfter: delays.schedule) { _, _, _ in }
        desk.onApprovalSettled = { _, _ in shownOutcomeCount += 1 }
        desk.onWaitingRequestsChanged = { waitingRequests in changedQueues.append(waitingRequests.map(\.approvalID)) }
        desk.receive(anApprovalRequest("approval-stuck"))
        desk.receive(anApprovalRequest("approval-next"))
        #expect(desk.answer(approvalID: "approval-stuck", approved: true, scope: .once))
        #expect(desk.waitingRequests.map(\.approvalID) == ["approval-stuck", "approval-next"], "the card waits through the grace period")

        #expect(delays.runTheNext(afterSeconds: 2))
        #expect(desk.waitingRequests.map(\.approvalID) == ["approval-next"], "the stuck card is dropped and the next request becomes the oldest")
        #expect(desk.answeringApprovalIDs.isEmpty)
        #expect(changedQueues.last == ["approval-next"])
        #expect(shownOutcomeCount == 0, "nobody knows which answer the gate took, so no outcome shows")
        #expect(desk.cardToShow(on: .agentList, at: Date())?.request.approvalID == "approval-next", "the next request shows before the ending")

        desk.settle(approvalID: "approval-stuck", approved: true, scope: .once)
        #expect(shownOutcomeCount == 0, "a settlement that arrives after the drop shows nothing")
    }

    /// A settled request is gone before its grace period ends, so the grace task finds nothing to drop.
    @Test func aRequestTheHarnessSettledInTimeKeepsItsLaterRequestsAfterTheGracePeriod() {
        let delays = ScheduledDelays()
        let desk = HarnessApprovalDesk(answerSettleGraceSeconds: 2, scheduleAfter: delays.schedule) { _, _, _ in }
        desk.receive(anApprovalRequest("approval-1"))
        #expect(desk.answer(approvalID: "approval-1", approved: true, scope: .once))
        desk.settle(approvalID: "approval-1", approved: true, scope: .once)
        desk.receive(anApprovalRequest("approval-2"))

        #expect(delays.runTheNext(afterSeconds: 2), "the grace period of the settled request still ends")
        #expect(desk.waitingRequests.map(\.approvalID) == ["approval-2"], "the grace period of an answered request never touches a later one")
    }

    @Test func aRequestForAnEndedTaskOrAnUnknownActionNeverWaitsForTheLearner() {
        var answers: [(approvalID: String, approved: Bool)] = []
        let desk = HarnessApprovalDesk { approvalID, approved, _ in answers.append((approvalID, approved)) }
        desk.taskIsRunning = { taskID in taskID == self.firstTaskID }

        desk.receive(anApprovalRequest("approval-ended", taskID: secondTaskID))
        #expect(desk.waitingRequests.isEmpty, "a request that crossed a cancel is dropped")
        #expect(answers.isEmpty, "the harness already abandoned it, so nothing is sent")

        desk.receive(anApprovalRequest("approval-unknown", capability: .unknown("teleports")))
        #expect(desk.waitingRequests.isEmpty)
        #expect(answers.map(\.approvalID) == ["approval-unknown"])
        #expect(answers.map(\.approved) == [false], "an action the app cannot name is declined at once")
    }

    /// The card dims Allow once and For this task from `approvalAnswerReadiness`, and the desk's click check reads the same function, so
    /// at every moment the card looks ready exactly when `answerByClick` counts a yes.
    @Test func theCardLooksReadyExactlyWhenAYesCounts() {
        var now = Date(timeIntervalSince1970: 1_000)
        let desk = HarnessApprovalDesk(currentDate: { now }) { _, _, _ in }
        desk.listIsShowing = { true }
        desk.receive(anApprovalRequest("approval-1"))

        #expect(desk.answerReadiness(on: .agentList, at: now) == .summaryNotYetSeen)
        #expect(desk.answerReadiness(on: .agentList, at: now).allowButtonsAreDimmed)
        #expect(desk.cardToShow(on: .agentList, at: now)?.phase == .waiting(.summaryNotYetSeen))
        #expect(approvalCardStatusText(phase: .waiting(.summaryNotYetSeen), reduceMotionIsOn: false) == "Read the whole request to allow it")

        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .agentList)
        now += 0.4
        #expect(desk.answerReadiness(on: .agentList, at: now) == .readyInAMoment)
        #expect(desk.answerReadiness(on: .agentList, at: now).allowButtonsAreDimmed)
        #expect(abs(approvalReadyClockProgress(wholeSummaryShownSince: desk.wholeSummaryShownSinceBySurface[.agentList], at: now) - 0.4) < 0.0001)
        #expect(approvalCardStatusText(phase: .waiting(.readyInAMoment), reduceMotionIsOn: true) == "Ready in 1 s", "Reduce Motion says the clock in words")
        #expect(desk.approvalAtPress(at: now)?.wholeSummaryWasSeen != true, "a dimmed card is a yes that does not count")

        now += 0.7
        #expect(desk.answerReadiness(on: .agentList, at: now) == .ready)
        #expect(!desk.answerReadiness(on: .agentList, at: now).allowButtonsAreDimmed)
        #expect(approvalReadyClockProgress(wholeSummaryShownSince: desk.wholeSummaryShownSinceBySurface[.agentList], at: now) == 1)
        #expect(desk.approvalAtPress(at: now) == ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: true), "a ready card is a yes that counts")

        // Closing the list discards what the card had shown, so the buttons dim again.
        desk.theCardHasNotShownTheWholeSummary(on: .agentList)
        #expect(desk.answerReadiness(on: .agentList, at: now) == .summaryNotYetSeen)
    }

    /// Instant No: a wrong no costs the agent a retry, while a wrong yes can send data out, so Don't allow counts before
    /// the summary was read, and Allow once and For this task do not.
    @Test func aNoCountsAtOnceBeforeTheSummaryWasReadAndAYesDoesNot() {
        let now = Date(timeIntervalSince1970: 1_000)
        var answers: [(approvalID: String, approved: Bool)] = []
        let desk = HarnessApprovalDesk(currentDate: { now }) { approvalID, approved, _ in answers.append((approvalID, approved)) }
        desk.listIsShowing = { true }
        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-2", taskID: secondTaskID))

        #expect(!desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once, on: .agentList))
        #expect(!desk.answerByClick(approvalID: "approval-1", approved: true, scope: .always, on: .agentList))
        #expect(!desk.answerByClick(approvalID: "approval-2", approved: false, scope: .once, on: .agentList), "a no answers only the request the card shows")
        #expect(desk.answerByClick(approvalID: "approval-1", approved: false, scope: .once, on: .agentList))
        #expect(answers.map(\.approvalID) == ["approval-1"])
        #expect(answers.map(\.approved) == [false])
        #expect(desk.cardToShow(on: .agentList, at: now)?.phase == .sending)

        // A voice no from a press before reading reaches the same request: the press names it, unread.
        #expect(desk.approvalAtPress(at: now) == ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: false))
    }

    /// The card shows only what the desk knows: sending until the harness settles, then how the request ended, for a
    /// moment when no other request waits, while a request behind it shows at once.
    @Test func theCardShowsEachEndingFromTheDeskAndTheNextRequestAtOnce() {
        let now = Date(timeIntervalSince1970: 1_000)
        let delays = ScheduledDelays()
        let desk = HarnessApprovalDesk(timeoutSeconds: 60, answerSettleGraceSeconds: 61, secondsAnEndedCardStays: 3, currentDate: { now }, scheduleAfter: delays.schedule) { _, _, _ in }
        desk.receive(anApprovalRequest("approval-1"))
        #expect(desk.answerByClick(approvalID: "approval-1", approved: false, scope: .once, on: .agentList))
        #expect(desk.cardToShow(on: .agentList, at: now)?.phase == .sending)

        desk.settle(approvalID: "approval-1", approved: false, scope: .once)
        #expect(desk.cardToShow(on: .agentList, at: now) == ShownApprovalCard(request: anApprovalRequest("approval-1"), phase: .ended(.declined)))

        desk.receive(anApprovalRequest("approval-2"))
        #expect(desk.cardToShow(on: .agentList, at: now)?.request.approvalID == "approval-2", "a waiting request comes before an ended one")
        desk.settle(approvalID: "approval-2", approved: true, scope: .always)
        #expect(desk.cardToShow(on: .agentList, at: now)?.phase == .ended(.allowed(.always)))

        // The first ending's stay was replaced by the second, so it removes nothing, and the second's removes the card.
        #expect(delays.runTheNext(afterSeconds: 3))
        #expect(desk.cardToShow(on: .agentList, at: now)?.phase == .ended(.allowed(.always)), "an older ending's timer never removes a newer card")
        #expect(delays.runTheNext(afterSeconds: 3))
        #expect(desk.cardToShow(on: .agentList, at: now) == nil, "the ended card goes")
    }

    @Test func anAnswerCountsOnlyOnceTheCardHasShownTheWholeSummaryForASecond() {
        var now = Date(timeIntervalSince1970: 1_000)
        var answeredIDs: [String] = []
        let desk = HarnessApprovalDesk(currentDate: { now }) { approvalID, _, _ in answeredIDs.append(approvalID) }
        desk.listIsShowing = { true }

        desk.receive(anApprovalRequest("approval-1"))
        #expect(desk.approvalAtPress(at: now + 60)?.wholeSummaryWasSeen != true, "no card has shown it yet")

        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .agentList)
        now += 0.5
        #expect(desk.approvalAtPress(at: now)?.wholeSummaryWasSeen != true, "a summary on screen for an instant is one nobody read")
        #expect(!desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once, on: .agentList), "a click meant for the page must not land on Yes")

        // A click closes the list before the second is up, so a later press finds nothing it may answer.
        desk.theCardHasNotShownTheWholeSummary(on: .agentList)
        now += 5
        #expect(desk.approvalAtPress(at: now)?.wholeSummaryWasSeen != true)

        // The list opens again and the card shows all of it for a second, so the press and the click both count.
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1", on: .agentList)
        now += 1.1
        #expect(desk.approvalAtPress(at: now) == ApprovalAtPress(approvalID: "approval-1", wholeSummaryWasSeen: true))
        #expect(desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once, on: .agentList))
        #expect(answeredIDs == ["approval-1"])
    }

    /// "The task goes on" would describe a task that is gone, so an ended card leaves with its task.
    @Test func anEndedCardGoesWhenItsTaskEnds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let desk = HarnessApprovalDesk(secondsAnEndedCardStays: 60, currentDate: { now }) { _, _, _ in }
        desk.receive(anApprovalRequest("approval-1"))
        desk.settle(approvalID: "approval-1", approved: true, scope: .once)
        desk.dropRequests(forTaskID: secondTaskID)
        #expect(desk.cardToShow(on: .agentList, at: now)?.phase == .ended(.allowed(.once)), "another task's end leaves it")

        desk.dropRequests(forTaskID: firstTaskID)
        #expect(desk.cardToShow(on: .agentList, at: now) == nil)
    }

    /// The learner sent nothing for a request the desk's own timeout declined, so a harness that never settles it leaves a
    /// card that says it timed out, never "Sent, but the agent never confirmed it."
    @Test func aTimedOutRequestTheHarnessNeverSettlesEndsAsTimedOut() {
        let delays = ScheduledDelays()
        let desk = HarnessApprovalDesk(timeoutSeconds: 1, answerSettleGraceSeconds: 2, secondsAnEndedCardStays: 60, scheduleAfter: delays.schedule) { _, _, _ in }
        desk.receive(anApprovalRequest("approval-1"))

        #expect(delays.runTheNext(afterSeconds: 1), "the desk's own timeout declines it")
        #expect(desk.cardToShow(on: .agentList, at: Date())?.phase == .sending, "the card says sending until the grace period ends")
        #expect(delays.runTheNext(afterSeconds: 2))
        #expect(desk.waitingRequests.isEmpty)
        #expect(desk.cardToShow(on: .agentList, at: Date())?.phase == .ended(.timedOut))
    }

    @Test func aRequestThatBecomesTheOldestStartsItsCardOverAndOpensAClosedList() {
        var now = Date(timeIntervalSince1970: 1_000)
        var listIsOpen = true
        var requestsThatNeededShowing: [String] = []
        let desk = HarnessApprovalDesk(currentDate: { now }) { _, _, _ in }
        desk.listIsShowing = { listIsOpen }
        desk.onOldestRequestNeedsShowing = { requestsThatNeededShowing.append($0.approvalID) }

        desk.receive(anApprovalRequest("approval-A"))
        desk.receive(anApprovalRequest("approval-B", taskID: secondTaskID))
        // Only the oldest has a card, so a report about another request changes nothing.
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-B", on: .agentList)
        #expect(desk.approvalAtPress(at: now + 60)?.wholeSummaryWasSeen != true)
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-A", on: .agentList)
        now += 2
        #expect(desk.approvalAtPress(at: now) == ApprovalAtPress(approvalID: "approval-A", wholeSummaryWasSeen: true))

        // A ends while the list is closed. B becomes the oldest with no card showing it, so the list is asked to open,
        // and nothing can answer B until its own card has shown it for a second.
        listIsOpen = false
        desk.dropRequests(forTaskID: firstTaskID)
        #expect(requestsThatNeededShowing == ["approval-B"])
        now += 5
        #expect(desk.approvalAtPress(at: now)?.wholeSummaryWasSeen != true)
        #expect(!desk.answerByClick(approvalID: "approval-B", approved: true, scope: .once, on: .agentList))
    }

    @Test func theHarnessStoppingDropsEveryRequestWithoutOpeningTheList() {
        var requestsThatNeededShowing: [String] = []
        let desk = HarnessApprovalDesk { _, _, _ in }
        desk.onOldestRequestNeedsShowing = { requestsThatNeededShowing.append($0.approvalID) }
        desk.receive(anApprovalRequest("approval-A"))
        desk.receive(anApprovalRequest("approval-B", taskID: secondTaskID))
        requestsThatNeededShowing.removeAll()

        desk.dropAllRequests()
        #expect(desk.waitingRequests.isEmpty)
        #expect(requestsThatNeededShowing.isEmpty, "the list must not open for a request that is about to be dropped")
    }

    @Test func theDeskTellsItsOwnerAboutEachArrivalAndEachChangeToTheQueue() {
        var arrivedIDs: [String] = []
        var waitingIDsAfterEachChange: [[String]] = []
        let desk = HarnessApprovalDesk { _, _, _ in }
        desk.onRequestArrived = { arrivedIDs.append($0.approvalID) }
        desk.onWaitingRequestsChanged = { waitingRequests in waitingIDsAfterEachChange.append(waitingRequests.map(\.approvalID)) }

        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-2"))
        desk.answer(approvalID: "approval-1", approved: true, scope: .once)
        desk.settle(approvalID: "approval-1", approved: true, scope: .once)

        #expect(arrivedIDs == ["approval-1", "approval-2"])
        #expect(waitingIDsAfterEachChange == [["approval-1"], ["approval-1", "approval-2"], ["approval-2"]])
    }

    @Test func aTaskThatEndsTakesItsWaitingRequestsWithItAndSendsNoAnswer() {
        var answers: [String] = []
        let desk = HarnessApprovalDesk { approvalID, _, _ in answers.append(approvalID) }
        var changeCount = 0
        desk.onWaitingRequestsChanged = { _ in changeCount += 1 }
        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-2", taskID: secondTaskID))
        changeCount = 0

        desk.dropRequests(forTaskID: firstTaskID)
        #expect(desk.waitingRequests.map(\.approvalID) == ["approval-2"])
        #expect(changeCount == 1)
        desk.dropRequests(forTaskID: firstTaskID)
        #expect(changeCount == 1, "dropping a task with no request changes nothing")
        #expect(answers.isEmpty, "the harness already abandoned the request, so nothing is sent")
    }

    @Test func theHarnessDropsATasksRequestsWhenTheRouterEndsThatTask() {
        let harness = AgentHarness(workerBaseURL: "http://127.0.0.1:8787")
        _ = harness.taskRouter.register(taskID: firstTaskID)
        _ = harness.taskRouter.register(taskID: secondTaskID)
        harness.approvalDesk.receive(anApprovalRequest("approval-1"))
        harness.approvalDesk.receive(anApprovalRequest("approval-2", taskID: secondTaskID))
        // A request whose task the router does not run, such as one that crossed a cancel, never queues.
        harness.approvalDesk.receive(anApprovalRequest("approval-3", taskID: UUID()))

        harness.taskRouter.end(taskID: firstTaskID)

        #expect(harness.approvalDesk.waitingRequests.map(\.approvalID) == ["approval-2"])
    }

    @Test func theRouterReportsEachEndedTaskOnceAndIgnoresATaskItNeverHad() {
        let router = HarnessTaskRouter()
        var endedTaskIDs: [UUID] = []
        router.onTaskEnded = { endedTaskIDs.append($0) }
        _ = router.register(taskID: firstTaskID)
        _ = router.register(taskID: secondTaskID)

        router.end(taskID: firstTaskID)
        router.end(taskID: firstTaskID)
        router.end(taskID: UUID())
        router.failEveryTask(reason: "stopped")

        #expect(endedTaskIDs == [firstTaskID, secondTaskID])
    }

    #if DEBUG
    @Test func theDebugAnswerToolTakesAnIDAndAVerdictAndRefusesAGuessedScope() {
        #expect(DebugApprovalAnswer(arguments: ["approvalID": .string("approval-1"), "approved": .bool(true)])
            == DebugApprovalAnswer(arguments: ["approvalID": .string("approval-1"), "approved": .bool(true), "scope": .string("once")]))
        #expect(DebugApprovalAnswer(arguments: ["approvalID": .string("approval-1"), "approved": .bool(true), "scope": .string("always")])?.scope == .always)
        #expect(DebugApprovalAnswer(arguments: ["approvalID": .string("approval-1"), "approved": .bool(true), "scope": .string("forever")]) == nil)
        #expect(DebugApprovalAnswer(arguments: ["approvalID": .string("approval-1")]) == nil)
        #expect(DebugApprovalAnswer(arguments: ["approved": .bool(true)]) == nil)
        #expect(DebugApprovalAnswer(arguments: ["approvalID": .string("approval-1"), "approved": .string("yes")]) == nil)
    }
    #endif

    // MARK: - General tools

    @Test func openURLTakesOnlyAnHTTPSLinkWithAHost() {
        #expect(taskAgentOpenableURL(" https://example.com/page?q=1 ")?.absoluteString == "https://example.com/page?q=1")
        #expect(taskAgentOpenableURL("HTTPS://example.com") != nil)
        for refusedLink in ["http://example.com", "file:///etc/passwd", "x-apple.systempreferences:", "https://", "example.com", "", "https://example.com/" + String(repeating: "a", count: 2048)] {
            #expect(taskAgentOpenableURL(refusedLink) == nil, "\(refusedLink.prefix(60))")
        }
    }

    @Test func eachTaskKeepsItsScreenshotsInItsOwnFolderAndTheFolderGoesWhenTheTaskEnds() throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("clicky-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectoryURL) }

        let firstScreenshotURL = try TaskAgentWorkspace.nextScreenshotURL(taskID: firstTaskID, temporaryDirectoryURL: temporaryDirectoryURL)
        try Data("one".utf8).write(to: firstScreenshotURL)
        let secondScreenshotURL = try TaskAgentWorkspace.nextScreenshotURL(taskID: firstTaskID, temporaryDirectoryURL: temporaryDirectoryURL)
        let otherTaskScreenshotURL = try TaskAgentWorkspace.nextScreenshotURL(taskID: secondTaskID, temporaryDirectoryURL: temporaryDirectoryURL)

        #expect(firstScreenshotURL.lastPathComponent == "screenshot-1.jpg")
        #expect(secondScreenshotURL.lastPathComponent == "screenshot-2.jpg")
        #expect(otherTaskScreenshotURL.lastPathComponent == "screenshot-1.jpg")
        #expect(firstScreenshotURL.deletingLastPathComponent() != otherTaskScreenshotURL.deletingLastPathComponent())

        TaskAgentWorkspace.removeFolder(taskID: firstTaskID, temporaryDirectoryURL: temporaryDirectoryURL)
        #expect(!FileManager.default.fileExists(atPath: firstScreenshotURL.path))
        #expect(FileManager.default.fileExists(atPath: otherTaskScreenshotURL.deletingLastPathComponent().path))
    }

    @Test func theClipboardToolsMoveTextAndRefuseWhatTheyCannotDo() async {
        // A named pasteboard of its own, so the test never touches the learner's clipboard.
        let testPasteboard = NSPasteboard(name: NSPasteboard.Name("com.crodris.clicky-watch-along.test-\(UUID().uuidString)"))
        defer { testPasteboard.releaseGlobally() }

        let emptyRead = await runTaskAgentGeneralTool(named: "read_clipboard", input: [:], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(emptyRead.isError)

        let write = await runTaskAgentGeneralTool(named: "write_clipboard", input: ["text": .string("hello")], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(!write.isError)
        let read = await runTaskAgentGeneralTool(named: "read_clipboard", input: [:], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(read.content == .string("hello") && !read.isError)

        let longText = String(repeating: "a", count: longestTaskAgentClipboardText + 50)
        _ = await runTaskAgentGeneralTool(named: "write_clipboard", input: ["text": .string(longText)], taskID: firstTaskID, pasteboard: testPasteboard)
        let longRead = await runTaskAgentGeneralTool(named: "read_clipboard", input: [:], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(longRead.content.stringValue?.count == longestTaskAgentClipboardText)

        let emptyWrite = await runTaskAgentGeneralTool(named: "write_clipboard", input: ["text": .string("")], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(emptyWrite.isError)
        // A link that is not https never reaches NSWorkspace, and a tool this function does not run is an error.
        let refusedLink = await runTaskAgentGeneralTool(named: "open_url", input: ["url": .string("file:///etc/passwd")], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(refusedLink.isError)
        let notAGeneralTool = await runTaskAgentGeneralTool(named: "write_notion_page", input: [:], taskID: firstTaskID, pasteboard: testPasteboard)
        #expect(notAGeneralTool.isError)
    }

    // MARK: - Routing

    private func nextEvent(of taskEvents: AsyncStream<HarnessTaskEvent>) async -> HarnessTaskEvent? {
        var iterator = taskEvents.makeAsyncIterator()
        return await iterator.next()
    }

    // A stream that never ends would hang the run, so a broken router fails the test after a minute.
    @Test(.timeLimit(.minutes(1))) func aToolCallReachesOnlyTheTaskItBelongsTo() async {
        let router = HarnessTaskRouter()
        let firstTaskEvents = router.register(taskID: firstTaskID)
        let secondTaskEvents = router.register(taskID: secondTaskID)
        let toolCall = HarnessToolCall(toolUseID: "toolu_report", toolName: "report_step", input: ["step": .string("Searching")])

        router.route(.toolCall(taskID: secondTaskID, toolCall))
        router.route(.taskFinished(taskID: firstTaskID, spokenSummary: "First answer."))

        #expect(await nextEvent(of: secondTaskEvents) == .toolCall(toolCall))
        // The first task heard only its own end, with the second task's call nowhere in it.
        var firstTaskHeard: [HarnessTaskEvent] = []
        for await event in firstTaskEvents { firstTaskHeard.append(event) }
        #expect(firstTaskHeard == [.finished(spokenSummary: "First answer.")])
    }

    // A stream that never ends would hang the run, so a broken router fails the test after a minute.
    @Test(.timeLimit(.minutes(1))) func aFinishedOrFailedTaskEndsItsStreamAndForgetsLaterMessages() async {
        let router = HarnessTaskRouter()
        let taskEvents = router.register(taskID: firstTaskID)

        router.route(.taskFailed(taskID: firstTaskID, reason: "the agent used all 14 turns without finishing"))
        // A message that arrives after the end belongs to a task the router no longer has.
        router.route(.toolCall(taskID: firstTaskID, HarnessToolCall(toolUseID: "toolu_late", toolName: "report_step", input: [:])))

        var heardEvents: [HarnessTaskEvent] = []
        for await event in taskEvents { heardEvents.append(event) }
        #expect(heardEvents == [.failed(reason: "the agent used all 14 turns without finishing")])
        #expect(!router.hasATaskRunning)
    }

    // A stream that never ends would hang the run, so a broken router fails the test after a minute.
    @Test(.timeLimit(.minutes(1))) func endingATaskFinishesItsStreamWithNoEvent() async {
        let router = HarnessTaskRouter()
        let taskEvents = router.register(taskID: firstTaskID)

        router.end(taskID: firstTaskID)

        var heardEvents: [HarnessTaskEvent] = []
        for await event in taskEvents { heardEvents.append(event) }
        #expect(heardEvents.isEmpty)
        #expect(!router.hasATaskRunning)
    }

    // A stream that never ends would hang the run, so a broken router fails the test after a minute.
    @Test(.timeLimit(.minutes(1))) func aHarnessThatStopsFailsEveryTaskItHad() async {
        let router = HarnessTaskRouter()
        let firstTaskEvents = router.register(taskID: firstTaskID)
        let secondTaskEvents = router.register(taskID: secondTaskID)

        router.failEveryTask(reason: "The agent harness stopped with status 1")

        #expect(await nextEvent(of: firstTaskEvents) == .failed(reason: "The agent harness stopped with status 1"))
        #expect(await nextEvent(of: secondTaskEvents) == .failed(reason: "The agent harness stopped with status 1"))
        #expect(!router.hasATaskRunning)
    }
}
