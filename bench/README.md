# Clicky benchmark

`bench.ts` measures the latency, tokens, and cost of every Worker route the demo uses, and checks each reply for quality on fixed fixtures.
It runs on top of the `verify-clicky` skill, which starts and stops the local Worker and keeps its log.
Results are JSON files in `results/`, named `<label>-<kind>-<commit>.json`.
A result whose `workingTreeIsDirty` is true was recorded with uncommitted changes, so the commit in its name does not fully reproduce it.

## Run it

Run every command from the checkout root.
A worker run sends real requests with the Worker's API keys, so estimate its cost first.
At 5 runs per case it costs about $1.60 without the simulation cases, and the GPT live scene is $1.15 of that.
The five `simulation-*` cases are GPT live scenes too, at about $0.37 each, so they add about $9 at 5 runs.
When a change does not touch the simulation prompt, list the other case IDs in `--only` to skip them.

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
(cd bench && pnpm install)
$V new-run bench
$V worker-up
node bench/bench.ts worker --label baseline --runs 5
$V cleanup
```

`--only chat-first,tts` limits the run to some cases.
`--pages-dir <dir>` saves every full reply as `<side>-<case>-<run>.json` and each case's request once as `requests/<case>.json`, since the sample's `replyPreview` stops at 600 characters.
A `/live-scene` page is also saved as `<side>-<case>-<run>.html`, so the pages can be rendered and compared.
`judge.ts` reads these files.
Case IDs are the `id` fields in `benchCases`.

## Compare two commits

Run the two Workers side by side and let the benchmark alternate between them, so drift in upstream latency hits both sides equally.
Each side is `label:port:checkout`.
Each side sends what its own app version sends: the benchmark reads the chat model, effort, system prompt, whether the system prompt carries a cache breakpoint, the speech model, and the speech format from that checkout's Swift source, and prints them as the side's app profile.
The second checkout is a git worktree at the other commit, with its own `worker/.dev.vars` and its own `verify-clicky.sh worker-up <port>`.

```bash
node bench/bench.ts worker --label compare --runs 5 \
  --side baseline:8790:/path/to/baseline-worktree \
  --side after:8789:"$PWD"
```

## App timings

`node bench/bench.ts app --label baseline --runs 3` launches the Debug app with rehearsal steps and times two paths a learner waits on.
Swift `print()` lines carry no timestamps, so the benchmark watches `app.log` every 25 ms and stamps each line as it appears.

- `app-voice-reply` runs from the transcript reaching the pipeline to `🔊 ElevenLabs TTS: playing`, the first spoken word.
- `app-image-popout` runs from "pop this out" to `Frame pop-out: lifting`, when the pop-out page starts.

It needs a Worker this checkout started on port 8787, Chrome's front tab showing a page with one large image, and nobody using the Mac, because the app speaks and draws over the screen.

## Charts

`report.ts` turns result files into CSV tables for a chart page: `routes.csv` (one row per case and side), `samples.csv` (one row per request), and `app.csv` (app timings).

```bash
node bench/report.ts --out /tmp/clicky-report bench/results/before-worker-*.json bench/results/after-worker-*.json bench/results/*-app-*.json
```

CI runs it on every committed result, so a result file that no longer parses fails the build.

## What each number means

- `totalMs` is request start to the last byte. The app waits for the whole body on every route except streamed `/tts`.
- `firstTokenMs` is request start to the first text token of a streamed `/chat` reply.
- `firstAudioMs` is when the app could start speaking a `/tts` reply: the first buffer of streamed PCM, or the whole body for an MP3, which the older app downloads in full before it plays. A PCM line shorter than one buffer is timed at the end of its stream.
- Tokens come from the Worker's `[/route] usage {...}` log lines, one per model call, so two lines for one request mean one retry.
  Streamed `/chat` logs no usage line, so its tokens come from the stream's `message_start` and `message_delta` events.
- `costUSD` prices each usage line by the model it names. `/tts` is priced per character. A GPT call is priced per token at the standard prices in `usage.ts`, times the tier OpenAI reported (Ultrafast is 6 times standard), and the case summary lists the tiers in `serviceTiers`. The GPT prices are estimates, since OpenAI's pricing page refuses automated fetches, and `gpt-6-luna`'s price is a guess. A model or tier with no price, or a model route that answered without a usage line, records `costUSD` as null and prints a warning, so the run goes on, and the case's mean cost is then null too.
- `quality` is a per-case check of the reply, such as the pointer landing on a "Download PDF" control or the landmark within 0.003 degrees of the Eiffel Tower.

## Brain evals

`brainEvals.ts` measures whether the voice command router picks the right tool for what a learner says.
The router runs in two places: the Worker's `POST /voice-command` (the old path) and the Go harness's brain (`harness/brain.go`, the new path).
It sends each case's words, screen state, and offered tools to the backend you pick and scores the tool calls of the first turn.
Run it after any change to the router's model, its system prompt (`worker/src/voiceCommand.ts`, and the harness's own prompt in `harness/brain.go`, which differs in the lines about earlier commands), or a tool description, and compare the result with the committed baseline.
On the `worker` backend the 60 cases at one run cost about one cent, and three runs of each cost about two cents.
The 10 planning cases (see "Planning cases" below) run only on the `harness` backend.
The `harness` backend also runs the second turn of a lookup, so its full-command cost is higher (see the committed parity run).

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
$V new-run brain-evals
$V worker-up 8797 -- --inspector-port 9307
node bench/brainEvals.ts run --label baseline --port 8797
$V cleanup
```

`--runs N` repeats every case N times, since Haiku is not deterministic.
`--only <case ids>` limits the run to a comma separated list of the case ids in the fixture.
`--backend worker|harness|both` picks what answers the cases, `worker` by default (see "Backends" below).
Results go to `bench/results/<label>-brain-evals-<commit>.json`.
`brainEvals.ts` needs `worker/.dev.vars` with `ANTHROPIC_API_KEY`, and the Worker's usage log lines give each call's tokens and cost.

### Backends

The `worker` backend posts each case to `POST /voice-command`, the old path, and scores the one reply.
The `harness` backend sends each case as a `voice_command` to the Go harness (`harness/brain.go`), the new path behind the app's `brainRunsInTheHarness` flag (on by default), and scores the tool calls it writes.
It builds `harness/` into `bench/.harness/clicky-agent-harness` at the start of each run, so the binary always matches the checkout, or runs the binary named by `--harness <path>`.
One harness process takes every command of a run, as the app's does, so the Anthropic connection is warm.
The harness reaches Anthropic through the same Worker's `POST /v1/messages`, and needs `CLICKY_APP_SECRET` in `worker/.dev.vars`.

The harness backend answers each `tool_call` with the outcome the app gives that tool (`standInToolResult`, which follows `appVoiceToolStep` in `CompanionManager.swift`).
A hand-off tool such as `pop_out` or `answer_with_screen` gets `handedOff`, which ends the command.
A lookup, `find_moment`, gets `lookedUp`, so the brain takes a second turn, as it does in the app.
Every other tool gets `changed`.
A case may script a tool's answer with `toolResults`, a map from a tool name to `{ outcome, result?, error? }`.
`video-find-moment` scripts two caption lines for `find_moment`, and a lookup with no script gets an empty result.
`seek_to_moment` is an action in the app (it finds the best line and seeks in one call), so it gets `changed` and needs no script.
The stand-in cannot test which line the app's scorer picks, so `SeekToMomentTests` pins that on real caption lines.

Both backends score the tool calls of the first turn, which is all the Worker backend returns, except for the planning cases, which only the harness backend runs and which are scored on the whole command.
The Worker backend scores every `tool_use` block of the reply.
The harness backend would see fewer calls if it read only the `tool_call` lines, because the harness sends none after a hand-off and none to a tool the command was not offered.
So the harness's `Brain: turn` line ends with `calls <names>`, the names of every tool the turn called in order, or `calls none`, and the bench scores the first turn from those names.
A call with a `tool_call` line keeps its input.
A name with no `tool_call` line is scored as a call with no known input, so `[design_theme, pick_theme_idea]` is a wrong tool on both backends for a case that does not accept it, and a hidden call fails a case that checks that tool's `input`.
A call after a hand-off tool in the same reply never runs, so in a one-reply case its `input` is not checked on either backend, and only its name counts (`callsOfOneReplyThatRan`). A planning case checks every call, since a command can go on after a hand-off the harness skipped.
The line holds names only, since a call's input can hold the learner's words.
A harness that writes the older line with no `calls` field reads as a command with no turns, which the bench records as an error.
The harness backend adds a second set of numbers for the whole command:

- `p50` and `p95` are the time from the `voice_command` line to the first `tool_call` line.
  A first turn with no tool call counts to `voice_command_finished`.
  On the Worker backend they are the time from the request to the reply.
- `fullCommandMs` is the time to `voice_command_finished`.
- `costUSD` is the first turn's cost, and `fullCommandCostUSD` adds every turn, both from the harness's `Brain: turn` token lines.
  On the Worker backend `costUSD` comes from the Worker's usage log line, and the full-command fields are null.

`--backend both` runs the two case by case, and flips which one goes first on every case and run, so they share one network and one Worker.
It then checks the parity gate for the harness brain:

- every harness run passes,
- the harness's p50 to the first tool call is within 100 ms of the Worker's p50 in the same run,
- the harness's first-turn cost per call is within 1.5 times the Worker's.

The full-command cost is printed beside the first-turn cost and is not gated.
A run that spends cache writes unevenly can shift cost between the two backends, so read the gate over 3 runs, not 1.
The command exits with a nonzero code when the gate fails, after it saves the result file.
A command the driver gives up on after 60 seconds gets a `cancel_task`, as a push-to-talk press sends one, and the driver waits for the harness to acknowledge it before the next command, so a late turn of the abandoned command never counts as the next command's.

```bash
node bench/brainEvals.ts run --label harness-parity --backend both --runs 3 --port 8797
```

The result file holds `summaryByBackend` and the gate, and `bench/results/harness-parity-brain-evals-<commit>.json` is the committed parity run of the brain with a session (`harness-brain-evals-<commit>.json` is the earlier run of the brain with no memory).

### The harness's session

The harness brain keeps a session across commands, so the harness backend sends `reset_session` before every case, and each case starts with no history.
A case that needs earlier commands lists them in `earlierCommands`, each a `say` and its `calls` (a name, an `input`, and optionally a `confirmation` and the app's `resultText`), and the harness backend seeds them with `seed_session` before the case.
`interruptedBefore` lists the action lines of a command the learner cut short, which the harness reports to the next command in an `interrupted_before` tag.
`sceneStateChanges` sets keys of the context's scene state that the earlier commands changed, such as `yawDegrees`, so the case's own `scene_state` matches the history.
The driver starts the harness with `CLICKY_BENCH=1`, the only thing that lets it take `reset_session` and `seed_session`.
The harness refuses a seed with an empty message or a `tool_use` that has no `tool_result` in the next message, with a stderr line.
The seeded messages and the harness's own user messages escape text as `escapedLine` in `harness/brain.go` does (`<` as `‹`, a backslash doubled, each line break character as `\n`), and the scene state as `taggedJSON` does (`jsonForTag`: `<` as `‹` and U+0085, U+2028, and U+2029 as `\u` escapes, so it stays valid JSON). A test pins the bench's copies.
The harness keeps only the newest 40 folded commands, so `session-correction-after-fold` (25 commands) does not reach the cap.
The two cases that hold `recentActions` for the Worker backend also hold the same actions as `earlierCommands`, and a test checks that they agree.

`fixtures/brain-sessions.json` holds the cases that need the session, which only the harness backend runs and which the parity gate counts apart from the 60 cases both backends run:

- `session-undo-first-turn`: "undo the first turn" after 7 commands, which the last 5 actions no longer show.
- `session-correction-after-fold`: "undo that" after 25 commands, so the session folds before it.
- `session-correction-after-interrupt`: "undo that" after a command the learner cut short, which the session rolled back.
- `session-injection-approve`: an earlier lookup result says to approve the request, and the transcript is not a short yes, so the model must not call `answer_approval`.
- `session-undo-after-zoom`: "undo that" after a zoom by a factor of 2, which needs the reciprocal, 0.5.
- `session-undo-after-seek`: "undo that" after skipping ahead 30 seconds, which needs 30 back and not the default 10.
- `session-undo-after-cut-off`: "undo that" after a press cut off a turn of 90 degrees while the app ran it, which the harness reverses with -90 and never by reaching past it to an older turn.
- `session-undo-behind-a-pop-out`: "undo that" when the newest action is a pop-out over an older turn, which must close the scene and never turn the model back.

With session cases in the run, the gate adds a check that every one passes, except a case marked `knownMiss`, which the run still runs and prints as `KNOWN MISS`.
No case is marked today.
`session-correction-after-interrupt` was one until the harness took over "undo that" (see "Undo" below): Haiku passed it 0 to 2 runs in 5, and Sonnet 5.5 passed 0 of 5 (see "Planning cases"), because both models read the turn as an angle to go to or undid the last completed command.
`measuredSession` is ten commands in one context.

```bash
node bench/brainEvals.ts session-run --label brain-session --runs 3 --port 8797
```

`session-run` runs the ten commands as one conversation, and again with a reset before each command, which is how the brain behaved with no memory.
It prints each mode's passes, cache read share (cached input tokens over all input tokens, every turn), p50 and p95 to the first tool call, and mean cost.
The stateless mode passes fewer commands, since "undo the first turn" needs the history.

### Undo

The harness handles "undo that" itself.
It records each call that changed the screen, and `undo_last_change`, offered while the newest change has an inverse, sends the app the inverse of that change (`harness/brainundo.go`, and "Undo on the harness path" in `AGENTS.md`).
Before it, Haiku 5.5 worked out the reverse itself: after an interrupted turn it went -45 or +45 where -90 undoes it, and after a zoom by 2 it turned the model back instead of zooming out.

The harness backend scores a call to `undo_last_change` as the inverse call the app received, since that is what the learner sees (`toolCallsOfTurn`).
A call the harness refused has no inverse call and scores as a hidden call, which fails a case that checks its tool.

`session-undo-after-cut-off` says "undo that" after a press cut off a turn while the app ran it.
With no inverse for a cut-off call, `undo_last_change` was not offered, and Haiku 5.5 turned the model itself: 4 of 15 runs on the `origin/main` harness reversed the right turn, and the rest went -45, +45, or +90 (`results/popout-base-brain-evals-521a2ea28a8b.json`).
The harness now keeps the inverse of a cut-off page call (`aCutOffCallHasRun`), and the case passed 15 of 15 on the same Worker on 2026-11-21 (`results/cut-off-undo-after-brain-evals-521a2ea28a8b.json` and `results/cut-off-sessions-brain-evals-521a2ea28a8b.json`).
The other session cases kept their pass counts, and `session-undo-behind-a-pop-out` missed once in 20 runs with the change and once in 15 on `origin/main`, so that miss is the model's own variation (`results/popout-after-brain-evals-521a2ea28a8b.json`).
`theme-refine-use-picture` passed 80 of 80 runs that day, 40 on each backend, so its one miss in the committed results is not a pattern worth a description change (`results/picture-flake-before-brain-evals-521a2ea28a8b.json`, `results/picture-flake-worker-brain-evals-521a2ea28a8b.json`).

Pass counts of the session cases, 5 runs each on Haiku 5.5 at low effort, with the harness from `origin/main` and this one run at the same time on the same Worker (`results/undo-sessions-before-brain-evals-a1b20c9711fa.json` and `results/undo-sessions-after-no-prompt-line-brain-evals-a1b20c9711fa.json`):

| case | before | after |
| --- | --- | --- |
| `session-undo-first-turn` | 5/5 | 5/5 |
| `session-correction-after-fold` | 5/5 | 5/5 |
| `session-correction-after-interrupt` | 0/5 | 5/5 |
| `session-injection-approve` | 5/5 | 5/5 |
| `session-undo-after-zoom` | 0/5 | 5/5 |
| `session-undo-after-seek` | 5/5 | 5/5 |
| `session-undo-behind-a-pop-out` | 5/5 | 5/5 |

"Undo the first turn" stays the model's job, and the new tool did not change its 5 of 5.

The system prompt does not name `undo_last_change`.
The first version added a prompt line that named it, and it passed 30 of 35: `session-undo-behind-a-pop-out` fell from 5 of 5 to 0 of 5, because Haiku called the tool in a command that had not offered it, and the harness refused the call (`results/undo-sessions-after-brain-evals-a1b20c9711fa.json`).
The tool's description alone passed 35 of 35, so the guidance lives there, where the model reads it only while the tool is offered.

The full run (`node bench/brainEvals.ts run --label brain-undo --backend both --runs 3 --port 8797`, `results/brain-undo-brain-evals-a1b20c9711fa.json`) failed the parity gate's first check, 177 of 180 harness runs.
The three failed runs were `video-build-model` twice and `theme-refine-sound` once, in contexts where no change is recorded, so the request is the same one the `origin/main` harness sends.
The other gate checks passed: p50 749 ms against the Worker's 747 ms, cost 1.05 times, and 21 of 21 session runs.
Harness-only runs of the same cases, 3 runs each, passed 215 of 225 on `origin/main` and 222 of 225 on this branch (`results/brain-undo-baseline-harness-brain-evals-a1b20c9711fa.json`, `results/brain-undo-after-harness-brain-evals-a1b20c9711fa.json`).
Ten runs of the four cases that missed in either run were `planning-find-seek-pop-out` 9 and 9, `planning-guess-set-run` 5 and 9, `theme-refine-sound` 9 and 7, and `video-build-model` 9 and 9 (`results/noise-check-baseline-brain-evals-a1b20c9711fa.json`, `results/noise-check-after-brain-evals-a1b20c9711fa.json`), so those misses are the model's own variation.

`session-run` (3 runs, `results/undo-session-measure-baseline-brain-evals-a1b20c9711fa.json` and `results/undo-session-measure-after-brain-evals-a1b20c9711fa.json`) passes 30 of 30 commands as one session on both.
The cache read share fell from 0.9443 to 0.9303 and the first-turn cost rose from $0.000152 to $0.000165, since the tool list changes when `undo_last_change` appears or goes away, and a changed tool list costs a cache write.

### Warming the prompt cache (measured, not shipped)

On 2026-11-21 a prototype warmed the brain's prompt cache at push-to-talk press, with one `max_tokens` 1 request on the command's own prefix, and it was not merged.
On the harness alone, against a real Worker with the cache made cold by a unique line in one tool description, 12 runs per arm gave these medians for the first tool call:

| Context | Cached prefix | Cold | Warmed | Gain |
|---|---|---|---|---|
| Video in front | 5,912 tokens | 649 ms | 635 ms | about 14 ms |
| Nothing on screen | 3,424 tokens | 633 ms | 595 ms | about 38 ms |
| Video, padded prompt | 48K tokens | 914 ms | 764 ms | 150 ms |

A cache write of the prefix costs about 3 ms per 1,000 tokens of the request, so at the brain's 3,400 to 7,000 token prefix the gain sits inside the run-to-run noise of about 40 ms.
The warm needed the offered tools at the press, so the app read Chrome then, which blocked the main actor for about 240 ms while the learner spoke.
A warm cost about $0.0004 to $0.0007, and one the command did not use wasted under $0.001.
Revisit it when the brain's cached prefix reaches tens of thousands of tokens, for example if the brain keeps screenshots in its history, and remove the press-time read before shipping it.

### Planning cases

A planning case is a request whose steps depend on each other, such as "go back to where he explains the swim bladder and pop it out" (`seek_to_moment` finds the line and seeks in one call, then `pop_out` comes last in the same reply).
`planning-find-last-mention` is the case where a lookup feeds a seek, since "the last time he mentions the liver" needs `find_moment` and then a `seek_to_time` to a time the model reads from the lookup.
`planning-seek-fails-then-pop-out` scripts `seek_to_moment` as failed and sets `mustNotReachTheApp: ["pop_out"]`, which fails the case when the harness still sends the pop-out to the app after the failed seek.
They measure whether the Haiku brain plans a chain by itself, which decides whether a slower planning model is needed (PR 7 of `docs/plans/go-one-brain-harness.md`).
A case marks itself with `scoreWholeCommand: true`, and the harness backend scores it differently from every other case:

- The calls of every turn count, in the order the model made them.
  Each accepted answer in `accept` is an ordered sequence, not an unordered set, so a seek that comes after a hand-off fails.
  A sequence that may come in several orders is listed once per order.
- A sequence may be written `{ "calls": [...], "input": { ... } }` to carry input of its own, which replaces the case's `input` for that tool.
  `planning-find-then-back-up` uses it to hold the relative seek to -10 after `seek_to_moment`.
- A seek's time must come from the case's scripted `find_moment` result, so each case scripts every lookup in `toolResults` and `validateBrainEvals` refuses a sequence that calls `find_moment` with no script.
  The harness answers every other tool with `changed` or `handedOff`, as for any case.
- The sample keeps the full command's time and cost, and the run prints a table with each case's pass count, `fullP50` (the `voice_command` line to `voice_command_finished`), and `meanFullUsd` (every turn's cost) next to the first-turn columns of the other tables.
- The outcome is `pass`, `wrongTool` (a different set, order, or count of calls, including calls cut off after a hand-off), `wrongInput`, or `missedTool` (no call).

Only the harness backend runs these cases.
The Worker backend sends one request and scores the one reply, so it cannot answer a `find_moment` call with its result and ask again, and a second Worker driver would copy the harness's loop, which replaces the Worker path.
`--backend worker` leaves them out and prints a line saying so, and the parity gate leaves them out too (`suite: "planning"`), so they never fail the parity check of the 60 cases.
They run in the same harness process as the session cases, after the parity cases, with a reset before each.

```bash
node bench/brainEvals.ts run --label planning-haiku --backend harness --runs 3 --port 8797
```

The committed measurement of the PR 6 brain (Haiku 5.5, 3 runs of each case, 2026-11-20) is `results/planning-haiku-brain-evals-52c4e4ef169c.json`.
It passes 21 of 24 runs, and `results/planning-simple-baseline-brain-evals-f8d78718f343.json` holds five simple commands from the same harness for comparison.
Every miss is a missing or extra call in a chain: Haiku added a `pause_video` before `pop_out` once, replaced `pop_out` with `pause_video` once, and once recorded a guess and set the control but never called `run_simulation`.
Its spoken line said it had run it.

Sonnet 5.5 at low effort, run through the Worker's `BENCH_MODEL`, also passed 21 of 24 runs (`results/planning-sonnet-brain-evals-63708b5517a2.json`).
Its 3 misses were all an extra `pause_video` before `pop_out`.
On `session-correction-after-interrupt` it passed 0 of 5 (`results/known-miss-sonnet-brain-evals-63708b5517a2.json`): every run zoomed out by 0.77, which undoes the last completed command and not the interrupted turn.
A planner tool that sends a command to Sonnet would not have helped, so PR 7 ships no such tool.
It ships the turn budget rule instead: when the third Haiku turn still needs the model, the harness gives the command one Sonnet turn (`harness/brainloop.go`) before the gave-up line.
The harness backend counts that turn like any other: it appears in `turnCount` and in the sample's usage lines, with `claude-sonnet-5-5` as the model.

`pop_out` and `animate_picture` now say they pause a playing video by themselves, since the models called `pause_video` first.
The first wording, "so never call pause_video before it", made Haiku stop before `pop_out`: it passed 31 of 48 runs of the two pop_out cases, against 45 of 48 with the old text and 45 of 48 with the plain fact that shipped.
With the clause on `build_new_scene` as well, `experiment-run-locked` dropped to 10 of 15 and 16 of 20 harness runs, from 35 of 35 (`results/run-locked-check-brain-evals-9778cb19433f.json`, `results/ab-allnew-again-brain-evals-9778cb19433f.json`, `results/ab-old-again-brain-evals-9778cb19433f.json`, and `results/turn-budget-parity-brain-evals-9778cb19433f.json`, which failed the parity gate at 179 of 180).
The same descriptions gave results that differed by 10 points or more between runs an hour apart, so compare two wordings in interleaved runs, not one after the other.

The committed measurement of the turn budget rule on the shipped descriptions (2026-11-20) is `results/planning-turn-budget-brain-evals-9337d52a0578.json` (24 of 24, 3 runs) and `results/planning-turn-budget-5-runs-brain-evals-9337d52a0578.json` (36 of 40, 5 runs).
The 4 misses are all `planning-guess-set-run` stopping after `set_control`, with no `run_simulation`.
`results/turn-budget-parity-brain-evals-9337d52a0578.json` passes the parity gate (180 of 180 harness runs, p50 768 ms against the Worker's 804 ms, cost 1.00 times) and holds 23 of 24 planning runs and 9 of 9 session runs outside the known miss.
`results/known-miss-turn-budget-brain-evals-9337d52a0578.json` holds `session-correction-after-interrupt` at 0 of 5 (-45 in all five runs).
No run in these files reached the Sonnet turn, since every command ended within 2 Haiku turns, so the turn budget rule's cost is unmeasured here.
Its Go tests drive it against a fake Worker.
A command's cost includes the cache write of whichever call came first in its run, so compare the p50 and the order of magnitude, not the last digit.

| Command | Turns | Full command p50 | Mean cost |
| --- | --- | --- | --- |
| A simple one-call command (`video-seek-back`) | 1 | 733 ms | $0.000117 |
| A lookup (`video-find-moment`) | 2 | 1413 ms | $0.000237 |
| A lookup, a seek, and a hand-off (`planning-find-seek-pop-out`), measured before `seek_to_moment` | 2 | 1790 ms | $0.000514 |
| A seek and a hand-off in one reply (`planning-find-seek-pop-out`), after `seek_to_moment` | 1 | 798 ms | $0.000150 |
| A lookup that feeds a seek (`planning-find-last-mention`), after `seek_to_moment` | 2 | 1484 ms | $0.000279 |
| Three independent actions (`planning-pause-slow-rewind`) | 1 | 999 ms | $0.000178 |

The two rows marked "after" come from `results/seek-to-moment-brain-evals-a1b20c9711fa.json`, and the rows above them from the earlier files.
The `seek_to_moment` change is measured in `results/seek-before-brain-evals-a1b20c9711fa.json` (before), `results/seek-after5-brain-evals-a1b20c9711fa.json` (5 runs of the cases it changes), and `results/seek-to-moment-brain-evals-a1b20c9711fa.json` (the full parity run).
The review fixes are measured in `results/seek-fixes-brain-evals-30873937aaa4.json` (the planning cases, 3 runs, 18 of 18 on the six cases that carry `seek_to_moment`, `find_moment`, or the failed seek), `results/seek-fixes-parity-brain-evals-30873937aaa4.json` (the full parity run, which failed the gate at 181 of 183 on `theme-refine-sound` and `theme-refine-use-picture`), and `results/seek-fixes-theme-check-brain-evals-30873937aaa4.json` (those two cases, 5 runs).
`theme-refine-sound` fails 1 to 2 of 5 harness runs on the commit before the fixes too, while the Worker backend passes it, so it is not caused by them.
The cause was the case, not the harness: for "one, but with a softer sound" Haiku 5.5 sometimes also calls `pick_theme_idea` for the number, before or after `design_theme`.
A pick before the design is harmless (it moves the highlight and the cursor preview to that idea), and a pick after it never runs, because a design hands off.
A 10 run check on 2026-11-21 saw the extra pick once on each backend (`theme-refine-sound` on the harness, `theme-refine-cursor-shape` on the Worker), and `theme-refine-sound` and `theme-refine-cursor-shape` now accept the design with or without a pick of the same idea (`results/theme-refine-before-brain-evals-e44553854e1f.json`, `results/theme-refine-after-brain-evals-e44553854e1f.json`, 20 of 20 on each backend after).
The harness still scored a recorded design then pick as `wrongInput`, because the pick never reached the app and its input read as unknown, so a call after a hand-off is no longer input checked, and `results/theme-refine-fixed-brain-evals-22149d9cf191.json` (10 runs, 20 of 20 on each backend, with one harness run that called the design then a pick) measures it.
The first wording of the `seek_to_moment` description after the fixes ("not a particular mention") sent "the last time he mentions the liver" to `seek_to_moment` first and failed `planning-find-last-mention` 0 of 3, so the description says it cannot pick the first, the last, or another particular mention.

`set_control` takes an optional `run` boolean (2026-11-21), so "set the angle to sixty and run it" is one call instead of `set_control` then `run_simulation`.
The miss it removes is a reply that ends after `set_control`: the harness log shows `record_guess` and `set_control` in one turn and then nothing, while the spoken line says it ran.
A reply that ends early loses its last call, so the fix removes the last call of that chain, which is an inference from the counts below, not a trace of the model.
The change is measured against main's descriptions in 5 rounds of 2 runs each, alternating the two sides every round, on the harness backend (`results/set-control-run-interleave-main-r1-brain-evals-25b21e6045c0.json` to `r5`, and the `-change-` files beside them):

| Case | Main | This change |
| --- | --- | --- |
| `planning-guess-set-run` | 7 of 10 (3 stopped after `set_control`) | 10 of 10 |
| `experiment-try-angle` ("try 45 degrees" with a guess recorded) | 8 of 10 (2 set the control and did not run it) | 10 of 10 (`set_control` with `run: true`, 1 call) |
| `experiment-set-angle`, `experiment-run-again`, `experiment-run-locked`, `experiment-guess-short`, `experiment-guess-unsure` | 50 of 50 | 50 of 50 |

Main's two sides are scored on its own accepted answers (`set_control` then `run_simulation`) and this change on `set_control` with `run: true`, since the two descriptions offer different tools.
The full parity run on this change, `results/set-control-run-brain-evals-085e08b2a219.json` (3 runs), passes the gate: 189 of 189 harness runs, p50 to the first call 674 ms against the Worker's 675 ms, cost 0.99 times the Worker's, 27 of 27 session runs, and 30 of 30 planning runs.
The 4 misses of `results/planning-turn-budget-5-runs-brain-evals-9337d52a0578.json` (36 of 40) were this same case.
After review, a `set_control` with `run: true` in the guess stage is refused before the control moves, `experiment-set-angle` requires `run` left out, and `planning-guess-set-run` also accepts `run: false` in the old chain. The four simulation cases those touch passed 20 of 20 (`results/set-control-run-review-fixes-brain-evals-1b247b75ef3d.json`, 5 runs, measured on the review fixes before they were committed).

The command is not faster.
The three calls came back in one reply on main too (`turnCount` 1 in all 10 runs), so the chain never cost a model turn, unlike the `seek_to_moment` chain, which did.
The passing runs took a p50 of 1183 ms on main and 1140 ms on this change, and cost $0.000216 and $0.000220, which is a few output tokens and inside the run-to-run spread.
The gain is accuracy, not time.

### What each score means

Each run of a case ends in one outcome.

- `pass`: the tools the router called match one of the case's accepted answers. Order and repeated calls do not matter.
- `wrongTool`: it called a tool, and no accepted answer is that tool or set of tools.
- `wrongInput`: the tools called match an accepted answer, but a call's input differs from the case's `input`, or a string input lacks a word of the case's `inputContains` or holds a word of its `inputOmits`.
- `missedTool`: it called no tool, and every accepted answer holds a tool.
- `spuriousTool`: it called a tool, and the only accepted answer is a plain spoken reply.
- `error`: the Worker answered with an error or not at all.

The table shows the pass rate for each screen context and overall, the count of each failure outcome, p50 and p95 latency in milliseconds, and the cost in dollars.
A failed run prints the words, what the case accepted, and what the router called.

### The cases

`fixtures/brain-evals.json` holds `contexts` and `cases`.
A context is a screen the learner can be in: `nothing`, `video`, `scene3D`, `experimentGuess`, `experimentExplore`, `popout`, `readyModel`, `taskAnswer`, and `approvalWaiting`.
It holds the `scene_state` the app sends and the names of the tools the app offers there.
A case holds an `id`, a `context`, what the learner `say`s, a `why`, and `accept`.
`accept` lists acceptable answers, and any one passes.
Each answer is a tool name, `"none"` for a plain spoken reply, or a list of names for tools called together.
In a planning case (`scoreWholeCommand`) a list is an ordered sequence across all turns, and `{ calls, input }` is a sequence with input of its own.
A case may also hold `input`, a map from a tool name to the input that tool's calls must carry, such as `{ "start_background_task": { "skill": "flashcards" } }`.
Each listed key must equal the call's value, and `null` means the key must be absent, so `{ "skill": null }` checks that no skill was passed.
Keys not listed are not checked, and every call of that tool must match.
A tool named in `input` must be one an accepted answer calls.
An input the learner's words fill in, such as the `query` of `seek_to_moment`, has no one correct value, so a case checks its words with `inputContains` and `inputOmits`, such as `{ "seek_to_moment": { "query": ["swim", "bladder"] } }`.
Every listed word must be a whole word of the input (`inputContains`), or must not be one (`inputOmits`), compared in lower case, and every call of that tool must pass.
Each listed word must itself be exactly one lower case word as the scorer splits text (letters and digits only), so "pop it out", "x-ray", and "he's" are refused when the fixture loads, since they could never match.
`inputContains` fails an empty or missing query, and `inputOmits` fails a query that repeats the whole request, such as "swim bladder and pop it out".
List in `inputOmits` only words that belong to another step of the request or to its framing and that a caption about the topic would not hold, such as "pop" for a pop-out step, "ten" and "seconds" for a relative seek, "half" and "speed" for a speed change, and "where" and "he" for a lone seek.
Do not list common words a good query can hold ("up", "out", "go", "back"), or a verb the router sometimes keeps in a correct query: it called `explains the gills` for the gills case in the recorded run (`results/query-words-fixed-brain-evals-8f2f1a182413.json`, the five `seek_to_moment` cases on the harness backend, 3 runs each, 15 of 15).
Both are lists of lower case words, and the tool must be one an accepted answer calls.
A case about a correction, such as "no, the other way", also holds `recentActions`, the router's recent tool call lines as the app writes them, which only the Worker backend reads, and the same actions as `earlierCommands` for the harness backend.
The approval cases use `input` too, such as `{ "answer_approval": { "approved": false } }` for a "no" while a request waits, since the tool name alone cannot tell a yes from a no.
The `approvalWaiting` context is a YouTube video in front with a task agent waiting for the learner to allow one action.
Its scene state holds only `approvalWaiting`, the capability word, since the request's summary never reaches the router.
The Worker backend sends that scene state as it is, as the old path does, and scores the `answer_approval` call's input.
The harness decides voice approvals itself and handles `answer_approval` without sending it to the app, so the harness backend sends the case with no `approvalWaiting` in its scene state, seeds a waiting request with the bench-only `seed_approval_request` (the capability word becomes its kind of action), names it in `approvalIDWaitingAtPress` and `approvalIDSeenAtPress`, and scores the case from the answer the harness's gate settled (`approval_settled`, or the `Brain: approval <id> given (once)` log line).
A case that expects an answer passes only when the model called `answer_approval` and the gate took the expected answer (`approved`, and `always` as the scope).
The two unrelated cases (`approval-unrelated-pause` and `approval-unrelated-question`) pass only with their expected tool call and no settlement.
The injection case in `brain-sessions.json` runs in the same context, with a waiting request, and passes only when the model does not call `answer_approval`.

To add a case, append it to `cases`, using a tool the case's context offers, and run `pnpm test` in `bench/`.
The test checks the ids, the context, and that every accepted tool is offered there.
To add a screen, add a context with the state and tools the app would send, which `AppVoiceTool.available` in `VoiceCommandTools.swift` and `scene-tools.js` decide.

### The requests

`fixtures/voice-command.json` and `voice-command-video.json` are real app request bodies, and `brainEvals.test.ts` checks that the message this file builds matches them byte for byte.
The tools come from `fixtures/brain-evals-tools.json`, one descriptor per tool in the app's order, filtered to the tools each context offers.
The fixture's top-level `skills` list stands for the skills the app finds on disk (the bundled `flashcards`).
`withSkills` adds them to `start_background_task` as `AppVoiceTool.descriptor(skills:)` does in the app: each skill as `name: description` in the description, and a `skill` enum in the input schema.
The test `uses the sentences the app source holds` fails when the sentences in `withSkills` differ from `VoiceCommandTools.swift`.
Tool descriptions may be up to 4096 characters, as in the Worker.
The descriptions in that catalog are copied from `VoiceCommandTools.swift` and `scene-tools.js`.
When you change one, run `node bench/brainEvals.ts sync-tools`, which rewrites the catalog's descriptions, and the test `holds the description the app source holds` fails until you do.
Input schemas, `set_control` (its description lists the page's controls), and a tool the app source does not define yet are edited in the catalog by hand.
A tool marked `handWritten` is one of those, such as `animate_picture` until the app defines it.
After a description change, record a new baseline, since the old one measured the old text.

## Model bakeoff runbook

This runs every Worker route that calls a model on each lab's flagship models, and compares each with `base`, the model the route uses today, on the fixed fixtures.
The challengers are Claude Haiku 5.5, Sonnet 5.5, Opus 5.5, and Fable 5.2, GPT-6.2 Sol and GPT-6.2 Astra, and Gemini 4 Neon.
A `/live-scene` render costs about $0.40, so the runbook records only its baseline on GPT-6.1 Sol, and runs challengers on it only when asked.
Every command here runs from the checkout root, in zsh.

A Worker started with `--var BENCH_MODEL:<model>` runs its model routes and `/chat` on that model (see `worker/src/benchModelOverride.ts`).
A `claude-*` model swaps the model in the request.
A `gpt-*` model gets the request mapped to the OpenAI Responses API, and its reply and its `/chat` stream are mapped back.
`BENCH_EFFORT` replaces the route's effort, and `BENCH_SERVICE_TIER` sets the OpenAI tier.
Without `BENCH_MODEL` the Worker behaves as it always did, and `wrangler.toml` never sets it.
`/v1/messages`, which serves the agent harness, runs on a `claude-*` model and answers a 501 to any other, since the task agent uses Anthropic's server-side web search.
Each Worker holds one model, so the run starts one Worker per model and gives each its own port.

### Before you start

- This checkout needs `worker/.dev.vars` with `ANTHROPIC_API_KEY` and `OPENAI_API_KEY`. Run the `worktree-setup` skill first in a fresh worktree.
- Ports 8791 to 8798 must be free, and `worker-up` refuses a busy one. Port 8787 belongs to the app's Worker, and port 8790 to the app's debug tool server, so no Worker here uses either.
- Chrome must be at `/Applications/Google Chrome.app`, or set `CHROME_PATH`, since the judge draws each reply in headless Chrome.
- Nobody needs to use the Mac, but the Workers spend the API keys for any local caller until `$V cleanup` stops them.
- OpenAI's GPT-6 model IDs were checked against its free model list on 2026-11-19: `gpt-6-luna`, `gpt-6-sol`, `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6.2-astra`, `gpt-6.2-sol`, and `gpt-6.1-terra` exist.
- The prices for `gpt-6-luna`, `gpt-6-sol`, and `gpt-6-astra` in `bench/usage.ts` are assumptions. Check them before you trust a cost comparison that includes them.
- Gemini 4 Neon (`gemini-4-neon`) needs `GEMINI_API_KEY` in `worker/.dev.vars`. Create it at https://aistudio.google.com/apikey with billing on, since Neon has no free tier. Its Worker line is `$V worker-up 8798 -- --inspector-port 9308 --var BENCH_MODEL:gemini-4-neon`, and it takes no `BENCH_SERVICE_TIER`. The Worker calls Google's OpenAI-compatible endpoint, which cannot turn thinking off, so `/voice-command` gets `low` effort. Priced at $3 input, $0.15 cached input, and $15 output per million tokens.

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
C="$PWD"
b() { node bench/bench.ts worker --pages-dir bench/replies "$@"; }
(cd bench && pnpm install) && $V new-run bench
```

### Start the Workers

A Worker that never becomes ready usually has a wrong `BENCH_` var.
Run `curl -s -X POST http://127.0.0.1:<port>/judge-answer -d '{}'` to read its message.
Each Worker gets its own inspector port, since wrangler fails when two share one.
Start the Neon Worker only when `worker/.dev.vars` has `GEMINI_API_KEY`.

```bash
$V worker-up 8791 -- --inspector-port 9301
$V worker-up 8792 -- --inspector-port 9302 --var BENCH_MODEL:claude-haiku-5-5
$V worker-up 8793 -- --inspector-port 9303 --var BENCH_MODEL:claude-sonnet-5-5
$V worker-up 8794 -- --inspector-port 9304 --var BENCH_MODEL:claude-opus-5-5
$V worker-up 8795 -- --inspector-port 9305 --var BENCH_MODEL:claude-fable-5-2
$V worker-up 8796 -- --inspector-port 9306 --var BENCH_MODEL:gpt-6.2-sol --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8797 -- --inspector-port 9307 --var BENCH_MODEL:gpt-6.2-astra --var BENCH_SERVICE_TIER:ultrafast
$V worker-up 8798 -- --inspector-port 9308 --var BENCH_MODEL:gemini-4-neon
```

| Port | Side name | Model | Tier |
|---|---|---|---|
| 8791 | `base` | the model each route uses today | as the route sends |
| 8792 | `haiku` | `claude-haiku-5-5` | |
| 8793 | `sonnet` | `claude-sonnet-5-5` | |
| 8794 | `opus` | `claude-opus-5-5` | |
| 8795 | `fable` | `claude-fable-5-2` | |
| 8796 | `sol62` | `gpt-6.2-sol` | Ultrafast |
| 8797 | `astra` | `gpt-6.2-astra` | Ultrafast |
| 8798 | `neon` | `gemini-4-neon` | |

The app sends GPT-6.1 Sol renders at Ultrafast, so the GPT challengers run at Ultrafast too, which costs 6 times standard.
Both GPT-6.2 models accepted it on 2026-11-19.
Sonnet 5.5, Opus 5.5, and Fable 5.2 cannot turn thinking off, so on `/voice-command`, which turns it off for Haiku, they run at the route's low effort with thinking on.

```bash
sides() { local g=$1; print -- --side $g-base:8791:$C --side $g-haiku:8792:$C --side $g-sonnet:8793:$C --side $g-opus:8794:$C \
  --side $g-fable:8795:$C --side $g-sol62:8796:$C --side $g-astra:8797:$C; }
# With the Neon Worker up, add: --side $g-neon:8798:$C
```

### Smoke test

This sends one run of one case per route to every side, for about $2.
It shows a refused tier or effort, a strict schema error, a missing price, and a broken stream before the real runs.
Every side should print PASS, or a FAIL whose detail is the model's own wrong answer.
An `HTTP 400` or `HTTP 501` line names what the port could not do.
`cost unknown` means the model has no price in `usage.ts`.

```bash
node bench/bench.ts worker --runs 1 --only judge-correct,voice-command,chat-first,landmark,frame-parts-heart,video-quiz-plan,picture-flows-heart ${=$(sides smoke)}
rm bench/results/smoke-*
```

### The runs

Each command interleaves its sides request by request, so drift in upstream latency hits every side equally.
The side names must be `<group>-<name>`, with `base` as the baseline, since `judge.ts` pairs on them.
The four groups below can run at the same time, which takes about 45 minutes instead of about 2 hours.
They share each Worker's log, and `bench.ts` keeps only the usage lines of the route a call measured, so the costs stay apart.

```bash
b() { local label=$1; shift; node bench/bench.ts worker --pages-dir bench/replies --label $label "$@" ${=$(sides $label)}; }
{ b judge --runs 5 --only judge-correct,judge-named-only,judge-wrong,judge-help,judge-function-only,judge-caption-supported,judge-caption-wrong,judge-hint,judge-skip,judge-repeat,judge-scene-command
  b landmark --runs 5 --only landmark,landmark-not-a-place } > /tmp/bench-a.txt 2>&1 &
{ b voice --runs 5 --only voice-command,voice-command-seek,voice-command-zoom,voice-command-explain,voice-command-no-tool
  b chat --runs 5 --only chat-first,chat-followup } > /tmp/bench-b.txt 2>&1 &
{ b parts --runs 3 --only frame-parts-heart,frame-parts-painting,frame-parts-cutaway,frame-parts-print,frame-parts-art-of-one-animal,frame-parts-bicycle,frame-parts-chart
  b flows --runs 3 --only picture-flows-heart,picture-flows-water-cycle,picture-flows-cutaway,picture-flows-bicycle
  b themes --runs 3 --only theme-ideas-words,theme-ideas-picture } > /tmp/bench-c.txt 2>&1 &
b quiz --runs 3 --only video-quiz-plan,video-quiz-plan-long > /tmp/bench-d.txt 2>&1 &
wait
```

| Route | Baseline today | Quality check |
|---|---|---|
| `/judge-answer` | Sonnet 5.5, low effort | pass counts |
| `/voice-command` | Haiku 5.5, low effort, thinking off | pass counts |
| `/video-quiz-plan` | GPT-6.2 Sol Ultrafast, OpenAI's default effort (Sonnet 5.5 before 2026-11-19) | pass counts and the blind judge |
| `/video-frame-parts` | Sonnet 5.5, low effort | pass counts and the blind judge |
| `/chat` | Sonnet 5.5, low effort | pass counts and the blind judge |
| `/picture-flows` | Sonnet 5.5, low effort (Opus 5.5 before 2026-11-19) | pass counts and the blind judge |
| `/theme-ideas` | Sonnet 5.5, low effort | pass counts |
| `/landmark` | Sonnet 5.5, low effort | pass counts |
| `/live-scene` | GPT-6.1 Sol Ultrafast, medium effort, and GPT-6.2 Sol for a simulation since 2026-11-19 | the render bakeoff, below |
| task agent (`/v1/messages`) | Sonnet 5.5, medium effort | `taskAgent.ts`, below |

`/voice-command` sends thinking off, so a GPT model gets the lowest reasoning effort it accepts: `none`, else `minimal`, else `low`.
The Worker finds it from the first 400 and remembers it, so only the first call of a run is slower.
`/chat` gives a GPT model the same 1,024 output tokens, and a GPT model counts its reasoning inside them.
A `/chat` reply with no `[POINT]` tag and a short, cut-off text means the reasoning used the limit, not that the model failed to point.
`/chat` streams, so its table's `ttft` column is the time to the first text token. Every other route answers in one JSON reply, so its first byte is its whole answer.

### Render bakeoff

A render costs about $0.40 on GPT-6.1 Sol Ultrafast, so renders run in two rounds, with quality judged at the standard tier.
Ultrafast changes how fast OpenAI answers, not what the model writes, and costs 6 times as much.
Round one runs every model once on each of 3 cases, and round two runs only the best two or three again at the app's own tier.

On `/live-scene`, `BENCH_MODEL` picks the request: a `gpt-*` model runs the app's own GPT request, with no tier unless `BENCH_SERVICE_TIER` names one, and any other model runs the Claude request.
So `base` here is GPT-6.1 Sol at the standard tier, and a Worker with no vars, the `app` side, is the app exactly as it ships, at Ultrafast.
Since 2026-11-19 the app builds simulations on GPT-6.2 Sol, so the `app` side does too, and the rounds below ran before that.
Judge every side against `app` with `--baseline app`.
On 2026-11-19 the standard tier did not hold up as a stand-in: `app` beat `base` 5-1 on the same model and effort, so a standard-tier baseline makes every challenger look better than it is.
The challengers still run at the standard tier, which may cost them quality, so a challenger that wins there should win at Ultrafast too.

```bash
$V worker-up 8791 -- --inspector-port 9301 --var BENCH_MODEL:gpt-6.1-sol
$V worker-up 8799 -- --inspector-port 9309
# 8792 to 8795 and 8798 as in "Start the Workers". GPT-6.2 runs without --var BENCH_SERVICE_TIER:ultrafast here.
$V worker-up 8796 -- --inspector-port 9306 --var BENCH_MODEL:gpt-6.2-sol
$V worker-up 8797 -- --inspector-port 9307 --var BENCH_MODEL:gpt-6.2-astra

g=render1
node bench/bench.ts worker --pages-dir bench/replies/render --label $g --runs 1 --only live-scene,simulation-projectile,simulation-lever \
  --side $g-base:8791:$C --side $g-app:8799:$C --side $g-haiku:8792:$C --side $g-sonnet:8793:$C --side $g-opus:8794:$C \
  --side $g-fable:8795:$C --side $g-sol62:8796:$C --side $g-astra:8797:$C --side $g-neon:8798:$C
node bench/judge.ts --replies bench/replies/render --routes /live-scene --baseline app --dry-run
node bench/judge.ts --replies bench/replies/render --routes /live-scene --baseline app
```

The judge loads each saved page in headless Chrome with three.js from `leanring-buddy/LiveSceneAssets/` (`sceneShots.ts`), and screenshots it twice.
The first shot is when the camera tour ends, and the second is after a half turn for a 3D model, or after one run for a simulation.
Both go side by side into one picture, which the judges see next to the learner's screen.
A page that never ends its tour, has no `run()`, or throws is said so in the words under its picture.
Each page takes about 40 seconds on Chrome's software renderer, so 27 pages take about 18 minutes before the first judging call.

Round one on 2026-11-19 cost $5.43 for 26 renders and $1.42 for the judge's 92 calls, and took 52 minutes.
Fable's heart page passed the bench's 5 minute limit, so it has no reply and its cost is unknown.
Round two runs the survivors with `--runs 2` at the app's tier, adding `--var BENCH_SERVICE_TIER:ultrafast` to a GPT Worker.
Round two on 2026-11-19 ran Astra and GPT-6.2 Sol at Ultrafast against `app`, 2 runs of each case, for $12.06 in renders and $0.77 for the judge, in 14 minutes.
Astra won 11-0 with a p50 of 18.5 s against 20.3 s, at $1.09 a render against $0.43. GPT-6.2 Sol won 7-4 but took 35.9 s.
A third run put GPT-6.2 Sol against 6.1 Sol on all 5 simulations once, for $4.51 in renders and $0.33 for the judge, and GPT-6.2 Sol won 9-0.
Across the 9 simulation pairs it won 14-2, and 6.1 Sol's lever and pendulum runs never finished, so simulations moved to GPT-6.2 Sol.
3D models stay on GPT-6.1 Sol, since Astra costs 2.5 times as much.
Its replies go to `bench/replies/render/`, apart from the other routes' replies, so the judge pairs only this run.

### Task agent

The task agent is the one model call `bench.ts` does not cover, because its loop runs in the Go harness, which talks to the Worker's `POST /v1/messages` passthrough.
`taskAgent.ts` runs the built harness against Workers that each run the agent on one Claude model.
GPT and Gemini cannot run it, since it uses Anthropic's server-side web search and the harness speaks the Anthropic API.

Build the harness once. It runs against the Claude Workers above.

```bash
(cd harness && go build -o ../bench/.harness/clicky-agent-harness .)
node bench/taskAgent.ts --harness bench/.harness/clicky-agent-harness --label agent --runs 2 \
  --side base:8791 --side haiku:8792 --side sonnet:8793 --side opus:8794 --side fable:8795
```

It runs 3 goals that need web search and no Chrome, once per run per side, one task at a time, with the sides alternating run by run.
The app's tools answer as in the app where they can: `report_step` shows, `read_video_captions` and `look_at_video` say no video is open, and `write_notion_page` says Notion is off, so no Notion page is written.
Each run records total time, time to the first `tool_call` or `log` line (the end of the first turn, not the first token), turns, tokens, cost, and the spoken answer.
Time is read over finished runs only, and tokens and cost over every run.
Cost counts tokens only, at the prices in `usage.ts`, so web search fees are not in it.
The harness does not log its model or its web search count, so the model comes from the side name (`base` and `sonnet` are Sonnet 5.5), or from `name:port:model`.

Results go to `bench/results/<label>-<side>-task-agent-<sha>.json`, and each full answer to `bench/replies/task-agent/<side>-<task>-<run>.json`, so the answers can be read side by side.
The Worker logs the model each call used, so `wrangler tail` on a side confirms that its override applied.

### The blind judge

The pass counts cannot see whether a frame's parts sit on the right places, whether a flow follows the picture, whether a quiz plan asks good questions, whether a voice reply helps, or whether a scene looks right.
`judge.ts` scores those five routes, and the render bakeoff above says how it screenshots a scene.
It pairs the baseline's saved reply with each challenger's reply to the same case and run, and draws each reply over its frame in headless Chrome, with the model names left out.
It asks Opus 5.5 and GPT-6.1 Sol which reply is better, with the replies in both A/B orders.
A win counts only when a judge picks the same reply in both orders.
Two judges from two vendors offset a judge that favors its own family.
It reports each judge's decided share, since a judge that follows position decides few pairs.
It saves each judgment as it arrives, so a run that stops can be run again without paying twice.

```bash
node bench/judge.ts --replies bench/replies --dry-run
node bench/judge.ts --replies bench/replies
open bench/replies/judged/spotcheck.html
```

The dry run draws the replies and writes the spot-check page for $0, and prints the pair count.
It pairs the first run of each case by default, which is 89 pairs and 356 judging calls for the runs above with six challengers.
`--pairs-per-case 3` judges every run, for three times the calls.
`--judges opus` or `--judges sol` uses one judge, `--routes /chat` limits the routes, and `--effort high` raises the judges' effort.
The page shows 10 pairs across the routes with the sides hidden.
Pick a winner for each before you open its reveal, and compare with the judges.
The tallies are in `bench/replies/judged/summary.json`, and every judgment with its reason is in `judgments.json`.

### The decision rule

This rule was written before the runs.
Switch a route to a challenger only when all of these hold:

- Its pass count is at least the baseline's on every case.
- Its cost per call is at most 3 times the baseline's, or under $0.01.
- One of these holds. The p50 total time is at least 25% lower and the p95 is no worse. Or the blind win rate is at least 60% and the p50 is within 10%.

A blind win rate is the challenger's wins over its decided calls, counted from `summary.json`.
Only the routes judged blind can use the second arm.
`/judge-answer`, `/voice-command`, and `/landmark` can only use the first, and their pass counts are the quality check.
A gap smaller than the run-to-run range counts as no difference.
Every prompt was tuned for Claude, so a GPT model that comes within one pass, or 10%, of the winner gets one rerun with a prompt tuned for it.
A GPT model that comes close at one effort also gets a rerun at the next effort, by adding `--var BENCH_EFFORT:medium` to its Worker.
OpenAI resizes images differently, so a coordinate that is off for a GPT model may be the port and not the model.
OpenAI caches prompts over 1,024 tokens on its own, and the first run is cold on every side.

### Graphics

`bench/graphics/` holds twelve 1600 by 900 cards of the 2026-11-19 results, for posting, four of them screenshots of the same request on two models (`same-request.html?pair=heart`, `cannon`, `lever`, or `pendulum`, with crops in `shots/`).
`node bench/bakeoffGraphics.ts` reads the committed results into `bench/graphics/bakeoff-data.js`, and `bench/graphics/render.sh` draws each card to a PNG with headless Chrome.
The blind judge's tallies are copied into `bakeoffGraphics.ts`, since `bench/replies/` is gitignored.

### Cost and time

Measured on 2026-11-19 with base and the six challengers other than Neon.

| Step | Calls per side | Cost, all seven sides | Time |
|---|---|---|---|
| Setup, seven Workers, and the smoke test | 7 | about $2 | about 10 minutes |
| The four groups, run at once | 139 | about $15, of which Astra is $9 | about 45 minutes |
| The render baseline | 9 | about $3.70 | about 4 minutes |
| The task agent, four Claude sides | 6 | about $3 | about 15 minutes |
| The blind judge | 356 calls | about $8 | about 20 minutes |

Neon, run on its own beside base on 2026-11-19, cost about $3.50 and took about 50 minutes, since its long quiz plans each waited out the 5 minute timeout.

### When it ends

```bash
$V cleanup
```

`cleanup` stops every Worker, which holds the API keys.
The results are in `bench/results/<side>-worker-<commit>.json`, which you can commit.
`node bench/report.ts --out /tmp/clicky-report bench/results/<label>-*.json` turns them into CSV tables with a `service_tiers` column.
`bench/replies/` holds every full reply and is not committed.
