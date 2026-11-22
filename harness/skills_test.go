package main

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeSkillFile(t *testing.T, directory string, name string, fileText string) {
	t.Helper()
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(directory, name+".md"), []byte(fileText), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParsingASkillFile(t *testing.T) {
	got, err := parseSkill("quiz-me", "---\nname: quiz-me\ndescription: \"Ask five questions.\"\ntools: [read_video_captions, 'finish']\nunheard_of: ignored\n---\n\nAsk the questions.\nOne at a time.\n")
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	want := skill{
		name:        "quiz-me",
		description: "Ask five questions.",
		tools:       []string{"read_video_captions", "finish"},
		body:        "Ask the questions.\nOne at a time.",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parsed:\n got %#v\nwant %#v", got, want)
	}

	withoutTools, err := parseSkill("quiz-me", "---\nname: quiz-me\ndescription: Ask.\n---\nGo.")
	if err != nil || withoutTools.tools != nil {
		t.Errorf("a skill with no tools line must not limit tools, got %#v, %v", withoutTools.tools, err)
	}
}

func TestASkillFileThatIsNotWholeIsRefusedWithAReason(t *testing.T) {
	tests := map[string]struct {
		fileText string
		reason   string
	}{
		"no front matter":      {"Just text.", "must start with"},
		"no closing line":      {"---\nname: a\ndescription: b\nBody.", "no closing"},
		"a line with no colon": {"---\nname a\n---\nBody.", "not key: value"},
		"no name":              {"---\ndescription: b\n---\nBody.", "no name"},
		"another file's name":  {"---\nname: other\ndescription: b\n---\nBody.", "does not match"},
		"no description":       {"---\nname: a\n---\nBody.", "no description"},
		"no body":              {"---\nname: a\ndescription: b\n---\n  \n", "no text"},
	}
	for name, test := range tests {
		t.Run(name, func(t *testing.T) {
			_, err := parseSkill("a", test.fileText)
			if err == nil || !strings.Contains(err.Error(), test.reason) {
				t.Errorf("expected an error that says %q, got %v", test.reason, err)
			}
		})
	}
}

func TestASkillIsFoundInTheFirstDirectoryThatHasIt(t *testing.T) {
	userDirectory := filepath.Join(t.TempDir(), "user")
	bundledDirectory := filepath.Join(t.TempDir(), "bundled")
	writeSkillFile(t, bundledDirectory, "flashcards", "---\nname: flashcards\ndescription: Bundled.\n---\nBundled steps.")
	writeSkillFile(t, bundledDirectory, "only-bundled", "---\nname: only-bundled\ndescription: Bundled.\n---\nSteps.")
	writeSkillFile(t, userDirectory, "flashcards", "---\nname: flashcards\ndescription: Mine.\n---\nMy steps.")
	directories := []string{userDirectory, bundledDirectory}

	overridden, err := loadSkill(directories, "flashcards")
	if err != nil || overridden.description != "Mine." {
		t.Errorf("the user's skill should win, got %#v, %v", overridden, err)
	}
	fallback, err := loadSkill(directories, "only-bundled")
	if err != nil || fallback.description != "Bundled." {
		t.Errorf("a skill only the second directory has should load, got %#v, %v", fallback, err)
	}
	if _, err := loadSkill(directories, "missing"); err == nil || !strings.Contains(err.Error(), `no skill named "missing"`) {
		t.Errorf("a missing skill should say so, got %v", err)
	}
	// A file that exists but cannot be read is an error, not a reason to look in the next directory.
	if err := os.MkdirAll(filepath.Join(userDirectory, "unreadable.md"), 0o755); err != nil {
		t.Fatal(err)
	}
	writeSkillFile(t, bundledDirectory, "unreadable", "---\nname: unreadable\ndescription: Bundled.\n---\nSteps.")
	if _, err := loadSkill(directories, "unreadable"); err == nil || !strings.Contains(err.Error(), "could not be read") {
		t.Errorf("an unreadable skill file should fail, got %v", err)
	}
	for _, name := range []string{"../escape", "Flash Cards", "a/b", ""} {
		if _, err := loadSkill(directories, name); err == nil || !strings.Contains(err.Error(), "is not a skill name") {
			t.Errorf("%q should be refused as a name, got %v", name, err)
		}
	}
}

// The skill the app ships must stay loadable, and must name only tools the agent has.
func TestTheBundledFlashcardsSkillLoadsAndItsToolsExist(t *testing.T) {
	flashcards, err := loadSkill([]string{filepath.Join("..", "leanring-buddy", "Skills")}, "flashcards")
	if err != nil {
		t.Fatalf("the bundled flashcards skill does not load: %v", err)
	}
	if flashcards.tools == nil {
		t.Fatal("the flashcards skill should limit the agent's tools")
	}
	// leanring-buddyTests/TaskAgentSkillsTests.swift asserts these same two strings, since the app lists the skill from them.
	if flashcards.name != "flashcards" {
		t.Errorf("the flashcards skill's name was %q", flashcards.name)
	}
	if want := "Make flashcards from the video that is playing or the page on screen, and save them as a Notion page."; flashcards.description != want {
		t.Errorf("the flashcards skill's description was %q, want %q", flashcards.description, want)
	}
	if _, err := taskAgentTools(&flashcards, nil); err != nil {
		t.Errorf("the flashcards skill names a tool the agent lacks: %v", err)
	}
}

func TestASkillWithAToolsLineLimitsTheAgentToThoseTools(t *testing.T) {
	limited, err := taskAgentTools(&skill{name: "s", tools: []string{"read_video_captions", "web_fetch"}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range limited {
		names = append(names, *tool.GetName())
	}
	// The agent's own order, with report_step and finish kept.
	if got, want := strings.Join(names, ","), "web_fetch,report_step,read_video_captions,finish"; got != want {
		t.Errorf("limited tools were %s, want %s", got, want)
	}
	if _, err := taskAgentTools(&skill{name: "s", tools: []string{"send_the_launch_codes"}}, nil); err == nil || !strings.Contains(err.Error(), "send_the_launch_codes") {
		t.Errorf("a skill that names a missing tool should fail with that name, got %v", err)
	}
}

func startTaskWithSkillLine(taskID string, goal string, skillName string) string {
	return fmt.Sprintf(`{"type":"start_task","taskID":%q,"goal":%q,"frontTabTitle":null,"frontTabURL":null,"skill":%q}`, taskID, goal, skillName)
}

func TestATaskWithASkillCarriesItsTextAndALimitedToolList(t *testing.T) {
	skillsDirectory := t.TempDir()
	writeSkillFile(t, skillsDirectory, "quiz-me", "---\nname: quiz-me\ndescription: Ask five questions.\ntools: read_video_captions\n---\nAsk one question at a time.")
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		writeStreamedMessage(writer, "tool_use", toolUseBlock("toolu_finish", "finish", `{"spokenSummary":"Done."}`))
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, skillsDirectories: []string{skillsDirectory}})

	driver.send(startTaskWithSkillLine("task-1", "quiz me", "quiz-me"))
	driver.expectLine("task_finished")

	requestBody := worker.requests()[0].body
	firstMessageText := firstUserText(t, requestBody)
	if !strings.Contains(firstMessageText, "Task from the learner: quiz me") || !strings.Contains(firstMessageText, "<skill>\nAsk one question at a time.\n</skill>") {
		t.Errorf("the first message did not carry the skill: %q", firstMessageText)
	}
	var toolNames []string
	for _, tool := range jsonValueAt(t, requestBody, "tools").([]any) {
		toolNames = append(toolNames, jsonValueAt(t, tool, "name").(string))
	}
	if got, want := strings.Join(toolNames, ","), "report_step,read_video_captions,finish"; got != want {
		t.Errorf("the tools were %s, want %s", got, want)
	}
}

func TestATaskWhoseSkillIsMissingOrMalformedFailsWithAClearReason(t *testing.T) {
	skillsDirectory := t.TempDir()
	writeSkillFile(t, skillsDirectory, "broken", "no front matter here")
	worker := newFakeWorker(t, func(writer http.ResponseWriter, _ *http.Request, _ recordedRequest, _ int) {
		t.Error("a task whose skill cannot load must not call the model")
	})
	driver := startHarnessWith(t, configuration{workerBaseURL: worker.server.URL, skillsDirectories: []string{skillsDirectory}})

	driver.send(startTaskWithSkillLine("task-1", "do it", "missing"))
	if failed := driver.expectLine("task_failed"); !strings.Contains(failed, `no skill named \"missing\"`) {
		t.Errorf("a missing skill failed with %s", failed)
	}
	driver.send(startTaskWithSkillLine("task-2", "do it", "broken"))
	if failed := driver.expectLine("task_failed"); !strings.Contains(failed, "broken.md is malformed") {
		t.Errorf("a malformed skill failed with %s", failed)
	}
	if got := len(worker.requests()); got != 0 {
		t.Errorf("the Worker got %d requests, want 0", got)
	}
}

func TestTheSkillsDirectoriesComeFromTheEnvironmentInOrder(t *testing.T) {
	lookup := func(name string) string {
		return map[string]string{
			"CLICKY_WORKER_BASE_URL": "http://worker",
			"CLICKY_SKILLS_DIRS":     "/user/skills" + string(os.PathListSeparator) + string(os.PathListSeparator) + "/bundle/Skills",
		}[name]
	}
	loaded, err := loadConfiguration(lookup)
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"/user/skills", "/bundle/Skills"}; !reflect.DeepEqual(loaded.skillsDirectories, want) {
		t.Errorf("skills directories were %v, want %v", loaded.skillsDirectories, want)
	}
}
