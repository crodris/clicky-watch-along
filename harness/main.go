// Command clicky-agent-harness runs Clicky's task agent and, behind the app's brainRunsInTheHarness flag, its voice
// command brain (brain.go, brainloop.go). The Clicky app starts it as a helper process and talks to it in JSON lines on
// stdin and stdout (see protocol.go). The harness runs Claude's tool loop through the Worker's /v1/messages
// passthrough. The app answers the task agent's tools that touch the Mac or Notion, and a voice command's scene, video,
// and agent tools.
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const (
	appSecretHeaderName = "x-clicky-app-secret"
	// The Worker holds the real Anthropic key and replaces this one, but the SDK refuses to send a request with none.
	placeholderAPIKey = "worker-holds-the-key"
)

// configuration is what the app sets in the harness's environment when it launches the process. The app passes a
// clean environment with only these variables, so no Anthropic credential of the developer's reaches the Worker.
type configuration struct {
	workerBaseURL string
	appSecret     string
	// skillsDirectories are the folders that hold skill files, from CLICKY_SKILLS_DIRS. The app lists the user's folder
	// before its own, so a skill the user wrote overrides a bundled one of the same name.
	skillsDirectories []string
	// mcpConfigPath is the mcp.json to read, from CLICKY_MCP_CONFIG. Empty means no MCP servers.
	mcpConfigPath string
	// benchMode is true when CLICKY_BENCH is 1. Only then does the harness take reset_session and seed_session, which
	// let the brain evals start each case from a known session. The app's environment never carries it.
	benchMode bool
	// lookupEnvironment reads this process's variables, which a stdio MCP server's baseline environment copies a few of.
	// A nil one reads the real environment.
	lookupEnvironment func(string) string
}

func loadConfiguration(lookupEnvironment func(string) string) (configuration, error) {
	workerBaseURL := lookupEnvironment("CLICKY_WORKER_BASE_URL")
	if workerBaseURL == "" {
		return configuration{}, errors.New("CLICKY_WORKER_BASE_URL is not set")
	}
	var skillsDirectories []string
	for _, directory := range filepath.SplitList(lookupEnvironment("CLICKY_SKILLS_DIRS")) {
		if directory != "" {
			skillsDirectories = append(skillsDirectories, directory)
		}
	}
	return configuration{
		workerBaseURL:     workerBaseURL,
		appSecret:         lookupEnvironment("CLICKY_APP_SECRET"),
		skillsDirectories: skillsDirectories,
		mcpConfigPath:     lookupEnvironment("CLICKY_MCP_CONFIG"),
		benchMode:         lookupEnvironment("CLICKY_BENCH") == "1",
		lookupEnvironment: lookupEnvironment,
	}, nil
}

func main() {
	harnessConfiguration, err := loadConfiguration(os.Getenv)
	if err != nil {
		fmt.Fprintf(os.Stderr, "harness: %v\n", err)
		os.Exit(1)
	}
	if harnessConfiguration.appSecret == "" {
		fmt.Fprintln(os.Stderr, "harness: CLICKY_APP_SECRET is not set, so the Worker will refuse every request")
	}
	if err := run(context.Background(), os.Stdin, os.Stdout, harnessConfiguration); err != nil {
		fmt.Fprintf(os.Stderr, "harness: %v\n", err)
		os.Exit(1)
	}
}

// harness is the task registry. Each task and each voice command runs in its own goroutine, and the app's messages are
// routed to it by task ID.
type harness struct {
	rootContext context.Context
	runner      *taskRunner
	brain       *brainRunner

	tasksMutex sync.Mutex
	tasks      map[string]*runningTask
	// runningVoiceCommandID is the voice command still running, which a new one cancels, so two never interleave.
	runningVoiceCommandID string
	// lastVoiceCommandEnded closes when the newest voice command's goroutine has ended. A new command waits for it, so it
	// begins only after the one it cancelled has rolled back, and the session it reads is whole.
	lastVoiceCommandEnded chan struct{}
	benchMode             bool
	taskGroup             sync.WaitGroup
}

// run serves the protocol until input ends, then stops every task and returns. It writes nothing but protocol lines to
// output.
func run(rootContext context.Context, input io.Reader, output io.Writer, harnessConfiguration configuration) error {
	clientOptions := []option.RequestOption{
		option.WithBaseURL(harnessConfiguration.workerBaseURL),
		option.WithAPIKey(placeholderAPIKey),
	}
	if harnessConfiguration.appSecret != "" {
		clientOptions = append(clientOptions, option.WithHeader(appSecretHeaderName, harnessConfiguration.appSecret))
	}
	client := anthropic.NewClient(clientOptions...)
	writer := newProtocolWriter(output)
	var servers *mcpHub
	if harnessConfiguration.mcpConfigPath != "" {
		lookupEnvironment := harnessConfiguration.lookupEnvironment
		if lookupEnvironment == nil {
			lookupEnvironment = os.Getenv
		}
		servers = newMCPHub(rootContext, harnessConfiguration.mcpConfigPath, lookupEnvironment, func(text string) { writer.send(newLogMessage(text)) })
	}
	serving := &harness{
		rootContext: rootContext,
		runner:      &taskRunner{client: client, writer: writer, skillsDirectories: harnessConfiguration.skillsDirectories, mcp: servers, approvals: newApprovalGate()},
		brain:       &brainRunner{client: client, writer: writer, session: newBrainSession(time.Now)},
		tasks:       map[string]*runningTask{},
		benchMode:   harnessConfiguration.benchMode,
	}

	writer.send(newReadyMessage())

	// A reader that grows with the line, since a tool result can hold a screenshot of a few megabytes.
	lineReader := bufio.NewReader(input)
	for {
		line, readErr := lineReader.ReadBytes('\n')
		if len(bytes.TrimSpace(line)) > 0 {
			serving.handle(line)
		}
		if readErr != nil {
			break
		}
	}

	serving.cancelEveryTask()
	serving.taskGroup.Wait()
	servers.close()
	return nil
}

func (serving *harness) handle(line []byte) {
	message, err := parseInboundMessage(line)
	if err != nil {
		fmt.Fprintf(os.Stderr, "harness: dropped a line from the app: %v\n", err)
		// The app waits on a voice command's events, so a command dropped here would hold the router failure fallback
		// for the app's whole wait. task_failed for its ID starts the fallback at once, as the old path's 400 did.
		if commandID := voiceCommandIDOfARefusedLine(line); commandID != "" {
			serving.brain.writer.send(newTaskFailedMessage(commandID, err.Error()))
		}
		return
	}
	switch message := message.(type) {
	case startTaskMessage:
		serving.startTask(message)
	case voiceCommandMessage:
		serving.startVoiceCommand(message)
	case resetSessionMessage:
		if !serving.benchMode {
			fmt.Fprintln(os.Stderr, "harness: dropped reset_session, which only a harness started with CLICKY_BENCH=1 takes")
			return
		}
		serving.brain.session.reset()
	case seedSessionMessage:
		if !serving.benchMode {
			fmt.Fprintln(os.Stderr, "harness: dropped seed_session, which only a harness started with CLICKY_BENCH=1 takes")
			return
		}
		if err := serving.brain.session.seed(message.Messages, message.InterruptedBefore); err != nil {
			fmt.Fprintf(os.Stderr, "harness: dropped seed_session: %v\n", err)
		}
	case toolResultMessage:
		serving.deliverToolResult(message)
	case cancelTaskMessage:
		serving.cancelTask(message.TaskID)
	case approvalResultMessage:
		if !serving.runner.approvals.deliver(message) {
			fmt.Fprintf(os.Stderr, "harness: dropped an approval answer for %s, which nothing is waiting for\n", message.ApprovalID)
		}
	}
}

func (serving *harness) startTask(start startTaskMessage) {
	serving.tasksMutex.Lock()
	if _, taskExists := serving.tasks[start.TaskID]; taskExists {
		serving.tasksMutex.Unlock()
		fmt.Fprintf(os.Stderr, "harness: ignored start_task for %s, which is already running\n", start.TaskID)
		return
	}
	taskContext, cancel := context.WithCancel(serving.rootContext)
	task := &runningTask{cancel: cancel, done: taskContext.Done(), toolResults: make(chan toolResultMessage, 32), mcpImages: newImageByteBudget(mostMCPImageBytesPerTask)}
	serving.tasks[start.TaskID] = task
	serving.tasksMutex.Unlock()

	serving.taskGroup.Add(1)
	go func() {
		defer serving.taskGroup.Done()
		defer serving.removeTask(start.TaskID)
		serving.runner.runTask(taskContext, task, start)
	}()
}

// startVoiceCommand runs a command in its own goroutine, like a task, so a slow task never holds it up. It never waits
// on the MCP servers, which only tasks use. A command still running is cancelled first.
func (serving *harness) startVoiceCommand(voiceCommand voiceCommandMessage) {
	serving.tasksMutex.Lock()
	if _, taskExists := serving.tasks[voiceCommand.TaskID]; taskExists {
		serving.tasksMutex.Unlock()
		fmt.Fprintf(os.Stderr, "harness: ignored voice_command for %s, which is already running\n", voiceCommand.TaskID)
		return
	}
	if previousCommand := serving.tasks[serving.runningVoiceCommandID]; previousCommand != nil {
		cancelUnlessAHandOffCompletedIt(previousCommand)
	}
	commandContext, cancel := context.WithCancel(serving.rootContext)
	command := &runningTask{cancel: cancel, done: commandContext.Done(), toolResults: make(chan toolResultMessage, 32), isVoiceCommand: true}
	serving.tasks[voiceCommand.TaskID] = command
	serving.runningVoiceCommandID = voiceCommand.TaskID
	previousCommandEnded := serving.lastVoiceCommandEnded
	commandEnded := make(chan struct{})
	serving.lastVoiceCommandEnded = commandEnded
	serving.tasksMutex.Unlock()

	serving.taskGroup.Add(1)
	go func() {
		defer serving.taskGroup.Done()
		defer close(commandEnded)
		defer serving.removeTask(voiceCommand.TaskID)
		if previousCommandEnded != nil {
			<-previousCommandEnded
		}
		serving.brain.runCommand(commandContext, command, voiceCommand)
	}()
}

func (serving *harness) removeTask(taskID string) {
	serving.tasksMutex.Lock()
	defer serving.tasksMutex.Unlock()
	if task, taskExists := serving.tasks[taskID]; taskExists {
		task.cancel()
		delete(serving.tasks, taskID)
	}
	if serving.runningVoiceCommandID == taskID {
		serving.runningVoiceCommandID = ""
	}
}

func (serving *harness) deliverToolResult(result toolResultMessage) {
	serving.tasksMutex.Lock()
	task := serving.tasks[result.TaskID]
	// A hand-off completes the command here, under the mutex, before the stdin loop reads its next line, so a
	// cancel_task the app wrote right after this result always sees it.
	if task != nil && task.isVoiceCommand && result.Outcome == voiceToolHandedOff {
		task.handOffCompletedIt = true
	}
	serving.tasksMutex.Unlock()
	if task == nil {
		fmt.Fprintf(os.Stderr, "harness: dropped a tool result for %s, which is not running\n", result.TaskID)
		return
	}
	select {
	case task.toolResults <- result:
	case <-task.done:
	}
}

func (serving *harness) cancelTask(taskID string) {
	serving.tasksMutex.Lock()
	defer serving.tasksMutex.Unlock()
	if task := serving.tasks[taskID]; task != nil {
		cancelUnlessAHandOffCompletedIt(task)
	}
}

// cancelUnlessAHandOffCompletedIt cancels a task or command, except a command a hand-off completed. The caller holds
// the harness's tasksMutex. Without this, the command's wait between its cancelled context and its result channel
// would pick one at random when both are ready, and a hand-off could end as a cancel.
func cancelUnlessAHandOffCompletedIt(task *runningTask) {
	if task.handOffCompletedIt {
		return
	}
	task.cancel()
}

func (serving *harness) cancelEveryTask() {
	serving.tasksMutex.Lock()
	defer serving.tasksMutex.Unlock()
	for _, task := range serving.tasks {
		task.cancel()
	}
}
