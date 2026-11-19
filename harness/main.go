// Command clicky-agent-harness runs Clicky's task agent. The Clicky app starts it as a helper process and talks to it
// in JSON lines on stdin and stdout (see protocol.go). The harness runs Claude's tool loop through the Worker's
// /v1/messages passthrough, and the app answers only the tools that touch the Mac or Notion.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

const (
	appSecretHeaderName = "x-clicky-app-secret"
	// The Worker holds the real Anthropic key and replaces this one, but the SDK refuses to send a request with none.
	placeholderAPIKey = "worker-holds-the-key"
)

// configuration is what the app sets in the harness's environment when it launches the process. The app passes a
// clean environment with just these two variables, so no Anthropic credential of the developer's reaches the Worker.
type configuration struct {
	workerBaseURL string
	appSecret     string
}

func loadConfiguration(lookupEnvironment func(string) string) (configuration, error) {
	workerBaseURL := lookupEnvironment("CLICKY_WORKER_BASE_URL")
	if workerBaseURL == "" {
		return configuration{}, errors.New("CLICKY_WORKER_BASE_URL is not set")
	}
	return configuration{workerBaseURL: workerBaseURL, appSecret: lookupEnvironment("CLICKY_APP_SECRET")}, nil
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

// harness is the task registry. Each task runs in its own goroutine, and the app's messages are routed to it by task ID.
type harness struct {
	rootContext context.Context
	runner      *taskRunner

	tasksMutex sync.Mutex
	tasks      map[string]*runningTask
	taskGroup  sync.WaitGroup
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
	serving := &harness{
		rootContext: rootContext,
		runner:      &taskRunner{client: client, writer: writer},
		tasks:       map[string]*runningTask{},
	}

	writer.send(newReadyMessage())

	// A reader that grows with the line, since a tool result can hold a screenshot of a few megabytes.
	lineReader := bufio.NewReader(input)
	for {
		line, readErr := lineReader.ReadBytes('\n')
		if len(line) > 0 {
			serving.handle(line)
		}
		if readErr != nil {
			break
		}
	}

	serving.cancelEveryTask()
	serving.taskGroup.Wait()
	return nil
}

func (serving *harness) handle(line []byte) {
	message, err := parseInboundMessage(line)
	if err != nil {
		fmt.Fprintf(os.Stderr, "harness: dropped a line from the app: %v\n", err)
		return
	}
	switch message := message.(type) {
	case startTaskMessage:
		serving.startTask(message)
	case toolResultMessage:
		serving.deliverToolResult(message)
	case cancelTaskMessage:
		serving.cancelTask(message.TaskID)
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
	task := &runningTask{cancel: cancel, done: taskContext.Done(), toolResults: make(chan toolResultMessage, 32)}
	serving.tasks[start.TaskID] = task
	serving.tasksMutex.Unlock()

	serving.taskGroup.Add(1)
	go func() {
		defer serving.taskGroup.Done()
		defer serving.removeTask(start.TaskID)
		serving.runner.runTask(taskContext, task, start)
	}()
}

func (serving *harness) removeTask(taskID string) {
	serving.tasksMutex.Lock()
	defer serving.tasksMutex.Unlock()
	if task, taskExists := serving.tasks[taskID]; taskExists {
		task.cancel()
		delete(serving.tasks, taskID)
	}
}

func (serving *harness) task(taskID string) *runningTask {
	serving.tasksMutex.Lock()
	defer serving.tasksMutex.Unlock()
	return serving.tasks[taskID]
}

func (serving *harness) deliverToolResult(result toolResultMessage) {
	task := serving.task(result.TaskID)
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
	if task := serving.task(taskID); task != nil {
		task.cancel()
	}
}

func (serving *harness) cancelEveryTask() {
	serving.tasksMutex.Lock()
	defer serving.tasksMutex.Unlock()
	for _, task := range serving.tasks {
		task.cancel()
	}
}
