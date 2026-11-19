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
}

// taskRunner runs task agents. It holds no per-task state, so any number of tasks can run on one runner.
type taskRunner struct {
	client anthropic.Client
	writer *protocolWriter
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
	messages := []anthropic.MessageParam{
		anthropic.NewUserMessage(anthropic.NewTextBlock(firstMessage(start.Goal, start.FrontTabTitle, start.FrontTabURL))),
	}
	pageWasWritten := false

	for turnNumber := 1; turnNumber <= mostTaskAgentTurns; turnNumber++ {
		reply, err := runner.requestTurn(taskContext, messages)
		if err != nil {
			return "", err
		}
		runner.log(taskContext, usageLine(turnNumber, reply))
		if err := failureOfTurn(reply); err != nil {
			return "", err
		}
		messages = append(messages, reply.message.ToParam())

		switch step := nextStepAfter(reply).(type) {
		case continueThePausedTurn:
			continue

		case finishTask:
			toolResults, err := runner.runAppTools(taskContext, task, start.TaskID, step.afterRunning, &pageWasWritten)
			if err != nil {
				return "", err
			}
			// A page refused in the same turn as finish goes back to the agent with a finish that did not count, so it
			// writes the page again instead of the task ending without one.
			if finishWaitsForTheRefusedPage(step.afterRunning, pageWasWritten, turnNumber == mostTaskAgentTurns) {
				toolResults = append(toolResults, anthropic.NewToolResultBlock(step.finishCallID, "Not finished: the page was not written. Fix it, write it, then call finish again.", true))
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
			toolResults, err := runner.runAppTools(taskContext, task, start.TaskID, step.calls, &pageWasWritten)
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
func (runner *taskRunner) requestTurn(taskContext context.Context, messages []anthropic.MessageParam) (turn, error) {
	requestContext, cancel := context.WithTimeout(taskContext, turnTimeout)
	defer cancel()

	stream := runner.client.Messages.NewStreaming(requestContext, taskAgentRequest(messages))
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

// runAppTools sends each call the app runs, together, waits for all of their results, and returns one tool_result
// block per call in the calls' order. A call to a tool the agent was not given is answered here with an error, so the
// app only ever sees the tools it knows. It sets pageWasWritten once a write_notion_page call succeeds.
func (runner *taskRunner) runAppTools(
	taskContext context.Context,
	task *runningTask,
	taskID string,
	calls []toolCall,
	pageWasWritten *bool,
) ([]anthropic.ContentBlockParamUnion, error) {
	resultsByToolUseID := map[string]toolResultMessage{}
	for _, call := range calls {
		if toolsTheAppRuns[call.Name] {
			input := call.Input
			if len(input) == 0 {
				input = json.RawMessage("{}")
			}
			runner.send(taskContext, newToolCallMessage(taskID, call.ID, call.Name, input))
		} else {
			resultsByToolUseID[call.ID] = toolResultMessage{
				TaskID:    taskID,
				ToolUseID: call.ID,
				Content:   mustMarshal(fmt.Sprintf("%s is not a tool", call.Name)),
				IsError:   true,
			}
		}
	}

	for len(resultsByToolUseID) < len(calls) {
		select {
		case <-taskContext.Done():
			return nil, taskContext.Err()
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
			*pageWasWritten = true
		}
		toolResultBlocks = append(toolResultBlocks, toolResultBlock(result))
	}
	return toolResultBlocks, nil
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
		return []anthropic.ToolResultBlockParamContentUnion{{OfText: &anthropic.TextBlockParam{Text: text}}}, nil
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
			content = append(content, anthropic.ToolResultBlockParamContentUnion{OfText: &anthropic.TextBlockParam{Text: block.Text}})
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
