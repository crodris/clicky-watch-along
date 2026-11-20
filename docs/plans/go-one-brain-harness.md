# Go one brain: build plan

Written 2026-11-19, against `origin/main` at f213fda (PR #46 merged).
This is a plan only.
Nothing in it is built yet.
Revised 2026-11-20 after a council review (Claude Opus 5.5, Claude Fable 5.2, GPT-6.2 Sol) that checked it against the code.

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
   A turn that fails or hangs starts the fallback within 8 seconds of that turn's request, as the old client's per-request timeout gives today (`VoiceCommandTools.swift:930-931`), and a hung harness within 10 seconds.
   Through PR 8, an install with no app secret keeps working voice commands (see PR 8).
   PR 9 ends this, and makes the secret a setup requirement, with Chris's OK.
10. **Background agents.** Task agents keep running in the same harness process, with their own loop, approvals, skills, and MCP servers, and a brain command never waits on them.

## Order of the PRs

Each PR merges on its own and leaves the app working, since the harness flag stays off until the cutover PR.
The three approval follow-ups go first, because the cutover PR moves the approval rules and should move code that is already fixed.

| Order | PR | Piece | Estimate | Ships behind the flag |
|---|---|---|---|---|
| 0 | `/live-scene` falls back to Sonnet 5.5 | Credits | 3 hours | No flag, it changes the Worker now |
| 1 | "Always" lasts for one task | F4 | 2 hours | No flag, it changes approvals for task agents now |
| 2 | Notion sources must come from the task's research | F2 | 4 hours | No flag |
| 3 | The approval card counts only a summary scrolled through | F36 | 4 hours | No flag |
| 4 | The brain answers voice commands in the harness, stateless | Piece 2, plus the prompt half of piece 4 | 1.5 days | Yes, the harness flag |
| 5 | Brain evals drive the harness binary | Piece 5 | Half a day | Bench only |
| 6 | The brain keeps a session, with compaction | Piece 1 | 1 day | Yes, the harness flag |
| 7 | Two speeds: Haiku first, Sonnet when it plans | Piece 3 | 1 day, or 2 hours if the evals say Haiku is enough | Yes, the harness flag |
| 8 | Approval rules move into the harness, and the harness flag turns on | Piece 4 | 1.5 days | The flag's default turns on |
| 9 | Delete the old path | Cleanup | 2 hours | Chris decides when |

Total: about 6.5 days of agent work for the brain, plus about 1.5 days for PR 0 and the three approval items.
The council review added a day to PR 4 and PR 8, for the hand-off mark, the request limits, the turn index, and the app secret fallback.
PR 0 has no dependency on any other PR, so it can merge first or in parallel.

The prompt moves in PR 4, not PR 8, because the brain cannot answer without it.
PR 4 copies it word for word, with a test that it matches the Worker's copy, so the two paths stay comparable until PR 6 changes it on purpose.
PR 6 must change it, since the prompt names the `recent_actions` tag (`worker/src/voiceCommand.ts:18-27`), which PR 6 removes.

---

## PR 0: `/live-scene` falls back to Sonnet 5.5

**Problem.** Chris wants Anthropic API credits to be the default for everything, without topping up OpenAI.
Today, when the OpenAI key is out of credit, rate limited, refused, or OpenAI is down, `requestGPTLiveSceneReply` in `worker/src/liveScene.ts` returns OpenAI's status as an `upstream` failure.
3D models and experiments then end in "Sorry, I couldn't build that one."
Only `/video-quiz-plan` falls back to Sonnet today, through `requestAnthropicMessage`'s OpenAI path in `worker/src/anthropic.ts`.

**Fix.** When the GPT request for a 3D model or an experiment gets a 401, 403, 404, 429, or 5xx, `handleLiveScene` builds the same page on Sonnet 5.5 with the existing Claude request (`requestClaudeLiveSceneReply`, which `LIVE_SCENE_MODEL=sonnet` already selects).

- Reuse the status rule: export `openAICannotAnswerNow` from `anthropic.ts` instead of copying the status list.
- The fallback uses Sonnet's own default effort (`low` in `defaultLiveSceneEffortByModel`), not GPT's `medium`, since the two models take different effort lists.
- Once a request has fallen back, its retry also goes to Sonnet, so a learner never waits on OpenAI twice.
- The page check (`checkLiveSceneModelReply`) and the retry once in `liveSceneReply.ts` apply to the Sonnet reply unchanged.
- A `fetch` to OpenAI that throws, such as a network failure, also falls back.
  Today it throws past the status check (`worker/src/liveScene.ts:304`).
- A 400 or 422 from OpenAI is about the request, so it still returns the error with no fallback.
- A benchmark override (`BENCH_MODEL`) never falls back, as in `requestAnthropicMessage`, since it measures one model.
- The log says `[/live-scene] gpt-6.1-sol could not answer (HTTP 429), so the scene falls back to claude-sonnet-5-5`, and the usage line names the model that answered.

**Why Sonnet 5.5.** Round one of the render bakeoff (`bench/README.md` "Render bakeoff", `renderRound1` in `bench/graphics/bakeoff-data.js`), judged against the shipped GPT-6.1 Sol render:

| Model | Wins against GPT-6.1 Sol | Cost per render | Median time | Pages that worked |
|---|---|---|---|---|
| Sonnet 5.5 | 2 to 4 | $0.07 | 36 s | 3 of 3 |
| Opus 5.5 | 2 to 4 | $0.18 | 78 s | |
| Fable 5.2 | 2 to 0, on the 2 pages it finished | $0.83 | 160 s | Timed out on the heart |
| Haiku 5.5 | 1 to 5 | | | |
| GPT-6.1 Sol (ships) | | $0.41 | 19 s | |

Sonnet loses to GPT-6.1 Sol on quality but ties Opus at less than half its cost and time, and every page it built worked.

**Files.** `worker/src/liveScene.ts`, `worker/src/anthropic.ts` (export the status rule), `worker/src/liveScene.test.ts`, `AGENTS.md` (the `/live-scene` route row and the Live Scene section), `.claude/skills/verify-clicky/features/live-scene.md` and `simulation.md`.

**Protocol.** No change for the app: the reply is the same `{ html, quiz }`.

**Tests.**

- One test per status that falls back (401, 403, 404, 429, and 500 or 503) with a stubbed `fetch`: OpenAI answers that status, Anthropic answers a valid page, and the route returns 200 with Sonnet's page.
- One test where the OpenAI `fetch` throws: the route returns 200 with Sonnet's page.
- One test for a status that does not fall back (400): the route returns OpenAI's 400, and Anthropic is never called.
- One test that the Sonnet reply goes through the same page checks: a Sonnet simulation page that lacks `setControl` is retried on Sonnet, not on OpenAI, and ends in 422.

**Verify.**

- Start a local Worker with a bad OpenAI key, for example `$V worker-up 8787 -- --var OPENAI_API_KEY:sk-invalid`, then `$V post /live-scene` with the existing scene fixture.
  Check that the log shows a 401 from OpenAI first, since a key in `worker/.dev.vars` may win over `--var`; if it does, use a copy of `.dev.vars` with the bad key.
  The Worker log shows the fallback line and a `[/live-scene] usage` line naming `claude-sonnet-5-5`, and the reply holds a page.
- With that Worker, `$V app-launch "show me this in 3D"` on a video with one clear object, and `$V app-launch "let me try it"` on a physics video.
  Both rise out of the video, and neither says "Sorry, I couldn't build that one."

**Risks.**

- **The app's 60 second timeout.** `LiveSceneClient` gives `/live-scene` 60 seconds, and Sonnet's median render is 36 s, so a fallback plus its one retry can pass it.
  The two background agents, the 3D model and the experiment, are not waited on by the learner, so their requests can take 120 seconds with no visible cost.
  Measure the fallback's p95 in the verify run, and raise the timeout for the background builds only if the p95 passes 60 s.
- **A slow failure.** A bad key fails at once, but a 5xx or a hung request can arrive late (`LiveSceneClient.swift:38` gives 60 seconds in all).
  A 5xx after 40 seconds leaves Sonnet too little time.
  This PR adds no cap on the GPT wait, since a cap would also cut GPT experiments that run long.
  The verify run records the time of each fallback, and open question 5 covers the timeout.
- **Experiments on Sonnet are not measured.** The bakeoff judged 3D renders.
  Run the bench's simulation cases on `LIVE_SCENE_MODEL=sonnet` once in this PR, and report how many pages pass the simulation checks.

## PR 1: "Always" lasts for one task (F4)

**Problem.** "Always" grants one tool at one capability for the whole harness process (`standingGrantKey` in `harness/approval.go`).
A learner who says "always" to one `open_url` link has approved every link any later task opens, until Clicky quits.
The card does not say this.

**Fix (recommended).** Add the task ID to `standingGrantKey`, so "always" covers that tool at that capability for the rest of the task that asked.
The Always button has no help text today (`BackgroundAgentListPanel.swift:784`), so add one that says "for this task", and change the `answer_approval` chip to say the same.
Change the approval log line "was already approved for the rest of this session" (`harness/loop.go:314`) to say "for the rest of this task".
Drop a task's grants when the task ends, so the grant map does not grow for the life of the process.
A skill that opens five links still asks once.

**Alternative.** Keep the process scope, and key `open_url` grants by host and MCP grants by server and tool.
This is narrower for links but adds one rule per tool kind, so it is not recommended.

**Files.** `harness/approval.go`, `harness/approval_test.go`, `leanring-buddy/BackgroundAgentListPanel.swift` (button text), `leanring-buddy/VoiceApprovals.swift` (chip text), `AGENTS.md` (the "always" sentences in "Skills, MCP servers, and approvals" and the protocol section), `.claude/skills/verify-clicky/features/task-agent.md`.

**Protocol.** No change.
`approval_result.scope` keeps `once` and `always`, and only what `always` covers changes.

**Test.** One Go test: an `always` grant in task A, then the same tool and capability in task B, asks again, while a second call in task A runs with no request, and once task A ends the gate holds no grant for it.

**Verify.** Drive the harness alone, as `features/task-agent.md` describes: two `start_task` lines whose goals each call `open_url`, answer the first request with `scope: always`, and check that the second task's call sends a new `approval_request`.
Then in the app, run one task that opens two links and confirm with `$V app-launch` that the second link opens with no card.

## PR 2: Notion sources must come from the task's research (F2)

**Problem.** `write_notion_page` has capability `none`, and its `sources` are links the agent writes.
An agent steered by a page can put screen or clipboard data in a source URL's path or query.
The page is private, but a learner who clicks the source sends that data to the link's host.

**Fix (recommended).** The harness keeps the set of URLs the task may cite, and `write_notion_page` refuses a source URL outside it, with an error result that names the URL.
This is a rule in code with no new approval card.
`loop.go` does not read search or fetch result blocks today, so this is new parsing.

The set holds only URLs that come from somewhere the agent cannot write:

- Every URL in a `web_search_tool_result` block.
- The front tab URL from `start_task`.
- The video link of a `read_video_captions` result, since the flashcards skill cites it (`leanring-buddy/Skills/flashcards.md:11`).
  Today the app writes it as a `Link:` line in the same string as the tab title and the captions (`CompanionManager.swift:2825`), which a page controls, so the harness must not parse it from that text.
  Instead `tool_result` gains an optional `sourceURL` field, which the app sets to the video's URL for this tool only, and the harness reads only that field.
- A fetched page, only when the URL the agent asked `web_fetch` for is already in the set.
  When the fetch result's `url` differs from the requested one, as after a redirect, it is added too.
  The SDK's fetch block has a single `url` field ("Fetched content URL"), so check one redirecting fetch against the real API before writing that test, and drop the redirect rule if the field holds the requested URL.
  A fetch alone never adds its URL, because the agent can fetch a URL it read from the clipboard or a screenshot, and web fetch accepts it.

So a page the agent reached by following a link inside a fetched page can be read but not cited, and the PR body names this change.
The refusal says which sources count: "Cite only search results, the page in front, or the video, and leave this link out."

A URL from an MCP result or the clipboard is never in the set.
That is a behavior change: a page that cites an MCP server's link now gets refused, so the PR body says so.

**Match rule.** Compare a normalized key: lowercase scheme and host, no fragment, and no trailing slash on the path, with the query kept exactly.
The page writes the URL as the set spelled it, not as the agent did.

**Alternative.** Strip the query and fragment from every source URL in the Worker (`worker/src/notionPage.ts`).
This is simpler but still lets a path carry data, so it is not recommended alone.

**Files.** `harness/loop.go` (collect URLs from each turn's server tool blocks into the task's record), `harness/taskagent.go` (the check before the call goes to the app), `harness/loop_test.go`, `AGENTS.md`.
If the check needs a new file, add it to the "Build Agent Harness" input list in `project.pbxproj`.

**Protocol.** `tool_result` gains an optional `sourceURL` string, which only the `read_video_captions` result sets.
Add it to `AgentHarness.swift` (`HarnessCommand`), the `read_video_captions` case in `CompanionManager.swift`, and `harness/protocol.go`.

**Tests.** Go tests against the fake `/v1/messages` server, one per rule:

- A turn whose web search result names `https://a.example/x`, then a `write_notion_page` call with that source and one more source `https://b.example/?q=secret`: the app receives no `tool_call`, and the agent gets the refusal that names the second URL.
- A URL seen only in a `read_clipboard` result, then fetched with `web_fetch`, is still refused.
- A fetch of a search result that redirected: the final URL is accepted.
- The `sourceURL` of a captions result is accepted, written with a trailing slash, and a link-shaped line in the captions or title text adds no source.

**Verify.** Run the task agent bench (`bench/taskAgent.ts`) once, and confirm with `$V app-launch "find out how this catch compares to the first booster catch"` on a Starship video that the page still writes, with sources that are search results.
Then run the flashcards skill on a YouTube video, and check that the page cites the video link and the log shows no source refusal.

## PR 3: The approval card counts only a summary scrolled through (F36)

**Problem.** `approvalSummaryShowsToItsEnd` is true once the summary's last line is in view.
A learner who drags the scroll straight to the end reaches that state without the middle ever showing.
It is also unverified on the real app that the summary's frame preference updates while the learner scrolls.

**Fix.** Replace the end check with coverage: the card records each range of the summary that has been inside the scroll area, and the 1 second clock starts only once those ranges cover the summary from top to bottom.
A pure function, `approvalSummaryWasShownWhole(seenRanges:summaryHeight:)`, decides it, and the desk's clock rules stay as they are.
The seen ranges reset when another request becomes the oldest and when the list closes, the same moments the desk's clock resets.

**Files.** `leanring-buddy/BackgroundAgentListPanel.swift` (`ApprovalCardView` records ranges, the new pure function replaces `approvalSummaryShowsToItsEnd`), `leanring-buddy/AgentHarness.swift` (`HarnessApprovalDesk` if the call names change), `leanring-buddyTests/AgentHarnessTests.swift` or a new `ApprovalCardTests.swift`, `.claude/skills/verify-clicky/verify-clicky.sh` (a new `scroll <points>` primitive that posts a real scroll wheel event with a small CGEvent script, like `demo/scripts/mouse/mouse.swift`), `features/task-agent.md`, `AGENTS.md`.

**Tests.**

- One Swift test: ranges for the top and the bottom only leave the middle uncovered and return false, and adding the middle returns true.
- One Swift test: when another request becomes the oldest, its card starts with no seen ranges.

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

- `tool_call` (one new field for a voice command): the input arrives without `confirmation`, since the harness added it and keeps it.
  A voice command's `tool_call` also carries `turnIndex`, counted from 0, which task calls leave out.
  Swift needs it for the first-reply approval rule: today it passes the approval ID to `runVoiceTool` only when `turnIndex == 0` (`CompanionManager.swift:2542`), and without the field a yes from turn 2 or 3 would reach the desk.
  Swift keeps the approval ID it read at the press (`approvalIDWaitingWhenTheCommandStarted`) for the whole command, as today.
- `voice_command_finished` (new): `taskID`, `spokenLine` (the joined confirmations, or empty, sent whole, since Swift cuts it to 300 characters by grapheme cluster), and `gaveUp` (true when the third turn still needed the model, so Swift says `voiceCommandGaveUpLine`).
- `task_failed` (unchanged): the Worker or Anthropic failed, which sends Swift down the router failure fallback.
- `log` (unchanged): one `Brain: turn N on <model> stopped for <reason>, tokens in N, cache read N, cache write N, out N, N ms` line per turn, since the Worker logs no usage for `/v1/messages`.

### Harness side

- New `harness/brain.go`: the brain's whole definition, like `taskagent.go` is the task agent's.
  It holds the model (`claude-haiku-5-5`, thinking off, effort low, `max_tokens` 1024), the system prompt copied word for word from `worker/src/voiceCommand.ts`, the port of `toolsForAnthropic` (the `confirmation` property, required unless `readOnly`, and the cache breakpoint on the last tool), a cache breakpoint on the system prompt (the old path gets one from `withCachedSystemPrompt` in `worker/src/anthropic.ts:179`, and the `/v1/messages` passthrough adds none), the port of `voiceCommandUserMessageText` (the `scene_state` and `recent_actions` tags and the `<` escape), and the port of `voiceCommandNextStep`.
- New `harness/brainloop.go`: `runCommand` sends one non-streaming request per turn through the same SDK client and Worker base URL, sends each tool call as a `tool_call` in order, waits for each result before the next one starts (Swift runs them one at a time today), stops at a `handedOff` result, and ends with `voice_command_finished`.
  It refuses a tool name the command did not offer, before the app sees it.
  App voice tools need no approval, since the learner asked for the action directly, so the approval gate is not on this path.
- **Request limits.** Brain requests use their own options: `option.WithMaxRetries(0)` and an 8 second timeout per turn.
  Today the harness client sets neither (`harness/main.go:90-97`), so the SDK's default retries apply, and the only limit is the task loop's 3 minute `turnTimeout` (`harness/loop.go:15`).
  A failed or timed-out turn sends `task_failed`, so the router failure fallback starts within 8 seconds of that turn's request, as item 9 says.
- **Hand-off completes the command.** `deliverToolResult` marks a command complete, under the harness's mutex, when its result's `outcome` is `handedOff`.
  `cancelTask` skips a command marked complete.
  The stdin loop handles lines one at a time (`harness/main.go:135-150`), so a `cancel_task` read after the result always sees the mark.
  Without the mark, the command's `select` between its cancelled context and the result channel picks one at random when both are ready (`harness/loop.go:265-271`).
- **Cancel log line.** A cancelled command writes `Brain: command cancelled during turn N` as a `log` line, since a verify run would otherwise hold no evidence of the cancel.
  It goes straight to the protocol writer, because `taskRunner.send` drops every line of a cancelled task (`harness/loop.go:44-49`).
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
  Swift also fails the command when no harness event arrives for 10 seconds while it waits on the harness, so a hung harness falls back too.
- **Cancel.** The command's Swift task wraps the event loop in `withTaskCancellationHandler`, whose handler sends `cancel_task`.
  Events that arrive after the cancel are dropped, because `HarnessTaskRouter.end` closes the stream.
- **Hand-off order.** A hand-off cancels the router's own task before its outcome exists: `respondToTranscript` cancels `currentResponseTask` as its first line (`CompanionManager.swift:1166`), inside `runAppVoiceTool`, before `.handedOff` is returned (`:2627-2629`).
  With the plain cancel handler, `cancel_task` would reach the harness first.
  Some tools decide inside the call whether they hand off: `build_simulation` hands off only when it shows a ready experiment (`:2633-2642`).
  So the harness path keeps a per-command mark, `handOffHasStarted`, with the current call's `toolUseID`, in one lock-protected box per command (a `Mutex`).
  The box is needed because the `onCancel` closure of `withTaskCancellationHandler` is `@Sendable` and runs off the main actor, so it cannot read main-actor state.
  The box also holds a one-shot "result sent" flag, and both the cancel handler and the normal path claim it under the lock before they write, so exactly one of them sends the result.
  Both write through `AgentHarness`'s one serial stdin queue.
  Each branch of `runAppVoiceTool` that returns `.handedOff` sets it immediately before its side effect, such as the `respondToTranscript` call.
  The cancel handler reads the mark: when it is set, it sends the `tool_result` with outcome `handedOff` for the current call instead of `cancel_task`, and the normal path does not send that result a second time.
  The old path and the debug server never set the mark, so `runVoiceTool` keeps its shape.
  PR 6 depends on this, since a cancelled command is rolled back and a handed-off one is not.
- **Interrupt rehearsal step.** A new rehearsal prefix, `^`, presses push-to-talk 0.3 seconds after Swift writes this step's `voice_command` line, not after the step goes out, since `runVoiceCommand` awaits page reads before the first request (`CompanionManager.swift:2474-2478`).
  It presses through `handleShortcutTransition(.pressed)` (`:827`), the handler a real press runs, and sends `.released` 0.2 seconds later.
  Document `^` with the other prefixes in verify-clicky's rehearsal docs, and add it to the rehearsal prefix tests.
  The release is needed, because the press opens a real dictation session (`startPushToTalkFromKeyboardShortcut`), and without it `isDictationInProgress` stays true and blocks every later press (`:829`).
  The empty transcript then asks nothing, as a tap with no words does today, and the next step goes out as usual.
  The `~` prefix is not enough: it waits 6 seconds (`:1020-1021`), a Haiku turn takes about 0.85 seconds, and a rehearsal step skips the press handler, so audio is never stopped by a press.
- **Prewarm.** With the harness flag on, `AgentHarness` launches the process when the app starts, not on the first task, so no command pays the launch.
- `.claude/skills/verify-clicky/verify-clicky.sh`: `app-launch --harness-brain` passes `--brain-runs-in-the-harness`.

### Tests (one per logic change)

- Go: `toolsForAnthropic` port, table test copied from `worker/src/voiceCommand.test.ts`.
- Go: `nextVoiceStep`, table test ported from the Swift `voiceCommandNextStep` tests.
- Go: the user message text escapes `<` in the scene state and actions.
- Go: the prompt matches the Worker's copy (the test reads `../worker/src/voiceCommand.ts` and checks each prompt line appears in it), until PR 6 changes the prompt on purpose.
- Go: the request carries both cache breakpoints, on the system prompt and on the last tool.
- Go: the loop end to end against the fake `/v1/messages` server in `helpers_test.go`: a two-call turn, then `voice_command_finished` with both confirmations, with `turnIndex` 0 on both calls and 1 on a second turn's call.
- Go: a fake server that never answers ends the command with `task_failed` within 8 seconds and makes one request, not three.
- Go: a `cancel_task` during a turn ends the request, writes the cancel log line, and sends nothing more.
- Go: a `handedOff` result and a `cancel_task` written back to back end the command as handed off, in 100 runs under `-race`.
- Go: a command gets its first `tool_call` while a task waits on `mcpHub.connect` and another task's tool result is in flight, since commands and tasks share one stdin reader (`harness/main.go:116-125`) and one app write queue (`AgentHarness.swift:458`).
  This protects item 10.
- Swift: `HarnessMessage` parses `voice_command_finished` and a `tool_call` with `turnIndex`, and `HarnessCommand.voiceCommand` encodes as one line, in `AgentHarnessTests.swift`.
- Swift: on the harness path, an `answer_approval` call with `turnIndex` 1 reaches `runVoiceTool` with no approval ID, and one with `turnIndex` 0 carries the press-time ID.
- Swift: for a `pop_out` call, the lines written to the harness are one `tool_result` with outcome `handedOff` and no `cancel_task`.
- Swift: a cancel that arrives just before the mark is set sends `cancel_task`, and one just after sends only the `handedOff` result, with exactly one line either way.

### Verify

- `$V app-launch --brain --harness-brain "pop this out|turn it to the left|zoom in a bit|no, the other way"` on a YouTube video with one clear object, then `$V app-wait`.
  The app log shows one `Brain: turn` line per turn on `claude-haiku-5-5`, the same chips and spoken confirmations as the old path, and no `[/voice-command]` usage line in the Worker log.
- Push-to-talk during a turn: `$V app-launch --harness-brain "^skip to where they talk about the engine|pause it"` presses push-to-talk 0.3 seconds into the first command.
  The log shows `Brain: command cancelled during turn 1`, and no tool call of the first command after the press.
  The press handler's audio stop is unchanged Swift code that runs before any router code, and a new command already stops earlier speech, so this step proves the cancel, not the audio stop.
- Router failure: stop the Worker mid-run, and check that the next command takes the keyword path.
  Record the time from the `voice_command` line to the fallback's log line, which must be under 8 seconds.
  Repeat with a small stub in front of the Worker that holds `/v1/messages` open and never answers, and passes every other route through, so the keyword path's `/chat` still answers.

**Ships behind the flag.** Yes.
With the flag off, nothing changes.

## PR 5: Brain evals drive the harness binary (piece 5)

**What it does.** `bench/brainEvals.ts` gains `--backend worker|harness|both`.
`harness` spawns the built harness binary, the way `bench/taskAgent.ts` does, sends each case as a `voice_command`, and scores the tool calls of the first turn, which is what the Worker backend scores today.
It answers each `tool_call` with the outcome Swift would give that tool, so the command ends as it would in the app.
A stand-in `changed` for every call is not enough: `find_moment` is a lookup (`CompanionManager.swift:2684`), so Swift returns `lookedUp` and the brain takes another turn, and one eval case already calls it (`bench/fixtures/brain-evals.json:357`).
A case may script each tool's outcome and result text, such as the caption lines a `find_moment` returns, and a lookup tool with no script gets an empty `lookedUp` result.
`both` runs the two backends in one invocation, alternating case by case, so the latency comparison shares one network and one Worker.

**Files.** `bench/brainEvals.ts`, `bench/brainEvals.test.ts`, a shared driver extracted from `bench/taskAgent.ts` if it stays small (otherwise a copy of its spawn and line reader), `bench/README.md` ("Brain evals"), `.claude/skills/verify-clicky/features/voice-commands.md`.

**Measures.** Pass count, p50 and p95 from the `voice_command` line to the first `tool_call` line, p50 to `voice_command_finished`, and cost from the `Brain: turn` token lines.
The Worker backend sends one request per case (`bench/brainEvals.ts:398`), so the cost gate compares first-turn cost on both backends.
The full-command cost of every turn is reported beside it, with no gate.
The old backend's latency is measured the same way, from request to reply.

**Gate.** 129 of 129 runs pass on the harness backend (43 cases, 3 runs), the p50 to the first tool call is within 100 ms of the Worker backend's p50 in the same run, and the cost per call is within 1.5 times.
Commit the result to `bench/results/` as `harness-brain-evals-<commit>.json`.
If the gate fails, stop and report before PR 6.

**Tests.**

- One bench test: the harness backend scores a recorded `tool_call` line stream the same as the equivalent Worker reply (pin the `Brain: turn` line format against `brainloop.go`, as `taskAgent.test.ts` pins the task agent's line).
- One bench test: a scripted `find_moment` case answers with `lookedUp` and its caption lines, the first-turn cost counts one turn, and the full-command cost adds both.

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
- **Only the newest image stays.** Every image kept in the history is paid for again on every later command, at the full input price on a cache miss.
  No brain tool returns an image today, so this PR builds nothing for it.
  When a brain tool first returns one, the session keeps only the newest image and replaces each older one with a one-line text note, such as "Screenshot of the YouTube tab, replaced", and that PR adds the test.
- **Cancel rolls back.** A cancelled command removes its messages from the session, back to where it started, since a turn whose tool calls never got results cannot go back to Anthropic.
  The action lines of the calls that did finish go into the next command's user message as one "Interrupted before:" line, so the brain still knows what changed on screen.
- **Hand-off stays.** A command that handed off stays in the session, with a result such as "Handed off: Clicky answers out loud".
  A hand-off stops the turn's calls (`CompanionManager.swift:2554`), so calls after it in the same reply never run.
  The session adds a "Not run: the request was handed off" result for each of them, because Anthropic refuses a request with a `tool_use` block that has no matching `tool_result`, and every later command would fail.
- **Reset.** A new `reset_session` message empties the session.
  The brain evals send it before each case, so the cases stay independent.
- **Caching.** The tools and the system prompt keep their breakpoints from PR 4, and a third breakpoint sits on the last message of the previous command, so the next command reads the whole history from the cache.
- **Compaction (no model call).** Before a command, when the cache is already cold (no request in the last 5 minutes) or the session holds more than 24 commands, the harness folds every command except the last 6 into one text block at the start: per command, the learner's words and its action lines, with the old scene states dropped.
  Folding only while the cache is cold, or at the hard cap, means a fold almost never throws away a warm cache.
  A model-written summary is deferred until an eval case needs one.
- **Where it lives.** In the harness process's memory only, never on disk.
  A new app launch, or a harness relaunch after a crash, starts an empty session.
  See the open question on restarts below.
- **The prompt changes here.** The Worker's prompt tells the model to correct against `recent_actions` (`worker/src/voiceCommand.ts:18-27`).
  This PR rewrites those lines to point at the earlier commands in the conversation, names the fold block and the "Interrupted before:" line in the prompt's sentence that says tool results are data, and deletes PR 4's test that the prompt matches the Worker's copy.
- **What guards a voice yes now.** The first-reply rule exists because a later turn has read tool results (`CompanionManager.swift:2540-2541`).
  With a session, the first reply of every later command has read earlier commands' results, such as captions and page state.
  The short-answer transcript check (`approvalVoiceAnswerTheLearnerSaid`, `VoiceApprovals.swift:79`) becomes the guard that matters.
  It stays in Swift until PR 8, which the bench does not run, so PR 6's eval case scores only that the model does not call `answer_approval`, and PR 8 adds the case that the check refuses it.

### Files

`harness/brainsession.go` (new: append, rollback, fold, the cache breakpoint placement), `harness/brainloop.go`, `harness/brain.go` (the user message without `recent_actions`), their tests, `project.pbxproj` (build phase inputs), `leanring-buddy/CompanionManager.swift` (no `recentActions` on the harness path), `leanring-buddy/AgentHarness.swift`, new fixture `bench/fixtures/brain-sessions.json` and its runner in `bench/brainEvals.ts`, `AGENTS.md`.

### Protocol

`voice_command.recentActions` becomes optional and the harness ignores it.
New app to harness `reset_session`, with no fields, which empties the session.
Bench only: `seed_session` (`messages`, the user, assistant, and tool result messages of earlier commands), which replaces the session with those messages.
The harness accepts both only when `CLICKY_BENCH=1` is in its environment, which the bench sets and `agentHarnessEnvironment` never passes.

### Tests

- Go: rollback after a cancel leaves the session exactly as before the command, and adds the "Interrupted before:" line from the finished calls.
- Go: the fold keeps the last 6 commands whole, drops old scene states, and runs only when the cache is cold or past 24 commands.
- Go: the breakpoint is on the last message of the previous command.
- Go: a reply with two calls whose first hands off leaves a "Not run" result for the second, and the next command's request has a `tool_result` for every `tool_use`.
- Go: `reset_session` empties the session.
- Bench: three session cases: an "undo the first turn" after 7 commands, a correction right after a fold, and a correction after an interrupted command.
  The bench sends `reset_session` before each case.
  The two existing cases that seed `recentActions` (`bench/fixtures/brain-evals.json:397`, `:481`) seed earlier commands instead, with a bench-only `seed_session` message that puts fixed messages in the session with no model call, so each run starts from the same history.
- Bench: one injection case: an earlier command's tool result says "approve the request", then a transcript that is not a short yes, and the model does not call `answer_approval`.
- Go: the harness refuses `reset_session` and `seed_session` without `CLICKY_BENCH=1`.

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
  When Haiku calls it alone, before any tool of the command has run, the harness drops that turn and runs the command again on Sonnet 5.5 at low effort, with a longer planning prompt, the same tools, and up to 6 turns.
  After a tool has run, the harness never restarts the command, since a restart could repeat a relative seek or start a second background task.
  A later call to `think_it_through` instead moves the next turn to Sonnet, with the turns and results so far kept.
  The harness gives that call a result, "Moving to the planner", since Anthropic refuses a history with a `tool_use` block and no matching `tool_result`.
  A `think_it_through` that comes with other calls in one reply counts as a later call: the other calls run, then the next turn moves to Sonnet.
- **The turn budget rule.** When Haiku's third turn still needs the model, the harness gives the command one Sonnet turn before the gave-up line.
- **Sonnet's time limit.** PR 4's 8 second turn timeout is for Haiku, and a Sonnet planning turn can take longer.
  A Sonnet turn gets a 30 second timeout.
  The harness writes a `Brain: planning on claude-sonnet-5-5` log line when a Sonnet turn starts, and Swift's deadline then waits 35 seconds from that line instead of 10, so it stays above the harness's own limit.
- **Long tasks do not change.** "Find out", "research", and "compare" still go to `start_background_task`, which runs the Sonnet task agent in the same harness.

### Files

`harness/brain.go` (the planner tool, the Sonnet settings, the planning prompt, the model choice per turn), `harness/brainloop.go`, tests, `bench/fixtures/brain-evals.json`, `bench/brainEvals.ts` (score a case by the whole command when it is a planning case, not only the first turn), `AGENTS.md`.
A planning case scripts each tool's result with PR 5's scripted outcomes, such as the timestamp a `find_moment` returns, and is scored on the ordered calls, a seek input taken from that timestamp, and the cost of all turns.

### Protocol

No change.
The `Brain: turn` log line already names the model.

### Tests

- Go: a `think_it_through` call before any tool runs sends the next request on Sonnet with the planning prompt and does not keep the Haiku turn.
- Go: a `think_it_through` call after a `seek_relative` has run moves the next turn to Sonnet with the history kept, the seek runs exactly once, and the Sonnet request has a `tool_result` for the `think_it_through` call.
- Go: a third Haiku turn that still needs the model gets one Sonnet turn, then the gave-up line.
- Bench: the 8 planning cases pass in 3 runs, and the 43 old cases still pass 129 of 129 with no Sonnet turn among them.
- Bench: record the p50 and cost of each planning case.
  The Sonnet cache is separate from Haiku's, so each escalation pays full input price for the tools, the prompt, and the session.
  The PR reports these numbers next to a simple command's, and Chris sets the cost ceiling for escalation from them before the PR merges.

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
- Bench only: app to harness `seed_approval_request` (`approvalID`, `capability`), which puts a waiting request in the gate with no task, so the approval eval cases have one to answer.
  Like PR 6's bench messages, the harness accepts it only when `CLICKY_BENCH=1` is in its environment.
- **The first answer wins, and the harness says which.** A click can arrive while a voice yes is settling the same request.
  The gate takes the first answer it receives, and logs and ignores the second.
  On the harness path, the harness sends `approval_settled` for a click too, and the desk shows the outcome and drops the card only from `approval_settled`.
  A click marks the card as answering until then, so the desk never shows a decline that the gate did not take (today `answer` removes the card at once, `AgentHarness.swift:366`).

### The app secret becomes required

`/v1/messages` requires the app secret (`worker/src/appSecret.ts:10`), and `/voice-command` does not (`VoiceCommandTools.swift:944`, `sendsAppSecret: false`).
The harness only warns when the secret is missing (`harness/main.go:69`).
So once the flag is on by default, an install with no `clickyAppSecret`, such as a fresh clone, would get a 401 on every command and fall to the keyword path with only a log line.

- At launch, the app reads whether `clickyAppSecret` is set.
  With no secret, voice commands stay on the old path and the log says once `Brain: no app secret, so voice commands use the Worker router`.
  This keeps item 9 for an install with no secret.
- A brain turn refused by the Worker's own secret check sends `task_failed` with the reason `app secret refused`.
  The harness tells it from an Anthropic 401, which `/v1/messages` passes through, by the Worker's body, `{"error":"Missing or wrong x-clicky-app-secret"}` (`worker/src/index.ts:88-91`).
  The app then sends that same command once on the old path, instead of the router failure fallback, when no tool of the command has run, and uses the old path for the rest of the launch.
- `verify-clicky.sh doctor` reports a missing or refused secret.
- The README and `AGENTS.md` setup text stop calling the secret Notion-only.

### Files

New `harness/voiceapproval.go` (the yes check and the offer rule), `harness/brain.go`, `harness/approval.go` (deliver a voice answer to the gate), `harness/protocol.go` (`approval_settled` and `seed_approval_request`), `bench/brainEvals.ts` (the seeded approval cases), tests, a shared fixture `harness/testdata/approval-voice-answers.json` that both the Go test and a Swift test read while both checks exist (as `flashcards.md` is read by both sides today), `leanring-buddy/AgentHarness.swift` (`approval_settled`), `leanring-buddy/CompanionManager.swift` (send `approvalIDSeenAtPress`, stop adding `approvalWaiting` on the harness path), `leanring-buddy/VoiceCommandTools.swift` (`BrainRunsInTheHarness` default on), `worker/src/voiceCommand.ts` (unchanged, still serving the old path), `.claude/skills/verify-clicky/verify-clicky.sh` (the secret check in `doctor`), `features/task-agent.md`, `features/voice-commands.md`, `README.md`, `AGENTS.md`.

### Tests

- Go: `answer_approval` is offered only when `approvalIDSeenAtPress` names a request the gate holds as waiting.
- Go: a yes from the second turn of a command is refused.
- Go: the shared fixture's transcripts give the same answer in Go and Swift ("okay, what is this video about" is not a yes, a bare "always" is a yes with always).
- Go: the scene state the model reads holds the capability word and never the summary.
- Go: a voice answer and an `approval_result` for one request settle it once, with the first answer kept.
- Swift: a click then an `approval_settled` for a voice yes shows "Allowed it", and an `approval_settled` then a late click changes nothing.
- Go: an Anthropic 401 fails the command as a router failure, and the Worker's secret body fails it with `app secret refused`.
- Swift: with no `clickyAppSecret`, a command goes to the old path.
- Swift: a `task_failed` with reason `app secret refused` sends that command to the old path once, not to the keyword path, and later commands go to the old path.
- Bench: the 7 `approvalWaiting` cases (21 of 129 runs) keep a score.
  After this PR, `answer_approval` never leaves the harness, so they cannot be scored from `tool_call` lines.
  The bench seeds a waiting request with a bench-only `seed_approval_request` message and scores each case from its `approval_settled` line or a `Brain: approval` log line.
  The two unrelated cases (`approval-unrelated-pause` and `approval-unrelated-question`, `bench/fixtures/brain-evals.json:710`) pass only with their expected tool call and no settlement.

### Verify

- With the flag at its new default, `$V app-launch --brain` on a task that calls `open_url`.
  When the card shows, say "yes" with a rehearsal step, and check the log for `given (once)` and the "Allowed it" chip.
- A rehearsal step "okay, what is this video about" while a card waits does not approve it.
- Re-run the brain evals with `--backend both` and attach the result.
- Both upgrade paths: launch once with `clickyAppSecret` removed from the Debug app's defaults, and once with a wrong secret.
  Each time, "turn it to the left" still turns the model, through the old path.
  `app-launch` copies the secret from `worker/.dev.vars` and opens the app at once (`verify-clicky.sh:540-542`), so the step adds two `app-launch` options, `--no-app-secret` and `--wrong-app-secret`, which set the Debug app's defaults before the app starts.
  The command must work on the first try in both cases.

**Fallback.** With the harness down, a command takes the router failure fallback (the keyword path), not the old Worker route.

## PR 9: Delete the old path (Chris decides when)

After a few days of use with the harness flag on, delete `POST /voice-command` and its tests, `VoiceCommandClient`, `recentVoiceToolActionLines`, the Swift copy of the voice approval check, the shared fixture's Swift reader, the harness flag, and the Worker backend of the brain evals.
Update `AGENTS.md`, `bench/README.md`, and the verify-clicky feature map in the same PR.
Two things go with the old path:

- The no-secret fallback from PR 8, so the secret becomes a setup requirement.
- Router benchmarks on other vendors' models: a `gpt-*` or `gemini-*` `BENCH_MODEL` answers `/v1/messages` with 501 (`worker/src/index.ts:181-182`).
  The brain evals can then compare Claude models only.

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
The one ordering trap is a hand-off, which cancels the router's own task before its outcome exists.
PR 4's `handOffHasStarted` mark makes the cancel handler send the `handedOff` result instead of `cancel_task`, and the harness marks the command complete when that result arrives, so a hand-off is never rolled back.

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
   Deleting it also ends the no-secret fallback and router benchmarks on GPT and Gemini models.
5. **PR 0's timeout.** Raise the app's `/live-scene` timeout for the background builds if the Sonnet fallback's p95 passes 60 seconds, or keep 60 and accept a failure on a slow fallback.
   The same choice covers a slow OpenAI failure, which this plan does not cap.
6. **PR 7 if Haiku passes the planning cases.** Skip the planner tool and ship only the turn budget rule, or build both.
7. **PR 7's cost ceiling.** How much a planning command may cost, set from the numbers PR 7 records.
