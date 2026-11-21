package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
)

// A turn that takes longer than this fails the task. The app allowed the same for one turn before the loop moved here.
const turnTimeout = 3 * time.Minute

var (
	errRanOutOfTurns     = fmt.Errorf("the agent used all %d turns without finishing", mostTaskAgentTurns)
	errEndedWithNoAnswer = errors.New("the agent ended with no answer")
)

// runningTask is the harness's record of one task: how to stop it, and where the app's tool results for it arrive.
type runningTask struct {
	cancel      context.CancelFunc
	done        <-chan struct{}
	toolResults chan toolResultMessage
	// mcpImages is what is left of the bytes of MCP result images the task may keep in its history.
	mcpImages *imageByteBudget
	// isVoiceCommand is true for a brain command (brainloop.go), which is routed like a task.
	isVoiceCommand bool
	// handOffCompletedIt is set, under the harness's tasksMutex, when the app's handedOff result for this command
	// arrives. A cancel_task read after it changes nothing, since a slow path already owns the reply.
	handOffCompletedIt bool
}

// taskRunner runs task agents. It holds no per-task state, so any number of tasks can run on one runner.
type taskRunner struct {
	client anthropic.Client
	writer *protocolWriter
	// skillsDirectories are searched in order for a task's skill.
	skillsDirectories []string
	// mcp holds the learner's MCP servers. It is nil when none are configured.
	mcp *mcpHub
	// approvals holds the learner's answers, and an always one lasts until the task that gave it ends.
	approvals *approvalGate
}

// send writes a message for a task unless the task was cancelled, since a cancelled task sends nothing more.
func (runner *taskRunner) send(taskContext context.Context, message outboundMessage) {
	if taskContext.Err() != nil {
		return
	}
	runner.writer.send(message)
}

func (runner *taskRunner) log(taskContext context.Context, text string) {
	runner.send(taskContext, newLogMessage(text))
}

// runTask runs one task to its end and reports how it ended. A cancelled task reports nothing.
func (runner *taskRunner) runTask(taskContext context.Context, task *runningTask, start startTaskMessage) {
	spokenSummary, err := runner.converse(taskContext, task, start)
	if taskContext.Err() != nil {
		return
	}
	if err != nil {
		runner.send(taskContext, newTaskFailedMessage(start.TaskID, err.Error()))
		return
	}
	runner.send(taskContext, newTaskFinishedMessage(start.TaskID, spokenSummary))
}

// converse is the loop: one request at a time, running the app's tools between requests, until the agent calls finish
// or stops. The history is append-only, because earlier turns carry thinking and server tool blocks that must go back
// unchanged.
func (runner *taskRunner) converse(taskContext context.Context, task *runningTask, start startTaskMessage) (string, error) {
	startedAt := time.Now()
	var chosenSkill *skill
	if start.Skill != nil {
		loaded, err := loadSkill(runner.skillsDirectories, *start.Skill)
		if err != nil {
			return "", err
		}
		chosenSkill = &loaded
	}
	tools, err := taskAgentTools(chosenSkill, runner.mcp.connect())
	if err != nil {
		return "", err
	}
	offered := offeredToolNames(tools)
	messages := []anthropic.MessageParam{
		anthropic.NewUserMessage(anthropic.NewTextBlock(firstMessage(start.Goal, start.FrontTabTitle, start.FrontTabURL, chosenSkill))),
	}
	var page pageOutcome
	sources := newCitableSources(start.FrontTabURL)

	for turnNumber := 1; turnNumber <= mostTaskAgentTurns; turnNumber++ {
		reply, err := runner.requestTurn(taskContext, messages, tools)
		if err != nil {
			return "", err
		}
		runner.log(taskContext, usageLine(turnNumber, reply))
		if err := failureOfTurn(reply); err != nil {
			return "", err
		}
		messages = append(messages, reply.message.ToParam())
		sources.addSearchResultsOf(reply.message)

		switch step := nextStepAfter(reply).(type) {
		case continueThePausedTurn:
			continue

		case finishTask:
			toolResults, err := runner.runToolCalls(taskContext, task, start.TaskID, step.afterRunning, offered, &page, sources)
			if err != nil {
				return "", err
			}
			// A page refused in the same turn as finish goes back to the agent with a finish that did not count, so it
			// writes the page again instead of the task ending without one.
			if finishWaitsForTheRefusedPage(step.afterRunning, page.written, turnNumber == mostTaskAgentTurns) {
				for _, finishCallID := range step.finishCallIDs {
					toolResults = append(toolResults, anthropic.NewToolResultBlock(finishCallID, "Not finished: the page was not written. Fix it, write it, then call finish again.", true))
				}
				messages = append(messages, anthropic.NewUserMessage(toolResults...))
				continue
			}
			if step.spokenSummary == "" {
				return "", errEndedWithNoAnswer
			}
			runner.log(taskContext, fmt.Sprintf("Task agent: finished in %d s after %d turns", int(time.Since(startedAt).Seconds()), turnNumber))
			return step.spokenSummary, nil

		case endedWithText:
			if step.text == "" {
				return "", errEndedWithNoAnswer
			}
			runner.log(taskContext, fmt.Sprintf("Task agent: ended without finish in %d s, so its last words are the answer", int(time.Since(startedAt).Seconds())))
			return step.text, nil

		case runTools:
			toolResults, err := runner.runToolCalls(taskContext, task, start.TaskID, step.calls, offered, &page, sources)
			if err != nil {
				return "", err
			}
			messages = append(messages, anthropic.NewUserMessage(toolResults...))
		}
	}
	return "", errRanOutOfTurns
}

// requestTurn streams one request and returns the accumulated reply, since a long reply at this token limit is not
// allowed as a plain request.
func (runner *taskRunner) requestTurn(taskContext context.Context, messages []anthropic.MessageParam, tools []anthropic.ToolUnionParam) (turn, error) {
	requestContext, cancel := context.WithTimeout(taskContext, turnTimeout)
	defer cancel()

	stream := runner.client.Messages.NewStreaming(requestContext, taskAgentRequest(messages, tools))
	defer stream.Close()

	var message anthropic.Message
	for stream.Next() {
		if err := message.Accumulate(stream.Current()); err != nil {
			return turn{}, fmt.Errorf("the reply stream was not readable: %w", err)
		}
	}
	if err := stream.Err(); err != nil {
		return turn{}, fmt.Errorf("the request to Claude failed: %w", err)
	}
	return newTurn(message), nil
}

// failureOfTurn is the error for a reply the agent cannot continue from, or nil. A refusal or a reply cut off at the
// token limit may hold half a tool call, so none of its tools run.
func failureOfTurn(reply turn) error {
	switch reply.stopReason {
	case anthropic.StopReasonRefusal:
		return errors.New("Claude refused the task")
	case anthropic.StopReasonMaxTokens:
		return fmt.Errorf("the reply was cut off at the %d token limit", taskAgentMaxTokens)
	case anthropic.StopReasonModelContextWindowExceeded:
		return errors.New("the conversation grew past the model's context window")
	}
	return nil
}

func usageLine(turnNumber int, reply turn) string {
	usage := reply.message.Usage
	return fmt.Sprintf(
		"Task agent: turn %d stopped for %s, tokens in %d, cache read %d, cache write %d, out %d",
		turnNumber, reply.stopReason, usage.InputTokens, usage.CacheReadInputTokens, usage.CacheCreationInputTokens, usage.OutputTokens,
	)
}

// pageOutcome records whether the task's Notion page was written, which finish waits on.
type pageOutcome struct {
	written bool
}

// runToolCalls runs the calls of one turn and returns one tool_result block per call in the calls' order.
//
// A call to a tool the task was not offered (the set in offered) is answered here with an error. A tool with no capability starts at once.
// One with a capability waits for the learner's approval, one call at a time in the turn's order, and a declined one
// gets the declined result and never runs. A write_notion_page call that cites a link outside sources is refused with an
// error naming it, and one that passes reaches the app with each source's link as sources spelled it. It sets page once
// a write_notion_page call succeeds, and adds the video link of a successful read_video_captions result to sources.
func (runner *taskRunner) runToolCalls(
	taskContext context.Context,
	task *runningTask,
	taskID string,
	calls []toolCall,
	offered map[toolName]bool,
	page *pageOutcome,
	sources *citableSources,
) ([]anthropic.ContentBlockParamUnion, error) {
	resultsByToolUseID := map[string]toolResultMessage{}
	// An MCP server's tool runs in the harness, in its own goroutine, and its result arrives here.
	serverResults := make(chan toolResultMessage, len(calls))
	// Every check and summary below reads the same encoding of the input that runs.
	for index := range calls {
		calls[index].Input = canonicalToolInput(calls[index].Input)
	}
	start := func(call toolCall) {
		input := call.Input
		if _, isAppTool := appToolCapabilities[call.Name]; isAppTool {
			runner.send(taskContext, newToolCallMessage(taskID, call.ID, call.Name, input))
			return
		}
		go func() {
			result := runner.mcp.call(taskContext, call.Name, input, task.mcpImages)
			result.TaskID, result.ToolUseID = taskID, call.ID
			serverResults <- result
		}()
	}

	var callsThatNeedApproval []toolCall
	for _, call := range calls {
		// A tool the task was not offered is not a tool, even when the app or a server has it. A skill that limits the
		// tools holds the agent to them here, and not only in the request, since the model may call a name it never saw.
		needed, known := runner.capabilityOf(call.Name)
		// The page is private, but a source link is one the learner may click, so a link the agent could have written
		// from what it read is refused before the call reaches the app.
		pageRefusal := ""
		// A page the task was not offered gets "is not a tool" below, so its sources are not checked or logged.
		if call.Name == writeNotionPageTool && known && offered[call.Name] {
			check := sources.checkPageSources(call.Input)
			pageRefusal = check.refusal
			switch {
			case pageRefusal == "":
				// The page cites each link as the set spelled it, never as the agent did.
				call.Input = check.input
			case check.refusedCount == 0:
				runner.log(taskContext, "Task agent: refused a page whose sources could not be read")
			default:
				// A count only, since a refused link can hold what the agent read on the screen or the clipboard.
				runner.log(taskContext, fmt.Sprintf("Task agent: refused a page, unresearched sources: %d", check.refusedCount))
			}
		}
		switch {
		case !known || !offered[call.Name]:
			resultsByToolUseID[call.ID] = toolResultMessage{
				TaskID:    taskID,
				ToolUseID: call.ID,
				Content:   mustMarshal(fmt.Sprintf("%s is not a tool", call.Name)),
				IsError:   true,
			}
		case pageRefusal != "":
			resultsByToolUseID[call.ID] = toolResultMessage{TaskID: taskID, ToolUseID: call.ID, Content: mustMarshal(pageRefusal), IsError: true}
		case needed.needsApproval():
			callsThatNeedApproval = append(callsThatNeedApproval, call)
		default:
			start(call)
		}
	}

	for _, call := range callsThatNeedApproval {
		needed, _ := runner.capabilityOf(call.Name)
		// A payload too long to show in full is refused, not approved on a summary that cuts it.
		if refusal := approvalRefusal(call, runner.mcp.tool(call.Name)); refusal != "" {
			resultsByToolUseID[call.ID] = toolResultMessage{TaskID: taskID, ToolUseID: call.ID, Content: mustMarshal(refusal), IsError: true}
			continue
		}
		phase := runner.approvals.authorize(taskContext, taskID, call.Name, needed, approvalSummary(call, runner.mcp.tool(call.Name)), func(message outboundMessage) {
			runner.send(taskContext, message)
		})
		if phase == approvalAbandoned {
			return nil, taskContext.Err()
		}
		runner.log(taskContext, fmt.Sprintf("Approval: %s (%s) %s", call.Name, needed, approvalOutcomeWords(phase)))
		if phase.mayRun() {
			start(call)
			continue
		}
		resultsByToolUseID[call.ID] = toolResultMessage{TaskID: taskID, ToolUseID: call.ID, Content: mustMarshal(declinedToolResult), IsError: true}
	}

	for len(resultsByToolUseID) < len(calls) {
		select {
		case <-taskContext.Done():
			return nil, taskContext.Err()
		case result := <-serverResults:
			resultsByToolUseID[result.ToolUseID] = result
		case result := <-task.toolResults:
			if !callsInclude(calls, result.ToolUseID) {
				fmt.Fprintf(os.Stderr, "harness: dropped a tool result for %s, which this turn did not call\n", result.ToolUseID)
				continue
			}
			resultsByToolUseID[result.ToolUseID] = result
		}
	}

	toolResultBlocks := make([]anthropic.ContentBlockParamUnion, 0, len(calls))
	for _, call := range calls {
		result := resultsByToolUseID[call.ID]
		if call.Name == writeNotionPageTool && !result.IsError {
			page.written = true
		}
		// The video link comes only from this field of this tool's result, never from the captions text, which a video
		// writes.
		if call.Name == readVideoCaptionsTool && !result.IsError {
			sources.add(result.SourceURL)
		}
		toolResultBlocks = append(toolResultBlocks, toolResultBlock(result))
	}
	return toolResultBlocks, nil
}

// offeredToolNames is the set of tool names a task's request lists.
func offeredToolNames(tools []anthropic.ToolUnionParam) map[toolName]bool {
	offered := map[toolName]bool{}
	for _, tool := range tools {
		offered[toolName(*tool.GetName())] = true
	}
	return offered
}

// capabilityOf is what a tool may do, and false for a tool the agent was not given.
func (runner *taskRunner) capabilityOf(name toolName) (capability, bool) {
	if needed, isAppTool := appToolCapabilities[name]; isAppTool {
		return needed, true
	}
	if serverTool := runner.mcp.tool(name); serverTool != nil {
		return serverTool.capability(), true
	}
	return capabilityNone, false
}

func approvalOutcomeWords(phase approvalPhase) string {
	switch phase {
	case approvalAlreadyGranted:
		return "was already approved for the rest of this task"
	case approvalGiven:
		return "was approved"
	default:
		return "was declined"
	}
}

func callsInclude(calls []toolCall, toolUseID string) bool {
	for _, call := range calls {
		if call.ID == toolUseID {
			return true
		}
	}
	return false
}

func mustMarshal(value any) json.RawMessage {
	encoded, err := json.Marshal(value)
	if err != nil {
		panic(fmt.Sprintf("could not encode %T: %v", value, err))
	}
	return encoded
}

// toolResultBlock turns the app's answer into a tool_result block. Content is a string or an array of text and base64
// image blocks. An answer it cannot read goes to the agent as an error, so the task moves on instead of waiting.
func toolResultBlock(result toolResultMessage) anthropic.ContentBlockParamUnion {
	content, err := parseToolResultContent(result.Content)
	if err != nil {
		return anthropic.NewToolResultBlock(result.ToolUseID, "The app returned a result the agent could not read: "+err.Error(), true)
	}
	return anthropic.ContentBlockParamUnion{OfToolResult: &anthropic.ToolResultBlockParam{
		ToolUseID: result.ToolUseID,
		Content:   content,
		IsError:   anthropic.Bool(result.IsError),
	}}
}

// parseToolResultContent reads the protocol's content field at the boundary.
func parseToolResultContent(rawContent json.RawMessage) ([]anthropic.ToolResultBlockParamContentUnion, error) {
	var text string
	if err := json.Unmarshal(rawContent, &text); err == nil {
		return textContent(text), nil
	}

	var blocks []struct {
		Type   string `json:"type"`
		Text   string `json:"text"`
		Source struct {
			Type      string `json:"type"`
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
		} `json:"source"`
	}
	if err := json.Unmarshal(rawContent, &blocks); err != nil {
		return nil, errors.New("content must be a string or an array of content blocks")
	}

	content := make([]anthropic.ToolResultBlockParamContentUnion, 0, len(blocks))
	for _, block := range blocks {
		switch {
		case block.Type == "text":
			content = append(content, textContent(block.Text)...)
		case block.Type == "image" && block.Source.Type == "base64":
			content = append(content, anthropic.ToolResultBlockParamContentUnion{OfImage: &anthropic.ImageBlockParam{
				Source: anthropic.ImageBlockParamSourceUnion{OfBase64: &anthropic.Base64ImageSourceParam{
					Data:      block.Source.Data,
					MediaType: anthropic.Base64ImageSourceMediaType(block.Source.MediaType),
				}},
			}})
		default:
			return nil, fmt.Errorf("a %q content block is not supported", block.Type)
		}
	}
	return content, nil
}

// textContent is one text block, or none for empty text, since the API refuses an empty text block and a tool result
// with no content is valid.
func textContent(text string) []anthropic.ToolResultBlockParamContentUnion {
	if text == "" {
		return nil
	}
	return []anthropic.ToolResultBlockParamContentUnion{{OfText: &anthropic.TextBlockParam{Text: text}}}
}
