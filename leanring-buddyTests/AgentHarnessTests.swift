//
//  AgentHarnessTests.swift
//  leanring-buddyTests
//
//  The messages between the app and the Go agent harness. The lines below are the ones harness/loop_test.go asserts
//  the harness writes, so the two sides agree on the wire format. The loop's own rules are tested in Go.
//

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
        let startWithATab = HarnessCommand.startTask(taskID: firstTaskID, goal: "compare the catches", frontTabTitle: "SpaceX catch", frontTabURL: "https://www.youtube.com/watch?v=abc")
        #expect(try decodedJSON(of: startWithATab.line) == .object([
            "type": .string("start_task"),
            "taskID": .string("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"),
            "goal": .string("compare the catches"),
            "frontTabTitle": .string("SpaceX catch"),
            "frontTabURL": .string("https://www.youtube.com/watch?v=abc"),
        ]))

        let startWithNoTab = HarnessCommand.startTask(taskID: firstTaskID, goal: "compare", frontTabTitle: nil, frontTabURL: nil)
        #expect(try decodedJSON(of: startWithNoTab.line)["frontTabTitle"] == .null)
        #expect(try decodedJSON(of: startWithNoTab.line)["frontTabURL"] == .null)

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
