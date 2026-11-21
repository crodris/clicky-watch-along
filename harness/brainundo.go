package main

import (
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strings"

	"github.com/anthropics/anthropic-sdk-go"
)

// This file is the brain's undo. A model asked to undo a change has to work out the reverse of an angle, a factor, or a
// number of seconds, and it gets that wrong about as often as it gets it right (the known miss in
// bench/fixtures/brain-sessions.json). So the harness remembers each change the app made, with the exact input the app
// ran, and offers undo_last_change while the newest change has an inverse that follows from its own input. The harness
// handles the call: it sends the inverse to the app as an ordinary tool_call, so the app shows its usual chip and writes
// its usual action line, and the outcome of that call is the outcome of the undo. This is the same split as answer_approval
// (voiceapproval.go): the model chooses to undo, and the harness does the part a model gets wrong.

const (
	// undoLastChangeTool is the brain's tool for reversing the newest change. The app never lists it.
	undoLastChangeTool toolName = "undo_last_change"

	// mostAppliedChangesKept is how many changes the record keeps, newest first. Only the newest change can be undone, and
	// an undo reveals the one before it, so a short run of undos is the most a learner says in a row.
	mostAppliedChangesKept = 20

	// undoCallIDSuffix is added to the model's call ID to name the inverse call the harness sends to the app, since the
	// app and the harness match each result to its call by ID and the model's own ID belongs to undo_last_change.
	undoCallIDSuffix = "-undo"
)

// undoLastChangeOffer is the tool as the model sees it. The description never names the change it would undo, because a
// description that changed from command to command would throw away the cached tool list every time.
var undoLastChangeOffer = voiceToolOffer{
	Name:        string(undoLastChangeTool),
	Description: `Undo the newest change Clicky made to the screen or the video, exactly. The harness runs the opposite action itself, so you never work out the angle, the zoom factor, or the seconds. Use it when the learner says "undo" or "undo that", or asks to put the last thing back the way it was. It reverses only the newest change. For an older action, such as "undo the first turn", and for "more", "less", or "the other way", call the tool that makes that change yourself. Your confirmation is a few plain words, such as "undid it".`,
	InputSchema: json.RawMessage(`{"type":"object","properties":{}}`),
}

// appliedChange is one call that changed what the learner sees: its tool and the exact input the app ran, without the
// brain's confirmation, and the scene the command saw when it ran it (scene). A hand-off counts too. No inverse reverses a
// pop-out, but it stands between "undo that" and an older change, so the older change is not undone by mistake. A lookup
// changed nothing and a failed call changed nothing, so neither is recorded.
//
// scene is nil only for a change a seeded session implied (bench only), which has no scene state of its own. The next
// command adopts it as its own scene, so a seeded record is read as one that matches what that command sees.
type appliedChange struct {
	tool  toolName
	input json.RawMessage
	scene *sceneIdentity
}

// sceneIdentity is what a change was made to, read from the scene_state JSON the app sends with each voice command. The
// Escape key and a tab switch change the screen outside the harness, so the record cannot learn of them from its own calls,
// and an inverse run on a different scene or video would move the wrong thing: it would turn a new pop-out back by an old
// pop-out's rotation. Each part is a string made of the scene state's own fields, empty when there is nothing on screen:
//
//   - page is the scene the page tools act on: the state's "page" (framePopout, landmark, simulation, generated3DScene)
//     and "sceneNumber", which the app adds and counts up each time a scene starts to show. The number is what tells two
//     pop-outs of the same video apart, since their page and labels look the same. An app that sends no number leaves
//     the page name as the identity.
//   - video is the video the video tools act on: the state's video "title" and "durationSeconds". A different tab means a
//     different title or length. A title that changes inside one video, such as a notification count in front of it,
//     reads as a different video, which only costs an undo the harness refuses, never one it runs on the wrong video.
type sceneIdentity struct {
	page  string
	video string
}

// sceneIdentityOf reads the identity from a command's scene state. A state that is not a JSON object, or a field of the
// wrong type, reads as nothing on screen.
func sceneIdentityOf(sceneState json.RawMessage) sceneIdentity {
	fields, isAnObject := decodedToolInput(sceneState)
	if !isAnObject {
		return sceneIdentity{}
	}
	var identity sceneIdentity
	if pageName, hasAPage := fields["page"].(string); hasAPage && pageName != "none" {
		identity.page = fmt.Sprintf("%s#%v", pageName, fields["sceneNumber"])
	}
	if video, hasAVideo := fields["video"].(map[string]any); hasAVideo {
		identity.video = fmt.Sprintf("%v|%v", video["title"], video["durationSeconds"])
	}
	return identity
}

// changeTarget says which part of the identity a tool's change depends on.
type changeTarget int

const (
	// targetsNothingInParticular is every tool not listed below: a hand-off, an answered approval, a theme change. Such a
	// change stands between "undo that" and an older change for as long as the record keeps it, and never goes stale by
	// itself, because it is what changes the scene or the video.
	targetsNothingInParticular changeTarget = iota
	// targetsThePage is a camera, cutaway, or simulation change, which belongs to the scene on screen.
	targetsThePage
	// targetsTheVideo is a seek, pause, or speed change, which belongs to the video in front.
	targetsTheVideo
)

var changeTargets = map[toolName]changeTarget{
	"rotate_model":    targetsThePage,
	"zoom":            targetsThePage,
	"zoom_to_part":    targetsThePage,
	"reset_view":      targetsThePage,
	"explode_view":    targetsThePage,
	"set_inside_view": targetsThePage,
	"set_labels":      targetsThePage,
	"set_control":     targetsThePage,
	"run_simulation":  targetsThePage,
	"pause_video":     targetsTheVideo,
	"play_video":      targetsTheVideo,
	"seek_relative":   targetsTheVideo,
	"seek_to_time":    targetsTheVideo,
	"set_speed":       targetsTheVideo,
}

// isStale is true when the scene or video the change was made to is not the one the command sees.
func (change appliedChange) isStale(current sceneIdentity) bool {
	switch changeTargets[change.tool] {
	case targetsThePage:
		return change.scene.page != current.page
	case targetsTheVideo:
		return change.scene.video != current.video
	default:
		return false
	}
}

// changesThatStillApply is the record a command reads: the changes up to the newest stale one. That change and every
// change older than it are dropped for good, since the newest thing the learner did is gone from the screen, so "undo
// that" has no target in the record, and an older change must not take its place. A seeded change with no scene takes the
// current one.
func changesThatStillApply(recordedNewestFirst []appliedChange, current sceneIdentity) []appliedChange {
	kept := make([]appliedChange, 0, len(recordedNewestFirst))
	for _, change := range recordedNewestFirst {
		if change.scene == nil {
			adopted := current
			change.scene = &adopted
		}
		if change.isStale(current) {
			break
		}
		kept = append(kept, change)
	}
	return kept
}

// inverseCall is the call that reverses a change.
type inverseCall struct {
	tool  toolName
	input json.RawMessage
}

// inverseBuilder reads a change's input and says the call that reverses it, or false when the input does not hold what
// the inverse needs.
type inverseBuilder func(input map[string]any) (inverseCall, bool)

// inverseBuilders is the table of changes that have an inverse. A tool is in it only when the inverse follows from the
// tool's own input. It is exact until the page clamps the move: a camera at its zoom or pitch limit, or a seek past the
// end of the video, moves less than the input says, and the inverse then moves back too far.
//
// A tool left out needs state its input does not hold:
//   - explode_view sets an absolute amount, and the amount before it is not in the input.
//   - set_speed sets an absolute rate, and the rate before it is not in the input.
//   - seek_to_time jumps to an absolute time, and the time before it is not in the input.
//   - zoom_to_part moves the camera to a part from a pose the input does not name.
//   - reset_view discards the camera, the explode amount, and the cutaway, none of which the input names.
//   - set_control sets an absolute value, and the value before it is not in the input.
//   - run_simulation plays a run, which has no opposite.
//   - close_scene closes a scene that cannot be reopened from here.
//
// The flags and the pause pair have two values, so a call that changed something started from the opposite value, and
// that is the inverse. A call that changed nothing, such as hiding labels that were already hidden, is the one case where
// its inverse puts back something that was never there.
var inverseBuilders = map[toolName]inverseBuilder{
	"rotate_model":    inverseOfRotateModel,
	"zoom":            inverseOfZoom,
	"seek_relative":   inverseOfSeekRelative,
	"set_labels":      inverseOfFlippingAFlag("set_labels", "visible"),
	"set_inside_view": inverseOfFlippingAFlag("set_inside_view", "open"),
	"pause_video":     inverseIsACallWithNoInput("play_video"),
	"play_video":      inverseIsACallWithNoInput("pause_video"),
}

// The page clamps a zoom factor to this range before it moves the camera (scene-tools.js).
const (
	smallestZoomFactor = 0.3
	largestZoomFactor  = 3.0
)

// inverse is the call that reverses the change, or false when the change has none.
func (change appliedChange) inverse() (inverseCall, bool) {
	buildInverse, hasAnInverse := inverseBuilders[change.tool]
	if !hasAnInverse {
		return inverseCall{}, false
	}
	input, isAnObject := decodedToolInput(change.input)
	if !isAnObject {
		return inverseCall{}, false
	}
	return buildInverse(input)
}

// numberInput reads one input key as a finite number. A key that is missing, or holds a string, null, or a number too
// large for a float64 (which Float64 reports as an error), is not a number the inverse can reverse.
func numberInput(input map[string]any, key string) (float64, bool) {
	number, isANumber := input[key].(json.Number)
	if !isANumber {
		return 0, false
	}
	value, err := number.Float64()
	return value, err == nil
}

// negated is the opposite of a number. It subtracts from zero because negating zero gives -0, which JSON writes as "-0".
func negated(value float64) float64 {
	return 0 - value
}

// inverseOfRotateModel turns the camera back: yaw and pitch are relative, so the opposite of a turn is the same turn
// backward. The page clamps each input to a range that is the same on both sides of zero, so a clamped input reverses
// exactly too.
func inverseOfRotateModel(input map[string]any) (inverseCall, bool) {
	yawDegrees, hasYaw := numberInput(input, "yawDegrees")
	if !hasYaw {
		return inverseCall{}, false
	}
	reversedInput := map[string]any{"yawDegrees": negated(yawDegrees)}
	if _, hasPitch := input["pitchDegrees"]; hasPitch {
		pitchDegrees, pitchIsANumber := numberInput(input, "pitchDegrees")
		if !pitchIsANumber {
			return inverseCall{}, false
		}
		reversedInput["pitchDegrees"] = negated(pitchDegrees)
	}
	return inverseCall{tool: "rotate_model", input: mustMarshal(reversedInput)}, true
}

// inverseOfZoom zooms by the reciprocal: the page scales the camera's distance by 1 / factor, so 1 / factor scales it
// back. The page clamps the factor to 0.3 through 3 first, so the reciprocal is taken of the clamped factor. A factor
// under one third was applied whole, but its reciprocal is more than the page takes in one call.
func inverseOfZoom(input map[string]any) (inverseCall, bool) {
	factor, hasFactor := numberInput(input, "factor")
	if !hasFactor || factor <= 0 {
		return inverseCall{}, false
	}
	appliedFactor := math.Min(largestZoomFactor, math.Max(smallestZoomFactor, factor))
	if appliedFactor < 1/largestZoomFactor {
		return inverseCall{}, false
	}
	reversedFactor := math.Min(largestZoomFactor, 1/appliedFactor)
	return inverseCall{tool: "zoom", input: mustMarshal(map[string]any{"factor": reversedFactor})}, true
}

// inverseOfSeekRelative seeks the same distance the other way.
func inverseOfSeekRelative(input map[string]any) (inverseCall, bool) {
	seconds, hasSeconds := numberInput(input, "seconds")
	if !hasSeconds {
		return inverseCall{}, false
	}
	return inverseCall{tool: "seek_relative", input: mustMarshal(map[string]any{"seconds": negated(seconds)})}, true
}

// inverseOfFlippingAFlag sets the flag the other way. The page reads the flag as true only for the boolean true, so an
// input with no boolean there has no inverse.
func inverseOfFlippingAFlag(tool toolName, flagName string) inverseBuilder {
	return func(input map[string]any) (inverseCall, bool) {
		flagValue, flagIsABoolean := input[flagName].(bool)
		if !flagIsABoolean {
			return inverseCall{}, false
		}
		return inverseCall{tool: tool, input: mustMarshal(map[string]any{flagName: !flagValue})}, true
	}
}

// inverseIsACallWithNoInput is the pair of a tool that takes no input.
func inverseIsACallWithNoInput(pairedTool toolName) inverseBuilder {
	return func(map[string]any) (inverseCall, bool) {
		return inverseCall{tool: pairedTool, input: json.RawMessage("{}")}, true
	}
}

// noteChange puts a change at the front of the run's record, made to the scene the command saw, and drops the oldest past
// the limit.
func (run *sessionRun) noteChange(change appliedChange) {
	sceneSeen := run.scene
	change.scene = &sceneSeen
	run.changes = slices.Insert(run.changes, 0, change)
	if len(run.changes) > mostAppliedChangesKept {
		run.changes = run.changes[:mostAppliedChangesKept]
	}
}

// noteTheScreenChanged records a call the app finished, when its outcome says the screen changed. A hand-off counts, as
// appliedChange says.
func (run *sessionRun) noteTheScreenChanged(finishedCall toolCall, outcome voiceToolOutcome) {
	if outcome != voiceToolChanged && outcome != voiceToolHandedOff {
		return
	}
	run.noteChange(appliedChange{tool: finishedCall.Name, input: inputWithoutConfirmation(finishedCall.Input)})
}

// noteFinishedCall keeps what a finished call leaves behind: its action line, which the next command reads if this one is
// cancelled, and the change to the record. An undo that changed the screen removes the change it reversed and records
// nothing of its own, so the same change is never undone twice and the change before it is next. The inverse call's own
// line is the action line, since that is what ran on the screen.
func (run *sessionRun) noteFinishedCall(ranCall toolCall, outcome voiceToolOutcome, resultText string, wasAnUndo bool) {
	run.actionLines = append(run.actionLines, voiceToolActionLine(ranCall, outcome, resultText))
	if wasAnUndo && outcome == voiceToolChanged {
		run.changes = run.changes[1:]
		return
	}
	run.noteTheScreenChanged(ranCall, outcome)
}

// inverseOfTheNewestChange is the call that undoes the newest change, or false when there is no change, it has no inverse,
// or the tool that would reverse it is not one the command offers.
func (run *sessionRun) inverseOfTheNewestChange(isOffered func(toolName) bool) (inverseCall, bool) {
	if len(run.changes) == 0 {
		return inverseCall{}, false
	}
	inverse, hasAnInverse := run.changes[0].inverse()
	if !hasAnInverse || !isOffered(inverse.tool) {
		return inverseCall{}, false
	}
	return inverse, true
}

// withTheUndoOffer is the command's tools with undo_last_change added, when the newest change can be undone with a tool the
// command offers. It is added last, so it never moves the app's own tools. An app tool with the same name is dropped,
// since the harness handles every call to that name itself and the model must read the harness's description.
func withTheUndoOffer(appOffers []voiceToolOffer, run *sessionRun) []voiceToolOffer {
	offers := slices.DeleteFunc(slices.Clone(appOffers), func(offer voiceToolOffer) bool { return toolName(offer.Name) == undoLastChangeTool })
	_, canBeUndone := run.inverseOfTheNewestChange(func(name toolName) bool {
		return slices.ContainsFunc(offers, func(offer voiceToolOffer) bool { return toolName(offer.Name) == name })
	})
	if !canBeUndone {
		return offers
	}
	return append(offers, undoLastChangeOffer)
}

// resultOfTheUndo is the result the model reads for undo_last_change: the app's result for the inverse call, under the
// model's own call ID, with a line that says what ran. The app's text can hold page text, so the caller runs the result
// through tagSafeToolResult like any other.
func resultOfTheUndo(modelCall toolCall, ranCall toolCall, appResult toolResultMessage) toolResultMessage {
	appResult.ToolUseID = modelCall.ID
	appResult.Content = mustMarshal(fmt.Sprintf("Undid the newest change by running %s %s. The app said: %s", ranCall.Name, ranCall.Input, voiceToolResultText(appResult)))
	return appResult
}

// appliedChangesOfASeed is the record a seeded session starts with, newest first: the calls of the seeded messages that did
// not fail, then the interrupted command's calls that did not fail, which are newer than every message. A seed carries no
// outcome, so every call that did not fail counts as a change, a lookup included. That is the cautious reading, since a
// recorded lookup has no inverse and so only stops an undo from reaching past it.
func appliedChangesOfASeed(messages []anthropic.MessageParam, interruptedActionLines []string) []appliedChange {
	var changesOldestFirst []appliedChange
	for messageIndex, message := range messages {
		if message.Role != anthropic.MessageParamRoleAssistant || messageIndex+1 >= len(messages) {
			continue
		}
		for _, block := range message.Content {
			if block.OfToolUse == nil {
				continue
			}
			isError, _, found := toolResultOf(messages[messageIndex+1], block.OfToolUse.ID)
			if !found || isError {
				continue
			}
			input, _ := json.Marshal(block.OfToolUse.Input)
			changesOldestFirst = append(changesOldestFirst, appliedChange{tool: toolName(block.OfToolUse.Name), input: inputWithoutConfirmation(input)})
		}
	}
	for _, actionLine := range interruptedActionLines {
		if change, callDidNotFail := appliedChangeOfActionLine(actionLine); callDidNotFail {
			changesOldestFirst = append(changesOldestFirst, change)
		}
	}
	slices.Reverse(changesOldestFirst)
	if len(changesOldestFirst) > mostAppliedChangesKept {
		changesOldestFirst = changesOldestFirst[:mostAppliedChangesKept]
	}
	return changesOldestFirst
}

// appliedChangeOfActionLine reads a call back out of its action line, `name {input} -> ok`, which voiceToolActionLine
// writes. It is false for a line of a failed call and for a line it cannot read. The input is read as one JSON value, since
// it can hold " -> " inside a string.
func appliedChangeOfActionLine(actionLine string) (appliedChange, bool) {
	name, afterName, hasInput := strings.Cut(actionLine, " ")
	if !hasInput {
		return appliedChange{}, false
	}
	decoder := json.NewDecoder(strings.NewReader(afterName))
	var input json.RawMessage
	if decoder.Decode(&input) != nil {
		return appliedChange{}, false
	}
	if strings.TrimSpace(afterName[decoder.InputOffset():]) != "-> ok" {
		return appliedChange{}, false
	}
	return appliedChange{tool: toolName(name), input: input}, true
}
