package main

import (
	"reflect"
	"testing"
)

func TestParsingAMessageFromTheApp(t *testing.T) {
	tabTitle := "SpaceX catch"
	tabURL := "https://www.youtube.com/watch?v=abc"
	skillName := "flashcards"

	tests := []struct {
		name string
		line string
		want inboundMessage
	}{
		{
			name: "start_task with a page",
			line: `{"type":"start_task","taskID":"task-1","goal":"compare","frontTabTitle":"SpaceX catch","frontTabURL":"https://www.youtube.com/watch?v=abc"}`,
			want: startTaskMessage{TaskID: "task-1", Goal: "compare", FrontTabTitle: &tabTitle, FrontTabURL: &tabURL},
		},
		{
			name: "start_task with no page",
			line: `{"type":"start_task","taskID":"task-1","goal":"compare","frontTabTitle":null,"frontTabURL":null}`,
			want: startTaskMessage{TaskID: "task-1", Goal: "compare"},
		},
		{
			name: "start_task with a skill",
			line: `{"type":"start_task","taskID":"task-1","goal":"make cards","frontTabTitle":null,"frontTabURL":null,"skill":"flashcards"}`,
			want: startTaskMessage{TaskID: "task-1", Goal: "make cards", Skill: &skillName},
		},
		{
			name: "tool_result with text",
			line: `{"type":"tool_result","taskID":"task-1","toolUseID":"toolu_1","content":"shown","isError":false}`,
			want: toolResultMessage{TaskID: "task-1", ToolUseID: "toolu_1", Content: []byte(`"shown"`)},
		},
		{
			name: "tool_result with blocks and an error",
			line: `{"type":"tool_result","taskID":"task-1","toolUseID":"toolu_1","content":[{"type":"text","text":"x"}],"isError":true}`,
			want: toolResultMessage{TaskID: "task-1", ToolUseID: "toolu_1", Content: []byte(`[{"type":"text","text":"x"}]`), IsError: true},
		},
		{
			name: "cancel_task",
			line: `{"type":"cancel_task","taskID":"task-1"}`,
			want: cancelTaskMessage{TaskID: "task-1"},
		},
		{
			// The exact line the app writes, which AgentHarnessTests.swift asserts.
			name: "a voice command's tool_result with its outcome",
			line: `{"content":"{\"ok\":true}","isError":false,"outcome":"handedOff","taskID":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","toolUseID":"toolu_pop","type":"tool_result"}`,
			want: toolResultMessage{TaskID: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F", ToolUseID: "toolu_pop", Content: []byte(`"{\"ok\":true}"`), Outcome: voiceToolHandedOff},
		},
		{
			name: "voice_command",
			line: `{"type":"voice_command","taskID":"command-1","transcript":"turn it left","sceneState":{"page":"framePopout"},"recentActions":["zoom {} -> ok"],"tools":[{"name":"rotate_model","description":"Turns it.","inputSchema":{"type":"object"},"readOnly":false}]}`,
			want: voiceCommandMessage{
				TaskID:        "command-1",
				Transcript:    "turn it left",
				SceneState:    []byte(`{"page":"framePopout"}`),
				RecentActions: []string{"zoom {} -> ok"},
				Tools:         []voiceToolOffer{{Name: "rotate_model", Description: "Turns it.", InputSchema: []byte(`{"type":"object"}`)}},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseInboundMessage([]byte(test.line))
			if err != nil {
				t.Fatalf("parse failed: %v", err)
			}
			if !reflect.DeepEqual(got, test.want) {
				t.Errorf("parsed:\n got %#v\nwant %#v", got, test.want)
			}
		})
	}
}

func TestALineFromTheAppThatIsNotAWholeMessageIsRefused(t *testing.T) {
	tests := map[string]string{
		"not JSON":                            `hello`,
		"an array":                            `[1,2]`,
		"a type this harness lacks":           `{"type":"unheard_of","taskID":"task-1"}`,
		"no type":                             `{"taskID":"task-1"}`,
		"start_task with no goal":             `{"type":"start_task","taskID":"task-1","goal":""}`,
		"start_task with no ID":               `{"type":"start_task","goal":"compare"}`,
		"tool_result with no tool use ID":     `{"type":"tool_result","taskID":"task-1","content":"x","isError":false}`,
		"cancel_task with no ID":              `{"type":"cancel_task"}`,
		"a wrong field type":                  `{"type":"start_task","taskID":7,"goal":"compare"}`,
		"tool_result with an unknown outcome": `{"type":"tool_result","taskID":"command-1","toolUseID":"toolu_1","content":"x","isError":false,"outcome":"maybe"}`,
		"voice_command with no tools":         `{"type":"voice_command","taskID":"command-1","transcript":"turn it","sceneState":{},"recentActions":[],"tools":[]}`,
		"voice_command with no transcript":    `{"type":"voice_command","taskID":"command-1","transcript":"","sceneState":{},"tools":[{"name":"zoom","description":"x","inputSchema":{"type":"object"}}]}`,
	}
	for name, line := range tests {
		t.Run(name, func(t *testing.T) {
			if message, err := parseInboundMessage([]byte(line)); err == nil {
				t.Errorf("expected an error, got %#v", message)
			}
		})
	}
}
