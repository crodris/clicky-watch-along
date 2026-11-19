package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
)

// The protocol between the Clicky app and this harness is one JSON object per line on stdin and stdout. Every message
// has a "type" string, and every task message carries the task's ID, which is the UUID string of the agent in the
// app's BackgroundAgentStore. The Swift side of it is leanring-buddy/AgentHarness.swift.

// inboundMessage is a message the app sends, already parsed and checked.
type inboundMessage interface {
	inboundMessage()
}

// startTaskMessage starts a task agent on the learner's goal. frontTabTitle and frontTabURL describe the page the learner
// is watching, which "this" in the goal refers to. Both are nil when no tab was found.
type startTaskMessage struct {
	TaskID        string  `json:"taskID"`
	Goal          string  `json:"goal"`
	FrontTabTitle *string `json:"frontTabTitle"`
	FrontTabURL   *string `json:"frontTabURL"`
}

// toolResultMessage answers one tool_call. Content is a JSON string or an array of content blocks, such as the image
// block look_at_video returns.
type toolResultMessage struct {
	TaskID    string          `json:"taskID"`
	ToolUseID string          `json:"toolUseID"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"isError"`
}

// cancelTaskMessage stops a task. The harness sends nothing more for it.
type cancelTaskMessage struct {
	TaskID string `json:"taskID"`
}

func (startTaskMessage) inboundMessage()  {}
func (toolResultMessage) inboundMessage() {}
func (cancelTaskMessage) inboundMessage() {}

// parseInboundMessage checks one line from the app at the boundary and returns the typed message, or an error that
// names what is wrong with the line.
func parseInboundMessage(line []byte) (inboundMessage, error) {
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(line, &envelope); err != nil {
		return nil, fmt.Errorf("the line is not a JSON object: %w", err)
	}

	switch envelope.Type {
	case "start_task":
		var message startTaskMessage
		if err := json.Unmarshal(line, &message); err != nil {
			return nil, fmt.Errorf("start_task is malformed: %w", err)
		}
		if message.TaskID == "" || message.Goal == "" {
			return nil, fmt.Errorf("start_task needs a taskID and a goal")
		}
		return message, nil
	case "tool_result":
		var message toolResultMessage
		if err := json.Unmarshal(line, &message); err != nil {
			return nil, fmt.Errorf("tool_result is malformed: %w", err)
		}
		if message.TaskID == "" || message.ToolUseID == "" {
			return nil, fmt.Errorf("tool_result needs a taskID and a toolUseID")
		}
		return message, nil
	case "cancel_task":
		var message cancelTaskMessage
		if err := json.Unmarshal(line, &message); err != nil {
			return nil, fmt.Errorf("cancel_task is malformed: %w", err)
		}
		if message.TaskID == "" {
			return nil, fmt.Errorf("cancel_task needs a taskID")
		}
		return message, nil
	default:
		return nil, fmt.Errorf("unknown message type %q", envelope.Type)
	}
}

// outboundMessage is a message this harness sends to the app. Build one with its new...Message function, which sets
// the "type" the app switches on.
type outboundMessage interface {
	outboundMessage()
}

// readyMessage is sent once, after the harness has read its environment.
type readyMessage struct {
	Type string `json:"type"`
}

// toolCallMessage asks the app to run one of the app's tools. Input is the model's JSON object for the tool.
type toolCallMessage struct {
	Type      string          `json:"type"`
	TaskID    string          `json:"taskID"`
	ToolUseID string          `json:"toolUseID"`
	Name      toolName        `json:"name"`
	Input     json.RawMessage `json:"input"`
}

// taskFinishedMessage ends a task with the answer the agent would speak.
type taskFinishedMessage struct {
	Type          string `json:"type"`
	TaskID        string `json:"taskID"`
	SpokenSummary string `json:"spokenSummary"`
}

// taskFailedMessage ends a task that ran out of turns, ended with no answer, or hit an API error.
type taskFailedMessage struct {
	Type   string `json:"type"`
	TaskID string `json:"taskID"`
	Reason string `json:"reason"`
}

// logMessage is a line the app prints, since stdout carries only protocol lines.
type logMessage struct {
	Type    string `json:"type"`
	Message string `json:"message"`
}

func (readyMessage) outboundMessage()        {}
func (toolCallMessage) outboundMessage()     {}
func (taskFinishedMessage) outboundMessage() {}
func (taskFailedMessage) outboundMessage()   {}
func (logMessage) outboundMessage()          {}

func newReadyMessage() readyMessage {
	return readyMessage{Type: "ready"}
}

func newToolCallMessage(taskID string, toolUseID string, name toolName, input json.RawMessage) toolCallMessage {
	return toolCallMessage{Type: "tool_call", TaskID: taskID, ToolUseID: toolUseID, Name: name, Input: input}
}

func newTaskFinishedMessage(taskID string, spokenSummary string) taskFinishedMessage {
	return taskFinishedMessage{Type: "task_finished", TaskID: taskID, SpokenSummary: spokenSummary}
}

func newTaskFailedMessage(taskID string, reason string) taskFailedMessage {
	return taskFailedMessage{Type: "task_failed", TaskID: taskID, Reason: reason}
}

func newLogMessage(message string) logMessage {
	return logMessage{Type: "log", Message: message}
}

// protocolWriter writes each message as one line. Tasks run in their own goroutines, so writes are serialized to keep
// lines from interleaving.
type protocolWriter struct {
	mutex  sync.Mutex
	output io.Writer
}

func newProtocolWriter(output io.Writer) *protocolWriter {
	return &protocolWriter{output: output}
}

func (writer *protocolWriter) send(message outboundMessage) {
	line, err := json.Marshal(message)
	if err != nil {
		fmt.Fprintf(os.Stderr, "harness: could not encode %T: %v\n", message, err)
		return
	}
	writer.mutex.Lock()
	defer writer.mutex.Unlock()
	if _, err := writer.output.Write(append(line, '\n')); err != nil {
		fmt.Fprintf(os.Stderr, "harness: could not write to the app: %v\n", err)
	}
}
