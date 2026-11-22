package main

import (
	"context"
	"sync"
)

// pauseGate holds a task agent's next step while the learner has paused every agent ("hold on"). The app sends
// pause_task and resume_task for each running task, and start_task with startsPaused for a task that starts during a
// pause. A step is a model turn or a tool call, so a request or a call already in flight finishes, and the step after it
// waits. A voice command never has a gate, since the voice brain is never paused.
type pauseGate struct {
	mutex sync.Mutex
	// resumed is nil while the task runs, and while it is paused a channel that resume closes.
	resumed chan struct{}
}

func newPauseGate(startsPaused bool) *pauseGate {
	gate := &pauseGate{}
	if startsPaused {
		gate.pause()
	}
	return gate
}

// pause holds the task's next step. Pausing a paused task changes nothing.
func (gate *pauseGate) pause() {
	gate.mutex.Lock()
	defer gate.mutex.Unlock()
	if gate.resumed == nil {
		gate.resumed = make(chan struct{})
	}
}

// resume lets every waiting step go on. Resuming a running task changes nothing.
func (gate *pauseGate) resume() {
	gate.mutex.Lock()
	defer gate.mutex.Unlock()
	if gate.resumed != nil {
		close(gate.resumed)
		gate.resumed = nil
	}
}

// waitWhilePaused returns at once while the task runs. While it is paused, it calls onHeld once and returns when the
// task resumes, or with the context's error when the task is cancelled first.
func (gate *pauseGate) waitWhilePaused(taskContext context.Context, onHeld func()) error {
	gate.mutex.Lock()
	resumed := gate.resumed
	gate.mutex.Unlock()
	if resumed == nil {
		return nil
	}
	onHeld()
	select {
	case <-resumed:
		return nil
	case <-taskContext.Done():
		return taskContext.Err()
	}
}
