package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
)

// ---- A session with a clock the test moves ----

type testClock struct{ current time.Time }

func (clock *testClock) now() time.Time { return clock.current }

func newTestSession() (*brainSession, *testClock) {
	clock := &testClock{current: time.Date(2026, 11, 20, 9, 0, 0, 0, time.UTC)}
	return newBrainSession(clock.now), clock
}

// commitACommand runs a whole command against the session with no model: the learner's words, one rotate_model call
// with its result, and a request in between so the cache counts as warm.
func commitACommand(session *brainSession, transcript string, resultText string) {
	run := session.begin(transcript, json.RawMessage(`{"page":"framePopout"}`))
	session.noteRequest(session.now())
	callID := "toolu_" + strings.ReplaceAll(transcript, " ", "_")
	run.own = append(run.own,
		anthropic.NewAssistantMessage(anthropic.NewToolUseBlock(callID, map[string]any{"yawDegrees": 45}, "rotate_model")),
		anthropic.NewUserMessage(anthropic.NewToolResultBlock(callID, resultText, false)),
	)
	run.actionLines = append(run.actionLines, `rotate_model {"yawDegrees":45} -> ok`)
	run.commit()
}

// whatTheSessionHolds is the history a command that began now would read, as JSON, before that command's own words. A
// command that is never committed leaves no trace, so reading the session this way changes nothing a test checks.
func whatTheSessionHolds(t *testing.T, session *brainSession) string {
	t.Helper()
	run := session.begin("probe", json.RawMessage(`{}`))
	return string(mustMarshal(run.history))
}

func countOf(text string, part string) int { return strings.Count(text, part) }

// ---- Rollback ----

func TestARolledBackCommandLeavesTheSessionAsItWasAndItsFinishedCallsGoIntoTheNextUserMessage(t *testing.T) {
	session, _ := newTestSession()
	commitACommand(session, "turn it left", `{"ok":true,"state":null}`)
	before := whatTheSessionHolds(t, session)

	run := session.begin("zoom in and turn it up", json.RawMessage(`{"page":"framePopout"}`))
	run.own = append(run.own,
		anthropic.NewAssistantMessage(anthropic.NewToolUseBlock("toolu_zoom", map[string]any{"factor": 1.3}, "zoom")),
	)
	run.actionLines = append(run.actionLines, `zoom {"factor":1.3} -> ok`)
	run.abandon()

	if after := whatTheSessionHolds(t, session); after != before {
		t.Errorf("the rolled back command changed the session:\n before %s\n after  %s", before, after)
	}
	next := session.begin("no, the other way", json.RawMessage(`{"page":"framePopout"}`))
	nextText := next.own[0].Content[0].OfText.Text
	if !strings.Contains(nextText, "<interrupted_before>zoom {\"factor\":1.3} -> ok</interrupted_before>\n") {
		t.Errorf("the next command's message did not carry the interrupted action line: %s", nextText)
	}
	// Everything before the new command's own text is what the session held before the cancelled command.
	if requestText := string(mustMarshal(next.requestMessages())); strings.Contains(requestText, "toolu_zoom") || strings.Contains(requestText, "zoom in and turn it up") {
		t.Errorf("the cancelled command's messages are still in the session: %s", requestText)
	}
}

func TestInterruptedLinesPileUpAcrossCancelsAndClearOnceACommandStays(t *testing.T) {
	session, _ := newTestSession()
	for _, line := range []string{"rotate_model {} -> ok", "zoom {} -> ok"} {
		run := session.begin("a", json.RawMessage(`{}`))
		run.actionLines = []string{line}
		run.abandon()
	}
	staying := session.begin("c", json.RawMessage(`{}`))
	if text := staying.own[0].Content[0].OfText.Text; !strings.Contains(text, "<interrupted_before>rotate_model {} -> ok; zoom {} -> ok</interrupted_before>\n") {
		t.Fatalf("the two cancelled commands' lines were not both carried: %s", text)
	}
	staying.commit()

	if text := session.begin("d", json.RawMessage(`{}`)).own[0].Content[0].OfText.Text; strings.Contains(text, "interrupted_before") {
		t.Errorf("a command that stayed did not clear the interrupted lines: %s", text)
	}
}

func TestACommandThatWasBeingCancelledAgainKeepsTheLinesItCarried(t *testing.T) {
	session, _ := newTestSession()
	first := session.begin("a", json.RawMessage(`{}`))
	first.actionLines = []string{"rotate_model {} -> ok"}
	first.abandon()

	second := session.begin("b", json.RawMessage(`{}`))
	second.actionLines = []string{"zoom {} -> ok"}
	second.abandon()

	if text := session.begin("c", json.RawMessage(`{}`)).own[0].Content[0].OfText.Text; !strings.Contains(text, "<interrupted_before>rotate_model {} -> ok; zoom {} -> ok</interrupted_before>\n") {
		t.Errorf("the lines were not kept in order: %s", text)
	}
}

// ---- The fold ----

func commitCommands(session *brainSession, count int) {
	for commandNumber := 1; commandNumber <= count; commandNumber++ {
		commitACommand(session, fmt.Sprintf("command %d", commandNumber), `{"ok":true,"state":null}`)
	}
}

func TestAColdCacheFoldsEveryCommandButTheNewestSixIntoOneTextBlockWithNoSceneStates(t *testing.T) {
	session, clock := newTestSession()
	commitCommands(session, 8)
	clock.current = clock.current.Add(cacheLifetime)

	messages := session.begin("next", json.RawMessage(`{}`)).requestMessages()
	requestText := string(mustMarshal(messages))

	// Commands 1 and 2 are folded: their words and action lines are in the first block, and their own messages are gone.
	foldBlock := messages[0].Content[0].OfText.Text
	if !strings.HasPrefix(foldBlock, "<"+earlierCommandsTag+">") {
		t.Fatalf("the first block is not the fold block: %s", foldBlock)
	}
	for _, folded := range []string{`<learner_words>command 1</learner_words>`, `<learner_words>command 2</learner_words>`, `rotate_model {"yawDegrees":45} -> ok`} {
		if !strings.Contains(foldBlock, folded) {
			t.Errorf("the fold block lacks %q: %s", folded, foldBlock)
		}
	}
	if strings.Contains(foldBlock, "scene_state") || strings.Contains(foldBlock, "framePopout") {
		t.Errorf("the fold block kept a scene state: %s", foldBlock)
	}
	if strings.Contains(requestText, "toolu_command_1") || strings.Contains(requestText, "toolu_command_2") {
		t.Errorf("a folded command's messages are still in the request")
	}
	// Commands 3 to 8 stay whole, each with its scene state.
	for commandNumber := 3; commandNumber <= 8; commandNumber++ {
		if !strings.Contains(requestText, fmt.Sprintf(`learner_words\u003ecommand %d\u003c/learner_words`, commandNumber)) || !strings.Contains(requestText, fmt.Sprintf("toolu_command_%d", commandNumber)) {
			t.Errorf("command %d was folded, and the newest six stay whole", commandNumber)
		}
	}
	if got := countOf(requestText, `\u003cscene_state\u003e`); got != 7 {
		t.Errorf("the request holds %d scene states, want 6 kept whole and the new command's", got)
	}
}

func TestAFoldWaitsForAColdCacheOrMoreThanTwentyFourCommands(t *testing.T) {
	tests := []struct {
		name         string
		commands     int
		cacheAge     time.Duration
		wantFolded   bool
		wantWholeRun int
	}{
		{"a warm cache with 24 commands", 24, cacheLifetime - time.Second, false, 24},
		{"a warm cache with 25 commands", 25, cacheLifetime - time.Second, true, 6},
		{"a cold cache with 7 commands", 7, cacheLifetime, true, 6},
		{"a cold cache with 6 commands has nothing old enough to fold", 6, cacheLifetime, false, 6},
		{"a cache one second short of cold", 7, cacheLifetime - time.Second, false, 7},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			session, clock := newTestSession()
			commitCommands(session, test.commands)
			clock.current = clock.current.Add(test.cacheAge)

			messages := session.begin("next", json.RawMessage(`{}`)).requestMessages()

			isFolded := strings.HasPrefix(messages[0].Content[0].OfText.Text, "<"+earlierCommandsTag+">")
			if isFolded != test.wantFolded {
				t.Errorf("folded was %v, want %v", isFolded, test.wantFolded)
			}
			if got := countOf(string(mustMarshal(messages)), "toolu_command_"); got != test.wantWholeRun*2 {
				t.Errorf("the request carries %d call and result blocks of kept commands, want %d", got, test.wantWholeRun*2)
			}
		})
	}
}

func TestAfterAFoldTheNextFoldWaitsUntilTheSessionAgainHoldsMoreThanTwentyFourCommands(t *testing.T) {
	session, _ := newTestSession()
	commitCommands(session, 25)
	session.begin("fold now", json.RawMessage(`{}`))
	if len(session.commands) != commandsKeptWholeInAFold || len(session.foldedCommands) != 19 {
		t.Fatalf("the fold left %d whole and %d folded commands, want 6 and 19", len(session.commands), len(session.foldedCommands))
	}
	commitCommands(session, 18)
	session.begin("still no fold", json.RawMessage(`{}`))
	if len(session.foldedCommands) != 19 {
		t.Errorf("the folded count changed to %d with only 24 whole commands", len(session.foldedCommands))
	}
}

// ---- The cache breakpoint ----

func cacheControlBlocks(t *testing.T, messages []anthropic.MessageParam) []string {
	t.Helper()
	var marked []string
	var decoded []map[string]any
	if err := json.Unmarshal(mustMarshal(messages), &decoded); err != nil {
		t.Fatal(err)
	}
	for messageIndex, message := range decoded {
		for blockIndex, block := range message["content"].([]any) {
			if _, hasBreakpoint := block.(map[string]any)["cache_control"]; hasBreakpoint {
				marked = append(marked, fmt.Sprintf("%d.%d", messageIndex, blockIndex))
			}
		}
	}
	return marked
}

func TestTheBreakpointSitsOnTheLastBlockOfThePreviousCommandAndNotOnTheNewOne(t *testing.T) {
	session, _ := newTestSession()
	commitCommands(session, 2)

	messages := session.begin("next", json.RawMessage(`{}`)).requestMessages()

	// Two commands of three messages each: the second ends with its tool result, which the new command's words join.
	if got := cacheControlBlocks(t, messages); len(got) != 1 || got[0] != "5.0" {
		t.Errorf("the breakpoints are on %v, want only the previous command's tool_result at 5.0", got)
	}
	if len(messages) != 6 || len(messages[5].Content) != 2 {
		t.Fatalf("the new command's words should join the last user message: %d messages, %d blocks", len(messages), len(messages[len(messages)-1].Content))
	}
	if messages[5].Content[0].OfToolResult == nil || messages[5].Content[1].OfText == nil {
		t.Error("the tool result must come first in the joined message")
	}
}

func TestTheBreakpointSitsOnAnAssistantTextBlockWhenThePreviousCommandEndedInWords(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("what is this", json.RawMessage(`{}`))
	run.own = append(run.own, anthropic.NewAssistantMessage(anthropic.NewTextBlock("It is a shark.")))
	run.commit()

	messages := session.begin("next", json.RawMessage(`{}`)).requestMessages()

	if got := cacheControlBlocks(t, messages); len(got) != 1 || got[0] != "1.0" {
		t.Errorf("the breakpoints are on %v, want the assistant's text at 1.0", got)
	}
	if len(messages) != 3 || messages[2].Role != anthropic.MessageParamRoleUser {
		t.Errorf("the new command should be its own user message after the assistant's words")
	}
}

func TestAnEmptySessionHasNoMessageBreakpoint(t *testing.T) {
	session, _ := newTestSession()
	messages := session.begin("first", json.RawMessage(`{}`)).requestMessages()
	if got := cacheControlBlocks(t, messages); len(got) != 0 {
		t.Errorf("an empty session's request has message breakpoints at %v", got)
	}
}

func TestTheSessionKeepsNoBreakpointInItsOwnMessages(t *testing.T) {
	session, _ := newTestSession()
	commitCommands(session, 2)
	session.begin("next", json.RawMessage(`{}`)).requestMessages()

	var stored []anthropic.MessageParam
	for _, command := range session.commands {
		stored = append(stored, command.messages...)
	}
	if got := cacheControlBlocks(t, stored); len(got) != 0 {
		t.Errorf("a request's breakpoint leaked into the session at %v", got)
	}
}

// ---- The cut ----

func TestAToolResultInTheHistoryIsCutToTwoThousandCharacters(t *testing.T) {
	session, _ := newTestSession()
	longResult := strings.Repeat("é", 5000)
	commitACommand(session, "find the engine", longResult)

	history := session.begin("next", json.RawMessage(`{}`)).requestMessages()

	resultText := history[2].Content[0].OfToolResult.Content[0].OfText.Text
	if got := len([]rune(resultText)); got != 2000 {
		t.Errorf("the kept result has %d characters, want %d", got, 2000)
	}
	if !strings.HasSuffix(resultText, cutMarker) {
		t.Errorf("the cut result does not say it was cut: ...%s", resultText[len(resultText)-20:])
	}
}

func TestAToolResultWithinTheLimitIsKeptWhole(t *testing.T) {
	session, _ := newTestSession()
	exactResult := strings.Repeat("x", 2000)
	commitACommand(session, "find the engine", exactResult)

	history := session.begin("next", json.RawMessage(`{}`)).requestMessages()

	if got := history[2].Content[0].OfToolResult.Content[0].OfText.Text; got != exactResult {
		t.Errorf("a result of exactly %d characters was changed to %d characters", 2000, len([]rune(got)))
	}
}

// ---- Reset and seed ----

func TestResetEmptiesTheSessionAndAnOldCommandNeverWritesBackIntoTheNewOne(t *testing.T) {
	session, _ := newTestSession()
	commitCommands(session, 3)
	running := session.begin("still running", json.RawMessage(`{}`))
	session.reset()

	if got := whatTheSessionHolds(t, session); countOf(got, "command ") != 0 {
		t.Errorf("a reset session still holds commands: %s", got)
	}
	running.commit()
	if len(session.commands) != 0 {
		t.Errorf("a command that began before the reset wrote %d commands into the new session", len(session.commands))
	}
}

func TestSeedingReplacesTheSessionAndDerivesTheWordsAndActionsAFoldWritesDown(t *testing.T) {
	session, _ := newTestSession()
	var seeded []anthropic.MessageParam
	for commandNumber := 1; commandNumber <= 25; commandNumber++ {
		callID := fmt.Sprintf("toolu_seed_%d", commandNumber)
		seeded = append(seeded,
			anthropic.NewUserMessage(anthropic.NewTextBlock(brainUserMessageText(fmt.Sprintf("seed %d", commandNumber), json.RawMessage(`{"page":"framePopout"}`), nil))),
			anthropic.NewAssistantMessage(anthropic.NewToolUseBlock(callID, map[string]any{"yawDegrees": 45, "confirmation": "turned it"}, "rotate_model")),
			anthropic.NewUserMessage(anthropic.NewToolResultBlock(callID, `{"ok":true,"state":null}`, false)),
		)
	}
	commitACommand(session, "something old", `{"ok":true,"state":null}`)
	if err := session.seed(seeded, []string{"zoom {} -> ok"}); err != nil {
		t.Fatal(err)
	}

	run := session.begin("next", json.RawMessage(`{}`))
	messages := run.requestMessages()

	// 25 whole commands is past the cap, so the seeded session folds on its first command, and the old one is gone.
	foldBlock := messages[0].Content[0].OfText.Text
	if strings.Contains(string(mustMarshal(messages)), "something old") {
		t.Error("seeding did not replace the earlier session")
	}
	for _, folded := range []string{`<learner_words>seed 1</learner_words>`, `rotate_model {"yawDegrees":45} -> ok`, `<learner_words>seed 19</learner_words>`} {
		if !strings.Contains(foldBlock, folded) {
			t.Errorf("the fold block lacks %q: %s", folded, foldBlock)
		}
	}
	if strings.Contains(foldBlock, `<learner_words>seed 20</learner_words>`) {
		t.Error("the newest six commands were folded")
	}
	if text := run.own[0].Content[0].OfText.Text; !strings.Contains(text, "<interrupted_before>zoom {} -> ok</interrupted_before>") {
		t.Errorf("the seeded interrupted line did not reach the next command: %s", text)
	}
}

func TestSeedingMessagesThatDoNotStartWithTheLearnerIsAnError(t *testing.T) {
	session, _ := newTestSession()
	err := session.seed([]anthropic.MessageParam{anthropic.NewAssistantMessage(anthropic.NewTextBlock("hi"))}, nil)
	if err == nil {
		t.Error("a seed that starts with the assistant was accepted")
	}
}

// ---- A command that ends with no words ----

func TestAReplyWithNoContentLeavesNoEmptyAssistantMessageInTheSession(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("hello", json.RawMessage(`{}`))
	run.addReply(newTurn(anthropic.Message{Content: []anthropic.ContentBlockUnion{{Type: "text", Text: " "}}}))
	run.commit()

	messages := session.begin("next", json.RawMessage(`{}`)).requestMessages()
	if len(messages) != 1 || messages[0].Role != anthropic.MessageParamRoleUser {
		t.Errorf("the request holds %d messages, want one user message holding both commands' words", len(messages))
	}
}

// ---- Through the whole harness ----

func lastUserBlocks(t *testing.T, requestBody map[string]any) []any {
	t.Helper()
	messages := jsonValueAt(t, requestBody, "messages").([]any)
	return jsonValueAt(t, messages[len(messages)-1], "content").([]any)
}

func lastUserText(t *testing.T, requestBody map[string]any) string {
	t.Helper()
	blocks := lastUserBlocks(t, requestBody)
	return jsonValueAt(t, blocks[len(blocks)-1], "text").(string)
}

// everyToolUseHasItsResult is the rule the API enforces: each tool_use is answered by a tool_result in the next message.
func everyToolUseHasItsResult(t *testing.T, requestBody map[string]any) {
	t.Helper()
	messages := jsonValueAt(t, requestBody, "messages").([]any)
	for messageIndex, message := range messages {
		if jsonValueAt(t, message, "role") != "assistant" {
			continue
		}
		for _, block := range jsonValueAt(t, message, "content").([]any) {
			if jsonValueAt(t, block, "type") != "tool_use" {
				continue
			}
			toolUseID := jsonValueAt(t, block, "id")
			answered := false
			if messageIndex+1 < len(messages) {
				for _, nextBlock := range jsonValueAt(t, messages[messageIndex+1], "content").([]any) {
					if jsonValueAt(t, nextBlock, "type") == "tool_result" && jsonValueAt(t, nextBlock, "tool_use_id") == toolUseID {
						answered = true
					}
				}
			}
			if !answered {
				t.Errorf("tool_use %v in message %d has no tool_result in the next message", toolUseID, messageIndex)
			}
		}
	}
}

func TestASecondCommandSeesTheFirstAndTheRequestKeepsEveryToolUseAnswered(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		writeBrainReply(writer, "tool_use", brainToolUse(fmt.Sprintf("toolu_rotate_%d", requestNumber), "rotate_model", `{"yawDegrees":45,"confirmation":"turned it"}`))
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(voiceCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_rotate_1", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.expectLine("voice_command_finished")
	driver.send(voiceCommandLine("command-2", "no, the other way"))
	driver.expectLine("tool_call")

	secondRequest := worker.requests()[1].body
	messages := jsonValueAt(t, secondRequest, "messages").([]any)
	if len(messages) != 3 {
		t.Fatalf("the second command's request holds %d messages, want the first command's three joined with its own words", len(messages))
	}
	if got := firstUserText(t, secondRequest); !strings.Contains(got, `<learner_words>turn it left</learner_words>`) {
		t.Errorf("the first command's words are missing: %s", got)
	}
	if got := lastUserText(t, secondRequest); !strings.Contains(got, `<learner_words>no, the other way</learner_words>`) {
		t.Errorf("the second command's words are missing: %s", got)
	}
	everyToolUseHasItsResult(t, secondRequest)
	if strings.Contains(string(mustMarshal(secondRequest)), "recent_actions") {
		t.Error("a request still carries recent_actions")
	}
	// Three breakpoints: the system prompt, the last tool, and the first command's last block.
	if got := countOf(string(mustMarshal(secondRequest)), `"cache_control"`); got != 3 {
		t.Errorf("the request carries %d cache breakpoints, want 3", got)
	}
	jsonResult := jsonValueAt(t, messages[2], "content", 0)
	if jsonValueAt(t, jsonResult, "cache_control", "type") != "ephemeral" {
		t.Errorf("the breakpoint is not on the first command's tool result: %v", jsonResult)
	}
}

func TestACallAfterAHandOffGetsANotRunResultAndTheNextCommandStillHasEveryToolResult(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_pop", "pop_out", `{"confirmation":""}`),
				brainToolUse("toolu_rotate", "rotate_model", `{"yawDegrees":45,"confirmation":"turned it"}`),
				brainToolUse("toolu_zoom", "zoom", `{"factor":1.3,"confirmation":"zoomed"}`),
			)
			return
		}
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"It is a shark."}`)
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(voiceCommandLine("command-1", "pop it out and turn it"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_pop", voiceToolHandedOff, `{"ok":true}`))
	driver.expectLine("voice_command_finished")
	driver.send(voiceCommandLine("command-2", "what is this"))
	driver.expectLine("voice_command_finished")

	secondRequest := worker.requests()[1].body
	everyToolUseHasItsResult(t, secondRequest)
	results := jsonValueAt(t, secondRequest, "messages", 2, "content").([]any)
	wantResults := []string{handedOffResultText, notRunResultText, notRunResultText}
	if len(results) != 4 {
		t.Fatalf("the user message after the hand-off holds %d blocks, want three results and the new words", len(results))
	}
	for resultIndex, wantText := range wantResults {
		if got := jsonValueAt(t, results[resultIndex], "content", 0, "text"); got != wantText {
			t.Errorf("result %d was %v, want %q", resultIndex, got, wantText)
		}
	}
}

func TestACancelledCommandLeavesTheSessionAsItWasAndTheNextCommandHearsWhatItDid(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, requestNumber int) {
		switch {
		case strings.Contains(lastUserText(t, recorded.body), "turn it left"):
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_left", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it"}`))
		case strings.Contains(lastUserText(t, recorded.body), "turn and zoom"):
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":90,"confirmation":"turned it"}`),
				brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed"}`),
			)
		default:
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"Done."}`)
		}
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(voiceCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_left", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.expectLine("voice_command_finished")

	// The second command's first call finishes, and the press cancels it while the second call waits.
	driver.send(voiceCommandLine("command-2", "turn and zoom"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_turn", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.expectLine("tool_call")
	driver.send(cancelTaskLine("command-2"))
	driver.expectLine("log")

	driver.send(voiceCommandLine("command-3", "no, the other way"))
	driver.expectLine("voice_command_finished")

	thirdRequest := worker.requests()[len(worker.requests())-1].body
	requestText := string(mustMarshal(thirdRequest))
	if strings.Contains(requestText, "toolu_turn") || strings.Contains(requestText, "toolu_zoom") || strings.Contains(requestText, "turn and zoom") {
		t.Errorf("the cancelled command's messages are in the next request: %s", requestText)
	}
	if got := lastUserText(t, thirdRequest); !strings.Contains(got, `<interrupted_before>rotate_model {"yawDegrees":90} -> ok</interrupted_before>`+"\n"+`<learner_words>no, the other way</learner_words>`) {
		t.Errorf("the next message did not say what the cancelled command had done: %s", got)
	}
	if strings.Contains(lastUserText(t, thirdRequest), "zoom {") {
		t.Errorf("the call still waiting at the cancel was reported as done")
	}
	everyToolUseHasItsResult(t, thirdRequest)
}

// A new command cancels the one running and waits for it to roll back, so it never reads a session the old command is
// about to change. Repeated, since a command that read too early only does so some of the time.
func TestANewCommandWaitsForTheCommandItCancelledToRollBackBeforeItReadsTheSession(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		if strings.Contains(lastUserText(t, recorded.body), "turn and zoom") {
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":90,"confirmation":"turned it"}`),
				brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed"}`),
			)
			return
		}
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Done."}`)
	})
	driver := startHarness(t, worker.server.URL)

	for run := 1; run <= 40; run++ {
		interruptedID := fmt.Sprintf("interrupted-%d", run)
		driver.send(voiceCommandLine(interruptedID, "turn and zoom"))
		driver.expectLine("tool_call")
		toolUseID := "toolu_turn"
		driver.send(voiceToolResultLine(interruptedID, toolUseID, voiceToolChanged, `{"ok":true,"state":null}`))
		driver.expectLine("tool_call")
		// The next command arrives while the second call waits, so it cancels the first.
		followingID := fmt.Sprintf("following-%d", run)
		driver.send(voiceCommandLine(followingID, "no, the other way"))
		driver.expectLine("voice_command_finished")

		requests := worker.requests()
		if got := lastUserText(t, requests[len(requests)-1].body); !strings.Contains(got, `<interrupted_before>rotate_model {"yawDegrees":90} -> ok</interrupted_before>`) {
			t.Fatalf("run %d: the following command read the session before the cancelled one rolled back: %s", run, got)
		}
	}
}

func TestAHarnessWithoutTheBenchSwitchIgnoresResetAndSeed(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Done."}`)
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(voiceCommandLine("command-1", "show the shark"))
	driver.expectLine("voice_command_finished")
	driver.send(`{"type":"reset_session"}`)
	driver.send(`{"type":"seed_session","messages":[{"role":"user","content":[{"type":"text","text":"<learner_words>seeded</learner_words>"}]}]}`)
	driver.send(voiceCommandLine("command-2", "and this"))
	driver.expectLine("voice_command_finished")

	secondRequest := worker.requests()[1].body
	requestText := string(mustMarshal(secondRequest))
	if !strings.Contains(requestText, "show the shark") {
		t.Errorf("reset_session emptied the session of a harness with no CLICKY_BENCH: %s", requestText)
	}
	if strings.Contains(requestText, "seeded") {
		t.Errorf("seed_session replaced the session of a harness with no CLICKY_BENCH: %s", requestText)
	}
}

func TestAHarnessStartedForTheBenchTakesResetAndSeed(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Done."}`)
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, appSecret: "test-secret", benchMode: true})

	driver.send(voiceCommandLine("command-1", "show the shark"))
	driver.expectLine("voice_command_finished")
	driver.send(`{"type":"reset_session"}`)
	driver.send(voiceCommandLine("command-2", "and this"))
	driver.expectLine("voice_command_finished")
	if requestText := string(mustMarshal(worker.requests()[1].body)); strings.Contains(requestText, "show the shark") {
		t.Errorf("reset_session left the first command in the session: %s", requestText)
	}

	seededMessages := `[{"role":"user","content":[{"type":"text","text":"<scene_state>{}</scene_state>\n<learner_words>turn it left</learner_words>"}]},` +
		`{"role":"assistant","content":[{"type":"tool_use","id":"toolu_seed","name":"rotate_model","input":{"yawDegrees":-45}}]},` +
		`{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_seed","content":[{"type":"text","text":"{\"ok\":true}"}],"is_error":false}]}]`
	driver.send(`{"type":"seed_session","interruptedBefore":["zoom {} -> ok"],"messages":` + seededMessages + `}`)
	driver.send(voiceCommandLine("command-3", "no, the other way"))
	driver.expectLine("voice_command_finished")

	thirdRequest := worker.requests()[2].body
	if requestText := string(mustMarshal(thirdRequest)); strings.Contains(requestText, "and this") || !strings.Contains(requestText, "toolu_seed") {
		t.Errorf("seed_session did not replace the session: %s", requestText)
	}
	if got := lastUserText(t, thirdRequest); !strings.Contains(got, "<interrupted_before>zoom {} -> ok</interrupted_before>") {
		t.Errorf("the seeded interrupted line did not reach the command: %s", got)
	}
	everyToolUseHasItsResult(t, thirdRequest)
}

func TestTheBenchSwitchComesOnlyFromTheEnvironmentValueOne(t *testing.T) {
	for value, want := range map[string]bool{"1": true, "": false, "0": false, "true": false} {
		harnessConfiguration, err := loadConfiguration(func(name string) string {
			switch name {
			case "CLICKY_WORKER_BASE_URL":
				return "http://127.0.0.1:1"
			case "CLICKY_BENCH":
				return value
			}
			return ""
		})
		if err != nil {
			t.Fatal(err)
		}
		if harnessConfiguration.benchMode != want {
			t.Errorf("CLICKY_BENCH=%q gave benchMode %v, want %v", value, harnessConfiguration.benchMode, want)
		}
	}
}
