package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// brainRunner runs voice commands, one turn at a time, with the definition in brain.go. It holds no per-command state.
// A command keeps no memory of the last one yet: each starts a new conversation, and the app sends its recent actions.
type brainRunner struct {
	client anthropic.Client
	writer *protocolWriter
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
// fails, which sends the app down its router failure fallback. A cancelled command writes only the cancel log line.
func (brain *brainRunner) runCommand(commandContext context.Context, command *runningTask, voiceCommand voiceCommandMessage) {
	tools, err := brainTools(voiceCommand.Tools)
	if err != nil {
		brain.send(commandContext, newTaskFailedMessage(voiceCommand.TaskID, err.Error()))
		return
	}
	offered := offeredToolNames(tools)
	messages := []anthropic.MessageParam{
		anthropic.NewUserMessage(anthropic.NewTextBlock(brainUserMessageText(voiceCommand.Transcript, voiceCommand.SceneState, voiceCommand.RecentActions))),
	}

	for turnIndex := 0; turnIndex < mostBrainTurns; turnIndex++ {
		turnNumber := turnIndex + 1
		reply, err := brain.requestTurn(commandContext, messages, tools, turnNumber)
		if commandContext.Err() != nil {
			brain.logTheCancel(turnNumber)
			return
		}
		if err != nil {
			brain.send(commandContext, newTaskFailedMessage(voiceCommand.TaskID, err.Error()))
			return
		}
		messages = append(messages, reply.message.ToParam())

		outcomes, toolResultBlocks, err := brain.runToolCalls(commandContext, command, voiceCommand.TaskID, reply.toolCalls, offered, turnIndex)
		if err != nil {
			brain.logTheCancel(turnNumber)
			return
		}
		switch step := nextVoiceStep(reply.toolCalls, outcomes, reply.text).(type) {
		case finishSilently:
			brain.send(commandContext, newVoiceCommandFinishedMessage(voiceCommand.TaskID, "", false))
			return
		case speakAndFinish:
			brain.send(commandContext, newVoiceCommandFinishedMessage(voiceCommand.TaskID, step.spokenLine, false))
			return
		case askTheModelAgain:
			messages = append(messages, anthropic.NewUserMessage(toolResultBlocks...))
		}
	}
	// The last turn still needed the model, so Clicky says its apology instead of going quiet.
	brain.send(commandContext, newVoiceCommandFinishedMessage(voiceCommand.TaskID, "", true))
}

// requestTurn sends one request without streaming, since a short tool call needs no stream, and logs its token line.
// It makes one attempt only: a retry would push the router failure fallback past brainTurnTimeout.
func (brain *brainRunner) requestTurn(commandContext context.Context, messages []anthropic.MessageParam, tools []anthropic.ToolUnionParam, turnNumber int) (turn, error) {
	requestContext, cancel := context.WithTimeout(commandContext, brainTurnTimeout)
	defer cancel()

	startedAt := time.Now()
	message, err := brain.client.Messages.New(requestContext, brainRequest(messages, tools), option.WithMaxRetries(0))
	if err != nil {
		if errors.Is(requestContext.Err(), context.DeadlineExceeded) && commandContext.Err() == nil {
			return turn{}, fmt.Errorf("turn %d got no reply from Claude within %s", turnNumber, brainTurnTimeout)
		}
		return turn{}, fmt.Errorf("the request to Claude failed: %w", err)
	}
	reply := newTurn(*message)
	brain.send(commandContext, newLogMessage(brainUsageLine(turnNumber, reply, time.Since(startedAt))))
	return reply, nil
}

// runToolCalls runs the calls of one turn in order, one at a time, as the app ran them before, and returns each call's
// outcome and the tool_result blocks for the next turn. A call to a tool the command did not offer is refused here,
// before the app sees it. A hand-off stops the turn's calls, since a slow path now owns the reply. It returns an error
// only when the command was cancelled.
func (brain *brainRunner) runToolCalls(
	commandContext context.Context,
	command *runningTask,
	commandID string,
	calls []toolCall,
	offered map[toolName]bool,
	turnIndex int,
) ([]voiceToolOutcome, []anthropic.ContentBlockParamUnion, error) {
	var outcomes []voiceToolOutcome
	var toolResultBlocks []anthropic.ContentBlockParamUnion
	for _, call := range calls {
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
		if outcome == voiceToolHandedOff {
			break
		}
		toolResultBlocks = append(toolResultBlocks, toolResultBlock(result))
	}
	return outcomes, toolResultBlocks, nil
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
