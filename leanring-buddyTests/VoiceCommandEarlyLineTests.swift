//
//  VoiceCommandEarlyLineTests.swift
//  leanring-buddyTests
//
//  The line a voice command's turn would speak if every call changes the screen, which the harness sends ahead of the
//  turn's calls so its audio is fetched while they run: the line parsed at the boundary, the event reaching the app
//  before the calls run, and the rule that plays the early audio only for a finished line with exactly its words.
//

import Foundation
import Testing
@testable import Clicky

@MainActor
struct VoiceCommandEarlyLineTests {
    private let commandID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!

    @Test func theEarlyLineIsParsedAndReachesItsCommandsStream() async throws {
        let line = #"{"type":"voice_line_if_every_call_changes","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenLine":"turned it left","toolNames":["rotate_model"]}"#
        #expect(try HarnessMessage(line: line) == .voiceLineIfEveryCallChanges(taskID: commandID, spokenLine: "turned it left", toolNames: ["rotate_model"]))
        // A line without its tool names, or with a name that is not text, is refused too.
        #expect(throws: HarnessMessage.ParseError.self) {
            try HarnessMessage(line: #"{"type":"voice_line_if_every_call_changes","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenLine":"turned it left"}"#)
        }
        #expect(throws: HarnessMessage.ParseError.self) {
            try HarnessMessage(line: #"{"type":"voice_line_if_every_call_changes","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","spokenLine":"turned it left","toolNames":[4]}"#)
        }
        // A line with no words is refused at the boundary, like any line that lacks a field.
        #expect(throws: HarnessMessage.ParseError.self) {
            try HarnessMessage(line: #"{"type":"voice_line_if_every_call_changes","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F"}"#)
        }

        let taskRouter = HarnessTaskRouter()
        let commandEvents = taskRouter.register(taskID: commandID)
        taskRouter.route(try HarnessMessage(line: line))
        taskRouter.end(taskID: commandID)
        var receivedEvents: [HarnessTaskEvent] = []
        for await commandEvent in commandEvents { receivedEvents.append(commandEvent) }
        #expect(receivedEvents == [.spokenLineIfEveryCallChanges(spokenLine: "turned it left", toolNames: ["rotate_model"])])
    }

    @Test func theEarlyLineReachesTheAppBeforeTheCallsRun() async {
        let (commandEvents, eventContinuation) = AsyncStream<HarnessTaskEvent>.makeStream()
        eventContinuation.yield(.spokenLineIfEveryCallChanges(spokenLine: "turned it left", toolNames: ["rotate_model"]))
        eventContinuation.yield(.toolCall(HarnessToolCall(toolUseID: "toolu_rotate", toolName: "rotate_model", input: ["yawDegrees": .number(-45)], turnIndex: 0)))
        eventContinuation.yield(.voiceCommandFinished(spokenLine: "turned it left", gaveUp: false))
        let commandLines = HarnessVoiceCommandLines(taskID: commandID, sendLine: { _ in })

        var whatHappened: [String] = []
        let commandEnding = await runTheVoiceCommandEvents(
            commandEvents,
            lines: commandLines,
            approvalWhenTheCommandStarted: nil,
            whenNoEventArrivesInTime: {},
            whenTheLineIfEveryCallChangesArrives: { spokenLine, toolNames in whatHappened.append("fetch \(spokenLine) for \(toolNames.joined(separator: ","))") },
            runTool: { toolCall, _ in
                whatHappened.append("run \(toolCall.name)")
                return .changed(state: nil)
            }
        )

        #expect(commandEnding == .finished(spokenLine: "turned it left", gaveUp: false))
        #expect(whatHappened == ["fetch turned it left for rotate_model", "run rotate_model"])
    }

    @Test func theEarlyAudioPlaysOnlyForAFinishedLineWithExactlyItsWords() {
        // Every call changed the screen, so the harness finished with the early line's words.
        #expect(voiceCommandLineAudio(lineToSpeak: "turned it left", earlyLineFetched: "turned it left") == .theAudioFetchedEarly)
        // A lookup or a failure sent the model back, and its next turn said something else.
        #expect(voiceCommandLineAudio(lineToSpeak: "that part has no label", earlyLineFetched: "turned it left") == .aFetchStartedNow)
        // Even a change in punctuation or case fetches the finished line, so Clicky never says words the harness did not end with.
        #expect(voiceCommandLineAudio(lineToSpeak: "Turned it left.", earlyLineFetched: "turned it left") == .aFetchStartedNow)
        // A turn whose calls had no confirmation sent no early line.
        #expect(voiceCommandLineAudio(lineToSpeak: "turned it left", earlyLineFetched: nil) == .aFetchStartedNow)
    }

    @Test func aTurnThatHandsOffOrLooksSomethingUpFetchesNoEarlyLine() {
        let lookups: Set<String> = ["find_moment"]
        #expect(earlyLineIsWorthFetching(turnToolNames: ["rotate_model", "zoom"], lookupToolNames: lookups))
        #expect(earlyLineIsWorthFetching(turnToolNames: ["undo_last_change"], lookupToolNames: lookups))
        // These lines never play, so each fetch would only bill ElevenLabs.
        for handOffToolName in ["pop_out", "build_new_scene", "answer_with_screen", "animate_picture", "show_art_in_my_room", "close_scene", "build_simulation"] {
            #expect(!earlyLineIsWorthFetching(turnToolNames: ["rotate_model", handOffToolName], lookupToolNames: lookups), "\(handOffToolName)")
        }
        #expect(!earlyLineIsWorthFetching(turnToolNames: ["find_moment", "seek_to_time"], lookupToolNames: lookups))
        // A page's own read-only tool is a lookup too.
        #expect(!earlyLineIsWorthFetching(turnToolNames: ["describe_part"], lookupToolNames: ["describe_part"]))
    }

    @Test func theToolsThatMayHandOffAreTheOnesWhoseStepHandsOff() {
        let handOffTools = Set(AppVoiceTool.allCases.filter(\.mayHandOff).map(\.rawValue))
        #expect(handOffTools == [
            "answer_with_screen", "build_new_scene", "build_simulation", "pop_out", "animate_picture", "show_art_in_my_room", "close_scene",
            "explain_part", "end_quiz", "show_ready_model", "hear_task_answer", "design_theme",
        ])
    }

    @Test func theEarlyLineAndTheFinishedLineAreCutTheSameWay() {
        // The harness sends both lines whole, so a long line fetched early is the same cut line the finished one speaks.
        let longHarnessLine = String(repeating: "👍🏽", count: 400)
        let earlyLine = voiceCommandLineToSpeak(longHarnessLine)
        #expect(earlyLine.count == longestSpokenVoiceCommandLine)
        #expect(voiceCommandLineAudio(lineToSpeak: voiceCommandLineToSpeak(longHarnessLine), earlyLineFetched: earlyLine) == .theAudioFetchedEarly)
    }

    @Test func theTimingLineSaysWhereTheFinishedLinesAudioCameFrom() {
        let released = Date(timeIntervalSinceReferenceDate: 1000)
        var timing = VoiceCommandTiming(pushToTalkReleasedAt: released, transcriptReadyAt: released.addingTimeInterval(0.7))
        timing.lineAudio = .theAudioFetchedEarly
        #expect(timing.logLine.contains(" line_audio=fetched_early "))
        timing.lineAudio = .aFetchStartedNow
        #expect(timing.logLine.contains(" line_audio=fetched_now "))
    }
}
