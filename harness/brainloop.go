package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// brainRunner runs voice commands, one turn at a time, with the definition in brain.go. It holds no per-command state
// except the session, which each command reads when it begins and writes back when it ends whole (brainsession.go).
type brainRunner struct {
	client  anthropic.Client
	writer  *protocolWriter
	session *brainSession
}

// send writes a message for a command unless the command was cancelled, since a cancelled command sends nothing more.
func (brain *brainRunner) send(commandContext context.Context, message outboundMessage) {
	if commandContext.Err() != nil {
		return
	}
	brain.writer.send(message)
}

// logTheCancel goes straight to the writer, since send drops every line of a cancelled command, and a verify run would
// otherwise hold no evidence that the press cancelled it.
func (brain *brainRunner) logTheCancel(turnNumber int) {
	brain.writer.send(newLogMessage(fmt.Sprintf("Brain: command cancelled during turn %d", turnNumber)))
}

// runCommand runs one voice command to its end: voice_command_finished with the spoken line, or task_failed when a turn
// fails, which sends the app down its router failure fallback. A cancelled command writes only the cancel log line. A
// cancelled or failed command is rolled back out of the session, and a command that ends whole stays in it.
func (brain *brainRunner) runCommand(commandContext context.Context, command *runningTask, voiceCommand voiceCommandMessage) {
	tools, err := brainTools(voiceCommand.Tools)
	if err != nil {
		brain.send(commandContext, newTaskFailedMessage(voiceCommand.TaskID, err.Error()))
		return
	}
	offered := offeredToolNames(tools)
	run := brain.session.begin(voiceCommand.Transcript, voiceCommand.SceneState)

	for turnIndex := 0; turnIndex < mostBrainTurns; turnIndex++ {
		turnNumber := turnIndex + 1
		reply, err := brain.requestTurn(commandContext, run, tools, turnNumber)
		if commandContext.Err() != nil {
			brain.logTheCancel(turnNumber)
			run.abandon()
			return
		}
		if err != nil {
			run.abandon()
			brain.send(commandContext, newTaskFailedMessage(voiceCommand.TaskID, err.Error()))
			return
		}
		run.addReply(reply)

		outcomes, toolResultBlocks, err := brain.runToolCalls(commandContext, command, voiceCommand.TaskID, reply.toolCalls, offered, turnIndex, run)
		if err != nil {
			brain.logTheCancel(turnNumber)
			run.abandon()
			return
		}
		// Every tool_use needs its tool_result in the history, even when the model is not asked again, since the next
		// command's request carries both.
		run.addToolResults(toolResultBlocks)
		switch step := nextVoiceStep(reply.toolCalls, outcomes, reply.text).(type) {
		case finishSilently:
			brain.finish(commandContext, run, newVoiceCommandFinishedMessage(voiceCommand.TaskID, "", false))
			return
		case speakAndFinish:
			brain.finish(commandContext, run, newVoiceCommandFinishedMessage(voiceCommand.TaskID, step.spokenLine, false))
			return
		case askTheModelAgain:
		}
	}
	// The last turn still needed the model, so Clicky says its apology instead of going quiet.
	brain.finish(commandContext, run, newVoiceCommandFinishedMessage(voiceCommand.TaskID, "", true))
}

// finish keeps the command in the session and tells the app it ended. A cancel that arrived while the last call ran
// rolls it back instead, since the app already treats the command as cancelled.
func (brain *brainRunner) finish(commandContext context.Context, run *sessionRun, finished voiceCommandFinishedMessage) {
	if commandContext.Err() != nil {
		run.abandon()
		return
	}
	run.commit()
	brain.send(commandContext, finished)
}

// requestTurn sends one request without streaming, since a short tool call needs no stream, and logs its token line.
// It makes one attempt only: a retry would push the router failure fallback past brainTurnTimeout.
func (brain *brainRunner) requestTurn(commandContext context.Context, run *sessionRun, tools []anthropic.ToolUnionParam, turnNumber int) (turn, error) {
	requestContext, cancel := context.WithTimeout(commandContext, brainTurnTimeout)
	defer cancel()

	startedAt := time.Now()
	message, err := brain.client.Messages.New(requestContext, brainRequest(run.requestMessages(), tools), option.WithMaxRetries(0))
	if err != nil {
		if errors.Is(requestContext.Err(), context.DeadlineExceeded) && commandContext.Err() == nil {
			return turn{}, fmt.Errorf("turn %d got no reply from Claude within %s", turnNumber, brainTurnTimeout)
		}
		return turn{}, fmt.Errorf("the request to Claude failed: %w", err)
	}
	brain.session.noteRequest(startedAt)
	reply := newTurn(*message)
	brain.send(commandContext, newLogMessage(brainUsageLine(turnNumber, reply, time.Since(startedAt))))
	return reply, nil
}

// runToolCalls runs the calls of one turn in order, one at a time, as the app ran them before, and returns each call's
// outcome and one tool_result block for every call. A call to a tool the command did not offer is refused here, before
// the app sees it. A hand-off stops the turn's calls, since a slow path now owns the reply: its own result says so, and
// each call after it gets a "Not run" result, since the API refuses a tool_use with no tool_result. It records the
// action line of every call the app ran. It returns an error only when the command was cancelled.
func (brain *brainRunner) runToolCalls(
	commandContext context.Context,
	command *runningTask,
	commandID string,
	calls []toolCall,
	offered map[toolName]bool,
	turnIndex int,
	run *sessionRun,
) ([]voiceToolOutcome, []anthropic.ContentBlockParamUnion, error) {
	var outcomes []voiceToolOutcome
	var toolResultBlocks []anthropic.ContentBlockParamUnion
	requestWasHandedOff := false
	for _, call := range calls {
		if requestWasHandedOff {
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, notRunResultText, false))
			continue
		}
		if !offered[call.Name] {
			outcomes = append(outcomes, voiceToolFailed)
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, voiceToolFailureText(fmt.Sprintf("%s is not available right now", call.Name)), true))
			continue
		}
		brain.send(commandContext, newVoiceToolCallMessage(commandID, call.ID, call.Name, inputWithoutConfirmation(call.Input), turnIndex))
		result, err := waitForTheVoiceToolResult(commandContext, command, call.ID)
		if err != nil {
			return nil, nil, err
		}
		outcome := result.Outcome
		if !outcome.isKnown() {
			// The app sends an outcome with every voice tool result, so one without it is a newer or broken app. The
			// model reads it as a failure, which ends the command with a spoken sentence instead of a wait.
			fmt.Fprintf(os.Stderr, "harness: the tool result for %s had no outcome, so it counts as failed\n", call.ID)
			outcome = voiceToolFailed
		}
		outcomes = append(outcomes, outcome)
		resultText := voiceToolResultText(result)
		run.actionLines = append(run.actionLines, voiceToolActionLine(call, outcome, resultText))
		if outcome == voiceToolHandedOff {
			requestWasHandedOff = true
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, handedOffResultText, false))
			continue
		}
		toolResultBlocks = append(toolResultBlocks, toolResultBlock(result))
	}
	return outcomes, toolResultBlocks, nil
}

// voiceToolResultText is the text of a voice tool's result, which the app sends as a string. Anything else reads as empty.
func voiceToolResultText(result toolResultMessage) string {
	var text string
	if err := json.Unmarshal(result.Content, &text); err != nil {
		return ""
	}
	return text
}

// waitForTheVoiceToolResult waits for the app's answer to one call. A result for another call is dropped.
func waitForTheVoiceToolResult(commandContext context.Context, command *runningTask, toolUseID string) (toolResultMessage, error) {
	for {
		select {
		case <-commandContext.Done():
			return toolResultMessage{}, commandContext.Err()
		case result := <-command.toolResults:
			if result.ToolUseID != toolUseID {
				fmt.Fprintf(os.Stderr, "harness: dropped a tool result for %s, which the command is not waiting on\n", result.ToolUseID)
				continue
			}
			return result, nil
		}
	}
}
