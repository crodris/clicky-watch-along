# Go one brain: build plan

Written 2026-11-19, against `origin/main` at f213fda (PR #46 merged).
This is a plan only.
Nothing in it is built yet.

## Goal

Every voice request goes to one brain that runs in the Go agent harness (`harness/`), instead of a stateless Haiku call in the Worker (`POST /voice-command`).
The brain keeps a conversation across commands, offers the tools the app announces on each request, answers simple commands on Haiku as fast as today, and moves to Sonnet only when a request needs planning.
Renders, quiz plans, answers about the screen, and the other Worker routes stay as tools on their fixed models.

Terms used in this plan:

- **The brain** is the voice command loop that runs in the harness process.
- **A command** is one push-to-talk utterance that reaches the brain, with all the model turns and tool calls it takes.
- **The session** is the brain's conversation history across commands, held in the harness process.
- **The old path** is today's router: `CompanionManager.runVoiceCommand` calling `POST /voice-command`.
- **The harness flag** is the new UserDefaults switch `brainRunsInTheHarness` (default off), which picks the brain over the old path.
  It is separate from `brainTakesEveryRequest`, which decides *when* the router takes a transcript.
  The harness flag decides *where* the router runs.

## Decisions already made

- The brain is built in Go, on the existing harness.
  Not Rust, and not pi in Bun.
- Simple commands stay as fast as today: the first turn runs on Haiku with a short prompt ("two speeds, one brain").
- Renders (`/live-scene`), quiz plans (`/video-quiz-plan`), answers (`/chat`), and the other routes stay as tools that call the Worker on their fixed models.

## Behavior that must not change

Every PR below checks this list.
A PR that changes one of these items says so in its body and gets Chris's OK first.

1. **Latency.** A simple command ("turn it left", "go back ten seconds") reaches its first tool call within 100 ms of the old path's p50 on the same machine, measured by the brain evals (today p50 846 ms).
2. **Cost.** A simple command costs at most 1.5 times the old path, measured by the brain evals (today about $0.00015 per call).
3. **Push-to-talk cancels.** A press cancels the command in flight, stops Clicky's audio at once, and no tool call of the cancelled command runs after the press.
4. **Swift keeps the routing rules ahead of the router.** `handleTranscript` keeps its order: a quiz answer goes to the judge, a scene still building keeps the keyword path, "stop the quiz" and "put it back" keep their phrase matches (`asksToPutTheSceneBack`), and the "animate this" and "let me try it" keyword branches run when `brainTakesEveryRequest` is off (`keywordBranchAheadOfTheRouter`).
5. **Only offered tools run.** `runVoiceTool` refuses a tool the command did not offer, and `voiceToolsOfferedToTheModel` keeps its page tool name filter, description cut, schema size limit, and duplicate rule.
6. **What Clicky says.** Clicky speaks the confirmations after the change, never the model's own text next to a tool call, cuts spoken text to 300 characters, and says `voiceCommandGaveUpLine` when the third turn still needs the model.
7. **Chips and the serve.** The chip timing in `chipPhraseToShow(at:offeredToolNames:)` is unchanged, and the spoken line still waits for `waitForTheServeToLand`.
8. **Approval rules.** A voice yes answers only the request whose card showed its whole summary for 1 second at the press, only in the model's first reply of the command, only when the whole transcript is a short answer (`approvalVoiceAnswerTheLearnerSaid`), and the model reads only the capability word, never the summary.
9. **Router failure.** A failed brain falls back the way a failed router does today: the keyword path, the experiment for "let me try it" with no scene (`routerFailureFallback`), or a short line during a quiz question.
10. **Background agents.** Task agents keep running in the same harness process, with their own loop, approvals, skills, and MCP servers, and a brain command never waits on them.

## Order of the PRs

Each PR merges on its own and leaves the app working, since the harness flag stays off until the cutover PR.
The three approval follow-ups go first, because the cutover PR moves the approval rules and should move code that is already fixed.

| Order | PR | Piece | Estimate | Ships behind the flag |
|---|---|---|---|---|
| 1 | "Always" lasts for one task | F4 | 2 hours | No flag, it changes approvals for task agents now |
| 2 | Notion sources must come from the task's research | F2 | 3 hours | No flag |
| 3 | The approval card counts only a summary scrolled through | F36 | 4 hours | No flag |
| 4 | The brain answers voice commands in the harness, stateless | Piece 2, plus the prompt half of piece 4 | 1 day | Yes, the harness flag |
| 5 | Brain evals drive the harness binary | Piece 5 | Half a day | Bench only |
| 6 | The brain keeps a session, with compaction | Piece 1 | 1 day | Yes, the harness flag |
| 7 | Two speeds: Haiku first, Sonnet when it plans | Piece 3 | 1 day, or 2 hours if the evals say Haiku is enough | Yes, the harness flag |
| 8 | Approval rules move into the harness, and the harness flag turns on | Piece 4 | 1 day | The flag's default turns on |
| 9 | Delete the old path | Cleanup | 2 hours | Chris decides when |

Total: about 5.5 days of agent work, close to the 4 to 5 day estimate, plus the three approval items.

The prompt moves in PR 4, not PR 8, because the brain cannot answer without it.
PR 4 copies it word for word, with a test that it matches the Worker's copy, so the two paths stay comparable until PR 7 changes it on purpose.

---

## PR 1: "Always" lasts for one task (F4)

**Problem.** "Always" grants one tool at one capability for the whole harness process (`standingGrantKey` in `harness/approval.go`).
A learner who says "always" to one `open_url` link has approved every link any later task opens, until Clicky quits.
The card does not say this.

**Fix (recommended).** Add the task ID to `standingGrantKey`, so "always" covers that tool at that capability for the rest of the task that asked.
Change the card's Always button help text and the `answer_approval` chip to say "for this task".
A skill that opens five links still asks once.

**Alternative.** Keep the process scope, and key `open_url` grants by host and MCP grants by server and tool.
This is narrower for links but adds one rule per tool kind, so it is not recommended.

**Files.** `harness/approval.go`, `harness/approval_test.go`, `leanring-buddy/BackgroundAgentListPanel.swift` (button text), `leanring-buddy/VoiceApprovals.swift` (chip text), `AGENTS.md` (the "always" sentences in "Skills, MCP servers, and approvals" and the protocol section), `.claude/skills/verify-clicky/features/task-agent.md`.

**Protocol.** No change.
`approval_result.scope` keeps `once` and `always`, and only what `always` covers changes.

**Test.** One Go test: an `always` grant in task A, then the same tool and capability in task B, asks again, while a second call in task A runs with no request.

**Verify.** Drive the harness alone, as `features/task-agent.md` describes: two `start_task` lines whose goals each call `open_url`, answer the first request with `scope: always`, and check that the second task's call sends a new `approval_request`.
Then in the app, run one task that opens two links and confirm with `$V app-launch` that the second link opens with no card.

## PR 2: Notion sources must come from the task's research (F2)

**Problem.** `write_notion_page` has capability `none`, and its `sources` are links the agent writes.
An agent steered by a page can put screen or clipboard data in a source URL's path or query.
The page is private, but a learner who clicks the source sends that data to the link's host.

**Fix (recommended).** The harness keeps the set of URLs the task actually saw: every URL in its `web_search_tool_result` and `web_fetch_tool_result` blocks, plus the front tab URL from `start_task`.
`write_notion_page` refuses a source URL outside that set, with an error result that tells the agent to list only pages it read.
This is a rule in code with no new approval card.

**Alternative.** Strip the query and fragment from every source URL in the Worker (`worker/src/notionPage.ts`).
This is simpler but still lets a path carry data, so it is not recommended alone.

**Files.** `harness/loop.go` (collect URLs from each turn's server tool blocks into the task's record), `harness/taskagent.go` (the check before the call goes to the app), `harness/loop_test.go`, `AGENTS.md`.
If the check needs a new file, add it to the "Build Agent Harness" input list in `project.pbxproj`.

**Protocol.** No change.

**Test.** One Go test against the fake `/v1/messages` server: a turn whose web search result names `https://a.example/x`, then a `write_notion_page` call with that source and one more source `https://b.example/?q=secret`; the app receives no `tool_call`, and the agent gets the refusal that names the second URL.

**Verify.** Run the task agent bench (`bench/taskAgent.ts`) once, and confirm with `$V app-launch "find out how this catch compares to the first booster catch"` on a Starship video that the page still writes, with sources that are search results.

## PR 3: The approval card counts only a summary scrolled through (F36)

**Problem.** `approvalSummaryShowsToItsEnd` is true once the summary's last line is in view.
A learner who drags the scroll straight to the end reaches that state without the middle ever showing.
It is also unverified on the real app that the summary's frame preference updates while the learner scrolls.

**Fix.** Replace the end check with coverage: the card records each range of the summary that has been inside the scroll area, and the 1 second clock starts only once those ranges cover the summary from top to bottom.
A pure function, `approvalSummaryWasShownWhole(seenRanges:summaryHeight:)`, decides it, and the desk's clock rules stay as they are.

**Files.** `leanring-buddy/BackgroundAgentListPanel.swift` (`ApprovalCardView` records ranges, the new pure function replaces `approvalSummaryShowsToItsEnd`), `leanring-buddy/AgentHarness.swift` (`HarnessApprovalDesk` if the call names change), `leanring-buddyTests/AgentHarnessTests.swift` or a new `ApprovalCardTests.swift`, `.claude/skills/verify-clicky/verify-clicky.sh` (a new `scroll <points>` primitive that posts a real scroll wheel event with a small CGEvent script, like `demo/scripts/mouse/mouse.swift`), `features/task-agent.md`, `AGENTS.md`.

**Test.** One Swift test: ranges for the top and the bottom only leave the middle uncovered and return false, and adding the middle returns true.

**Verify.** Start a task whose MCP tool call has a summary taller than 200 points, so the card scrolls.
Use `$V scroll` to jump to the end, then `$V shot`.
Click Yes with a real click through the demo mouse script, since `debug_answer_approval` answers without the seen check, and check that the log says `ignored a click on approval`.
Then scroll through the middle, wait 1 second, click, and check `given (once)`.
This also proves on the real app that the frame preference updates while scrolling, which is the open half of F36.

---

## PR 4: The brain answers voice commands in the harness, stateless (piece 2, and the prompt half of piece 4)

**What it does.** With the harness flag on, `runVoiceCommand` sends each command to the harness instead of `POST /voice-command`.
The harness runs the same loop the Swift code runs today: one Haiku turn, the app runs the tool calls, and up to 3 turns.
It has no memory yet: each command starts a new conversation, and Swift still sends the last 5 actions.

### Protocol

A voice command reuses the task messages, with the command's UUID in `taskID`, so `HarnessTaskRouter` routes it like a task.

App to harness:

- `voice_command` (new): `taskID`, `transcript`, `sceneState` (the JSON object `voiceCommandSceneState` builds today), `recentActions` (the `voiceToolActionLine` strings, removed in PR 6), and `tools` (the `VoiceToolDescriptor` list after `voiceToolsOfferedToTheModel`, as `{ name, description, inputSchema, readOnly }`).
- `tool_result` (extended): a new `outcome` field, one of `changed`, `lookedUp`, `handedOff`, or `failed`, required for a voice command and ignored for a task.
  `isError` stays for tasks.
- `cancel_task` (unchanged): cancels a command too.

Harness to app:

- `tool_call` (unchanged shape): the input arrives without `confirmation`, since the harness added it and keeps it.
- `voice_command_finished` (new): `taskID`, `spokenLine` (the joined confirmations, cut to 300 characters, or empty), and `gaveUp` (true when the third turn still needed the model, so Swift says `voiceCommandGaveUpLine`).
- `task_failed` (unchanged): the Worker or Anthropic failed, which sends Swift down the router failure fallback.
- `log` (unchanged): one `Brain: turn N on <model> stopped for <reason>, tokens in N, cache read N, cache write N, out N, N ms` line per turn, since the Worker logs no usage for `/v1/messages`.

### Harness side

- New `harness/brain.go`: the brain's whole definition, like `taskagent.go` is the task agent's.
  It holds the model (`claude-haiku-5-5`, thinking off, effort low, `max_tokens` 1024), the system prompt copied word for word from `worker/src/voiceCommand.ts`, the port of `toolsForAnthropic` (the `confirmation` property, required unless `readOnly`, and the cache breakpoint on the last tool), the port of `voiceCommandUserMessageText` (the `scene_state` and `recent_actions` tags and the `<` escape), and the port of `voiceCommandNextStep`.
- New `harness/brainloop.go`: `runCommand` sends one non-streaming request per turn through the same SDK client and Worker base URL, sends each tool call as a `tool_call` in order, waits for each result before the next one starts (Swift runs them one at a time today), stops at a `handedOff` result, and ends with `voice_command_finished`.
  It refuses a tool name the command did not offer, before the app sees it.
  App voice tools need no approval, since the learner asked for the action directly, so the approval gate is not on this path.
- `harness/protocol.go` and `harness/main.go`: parse `voice_command` and the `outcome` field, and route a command like a task, with its own goroutine and cancel.
  A new `voice_command` cancels any command still running, so two commands never interleave.
- The brain must not wait on `mcpHub.connect`, which runs when the first task starts.
- Add `brain.go`, `brainloop.go`, and their test files to the "Build Agent Harness" input list in `project.pbxproj`.

### Swift side

- `VoiceCommandTools.swift`: `BrainRunsInTheHarness`, read only by `isOn()`, like `BrainTakesEveryRequest`, with the Debug launch argument `--brain-runs-in-the-harness`.
- `AgentHarness.swift`: `HarnessCommand.voiceCommand`, `HarnessMessage.voiceCommandFinished`, the `outcome` field on `tool_result`, and `startVoiceCommand(...) -> AsyncStream<HarnessTaskEvent>`.
- `CompanionManager.swift`: in `runVoiceCommand`, when the harness flag is on, the `for turnIndex in 0..<3` loop becomes a loop over the command's events.
  A `tool_call` runs through `runVoiceTool` exactly as today, with the chips and the recent action lines, and its outcome goes back in `tool_result`.
  `voice_command_finished` waits for the serve to land and speaks the line, or says the gave-up line.
  `task_failed` runs the same fallback as a router failure.
- **Cancel.** The command's Swift task wraps the event loop in `withTaskCancellationHandler`, whose handler sends `cancel_task`.
  Events that arrive after the cancel are dropped, because `HarnessTaskRouter.end` closes the stream.
- **Hand-off order.** A hand-off tool (`answer_with_screen`, `build_new_scene`, `pop_out`, `animate_picture`, and the others whose outcome is `.handedOff`) cancels the router's own task when it starts the new path.
  So `runVoiceTool` sends the `handedOff` result *before* it starts the new path, and the harness treats a command whose last result was `handedOff` as complete and ignores the `cancel_task` that follows.
  PR 6 depends on this, since a cancelled command is rolled back and a handed-off one is not.
- **Prewarm.** With the harness flag on, `AgentHarness` launches the process when the app starts, not on the first task, so no command pays the launch.
- `.claude/skills/verify-clicky/verify-clicky.sh`: `app-launch --harness-brain` passes `--brain-runs-in-the-harness`.

### Tests (one per logic change)

- Go: `toolsForAnthropic` port, table test copied from `worker/src/voiceCommand.test.ts`.
- Go: `nextVoiceStep`, table test ported from the Swift `voiceCommandNextStep` tests.
- Go: the user message text escapes `<` in the scene state and actions.
- Go: the prompt matches the Worker's copy (the test reads `../worker/src/voiceCommand.ts` and checks each prompt line appears in it), until PR 7 changes the prompt on purpose.
- Go: the loop end to end against the fake `/v1/messages` server in `helpers_test.go`: a two-call turn, then `voice_command_finished` with both confirmations.
- Go: a `cancel_task` during a turn ends the request and sends nothing more, and a `cancel_task` after a `handedOff` result changes nothing.
- Swift: `HarnessMessage` parses `voice_command_finished`, and `HarnessCommand.voiceCommand` encodes as one line, in `AgentHarnessTests.swift`.

### Verify

- `$V app-launch --brain --harness-brain "pop this out|turn it to the left|zoom in a bit|no, the other way"` on a YouTube video with one clear object, then `$V app-wait`.
  The app log shows one `Brain: turn` line per turn on `claude-haiku-5-5`, the same chips and spoken confirmations as the old path, and no `[/voice-command]` usage line in the Worker log.
- Push-to-talk during a turn: `$V app-launch --harness-brain "~skip to where they talk about the engine|pause it"` makes the second step interrupt the first, and the log shows no tool call of the first command after the second press.
- Router failure: stop the Worker mid-run and check that the next command takes the keyword path.

**Ships behind the flag.** Yes.
With the flag off, nothing changes.

## PR 5: Brain evals drive the harness binary (piece 5)

**What it does.** `bench/brainEvals.ts` gains `--backend worker|harness|both`.
`harness` spawns the built harness binary, the way `bench/taskAgent.ts` does, sends each case as a `voice_command`, and scores the tool calls of the first turn, which is what the Worker backend scores today.
It answers each `tool_call` with a stand-in `changed` result, so the command ends.
`both` runs the two backends in one invocation, alternating case by case, so the latency comparison shares one network and one Worker.

**Files.** `bench/brainEvals.ts`, `bench/brainEvals.test.ts`, a shared driver extracted from `bench/taskAgent.ts` if it stays small (otherwise a copy of its spawn and line reader), `bench/README.md` ("Brain evals"), `.claude/skills/verify-clicky/features/voice-commands.md`.

**Measures.** Pass count, p50 and p95 from the `voice_command` line to the first `tool_call` line, p50 to `voice_command_finished`, and cost from the `Brain: turn` token lines.
The old backend's latency is measured the same way, from request to reply.

**Gate.** 129 of 129 runs pass on the harness backend (43 cases, 3 runs), the p50 to the first tool call is within 100 ms of the Worker backend's p50 in the same run, and the cost per call is within 1.5 times.
Commit the result to `bench/results/` as `harness-brain-evals-<commit>.json`.
If the gate fails, stop and report before PR 6.

**Test.** One bench test: the harness backend scores a recorded `tool_call` line stream the same as the equivalent Worker reply (pin the `Brain: turn` line format against `brainloop.go`, as `taskAgent.test.ts` pins the task agent's line).

**Verify.** The eval run itself is the verification: `$V worker-up 8797`, then `node bench/brainEvals.ts run --label harness-parity --backend both --runs 3 --port 8797`.

---

## PR 6: The brain keeps a session, with compaction (piece 1)

**What it does.** The harness keeps one session for the life of the process.
Each command appends to it, so "undo the first turn" or "go back to where we were" works past the last 5 actions, and Swift stops sending `recentActions` on the harness path.

### Session rules

- **One session.** `brainSession` in the harness holds the messages, the command count, and the time of the last request.
  One learner means one session.
- **Each command appends** a user message (the scene state for this moment and the learner's words), the model's turns, and the tool results.
  Each tool result in the history is cut to 2,000 characters.
- **Cancel rolls back.** A cancelled command removes its messages from the session, back to where it started, since a turn whose tool calls never got results cannot go back to Anthropic.
  The action lines of the calls that did finish go into the next command's user message as one "Interrupted before:" line, so the brain still knows what changed on screen.
- **Hand-off stays.** A command that handed off stays in the session, with a result such as "Handed off: Clicky answers out loud".
- **Caching.** The tools and system prompt keep their breakpoint, and a second breakpoint sits on the last message of the previous command, so the next command reads the whole history from the cache.
- **Compaction (no model call).** Before a command, when the cache is already cold (no request in the last 5 minutes) or the session holds more than 24 commands, the harness folds every command except the last 6 into one text block at the start: per command, the learner's words and its action lines, with the old scene states dropped.
  Folding only while the cache is cold, or at the hard cap, means a fold almost never throws away a warm cache.
  A model-written summary is deferred until an eval case needs one.
- **Where it lives.** In the harness process's memory only, never on disk.
  A new app launch, or a harness relaunch after a crash, starts an empty session.
  See the open question on restarts below.

### Files

`harness/brainsession.go` (new: append, rollback, fold, the cache breakpoint placement), `harness/brainloop.go`, `harness/brain.go` (the user message without `recent_actions`), their tests, `project.pbxproj` (build phase inputs), `leanring-buddy/CompanionManager.swift` (no `recentActions` on the harness path), `leanring-buddy/AgentHarness.swift`, new fixture `bench/fixtures/brain-sessions.json` and its runner in `bench/brainEvals.ts`, `AGENTS.md`.

### Protocol

`voice_command.recentActions` becomes optional and the harness ignores it.
No new message.

### Tests

- Go: rollback after a cancel leaves the session exactly as before the command, and adds the "Interrupted before:" line from the finished calls.
- Go: the fold keeps the last 6 commands whole, drops old scene states, and runs only when the cache is cold or past 24 commands.
- Go: the breakpoint is on the last message of the previous command.
- Bench: three session cases: an "undo the first turn" after 7 commands, a correction right after a fold, and a correction after an interrupted command.

### Verify

- `$V app-launch --brain --harness-brain "pop this out|turn it to the left|turn it to the left|zoom in a bit|zoom in a bit|turn it up|reset the zoom|undo the first turn"`.
  The last step turns the model right, and the `Brain: turn` lines show cache reads growing with the history.
- Re-run the PR 5 eval with `--backend both`, and record the cache read share and p50 of a 10 command session against the stateless numbers.

**Risk to measure here.** The tools render first in Anthropic's cache prefix, so a command whose offered tools differ from the last one (a scene appears, a video leaves) misses the cache for the whole history.
If the session eval shows p50 or cost past the gate, the mitigation is to offer a stable tool list and let the app refuse unavailable tools, which costs accuracy, so it needs Chris's call.

**Ships behind the flag.** Yes.

## PR 7: Two speeds, Haiku first and Sonnet when it plans (piece 3)

**First, measure.** Before writing code, add 8 planning cases to `bench/fixtures/brain-evals.json`: requests whose steps depend on each other, such as "go back to where he explains the heat shield and pop it out" (find a moment, seek, pop out) or "pause it, slow it down, and go back to the start of this part".
Run them on the PR 6 brain.
If Haiku passes every planning case in 3 runs, stop and ask Chris whether PR 7 is needed, and suggest shipping only the turn budget rule below.

### Design

- The first turn of every command runs on Haiku with today's short prompt, as in PR 4.
- **The planner tool.** A harness-only tool, `think_it_through`, is offered on Haiku turns.
  Its description says to call it alone when a request needs several steps that depend on each other and no single tool, `answer_with_screen`, or `start_background_task` fits.
  It never reaches the app.
  When Haiku calls it, the harness drops that turn and runs the command again on Sonnet 5.5 at low effort, with a longer planning prompt, the same tools, and up to 6 turns.
- **The turn budget rule.** When Haiku's third turn still needs the model, the harness gives the command one Sonnet turn before the gave-up line.
- **Long tasks do not change.** "Find out", "research", and "compare" still go to `start_background_task`, which runs the Sonnet task agent in the same harness.

### Files

`harness/brain.go` (the planner tool, the Sonnet settings, the planning prompt, the model choice per turn), `harness/brainloop.go`, tests, `bench/fixtures/brain-evals.json`, `bench/brainEvals.ts` (score a case by the whole command when it is a planning case, not only the first turn), `AGENTS.md`.
The Go test that the prompt matches the Worker's copy is deleted here, since the brain's prompt now differs on purpose.

### Protocol

No change.
The `Brain: turn` log line already names the model.

### Tests

- Go: a `think_it_through` call sends the next request on Sonnet with the planning prompt and does not keep the Haiku turn.
- Go: a third Haiku turn that still needs the model gets one Sonnet turn, then the gave-up line.
- Bench: the 8 planning cases pass in 3 runs, and the 43 old cases still pass 129 of 129 with no Sonnet turn among them.

### Verify

`$V app-launch --brain --harness-brain "go back to where he explains the heat shield and pop it out"` on a Starship video.
The log shows one Haiku turn, then Sonnet turns, then the pop-out, and the thinking dots stay up while Sonnet plans.

**Ships behind the flag.** Yes.

---

## PR 8: Approval rules move into the harness, and the harness flag turns on (piece 4)

**What it does.** The harness decides voice approvals, next to the approval gate it already owns, and the harness flag's default turns on.

### What moves, and what stays in Swift

- **Moves to Go:** the `answer_approval` tool (offered only while a request waits), the first-reply-only rule, the short-answer yes check (`approvalVoiceAnswerTheLearnerSaid` and the `ApprovalVoiceAnswer` vocabulary), and the `approvalWaiting` capability word in the scene state.
  The harness knows the waiting request's capability itself, since it issued the request, so the app stops sending it.
- **Stays in Swift:** which request the learner had seen for 1 second at the press (`approvalRequestAVoiceAnswerMayReach`, `oldestRequestIDTheLearnerHasSeen(at:)`).
  That fact depends on the card's scroll state and the desk's clock, which only the app sees.
  Swift sends its result as `approvalIDSeenAtPress` in `voice_command`, and the harness decides the rest.

### Protocol

- `voice_command` gains `approvalIDSeenAtPress` (string or null).
- New harness to app `approval_settled`: `approvalID`, `approved`, `scope`, sent when a voice answer settles a request, so the desk drops the card and the chip says "Allowed it", "Allowed it, for this task", or "Declined it".
- A click still answers with `approval_result`, unchanged.

### Files

New `harness/voiceapproval.go` (the yes check and the offer rule), `harness/brain.go`, `harness/approval.go` (deliver a voice answer to the gate), tests, a shared fixture `harness/testdata/approval-voice-answers.json` that both the Go test and a Swift test read while both checks exist (as `flashcards.md` is read by both sides today), `leanring-buddy/AgentHarness.swift` (`approval_settled`), `leanring-buddy/CompanionManager.swift` (send `approvalIDSeenAtPress`, stop adding `approvalWaiting` on the harness path), `leanring-buddy/VoiceCommandTools.swift` (`BrainRunsInTheHarness` default on), `worker/src/voiceCommand.ts` (unchanged, still serving the old path), `features/task-agent.md`, `features/voice-commands.md`, `AGENTS.md`.

### Tests

- Go: `answer_approval` is offered only when `approvalIDSeenAtPress` names a request the gate holds as waiting.
- Go: a yes from the second turn of a command is refused.
- Go: the shared fixture's transcripts give the same answer in Go and Swift ("okay, what is this video about" is not a yes, a bare "always" is a yes with always).
- Go: the scene state the model reads holds the capability word and never the summary.

### Verify

- With the flag at its new default, `$V app-launch --brain` on a task that calls `open_url`.
  When the card shows, say "yes" with a rehearsal step, and check the log for `given (once)` and the "Allowed it" chip.
- A rehearsal step "okay, what is this video about" while a card waits does not approve it.
- Re-run the brain evals with `--backend both` and attach the result.

**Fallback.** With the harness down, a command takes the router failure fallback (the keyword path), not the old Worker route.

## PR 9: Delete the old path (Chris decides when)

After a few days of use with the harness flag on, delete `POST /voice-command` and its tests, `VoiceCommandClient`, `recentVoiceToolActionLines`, the Swift copy of the voice approval check, the shared fixture's Swift reader, the harness flag, and the Worker backend of the brain evals.
Update `AGENTS.md`, `bench/README.md`, and the verify-clicky feature map in the same PR.

---

## Risks

### First-turn latency through stdin and the Worker

The old path is app to Worker to Anthropic.
The brain is app to harness (a pipe, well under 1 ms for a 60 KB tool list) to Worker to Anthropic, so it adds no network hop.
The Worker runs locally (`wrangler dev` on 8787), so neither path pays TLS to the Worker.
The costs that remain:

- **Process launch.** Today the harness launches on the first task. PR 4 launches it at app start when the flag is on.
- **MCP connect.** `mcpHub.connect` runs on the first task and can take seconds. The brain never calls it.
- **The SDK's request.** A non-streaming Go SDK request should match the Worker's own call. Streaming would let the first tool call start before the turn ends, which is a later option if PR 5 shows it is needed.
- **A longer history.** PR 6 adds history tokens, which add prefill time when the cache misses. PR 6 measures this.

PR 5 and PR 6 each gate on the 100 ms budget, so a regression stops the plan before the cutover.

### How a push-to-talk press cancels a turn in flight

The press cancels `currentResponseTask`, whose cancel handler sends `cancel_task`.
The harness cancels the command's context, the SDK aborts the HTTP request to the Worker, and the harness sends nothing more for the command.
A `tool_call` already written before the cancel reaches Swift after its stream has ended and is dropped.
Anthropic still bills a turn the Worker had already forwarded, which is the same as today.
The session rolls the command back (PR 6).
The one ordering trap is a hand-off, which cancels the router's own task: PR 4 sends the `handedOff` result first, so the cancel that follows is not a rollback.

### A harness crash ends the brain

With one process for tasks and the brain, a crash fails every running task (as today) and empties the session.
`AgentHarness` already relaunches on the next use, and the command that saw the crash takes the router failure fallback.
PR 8 makes this the only path, so check the relaunch time in PR 4's verify run.

### Two copies of the approval check during the move

From PR 8 to PR 9 the Swift and Go yes checks both exist.
The shared fixture keeps them from differing, and PR 9 deletes the Swift copy.

### Cache minimum for Haiku

Anthropic caches a prefix only past a minimum length per model.
Check Haiku 5.5's minimum with the `claude-api` reference before PR 6 relies on the history breakpoint, since a short session may not cache at all.

## Open questions for Chris

1. **Session across app restarts.** The plan keeps the session in memory only, so a relaunch starts fresh.
   A voice command refers to the screen as it is now, and an old session after a restart would mislead "no, the other way".
   It also keeps transcripts and page text off disk.
   Recommendation: memory only.
2. **Should the brain hear what `answer_with_screen` said?** Today `/chat` keeps its own history, so "say that again" works there, but the brain does not know what was answered.
   Recommendation: wait for an eval case that needs it.
3. **"Always" scope (PR 1).** One task (recommended), or a narrower per-tool target such as a link's host.
4. **Deleting the old path (PR 9).** After how many days of use, or keep `/voice-command` as a bench baseline.
5. **PR 7 if Haiku passes the planning cases.** Skip the planner tool and ship only the turn budget rule, or build both.
