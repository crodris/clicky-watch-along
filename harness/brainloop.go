package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
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
	// approvals is the gate the task agents also use. A voice answer settles a request through it, so the first answer
	// to a request, by voice or by click, wins.
	approvals *approvalGate
	// planningTurnTimeout is the Sonnet turn's time limit. Zero means brainPlanningTurnTimeout.
	planningTurnTimeout time.Duration
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

// runCommand runs one voice command to its end: voice_command_finished with the spoken line, or task_failed when a Haiku
// turn fails, which sends the app down its router failure fallback. A failed Sonnet turn ends the command as gave up
// instead, since the command's earlier calls already changed the screen. A cancelled command writes only the cancel log
// line. A cancelled or Haiku-failed command is rolled back out of the session, and a command that ends whole, or gave up
// after a failed Sonnet turn, stays in it. A cancel is checked before the Sonnet failure, so a press during the Sonnet
// turn rolls the command back like one during a Haiku turn.
//
// The command gets up to mostBrainHaikuTurns turns on Haiku. When the last of them still needs the model, it gets one
// more turn on Sonnet (the turn budget rule) before the gave-up line, with the same tools and the same history.
func (brain *brainRunner) runCommand(commandContext context.Context, command *runningTask, voiceCommand voiceCommandMessage) {
	// The gate decides whether a request can be answered by voice, from the ID the app says the learner had seen.
	approvalOffer := brain.approvals.answerableApproval(voiceCommand.ApprovalIDSeenAtPress)
	run := brain.session.begin(voiceCommand.Transcript, sceneStateForACommand(voiceCommand.SceneState, approvalOffer))
	// The session's record of applied changes decides whether undo_last_change is offered, so the command begins first.
	tools, err := brainTools(withTheUndoOffer(offersForACommand(voiceCommand.Tools, approvalOffer), run))
	if err != nil {
		run.abandon()
		brain.send(commandContext, newTaskFailedMessage(voiceCommand.TaskID, err.Error()))
		return
	}
	offered := offeredToolNames(tools)

	for turnIndex := 0; turnIndex <= mostBrainHaikuTurns; turnIndex++ {
		turnNumber := turnIndex + 1
		isThePlanningTurn := turnIndex == mostBrainHaikuTurns
		if isThePlanningTurn {
			brain.send(commandContext, newCommandLogMessage(voiceCommand.TaskID, brainPlanningLogLine))
		}
		reply, err := brain.requestTurn(commandContext, run, tools, turnNumber, isThePlanningTurn)
		if commandContext.Err() != nil {
			brain.logTheCancel(turnNumber)
			run.abandon()
			return
		}
		if err != nil && isThePlanningTurn {
			// The extra turn is optional, so its failure leaves the command where Haiku's last turn did: it gives up
			// and says so, and the app does not run the keyword path over actions the command already ran.
			brain.send(commandContext, newLogMessage(fmt.Sprintf("Brain: the planning turn failed, so the command gives up: %v", err)))
			break
		}
		if err != nil {
			run.abandon()
			brain.send(commandContext, newTaskFailedMessage(voiceCommand.TaskID, err.Error()))
			return
		}
		run.addReply(reply)

		outcomes, toolResultBlocks, err := brain.runToolCalls(commandContext, command, voiceCommand, reply.toolCalls, offered, approvalOffer, turnIndex, run)
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
	// The last turn, the Sonnet one, still needed the model, so Clicky says its apology instead of going quiet.
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

// planningTimeout is the Sonnet turn's time limit: 30 seconds, unless a test set a shorter one.
func (brain *brainRunner) planningTimeout() time.Duration {
	return cmp.Or(brain.planningTurnTimeout, brainPlanningTurnTimeout)
}

// requestTurn sends one request without streaming, since a short tool call needs no stream, and logs its token line.
// It makes one attempt only: a retry would push the router failure fallback past the turn's time limit, which is
// brainTurnTimeout on Haiku and the planning limit on the Sonnet turn.
func (brain *brainRunner) requestTurn(commandContext context.Context, run *sessionRun, tools []anthropic.ToolUnionParam, turnNumber int, isThePlanningTurn bool) (turn, error) {
	model, timeout := brainModel, brainTurnTimeout
	if isThePlanningTurn {
		model, timeout = brainPlanningModel, brain.planningTimeout()
	}
	requestContext, cancel := context.WithTimeout(commandContext, timeout)
	defer cancel()

	startedAt := time.Now()
	message, err := brain.client.Messages.New(requestContext, brainRequest(model, run.requestMessages(), tools), option.WithMaxRetries(0))
	if err != nil {
		if errors.Is(requestContext.Err(), context.DeadlineExceeded) && commandContext.Err() == nil {
			return turn{}, fmt.Errorf("turn %d got no reply from Claude within %s", turnNumber, timeout)
		}
		if theWorkerRefusedTheAppSecret(err) {
			return turn{}, errAppSecretRefused
		}
		return turn{}, fmt.Errorf("the request to Claude failed: %w", err)
	}
	brain.session.noteRequest(startedAt)
	reply := newTurn(*message)
	brain.send(commandContext, newLogMessage(brainUsageLine(turnNumber, model, reply, time.Since(startedAt))))
	return reply, nil
}

// errAppSecretRefused is the failure of a turn the Worker's own app secret check refused. Its text is the reason the
// command's task_failed carries, which the app reads: it then sends the same command once on the old path, which needs
// no secret, and uses that path for the rest of the launch. leanring-buddy/VoiceCommandTools.swift
// (`harnessFailureReasonAppSecretRefused`) holds the same words.
var errAppSecretRefused = errors.New("app secret refused")

// theWorkerRefusedTheAppSecret tells the Worker's secret check from Anthropic's own 401, which /v1/messages passes
// through. Both are a 401, and the Worker's body is {"error":"Missing or wrong x-clicky-app-secret"} (worker/src/index.ts),
// where the error is a string. Anthropic's is {"type":"error","error":{"type":"authentication_error",...}}, where it is an
// object. An Anthropic 401 is a router failure like any other, and the old path would hit it too.
func theWorkerRefusedTheAppSecret(err error) bool {
	var apiError *anthropic.Error
	if !errors.As(err, &apiError) || apiError.StatusCode != http.StatusUnauthorized {
		return false
	}
	var body struct {
		Error json.RawMessage `json:"error"`
	}
	if json.Unmarshal([]byte(apiError.RawJSON()), &body) != nil {
		return false
	}
	var message string
	return json.Unmarshal(body.Error, &message) == nil && message == "Missing or wrong "+appSecretHeaderName
}

// runToolCalls runs the calls of one turn in order, one at a time, as the app ran them before, and returns each call's
// outcome and one tool_result block for every call. A call to a tool the command did not offer is refused here, before
// the app sees it. A hand-off stops the turn's calls, since a slow path now owns the reply: its own result says so, and
// each call after it gets a "Not run" result, since the API refuses a tool_use with no tool_result. A failed call stops
// them too, since a later call that depends on it, such as a pop-out after a seek that found no moment, would act on
// the wrong screen and the learner would never hear the failure: each later call gets its own "Not run" result and the
// model is asked again. It records the action line of every call the app ran, and the change of every call that changed
// the screen. A call to undo_last_change reaches the app as the inverse of the newest change (brainundo.go), so an undo
// whose inverse fails, or that cannot be undone, is a failed call like any other. It returns an error only when the
// command was cancelled.
func (brain *brainRunner) runToolCalls(
	commandContext context.Context,
	command *runningTask,
	voiceCommand voiceCommandMessage,
	calls []toolCall,
	offered map[toolName]bool,
	approvalOffer approvalOffer,
	turnIndex int,
	run *sessionRun,
) ([]voiceToolOutcome, []anthropic.ContentBlockParamUnion, error) {
	commandID := voiceCommand.TaskID
	var outcomes []voiceToolOutcome
	var toolResultBlocks []anthropic.ContentBlockParamUnion
	requestWasHandedOff := false
	anEarlierCallFailed := false
	for _, call := range calls {
		if requestWasHandedOff {
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, notRunResultText, false))
			continue
		}
		if anEarlierCallFailed {
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, notRunAfterAFailureResultText, false))
			continue
		}
		if !offered[call.Name] {
			anEarlierCallFailed = true
			outcomes = append(outcomes, voiceToolFailed)
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, voiceToolFailureText(fmt.Sprintf("%s is not available right now", call.Name)), true))
			continue
		}
		if call.Name == answerApprovalTool {
			// The harness settles an approval itself, so this call never reaches the app. A press that cancelled the command
			// first leaves the request waiting.
			if commandContext.Err() != nil {
				return nil, nil, commandContext.Err()
			}
			outcome, resultText := brain.answerTheApproval(call, approvalOffer, turnIndex, voiceCommand.Transcript)
			anEarlierCallFailed = outcome == voiceToolFailed
			outcomes = append(outcomes, outcome)
			run.noteFinishedCall(call, outcome, resultText, false)
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, resultText, outcome == voiceToolFailed))
			continue
		}
		// callToRun is what reaches the app. It is the model's call, except for undo_last_change, which the harness turns
		// into the inverse of the newest change, so the model never works out the reverse.
		callToRun := call
		isAnUndo := call.Name == undoLastChangeTool
		if isAnUndo {
			inverse, canBeUndone := run.inverseOfTheNewestChange(func(name toolName) bool { return offered[name] })
			if !canBeUndone {
				anEarlierCallFailed = true
				outcomes = append(outcomes, voiceToolFailed)
				toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, voiceToolFailureText("the newest change cannot be undone exactly, so make the reverse yourself"), true))
				continue
			}
			callToRun = toolCall{ID: call.ID + undoCallIDSuffix, Name: inverse.tool, Input: inverse.input}
		}
		brain.send(commandContext, newVoiceToolCallMessage(commandID, callToRun.ID, callToRun.Name, inputWithoutConfirmation(callToRun.Input), turnIndex))
		result, err := waitForTheVoiceToolResult(commandContext, command, callToRun.ID)
		if err != nil {
			// A result the app sent before its cancel_task is a call that finished, and it changed the screen, so its
			// action line still reaches the next command through the rollback, and its change joins the record.
			if result.ToolUseID == callToRun.ID {
				run.noteFinishedCall(callToRun, knownOutcomeOf(result), voiceToolResultText(result), isAnUndo)
			}
			return nil, nil, err
		}
		outcome := knownOutcomeOf(result)
		anEarlierCallFailed = outcome == voiceToolFailed
		outcomes = append(outcomes, outcome)
		resultText := voiceToolResultText(result)
		run.noteFinishedCall(callToRun, outcome, resultText, isAnUndo)
		if outcome == voiceToolHandedOff {
			requestWasHandedOff = true
			toolResultBlocks = append(toolResultBlocks, anthropic.NewToolResultBlock(call.ID, handedOffResultText, false))
			continue
		}
		if isAnUndo {
			result = resultOfTheUndo(call, callToRun, result)
		}
		toolResultBlocks = append(toolResultBlocks, tagSafeToolResult(toolResultBlock(result)))
	}
	return outcomes, toolResultBlocks, nil
}

// knownOutcomeOf is a result's outcome. The app sends one with every voice tool result, so a result without it is a newer
// or broken app. The model reads it as a failure, which ends the command with a spoken sentence instead of a wait.
func knownOutcomeOf(result toolResultMessage) voiceToolOutcome {
	if !result.Outcome.isKnown() {
		fmt.Fprintf(os.Stderr, "harness: the tool result for %s had no outcome, so it counts as failed\n", result.ToolUseID)
		return voiceToolFailed
	}
	return result.Outcome
}

// tagSafeToolResult is a tool result with every "<" in its text written as "‹", so a caption or page text in a result
// cannot hold a learner_words tag of its own once the session keeps it. Line breaks stay, since a result is a block of
// text and not one line. The block it came from is not changed.
func tagSafeToolResult(block anthropic.ContentBlockParamUnion) anthropic.ContentBlockParamUnion {
	if block.OfToolResult == nil {
		return block
	}
	copied := *block.OfToolResult
	copied.Content = make([]anthropic.ToolResultBlockParamContentUnion, len(block.OfToolResult.Content))
	for itemIndex, item := range block.OfToolResult.Content {
		if item.OfText != nil {
			copiedItem := *item.OfText
			copiedItem.Text = strings.ReplaceAll(copiedItem.Text, "<", tagSafeLessThanSymbol)
			item = anthropic.ToolResultBlockParamContentUnion{OfText: &copiedItem}
		}
		copied.Content[itemIndex] = item
	}
	return anthropic.ContentBlockParamUnion{OfToolResult: &copied}
}

// voiceToolResultText is the text of a voice tool's result, which the app sends as a string. Anything else reads as empty.
func voiceToolResultText(result toolResultMessage) string {
	var text string
	if err := json.Unmarshal(result.Content, &text); err != nil {
		return ""
	}
	return text
}

// waitForTheVoiceToolResult waits for the app's answer to one call. A result for another call is dropped. When the command
// is cancelled it also returns the call's result when the app sent one first: the app writes a finished call's result
// before its cancel_task, so the result is already queued by the time the context is done, and a select that saw both
// ready would otherwise pick one at random.
func waitForTheVoiceToolResult(commandContext context.Context, command *runningTask, toolUseID string) (toolResultMessage, error) {
	for {
		select {
		case <-commandContext.Done():
			for {
				select {
				case result := <-command.toolResults:
					if result.ToolUseID == toolUseID {
						return result, commandContext.Err()
					}
				default:
					return toolResultMessage{}, commandContext.Err()
				}
			}
		case result := <-command.toolResults:
			if result.ToolUseID != toolUseID {
				fmt.Fprintf(os.Stderr, "harness: dropped a tool result for %s, which the command is not waiting on\n", result.ToolUseID)
				continue
			}
			return result, nil
		}
	}
}
