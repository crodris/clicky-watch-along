package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

const testTimeout = 5 * time.Second

// jsonValueAt reads a value out of decoded JSON by a path of object keys and array positions.
func jsonValueAt(t *testing.T, document any, path ...any) any {
	t.Helper()
	current := document
	for _, step := range path {
		switch step := step.(type) {
		case string:
			object, isObject := current.(map[string]any)
			if !isObject {
				t.Fatalf("expected an object at %q, found %T", step, current)
			}
			current = object[step]
		case int:
			array, isArray := current.([]any)
			if !isArray || step >= len(array) {
				t.Fatalf("expected an array with position %d, found %v", step, current)
			}
			current = array[step]
		}
	}
	return current
}

// ---- A fake Worker that answers POST /v1/messages with a streamed reply ----

type recordedRequest struct {
	path   string
	header http.Header
	body   map[string]any
}

type fakeWorker struct {
	server  *httptest.Server
	mutex   sync.Mutex
	records []recordedRequest
}

// newFakeWorker starts a server whose answer to each request comes from respond. requestNumber counts from 1 across
// every task.
func newFakeWorker(t *testing.T, respond func(writer http.ResponseWriter, request *http.Request, recorded recordedRequest, requestNumber int)) *fakeWorker {
	t.Helper()
	worker := &fakeWorker{}
	worker.server = httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(request.Body).Decode(&body); err != nil {
			t.Errorf("the fake Worker could not read the request body: %v", err)
		}
		recorded := recordedRequest{path: request.URL.Path, header: request.Header.Clone(), body: body}
		worker.mutex.Lock()
		worker.records = append(worker.records, recorded)
		requestNumber := len(worker.records)
		worker.mutex.Unlock()
		respond(writer, request, recorded, requestNumber)
	}))
	// Closing the connections first ends a handler that waits on its request, so a failing test does not hang here.
	t.Cleanup(func() {
		worker.server.CloseClientConnections()
		worker.server.Close()
	})
	return worker
}

func (worker *fakeWorker) requests() []recordedRequest {
	worker.mutex.Lock()
	defer worker.mutex.Unlock()
	return append([]recordedRequest(nil), worker.records...)
}

// fakeBlock is one content block of a streamed reply: how it starts, then the deltas that fill it in.
type fakeBlock struct {
	start  string
	deltas []string
}

func textBlock(text string) fakeBlock {
	return fakeBlock{
		start:  `{"type":"text","text":""}`,
		deltas: []string{fmt.Sprintf(`{"type":"text_delta","text":%q}`, text)},
	}
}

func thinkingBlock(signature string) fakeBlock {
	return fakeBlock{
		start: `{"type":"thinking","thinking":"","signature":""}`,
		deltas: []string{
			`{"type":"thinking_delta","thinking":"Plan the search."}`,
			fmt.Sprintf(`{"type":"signature_delta","signature":%q}`, signature),
		},
	}
}

// toolUseBlock streams its input in two pieces, as the API does.
func toolUseBlock(id string, name string, inputJSON string) fakeBlock {
	return streamedToolBlock("tool_use", id, name, inputJSON)
}

func serverToolUseBlock(id string, name string, inputJSON string) fakeBlock {
	return streamedToolBlock("server_tool_use", id, name, inputJSON)
}

func streamedToolBlock(blockType string, id string, name string, inputJSON string) fakeBlock {
	middle := len(inputJSON) / 2
	return fakeBlock{
		start: fmt.Sprintf(`{"type":%q,"id":%q,"name":%q,"input":{}}`, blockType, id, name),
		deltas: []string{
			fmt.Sprintf(`{"type":"input_json_delta","partial_json":%q}`, inputJSON[:middle]),
			fmt.Sprintf(`{"type":"input_json_delta","partial_json":%q}`, inputJSON[middle:]),
		},
	}
}

// completeBlock is a block that arrives whole in its start event, like a web search result.
func completeBlock(blockJSON string) fakeBlock {
	return fakeBlock{start: blockJSON}
}

func writeStreamedMessage(writer http.ResponseWriter, stopReason string, blocks ...fakeBlock) {
	writer.Header().Set("Content-Type", "text/event-stream")
	var stream strings.Builder
	sendEvent := func(eventType string, dataJSON string) {
		fmt.Fprintf(&stream, "event: %s\ndata: %s\n\n", eventType, dataJSON)
	}
	sendEvent("message_start", `{"type":"message_start","message":{"id":"msg_test","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":120,"cache_read_input_tokens":30,"cache_creation_input_tokens":0,"output_tokens":1}}}`)
	for blockIndex, block := range blocks {
		sendEvent("content_block_start", fmt.Sprintf(`{"type":"content_block_start","index":%d,"content_block":%s}`, blockIndex, block.start))
		for _, delta := range block.deltas {
			sendEvent("content_block_delta", fmt.Sprintf(`{"type":"content_block_delta","index":%d,"delta":%s}`, blockIndex, delta))
		}
		sendEvent("content_block_stop", fmt.Sprintf(`{"type":"content_block_stop","index":%d}`, blockIndex))
	}
	sendEvent("message_delta", fmt.Sprintf(`{"type":"message_delta","delta":{"stop_reason":%q,"stop_sequence":null},"usage":{"output_tokens":40}}`, stopReason))
	sendEvent("message_stop", `{"type":"message_stop"}`)
	io.WriteString(writer, stream.String())
}

// firstUserText is the learner's task message, the first text of the first message of a request.
func firstUserText(t *testing.T, requestBody map[string]any) string {
	t.Helper()
	text, _ := jsonValueAt(t, requestBody, "messages", 0, "content", 0, "text").(string)
	return text
}

// ---- A driver that plays the app's side of the protocol over in-memory pipes ----

type protocolDriver struct {
	t           *testing.T
	input       *io.PipeWriter
	lines       chan string
	runFinished chan error
	stopOnce    sync.Once
	logs        []string
	// settledLines are the approval_settled lines skipped on the way to another line.
	settledLines []string
	// voiceLines are the voice_line_if_every_call_changes lines skipped on the way to another line.
	voiceLines []string
}

// startHarness runs the harness against a Worker URL and checks that it announces itself first.
func startHarness(t *testing.T, workerURL string) *protocolDriver {
	t.Helper()
	return startHarnessWith(t, configuration{workerBaseURL: workerURL, appSecret: "test-secret"})
}

// startHarnessWith is startHarness with the rest of the configuration set, such as the skills directories.
func startHarnessWith(t *testing.T, harnessConfiguration configuration) *protocolDriver {
	t.Helper()
	inputReader, inputWriter := io.Pipe()
	outputReader, outputWriter := io.Pipe()
	driver := &protocolDriver{t: t, input: inputWriter, lines: make(chan string, 256), runFinished: make(chan error, 1)}

	go func() {
		driver.runFinished <- run(context.Background(), inputReader, outputWriter, harnessConfiguration)
		outputWriter.Close()
	}()
	go func() {
		lineScanner := bufio.NewScanner(outputReader)
		lineScanner.Buffer(make([]byte, 1024*1024), 16*1024*1024)
		for lineScanner.Scan() {
			driver.lines <- lineScanner.Text()
		}
		close(driver.lines)
	}()
	t.Cleanup(func() { driver.stop() })

	if readyLine := driver.expectLine("ready"); readyLine != `{"type":"ready"}` {
		t.Fatalf("the ready line was %s", readyLine)
	}
	return driver
}

func (driver *protocolDriver) send(line string) {
	driver.t.Helper()
	if _, err := io.WriteString(driver.input, line+"\n"); err != nil {
		driver.t.Fatalf("could not write to the harness: %v", err)
	}
}

// nextLine returns the next line the harness wrote. Every line must be one JSON object, since stdout carries only
// protocol lines.
func (driver *protocolDriver) nextLine() string {
	driver.t.Helper()
	select {
	case line, open := <-driver.lines:
		if !open {
			driver.t.Fatal("the harness closed its output")
		}
		var decoded map[string]any
		if err := json.Unmarshal([]byte(line), &decoded); err != nil {
			driver.t.Fatalf("stdout carried a line that is not a JSON object: %q", line)
		}
		return line
	case <-time.After(testTimeout):
		driver.t.Fatal("timed out waiting for a line from the harness")
		return ""
	}
}

func messageType(line string) string {
	var envelope struct {
		Type string `json:"type"`
	}
	_ = json.Unmarshal([]byte(line), &envelope)
	return envelope.Type
}

// expectLine returns the next line of the given type. Log lines on the way are kept in driver.logs.
func (driver *protocolDriver) expectLine(expectedType string) string {
	driver.t.Helper()
	for {
		line := driver.nextLine()
		switch actualType := messageType(line); {
		case actualType == expectedType:
			return line
		case actualType == "log":
			driver.logs = append(driver.logs, line)
		case actualType == "approval_settled":
			// A click or a voice answer is announced to the app right after the gate takes it, so a test that does not
			// wait for it skips it. The tests of the answer itself expect it by name.
			driver.settledLines = append(driver.settledLines, line)
		case actualType == "voice_line_if_every_call_changes":
			// A turn with calls sends its line ahead of them, so a test that does not wait for it skips it. The tests of
			// the line itself expect it by name.
			driver.voiceLines = append(driver.voiceLines, line)
		default:
			driver.t.Fatalf("expected a %s line, got %s", expectedType, line)
		}
	}
}

func (driver *protocolDriver) logsContain(text string) bool {
	for _, logLine := range driver.logs {
		if strings.Contains(logLine, text) {
			return true
		}
	}
	return false
}

// logsContainLineEndingWith reports whether a log line starts with prefix and ends with suffix, so a test can pin the end
// of a line whose middle holds a time.
func (driver *protocolDriver) logsContainLineEndingWith(prefix string, suffix string) bool {
	for _, logLine := range driver.logs {
		if strings.Contains(logLine, prefix) && strings.HasSuffix(strings.TrimSuffix(logLine, `"}`), suffix) {
			return true
		}
	}
	return false
}

// stop closes the harness's input, as the app does when it quits, and waits for run to return.
func (driver *protocolDriver) stop() {
	driver.stopOnce.Do(func() {
		driver.input.Close()
		select {
		case err := <-driver.runFinished:
			if err != nil {
				driver.t.Errorf("run returned %v", err)
			}
		case <-time.After(testTimeout):
			driver.t.Error("the harness did not stop after its input closed")
		}
	})
}

func startTaskLine(taskID string, goal string) string {
	return fmt.Sprintf(`{"type":"start_task","taskID":%q,"goal":%q,"frontTabTitle":"SpaceX catch","frontTabURL":"https://www.youtube.com/watch?v=abc"}`, taskID, goal)
}

func approvalResultLine(approvalID string, approved bool, scope string) string {
	return fmt.Sprintf(`{"type":"approval_result","approvalID":%q,"approved":%t,"scope":%q}`, approvalID, approved, scope)
}

// answerNextApproval expects the harness to ask for approval, answers it, and returns the request line.
func (driver *protocolDriver) answerNextApproval(approved bool, scope string) string {
	driver.t.Helper()
	requestLine := driver.expectLine("approval_request")
	var request struct {
		ApprovalID string `json:"approvalID"`
	}
	if err := json.Unmarshal([]byte(requestLine), &request); err != nil || request.ApprovalID == "" {
		driver.t.Fatalf("the approval request had no approvalID: %s", requestLine)
	}
	driver.send(approvalResultLine(request.ApprovalID, approved, scope))
	return requestLine
}

func toolResultLine(taskID string, toolUseID string, contentJSON string, isError bool) string {
	return fmt.Sprintf(`{"type":"tool_result","taskID":%q,"toolUseID":%q,"content":%s,"isError":%t}`, taskID, toolUseID, contentJSON, isError)
}
