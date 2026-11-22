package main

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"
)

// How long a test watches for a line that must not come while a task is paused.
const pausedQuietTime = 300 * time.Millisecond

// expectOnlyLogsFor fails when any line but a log arrives within the time, which is how a paused task stays quiet.
func (driver *protocolDriver) expectOnlyLogsFor(duration time.Duration) {
	driver.t.Helper()
	deadline := time.After(duration)
	for {
		select {
		case line, open := <-driver.lines:
			if !open {
				driver.t.Fatal("the harness closed its output")
			}
			if messageType(line) != "log" {
				driver.t.Fatalf("a paused task sent %s", line)
			}
			driver.logs = append(driver.logs, line)
		case <-deadline:
			return
		}
	}
}

// expectLog waits for a log line that holds text, which is how a test knows the harness read a line it sent.
func (driver *protocolDriver) expectLog(text string) {
	driver.t.Helper()
	for !driver.logsContain(text) {
		driver.logs = append(driver.logs, driver.expectLine("log"))
	}
}

func pauseTaskLine(taskID string) string  { return `{"type":"pause_task","taskID":"` + taskID + `"}` }
func resumeTaskLine(taskID string) string { return `{"type":"resume_task","taskID":"` + taskID + `"}` }

func TestAPausedTaskStartsNoNewTurnUntilItResumes(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock(reportStepToolUse, "report_step", `{"step":"Searching"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "compare the catches"))
	driver.expectLine("tool_call")

	// The call already in flight finishes, and the result waits with the task.
	driver.send(pauseTaskLine("task-1"))
	driver.send(toolResultLine("task-1", reportStepToolUse, `"shown"`, false))
	driver.expectOnlyLogsFor(pausedQuietTime)
	if requestCount := len(worker.requests()); requestCount != 1 {
		t.Fatalf("a paused task sent %d requests, want 1", requestCount)
	}
	if !driver.logsContain("Task agent: holding turn 2 until the learner resumes") {
		t.Errorf("the log did not say the turn was held: %v", driver.logs)
	}

	driver.send(resumeTaskLine("task-1"))
	if finished := driver.expectLine("task_finished"); !strings.Contains(finished, "Done.") {
		t.Fatalf("finished line %s", finished)
	}
}

func TestATaskStartedPausedSendsNoRequestUntilItResumes(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(`{"type":"start_task","taskID":"task-1","goal":"look it up","frontTabTitle":null,"frontTabURL":null,"startsPaused":true}`)

	driver.expectOnlyLogsFor(pausedQuietTime)
	if requestCount := len(worker.requests()); requestCount != 0 {
		t.Fatalf("a task started paused sent %d requests, want 0", requestCount)
	}
	driver.send(resumeTaskLine("task-1"))
	driver.expectLine("task_finished")
}

func TestTheCallsOfATurnThatFinishedDuringAPauseWaitForTheResume(t *testing.T) {
	requestArrived := make(chan struct{})
	releaseTheReply := make(chan struct{})
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			close(requestArrived)
			<-releaseTheReply
			writeStreamedMessage(writer, "tool_use", toolUseBlock(reportStepToolUse, "report_step", `{"step":"Searching"}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "compare the catches"))
	waitFor(t, requestArrived, "the first request to reach the Worker")

	// The request in flight finishes during the pause, and the call it asks for waits.
	driver.send(pauseTaskLine("task-1"))
	driver.expectLog("Task agent: paused by the learner")
	close(releaseTheReply)
	driver.expectOnlyLogsFor(pausedQuietTime)
	if !driver.logsContain("Task agent: holding a tool call until the learner resumes") {
		t.Errorf("the log did not say the call was held: %v", driver.logs)
	}

	driver.send(resumeTaskLine("task-1"))
	driver.expectLine("tool_call")
	driver.send(toolResultLine("task-1", reportStepToolUse, `"shown"`, false))
	driver.expectLine("task_finished")
}

func TestAPendingApprovalStaysPendingAndItsCallWaitsForTheResume(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_read", "read_clipboard", `{}`))
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "read my clipboard"))
	requestLine := driver.expectLine("approval_request")

	// The pause neither answers nor drops the request, and the learner can still answer it.
	driver.send(pauseTaskLine("task-1"))
	driver.expectLog("Task agent: paused by the learner")
	driver.expectOnlyLogsFor(pausedQuietTime)
	approvalID := strings.SplitN(strings.SplitN(requestLine, `"approvalID":"`, 2)[1], `"`, 2)[0]
	driver.send(approvalResultLine(approvalID, true, "once"))
	driver.expectLine("approval_settled")
	driver.expectOnlyLogsFor(pausedQuietTime)

	driver.send(resumeTaskLine("task-1"))
	if toolCall := driver.expectLine("tool_call"); !strings.Contains(toolCall, "read_clipboard") {
		t.Fatalf("tool call %s", toolCall)
	}
	driver.send(toolResultLine("task-1", "toolu_read", `"clipboard text"`, false))
	driver.expectLine("task_finished")
}

func TestTheNextApprovalOfATurnWaitsForTheResume(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use",
				toolUseBlock("toolu_read", "read_clipboard", `{}`),
				toolUseBlock("toolu_open", "open_url", `{"url":"https://example.com/page"}`),
			)
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "read my clipboard and open the page"))
	firstRequest := driver.expectLine("approval_request")

	// The learner answers the first request during the pause, and the turn's second request waits for the resume.
	driver.send(pauseTaskLine("task-1"))
	driver.expectLog("Task agent: paused by the learner")
	approvalID := strings.SplitN(strings.SplitN(firstRequest, `"approvalID":"`, 2)[1], `"`, 2)[0]
	driver.send(approvalResultLine(approvalID, false, "once"))
	driver.expectLine("approval_settled")
	driver.expectOnlyLogsFor(pausedQuietTime)

	driver.send(resumeTaskLine("task-1"))
	if secondRequest := driver.answerNextApproval(false, "once"); !strings.Contains(secondRequest, "example.com") {
		t.Fatalf("second request %s", secondRequest)
	}
	driver.expectLine("task_finished")
}

func TestACancelledPausedTaskSendsNothingMore(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(`{"type":"start_task","taskID":"task-1","goal":"look it up","frontTabTitle":null,"frontTabURL":null,"startsPaused":true}`)
	driver.send(`{"type":"cancel_task","taskID":"task-1"}`)
	driver.send(resumeTaskLine("task-1"))
	driver.expectOnlyLogsFor(pausedQuietTime)
	if requestCount := len(worker.requests()); requestCount != 0 {
		t.Fatalf("a cancelled task sent %d requests, want 0", requestCount)
	}
}

func TestThePauseGateHoldsUntilResumeOrCancel(t *testing.T) {
	gate := newPauseGate(false)
	heldCount := 0
	if err := gate.waitWhilePaused(context.Background(), func() { heldCount++ }); err != nil || heldCount != 0 {
		t.Fatalf("a running gate waited: err %v, held %d", err, heldCount)
	}

	gate.pause()
	gate.pause()
	waitEnded := make(chan error, 1)
	go func() { waitEnded <- gate.waitWhilePaused(context.Background(), func() { heldCount++ }) }()
	select {
	case err := <-waitEnded:
		t.Fatalf("a paused gate let the step go: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	gate.resume()
	gate.resume()
	if err := <-waitEnded; err != nil {
		t.Fatalf("the resumed step got %v", err)
	}
	if heldCount != 1 {
		t.Errorf("onHeld ran %d times, want 1", heldCount)
	}

	// A second pause while a step waits keeps the same hold, so one resume still lets that step go.
	gate.pause()
	waitEndedAfterTheSecondPause := make(chan error, 1)
	go func() { waitEndedAfterTheSecondPause <- gate.waitWhilePaused(context.Background(), func() {}) }()
	time.Sleep(50 * time.Millisecond)
	gate.pause()
	gate.resume()
	select {
	case err := <-waitEndedAfterTheSecondPause:
		if err != nil {
			t.Fatalf("the resumed step got %v", err)
		}
	case <-time.After(testTimeout):
		t.Fatal("a second pause orphaned the step that was already waiting")
	}

	cancelledGate := newPauseGate(true)
	taskContext, cancel := context.WithCancel(context.Background())
	cancel()
	if err := cancelledGate.waitWhilePaused(taskContext, func() {}); !errors.Is(err, context.Canceled) {
		t.Errorf("a cancelled wait returned %v", err)
	}
}

func TestPauseAndResumeLinesNeedATaskID(t *testing.T) {
	for _, line := range []string{`{"type":"pause_task"}`, `{"type":"resume_task","taskID":""}`} {
		if _, err := parseInboundMessage([]byte(line)); err == nil {
			t.Errorf("%s was accepted", line)
		}
	}
	message, err := parseInboundMessage([]byte(pauseTaskLine("task-1")))
	if err != nil || message != (pauseTaskMessage{TaskID: "task-1"}) {
		t.Errorf("pause_task parsed to %#v, %v", message, err)
	}
	message, err = parseInboundMessage([]byte(resumeTaskLine("task-1")))
	if err != nil || message != (resumeTaskMessage{TaskID: "task-1"}) {
		t.Errorf("resume_task parsed to %#v, %v", message, err)
	}
}
