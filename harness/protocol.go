package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/anthropics/anthropic-sdk-go"
)

// The protocol between the Clicky app and this harness is one JSON object per line on stdin and stdout. Every message
// has a "type" string, and every task message carries the task's ID, which is the UUID string of the agent in the
// app's BackgroundAgentStore. A voice command reuses the task messages (tool_call, tool_result, cancel_task, task_failed)
// with the command's own UUID in taskID, and adds voice_command and voice_command_finished. The Swift side of it is
// leanring-buddy/AgentHarness.swift.

// inboundMessage is a message the app sends, already parsed and checked.
type inboundMessage interface {
	inboundMessage()
}

// startTaskMessage starts a task agent on the learner's goal. frontTabTitle and frontTabURL describe the page the learner
// is watching, which "this" in the goal refers to. Both are nil when no tab was found. Skill, when present, names a
// skill file (see skills.go) whose steps the task follows. StartsPaused is true for a task the app starts while the
// learner has paused every agent, so its first turn waits for resume_task (see pause.go).
type startTaskMessage struct {
	TaskID        string  `json:"taskID"`
	Goal          string  `json:"goal"`
	FrontTabTitle *string `json:"frontTabTitle"`
	FrontTabURL   *string `json:"frontTabURL"`
	Skill         *string `json:"skill"`
	StartsPaused  bool    `json:"startsPaused"`
}

// toolResultMessage answers one tool_call. Content is a JSON string or an array of content blocks, such as the image
// block look_at_video returns. SourceURL is the link of the video a read_video_captions result is about, which the app
// sets for that tool alone and the task may then cite (see citableSources in taskagent.go). It is empty for every other result, and the
// harness reads it only from a read_video_captions result, never from Content, which a page's text can write into.
// Outcome says what a voice command's tool did, and a task's result leaves it out.
type toolResultMessage struct {
	TaskID    string           `json:"taskID"`
	ToolUseID string           `json:"toolUseID"`
	Content   json.RawMessage  `json:"content"`
	IsError   bool             `json:"isError"`
	SourceURL string           `json:"sourceURL"`
	Outcome   voiceToolOutcome `json:"outcome"`
}

// voiceToolOutcome is what one of a voice command's tools did in the app, which decides what the brain does next (see
// nextVoiceStep in brain.go). It is the Swift VoiceToolOutcome's wire name.
type voiceToolOutcome string

const (
	// voiceToolChanged: the screen or the video changed.
	voiceToolChanged voiceToolOutcome = "changed"
	// voiceToolLookedUp: a lookup the model reads before it acts again, such as find_moment.
	voiceToolLookedUp voiceToolOutcome = "lookedUp"
	// voiceToolHandedOff: a slow path, such as a pop-out or an answer about the screen, took over and owns what Clicky
	// says next, so the command is complete.
	voiceToolHandedOff voiceToolOutcome = "handedOff"
	voiceToolFailed    voiceToolOutcome = "failed"
)

func (outcome voiceToolOutcome) isKnown() bool {
	switch outcome {
	case voiceToolChanged, voiceToolLookedUp, voiceToolHandedOff, voiceToolFailed:
		return true
	}
	return false
}

// voiceCommandMessage starts one voice command on the brain. SceneState is the JSON object the app builds of what is
// on screen, and Tools are the tools this command may call, already filtered by the app. The message has no
// recentActions, since the brain's session holds every earlier command, and a line that carries one is read with it left out.
// ApprovalIDWaitingAtPress is the oldest approval request the app's desk held when the learner pressed push-to-talk, the
// one its card showed, or nil. ApprovalIDSeenAtPress is that same request when a card had also shown its whole summary for
// a second at the press, or nil. They are the facts about approvals only the app knows (the desk's queue, the card's
// scroll state, and the desk's clock). The harness decides the rest: it offers answer_approval only while the gate holds
// the waiting request, a yes counts only for the request seen at the press, and a no counts for it either way, since a
// wrong no costs only a retry. It names the request's kind of action in the scene state itself, so the app sends no
// approvalWaiting.
type voiceCommandMessage struct {
	TaskID                   string           `json:"taskID"`
	Transcript               string           `json:"transcript"`
	SceneState               json.RawMessage  `json:"sceneState"`
	Tools                    []voiceToolOffer `json:"tools"`
	ApprovalIDWaitingAtPress *string          `json:"approvalIDWaitingAtPress"`
	ApprovalIDSeenAtPress    *string          `json:"approvalIDSeenAtPress"`
}

// seedApprovalRequestMessage puts a waiting request in the approval gate with no task behind it, so the brain evals have
// a request for a voice answer to settle. Only a harness started with CLICKY_BENCH=1 takes it.
type seedApprovalRequestMessage struct {
	ApprovalID string     `json:"approvalID"`
	Capability capability `json:"capability"`
}

// resetSessionMessage empties the brain's session. Only a harness started with CLICKY_BENCH=1 takes it, so the brain
// evals can keep their cases independent.
type resetSessionMessage struct{}

// seedSessionMessage replaces the brain's session with fixed messages, with no model call, so an eval starts from the
// same history every run. Messages are the user, assistant, and tool result messages of earlier commands in the
// Anthropic format. InterruptedBefore are the action lines of an interrupted command the next command's user message
// reports. Only a harness started with CLICKY_BENCH=1 takes it.
type seedSessionMessage struct {
	Messages          []anthropic.MessageParam `json:"messages"`
	InterruptedBefore []string                 `json:"interruptedBefore"`
}

// voiceToolOffer is one tool in the WebMCP and MCP shape, as the app offers it. ReadOnly marks a lookup, whose call
// needs no spoken confirmation.
type voiceToolOffer struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
	ReadOnly    bool            `json:"readOnly"`
}

// cancelTaskMessage stops a task. The harness sends nothing more for it. For a voice command, RunningToolUseID is the
// call the app had started and not answered when the press came, which may already have changed the screen, and it is
// empty when the press caught no call running, such as a call the app dropped before starting it.
type cancelTaskMessage struct {
	TaskID           string `json:"taskID"`
	RunningToolUseID string `json:"runningToolUseID,omitempty"`
}

// pauseTaskMessage holds a task agent's next turn and next tool call until resumeTaskMessage, when the learner says
// "hold on". A turn or a call already in flight finishes, and a pending approval stays pending (see pause.go).
type pauseTaskMessage struct {
	TaskID string `json:"taskID"`
}

// resumeTaskMessage lets a paused task go on, when the learner says "go ahead".
type resumeTaskMessage struct {
	TaskID string `json:"taskID"`
}

// approvalResultMessage answers one approval_request. It names the request by approvalID alone, since the harness made
// the ID and it is unique across tasks. Scope is "once" (this call only) or "always" (this tool at this capability, for
// the rest of the task that asked). A "no" is never remembered, whatever its scope.
type approvalResultMessage struct {
	ApprovalID string `json:"approvalID"`
	Approved   bool   `json:"approved"`
	Scope      string `json:"scope"`
}

const (
	approvalScopeOnce   = "once"
	approvalScopeAlways = "always"
)

func (startTaskMessage) inboundMessage()           {}
func (toolResultMessage) inboundMessage()          {}
func (cancelTaskMessage) inboundMessage()          {}
func (pauseTaskMessage) inboundMessage()           {}
func (resumeTaskMessage) inboundMessage()          {}
func (approvalResultMessage) inboundMessage()      {}
func (voiceCommandMessage) inboundMessage()        {}
func (resetSessionMessage) inboundMessage()        {}
func (seedSessionMessage) inboundMessage()         {}
func (seedApprovalRequestMessage) inboundMessage() {}

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
		if message.Outcome != "" && !message.Outcome.isKnown() {
			return nil, fmt.Errorf("tool_result outcome %q is not changed, lookedUp, handedOff, or failed", message.Outcome)
		}
		return message, nil
	case "voice_command":
		var message voiceCommandMessage
		if err := json.Unmarshal(line, &message); err != nil {
			return nil, fmt.Errorf("voice_command is malformed: %w", err)
		}
		if message.TaskID == "" || message.Transcript == "" || len(message.Tools) == 0 {
			return nil, fmt.Errorf("voice_command needs a taskID, a transcript, and at least one tool")
		}
		return message, nil
	case "reset_session":
		return resetSessionMessage{}, nil
	case "seed_session":
		var message seedSessionMessage
		if err := json.Unmarshal(line, &message); err != nil {
			return nil, fmt.Errorf("seed_session is malformed: %w", err)
		}
		return message, nil
	case "seed_approval_request":
		var message seedApprovalRequestMessage
		if err := json.Unmarshal(line, &message); err != nil {
			return nil, fmt.Errorf("seed_approval_request is malformed: %w", err)
		}
		if message.ApprovalID == "" || !message.Capability.isAKindOfApproval() {
			return nil, fmt.Errorf("seed_approval_request needs an approvalID and a capability that sends, deletes, spends, or reads_private")
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
	case "pause_task":
		var message pauseTaskMessage
		if err := json.Unmarshal(line, &message); err != nil || message.TaskID == "" {
			return nil, fmt.Errorf("pause_task needs a taskID")
		}
		return message, nil
	case "resume_task":
		var message resumeTaskMessage
		if err := json.Unmarshal(line, &message); err != nil || message.TaskID == "" {
			return nil, fmt.Errorf("resume_task needs a taskID")
		}
		return message, nil
	case "approval_result":
		var raw struct {
			ApprovalID string  `json:"approvalID"`
			Approved   *bool   `json:"approved"`
			Scope      *string `json:"scope"`
		}
		if err := json.Unmarshal(line, &raw); err != nil {
			return nil, fmt.Errorf("approval_result is malformed: %w", err)
		}
		if raw.ApprovalID == "" || raw.Approved == nil {
			return nil, fmt.Errorf("approval_result needs an approvalID and approved")
		}
		scope := approvalScopeOnce
		if raw.Scope != nil {
			scope = *raw.Scope
		}
		if scope != approvalScopeOnce && scope != approvalScopeAlways {
			return nil, fmt.Errorf("approval_result scope must be %q or %q, not %q", approvalScopeOnce, approvalScopeAlways, scope)
		}
		return approvalResultMessage{ApprovalID: raw.ApprovalID, Approved: *raw.Approved, Scope: scope}, nil
	default:
		return nil, fmt.Errorf("unknown message type %q", envelope.Type)
	}
}

// voiceCommandIDOfARefusedLine is the taskID of a voice_command line that parseInboundMessage refused, or "" when the
// line is some other message or its taskID cannot be read.
func voiceCommandIDOfARefusedLine(line []byte) string {
	var envelope struct {
		Type   string `json:"type"`
		TaskID string `json:"taskID"`
	}
	if json.Unmarshal(line, &envelope) != nil || envelope.Type != "voice_command" {
		return ""
	}
	return envelope.TaskID
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

// toolCallMessage asks the app to run one of the app's tools. Input is the model's JSON object for the tool. TurnIndex,
// counted from 0, is set only for a voice command's call, since the app lets only the first turn answer an approval.
type toolCallMessage struct {
	Type      string          `json:"type"`
	TaskID    string          `json:"taskID"`
	ToolUseID string          `json:"toolUseID"`
	Name      toolName        `json:"name"`
	Input     json.RawMessage `json:"input"`
	TurnIndex *int            `json:"turnIndex,omitempty"`
}

// approvalRequestMessage asks the app whether the learner allows one tool call, which waits until approval_result
// arrives. Capability is "sends", "deletes", "spends", or "reads_private". Summary says in plain words what the call will
// do, and the harness writes it from the call's own input.
type approvalRequestMessage struct {
	Type       string     `json:"type"`
	TaskID     string     `json:"taskID"`
	ApprovalID string     `json:"approvalID"`
	Capability capability `json:"capability"`
	Summary    string     `json:"summary"`
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

// voiceCommandFinishedMessage ends a voice command. SpokenLine is what Clicky says, which may be empty, and GaveUp is
// true when the last turn still needed the model, so Clicky says its apology instead.
type voiceCommandFinishedMessage struct {
	Type       string `json:"type"`
	TaskID     string `json:"taskID"`
	SpokenLine string `json:"spokenLine"`
	GaveUp     bool   `json:"gaveUp"`
}

// approvalSettledMessage tells the app which answer the gate took for a request, whoever gave it: a click's
// approval_result or a voice command's answer_approval. The first answer wins, so this is the one outcome the app's
// desk shows, and the desk drops the request's card only when it arrives. Scope is "always" only for a yes the learner
// asked to remember, since a no is never remembered.
type approvalSettledMessage struct {
	Type       string `json:"type"`
	ApprovalID string `json:"approvalID"`
	Approved   bool   `json:"approved"`
	Scope      string `json:"scope"`
}

// logMessage is a line the app prints, since stdout carries only protocol lines.
type logMessage struct {
	Type string `json:"type"`
	// TaskID names the voice command the line is about, for the few lines the app acts on, and is left out of the rest.
	TaskID  string `json:"taskID,omitempty"`
	Message string `json:"message"`
}

func (readyMessage) outboundMessage()                {}
func (approvalRequestMessage) outboundMessage()      {}
func (toolCallMessage) outboundMessage()             {}
func (taskFinishedMessage) outboundMessage()         {}
func (taskFailedMessage) outboundMessage()           {}
func (logMessage) outboundMessage()                  {}
func (voiceCommandFinishedMessage) outboundMessage() {}
func (approvalSettledMessage) outboundMessage()      {}

func newReadyMessage() readyMessage {
	return readyMessage{Type: "ready"}
}

func newToolCallMessage(taskID string, toolUseID string, name toolName, input json.RawMessage) toolCallMessage {
	return toolCallMessage{Type: "tool_call", TaskID: taskID, ToolUseID: toolUseID, Name: name, Input: input}
}

// newVoiceToolCallMessage is a voice command's tool_call, which carries the turn it came from.
func newVoiceToolCallMessage(taskID string, toolUseID string, name toolName, input json.RawMessage, turnIndex int) toolCallMessage {
	message := newToolCallMessage(taskID, toolUseID, name, input)
	message.TurnIndex = &turnIndex
	return message
}

func newVoiceCommandFinishedMessage(taskID string, spokenLine string, gaveUp bool) voiceCommandFinishedMessage {
	return voiceCommandFinishedMessage{Type: "voice_command_finished", TaskID: taskID, SpokenLine: spokenLine, GaveUp: gaveUp}
}

func newApprovalSettledMessage(approvalID string, approved bool, scope string) approvalSettledMessage {
	if !approved || scope != approvalScopeAlways {
		scope = approvalScopeOnce
	}
	return approvalSettledMessage{Type: "approval_settled", ApprovalID: approvalID, Approved: approved, Scope: scope}
}

func newApprovalRequestMessage(taskID string, approvalID string, needed capability, summary string) approvalRequestMessage {
	return approvalRequestMessage{Type: "approval_request", TaskID: taskID, ApprovalID: approvalID, Capability: needed, Summary: summary}
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

// newCommandLogMessage is a log line about one voice command, which the app also reads.
func newCommandLogMessage(commandID string, message string) logMessage {
	return logMessage{Type: "log", TaskID: commandID, Message: message}
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
