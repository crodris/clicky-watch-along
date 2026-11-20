package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"sort"
	"strings"
	"sync"
	"unicode"

	"golang.org/x/net/idna"
)

// A tool that reads private data or moves data out of the Mac does not run until the learner approves it. The rule is
// in this code and not in the prompt, so a web page, a clipboard, or an MCP server that talks the model into a call
// still cannot make the call run.
//
// Each tool carries a capability. None runs freely. The others each need an approval:
//   - sends: puts something where someone else can see it or where it changes a thing (a message, a page, a link opened
//     with data in it, the clipboard text a later paste uses).
//   - deletes: removes something.
//   - spends: costs money.
//   - reads_private: reads what the learner never offered to the agent (the screen, the clipboard).
type capability string

const (
	capabilityNone         capability = "none"
	capabilitySends        capability = "sends"
	capabilityDeletes      capability = "deletes"
	capabilitySpends       capability = "spends"
	capabilityReadsPrivate capability = "reads_private"
)

func (kind capability) needsApproval() bool {
	return kind != capabilityNone
}

// appToolCapabilities is every tool the app runs, and what each may do. A tool missing from it is not the app's.
var appToolCapabilities = map[toolName]capability{
	reportStepTool:        capabilityNone,
	readVideoCaptionsTool: capabilityNone,
	// Cropped to the video's area, so a page that asks for it learns nothing else on the screen.
	lookAtVideoTool: capabilityNone,
	// The whole screen, which can hold anything.
	takeScreenshotTool: capabilityReadsPrivate,
	readClipboardTool:  capabilityReadsPrivate,
	// A page could plant a command the learner later pastes.
	writeClipboardTool: capabilitySends,
	// A link can carry data out in its address.
	openURLTool: capabilitySends,
	// A private page in the learner's own Notion, which no one else reads, so nothing leaves the learner.
	writeNotionPageTool: capabilityNone,
}

// capability is what an MCP server's own annotations say about its tool, which is the best claim there is. No server tool
// runs freely. A tool that says it is read only reads private data, since it can read the learner's files or mail, and
// its input can carry what another tool read to a server that only claims to read. One that says it is destructive
// deletes. Anything else, including a tool with no annotations, sends.
func (tool mcpTool) capability() capability {
	switch {
	case tool.annotations != nil && tool.annotations.ReadOnlyHint:
		return capabilityReadsPrivate
	case tool.annotations != nil && tool.annotations.DestructiveHint != nil && *tool.annotations.DestructiveHint:
		return capabilityDeletes
	default:
		return capabilitySends
	}
}

// approvalPhase is where one gated tool call stands. Every call starts in one of two phases, and the phases that end
// the wait never change.
type approvalPhase int

const (
	// approvalNotRequired: the tool has no capability, so it runs.
	approvalNotRequired approvalPhase = iota
	// approvalAlreadyGranted: the learner said "always" for this tool and capability earlier, so it runs.
	approvalAlreadyGranted
	// approvalAwaitingAnswer: the request went to the app, and the tool waits.
	approvalAwaitingAnswer
	// approvalGiven: the learner approved, so it runs.
	approvalGiven
	// approvalDeclined: the learner declined, so it does not run.
	approvalDeclined
	// approvalAbandoned: the task ended while the tool waited, so it does not run.
	approvalAbandoned
)

// startingPhase is the phase of a call before anything is asked.
func startingPhase(needed capability, hasStandingGrant bool) approvalPhase {
	switch {
	case !needed.needsApproval():
		return approvalNotRequired
	case hasStandingGrant:
		return approvalAlreadyGranted
	default:
		return approvalAwaitingAnswer
	}
}

// afterAnswer is the phase once the app answers. Only a waiting call changes, so a late or repeated answer to a call
// that already ended changes nothing.
func (phase approvalPhase) afterAnswer(approved bool) approvalPhase {
	if phase != approvalAwaitingAnswer {
		return phase
	}
	if approved {
		return approvalGiven
	}
	return approvalDeclined
}

// afterTaskEnds is the phase when the task is cancelled or ends. Only a waiting call changes.
func (phase approvalPhase) afterTaskEnds() approvalPhase {
	if phase != approvalAwaitingAnswer {
		return phase
	}
	return approvalAbandoned
}

func (phase approvalPhase) mayRun() bool {
	return phase == approvalNotRequired || phase == approvalAlreadyGranted || phase == approvalGiven
}

// standingGrantKey is what "always" covers: one tool at one capability, so approving one tool never approves another.
type standingGrantKey struct {
	capability capability
	tool       toolName
}

// approvalGate asks the app for approval and remembers "always" answers for the life of the harness process.
type approvalGate struct {
	mutex          sync.Mutex
	standingGrants map[standingGrantKey]bool
	waiting        map[string]chan approvalResultMessage
}

// newApprovalID is random, not a count. A count starts again at 1 in a new harness process, so an answer the app still
// holds for a request of the process that exited could match a new request and approve it.
func newApprovalID() string {
	randomBytes := make([]byte, 16)
	if _, err := rand.Read(randomBytes); err != nil {
		panic("harness: no random bytes for an approval ID: " + err.Error())
	}
	return "approval-" + hex.EncodeToString(randomBytes)
}

func newApprovalGate() *approvalGate {
	return &approvalGate{standingGrants: map[standingGrantKey]bool{}, waiting: map[string]chan approvalResultMessage{}}
}

// authorize decides whether one call may run. For a call that needs an answer it sends approval_request through send
// and waits for approval_result or for the task to end. It returns the phase the call ended in.
func (gate *approvalGate) authorize(
	taskContext context.Context,
	taskID string,
	tool toolName,
	needed capability,
	summary string,
	send func(outboundMessage),
) approvalPhase {
	key := standingGrantKey{capability: needed, tool: tool}
	gate.mutex.Lock()
	phase := startingPhase(needed, gate.standingGrants[key])
	if phase != approvalAwaitingAnswer {
		gate.mutex.Unlock()
		return phase
	}
	approvalID := newApprovalID()
	answers := make(chan approvalResultMessage, 1)
	gate.waiting[approvalID] = answers
	gate.mutex.Unlock()

	send(newApprovalRequestMessage(taskID, approvalID, needed, summary))

	select {
	case answer := <-answers:
		phase = phase.afterAnswer(answer.Approved)
		// A "no" is never remembered, whatever its scope says.
		if phase == approvalGiven && answer.Scope == approvalScopeAlways {
			gate.mutex.Lock()
			gate.standingGrants[key] = true
			gate.mutex.Unlock()
		}
	case <-taskContext.Done():
		phase = phase.afterTaskEnds()
		gate.mutex.Lock()
		delete(gate.waiting, approvalID)
		gate.mutex.Unlock()
	}
	return phase
}

// deliver hands an answer to the call that waits for it. It returns false for an answer that matches no waiting call,
// such as one that arrives after its task ended.
func (gate *approvalGate) deliver(answer approvalResultMessage) bool {
	gate.mutex.Lock()
	answers, isWaiting := gate.waiting[answer.ApprovalID]
	delete(gate.waiting, answer.ApprovalID)
	gate.mutex.Unlock()
	if isWaiting {
		answers <- answer
	}
	return isWaiting
}

// declinedToolResult is what the model reads when a tool did not run because the learner said no.
const declinedToolResult = "The learner declined this action, so it did not run. Do not try it again or look for a way around it. Say in your answer what you could not do."

// A summary shows what the learner approves, all of it. A call whose payload is too long to show in full is refused
// instead of approved on a cut summary, since a cut could hide the part that does the harm.
const (
	// The most characters of clipboard text a write_clipboard call may carry.
	longestClipboardWrite = 500
	// The most characters of JSON input an MCP tool call may carry.
	longestMCPInput = 1500
)

// decodedToolInput reads a tool call's input as one JSON object, with each number kept as the digits it was sent in, so
// a summary never shows a rounded number. It is false for anything else, trailing data included.
func decodedToolInput(raw json.RawMessage) (map[string]any, bool) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var input map[string]any
	if decoder.Decode(&input) != nil || input == nil {
		return nil, false
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, false
	}
	return input, true
}

// canonicalToolInput encodes a call's input again from the value decodedToolInput reads, and that encoding is what the
// app or a server receives. The check, the summary, and the run then read the same bytes, even for an input with a key
// written twice, where Go keeps the last value and another reader might keep the first. An empty input is {}, and an
// input that is not an object stays as it is for approvalRefusal to refuse.
func canonicalToolInput(raw json.RawMessage) json.RawMessage {
	if len(bytes.TrimSpace(raw)) == 0 {
		return json.RawMessage("{}")
	}
	input, isObject := decodedToolInput(raw)
	if !isObject {
		return raw
	}
	encoded, err := json.Marshal(input)
	if err != nil {
		return raw
	}
	return encoded
}

// approvalRefusal is why a call that needs approval cannot even be asked about, or "" when it can. The reason goes to the
// model as an error result, so it can send something shorter.
func approvalRefusal(call toolCall, server *mcpTool) string {
	input, inputIsObject := decodedToolInput(call.Input)
	if !inputIsObject {
		return "The tool input is not a JSON object."
	}
	switch {
	case server != nil:
		if length := len([]rune(string(call.Input))); length > longestMCPInput {
			return fmt.Sprintf("The tool input is %d characters, and the learner cannot read more than %d before approving it. Call the tool with less.", length, longestMCPInput)
		}
	case call.Name == writeClipboardTool:
		text, _ := input["text"].(string)
		if length := len([]rune(text)); length > longestClipboardWrite {
			return fmt.Sprintf("The text is %d characters, and the learner cannot read more than %d before approving it. Copy a shorter text.", length, longestClipboardWrite)
		}
	}
	return ""
}

// approvalSummary says in plain words what the tool is about to do, from the call's own input. The summary is built
// here and never taken from the model or a server, since either could write a harmless one for a harmful call. It runs
// only for a call approvalRefusal let through, so it never cuts what it shows.
func approvalSummary(call toolCall, server *mcpTool) string {
	input, _ := decodedToolInput(call.Input)
	text := func(field string) string {
		value, _ := input[field].(string)
		return cleanForSummary(value)
	}

	if server != nil {
		return fmt.Sprintf("Use the %q tool of the %q server, which %s, with:\n%s",
			server.toolName, server.serverName, server.capability().meaning(), mcpArgumentLines(input, server.inputSchema))
	}
	switch call.Name {
	case openURLTool:
		return openURLSummary(text("url"))
	case writeClipboardTool:
		clipboardText := text("text")
		return fmt.Sprintf("Replace your clipboard with this text (%d characters):\n%s", len([]rune(clipboardText)), clipboardText)
	case readClipboardTool:
		return "Read the text on your clipboard."
	case takeScreenshotTool:
		return "Take a picture of your whole screen, on the display your mouse is on."
	default:
		return fmt.Sprintf("Run %s, which %s.", call.Name, appToolCapabilities[call.Name].meaning())
	}
}

// openURLSummary names the host on its own line in Punycode, so a lookalike letter shows as the xn-- name it really
// is, then the whole link. linkText is already cleaned of invisible characters.
func openURLSummary(linkText string) string {
	parsed, err := url.Parse(linkText)
	if err != nil || parsed.Hostname() == "" {
		return "Open this link in your browser (it has no host that can be read):\n" + linkText
	}
	host, err := idna.ToASCII(parsed.Hostname())
	if err != nil {
		host = cleanForSummary(parsed.Hostname()) + " (this host name is not valid)"
	}
	if port := parsed.Port(); port != "" {
		host += ":" + port
	}
	return fmt.Sprintf("Open this link in your browser.\nHost: %s\nLink: %s", host, linkText)
}

// mcpArgumentLines shows every argument as one "key: value" line. The tool's required fields come first, in the schema's
// order, then the others by name. A string shows as it is, and anything else as JSON.
func mcpArgumentLines(input map[string]any, schema map[string]any) string {
	var orderedKeys []string
	seen := map[string]bool{}
	if requiredNames, isList := schema["required"].([]any); isList {
		for _, requiredName := range requiredNames {
			if key, isText := requiredName.(string); isText {
				if _, present := input[key]; present && !seen[key] {
					orderedKeys = append(orderedKeys, key)
					seen[key] = true
				}
			}
		}
	}
	var otherKeys []string
	for key := range input {
		if !seen[key] {
			otherKeys = append(otherKeys, key)
		}
	}
	sort.Strings(otherKeys)
	orderedKeys = append(orderedKeys, otherKeys...)
	if len(orderedKeys) == 0 {
		return "(no arguments)"
	}

	lines := make([]string, 0, len(orderedKeys))
	for _, key := range orderedKeys {
		var valueText string
		if textValue, isText := input[key].(string); isText {
			valueText = cleanForSummary(textValue)
		} else {
			encoded, _ := json.Marshal(input[key])
			valueText = cleanForSummary(string(encoded))
		}
		lines = append(lines, cleanForSummary(key)+": "+valueText)
	}
	return strings.Join(lines, "\n")
}

// meaning is the capability in words an approval summary can carry.
func (kind capability) meaning() string {
	switch kind {
	case capabilitySends:
		return "can send or change something"
	case capabilityDeletes:
		return "can delete something"
	case capabilitySpends:
		return "can spend money"
	case capabilityReadsPrivate:
		return "reads private data"
	default:
		return "changes nothing"
	}
}

// cleanForSummary makes every character visible. A newline shows as ⏎ and a tab as \t, so text cannot hide behind
// whitespace. A character the learner could not see, such as a right-to-left override, a zero-width space, or any
// format or unprintable character, shows as \u{XXXX}.
func cleanForSummary(text string) string {
	var cleaned strings.Builder
	for _, character := range text {
		switch {
		case character == '\n':
			cleaned.WriteString("⏎")
		case character == '\t':
			cleaned.WriteString(`\t`)
		case character == '\r':
			cleaned.WriteString(`\r`)
		// Go's IsPrint already rejects every Cf character. The Cf test stays so the rule does not depend on that detail.
		case unicode.Is(unicode.Cf, character) || !unicode.IsPrint(character):
			fmt.Fprintf(&cleaned, `\u{%04X}`, character)
		default:
			cleaned.WriteRune(character)
		}
	}
	return cleaned.String()
}
