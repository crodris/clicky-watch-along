package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/anthropics/anthropic-sdk-go"
)

// This file is the brain's memory. The harness process holds one session for its whole life, since one learner means
// one session, and a command reads it and adds to it. The session lives in memory only and never on disk, so an app
// launch, or a harness relaunch after a crash, starts it empty.

const (
	// mostToolResultCharacters is how much of one tool result the history keeps. A caption search can return far more
	// than a later command needs, and every kept character is paid for again on each later request.
	mostToolResultCharacters = 2000

	// cacheLifetime is how long Anthropic keeps a cached prefix after the last request that read it.
	cacheLifetime = 5 * time.Minute

	// commandsKeptWholeInAFold is how many of the newest commands a fold leaves untouched.
	commandsKeptWholeInAFold = 6

	// mostCommandsBeforeAFold is the cap on whole commands in the session. A fold otherwise waits for a cold cache, since
	// it rewrites the start of the history and so throws away a warm cache.
	mostCommandsBeforeAFold = 24

	// mostFoldedCommandsKept is how many folded commands the fold block lists, newest first to stay. The block sits at the
	// start of every request, and a cold cache is normal while a learner watches a video, so each command after a pause
	// pays full price for the whole block. Without a cap it grows with every command, and after a few thousand commands
	// the request passes the context window and every later command fails until the harness restarts. At about 200
	// characters a command, 40 commands are about 2,000 tokens.
	mostFoldedCommandsKept = 40

	handedOffResultText = "Handed off: the app took this request over and answers it itself."
	notRunResultText    = "Not run: the request was handed off"
	// notRunAfterAFailureResultText answers each call that follows a failed call in the same reply.
	notRunAfterAFailureResultText = "Not run: an earlier call in this reply failed"
)

// sessionCommand is one command the session keeps. Its messages are the user message with the learner's words, then
// the model's turns and the tool results, in order. A folded command keeps no messages, only what a fold writes down.
type sessionCommand struct {
	transcript string
	// interruptedBefore are the action lines of earlier interrupted commands that this command's user message carried.
	interruptedBefore []string
	// actionLines are the lines of the tool calls that ran, in the app's recent action format.
	actionLines []string
	messages    []anthropic.MessageParam
}

// brainSession holds the messages of the commands so far. A command works on a snapshot (sessionRun) and writes back
// only when it ends whole, so a command the learner cancels leaves no trace. The mutex lets reset_session and
// seed_session, which the stdin reader handles, change the session while a command runs.
type brainSession struct {
	mutex sync.Mutex
	now   func() time.Time
	// foldedCommands are the newest commands a fold turned into text, oldest first, at most mostFoldedCommandsKept.
	foldedCommands []sessionCommand
	// droppedFoldedCommands counts the older folded commands the cap pushed out, which the fold block says in one line.
	droppedFoldedCommands int
	commands              []sessionCommand
	// interruptedActionLines are the lines of calls that finished in cancelled commands since the last command that
	// stayed. The next command's user message tells the model about them.
	interruptedActionLines []string
	// appliedChanges are the calls that changed the screen, newest first, at most mostAppliedChangesKept. undo_last_change
	// reads them (brainundo.go). They include the calls of cancelled commands, which did change the screen, and a call a
	// cancel caught while the app ran it, which has no inverse. An undo removes the change it reversed.
	appliedChanges []appliedChange
	lastRequestAt  time.Time
	// generation changes when the session is reset or seeded, so a command that began before that never writes back.
	generation int
}

func newBrainSession(now func() time.Time) *brainSession {
	return &brainSession{now: now}
}

// reset empties the session.
func (session *brainSession) reset() {
	session.mutex.Lock()
	defer session.mutex.Unlock()
	session.foldedCommands = nil
	session.droppedFoldedCommands = 0
	session.commands = nil
	session.interruptedActionLines = nil
	session.appliedChanges = nil
	session.lastRequestAt = time.Time{}
	session.generation++
}

// seed replaces the session with the messages of earlier commands, with no model call, so a bench run starts from the
// same history every time. The cache counts as warm, so only the cap folds a seeded session.
func (session *brainSession) seed(messages []anthropic.MessageParam, interruptedActionLines []string) error {
	commands, err := commandsOfSeededMessages(messages)
	if err != nil {
		return err
	}
	session.mutex.Lock()
	defer session.mutex.Unlock()
	session.foldedCommands = nil
	session.droppedFoldedCommands = 0
	session.commands = commands
	session.interruptedActionLines = slices.Clone(interruptedActionLines)
	session.appliedChanges = appliedChangesOfASeed(messages, interruptedActionLines)
	session.lastRequestAt = session.now()
	session.generation++
	return nil
}

// noteRequest records that a request went out, which keeps the cache warm.
func (session *brainSession) noteRequest(sentAt time.Time) {
	session.mutex.Lock()
	defer session.mutex.Unlock()
	session.lastRequestAt = sentAt
}

// cachePosition is a content block of a request, which carries a cache breakpoint.
type cachePosition struct {
	messageIndex int
	blockIndex   int
}

// sessionRun is one command's view of the session. history is what the session held when the command began. own is the
// command's messages so far, whose first is the user message with the learner's words.
type sessionRun struct {
	session    *brainSession
	generation int
	history    []anthropic.MessageParam
	// breakpoint is the last block of the previous command, or nil for an empty session.
	breakpoint        *cachePosition
	transcript        string
	interruptedBefore []string
	own               []anthropic.MessageParam
	actionLines       []string
	// scene is what the command saw on screen, which each change it makes is recorded against (brainundo.go).
	scene sceneIdentity
	// pageMayStillRefuseChanges is true when the scene state said the page's tour has not finished, while a pop-out may
	// still be building and a landmark refuses every move, so a page call a press cut off may not have run (brainundo.go).
	pageMayStillRefuseChanges bool
	// changes is the session's record of applied changes as this command sees it, minus the ones that no longer match the
	// scene (changesThatStillApply): a copy that the command's own calls update, which replaces the session's when the
	// command ends, whole or cancelled.
	changes []appliedChange
}

// begin starts a command. It folds old commands first when the cache is cold or the session holds too many, then
// copies what the model will read.
func (session *brainSession) begin(transcript string, sceneState json.RawMessage) *sessionRun {
	session.mutex.Lock()
	defer session.mutex.Unlock()

	cacheIsCold := session.now().Sub(session.lastRequestAt) >= cacheLifetime
	if len(session.commands) > commandsKeptWholeInAFold && (cacheIsCold || len(session.commands) > mostCommandsBeforeAFold) {
		session.foldAllButTheNewestCommands()
	}

	var history []anthropic.MessageParam
	for _, command := range session.commands {
		history = append(history, command.messages...)
	}
	if len(session.foldedCommands) > 0 && len(history) > 0 {
		history[0] = withTextBlockFirst(history[0], foldBlockText(session.foldedCommands, session.droppedFoldedCommands))
	}
	var breakpoint *cachePosition
	if len(history) > 0 {
		lastMessageIndex := len(history) - 1
		breakpoint = &cachePosition{messageIndex: lastMessageIndex, blockIndex: len(history[lastMessageIndex].Content) - 1}
	}

	interruptedBefore := slices.Clone(session.interruptedActionLines)
	scene := sceneIdentityOf(sceneState)
	pageMayStillRefuseChanges := pageTourIsStillGoing(sceneState)
	return &sessionRun{
		session:                   session,
		generation:                session.generation,
		history:                   history,
		breakpoint:                breakpoint,
		transcript:                transcript,
		interruptedBefore:         interruptedBefore,
		own:                       []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock(brainUserMessageText(transcript, sceneState, interruptedBefore)))},
		scene:                     scene,
		changes:                   changesThatStillApply(session.appliedChanges, scene),
		pageMayStillRefuseChanges: pageMayStillRefuseChanges,
	}
}

// foldAllButTheNewestCommands turns every command but the newest few into text, and drops the oldest folded commands
// past mostFoldedCommandsKept. The caller holds the mutex.
func (session *brainSession) foldAllButTheNewestCommands() {
	foldedCount := len(session.commands) - commandsKeptWholeInAFold
	for _, command := range session.commands[:foldedCount] {
		command.messages = nil
		session.foldedCommands = append(session.foldedCommands, command)
	}
	session.commands = slices.Clone(session.commands[foldedCount:])
	if overflow := len(session.foldedCommands) - mostFoldedCommandsKept; overflow > 0 {
		session.droppedFoldedCommands += overflow
		session.foldedCommands = slices.Clone(session.foldedCommands[overflow:])
	}
}

// foldBlockText is the one text block that stands for every folded command: per command, what the learner said and what
// it did, with the scene states and tool results left out. Every piece is escaped as one line, since an action line can
// hold a tool's error text or the model's own input, which repeat page text, and nothing in it may close the
// earlier_commands tag or start a line that reads as the learner's words. When the cap dropped older commands, the
// first line says how many, so the model knows the list starts partway through the session.
func foldBlockText(foldedCommands []sessionCommand, droppedCommandCount int) string {
	var block strings.Builder
	block.WriteString("<" + earlierCommandsTag + ">")
	if droppedCommandCount > 0 {
		fmt.Fprintf(&block, "\n%d older commands are not listed", droppedCommandCount)
	}
	for _, command := range foldedCommands {
		block.WriteString("\n")
		if len(command.interruptedBefore) > 0 {
			block.WriteString(taggedLine(interruptedBeforeTag, strings.Join(command.interruptedBefore, "; ")) + "\n")
		}
		block.WriteString(taggedLine(learnerWordsTag, command.transcript))
		for _, actionLine := range command.actionLines {
			block.WriteString("\n" + escapedLine(actionLine))
		}
	}
	block.WriteString("\n</" + earlierCommandsTag + ">")
	return block.String()
}

// withTextBlockFirst is the message with one more text block before its own. The message it came from is not changed.
func withTextBlockFirst(message anthropic.MessageParam, text string) anthropic.MessageParam {
	message.Content = append([]anthropic.ContentBlockParamUnion{anthropic.NewTextBlock(text)}, message.Content...)
	return message
}

// requestMessages is what one turn's request carries: the history, the command's own messages, and the cache
// breakpoint on the last block of the previous command. The user message of this command joins a trailing user message
// of the history, since the API reads two user messages in a row as one and a tool result must stay first in it.
func (run *sessionRun) requestMessages() []anthropic.MessageParam {
	messages := slices.Clone(run.history)
	if run.breakpoint != nil {
		messages[run.breakpoint.messageIndex] = withBreakpointOnBlock(messages[run.breakpoint.messageIndex], run.breakpoint.blockIndex)
	}
	firstOwnMessage := run.own[0]
	if len(messages) > 0 && messages[len(messages)-1].Role == anthropic.MessageParamRoleUser {
		last := messages[len(messages)-1]
		last.Content = append(slices.Clone(last.Content), firstOwnMessage.Content...)
		messages[len(messages)-1] = last
	} else {
		messages = append(messages, firstOwnMessage)
	}
	return append(messages, run.own[1:]...)
}

// withBreakpointOnBlock is the message with a cache breakpoint on one block. The block is copied, because the session's
// own message must keep no breakpoint: only the previous command's last block carries one, and only in a request.
func withBreakpointOnBlock(message anthropic.MessageParam, blockIndex int) anthropic.MessageParam {
	content := slices.Clone(message.Content)
	block := content[blockIndex]
	breakpoint := anthropic.NewCacheControlEphemeralParam()
	switch {
	case block.OfText != nil:
		copied := *block.OfText
		copied.CacheControl = breakpoint
		content[blockIndex] = anthropic.ContentBlockParamUnion{OfText: &copied}
	case block.OfToolUse != nil:
		copied := *block.OfToolUse
		copied.CacheControl = breakpoint
		content[blockIndex] = anthropic.ContentBlockParamUnion{OfToolUse: &copied}
	case block.OfToolResult != nil:
		copied := *block.OfToolResult
		copied.CacheControl = breakpoint
		content[blockIndex] = anthropic.ContentBlockParamUnion{OfToolResult: &copied}
	}
	message.Content = content
	return message
}

// addReply keeps the model's turn. The API refuses an empty text block and an empty message, and a refusal would make
// every later command fail, so neither enters the session.
func (run *sessionRun) addReply(reply turn) {
	var content []anthropic.ContentBlockParamUnion
	for _, block := range reply.message.ToParam().Content {
		if block.OfText != nil && strings.TrimSpace(block.OfText.Text) == "" {
			continue
		}
		content = append(content, block)
	}
	if len(content) > 0 {
		run.own = append(run.own, anthropic.NewAssistantMessage(content...))
	}
}

// addToolResults keeps the results of a turn's calls, one block for each call, so every tool_use has its tool_result.
func (run *sessionRun) addToolResults(toolResultBlocks []anthropic.ContentBlockParamUnion) {
	if len(toolResultBlocks) > 0 {
		run.own = append(run.own, anthropic.NewUserMessage(toolResultBlocks...))
	}
}

// commit keeps the command, with each tool result cut. A command the session was reset under writes nothing.
func (run *sessionRun) commit() {
	run.session.mutex.Lock()
	defer run.session.mutex.Unlock()
	if run.generation != run.session.generation {
		return
	}
	run.session.commands = append(run.session.commands, sessionCommand{
		transcript:        run.transcript,
		interruptedBefore: run.interruptedBefore,
		actionLines:       run.actionLines,
		messages:          withToolResultsCut(run.own),
	})
	run.session.interruptedActionLines = nil
	run.session.appliedChanges = run.changes
}

// abandon rolls the command back: its messages never reach the session. The calls that finished did change the screen,
// so their action lines wait for the next command's user message, after the lines an earlier interrupted command left,
// and their changes join the record of applied changes, so "undo that" can reverse them.
func (run *sessionRun) abandon() {
	run.session.mutex.Lock()
	defer run.session.mutex.Unlock()
	if run.generation != run.session.generation {
		return
	}
	run.session.interruptedActionLines = append(slices.Clone(run.interruptedBefore), run.actionLines...)
	run.session.appliedChanges = run.changes
}

// withToolResultsCut is the messages with every tool result's text cut to mostToolResultCharacters. The limit is shared by
// a result's text items. The API refuses an empty text block, and one refusal would fail every later command, so an
// item with no text left is dropped, and an item that lost all of its budget keeps only the cut marker.
func withToolResultsCut(messages []anthropic.MessageParam) []anthropic.MessageParam {
	cut := make([]anthropic.MessageParam, len(messages))
	for messageIndex, message := range messages {
		content := slices.Clone(message.Content)
		for blockIndex, block := range content {
			if block.OfToolResult == nil {
				continue
			}
			copied := *block.OfToolResult
			copied.Content = nil
			charactersLeft := mostToolResultCharacters
			for _, item := range block.OfToolResult.Content {
				if item.OfText == nil {
					copied.Content = append(copied.Content, item)
					continue
				}
				copiedItem := *item.OfText
				copiedItem.Text, charactersLeft = textCutTo(copiedItem.Text, charactersLeft)
				if copiedItem.Text == "" {
					continue
				}
				copied.Content = append(copied.Content, anthropic.ToolResultBlockParamContentUnion{OfText: &copiedItem})
			}
			content[blockIndex] = anthropic.ContentBlockParamUnion{OfToolResult: &copied}
		}
		message.Content = content
		cut[messageIndex] = message
	}
	return cut
}

const cutMarker = "...[cut]"

// textCutTo is the text shortened to at most limit characters, ending in a marker when it was cut, and how many
// characters are left for the next piece. Text cut when the budget is nearly gone becomes the marker alone, which can
// pass the limit by a few characters, so the text is never empty unless it was empty to begin with.
func textCutTo(text string, limit int) (string, int) {
	characterCount := utf8.RuneCountInString(text)
	if characterCount <= limit {
		return text, limit - characterCount
	}
	if limit <= len(cutMarker) {
		return cutMarker, 0
	}
	return string([]rune(text)[:limit-len(cutMarker)]) + cutMarker, 0
}

// voiceToolActionLine is one tool call in the app's recent action format, so the model reads it as the old path did:
// the name, the input without the confirmation, and "ok" or "failed: <why>". resultText is the app's result text. The
// reason is a tool's error text, which can repeat page text. The line is stored raw and escaped once, where it is written
// into a tag (taggedLine) or the fold (escapedLine), since escaping twice doubles every backslash again.
func voiceToolActionLine(call toolCall, outcome voiceToolOutcome, resultText string) string {
	resultWord := "ok"
	if outcome == voiceToolFailed {
		resultWord = "failed: " + failureReasonOf(resultText)
	}
	return fmt.Sprintf("%s %s -> %s", call.Name, inputWithoutConfirmation(call.Input), resultWord)
}

// cutOffResultWord is the result word of a call a press cancelled while the app was still running it. The call may have
// changed the screen, so the next command's interrupted_before tag says so, and the model does not reverse an older move
// as if the cut-off call had not happened.
const cutOffResultWord = "cut off, may have run"

// voiceToolCutOffActionLine is the action line of a call a press cancelled before the app answered, in the same format as
// voiceToolActionLine so appliedChangeOfActionLine reads it back.
func voiceToolCutOffActionLine(call toolCall) string {
	return fmt.Sprintf("%s %s -> %s", call.Name, inputWithoutConfirmation(call.Input), cutOffResultWord)
}

// failureReasonOf is the error text of a failed tool's result, which the app writes as {"error": "...", "ok": false}.
func failureReasonOf(resultText string) string {
	var result struct {
		Error string `json:"error"`
	}
	if json.Unmarshal([]byte(resultText), &result) == nil && result.Error != "" {
		return result.Error
	}
	return strings.TrimSpace(resultText)
}

// commandsOfSeededMessages splits the messages of earlier commands into commands. A command starts at a user message
// that is not a tool result. The action lines and the learner's words come from the messages, since a fold writes them down.
func commandsOfSeededMessages(messages []anthropic.MessageParam) ([]sessionCommand, error) {
	var commands []sessionCommand
	for _, message := range messages {
		startsACommand := message.Role == anthropic.MessageParamRoleUser && !slices.ContainsFunc(message.Content, func(block anthropic.ContentBlockParamUnion) bool { return block.OfToolResult != nil })
		if startsACommand {
			commands = append(commands, sessionCommand{})
		}
		if len(commands) == 0 {
			return nil, errors.New("the first seeded message must be a user message with the learner's words")
		}
		commands[len(commands)-1].messages = append(commands[len(commands)-1].messages, message)
	}
	for messageIndex, message := range messages {
		if len(message.Content) == 0 {
			return nil, fmt.Errorf("seeded message %d is empty, which the API refuses", messageIndex)
		}
		if message.Role != anthropic.MessageParamRoleAssistant {
			continue
		}
		for _, block := range message.Content {
			if block.OfToolUse == nil {
				continue
			}
			if messageIndex+1 >= len(messages) {
				return nil, fmt.Errorf("seeded tool_use %s has no tool_result after it", block.OfToolUse.ID)
			}
			if _, _, found := toolResultOf(messages[messageIndex+1], block.OfToolUse.ID); !found {
				return nil, fmt.Errorf("seeded tool_use %s has no tool_result in the next message", block.OfToolUse.ID)
			}
		}
	}
	for commandIndex := range commands {
		commands[commandIndex].transcript = learnerWordsOf(commands[commandIndex].messages[0])
		commands[commandIndex].actionLines = actionLinesOfMessages(commands[commandIndex].messages)
	}
	return commands, nil
}

// learnerWordsOf reads the words out of a user message written by brainUserMessageText.
func learnerWordsOf(userMessage anthropic.MessageParam) string {
	for _, block := range userMessage.Content {
		if block.OfText == nil {
			continue
		}
		text := block.OfText.Text
		if _, afterTag, found := strings.Cut(text, "<"+learnerWordsTag+">"); found {
			words, _, _ := strings.Cut(afterTag, "</"+learnerWordsTag+">")
			return unescapedLine(words)
		}
		return text
	}
	return ""
}

// unescapedLine undoes escapedLine's backslash and line break escapes, so words read back out of a seeded message are
// escaped once more, and only once, when the fold writes them. A "‹" stays, since escaping it again changes nothing.
func unescapedLine(escapedText string) string {
	var text strings.Builder
	for index := 0; index < len(escapedText); index++ {
		if escapedText[index] == '\\' && index+1 < len(escapedText) {
			switch escapedText[index+1] {
			case '\\':
				text.WriteByte('\\')
				index++
				continue
			case 'n':
				text.WriteByte('\n')
				index++
				continue
			}
		}
		text.WriteByte(escapedText[index])
	}
	return text.String()
}

// actionLinesOfMessages writes the action line of each tool call that has a result, in order.
func actionLinesOfMessages(messages []anthropic.MessageParam) []string {
	var lines []string
	for messageIndex, message := range messages {
		if message.Role != anthropic.MessageParamRoleAssistant || messageIndex+1 >= len(messages) {
			continue
		}
		for _, block := range message.Content {
			if block.OfToolUse == nil {
				continue
			}
			isError, resultText, found := toolResultOf(messages[messageIndex+1], block.OfToolUse.ID)
			if !found {
				continue
			}
			input, _ := json.Marshal(block.OfToolUse.Input)
			outcome := voiceToolChanged
			if isError {
				outcome = voiceToolFailed
			}
			lines = append(lines, voiceToolActionLine(toolCall{ID: block.OfToolUse.ID, Name: toolName(block.OfToolUse.Name), Input: input}, outcome, resultText))
		}
	}
	return lines
}

// toolResultOf finds the result for a tool_use ID in a user message.
func toolResultOf(userMessage anthropic.MessageParam, toolUseID string) (isError bool, resultText string, found bool) {
	for _, block := range userMessage.Content {
		if block.OfToolResult == nil || block.OfToolResult.ToolUseID != toolUseID {
			continue
		}
		var texts []string
		for _, item := range block.OfToolResult.Content {
			if item.OfText != nil {
				texts = append(texts, item.OfText.Text)
			}
		}
		return block.OfToolResult.IsError.Value, strings.Join(texts, "\n"), true
	}
	return false, "", false
}
