package main

import (
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

// A command the app starts on the partial transcript at push-to-talk release runs its first turn at once, and goes no
// further until the app says the final transcript matched. These tests play the three ways it ends: confirmed, discarded
// for a final transcript with other words, and discarded with a reply that called no tool.

// speculativeVoiceCommandLine is voiceCommandLine for a command started on the partial transcript.
func speculativeVoiceCommandLine(commandID string, partialTranscript string) string {
	return fmt.Sprintf(`{"type":"voice_command","taskID":%q,"transcript":%q,"sceneState":{"page":"framePopout"},"tools":%s,"waitsForTheFinalTranscript":true}`,
		commandID, partialTranscript, brainTestTools)
}

// expectOnlyLogLinesFor fails when the harness writes anything but a log line in this time.
func (driver *protocolDriver) expectOnlyLogLinesFor(quiet time.Duration) {
	driver.t.Helper()
	deadline := time.After(quiet)
	for {
		select {
		case line := <-driver.lines:
			if messageType(line) != "log" {
				driver.t.Fatalf("expected only log lines, got %s", line)
			}
			driver.logs = append(driver.logs, line)
		case <-deadline:
			return
		}
	}
}

func confirmVoiceCommandLine(commandID string) string {
	return fmt.Sprintf(`{"type":"confirm_voice_command","taskID":%q}`, commandID)
}

// newRotatingBrainWorker answers every brain turn with one rotate call, and records each turn's transcript and whether
// its request carried earlier messages.
func newRotatingBrainWorker(t *testing.T) (*fakeWorker, func() []string) {
	var mutex sync.Mutex
	var userTexts []string
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		mutex.Lock()
		userTexts = append(userTexts, firstUserText(t, recorded.body))
		mutex.Unlock()
		writeBrainReply(writer, "tool_use", brainToolUse("toolu_rotate", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it left"}`))
	})
	return worker, func() []string {
		mutex.Lock()
		defer mutex.Unlock()
		return append([]string(nil), userTexts...)
	}
}

func TestACommandOnThePartialTranscriptSendsNoCallUntilTheFinalOneMatches(t *testing.T) {
	worker, _ := newRotatingBrainWorker(t)
	driver := startHarness(t, worker.server.URL)

	driver.send(speculativeVoiceCommandLine("command-1", "turn it left"))
	// The early line goes out at once. The app reads it, and starts fetching its audio, only once the command is confirmed,
	// since the command's events wait in their stream until then.
	if got := driver.expectLine("voice_line_if_every_call_changes"); !strings.Contains(got, `"spokenLine":"turned it left"`) {
		t.Fatalf("the early line was %s", got)
	}
	// The call waits for the final transcript, so the app runs nothing the learner did not say.
	driver.expectNoLineFor(300 * time.Millisecond)

	driver.send(confirmVoiceCommandLine("command-1"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"toolUseID":"toolu_rotate"`) {
		t.Fatalf("the confirmed command's call was %s", got)
	}
	driver.send(voiceToolResultLine("command-1", "toolu_rotate", voiceToolChanged, `{"ok":true,"state":null}`))
	if got := driver.expectLine("voice_command_finished"); !strings.Contains(got, `"spokenLine":"turned it left"`) {
		t.Fatalf("finished: %s", got)
	}
	if !driver.logsContain("Brain: turn 1 waited ") || !driver.logsContain(" ms for the final transcript") {
		t.Errorf("the wait for the final transcript left no log line: %v", driver.logs)
	}

	// The confirmed command stays in the session, so the next command's request carries it.
	driver.send(voiceCommandLine("command-2", "again"))
	driver.expectLine("tool_call")
	requests := worker.requests()
	// The confirmed command's user message, its call, and its result, which the next command's words join.
	nextMessages := jsonValueAt(t, requests[len(requests)-1].body, "messages").([]any)
	if len(nextMessages) != 3 || !strings.Contains(firstUserText(t, requests[len(requests)-1].body), "<learner_words>turn it left</learner_words>") {
		t.Errorf("the next command's request carried %d messages, starting %q, want the confirmed command's three", len(nextMessages), firstUserText(t, requests[len(requests)-1].body))
	}
}

func TestADiscardedCommandLeavesNoTraceAndTheFinalTranscriptRunsNormally(t *testing.T) {
	worker, userTexts := newRotatingBrainWorker(t)
	driver := startHarness(t, worker.server.URL)

	driver.send(speculativeVoiceCommandLine("command-partial", "turn it"))
	driver.expectLine("voice_line_if_every_call_changes")
	driver.expectNoLineFor(200 * time.Millisecond)
	// The final transcript had other words, so the app cancels the partial command, with no call running, and sends the
	// final one as a normal command.
	driver.send(cancelTaskLine("command-partial"))
	driver.send(voiceCommandLine("command-final", "turn it right"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"taskID":"command-final"`) {
		t.Fatalf("the first call after the discard was %s, which must be the final command's", got)
	}
	driver.send(voiceToolResultLine("command-final", "toolu_rotate", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.expectLine("voice_command_finished")
	if !driver.logsContain("Brain: command cancelled during turn 1") {
		t.Errorf("the discard left no cancel line: %v", driver.logs)
	}

	// The discarded command never ran a call, so the final command reads a session with nothing in it: no earlier
	// message, and no interrupted_before line that would tell the model a call was cut off.
	requests := worker.requests()
	if len(requests) != 2 {
		t.Fatalf("the Worker got %d requests, want 2", len(requests))
	}
	if got := len(jsonValueAt(t, requests[1].body, "messages").([]any)); got != 1 {
		t.Errorf("the final command's request carried %d messages, want only its own", got)
	}
	finalUserText := userTexts()[1]
	if strings.Contains(finalUserText, interruptedBeforeTag) || !strings.Contains(finalUserText, "<learner_words>turn it right</learner_words>") {
		t.Errorf("the final command read %q", finalUserText)
	}
}

func TestADiscardedCommandWhoseReplyCalledNoToolIsNeverKept(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"I can't do that one."}`)
			return
		}
		writeBrainReply(writer, "tool_use", brainToolUse("toolu_rotate", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it left"}`))
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(speculativeVoiceCommandLine("command-partial", "do a"))
	// A reply with no call would finish the command at once, so the finished line and the commit wait too.
	driver.expectOnlyLogLinesFor(300 * time.Millisecond)
	driver.send(cancelTaskLine("command-partial"))
	driver.send(voiceCommandLine("command-final", "do a barrel roll"))
	driver.expectLine("tool_call")
	if got := len(jsonValueAt(t, worker.requests()[1].body, "messages").([]any)); got != 1 {
		t.Errorf("the final command's request carried %d messages, so the discarded reply was kept", got)
	}
}

func TestACommandOnThePartialTranscriptCannotNameAnApproval(t *testing.T) {
	worker, _ := newRotatingBrainWorker(t)
	driver := startHarness(t, worker.server.URL)

	// A partial "yes" could answer a request the learner never finished answering, so the line is refused at the boundary.
	line := strings.TrimSuffix(speculativeVoiceCommandLine("command-1", "yes"), "}") + `,"approvalIDSeenAtPress":"approval-1"}`
	driver.send(line)
	if got := driver.expectLine("task_failed"); !strings.Contains(got, `"taskID":"command-1"`) || !strings.Contains(got, "cannot name an approval") {
		t.Fatalf("the refusal was %s", got)
	}
	// A confirm for a command that is not running changes nothing and writes nothing.
	driver.send(confirmVoiceCommandLine("command-1"))
	driver.expectNoLineFor(200 * time.Millisecond)
	if len(worker.requests()) != 0 {
		t.Errorf("a refused command reached the Worker")
	}
}
