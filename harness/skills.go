package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// A skill is a procedure written as a Markdown file, <directory>/<name>.md. The file starts with front matter between
// two "---" lines, then the text the agent follows:
//
//	---
//	name: flashcards
//	description: Make flashcards from what is playing or on screen.
//	tools: read_video_captions, write_notion_page
//	---
//	The steps, in plain words.
//
// name must match the file name, and description is one line that says when to use the skill. tools is optional. When
// it is present, the task gets only those tools, plus report_step and finish.
type skill struct {
	name        string
	description string
	// tools is nil when the skill does not limit the agent's tools.
	tools []string
	body  string
}

// skillNamePattern keeps a name from reaching outside the skills directories, since it becomes part of a path.
var skillNamePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*$`)

// loadSkill finds <name>.md in the first directory that has it, so a directory listed first overrides one listed
// later. A skill the agent cannot read fails with a reason that names the file.
func loadSkill(directories []string, name string) (skill, error) {
	if !skillNamePattern.MatchString(name) {
		return skill{}, fmt.Errorf("%q is not a skill name: use lowercase letters, digits, and hyphens", name)
	}
	for _, directory := range directories {
		skillPath := filepath.Join(directory, name+".md")
		fileText, err := os.ReadFile(skillPath)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return skill{}, fmt.Errorf("the skill file %s could not be read: %w", skillPath, err)
		}
		loaded, err := parseSkill(name, string(fileText))
		if err != nil {
			return skill{}, fmt.Errorf("the skill file %s is malformed: %w", skillPath, err)
		}
		return loaded, nil
	}
	return skill{}, fmt.Errorf("there is no skill named %q in %s", name, strings.Join(directories, ", "))
}

// parseSkill reads one skill file at the boundary and names what is wrong with a file that is not whole.
func parseSkill(expectedName string, fileText string) (skill, error) {
	lines := strings.Split(strings.ReplaceAll(fileText, "\r\n", "\n"), "\n")
	if strings.TrimSpace(lines[0]) != "---" {
		return skill{}, errors.New(`the file must start with a "---" line that opens the front matter`)
	}
	closingLineIndex := -1
	for lineIndex := 1; lineIndex < len(lines); lineIndex++ {
		if strings.TrimSpace(lines[lineIndex]) == "---" {
			closingLineIndex = lineIndex
			break
		}
	}
	if closingLineIndex < 0 {
		return skill{}, errors.New(`the front matter has no closing "---" line`)
	}

	var parsed skill
	for _, line := range lines[1:closingLineIndex] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		key, value, hasColon := strings.Cut(line, ":")
		if !hasColon {
			return skill{}, fmt.Errorf("the front matter line %q is not key: value", line)
		}
		value = strings.Trim(strings.TrimSpace(value), `"'`)
		switch strings.TrimSpace(key) {
		case "name":
			parsed.name = value
		case "description":
			parsed.description = value
		case "tools":
			parsed.tools = splitToolList(value)
		}
	}

	if parsed.name == "" {
		return skill{}, errors.New("the front matter has no name")
	}
	if parsed.name != expectedName {
		return skill{}, fmt.Errorf("the front matter name %q does not match the file name %q", parsed.name, expectedName)
	}
	if parsed.description == "" {
		return skill{}, errors.New("the front matter has no description")
	}
	parsed.body = strings.TrimSpace(strings.Join(lines[closingLineIndex+1:], "\n"))
	if parsed.body == "" {
		return skill{}, errors.New("the skill has no text after its front matter")
	}
	return parsed, nil
}

// splitToolList reads "a, b" or "[a, b]". A list with no names is nil, which means the skill does not limit tools.
func splitToolList(value string) []string {
	value = strings.TrimSuffix(strings.TrimPrefix(value, "["), "]")
	var names []string
	for _, name := range strings.Split(value, ",") {
		if name = strings.Trim(strings.TrimSpace(name), `"'`); name != "" {
			names = append(names, name)
		}
	}
	return names
}

// skillInstructions is the skill as the task's first message carries it. It is Clicky's own text, chosen by the
// learner, so it is not data to doubt, but it never outranks the rule that web pages and tool results are data.
func skillInstructions(chosen skill) string {
	return strings.Join([]string{
		fmt.Sprintf("The learner chose the skill %q: %s", chosen.name, chosen.description),
		"Follow these steps for this task.",
		"<skill>",
		chosen.body,
		"</skill>",
	}, "\n")
}
