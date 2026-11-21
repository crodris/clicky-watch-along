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
        #expect(desk.oldestWaitingRequest?.approvalID == "approval-2", "an answer moves on to the next request")
        #expect(desk.answer(approvalID: "approval-2", approved: false, scope: .once))
        #expect(answers.map(\.approvalID) == ["approval-1", "approval-2"])
        #expect(answers.map(\.approved) == [true, false])
        #expect(answers.map(\.scope) == [.always, .once])
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

    @Test(.timeLimit(.minutes(1))) func aRequestNoOneAnswersIsDeclinedAfterTheTimeoutAndAnAnsweredOneIsNot() async {
        var answers: [(approvalID: String, approved: Bool)] = []
        let desk = HarnessApprovalDesk(timeoutSeconds: 0.2) { approvalID, approved, _ in answers.append((approvalID, approved)) }

        desk.receive(anApprovalRequest("approval-1"))
        desk.receive(anApprovalRequest("approval-2"))
        #expect(answers.isEmpty, "a request waits before the timeout")
        #expect(desk.answer(approvalID: "approval-1", approved: true, scope: .always))

        // A loaded runner can start the timeout task late, so wait until the request is declined, with a deadline far past the
        // timeout, instead of sleeping for a guessed time.
        let deadline = Date().addingTimeInterval(10)
        while !desk.waitingRequests.isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(answers.map(\.approvalID) == ["approval-1", "approval-2"])
        #expect(answers.map(\.approved) == [true, false], "the learner's answer stands and the unanswered request is declined")
        #expect(desk.waitingRequests.isEmpty)
        #expect(HarnessApprovalDesk.defaultTimeoutSeconds == 120)
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

    @Test func anAnswerCountsOnlyOnceTheCardHasShownTheWholeSummaryForASecond() {
        var now = Date(timeIntervalSince1970: 1_000)
        var answeredIDs: [String] = []
        let desk = HarnessApprovalDesk(currentDate: { now }) { approvalID, _, _ in answeredIDs.append(approvalID) }
        desk.listIsShowing = { true }

        desk.receive(anApprovalRequest("approval-1"))
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now + 60) == nil, "no card has shown it yet")

        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1")
        now += 0.5
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now) == nil, "a summary on screen for an instant is one nobody read")
        #expect(!desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once), "a click meant for the page must not land on Yes")

        // A click closes the list before the second is up, so a later press finds nothing it may answer.
        desk.theCardHasNotShownTheWholeSummary()
        now += 5
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now) == nil)

        // The list opens again and the card shows all of it for a second, so the press and the click both count.
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-1")
        now += 1.1
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now) == "approval-1")
        #expect(desk.answerByClick(approvalID: "approval-1", approved: true, scope: .once))
        #expect(answeredIDs == ["approval-1"])
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
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-B")
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now + 60) == nil)
        desk.theCardShowedTheWholeSummary(ofApprovalID: "approval-A")
        now += 2
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now) == "approval-A")

        // A ends while the list is closed. B becomes the oldest with no card showing it, so the list is asked to open,
        // and nothing can answer B until its own card has shown it for a second.
        listIsOpen = false
        desk.dropRequests(forTaskID: firstTaskID)
        #expect(requestsThatNeededShowing == ["approval-B"])
        now += 5
        #expect(desk.oldestRequestIDTheLearnerHasSeen(at: now) == nil)
        #expect(!desk.answerByClick(approvalID: "approval-B", approved: true, scope: .once))
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
