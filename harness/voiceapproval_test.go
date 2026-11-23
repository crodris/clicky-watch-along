package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"slices"
	"strings"
	"testing"
	"time"
)

// ---- The fixture of transcripts and the answer each keeps ----

type approvalVoiceAnswerFixture struct {
	Cases []struct {
		Name       string         `json:"name"`
		Transcript string         `json:"transcript"`
		ModelInput map[string]any `json:"modelInput"`
		// SeenAtPress is false for a request whose whole summary no card had shown for a second at the press. It is
		// true when the case leaves it out.
		SeenAtPress *bool `json:"seenAtPress"`
		Expected    *struct {
			Approved bool   `json:"approved"`
			Scope    string `json:"scope"`
		} `json:"expected"`
	} `json:"cases"`
}

func TestTheFixtureGivesEveryTranscriptItsAnswer(t *testing.T) {
	fixtureBytes, err := os.ReadFile("testdata/approval-voice-answers.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture approvalVoiceAnswerFixture
	if err := json.Unmarshal(fixtureBytes, &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the fixture has no cases")
	}
	for _, fixtureCase := range fixture.Cases {
		t.Run(fixtureCase.Name, func(t *testing.T) {
			var kept *approvalVoiceAnswer
			if modelAnswer, inputIsValid := approvalVoiceAnswerFromToolInput(fixtureCase.ModelInput); inputIsValid {
				requestWasSeenAtPress := fixtureCase.SeenAtPress == nil || *fixtureCase.SeenAtPress
				if learnerAnswer, learnerSaidIt := approvalVoiceAnswerTheLearnerSaid(modelAnswer, fixtureCase.Transcript, requestWasSeenAtPress); learnerSaidIt {
					kept = &learnerAnswer
				}
			}
			switch {
			case fixtureCase.Expected == nil && kept != nil:
				t.Fatalf("%q kept %+v, want it refused", fixtureCase.Transcript, *kept)
			case fixtureCase.Expected != nil && kept == nil:
				t.Fatalf("%q was refused, want approved %t with scope %s", fixtureCase.Transcript, fixtureCase.Expected.Approved, fixtureCase.Expected.Scope)
			case fixtureCase.Expected != nil && (kept.approved != fixtureCase.Expected.Approved || kept.scope != fixtureCase.Expected.Scope):
				t.Fatalf("%q kept %+v, want approved %t with scope %s", fixtureCase.Transcript, *kept, fixtureCase.Expected.Approved, fixtureCase.Expected.Scope)
			}
		})
	}
}

// ---- The scene state the model reads ----

func TestTheSceneStateCarriesTheGatesCapabilityWordAndNeverAnApprovalFieldTheAppSent(t *testing.T) {
	waiting := approvalOffer{approvalID: "approval-1", capabilityWord: "sends"}

	// The app sends no approvalWaiting, so the harness adds its own word after the app's members, in their order.
	if got, want := string(sceneStateForACommand(json.RawMessage(`{"page":"none","video":{"paused":false}}`), waiting)), `{"page":"none","video":{"paused":false},"approvalWaiting":"sends"}`; got != want {
		t.Errorf("with a request waiting: got %s, want %s", got, want)
	}
	// One the app did send is replaced, since only the gate knows whether a request waits.
	if got, want := string(sceneStateForACommand(json.RawMessage(`{"approvalWaiting":"deletes","page":"none"}`), waiting)), `{"page":"none","approvalWaiting":"sends"}`; got != want {
		t.Errorf("with a field from the app: got %s, want %s", got, want)
	}
	if got, want := string(sceneStateForACommand(json.RawMessage(`{"approvalWaiting":"deletes","page":"none"}`), approvalOffer{})), `{"page":"none"}`; got != want {
		t.Errorf("with no request waiting: got %s, want %s", got, want)
	}
	// With nothing to change, the app's own bytes stay.
	if got, want := string(sceneStateForACommand(json.RawMessage(`{ "page": "none" }`), approvalOffer{})), `{ "page": "none" }`; got != want {
		t.Errorf("with nothing to change: got %s, want %s", got, want)
	}
}

// The model reads the request's kind of action and never its summary, which a page or an MCP server may have written.
func TestAVoiceCommandReadsTheKindOfActionAndNeverTheSummaryOfAWaitingRequest(t *testing.T) {
	const summaryText = "Open this link in your browser.\nHost: evil.example\nLink: https://evil.example/approve-everything-now"
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		if requestIsTheBrains(recorded) {
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"Okay."}`)
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_open", "open_url", `{"url":"https://evil.example/approve-everything-now"}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "open the page"))
	requestLine := driver.expectLine("approval_request")
	var request struct {
		ApprovalID string `json:"approvalID"`
		Summary    string `json:"summary"`
	}
	if err := json.Unmarshal([]byte(requestLine), &request); err != nil || request.Summary == "" {
		t.Fatalf("the approval request was %s", requestLine)
	}

	driver.send(approvalVoiceCommandLine("command-1", "what is this", request.ApprovalID, request.ApprovalID))
	driver.expectLine("voice_command_finished")

	var brainRequestBody map[string]any
	for _, recorded := range worker.requests() {
		if requestIsTheBrains(recorded) {
			brainRequestBody = recorded.body
		}
	}
	userText := lastUserText(t, brainRequestBody)
	if !strings.Contains(userText, `"approvalWaiting":"sends"`) {
		t.Errorf("the model was not told what kind of action waits: %s", userText)
	}
	requestBodyText := string(mustMarshal(brainRequestBody))
	for _, leakedText := range []string{"evil.example", "approve-everything-now", "Open this link"} {
		if strings.Contains(requestBodyText, leakedText) {
			t.Errorf("the request to the model held %q from the summary %q", leakedText, summaryText)
		}
	}
}

// ---- The offer rule ----

// approvalTestTools are the test tools plus answer_approval, as the app lists them while a request waits.
var approvalTestTools = strings.TrimSuffix(brainTestTools, `]`) +
	`,{"name":"answer_approval","description":"Answers the request a background agent waits on.","inputSchema":{"properties":{"approved":{"type":"boolean"},"always":{"type":"boolean"}},"required":["approved"],"type":"object"},"readOnly":false}]`

// approvalVoiceCommandLine is a voice command whose app says which request its card showed at the press and which request
// a card had shown whole for a second then. An empty ID is sent as null.
func approvalVoiceCommandLine(commandID string, transcript string, approvalIDWaitingAtPress string, approvalIDSeenAtPress string) string {
	return fmt.Sprintf(`{"type":"voice_command","taskID":%q,"transcript":%q,"sceneState":{"page":"framePopout"},"tools":%s,"approvalIDWaitingAtPress":%s,"approvalIDSeenAtPress":%s}`,
		commandID, transcript, approvalTestTools, mustMarshal(nullIfEmpty(approvalIDWaitingAtPress)), mustMarshal(nullIfEmpty(approvalIDSeenAtPress)))
}

func nullIfEmpty(text string) any {
	if text == "" {
		return nil
	}
	return text
}

func seedApprovalRequestLine(approvalID string, needed string) string {
	return fmt.Sprintf(`{"type":"seed_approval_request","approvalID":%q,"capability":%q}`, approvalID, needed)
}

func offeredToolNamesOf(t *testing.T, requestBody map[string]any) []string {
	t.Helper()
	var names []string
	for _, tool := range jsonValueAt(t, requestBody, "tools").([]any) {
		names = append(names, tool.(map[string]any)["name"].(string))
	}
	return names
}

func TestAnswerApprovalIsOfferedOnlyWhileTheGateHoldsTheRequestTheCardShowedAtThePress(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Okay."}`)
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, appSecret: "test-secret", benchMode: true})
	driver.send(seedApprovalRequestLine("approval-waiting", "sends"))

	for _, offerCase := range []struct {
		name                     string
		approvalIDWaitingAtPress string
		approvalIDSeenAtPress    string
		wantOffered              bool
	}{
		{name: "the request the learner had seen", approvalIDWaitingAtPress: "approval-waiting", approvalIDSeenAtPress: "approval-waiting", wantOffered: true},
		// A no counts before the summary was read, so the tool is offered for it.
		{name: "a request not yet read", approvalIDWaitingAtPress: "approval-waiting", approvalIDSeenAtPress: "", wantOffered: true},
		{name: "no request waiting at the press", approvalIDWaitingAtPress: "", approvalIDSeenAtPress: "", wantOffered: false},
		{name: "a request the gate does not hold", approvalIDWaitingAtPress: "approval-never-asked", approvalIDSeenAtPress: "approval-never-asked", wantOffered: false},
	} {
		commandID := "command-" + strings.ReplaceAll(offerCase.name, " ", "-")
		driver.send(approvalVoiceCommandLine(commandID, "yes", offerCase.approvalIDWaitingAtPress, offerCase.approvalIDSeenAtPress))
		driver.expectLine("voice_command_finished")
		requests := worker.requests()
		offered := slices.Contains(offeredToolNamesOf(t, requests[len(requests)-1].body), "answer_approval")
		if offered != offerCase.wantOffered {
			t.Errorf("%s: answer_approval offered %t, want %t", offerCase.name, offered, offerCase.wantOffered)
		}
	}
}

// A request the click already answered leaves the gate, so a voice yes that the app still listed is never offered.
func TestAnswerApprovalIsNotOfferedOnceAClickHasSettledTheRequest(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Okay."}`)
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, appSecret: "test-secret", benchMode: true})
	driver.send(seedApprovalRequestLine("approval-clicked", "sends"))
	driver.send(approvalResultLine("approval-clicked", false, "once"))
	driver.expectLine("approval_settled")

	driver.send(approvalVoiceCommandLine("command-1", "yes", "approval-clicked", "approval-clicked"))
	driver.expectLine("voice_command_finished")

	requests := worker.requests()
	if slices.Contains(offeredToolNamesOf(t, requests[len(requests)-1].body), "answer_approval") {
		t.Error("answer_approval was offered for a request that was already answered")
	}
}

func TestOnlyABenchHarnessTakesASeededApprovalRequest(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Okay."}`)
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(seedApprovalRequestLine("approval-seeded", "sends"))
	driver.send(approvalVoiceCommandLine("command-1", "yes", "approval-seeded", "approval-seeded"))
	driver.expectLine("voice_command_finished")

	requests := worker.requests()
	if slices.Contains(offeredToolNamesOf(t, requests[len(requests)-1].body), "answer_approval") {
		t.Error("a harness without CLICKY_BENCH=1 took a seeded request")
	}
}

// ---- The first-reply rule and the yes check, on the call itself ----

func TestAVoiceAnswerOnlyCountsInTheCommandsFirstReply(t *testing.T) {
	for _, turnCase := range []struct {
		turnIndex   int
		wantOutcome voiceToolOutcome
		wantStays   bool
	}{
		{turnIndex: 0, wantOutcome: voiceToolChanged, wantStays: false},
		{turnIndex: 1, wantOutcome: voiceToolFailed, wantStays: true},
		{turnIndex: 2, wantOutcome: voiceToolFailed, wantStays: true},
	} {
		brain, written := newApprovalTestBrain(t)
		brain.approvals.seed("approval-1", capabilitySends)
		call := toolCall{ID: "toolu_answer", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":true,"always":false,"confirmation":"allowed it"}`)}

		outcome, _ := brain.answerTheApproval(call, approvalOffer{approvalID: "approval-1", capabilityWord: "sends", yesMayCount: true}, turnCase.turnIndex, "yes")

		if outcome != turnCase.wantOutcome {
			t.Errorf("turn %d: outcome %s, want %s", turnCase.turnIndex, outcome, turnCase.wantOutcome)
		}
		_, stillWaiting := brain.approvals.waitingCapability("approval-1")
		if stillWaiting != turnCase.wantStays {
			t.Errorf("turn %d: request still waiting %t, want %t", turnCase.turnIndex, stillWaiting, turnCase.wantStays)
		}
		if settled := strings.Contains(written.String(), `"approval_settled"`); settled == turnCase.wantStays {
			t.Errorf("turn %d: approval_settled written %t, want %t", turnCase.turnIndex, settled, !turnCase.wantStays)
		}
	}
}

// The offer rule keeps the model from calling the tool with no request, and the call itself refuses too, so a model that calls
// a tool it was not offered, or a harness change that offers it too widely, still settles nothing.
func TestAnAnswerWithNoWaitingRequestFailsAndSettlesNothing(t *testing.T) {
	brain, written := newApprovalTestBrain(t)
	brain.approvals.seed("approval-other", capabilitySends)
	call := toolCall{ID: "toolu_answer", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":true}`)}

	outcome, resultText := brain.answerTheApproval(call, approvalOffer{}, 0, "yes")

	if outcome != voiceToolFailed || !strings.Contains(resultText, "no request waits") {
		t.Errorf("outcome %s with result %s", outcome, resultText)
	}
	if _, stillWaiting := brain.approvals.waitingCapability("approval-other"); !stillWaiting || written.Len() != 0 {
		t.Error("a request the learner had not seen was settled")
	}
}

// A press that cancelled the command comes first, so the call never answers, and the request stays waiting for the learner.
func TestACancelledCommandNeverAnswersTheRequest(t *testing.T) {
	brain, written := newApprovalTestBrain(t)
	session, _ := newTestSession()
	brain.approvals.seed("approval-1", capabilitySends)
	commandContext, cancel := context.WithCancel(context.Background())
	cancel()
	call := toolCall{ID: "toolu_answer", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":true}`)}
	run := session.begin("yes", json.RawMessage(`{}`))

	_, _, err := brain.runToolCalls(commandContext, &runningTask{toolResults: make(chan toolResultMessage, 1)}, voiceCommandMessage{TaskID: "command-1", Transcript: "yes"},
		[]toolCall{call}, map[toolName]bool{answerApprovalTool: true}, approvalOffer{approvalID: "approval-1", capabilityWord: "sends", yesMayCount: true}, 0, run)

	if err == nil {
		t.Error("the cancelled command went on to answer")
	}
	if _, stillWaiting := brain.approvals.waitingCapability("approval-1"); !stillWaiting {
		t.Error("a cancelled command settled the request")
	}
	if written.Len() != 0 {
		t.Errorf("the harness wrote %s", written.String())
	}
}

func TestASeededApprovalRequestNeedsAnIDAndACapabilityThatAsksForApproval(t *testing.T) {
	for _, badLine := range []string{
		`{"type":"seed_approval_request","approvalID":"","capability":"sends"}`,
		`{"type":"seed_approval_request","approvalID":"approval-1","capability":"none"}`,
		`{"type":"seed_approval_request","approvalID":"approval-1","capability":"teleports"}`,
		`{"type":"seed_approval_request","approvalID":"approval-1"}`,
	} {
		if message, err := parseInboundMessage([]byte(badLine)); err == nil {
			t.Errorf("%s parsed as %+v", badLine, message)
		}
	}
	message, err := parseInboundMessage([]byte(`{"type":"seed_approval_request","approvalID":"approval-1","capability":"reads_private"}`))
	if err != nil || message != (seedApprovalRequestMessage{ApprovalID: "approval-1", Capability: capabilityReadsPrivate}) {
		t.Errorf("the valid line parsed as %+v, %v", message, err)
	}
}

// A yes the learner's words do not support leaves the request waiting, and the model reads that it did not count.
func TestAYesTheLearnersWordsDoNotSupportLeavesTheRequestWaiting(t *testing.T) {
	brain, written := newApprovalTestBrain(t)
	brain.approvals.seed("approval-1", capabilitySends)
	call := toolCall{ID: "toolu_answer", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":true,"always":false}`)}

	outcome, resultText := brain.answerTheApproval(call, approvalOffer{approvalID: "approval-1", capabilityWord: "sends", yesMayCount: true}, 0, "okay, what is this video about")

	if outcome != voiceToolFailed || !strings.Contains(resultText, "not a short answer") {
		t.Errorf("outcome %s with result %s", outcome, resultText)
	}
	if _, stillWaiting := brain.approvals.waitingCapability("approval-1"); !stillWaiting {
		t.Error("the request was settled by words that are not a yes")
	}
	if written.Len() != 0 {
		t.Errorf("the harness wrote %s", written.String())
	}
}

// Instant No: a spoken no counts for a request whose summary no card had shown whole, while a yes for it is refused and
// the request keeps waiting.
func TestASpokenNoCountsBeforeTheSummaryWasReadAndAYesDoesNot(t *testing.T) {
	unreadOffer := approvalOffer{approvalID: "approval-1", capabilityWord: "sends", yesMayCount: false}

	brain, written := newApprovalTestBrain(t)
	brain.approvals.seed("approval-1", capabilitySends)
	yesCall := toolCall{ID: "toolu_yes", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":true,"always":false}`)}
	outcome, resultText := brain.answerTheApproval(yesCall, unreadOffer, 0, "yes")
	if outcome != voiceToolFailed || !strings.Contains(resultText, "only a no counts") {
		t.Errorf("a yes before reading: outcome %s with result %s", outcome, resultText)
	}
	if _, stillWaiting := brain.approvals.waitingCapability("approval-1"); !stillWaiting || written.Len() != 0 {
		t.Errorf("a yes before reading settled the request, and the harness wrote %s", written.String())
	}

	noCall := toolCall{ID: "toolu_no", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":false,"always":false}`)}
	outcome, _ = brain.answerTheApproval(noCall, unreadOffer, 0, "no")
	if outcome != voiceToolChanged {
		t.Errorf("a no before reading: outcome %s, want changed", outcome)
	}
	if _, stillWaiting := brain.approvals.waitingCapability("approval-1"); stillWaiting {
		t.Error("a no before reading left the request waiting")
	}
	if want := `{"type":"approval_settled","approvalID":"approval-1","approved":false,"scope":"once"}`; !strings.Contains(written.String(), want) {
		t.Errorf("the harness wrote %s, want %s", written.String(), want)
	}
}

// The whole path: the app names the request its card showed and no request seen whole, and the spoken no settles it.
func TestASpokenNoSettlesATasksRequestThatNoCardHadShownWhole(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		switch {
		case requestIsTheBrains(recorded):
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_answer", "answer_approval", `{"approved":false,"always":false,"confirmation":"declined it"}`))
		case len(recorded.body["messages"].([]any)) == 1:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_open", "open_url", `{"url":"https://example.com/a"}`))
		default:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Skipped it."}`))
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "open the page"))
	var request struct {
		ApprovalID string `json:"approvalID"`
	}
	if err := json.Unmarshal([]byte(driver.expectLine("approval_request")), &request); err != nil {
		t.Fatal(err)
	}

	driver.send(approvalVoiceCommandLine("command-1", "no", request.ApprovalID, ""))
	// The settled line, the command's end, and the task's end come in any order, since they run in their own goroutines.
	// The declined open_url call never reaches the app.
	var settledLine string
	commandFinished, taskFinished := false, false
	for settledLine == "" || !commandFinished || !taskFinished {
		switch line := driver.nextLine(); messageType(line) {
		case "approval_settled":
			settledLine = line
		case "voice_command_finished":
			commandFinished = true
		case "task_finished":
			taskFinished = true
		case "log":
			driver.logs = append(driver.logs, line)
		case "voice_line_if_every_call_changes":
			driver.voiceLines = append(driver.voiceLines, line)
		default:
			t.Fatalf("unexpected line %s", line)
		}
	}
	if want := fmt.Sprintf(`{"type":"approval_settled","approvalID":%q,"approved":false,"scope":"once"}`, request.ApprovalID); settledLine != want {
		t.Fatalf("settled:\n got %s\nwant %s", settledLine, want)
	}
}

func newApprovalTestBrain(t *testing.T) (*brainRunner, *bytes.Buffer) {
	t.Helper()
	written := &bytes.Buffer{}
	return &brainRunner{writer: newProtocolWriter(written), approvals: newApprovalGate()}, written
}

// ---- A voice answer and a click settle one request once ----

func TestAVoiceAnswerSettlesTheTasksRequestOnceAndALaterClickChangesNothing(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		switch {
		case requestIsTheBrains(recorded):
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_answer", "answer_approval", `{"approved":true,"always":false,"confirmation":"allowed it"}`))
		case len(recorded.body["messages"].([]any)) == 1:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_open", "open_url", `{"url":"https://example.com/a"}`))
		default:
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Opened it."}`))
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "open the page"))
	var request struct {
		ApprovalID string `json:"approvalID"`
	}
	if err := json.Unmarshal([]byte(driver.expectLine("approval_request")), &request); err != nil {
		t.Fatal(err)
	}

	driver.send(approvalVoiceCommandLine("command-1", "yes", request.ApprovalID, request.ApprovalID))
	// The model answers in its first reply, and the harness settles the request without asking the app. The settled line,
	// the command's end, and the task's approved open_url call come in any order, since the task and the command run in
	// their own goroutines.
	var settledLine, finishedLine, toolCallLine string
	for settledLine == "" || finishedLine == "" || toolCallLine == "" {
		switch line := driver.nextLine(); messageType(line) {
		case "approval_settled":
			settledLine = line
		case "voice_command_finished":
			finishedLine = line
		case "tool_call":
			toolCallLine = line
		case "log":
			driver.logs = append(driver.logs, line)
		case "voice_line_if_every_call_changes":
			driver.voiceLines = append(driver.voiceLines, line)
		default:
			t.Fatalf("unexpected line %s", line)
		}
	}
	if want := fmt.Sprintf(`{"type":"approval_settled","approvalID":%q,"approved":true,"scope":"once"}`, request.ApprovalID); settledLine != want {
		t.Fatalf("settled:\n got %s\nwant %s", settledLine, want)
	}
	if want := `{"type":"voice_command_finished","taskID":"command-1","spokenLine":"allowed it","gaveUp":false}`; finishedLine != want {
		t.Fatalf("finished:\n got %s\nwant %s", finishedLine, want)
	}
	// The call ran as approved, not as declined.
	if !strings.Contains(toolCallLine, `"name":"open_url"`) {
		t.Fatalf("the approved call was %s", toolCallLine)
	}
	// A click for the same request lost the race, so the gate drops it and the app hears nothing more about it.
	driver.send(approvalResultLine(request.ApprovalID, false, "once"))
	driver.send(toolResultLine("task-1", "toolu_open", `"opened"`, false))
	driver.expectLine("task_finished")
	if len(driver.settledLines) != 0 {
		t.Errorf("a second approval_settled followed the first: %v", driver.settledLines)
	}
	if !driver.logsContain("Brain: approval " + request.ApprovalID + " given (once)") {
		t.Errorf("the voice answer left no log line: %v", driver.logs)
	}
}

// On the harness path the app drops the card and shows the outcome only from approval_settled, so a click on a task's
// request is announced too, with the scope the gate took.
func TestAClickOnATasksRequestIsAnnouncedToTheAppAsSettled(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_open", "open_url", `{"url":"https://example.com/a"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Opened it."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "open the page"))

	requestLine := driver.answerNextApproval(true, "always")
	var request struct {
		ApprovalID string `json:"approvalID"`
	}
	if err := json.Unmarshal([]byte(requestLine), &request); err != nil {
		t.Fatal(err)
	}
	// The approved call may reach the app first, since the task runs in its own goroutine.
	want := fmt.Sprintf(`{"type":"approval_settled","approvalID":%q,"approved":true,"scope":"always"}`, request.ApprovalID)
	for settled := false; !settled; {
		switch line := driver.nextLine(); messageType(line) {
		case "approval_settled":
			if line != want {
				t.Fatalf("settled:\n got %s\nwant %s", line, want)
			}
			settled = true
		case "tool_call", "log":
		default:
			t.Fatalf("unexpected line %s", line)
		}
	}
}

// A click that the gate took first leaves a voice answer for the same request with nothing to settle: it fails, writes no
// approval_settled of its own, and the model reads that the request was already answered.
func TestAVoiceAnswerAfterAClickOnTheSameRequestFailsAndSettlesNothing(t *testing.T) {
	brain, written := newApprovalTestBrain(t)
	brain.approvals.seed("approval-1", capabilityDeletes)
	if !brain.approvals.deliver(approvalResultMessage{ApprovalID: "approval-1", Approved: false, Scope: approvalScopeOnce}) {
		t.Fatal("the click was not taken")
	}

	call := toolCall{ID: "toolu_answer", Name: answerApprovalTool, Input: json.RawMessage(`{"approved":true}`)}
	outcome, resultText := brain.answerTheApproval(call, approvalOffer{approvalID: "approval-1", capabilityWord: "deletes", yesMayCount: true}, 0, "yes")

	if outcome != voiceToolFailed || !strings.Contains(resultText, "already answered") {
		t.Errorf("outcome %s with result %s", outcome, resultText)
	}
	if written.Len() != 0 {
		t.Errorf("the harness wrote %s for an answer that lost", written.String())
	}
}

// The yes and the no that race for one request leave exactly one winner, whichever the stdin loop reads first.
func TestTheGateTakesOnlyOneOfTwoAnswersThatRace(t *testing.T) {
	for run := 0; run < 200; run++ {
		gate := newApprovalGate()
		gate.seed("approval-1", capabilitySends)
		results := make(chan bool, 2)
		go func() {
			results <- gate.deliver(approvalResultMessage{ApprovalID: "approval-1", Approved: true, Scope: approvalScopeOnce})
		}()
		go func() {
			results <- gate.deliver(approvalResultMessage{ApprovalID: "approval-1", Approved: false, Scope: approvalScopeOnce})
		}()
		first, second := <-results, <-results
		if first == second {
			t.Fatalf("run %d: both answers returned %t, want exactly one taken", run, first)
		}
	}
}

func TestASettledNoIsNeverRememberedAsAlways(t *testing.T) {
	if got, want := newApprovalSettledMessage("approval-1", false, approvalScopeAlways), (approvalSettledMessage{Type: "approval_settled", ApprovalID: "approval-1", Approved: false, Scope: approvalScopeOnce}); got != want {
		t.Errorf("a no with always: got %+v, want %+v", got, want)
	}
	if got := newApprovalSettledMessage("approval-1", true, approvalScopeAlways); got.Scope != approvalScopeAlways {
		t.Errorf("a yes with always settled with scope %s", got.Scope)
	}
}

// ---- The app secret ----

func TestAWorkerSecretRefusalFailsTheCommandWithTheReasonTheAppReadsAndAnAnthropic401DoesNot(t *testing.T) {
	for _, refusalCase := range []struct {
		name       string
		status     int
		body       string
		wantReason string
		wantExact  bool
	}{
		{name: "the Worker's secret check", status: http.StatusUnauthorized, body: `{"error":"Missing or wrong x-clicky-app-secret"}`, wantReason: "app secret refused", wantExact: true},
		{name: "Anthropic's own 401", status: http.StatusUnauthorized, body: `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`, wantReason: "401"},
		{name: "a 401 with another Worker error", status: http.StatusUnauthorized, body: `{"error":"something else"}`, wantReason: "401"},
		{name: "the secret's words with another status", status: http.StatusForbidden, body: `{"error":"Missing or wrong x-clicky-app-secret"}`, wantReason: "403"},
	} {
		worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
			writer.Header().Set("Content-Type", "application/json")
			writer.WriteHeader(refusalCase.status)
			fmt.Fprint(writer, refusalCase.body)
		})
		driver := startHarness(t, worker.server.URL)
		driver.send(voiceCommandLine("command-1", "turn it left"))

		var failure struct {
			Reason string `json:"reason"`
		}
		if err := json.Unmarshal([]byte(driver.expectLineWithin("task_failed", 10*time.Second)), &failure); err != nil {
			t.Fatal(err)
		}
		if refusalCase.wantExact && failure.Reason != refusalCase.wantReason {
			t.Errorf("%s: the reason was %q, want %q", refusalCase.name, failure.Reason, refusalCase.wantReason)
		}
		if !refusalCase.wantExact && (failure.Reason == "app secret refused" || !strings.Contains(failure.Reason, refusalCase.wantReason)) {
			t.Errorf("%s: the reason was %q, want a router failure that names the %s", refusalCase.name, failure.Reason, refusalCase.wantReason)
		}
		if len(worker.requests()) != 1 {
			t.Errorf("%s: the Worker got %d requests, want 1", refusalCase.name, len(worker.requests()))
		}
	}
}
