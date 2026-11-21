package main

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/anthropics/anthropic-sdk-go"
)

// ---- The inverse table ----

func inverseOf(tool toolName, inputJSON string) (inverseCall, bool) {
	return appliedChange{tool: tool, input: json.RawMessage(inputJSON)}.inverse()
}

func TestEachChangeInTheInverseTableHasTheCallThatReversesItsOwnInput(t *testing.T) {
	cases := []struct {
		name        string
		tool        toolName
		input       string
		wantTool    toolName
		wantInput   string
		wantInverse bool
	}{
		{name: "a left turn turns right", tool: "rotate_model", input: `{"yawDegrees":-45}`, wantTool: "rotate_model", wantInput: `{"yawDegrees":45}`, wantInverse: true},
		{name: "a turn that also tilted tilts back", tool: "rotate_model", input: `{"yawDegrees":90,"pitchDegrees":30}`, wantTool: "rotate_model", wantInput: `{"pitchDegrees":-30,"yawDegrees":-90}`, wantInverse: true},
		{name: "a tilt alone with no turn", tool: "rotate_model", input: `{"yawDegrees":0,"pitchDegrees":30}`, wantTool: "rotate_model", wantInput: `{"pitchDegrees":-30,"yawDegrees":0}`, wantInverse: true},
		{name: "a turn of zero writes 0 and never -0", tool: "rotate_model", input: `{"yawDegrees":0}`, wantTool: "rotate_model", wantInput: `{"yawDegrees":0}`, wantInverse: true},
		{name: "a turn past the page's limit reverses by the same amount, which clamps the same way", tool: "rotate_model", input: `{"yawDegrees":400}`, wantTool: "rotate_model", wantInput: `{"yawDegrees":-400}`, wantInverse: true},
		{name: "a zoom in by 2 zooms out by a half", tool: "zoom", input: `{"factor":2}`, wantTool: "zoom", wantInput: `{"factor":0.5}`, wantInverse: true},
		{name: "a zoom out by a half zooms in by 2", tool: "zoom", input: `{"factor":0.5}`, wantTool: "zoom", wantInput: `{"factor":2}`, wantInverse: true},
		{name: "a zoom in by 1.3 zooms by its reciprocal", tool: "zoom", input: `{"factor":1.3}`, wantTool: "zoom", wantInput: `{"factor":0.7692307692307692}`, wantInverse: true},
		{name: "a zoom past the page's limit reverses what the page applied, which is 3", tool: "zoom", input: `{"factor":5}`, wantTool: "zoom", wantInput: `{"factor":0.3333333333333333}`, wantInverse: true},
		{name: "a zoom out by a third is the farthest a single call can reverse", tool: "zoom", input: `{"factor":0.3333333333333333}`, wantTool: "zoom", wantInput: `{"factor":3}`, wantInverse: true},
		{name: "a zoom out past a third has an inverse bigger than one call can make", tool: "zoom", input: `{"factor":0.3}`},
		{name: "a zoom that failed on a factor of zero has none", tool: "zoom", input: `{"factor":0}`},
		{name: "a skip ahead skips back", tool: "seek_relative", input: `{"seconds":30}`, wantTool: "seek_relative", wantInput: `{"seconds":-30}`, wantInverse: true},
		{name: "a skip back skips ahead", tool: "seek_relative", input: `{"seconds":-10.5}`, wantTool: "seek_relative", wantInput: `{"seconds":10.5}`, wantInverse: true},
		{name: "showing labels hides them", tool: "set_labels", input: `{"visible":true}`, wantTool: "set_labels", wantInput: `{"visible":false}`, wantInverse: true},
		{name: "hiding labels shows them", tool: "set_labels", input: `{"visible":false}`, wantTool: "set_labels", wantInput: `{"visible":true}`, wantInverse: true},
		{name: "opening the cutaway closes it", tool: "set_inside_view", input: `{"open":true}`, wantTool: "set_inside_view", wantInput: `{"open":false}`, wantInverse: true},
		{name: "closing the cutaway opens it", tool: "set_inside_view", input: `{"open":false}`, wantTool: "set_inside_view", wantInput: `{"open":true}`, wantInverse: true},
		{name: "a pause plays", tool: "pause_video", input: `{}`, wantTool: "play_video", wantInput: `{}`, wantInverse: true},
		{name: "a play pauses", tool: "play_video", input: `{}`, wantTool: "pause_video", wantInput: `{}`, wantInverse: true},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			inverse, hasAnInverse := inverseOf(testCase.tool, testCase.input)
			if hasAnInverse != testCase.wantInverse {
				t.Fatalf("has an inverse: got %v, want %v (inverse %s %s)", hasAnInverse, testCase.wantInverse, inverse.tool, inverse.input)
			}
			if !hasAnInverse {
				return
			}
			if inverse.tool != testCase.wantTool || string(inverse.input) != testCase.wantInput {
				t.Errorf("inverse of %s %s:\n got %s %s\nwant %s %s", testCase.tool, testCase.input, inverse.tool, inverse.input, testCase.wantTool, testCase.wantInput)
			}
		})
	}
}

// A change and its inverse undo each other: the inverse of the inverse is the change, for every tool with a numeric or
// boolean input. The floats are compared with a tolerance, since 1 / (1 / 1.3) is not exactly 1.3.
func TestTheInverseOfAnInverseIsTheChangeItself(t *testing.T) {
	changes := []appliedChange{
		{tool: "rotate_model", input: json.RawMessage(`{"yawDegrees":-45,"pitchDegrees":12.5}`)},
		{tool: "zoom", input: json.RawMessage(`{"factor":1.3}`)},
		{tool: "zoom", input: json.RawMessage(`{"factor":0.77}`)},
		{tool: "seek_relative", input: json.RawMessage(`{"seconds":-30}`)},
		{tool: "set_labels", input: json.RawMessage(`{"visible":true}`)},
		{tool: "set_inside_view", input: json.RawMessage(`{"open":false}`)},
		{tool: "pause_video", input: json.RawMessage(`{}`)},
		{tool: "play_video", input: json.RawMessage(`{}`)},
	}
	for _, change := range changes {
		inverse, found := change.inverse()
		if !found {
			t.Fatalf("%s %s has no inverse", change.tool, change.input)
		}
		backAgain, found := appliedChange{tool: inverse.tool, input: inverse.input}.inverse()
		if !found {
			t.Fatalf("the inverse %s %s has no inverse", inverse.tool, inverse.input)
		}
		if backAgain.tool != change.tool || !jsonNumbersAreClose(t, string(backAgain.input), string(change.input)) {
			t.Errorf("%s %s came back as %s %s", change.tool, change.input, backAgain.tool, backAgain.input)
		}
	}
}

func jsonNumbersAreClose(t *testing.T, gotJSON string, wantJSON string) bool {
	t.Helper()
	var got, want map[string]any
	if json.Unmarshal([]byte(gotJSON), &got) != nil || json.Unmarshal([]byte(wantJSON), &want) != nil || len(got) != len(want) {
		return false
	}
	for key, wantValue := range want {
		gotNumber, gotIsANumber := got[key].(float64)
		wantNumber, wantIsANumber := wantValue.(float64)
		if gotIsANumber != wantIsANumber || (gotIsANumber && math.Abs(gotNumber-wantNumber) > 1e-9) || (!gotIsANumber && got[key] != wantValue) {
			return false
		}
	}
	return true
}

// Each of these is left out of the table, because its inverse needs state the input does not hold or has no opposite.
func TestAToolWhoseInverseNeedsStateItsInputLacksHasNoInverse(t *testing.T) {
	for _, change := range []appliedChange{
		{tool: "explode_view", input: json.RawMessage(`{"amount":1}`)},
		{tool: "set_speed", input: json.RawMessage(`{"rate":2}`)},
		{tool: "seek_to_time", input: json.RawMessage(`{"seconds":95}`)},
		{tool: "seek_to_moment", input: json.RawMessage(`{"query":"the gills"}`)},
		{tool: "zoom_to_part", input: json.RawMessage(`{"label":"piston"}`)},
		{tool: "reset_view", input: json.RawMessage(`{}`)},
		{tool: "set_control", input: json.RawMessage(`{"name":"angle","value":45}`)},
		{tool: "run_simulation", input: json.RawMessage(`{}`)},
		{tool: "close_scene", input: json.RawMessage(`{}`)},
		{tool: "pop_out", input: json.RawMessage(`{}`)},
		{tool: "answer_approval", input: json.RawMessage(`{"approved":true}`)},
	} {
		if inverse, hasAnInverse := change.inverse(); hasAnInverse {
			t.Errorf("%s has an inverse, %s %s, though its input does not say what it replaced", change.tool, inverse.tool, inverse.input)
		}
	}
}

// An input the page would treat differently from the number or boolean the inverse assumes has no inverse, so a
// malformed recorded call never produces a guess.
func TestAnInputThatIsNotWhatTheInverseNeedsHasNoInverse(t *testing.T) {
	for _, badChange := range []appliedChange{
		{tool: "rotate_model", input: json.RawMessage(`{"yawDegrees":"45"}`)},
		{tool: "rotate_model", input: json.RawMessage(`{"pitchDegrees":30}`)},
		{tool: "rotate_model", input: json.RawMessage(`{"yawDegrees":45,"pitchDegrees":null}`)},
		{tool: "rotate_model", input: json.RawMessage(`{"yawDegrees":1e999}`)},
		{tool: "zoom", input: json.RawMessage(`{"factor":"2"}`)},
		{tool: "seek_relative", input: json.RawMessage(`{}`)},
		{tool: "set_labels", input: json.RawMessage(`{"visible":"true"}`)},
		{tool: "set_labels", input: json.RawMessage(`{}`)},
		{tool: "set_inside_view", input: json.RawMessage(`{"open":1}`)},
		{tool: "rotate_model", input: json.RawMessage(`[1]`)},
		{tool: "rotate_model", input: json.RawMessage(`not json`)},
	} {
		if inverse, hasAnInverse := badChange.inverse(); hasAnInverse {
			t.Errorf("%s %s has the inverse %s %s", badChange.tool, badChange.input, inverse.tool, inverse.input)
		}
	}
}

// ---- The record ----

func TestTheRecordKeepsTheNewestChangesFirstAndDropsTheOldestPastTheLimit(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("turn it", json.RawMessage(`{}`))
	for changeNumber := 1; changeNumber <= mostAppliedChangesKept+3; changeNumber++ {
		run.noteChange(appliedChange{tool: "seek_relative", input: mustMarshal(map[string]any{"seconds": changeNumber})})
	}
	run.commit()

	next := session.begin("undo that", json.RawMessage(`{}`))
	if len(next.changes) != mostAppliedChangesKept {
		t.Fatalf("the record holds %d changes, want %d", len(next.changes), mostAppliedChangesKept)
	}
	if got, want := string(next.changes[0].input), fmt.Sprintf(`{"seconds":%d}`, mostAppliedChangesKept+3); got != want {
		t.Errorf("the newest change is %s, want %s", got, want)
	}
	if got, want := string(next.changes[len(next.changes)-1].input), `{"seconds":4}`; got != want {
		t.Errorf("the oldest change kept is %s, want %s", got, want)
	}
}

func TestACancelledCommandStillAddsItsFinishedCallsToTheRecordAndAFailedCallAddsNothing(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("turn and zoom", json.RawMessage(`{}`))
	run.noteFinishedCall(toolCall{ID: "a", Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":45,"confirmation":"turned"}`)}, voiceToolChanged, `{"ok":true}`, false)
	run.noteFinishedCall(toolCall{ID: "b", Name: "zoom", Input: json.RawMessage(`{"factor":2}`)}, voiceToolFailed, `{"ok":false,"error":"still loading"}`, false)
	run.noteFinishedCall(toolCall{ID: "c", Name: "find_moment", Input: json.RawMessage(`{"query":"x"}`)}, voiceToolLookedUp, `{"ok":true}`, false)
	run.abandon()

	next := session.begin("undo that", json.RawMessage(`{}`))
	if len(next.changes) != 1 || next.changes[0].tool != "rotate_model" || string(next.changes[0].input) != `{"yawDegrees":45}` {
		t.Errorf("the record after the cancel was %v, want the one rotate_model call with no confirmation", next.changes)
	}
}

func TestAnUndoThatChangedTheScreenRemovesTheChangeItReversedAndRecordsNothingOfItsOwn(t *testing.T) {
	session, _ := newTestSession()
	first := session.begin("zoom in", json.RawMessage(`{}`))
	first.noteFinishedCall(toolCall{Name: "zoom", Input: json.RawMessage(`{"factor":2}`)}, voiceToolChanged, `{"ok":true}`, false)
	first.noteFinishedCall(toolCall{Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":45}`)}, voiceToolChanged, `{"ok":true}`, false)
	first.commit()

	undo := session.begin("undo that", json.RawMessage(`{}`))
	undo.noteFinishedCall(toolCall{Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":-45}`)}, voiceToolChanged, `{"ok":true}`, true)
	if len(undo.changes) != 1 || undo.changes[0].tool != "zoom" {
		t.Fatalf("after the undo the newest change should be the zoom, got %v", undo.changes)
	}
	if want := []string{`rotate_model {"yawDegrees":-45} -> ok`}; !slices.Equal(undo.actionLines, want) {
		t.Errorf("the undo's action line is the inverse call that ran: got %q, want %q", undo.actionLines, want)
	}
	undo.commit()

	if next := session.begin("again", json.RawMessage(`{}`)); len(next.changes) != 1 || next.changes[0].tool != "zoom" {
		t.Errorf("the committed record is %v, want only the zoom", next.changes)
	}
}

func TestAnUndoThatFailedLeavesTheChangeToUndoAgain(t *testing.T) {
	session, _ := newTestSession()
	first := session.begin("turn", json.RawMessage(`{}`))
	first.noteFinishedCall(toolCall{Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":45}`)}, voiceToolChanged, `{"ok":true}`, false)
	first.commit()

	undo := session.begin("undo that", json.RawMessage(`{}`))
	undo.noteFinishedCall(toolCall{Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":-45}`)}, voiceToolFailed, `{"ok":false,"error":"still loading"}`, true)
	undo.commit()

	if next := session.begin("again", json.RawMessage(`{}`)); len(next.changes) != 1 || next.changes[0].tool != "rotate_model" {
		t.Errorf("a failed undo changed the record: %v", next.changes)
	}
}

func TestAResetClearsTheRecordAndACommandThatBeganBeforeItWritesNothingBack(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("turn", json.RawMessage(`{}`))
	run.noteFinishedCall(toolCall{Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":45}`)}, voiceToolChanged, `{"ok":true}`, false)
	session.reset()
	run.commit()

	if next := session.begin("undo that", json.RawMessage(`{}`)); len(next.changes) != 0 {
		t.Errorf("the record after a reset held %v", next.changes)
	}
}

// ---- A seeded session ----

func seededMessagesOfCalls(calls ...[3]string) []anthropic.MessageParam {
	// Each call is {id, name, inputJSON}. Every command is one user message, one assistant turn, and one result message.
	var messages []anthropic.MessageParam
	for commandIndex, call := range calls {
		var input map[string]any
		_ = json.Unmarshal([]byte(call[2]), &input)
		input["confirmation"] = "done"
		messages = append(messages,
			anthropic.NewUserMessage(anthropic.NewTextBlock(fmt.Sprintf("<learner_words>command %d</learner_words>", commandIndex+1))),
			anthropic.NewAssistantMessage(anthropic.NewToolUseBlock(call[0], input, call[1])),
			anthropic.NewUserMessage(anthropic.NewToolResultBlock(call[0], `{"ok":true,"state":null}`, false)),
		)
	}
	return messages
}

func TestASeededSessionStartsWithTheRecordItsMessagesAndInterruptedLinesImply(t *testing.T) {
	session, _ := newTestSession()
	messages := seededMessagesOfCalls(
		[3]string{"toolu_1", "zoom", `{"factor":1.3}`},
		[3]string{"toolu_2", "rotate_model", `{"yawDegrees":-45}`},
	)
	// A call whose result was an error changed nothing.
	messages = append(messages,
		anthropic.NewUserMessage(anthropic.NewTextBlock("<learner_words>command 3</learner_words>")),
		anthropic.NewAssistantMessage(anthropic.NewToolUseBlock("toolu_3", map[string]any{"factor": 2}, "zoom")),
		anthropic.NewUserMessage(anthropic.NewToolResultBlock("toolu_3", `{"ok":false}`, true)),
	)
	if err := session.seed(messages, []string{`rotate_model {"yawDegrees":90} -> ok`, `zoom {"factor":9} -> failed: still loading`}); err != nil {
		t.Fatal(err)
	}

	changes := session.begin("undo that", json.RawMessage(`{}`)).changes
	var got []string
	for _, change := range changes {
		got = append(got, string(change.tool)+" "+string(change.input))
	}
	// Newest first: the interrupted turn, then the messages' calls from the newest, with no confirmation and no failed call.
	want := []string{`rotate_model {"yawDegrees":90}`, `rotate_model {"yawDegrees":-45}`, `zoom {"factor":1.3}`}
	if !slices.Equal(got, want) {
		t.Errorf("the seeded record:\n got %q\nwant %q", got, want)
	}
}

func seededChangesAsText(changes []appliedChange) []string {
	var got []string
	for _, change := range changes {
		got = append(got, string(change.tool)+" "+string(change.input))
	}
	return got
}

// A seed has no outcome of its own, so it must not record a call the real harness would not have recorded.
func TestASeedDoesNotRecordCallsThatNeverRan(t *testing.T) {
	messages := seededMessagesOfCalls([3]string{"toolu_1", "zoom", `{"factor":1.3}`})
	messages = append(messages,
		anthropic.NewUserMessage(anthropic.NewTextBlock("<learner_words>pop it out and turn it</learner_words>")),
		anthropic.NewAssistantMessage(
			anthropic.NewToolUseBlock("toolu_pop", map[string]any{}, "pop_out"),
			anthropic.NewToolUseBlock("toolu_turn", map[string]any{"yawDegrees": 45}, "rotate_model"),
			anthropic.NewToolUseBlock("toolu_zoom2", map[string]any{"factor": 2}, "zoom"),
		),
		anthropic.NewUserMessage(
			anthropic.NewToolResultBlock("toolu_pop", handedOffResultText, false),
			anthropic.NewToolResultBlock("toolu_turn", notRunResultText, false),
			anthropic.NewToolResultBlock("toolu_zoom2", notRunAfterAFailureResultText, false),
		),
	)
	got := seededChangesAsText(appliedChangesOfASeed(messages, nil))
	want := []string{`pop_out {}`, `zoom {"factor":1.3}`}
	if !slices.Equal(got, want) {
		t.Errorf("the seeded record:\n got %q\nwant %q", got, want)
	}
}

func TestASeededUndoRemovesTheChangeItReversedInsteadOfBeingRecorded(t *testing.T) {
	messages := seededMessagesOfCalls(
		[3]string{"toolu_1", "zoom", `{"factor":1.3}`},
		[3]string{"toolu_2", "rotate_model", `{"yawDegrees":45}`},
		[3]string{"toolu_3", "undo_last_change", `{}`},
	)
	got := seededChangesAsText(appliedChangesOfASeed(messages, nil))
	if want := []string{`zoom {"factor":1.3}`}; !slices.Equal(got, want) {
		t.Errorf("the seeded record:\n got %q\nwant %q", got, want)
	}
	// An undo with nothing before it removes nothing and is not recorded.
	if got := appliedChangesOfASeed(seededMessagesOfCalls([3]string{"toolu_1", "undo_last_change", `{}`}), nil); len(got) != 0 {
		t.Errorf("an undo with nothing to reverse was recorded: %v", got)
	}
}

func TestAnInverseLineInTheInterruptedLinesRemovesTheChangeItReversedInsteadOfBeingRecorded(t *testing.T) {
	messages := seededMessagesOfCalls(
		[3]string{"toolu_1", "zoom", `{"factor":1.3}`},
		[3]string{"toolu_2", "rotate_model", `{"yawDegrees":-45,"pitchDegrees":10}`},
	)
	// The interrupted command undid the turn: its line is the inverse call's own line.
	got := seededChangesAsText(appliedChangesOfASeed(messages, []string{`rotate_model {"pitchDegrees":-10,"yawDegrees":45} -> ok`}))
	if want := []string{`zoom {"factor":1.3}`}; !slices.Equal(got, want) {
		t.Errorf("the seeded record:\n got %q\nwant %q", got, want)
	}
	// A line with the inverse's input but another tool is a new change, and so is one with the inverse's tool and another input.
	got = seededChangesAsText(appliedChangesOfASeed(messages, []string{`zoom {"pitchDegrees":-10,"yawDegrees":45} -> ok`}))
	if want := []string{`zoom {"pitchDegrees":-10,"yawDegrees":45}`, `rotate_model {"pitchDegrees":10,"yawDegrees":-45}`, `zoom {"factor":1.3}`}; !slices.Equal(got, want) {
		t.Errorf("the seeded record:\n got %q\nwant %q", got, want)
	}
	// A line that is not the inverse of the newest change is a new change, even for the same tool.
	got = seededChangesAsText(appliedChangesOfASeed(messages, []string{`rotate_model {"yawDegrees":90} -> ok`}))
	if want := []string{`rotate_model {"yawDegrees":90}`, `rotate_model {"pitchDegrees":10,"yawDegrees":-45}`, `zoom {"factor":1.3}`}; !slices.Equal(got, want) {
		t.Errorf("the seeded record:\n got %q\nwant %q", got, want)
	}
}

// The real harness records a cut-off call as a change with no inverse, so a seed that carries its line must too.
func TestASeededCutOffLineIsNeverAnUndo(t *testing.T) {
	messages := seededMessagesOfCalls(
		[3]string{"toolu_1", "zoom", `{"factor":1.3}`},
		[3]string{"toolu_2", "rotate_model", `{"yawDegrees":-45}`},
	)
	// A cut-off line that names the newest change's inverse is not read as the undo, since the harness cannot tell either.
	// A cut-off page call keeps its inverse, as the harness records one (aCutOffCallHasRun).
	record := appliedChangesOfASeed(messages, []string{`rotate_model {"yawDegrees":45} -> cut off, may have run`})
	if got, want := seededChangesAsText(record), []string{`rotate_model {"yawDegrees":45}`, `rotate_model {"yawDegrees":-45}`, `zoom {"factor":1.3}`}; !slices.Equal(got, want) {
		t.Fatalf("the seeded record:\n got %q\nwant %q", got, want)
	}
	if inverse, hasAnInverse := record[0].inverse(); !hasAnInverse || inverse.tool != "rotate_model" || string(inverse.input) != `{"yawDegrees":-45}` {
		t.Errorf("a cut-off page call's inverse: %s %s (%v)", inverse.tool, inverse.input, hasAnInverse)
	}

	// A cut-off video call may not have run, so it has no inverse, and undo is not offered past it.
	videoRecord := appliedChangesOfASeed(seededMessagesOfCalls([3]string{"toolu_1", "pause_video", `{}`}), []string{`play_video {} -> cut off, may have run`})
	if got, want := seededChangesAsText(videoRecord), []string{`play_video {}`, `pause_video {}`}; !slices.Equal(got, want) {
		t.Fatalf("the seeded video record:\n got %q\nwant %q", got, want)
	}
	if !videoRecord[0].effectIsUnknown {
		t.Errorf("a cut-off video call was recorded with an inverse")
	}
	session, _ := newTestSession()
	if err := session.seed(messages, []string{`play_video {} -> cut off, may have run`}); err != nil {
		t.Fatal(err)
	}
	if undoIsOfferedTo(session.begin("undo that", json.RawMessage(`{}`))) {
		t.Errorf("a seeded session offered undo past a cut-off video call")
	}
}

func TestAnActionLineReadsBackIntoTheCallItDescribes(t *testing.T) {
	change, callWasCutOff := appliedChangeOfActionLine(`play_video {} -> cut off, may have run`)
	if !callWasCutOff || change.tool != "play_video" || string(change.input) != `{}` || !change.effectIsUnknown {
		t.Errorf("read %s %s unknown=%v (%v)", change.tool, change.input, change.effectIsUnknown, callWasCutOff)
	}
	if change, _ := appliedChangeOfActionLine(`zoom {"factor":2} -> cut off, may have run`); change.effectIsUnknown {
		t.Errorf("a cut-off page call was read with no inverse")
	}
	if change, _ := appliedChangeOfActionLine(`zoom {"factor":2} -> ok`); change.effectIsUnknown {
		t.Errorf("an ok line was read as a cut-off call")
	}
	change, callDidNotFail := appliedChangeOfActionLine(`rotate_model {"yawDegrees":90,"pitchDegrees":-5} -> ok`)
	if !callDidNotFail || change.tool != "rotate_model" || string(change.input) != `{"yawDegrees":90,"pitchDegrees":-5}` {
		t.Errorf("read %s %s (%v)", change.tool, change.input, callDidNotFail)
	}
	// The input is read as one JSON value, so text with an arrow in it does not end it early.
	change, callDidNotFail = appliedChangeOfActionLine(`find_moment {"query":"a -> ok"} -> ok`)
	if !callDidNotFail || string(change.input) != `{"query":"a -> ok"}` {
		t.Errorf("an arrow inside a string ended the input early: %s (%v)", change.input, callDidNotFail)
	}
	for _, unreadable := range []string{
		`zoom {"factor":9} -> failed: still loading`,
		`zoom {"factor":9}`,
		`zoom`,
		`zoom not-json -> ok`,
		`zoom {"factor":9} -> ok and then some`,
		``,
	} {
		if change, callDidNotFail := appliedChangeOfActionLine(unreadable); callDidNotFail {
			t.Errorf("%q was read as %s %s", unreadable, change.tool, change.input)
		}
	}
}

// ---- Which tools are offered ----

// undoTestTools are the tools a command offers in these tests, in the app's wire shape.
const undoTestTools = `[` +
	`{"name":"rotate_model","description":"Turns the model.","inputSchema":{"properties":{"yawDegrees":{"type":"number"},"pitchDegrees":{"type":"number"}},"required":["yawDegrees"],"type":"object"},"readOnly":false},` +
	`{"name":"zoom","description":"Zooms.","inputSchema":{"properties":{"factor":{"type":"number"}},"required":["factor"],"type":"object"},"readOnly":false},` +
	`{"name":"explode_view","description":"Pulls the parts apart.","inputSchema":{"properties":{"amount":{"type":"number"}},"required":["amount"],"type":"object"},"readOnly":false},` +
	`{"name":"pause_video","description":"Pauses.","inputSchema":{"properties":{},"type":"object"},"readOnly":false},` +
	`{"name":"play_video","description":"Plays.","inputSchema":{"properties":{},"type":"object"},"readOnly":false},` +
	`{"name":"find_moment","description":"Finds a moment.","inputSchema":{"properties":{"query":{"type":"string"}},"required":["query"],"type":"object"},"readOnly":true},` +
	`{"name":"pop_out","description":"Pops out.","inputSchema":{"properties":{},"type":"object"},"readOnly":false}` +
	`]`

func voiceCommandLineWithTools(commandID string, transcript string, toolsJSON string) string {
	return fmt.Sprintf(`{"type":"voice_command","taskID":%q,"transcript":%q,"sceneState":{"page":"framePopout"},"tools":%s}`, commandID, transcript, toolsJSON)
}

func undoCommandLine(commandID string, transcript string) string {
	return voiceCommandLineWithTools(commandID, transcript, undoTestTools)
}

func offersUndo(t *testing.T, requestBody map[string]any) bool {
	t.Helper()
	return slices.Contains(offeredToolNamesOf(t, requestBody), string(undoLastChangeTool))
}

// A fake Worker that answers by what the learner just said, so a test reads as a script of commands.
func workerThatAnswersByWords(t *testing.T, answers map[string][]string) *fakeWorker {
	t.Helper()
	return newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, _ int) {
		learnerWords := lastUserText(t, recorded.body)
		for words, blocks := range answers {
			if strings.Contains(learnerWords, "<learner_words>"+words+"</learner_words>") {
				writeBrainReply(writer, "tool_use", blocks...)
				return
			}
		}
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"Okay."}`)
	})
}

func TestUndoIsOfferedOnlyWhileTheNewestChangeHasAnInverseTheCommandOffers(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it"}`)},
		"explode it":   {brainToolUse("toolu_explode", "explode_view", `{"amount":1,"confirmation":"pulled it apart"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	runCommand := func(commandID string, transcript string, toolUseID string, result string) {
		driver.send(undoCommandLine(commandID, transcript))
		if toolUseID != "" {
			driver.expectLine("tool_call")
			driver.send(voiceToolResultLine(commandID, toolUseID, voiceToolChanged, result))
		}
		driver.expectLine("voice_command_finished")
	}

	// No change yet.
	runCommand("command-1", "what is this?", "", "")
	// A left turn has an inverse, and rotate_model is offered.
	runCommand("command-2", "turn it left", "toolu_turn", `{"ok":true,"state":null}`)
	// An explode has none, so it stands between "undo that" and the turn.
	runCommand("command-3", "explode it", "toolu_explode", `{"ok":true,"state":null}`)
	runCommand("command-4", "what is this?", "", "")

	// The commands carry the record as it was when each began, so command 3 is the only one whose record has the turn on top.
	wantOffers := []bool{false, false, true, false}
	requests := worker.requests()
	if len(requests) != 4 {
		t.Fatalf("the Worker got %d requests, want 4", len(requests))
	}
	for requestIndex, wantOffer := range wantOffers {
		if got := offersUndo(t, requests[requestIndex].body); got != wantOffer {
			t.Errorf("command %d offered undo_last_change: %v, want %v (tools %v)", requestIndex+1, got, wantOffer, offeredToolNamesOf(t, requests[requestIndex].body))
		}
	}
	// It comes last, so the app's own tools keep their positions.
	if names := offeredToolNamesOf(t, requests[2].body); names[len(names)-1] != string(undoLastChangeTool) || len(names) != 8 {
		t.Errorf("command 3's tools were %v, want the app's 7 and undo_last_change last", names)
	}
}

func TestUndoIsNotOfferedWhenTheToolThatReversesTheChangeIsNotOffered(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned it"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true,"state":null}`))
	driver.expectLine("voice_command_finished")

	// The scene closed meanwhile, so the app no longer offers rotate_model.
	driver.send(voiceCommandLineWithTools("command-2", "what is this?", `[{"name":"zoom","description":"Zooms.","inputSchema":{"properties":{"factor":{"type":"number"}},"required":["factor"],"type":"object"},"readOnly":false}]`))
	driver.expectLine("voice_command_finished")

	if offersUndo(t, worker.requests()[1].body) {
		t.Errorf("undo_last_change was offered with no rotate_model to reverse the turn: %v", offeredToolNamesOf(t, worker.requests()[1].body))
	}
}

func TestAnAppToolNamedUndoLastChangeIsDroppedSinceTheHarnessOwnsThatName(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("undo that", json.RawMessage(`{}`))
	appOffers := []voiceToolOffer{{Name: "undo_last_change", Description: "The app's own."}, {Name: "zoom"}}

	for _, offer := range withTheUndoOffer(appOffers, run) {
		if offer.Name == "undo_last_change" {
			t.Errorf("an app tool called undo_last_change reached the model: %s", offer.Description)
		}
	}
}

func TestUndoLastChangeHasTheSameDescriptionInEveryCommand(t *testing.T) {
	session, _ := newTestSession()
	run := session.begin("turn", json.RawMessage(`{}`))
	run.noteChange(appliedChange{tool: "rotate_model", input: json.RawMessage(`{"yawDegrees":45}`)})
	offers := withTheUndoOffer([]voiceToolOffer{{Name: "rotate_model"}}, run)

	// A description that named the change would change with every command and throw away the cached tool list.
	if last := offers[len(offers)-1]; last.Description != undoLastChangeOffer.Description || strings.Contains(last.Description, "45") {
		t.Errorf("the offer's description changed with the change: %s", last.Description)
	}
	if undoLastChangeOffer.ReadOnly {
		t.Error("undo_last_change changes the screen, so it is not read only and needs a confirmation")
	}
}

// ---- The call ----

func TestUndoLastChangeReachesTheAppAsTheInverseOfTheNewestChangeAndItsConfirmationIsSpoken(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"pitchDegrees":10,"confirmation":"turned it left"}`)},
		"undo that":    {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true,"state":{"yawDegrees":-45}}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "undo that"))
	// The app gets the opposite of the turn as an ordinary call, under the model's ID plus a suffix, from turn 0.
	if got, want := driver.expectLine("tool_call"), `{"type":"tool_call","taskID":"command-2","toolUseID":"toolu_undo-undo","name":"rotate_model","input":{"pitchDegrees":-10,"yawDegrees":45},"turnIndex":0}`; got != want {
		t.Fatalf("the inverse call:\n got %s\nwant %s", got, want)
	}
	driver.send(voiceToolResultLine("command-2", "toolu_undo-undo", voiceToolChanged, `{"ok":true,"state":{"yawDegrees":0}}`))
	if got, want := driver.expectLine("voice_command_finished"), `{"type":"voice_command_finished","taskID":"command-2","spokenLine":"undid it","gaveUp":false}`; got != want {
		t.Fatalf("finished:\n got %s\nwant %s", got, want)
	}
	// The log names the model's call, and never the inverse's input.
	if !driver.logsContainLineEndingWith("Brain: turn 1 ", " ms, calls undo_last_change") {
		t.Errorf("the turn line did not name the model's call: %v", driver.logs)
	}

	// The same change cannot be undone twice: the third command's tools no longer hold undo_last_change, and the session
	// shows the model the undo's tool_use under its own ID with a result that says what ran.
	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLine("voice_command_finished")
	third := worker.requests()[2].body
	if offersUndo(t, third) {
		t.Errorf("the undone change is offered for undo again: %v", offeredToolNamesOf(t, third))
	}
	requestText := string(mustMarshal(third))
	for _, want := range []string{`"id":"toolu_undo"`, `"name":"undo_last_change"`, `"tool_use_id":"toolu_undo"`, `Undid the newest change by running rotate_model {\"pitchDegrees\":-10,\"yawDegrees\":45}. The app said:`} {
		if !strings.Contains(requestText, want) {
			t.Errorf("the next request lacks %s: %s", want, requestText)
		}
	}
	if strings.Contains(requestText, `toolu_undo-undo`) {
		t.Errorf("the inverse call's own ID leaked into the model's history: %s", requestText)
	}
	everyToolUseHasItsResult(t, third)
}

func TestUndoRevealsTheChangeBeforeIt(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"zoom in":      {brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed"}`)},
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"undo that":    {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	for step, command := range []struct{ words, toolUseID string }{{"zoom in", "toolu_zoom"}, {"turn it left", "toolu_turn"}} {
		commandID := fmt.Sprintf("command-%d", step+1)
		driver.send(undoCommandLine(commandID, command.words))
		driver.expectLine("tool_call")
		driver.send(voiceToolResultLine(commandID, command.toolUseID, voiceToolChanged, `{"ok":true}`))
		driver.expectLine("voice_command_finished")
	}

	// The first undo turns back, and the second reaches the zoom: the stack is popped once per undo.
	driver.send(undoCommandLine("command-3", "undo that"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"name":"rotate_model","input":{"yawDegrees":45}`) {
		t.Fatalf("the first undo was %s", got)
	}
	driver.send(voiceToolResultLine("command-3", "toolu_undo-undo", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")
	driver.send(undoCommandLine("command-4", "undo that"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"name":"zoom","input":{"factor":0.5}`) {
		t.Fatalf("the second undo was %s", got)
	}
	driver.send(voiceToolResultLine("command-4", "toolu_undo-undo", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	// Nothing is left to undo.
	driver.send(undoCommandLine("command-5", "what is this?"))
	driver.expectLine("voice_command_finished")
	requests := worker.requests()
	if offersUndo(t, requests[len(requests)-1].body) {
		t.Errorf("undo_last_change was offered after both changes were undone")
	}
}

func TestACommandThatDidNotOfferUndoRefusesACallToItWithoutAskingTheApp(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		if requestNumber == 1 {
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`))
			return
		}
		writeBrainReply(writer, "end_turn", `{"type":"text","text":"There is nothing to undo."}`)
	})
	driver := startHarness(t, worker.server.URL)

	driver.send(undoCommandLine("command-1", "undo that"))
	if got, want := driver.expectLine("voice_command_finished"), `{"type":"voice_command_finished","taskID":"command-1","spokenLine":"There is nothing to undo.","gaveUp":false}`; got != want {
		t.Fatalf("finished:\n got %s\nwant %s", got, want)
	}
}

func TestAnUndoFollowedByAnotherCallRunsBothInOrderAndTheSecondChangeIsTheNewest(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left":       {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"undo that and zoom": {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`), brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed in"}`)},
		"undo that":          {brainToolUse("toolu_undo_again", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "undo that and zoom"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"toolUseID":"toolu_undo-undo","name":"rotate_model","input":{"yawDegrees":45}`) {
		t.Fatalf("the first call was %s", got)
	}
	driver.send(voiceToolResultLine("command-2", "toolu_undo-undo", voiceToolChanged, `{"ok":true}`))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"toolUseID":"toolu_zoom","name":"zoom","input":{"factor":2}`) {
		t.Fatalf("the second call was %s", got)
	}
	driver.send(voiceToolResultLine("command-2", "toolu_zoom", voiceToolChanged, `{"ok":true}`))
	if got := driver.expectLine("voice_command_finished"); !strings.Contains(got, `"spokenLine":"undid it zoomed in"`) {
		t.Fatalf("finished: %s", got)
	}

	// The turn is gone from the record and the zoom is the newest change.
	driver.send(undoCommandLine("command-3", "undo that"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"name":"zoom","input":{"factor":0.5}`) {
		t.Fatalf("the next undo should reverse the zoom, got %s", got)
	}
}

// ---- Failures, cancels, and hand-offs ----

func TestAnInverseThatFailedGoesBackToTheModelAndLeavesTheChangeToUndoAgain(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`))
		case 2:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`))
		case 3:
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"The scene is still loading."}`)
		default:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_undo_again", "undo_last_change", `{"confirmation":"undid it"}`))
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "undo that"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_undo-undo", voiceToolFailed, `{"ok":false,"error":"The scene is still loading","state":null}`))
	if got := driver.expectLine("voice_command_finished"); !strings.Contains(got, `"spokenLine":"The scene is still loading."`) {
		t.Fatalf("finished: %s", got)
	}
	// The model read the failure under its own call's ID, as an error.
	failedResult := jsonValueAt(t, worker.requests()[2].body, "messages", 4, "content", 0)
	if jsonValueAt(t, failedResult, "tool_use_id") != "toolu_undo" || jsonValueAt(t, failedResult, "is_error") != true {
		t.Errorf("the failed undo's result was %v", failedResult)
	}
	// The text says the undo did not work, never that it undid anything, so the model cannot tell the learner it did.
	failedText := fmt.Sprint(jsonValueAt(t, failedResult, "content", 0, "text"))
	if !strings.HasPrefix(failedText, "The undo did not work: ") || strings.Contains(failedText, "Undid") {
		t.Errorf("the failed undo's text was %q", failedText)
	}

	driver.send(undoCommandLine("command-3", "undo that"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"name":"rotate_model","input":{"yawDegrees":45}`) {
		t.Fatalf("the change was not offered again after a failed undo: %s", got)
	}
}

func TestOnlyAnInverseThatChangedTheScreenIsReportedAsUndone(t *testing.T) {
	modelCall := toolCall{ID: "toolu_undo", Name: undoLastChangeTool}
	ranCall := toolCall{ID: "toolu_undo-undo", Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":45}`)}
	for _, testCase := range []struct {
		outcome voiceToolOutcome
		want    string
	}{
		{voiceToolChanged, `Undid the newest change by running rotate_model {"yawDegrees":45}. The app said: still loading`},
		{voiceToolFailed, `The undo did not work: still loading`},
		{voiceToolLookedUp, `The undo did not work: still loading`},
	} {
		appResult := toolResultMessage{ToolUseID: ranCall.ID, Content: mustMarshal("still loading"), Outcome: testCase.outcome}
		got := voiceToolResultText(resultOfTheUndo(modelCall, ranCall, appResult, testCase.outcome))
		if got != testCase.want {
			t.Errorf("outcome %v:\n got %q\nwant %q", testCase.outcome, got, testCase.want)
		}
	}
}

func TestAHandOffStandsBetweenUndoAndAnOlderChange(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"pop it out":   {brainToolUse("toolu_pop", "pop_out", `{"confirmation":"popping it out"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")
	driver.send(undoCommandLine("command-2", "pop it out"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_pop", voiceToolHandedOff, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-3", "undo that"))
	driver.expectLine("voice_command_finished")

	requests := worker.requests()
	if !offersUndo(t, requests[1].body) {
		t.Errorf("undo_last_change was not offered before the pop-out")
	}
	if offersUndo(t, requests[2].body) {
		t.Errorf("undo_last_change was offered behind a pop-out, so it would turn the model back past it: %v", offeredToolNamesOf(t, requests[2].body))
	}
}

func TestALookupAndAFailedCallChangeNothingSoTheEarlierChangeStaysTheNewest(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, recorded recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`))
		case 2:
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_find", "find_moment", `{"query":"engine"}`),
				brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed"}`))
		default:
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"It did not work."}`)
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "find the engine and zoom"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_find", voiceToolLookedUp, `{"ok":true,"result":[]}`))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_zoom", voiceToolFailed, `{"ok":false,"error":"still loading"}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLine("voice_command_finished")
	if !offersUndo(t, worker.requests()[3].body) {
		t.Errorf("a lookup and a failed call hid the turn from undo: %v", offeredToolNamesOf(t, worker.requests()[3].body))
	}
}

// The newest change can change inside one command. This turn calls explode_view, which has no inverse, and then
// undo_last_change, which was offered because the turn on top of the record at the start was a rotate. The undo must fail
// and turn nothing back, since the explode is now the newest change.
func TestAnUndoAfterAnExplodeInTheSameCommandFailsAndNeverReachesTheApp(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`))
		case 2:
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_explode", "explode_view", `{"amount":1,"confirmation":"pulled it apart"}`),
				brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`))
		default:
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"I can't undo that exactly."}`)
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "explode it and undo that"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_explode", voiceToolChanged, `{"ok":true}`))
	// The next line is the end: the undo was refused here, with no tool_call for the inverse of the turn.
	if got := driver.expectLine("voice_command_finished"); !strings.Contains(got, `"spokenLine":"I can't undo that exactly."`) {
		t.Fatalf("finished: %s", got)
	}
	refusal := jsonValueAt(t, worker.requests()[2].body, "messages", 4, "content", 1)
	if jsonValueAt(t, refusal, "tool_use_id") != "toolu_undo" || jsonValueAt(t, refusal, "is_error") != true {
		t.Errorf("the refused undo's result was %v", refusal)
	}
}

// An undo that cannot run is a failed call, so the calls after it in the reply are not run, as after any failed call.
func TestAnUndoThatCannotBeUndoneStopsTheLaterCallsOfItsReply(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`))
		case 2:
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_explode", "explode_view", `{"amount":1,"confirmation":"pulled it apart"}`),
				brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`),
				brainToolUse("toolu_pop", "pop_out", `{"confirmation":"popping it out"}`))
		default:
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"I can't undo that exactly."}`)
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "explode it, undo that, and pop it out"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_explode", voiceToolChanged, `{"ok":true}`))
	// The next line is the end: the pop-out after the refused undo never reached the app.
	driver.expectLine("voice_command_finished")
	notRun := jsonValueAt(t, worker.requests()[2].body, "messages", 4, "content", 2)
	if jsonValueAt(t, notRun, "tool_use_id") != "toolu_pop" || !strings.Contains(fmt.Sprint(jsonValueAt(t, notRun, "content", 0, "text")), "Not run") {
		t.Errorf("the pop-out's result was %v", notRun)
	}
}

// An inverse the app reports as failed stops the later calls of the reply too.
func TestAnInverseThatFailedStopsTheLaterCallsOfItsReply(t *testing.T) {
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, requestNumber int) {
		switch requestNumber {
		case 1:
			writeBrainReply(writer, "tool_use", brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`))
		case 2:
			writeBrainReply(writer, "tool_use",
				brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`),
				brainToolUse("toolu_pop", "pop_out", `{"confirmation":"popping it out"}`))
		default:
			writeBrainReply(writer, "end_turn", `{"type":"text","text":"The scene is still loading."}`)
		}
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "undo that and pop it out"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-2", "toolu_undo-undo", voiceToolFailed, `{"ok":false,"error":"still loading","state":null}`))
	driver.expectLine("voice_command_finished")
	notRun := jsonValueAt(t, worker.requests()[2].body, "messages", 4, "content", 1)
	if jsonValueAt(t, notRun, "tool_use_id") != "toolu_pop" || !strings.Contains(fmt.Sprint(jsonValueAt(t, notRun, "content", 0, "text")), "Not run") {
		t.Errorf("the pop-out's result was %v", notRun)
	}
}

// An answered approval changes what the learner sees and has no inverse, so it stands between "undo that" and an older
// change, as a hand-off does.
func TestAnAnsweredApprovalStandsBetweenUndoAndAnOlderChange(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"yes":          {brainToolUse("toolu_yes", "answer_approval", `{"approved":true,"always":false,"confirmation":"allowed it"}`)},
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, appSecret: "test-secret", benchMode: true})
	driver.send(voiceCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(seedApprovalRequestLine("approval-waiting", "sends"))
	driver.send(approvalVoiceCommandLine("command-2", "yes", "approval-waiting"))
	driver.expectLine("voice_command_finished")
	driver.send(voiceCommandLine("command-3", "undo that"))
	driver.expectLine("voice_command_finished")

	requests := worker.requests()
	if !slices.Contains(offeredToolNamesOf(t, requests[1].body), "answer_approval") {
		t.Fatal("the approval was not answered by a voice command, so this test checks nothing")
	}
	if offersUndo(t, requests[2].body) {
		t.Errorf("undo_last_change was offered behind an answered approval: %v", offeredToolNamesOf(t, requests[2].body))
	}
}

// A finished call and a cancel in the app's order (the result, then cancel_task) leave the call's change in the record, so
// "undo that" after the interrupted command reverses it. The turn has a second call, so the command cannot finish first.
func TestAnInterruptedCommandsFinishedCallCanBeUndone(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn and look": {
			brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":90,"confirmation":"turned"}`),
			brainToolUse("toolu_find", "find_moment", `{"query":"the crater","confirmation":"looking"}`),
		},
		"undo that": {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)

	for run := 1; run <= 20; run++ {
		cancelledID := fmt.Sprintf("command-%d-cancelled", run)
		driver.send(undoCommandLine(cancelledID, "turn and look"))
		driver.expectLine("tool_call")
		driver.send(voiceToolResultLine(cancelledID, "toolu_turn", voiceToolChanged, `{"ok":true}`) + "\n" + cancelTaskLine(cancelledID))

		undoID := fmt.Sprintf("command-%d-undo", run)
		driver.send(undoCommandLine(undoID, "undo that"))
		line := driver.expectLineContaining(`"taskID":"` + undoID + `","toolUseID":"toolu_undo-undo"`)
		if !strings.Contains(line, `"name":"rotate_model","input":{"yawDegrees":-90}`) {
			t.Fatalf("run %d: the undo after an interrupted turn was %s", run, line)
		}
		driver.send(voiceToolResultLine(undoID, "toolu_undo-undo", voiceToolChanged, `{"ok":true}`))
		driver.expectLineContaining(`"type":"voice_command_finished","taskID":"` + undoID + `"`)
		// Undone once, and the lookup the cancel cut off changed nothing, so nothing is left.
		requests := worker.requests()
		if lastRequest := requests[len(requests)-1].body; !offersUndo(t, lastRequest) {
			t.Fatalf("run %d: the undo was not offered after the interrupted command: %v", run, offeredToolNamesOf(t, lastRequest))
		}
		driver.send(undoCommandLine(fmt.Sprintf("command-%d-after", run), "what is this?"))
		driver.expectLineContaining(`"type":"voice_command_finished","taskID":"command-` + fmt.Sprint(run) + `-after"`)
		requests = worker.requests()
		if offersUndo(t, requests[len(requests)-1].body) {
			t.Fatalf("run %d: the interrupted turn was offered for undo again after it was undone", run)
		}
	}
}

// The press that cancels an undo can arrive before the app answered. The app writes a finished call's result before its
// cancel_task, so a result that did not arrive means the inverse may already have run, and the record cannot tell. It
// gets a change with no inverse at the front, so a second undo is not offered: it would reverse the same change again.
func TestACancelDuringAnUndoWithNoResultStopsASecondUndoOfTheSameChange(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"undo that":    {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	// The press arrives while the inverse is still running in the app.
	driver.send(undoCommandLine("command-2", "undo that"))
	driver.expectLine("tool_call")
	driver.send(cancelTaskLine("command-2"))

	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLineContaining(`"type":"voice_command_finished","taskID":"command-3"`)
	requests := worker.requests()
	if offersUndo(t, requests[len(requests)-1].body) {
		t.Errorf("a second undo was offered after an undo that was cancelled with no result: %v", offeredToolNamesOf(t, requests[len(requests)-1].body))
	}
}

// An inverse that finished before the cancel is reversed for certain, so it leaves the record and its line goes to the
// next command. The second call of the reply makes the command outlive the inverse's result, so the cancel can reach it.
func TestACancelAfterTheInverseFinishedRemovesTheChangeItReversed(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left":       {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"undo that and zoom": {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`), brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "undo that and zoom"))
	if got := driver.expectLineContaining(`"taskID":"command-2","toolUseID":"toolu_undo-undo"`); !strings.Contains(got, `"input":{"yawDegrees":45}`) {
		t.Fatalf("the inverse call was %s", got)
	}
	driver.send(voiceToolResultLine("command-2", "toolu_undo-undo", voiceToolChanged, `{"ok":true}`) + "\n" + cancelTaskLine("command-2"))
	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLineContaining(`"type":"voice_command_finished","taskID":"command-3"`)

	requests := worker.requests()
	last := requests[len(requests)-1].body
	if offersUndo(t, last) {
		t.Errorf("the change was offered after the inverse finished and the command was cancelled")
	}
	if got := lastUserText(t, last); !strings.Contains(got, `<interrupted_before>rotate_model {"yawDegrees":45} -> ok</interrupted_before>`) {
		t.Errorf("the next command was not told the inverse ran: %s", got)
	}
}

// A call the app was still running when the press came may already have changed the screen, so it stands between "undo
// that" and the older change, as a hand-off does.
func TestAVideoCallStillRunningWhenAPressCancelsTheCommandStandsBetweenUndoAndAnOlderChange(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"play it":      {brainToolUse("toolu_play", "play_video", `{"confirmation":"playing"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "play it"))
	driver.expectLine("tool_call")
	driver.send(cancelTaskLine("command-2"))

	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLineContaining(`"type":"voice_command_finished","taskID":"command-3"`)
	requests := worker.requests()
	if offersUndo(t, requests[len(requests)-1].body) {
		t.Errorf("undo was offered past a video call whose effect is unknown: %v", offeredToolNamesOf(t, requests[len(requests)-1].body))
	}
	// The model reads the cut-off call too, so "undo that" with no undo offered does not make it reach past the play.
	if got := lastUserText(t, requests[len(requests)-1].body); !strings.Contains(got, `<interrupted_before>play_video {} -> cut off, may have run</interrupted_before>`) {
		t.Errorf("the next command was not told about the cut-off call: %s", got)
	}
}

// A page still in its tour may have refused a cut-off call, so the call keeps no inverse and undo is not offered past it.
// A page that does not report tourFinished, as a generated page may not, counts as finished.
func TestACutOffPageCallKeepsItsInverseOnlyOnceThePageTourHasFinished(t *testing.T) {
	for _, testCase := range []struct {
		sceneState    string
		undoIsOffered bool
	}{
		{`{"page":"framePopout","sceneNumber":1,"tourFinished":false}`, false},
		{`{"page":"framePopout","sceneNumber":1,"tourFinished":true}`, true},
		{`{"page":"generated3DScene","sceneNumber":1}`, true},
	} {
		session, _ := newTestSession()
		run := session.begin("zoom in", json.RawMessage(testCase.sceneState))
		run.noteACallWhoseEffectIsUnknown(toolCall{ID: "toolu_zoom", Name: "zoom", Input: json.RawMessage(`{"factor":2}`)}, false)
		run.abandon()
		if got := undoIsOfferedTo(session.begin("undo that", json.RawMessage(testCase.sceneState))); got != testCase.undoIsOffered {
			t.Errorf("in %s, undo offered after a cut-off zoom = %v, want %v", testCase.sceneState, got, testCase.undoIsOffered)
		}
	}
}

// A page call a press cut off has almost surely run, so "undo that" reverses it and not the older change behind it.
func TestAPageCallStillRunningWhenAPressCancelsTheCommandIsTheOneUndone(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"zoom in":      {brainToolUse("toolu_zoom", "zoom", `{"factor":2,"confirmation":"zoomed"}`)},
		"undo that":    {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "zoom in"))
	driver.expectLine("tool_call")
	driver.send(cancelTaskLine("command-2"))

	driver.send(undoCommandLine("command-3", "undo that"))
	if got, want := driver.expectLine("tool_call"), `{"type":"tool_call","taskID":"command-3","toolUseID":"toolu_undo-undo","name":"zoom","input":{"factor":0.5},"turnIndex":0}`; got != want {
		t.Fatalf("the undo after a cut-off zoom:\n got %s\nwant %s", got, want)
	}
	requests := worker.requests()
	if got := lastUserText(t, requests[len(requests)-1].body); !strings.Contains(got, `<interrupted_before>zoom {"factor":2} -> cut off, may have run</interrupted_before>`) {
		t.Errorf("the undo command was not told about the cut-off call: %s", got)
	}
}

// A cancelled undo with no result may have run its inverse, so the next command reads the inverse's own call as cut off.
func TestACancelledUndoWithNoResultTellsTheNextCommandItsInverseWasCutOff(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"undo that":    {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "undo that"))
	driver.expectLine("tool_call")
	driver.send(cancelTaskLine("command-2"))

	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLineContaining(`"type":"voice_command_finished","taskID":"command-3"`)
	requests := worker.requests()
	if got := lastUserText(t, requests[len(requests)-1].body); !strings.Contains(got, `<interrupted_before>rotate_model {"yawDegrees":45} -> cut off, may have run</interrupted_before>`) {
		t.Errorf("the next command was not told the inverse was cut off: %s", got)
	}
}

// A result the app wrote before its cancel_task is the call's line. The cut-off line is for a call with no result only, so
// a call never has two lines.
func TestACallWhoseResultWasQueuedBeforeTheCancelGetsOneLineAndNoCutOffLine(t *testing.T) {
	zoomCall := toolCall{ID: "toolu_zoom", Name: "zoom", Input: json.RawMessage(`{"factor":2,"confirmation":"zoomed"}`)}
	for attempt := 1; attempt <= 50; attempt++ {
		session, _ := newTestSession()
		brain := &brainRunner{session: session}
		commandContext, cancel := context.WithCancel(context.Background())
		cancel()
		command := &runningTask{toolResults: make(chan toolResultMessage, 32)}
		command.toolResults <- toolResultMessage{ToolUseID: "toolu_zoom", Content: mustMarshal(`{"ok":true}`), Outcome: voiceToolChanged}
		run := session.begin("zoom in", json.RawMessage(`{}`))

		_, _, err := brain.runToolCalls(commandContext, command, voiceCommandMessage{TaskID: "command-1"}, []toolCall{zoomCall}, map[toolName]bool{"zoom": true}, approvalOffer{}, 0, run)

		if want := []string{`zoom {"factor":2} -> ok`}; !slices.Equal(run.actionLines, want) {
			t.Fatalf("attempt %d (error %v): the action lines were %q, want %q", attempt, err, run.actionLines, want)
		}
	}
}

// A call the cancel kept from being sent never ran, so it has no line either.
func TestACallTheCancelKeptFromBeingSentGetsNoActionLine(t *testing.T) {
	session, _ := newTestSession()
	brain := &brainRunner{session: session}
	commandContext, cancel := context.WithCancel(context.Background())
	cancel()
	command := &runningTask{toolResults: make(chan toolResultMessage, 32)}
	run := session.begin("zoom in", json.RawMessage(`{}`))
	zoomCall := toolCall{ID: "toolu_zoom", Name: "zoom", Input: json.RawMessage(`{"factor":2}`)}

	_, _, _ = brain.runToolCalls(commandContext, command, voiceCommandMessage{TaskID: "command-1"}, []toolCall{zoomCall}, map[toolName]bool{"zoom": true}, approvalOffer{}, 0, run)

	if len(run.actionLines) != 0 {
		t.Errorf("a call that was never sent got the lines %q", run.actionLines)
	}
}

// A lookup changes nothing, so a press that cancels one leaves the change before it undoable.
func TestACancelledLookupLeavesTheEarlierChangeToUndo(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left":  {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
		"find the moon": {brainToolUse("toolu_find", "find_moment", `{"query":"the moon","confirmation":"looking"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	driver.send(undoCommandLine("command-1", "turn it left"))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(undoCommandLine("command-2", "find the moon"))
	driver.expectLine("tool_call")
	driver.send(cancelTaskLine("command-2"))

	driver.send(undoCommandLine("command-3", "what is this?"))
	driver.expectLineContaining(`"type":"voice_command_finished","taskID":"command-3"`)
	requests := worker.requests()
	if !offersUndo(t, requests[len(requests)-1].body) {
		t.Errorf("a cancelled lookup took the undo away: %v", offeredToolNamesOf(t, requests[len(requests)-1].body))
	}
}

// A cancel that came before the call was sent means the app never received it, so nothing ran and the record is unchanged.
func TestACallTheCancelKeptFromBeingSentLeavesNoChangeInTheRecord(t *testing.T) {
	session, _ := newTestSession()
	brain := &brainRunner{session: session}
	commandContext, cancel := context.WithCancel(context.Background())
	cancel()
	command := &runningTask{toolResults: make(chan toolResultMessage, 32)}
	run := session.begin("zoom in", json.RawMessage(`{}`))
	zoomCall := toolCall{ID: "toolu_zoom", Name: "zoom", Input: json.RawMessage(`{"factor":2}`)}

	_, _, err := brain.runToolCalls(commandContext, command, voiceCommandMessage{TaskID: "command-1"}, []toolCall{zoomCall}, map[toolName]bool{"zoom": true}, approvalOffer{}, 0, run)

	if err == nil {
		t.Fatal("a cancelled command returned no error")
	}
	if len(run.changes) != 0 {
		t.Errorf("a call that was never sent left %v in the record", run.changes)
	}
}

// The same rule without the timing: the inverse's result is queued and the context is already cancelled, so the wait sees
// both ready. Whichever it picks, the inverse call's change must come out of the record and its line must be kept.
func TestAWaitThatSeesAQueuedInverseResultAndACancelRemovesTheChangeAndKeepsTheLine(t *testing.T) {
	undoCall := toolCall{ID: "toolu_undo", Name: undoLastChangeTool, Input: json.RawMessage(`{"confirmation":"undid it"}`)}
	for attempt := 1; attempt <= 50; attempt++ {
		session, _ := newTestSession()
		brain := &brainRunner{session: session}
		commandContext, cancel := context.WithCancel(context.Background())
		cancel()
		command := &runningTask{toolResults: make(chan toolResultMessage, 32)}
		command.toolResults <- toolResultMessage{ToolUseID: "toolu_undo-undo", Content: mustMarshal(`{"ok":true,"state":null}`), Outcome: voiceToolChanged}
		run := session.begin("undo that", json.RawMessage(`{}`))
		run.noteChange(appliedChange{tool: "rotate_model", input: json.RawMessage(`{"yawDegrees":45}`)})

		_, _, err := brain.runToolCalls(commandContext, command, voiceCommandMessage{TaskID: "command-1"}, []toolCall{undoCall}, map[toolName]bool{"rotate_model": true, undoLastChangeTool: true}, approvalOffer{}, 0, run)

		if want := []string{`rotate_model {"yawDegrees":-45} -> ok`}; !slices.Equal(run.actionLines, want) {
			t.Fatalf("attempt %d (error %v): the action lines were %q, want %q", attempt, err, run.actionLines, want)
		}
		if len(run.changes) != 0 {
			t.Fatalf("attempt %d (error %v): the reversed change is still in the record: %v", attempt, err, run.changes)
		}
	}
}

// ---- Which scene and video a change was made to ----

// Scene states as the app sends them: popOutScene(n) is the nth scene to show, a pop-out.
func popOutScene(sceneNumber int) string {
	return fmt.Sprintf(`{"page":"framePopout","sceneNumber":%d,"yawDegrees":10,"labels":["heart","valve"]}`, sceneNumber)
}

func videoInFront(title string, durationSeconds int) string {
	return fmt.Sprintf(`{"page":"none","video":{"title":%q,"durationSeconds":%d,"seconds":30,"paused":false}}`, title, durationSeconds)
}

// undoIsOfferedTo is whether a command that began with this run offers undo_last_change, when the app offers every tool.
func undoIsOfferedTo(run *sessionRun) bool {
	allTools := []voiceToolOffer{{Name: "rotate_model"}, {Name: "zoom"}, {Name: "seek_relative"}, {Name: "pause_video"}, {Name: "play_video"}}
	return slices.ContainsFunc(withTheUndoOffer(allTools, run), func(offer voiceToolOffer) bool { return offer.Name == string(undoLastChangeTool) })
}

// beginsInAndMakes begins a command in a scene state, runs each call as a change that worked, and commits.
func beginsInAndMakes(session *brainSession, sceneState string, calls ...toolCall) {
	run := session.begin("do it", json.RawMessage(sceneState))
	for _, call := range calls {
		run.noteFinishedCall(call, voiceToolChanged, `{"ok":true}`, false)
	}
	run.commit()
}

var (
	turnLeft  = toolCall{Name: "rotate_model", Input: json.RawMessage(`{"yawDegrees":-45}`)}
	zoomIn    = toolCall{Name: "zoom", Input: json.RawMessage(`{"factor":2}`)}
	seekAhead = toolCall{Name: "seek_relative", Input: json.RawMessage(`{"seconds":10}`)}
	popOut    = toolCall{Name: "pop_out", Input: json.RawMessage(`{}`)}
)

func TestTheIdentityOfASceneStateNamesThePageAndTheVideoAndNothingElse(t *testing.T) {
	samePop := sceneIdentityOf(json.RawMessage(popOutScene(3)))
	if moved := sceneIdentityOf(json.RawMessage(`{"page":"framePopout","sceneNumber":3,"yawDegrees":99,"labels":[],"video":null}`)); moved.page != samePop.page {
		t.Errorf("a camera move changed the page identity: %q then %q", samePop.page, moved.page)
	}
	if next := sceneIdentityOf(json.RawMessage(popOutScene(4))); next.page == samePop.page {
		t.Errorf("two pop-outs with the same page name and labels share the identity %q", next.page)
	}
	for _, nothingOnScreen := range []string{`{}`, `{"page":"none"}`, `null`, `[]`, `not json`, `{"page":7,"video":"x"}`} {
		if identity := sceneIdentityOf(json.RawMessage(nothingOnScreen)); identity != (sceneIdentity{}) {
			t.Errorf("%s read as %+v, want nothing on screen", nothingOnScreen, identity)
		}
	}
	first, second := sceneIdentityOf(json.RawMessage(videoInFront("Sharks", 612))), sceneIdentityOf(json.RawMessage(videoInFront("Sharks", 700)))
	if first.video == "" || first.video == second.video {
		t.Errorf("videos of different lengths read as %q and %q", first.video, second.video)
	}
	if first.page != "" {
		t.Errorf("a video with no scene read as page %q", first.page)
	}
}

func TestAChangeOnSceneAIsNotOfferedOnceTheSceneIsB(t *testing.T) {
	for name, nextScene := range map[string]string{
		"a new pop-out of the same video": popOutScene(2),
		"a different kind of page":        `{"page":"landmark","sceneNumber":2}`,
		"no scene at all":                 `{"page":"none"}`,
	} {
		session, _ := newTestSession()
		beginsInAndMakes(session, popOutScene(1), turnLeft)
		run := session.begin("undo that", json.RawMessage(nextScene))
		if undoIsOfferedTo(run) || len(run.changes) != 0 {
			t.Errorf("%s: the turn on scene 1 was still offered, record %v", name, run.changes)
		}
	}
}

func TestASeekOnVideoAIsNotOfferedOnVideoB(t *testing.T) {
	for name, nextState := range map[string]string{
		"another title":  videoInFront("Whales", 612),
		"another length": videoInFront("Sharks", 700),
		"no video":       `{"page":"none"}`,
	} {
		session, _ := newTestSession()
		beginsInAndMakes(session, videoInFront("Sharks", 612), seekAhead)
		run := session.begin("undo that", json.RawMessage(nextState))
		if undoIsOfferedTo(run) || len(run.changes) != 0 {
			t.Errorf("%s: the seek on the first video was still offered, record %v", name, run.changes)
		}
	}
}

// seek_to_moment has no inverse, since the time it left is not in its input, but it is a change to the video: it stands
// between "undo that" and an older seek, and a switch to another video drops it like any other seek.
func TestASeekToAMomentIsNotUndoneAndKeepsAnOlderSeekFromBeingUndoneInItsPlace(t *testing.T) {
	session, _ := newTestSession()
	beginsInAndMakes(session, videoInFront("Sharks", 612), seekAhead)
	beginsInAndMakes(session, videoInFront("Sharks", 612), toolCall{Name: "seek_to_moment", Input: json.RawMessage(`{"query":"the gills"}`)})
	run := session.begin("undo that", json.RawMessage(videoInFront("Sharks", 612)))
	if undoIsOfferedTo(run) {
		t.Errorf("undo was offered after a seek_to_moment, which would have reversed the older seek: record %v", run.changes)
	}
	if len(run.changes) != 2 {
		t.Errorf("the seek_to_moment should stay in the record, got %v", run.changes)
	}
}

func TestASeekToAMomentOnVideoAIsDroppedOnVideoB(t *testing.T) {
	session, _ := newTestSession()
	beginsInAndMakes(session, videoInFront("Sharks", 612), toolCall{Name: "seek_to_moment", Input: json.RawMessage(`{"query":"the gills"}`)})
	run := session.begin("undo that", json.RawMessage(videoInFront("Whales", 700)))
	if len(run.changes) != 0 {
		t.Errorf("the seek on the first video was still in the record: %v", run.changes)
	}
}

func TestTheSameSceneAndVideoKeepTheRecordWhateverElseTheirStateSays(t *testing.T) {
	session, _ := newTestSession()
	inScene := `{"page":"framePopout","sceneNumber":5,"yawDegrees":0,"video":{"title":"Sharks","durationSeconds":612,"seconds":10}}`
	beginsInAndMakes(session, inScene, zoomIn, seekAhead)

	movedOn := `{"page":"framePopout","sceneNumber":5,"yawDegrees":40,"zoom":0.6,"labels":["fin"],"video":{"title":"Sharks","durationSeconds":612,"seconds":300,"paused":true}}`
	run := session.begin("undo that", json.RawMessage(movedOn))
	if !undoIsOfferedTo(run) || len(run.changes) != 2 {
		t.Errorf("the same scene and video lost the record: %v", run.changes)
	}
}

func TestAStaleChangeIsDroppedForGoodSoItNeitherBlocksNorComesBack(t *testing.T) {
	session, _ := newTestSession()
	beginsInAndMakes(session, popOutScene(1), turnLeft)

	// The scene changed, and a command ran in it. The turn is gone from the record, not just hidden.
	other := session.begin("what is this?", json.RawMessage(popOutScene(2)))
	other.commit()
	// Even when the learner is back in a scene with the first one's identity, the turn does not return.
	back := session.begin("undo that", json.RawMessage(popOutScene(1)))
	if len(back.changes) != 0 || undoIsOfferedTo(back) {
		t.Errorf("a dropped change came back: %v", back.changes)
	}
	// And it does not block a change made in the new scene.
	beginsInAndMakes(session, popOutScene(2), zoomIn)
	if run := session.begin("undo that", json.RawMessage(popOutScene(2))); !undoIsOfferedTo(run) || run.changes[0].tool != "zoom" {
		t.Errorf("the change in the new scene was not the newest: %v", run.changes)
	}
}

func TestAStaleNewestChangeTakesTheOlderOnesWithIt(t *testing.T) {
	// A pop-out's camera change is newest and a seek is older, and the scene closes. "Undo that" must not reach the seek.
	session, _ := newTestSession()
	both := `{"page":"framePopout","sceneNumber":1,"video":{"title":"Sharks","durationSeconds":612}}`
	beginsInAndMakes(session, both, seekAhead)
	beginsInAndMakes(session, both, turnLeft)
	run := session.begin("undo that", json.RawMessage(videoInFront("Sharks", 612)))
	if undoIsOfferedTo(run) || len(run.changes) != 0 {
		t.Errorf("an older seek was offered after the newer turn's scene closed: %v", run.changes)
	}

	// A stale change that is older than a valid one only drops itself: the turn stays.
	session, _ = newTestSession()
	beginsInAndMakes(session, both, seekAhead)
	beginsInAndMakes(session, both, turnLeft)
	run = session.begin("undo that", json.RawMessage(`{"page":"framePopout","sceneNumber":1,"video":{"title":"Whales","durationSeconds":90}}`))
	if len(run.changes) != 1 || run.changes[0].tool != "rotate_model" || !undoIsOfferedTo(run) {
		t.Errorf("the turn did not survive a tab switch that only the seek was stale for: %v", run.changes)
	}
}

func TestAHandOffNeverGoesStaleAndKeepsStandingBetweenUndoAndOlderChanges(t *testing.T) {
	session, _ := newTestSession()
	beginsInAndMakes(session, popOutScene(1), turnLeft)
	beginsInAndMakes(session, popOutScene(1), popOut)
	// The pop-out changed the scene, so the next command sees a new one. The turn behind the pop-out is stale and goes, the
	// pop-out stays as the newest change, and it has no inverse.
	run := session.begin("undo that", json.RawMessage(popOutScene(2)))
	if len(run.changes) != 1 || run.changes[0].tool != "pop_out" || undoIsOfferedTo(run) {
		t.Errorf("the record after the pop-out was %v, offered undo: %v", run.changes, undoIsOfferedTo(run))
	}
}

func TestASeededChangeTakesTheSceneOfTheFirstCommandThatReadsIt(t *testing.T) {
	session, _ := newTestSession()
	if err := session.seed(nil, []string{`rotate_model {"yawDegrees":90} -> ok`}); err != nil {
		t.Fatal(err)
	}
	first := session.begin("undo that", json.RawMessage(popOutScene(7)))
	if !undoIsOfferedTo(first) {
		t.Fatalf("a seeded change was not offered in the first command: %v", first.changes)
	}
	first.commit()
	// The seed's scene is now scene 7, so a new scene drops it like any other change.
	if second := session.begin("undo that", json.RawMessage(popOutScene(8))); undoIsOfferedTo(second) {
		t.Errorf("a seeded change survived a scene change: %v", second.changes)
	}
}

func TestUndoFollowsTheSceneTheChangeWasMadeInWhenTheAppSendsEachCommand(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"turn it left": {brainToolUse("toolu_turn", "rotate_model", `{"yawDegrees":-45,"confirmation":"turned"}`)},
	})
	driver := startHarness(t, worker.server.URL)
	commandIn := func(commandID string, transcript string, sceneState string) string {
		return fmt.Sprintf(`{"type":"voice_command","taskID":%q,"transcript":%q,"sceneState":%s,"tools":%s}`, commandID, transcript, sceneState, undoTestTools)
	}
	driver.send(commandIn("command-1", "turn it left", popOutScene(1)))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-1", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")
	// The learner pressed Escape and a new pop-out of the same video opened, outside the harness.
	driver.send(commandIn("command-2", "what is this?", popOutScene(2)))
	driver.expectLine("voice_command_finished")
	// The same scene as the turn would have offered it.
	driver.send(commandIn("command-3", "turn it left", popOutScene(2)))
	driver.expectLine("tool_call")
	driver.send(voiceToolResultLine("command-3", "toolu_turn", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")
	driver.send(commandIn("command-4", "what is this?", popOutScene(2)))
	driver.expectLine("voice_command_finished")

	requests := worker.requests()
	for requestIndex, wantOffer := range []bool{false, false, false, true} {
		if got := offersUndo(t, requests[requestIndex].body); got != wantOffer {
			t.Errorf("command %d offered undo_last_change: %v, want %v", requestIndex+1, got, wantOffer)
		}
	}
}

// ---- Bench mode ----

func TestASeededSessionOffersUndoForTheInterruptedTurnAndResetForgetsIt(t *testing.T) {
	worker := workerThatAnswersByWords(t, map[string][]string{
		"undo that": {brainToolUse("toolu_undo", "undo_last_change", `{"confirmation":"undid it"}`)},
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, appSecret: "test-secret", benchMode: true})

	driver.send(`{"type":"reset_session"}`)
	driver.send(`{"type":"seed_session","interruptedBefore":["rotate_model {\"yawDegrees\":90} -> ok"],"messages":` + string(mustMarshal(seededMessagesOfCalls([3]string{"toolu_seed", "zoom", `{"factor":1.3}`}))) + `}`)
	driver.send(undoCommandLine("command-1", "undo that"))
	if got := driver.expectLine("tool_call"); !strings.Contains(got, `"name":"rotate_model","input":{"yawDegrees":-90}`) {
		t.Fatalf("the undo of the interrupted turn was %s", got)
	}
	driver.send(voiceToolResultLine("command-1", "toolu_undo-undo", voiceToolChanged, `{"ok":true}`))
	driver.expectLine("voice_command_finished")

	driver.send(`{"type":"reset_session"}`)
	driver.send(undoCommandLine("command-2", "what is this?"))
	driver.expectLine("voice_command_finished")
	requests := worker.requests()
	if offersUndo(t, requests[len(requests)-1].body) {
		t.Errorf("a reset left the record behind")
	}
}
