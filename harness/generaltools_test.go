package main

import (
	"net/http"
	"strings"
	"testing"
)

// The screenshot, clipboard, and link tools run in the app, so the harness forwards each call, and the screenshot's
// answer carries the picture and the saved file's path together.
func TestTheGeneralToolsAreForwardedToTheAppAndAScreenshotAnswersWithPictureAndPath(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeStreamedMessage(writer, "tool_use",
				toolUseBlock("toolu_shot", "take_screenshot", `{}`),
				toolUseBlock("toolu_read", "read_clipboard", `{}`),
				toolUseBlock("toolu_write", "write_clipboard", `{"text":"hello"}`),
				toolUseBlock("toolu_open", "open_url", `{"url":"https://example.com"}`),
			)
			return
		}
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(startTaskLine("task-1", "paste the screen"))

	wantNames := []string{"take_screenshot", "read_clipboard", "write_clipboard", "open_url"}
	for _, wantName := range wantNames {
		// Each of these needs the learner's approval before the app is asked to run it.
		driver.answerNextApproval(true, "once")
		toolCallLine := driver.expectLine("tool_call")
		if !strings.Contains(toolCallLine, `"name":"`+wantName+`"`) {
			t.Fatalf("expected a %s call for the app, got %s", wantName, toolCallLine)
		}
	}
	driver.send(toolResultLine("task-1", "toolu_shot",
		`[{"type":"text","text":"Saved to /tmp/clicky/task-1/screenshot-1.jpg"},{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"QUJD"}}]`, false))
	driver.send(toolResultLine("task-1", "toolu_read", `"copied text"`, false))
	driver.send(toolResultLine("task-1", "toolu_write", `"Copied"`, false))
	driver.send(toolResultLine("task-1", "toolu_open", `"Opened"`, false))
	driver.expectLine("task_finished")

	shotResult := jsonValueAt(t, worker.requests()[1].body, "messages", 2, "content", 0, "content")
	if jsonValueAt(t, shotResult, 0, "text") != "Saved to /tmp/clicky/task-1/screenshot-1.jpg" || jsonValueAt(t, shotResult, 1, "type") != "image" {
		t.Errorf("the screenshot result sent back was %v", shotResult)
	}
}
