package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// ---- The app's side of a voice command ----

// brainTestTools are the tools every test command offers, in the app's wire shape.
const brainTestTools = `[` +
	`{"name":"rotate_model","description":"Turns the model around its center.","inputSchema":{"properties":{"yawDegrees":{"type":"number"}},"required":["yawDegrees"],"type":"object"},"readOnly":false},` +
	`{"name":"zoom","description":"Zooms the camera.","inputSchema":{"properties":{"factor":{"type":"number"}},"required":["factor"],"type":"object"},"readOnly":false},` +
	`{"name":"find_moment","description":"Finds a moment in the captions.","inputSchema":{"properties":{"query":{"type":"string"}},"required":["query"],"type":"object"},"readOnly":true},` +
	`{"name":"seek_to_time","description":"Jumps the video to a time.","inputSchema":{"properties":{"seconds":{"type":"number"}},"required":["seconds"],"type":"object"},"readOnly":false},` +
	`{"name":"pop_out","description":"Pops the subject out of the frame.","inputSchema":{"properties":{},"required":[],"type":"object"},"readOnly":false}` +
	`]`

func voiceCommandLine(commandID string, transcript string) string {
	return fmt.Sprintf(`{"type":"voice_command","taskID":%q,"transcript":%q,"sceneState":{"page":"framePopout"},"tools":%s}`, commandID, transcript, brainTestTools)
}

// voiceToolResultLine is the app's answer to one call, with the result text the app writes for that outcome.
func voiceToolResultLine(commandID string, toolUseID string, outcome voiceToolOutcome, resultText string) string {
	return fmt.Sprintf(`{"type":"tool_result","taskID":%q,"toolUseID":%q,"content":%s,"isError":%t,"outcome":%q}`,
		commandID, toolUseID, mustMarshal(resultText), outcome == voiceToolFailed, outcome)
}

func cancelTaskLine(taskID string) string {
	return fmt.Sprintf(`{"type":"cancel_task","taskID":%q}`, taskID)
}

// ---- A fake Worker's answer to a brain turn, which is not streamed ----

func writeBrainReply(writer http.ResponseWriter, stopReason string, contentBlocksJSON ...string) {
	writer.Header().Set("Content-Type", "application/json")
	fmt.Fprintf(writer,
		`{"id":"msg_brain","type":"message","role":"assistant","model":"claude-haiku-5-5","content":[%s],"stop_reason":%q,"stop_sequence":null,"usage":{"input_tokens":900,"cache_read_input_tokens":800,"cache_creation_input_tokens":0,"output_tokens":20}}`,
		strings.Join(contentBlocksJSON, ","), stopReason)
}

func brainToolUse(id string, name string, inputJSON string) string {
	return fmt.Sprintf(`{"type":"tool_use","id":%q,"name":%q,"input":%s}`, id, name, inputJSON)
}

// requestIsTheBrains tells a brain turn from a task's, since both reach the same fake Worker.
func requestIsTheBrains(recorded recordedRequest) bool {
	return recorded.body["model"] == brainModel
}

// expectLineWithin is expectLine with a longer wait, for a test that waits out the brain's turn timeout.
func (driver *protocolDriver) expectLineWithin(expectedType string, timeout time.Duration) string {
	driver.t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case line, open := <-driver.lines:
			if !open {
				driver.t.Fatal("the harness closed its output")
			}
			switch actualType := messageType(line); {
			case actualType == expectedType:
				return line
			case actualType == "log":
				driver.logs = append(driver.logs, line)
			default:
				driver.t.Fatalf("expected a %s line, got %s", expectedType, line)
			}
		case <-deadline:
			driver.t.Fatalf("no %s line within %s", expectedType, timeout)
			return ""
		}
	}
}

// expectNoLineFor fails when the harness writes anything in this time.
func (driver *protocolDriver) expectNoLineFor(quiet time.Duration) {
	driver.t.Helper()
	select {
	case line := <-driver.lines:
		driver.t.Fatalf("expected no line, got %s", line)
	case <-time.After(quiet):
	}
}

// ---- The loop ----

func TestACommandRunsATwoCallTurnThenALookupAndItsActionAndSpeaksTheConfirmations(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeBrainReply(writer, "tool_use",
				`{"type":"text","text":"Sure."}`,
				brainToolUse("toolu_rotate", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it left"}`),
				brainToolUse("toolu_zoom", "zoom", `{"factor":1.3,"confirmation":"zoomed in"}`),
			)
		case 2:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_find", "find_moment", `{"query":"engine"}`))
		default:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_seek", "seek_to_time", `{"seconds":95,"confirmation":"jumped to the engine"}`))
		}
	})
	driver := startHarness(t, worker.server.URL)

	// A two-call turn: each call reaches the app in order, without the brain's confirmation, from turn 0.
	driver.send(voiceCommandLine("command-1", "turn it left and zoom in"))
	if got, want := driver.expectLine("tool_call"), `{"type":"tool_call","taskID":"command-1","toolUseID":"toolu_rotate","name":"rotate_model","input":{"yawDegrees":-45},"turnIndex":0}`; got != want {
		t.Fatalf("first call:\n got %s\nwant %s", got, want)
	}
	driver.send(voiceToolResultLine("command-1", "toolu_rotate", voiceToolChanged, `{"ok":true,"state":null}`))
	if got, want := driver.expectLine("tool_call"), `{"type":"tool_call","taskID":"command-1","toolUseID":"toolu_zoom","name":"zoom","input":{"factor":1.3},"turnIndex":0}`; got != want {
		t.Fatalf("second call:\n got %s\nwant %s", got, want)
	}
	driver.send(voiceToolResultLine("command-1", "toolu_zoom", voiceToolChanged, `{"ok":true,"state":null}`))
	if got, want := driver.expectLine("voice_command_finished"), `{"type":"voice_command_finished","taskID":"command-1","spokenLine":"turned it left zoomed in","gaveUp":false}`; got != want {
		t.Fatalf("finished:\n got %s\nwant %s", got, want)
	}
	if !driver.logsContain("Brain: turn 1 on claude-haiku-5-5 stopped for tool_use, tokens in 900, cache read 800, cache write 0, out 20, ") {
		t.Errorf("the turn's token line was missing: %v", driver.logs)
	}
	// The line ends with the names of the turn's calls in order, and no input.
	if !driver.logsContainLineEndingWith("Brain: turn 1 ", " ms, calls rotate_model,zoom") {
		t.Errorf("the first turn's line did not end with its call names: %v", driver.logs)
	}

	// A lookup goes back to the model, and the action it then takes comes from turn 1.
	driver.send(voiceCommandLine("command-2", "go to where they talk about the engine"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_find", voiceToolLookedUp, `{"ok":true,"result":[{"captions":"the engine","seconds":95}]}`))
	if got, want := driver.expectLine("tool_call"), `{"type":"tool_call","taskID":"command-2","toolUseID":"toolu_seek","name":"seek_to_time","input":{"seconds":95},"turnIndex":1}`; got != want {
		t.Fatalf("the second turn's call:\n got %s\nwant %s", got, want)
	}
	driver.send(voiceToolResultLine("command-2", "toolu_seek", voiceToolChanged, `{"ok":true,"state":null}`))
	if got := driver.expectLine("voice_command_finished"); !strings.Contains(got, `"spokenLine":"jumped to the engine"`) {
		t.Fatalf("finished: %s", got)
	}

	requests := worker.requests()
	if len(requests) != 3 {
		t.Fatalf("the Worker got %d requests, want 3", len(requests))
	}
	first := requests[0].body
	if requests[0].path != "/v1/messages" || first["stream"] != nil {
		t.Errorf("a brain turn went to %s with stream %v, want an unstreamed /v1/messages", requests[0].path, first["stream"])
	}
	wantMessage := `<scene_state>{"page":"framePopout"}</scene_state>` + "\n" + `Learner said: "turn it left and zoom in"`
	if got := firstUserText(t, first); got != wantMessage {
		t.Errorf("the user message:\n got %q\nwant %q", got, wantMessage)
	}
	// The lookup's turn sends the first command, the second command's words joined to its last tool results, the lookup
	// call unchanged, then the app's result text.
	lookupMessages := jsonValueAt(t, requests[2].body, "messages").([]any)
	if len(lookupMessages) != 5 {
		t.Fatalf("the lookup's next turn carried %d messages, want 5", len(lookupMessages))
	}
	if jsonValueAt(t, lookupMessages[3], "content", 0, "input", "query") != "engine" {
		t.Errorf("the lookup call sent back was %v", lookupMessages[3])
	}
	lookupResult := jsonValueAt(t, lookupMessages[4], "content", 0)
	if jsonValueAt(t, lookupResult, "tool_use_id") != "toolu_find" || jsonValueAt(t, lookupResult, "content", 0, "text") != `{"ok":true,"result":[{"captions":"the engine","seconds":95}]}` {
		t.Errorf("the lookup result sent back was %v", lookupResult)
	}
}

func TestACallToAToolTheCommandDidNotOfferNeverReachesTheApp(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_close", "close_scene", `{"confirmation":"closed it"}`))
			return
		}
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"I can't close it from here."}`)
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(voiceCommandLine("command-1", "close it"))

	// The refusal goes back to the model, which says what went wrong, and the app hears only the end.
	if got, want := driver.expectLine("voice_command_finished"), `{"type":"voice_command_finished","taskID":"command-1","spokenLine":"I can't close it from here.","gaveUp":false}`; got != want {
		t.Fatalf("finished:\n got %s\nwant %s", got, want)
	}
	requests := worker.requests()
	if len(requests) != 2 {
		t.Fatalf("the Worker got %d requests, want 2", len(requests))
	}
	refusal := jsonValueAt(t, requests[1].body, "messages", 2, "content", 0)
	if jsonValueAt(t, refusal, "is_error") != true || jsonValueAt(t, refusal, "content", 0, "text") != `{"error":"close_scene is not available right now","ok":false,"state":null}` {
		t.Errorf("the refusal sent to the model was %v", refusal)
	}
}

// The app never sees a call after a hand-off or a call to a tool the command did not offer, so the turn's log line is
// the only place a benchmark can read what the model chose. A turn with no call says "none", and the line holds no input.
func TestATurnLogNamesEveryCallEvenOnesTheAppNeverSees(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_pop", "pop_out", `{"confirmation":"popped it"}`),
				brainToolUse("toolu_close", "close_scene", `{"confirmation":"closed it"}`),
				brainToolUse("toolu_rotate", "rotate_model", `{"yawDegrees":45,"confirmation":"secret words"}`),
			)
			return
		}
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"It is a shark."}`)
	})
	driver := startHarness(t, worker.server.URL)

	// pop_out hands off, so close_scene (not offered) and rotate_model (after the hand-off) never reach the app.
	driver.send(voiceCommandLine("command-1", "pop it out and close it and turn it"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_pop", voiceToolHandedOff, `{"ok":true}`))
	driver.expectLine("voice_command_finished")
	if !driver.logsContainLineEndingWith("Brain: turn 1 ", " ms, calls pop_out,close_scene,rotate_model") {
		t.Errorf("the line did not name all three calls: %v", driver.logs)
	}
	for _, logLine := range driver.logs {
		if strings.Contains(logLine, "secret words") || strings.Contains(logLine, "yawDegrees") {
			t.Errorf("a log line held a call's input: %s", logLine)
		}
	}

	// A turn with no call says none.
	driver.send(voiceCommandLine("command-2", "what is this"))
	driver.expectLine("voice_command_finished")
	if !driver.logsContainLineEndingWith("Brain: turn 1 ", " ms, calls none") {
		t.Errorf("a turn with no call did not say none: %v", driver.logs)
	}
}

func TestACommandThatStillNeedsTheModelAfterThreeTurnsGivesUp(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		writeBrainReply(writer, "tool_use", brainToolUse(fmt.Sprintf("toolu_seek_%d", requestNumber), "seek_to_time", `{"seconds":-5,"confirmation":"there"}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(voiceCommandLine("command-1", "go back to the start"))
	for turnIndex := 0; turnIndex < 3; turnIndex++ {
		driver.expectLine("tool_call")
		driver.send(voiceToolResultLine("command-1", fmt.Sprintf("toolu_seek_%d", turnIndex+1), voiceToolFailed, `{"error":"seconds must not be negative","ok":false,"state":null}`))
	}
	if got, want := driver.expectLine("voice_command_finished"), `{"type":"voice_command_finished","taskID":"command-1","spokenLine":"","gaveUp":true}`; got != want {
		t.Fatalf("finished:\n got %s\nwant %s", got, want)
	}
	if len(worker.requests()) != 3 {
		t.Errorf("the Worker got %d requests, want 3", len(worker.requests()))
	}
}

// A turn that hangs or fails starts the app's router failure fallback within 8 seconds of its request, with no retry.
func TestATurnThatGetsNoReplyFailsTheCommandWithinEightSecondsAfterOneRequest(t *testing.T) {
	worker := newFakeWorker(t, func(_ http.ResponseWriter, request *http.Request, _ recordedRequest, _ int) {
		<-request.Context().Done()
	})
	driver := startHarness(t, worker.server.URL)
	sentAt := time.Now()
	driver.send(voiceCommandLine("command-1", "turn it left"))

	failedLine := driver.expectLineWithin("task_failed", 10*time.Second)
	elapsed := time.Since(sentAt)
	if elapsed < 7500*time.Millisecond || elapsed > 9*time.Second {
		t.Errorf("the command failed after %s, want about 8 s", elapsed)
	}
	if !strings.Contains(failedLine, "turn 1 got no reply from Claude within 8s") {
		t.Errorf("the failure was %s", failedLine)
	}
	if len(worker.requests()) != 1 {
		t.Errorf("the Worker got %d requests, want 1", len(worker.requests()))
	}
}

func TestATurnThatFailsIsNotRetried(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writer.Header().Set("Content-Type", "application/json")
		writer.WriteHeader(529)
		fmt.Fprint(writer, `{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}`)
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(voiceCommandLine("command-1", "turn it left"))

	if failedLine := driver.expectLine("task_failed"); !strings.Contains(failedLine, `"taskID":"command-1"`) {
		t.Errorf("the failure was %s", failedLine)
	}
	if len(worker.requests()) != 1 {
		t.Errorf("the Worker got %d requests, want 1, since the SDK would retry a 529 twice", len(worker.requests()))
	}
}

func TestACancelDuringATurnEndsTheRequestLogsItAndSendsNothingMore(t *testing.T) {
	requestArrived := make(chan struct{}, 1)
	requestEnded := make(chan struct{}, 1)
	worker := newFakeWorker(t, func(_ http.ResponseWriter, request *http.Request, _ recordedRequest, _ int) {
		requestArrived <- struct{}{}
		<-request.Context().Done()
		requestEnded <- struct{}{}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(voiceCommandLine("command-1", "skip to the engine"))
	select {
	case <-requestArrived:
	case <-time.After(testTimeout):
		t.Fatal("the turn's request never reached the Worker")
	}

	driver.send(cancelTaskLine("command-1"))

	if got := driver.expectLine("log"); !strings.Contains(got, "Brain: command cancelled during turn 1") {
		t.Fatalf("the log line was %s", got)
	}
	select {
	case <-requestEnded:
	case <-time.After(testTimeout):
		t.Fatal("the cancel did not end the request to the Worker")
	}
	driver.expectNoLineFor(300 * time.Millisecond)
}

// The app sends a hand-off's result from the cancel handler of the command it cancelled, so a cancel_task can follow it
// at once. The command still ends as handed off, every time.
func TestAHandedOffResultThenACancelEndTheCommandAsHandedOff(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		writeBrainReply(writer, "tool_use", brainToolUse(fmt.Sprintf("toolu_pop_%d", requestNumber), "pop_out", `{"confirmation":""}`))
	})
	driver := startHarness(t, worker.server.URL)
	for run := 1; run <= 100; run++ {
		commandID := fmt.Sprintf("command-%d", run)
		driver.send(voiceCommandLine(commandID, "pop this out"))
		driver.expectLine("tool_call")
		// One write, so the harness reads the two lines back to back.
		driver.send(voiceToolResultLine(commandID, fmt.Sprintf("toolu_pop_%d", run), voiceToolHandedOff, `{"ok":true}`) + "\n" + cancelTaskLine(commandID))
		want := fmt.Sprintf(`{"type":"voice_command_finished","taskID":%q,"spokenLine":"","gaveUp":false}`, commandID)
		if got := driver.expectLine("voice_command_finished"); got != want {
			t.Fatalf("run %d ended with %s, want %s", run, got, want)
		}
	}
	if driver.logsContain("Brain: command cancelled") {
		t.Error("a handed-off command was cancelled")
	}
}

// Commands and tasks share one stdin reader and one app write queue, so a task waiting on a slow MCP server, with a
// large tool result on its way to it, must not hold up a command.
func TestACommandGetsItsFirstCallWhileATaskWaitsOnTheMCPServersAndAResultIsInFlight(t *testing.T) {
	const mcpServerStartDelay = 1500 * time.Millisecond
	directory := t.TempDir()
	config := map[string]any{"mcpServers": map[string]any{"slow": map[string]any{
		"command": os.Args[0],
		"env": map[string]string{
			"CLICKY_TEST_MCP_SERVER":         "1",
			"CLICKY_TEST_MCP_LOG":            filepath.Join(directory, "ran.log"),
			"CLICKY_TEST_MCP_START_DELAY_MS": fmt.Sprint(mcpServerStartDelay.Milliseconds()),
		},
	}}}
	configPath := filepath.Join(directory, "mcp.json")
	if err := os.WriteFile(configPath, mustMarshal(config), 0o644); err != nil {
		t.Fatal(err)
	}
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		if requestIsTheBrains(recorded) {
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_rotate", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it left"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, appSecret: "test-secret", mcpConfigPath: configPath, lookupEnvironment: noEnvironment})
	startedAt := time.Now()
	driver.send(startTaskLine("task-1", "read my note"))
	// A screenshot-sized result for the task, which it cannot read yet, since it is still connecting.
	largeResultText := strings.Repeat("x", 4_000_000)
	driver.send(toolResultLine("task-1", "toolu_screenshot", string(mustMarshal(largeResultText)), false))
	driver.send(voiceCommandLine("command-1", "turn it left"))

	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"taskID":"command-1"`) {
		t.Fatalf("the first call was %s", got)
	}
	if elapsed := time.Since(startedAt); elapsed >= mcpServerStartDelay {
		t.Errorf("the command's first call came after %s, once the MCP server had started", elapsed)
	}
	for _, request := range worker.requests() {
		if !requestIsTheBrains(request) {
			t.Error("the task reached the Worker before its MCP server started, so the test proved nothing")
		}
	}
	driver.send(voiceToolResultLine("command-1", "toolu_rotate", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.expectLine("voice_command_finished")
	driver.expectLine("task_finished")
}

func TestANewCommandCancelsTheOneStillRunning(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		transcript := firstUserText(t, recorded.body)
		toolUseID := "toolu_first"
		if strings.Contains(transcript, "zoom in") {
			toolUseID = "toolu_second"
		}
		writeBrainReply(writer, "tool_use", brainToolUse(toolUseID, "zoom", `{"factor":1.3,"confirmation":"zoomed"}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(voiceCommandLine("command-1", "zoom out"))
	driver.expectLine("tool_call")

	// The first command waits on its call's result when the second arrives.
	driver.send(voiceCommandLine("command-2", "zoom in"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"taskID":"command-2"`) {
		t.Fatalf("the next call was %s", got)
	}
	if !driver.logsContain("Brain: command cancelled during turn 1") {
		t.Errorf("the first command was not cancelled: %v", driver.logs)
	}
	// The first command's late result changes nothing.
	driver.send(voiceToolResultLine("command-1", "toolu_first", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.send(voiceToolResultLine("command-2", "toolu_second", voiceToolChanged, `{"ok":true,"state":null}`))
	if got := driver.expectLine("voice_command_finished"); !strings.Contains(got, `"taskID":"command-2"`) {
		t.Fatalf("finished: %s", got)
	}
}

func TestAMalformedVoiceCommandFailsAtOnceAndAMalformedTaskLineIsDropped(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		t.Error("a malformed command must not reach the Worker")
	})
	driver := startHarness(t, worker.server.URL)

	// A refused line of a task is dropped as before, since a task_failed would end a task the line never reached.
	driver.send(`{"type":"tool_result","taskID":"task-running"}`)
	driver.expectNoLineFor(200 * time.Millisecond)

	// No tools: the app waits on this command's events, so the harness answers for its ID instead of dropping the line.
	driver.send(`{"type":"voice_command","taskID":"command-malformed","transcript":"turn it left","tools":[]}`)
	if got, want := driver.expectLine("task_failed"), `{"type":"task_failed","taskID":"command-malformed","reason":"voice_command needs a taskID, a transcript, and at least one tool"}`; got != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}
