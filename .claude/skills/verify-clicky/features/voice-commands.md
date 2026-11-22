# Voice commands

A follow-up command spoken while a 3D scene is on screen or a video is in Chrome's front tab, on any site, changes what is already there, in about a second, instead of building a new scene.
`POST /voice-command` asks Haiku 5.5 which tools to call from the list the app sends: the page's tools from `scene-tools.js` and the app's video, quiz, and hand-off tools.
The app runs each call, shows a chip above the cursor in plain words such as "Turning it left" (or as code, `rotate_model(yawDegrees: -45)`, in a Debug build with the "Log tool call JSON" switch on), and then speaks the short confirmation the model wrote into the call.
A request that needs a new scene or a screenshot answer hands off to the old path.

## Sub-features

- `voice-route` is `/voice-command`, which returns `tool_use` blocks whose `input` carries a `confirmation`.
- `voice-correction` reads "no, the other way" against the last 5 tool calls and reverses the last turn.
- `voice-scene-tools` turns, zooms, focuses a part, resets, explodes, or cuts open the scene on screen.
  Explode and cutaway need a generated page that lists its `parts`.
- `voice-video-tools` pauses, plays, seeks, and changes the speed of the largest video on the front tab's page, on any site, and finds a moment in the captions of a YouTube video. A video in a frame from another site cannot be reached.
  A voice pause or play drops Clicky's own pause record on that tab.
- `voice-handoff` sends "show me a different model", "pop this out", "animate this" (`animate_picture`), and questions about the screen to the old path.
- `voice-brain-flag` makes the router take every first utterance, with nothing on screen and no video in front, when `brainTakesEveryRequest` is on (`defaults write com.crodris.clicky-watch-along brainTakesEveryRequest -bool YES`, or `--brain-takes-every-request` on a Debug build). It is off by default. The "animate this" and "let me try it" keyword branches are skipped, and a quiz answer, a scene still building, "stop the quiz", and "put it back" keep their own code.
- `voice-harness-brain` runs the same Haiku loop in the agent harness instead of `POST /voice-command` when `brainRunsInTheHarness` is on. It is on by default, and `defaults write com.crodris.clicky-watch-along brainRunsInTheHarness -bool NO` turns it off. A Debug build launched with `--brain-runs-in-the-harness`, which `app-launch --harness-brain` passes, turns it on whatever the saved setting says. An install with no `clickyAppSecret` at launch runs voice commands on the old path and logs `Brain: no app secret, so voice commands use the Worker router` once, since the harness calls `/v1/messages`, which needs the secret. The harness (`harness/brain.go`, `harness/brainloop.go`, `harness/brainsession.go`) sends each call as a `tool_call` with its `turnIndex`, and the app runs it through the same `runVoiceTool` code, chips, and action lines. The harness keeps a session in memory for the life of its process, so "undo the first turn" works past the last 5 actions and the app sends no action lines on this path. A command the learner interrupts is rolled back out of the session, and the calls that finished reach the next command in an `interrupted_before` tag. After 5 minutes with no request, or past 24 commands, old commands fold into one text block. A Haiku turn with no reply in 8 seconds fails the command with no retry, and 10 seconds with no harness event fails it on the app's side, and both take the router failure fallback. When the third Haiku turn still needs the model, the harness gives the command one Sonnet 5.5 turn (30 second timeout) before the gave-up line, writes `Brain: planning on claude-sonnet-5-5` first, and the app then waits 35 seconds instead of 10 for the next event.
- `voice-quiz-controls` lets the judge hear skip, repeat, a hint request, or a view command during a quiz question.
- `voice-chip` shows each call above the cursor in plain words for 1.4 seconds, and pops in and leaves with a fade and a 6 point rise, and no chip for a hand-off (`pop_out`, `build_new_scene`, `answer_with_screen`, `show_ready_model`, `hear_task_answer`) whose own scene, speech, status line, or thinking dots follow.
- `voice-give-up` says "Sorry, I couldn't do that one." when the last turn (the third, or on the harness brain the Sonnet turn after it) still needs the model, and never the model's own text, which it writes before a tool call runs and can claim a success that failed.
- `voice-chrome-timeout` gives every script Clicky runs in a Chrome tab a 2 second Apple Event timeout, and a frame grab 5 seconds, so a page that shows an `alert()` fails the call instead of freezing Clicky for about 2 minutes.
- `voice-page-tool-limits` keeps the first of a page tool name listed twice, cuts each page tool description to 1,000 characters, drops a page tool whose schema encodes to over 2,000 bytes, and shows no chip for a tool the turn did not offer.
- `voice-debug-log` prints the full JSON of each reply and tool result when the panel's "Log tool call JSON" switch is on (Debug builds).
- `voice-debug-mcp` serves the same tools at `http://127.0.0.1:8790/mcp` in Debug builds launched with `--voice-tool-debug-server`, which `app-launch` passes.

## How to get to it (user POV)

- After a pop-out, landmark, or generated scene is on screen, hold ctrl+option and say "turn it to the left", "zoom in on the wing", or "no, the other way".
- With a video on YouTube or another site in Chrome's front tab, say "go back ten seconds", "play it at 1.5 speed", or "skip to where they talk about the engine".
- During a quiz question, say "can I get a hint", "say that again", or "skip this one".

## Driving it with verify-clicky.sh

Preconditions:

- For the route, `$V worker-up` reported the Worker ready on port 8789.
- For the app, the app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, and the Debug build is newer than the last commit under `leanring-buddy/`.

- **Route.** Run `$V post /voice-command .claude/skills/verify-clicky/fixtures/voice-command.json`.
  The fixture is a frame pop-out whose last action was `rotate_model {"yawDegrees":45}`, and the learner says "no, turn it the other way".
  The result is HTTP 200 with one `tool_use` block named `rotate_model`, a negative `yawDegrees`, and a non-empty `input.confirmation`.
  The request takes about 1 to 1.7 seconds on a local Worker.
- **Scene tools in the app.** With a YouTube video showing one clear object, run `$V app-launch "pop this out|turn it to the left|zoom in a bit|no, the other way"`, then `$V app-wait`.
  For each command the log shows `Voice command: rotate_model(yawDegrees: ...) ran in N ms, M ms after the command, ok`, where N is a few milliseconds.
  Run `$V shot voice-turned` after the last step and check the model turned and the chip is gone.
- **Video tools in the app.** With a video playing in Chrome's front tab, on YouTube and again on another site such as a Wikimedia Commons video file, run `$V app-launch "go back ten seconds|pause it"`.
  The log shows `seek_relative(seconds: -10)` and `pause_video()`, and the video's time went back about 10 seconds.
- **Video tools through the endpoint.** With a YouTube video playing in Chrome's front tab, post `tools/call` for `pause_video`, `seek_relative` with `{"seconds":30}`, `set_speed` with `{"rate":1.5}`, `play_video`, `find_moment` with `{"query":"crater"}`, and `seek_to_moment` with `{"query":"crater"}` on the volcano video `https://www.youtube.com/watch?v=p1eE93vybrc`.
  Each result is `{"ok":true,...}`, the video's own state (read with `execute active tab of front window javascript`) matches, `find_moment` returns caption lines with their seconds, such as 91.3 for the crater, and `seek_to_moment` moves the video to the best line and returns `movedTo` with that line's seconds and caption text.
  These calls go through the 2 second Chrome timeout.
  The first five passed on 2026-11-16, and `seek_to_moment` passed on 2026-11-21: the debug endpoint moved the volcano video to 91.3 s with the caption "the visible opening is called crater".
  On the harness brain, "go back to where she explains the crater" called `seek_to_moment`, and "the magma chamber" took 306 ms with the captions cached.
- **One-reply seek and pop-out.** On the volcano video, run `$V app-launch --brain --harness-brain "go back to where she explains the crater and pop it out"`.
  The app log shows one `Brain: turn 1 ... calls seek_to_moment,pop_out` line, the video moved to the crater line, and the pop-out lifted that frame.
  A query no caption says, such as "go back to where she explains the gills and pop it out", fails the seek and sends the failure back to the model, and no pop-out starts.
- **Debug MCP endpoint.** While the Debug app runs, post `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` to `http://127.0.0.1:8790/mcp` with `content-type: application/json`.
  The result lists the page tools of the scene on screen and the app tools that can work now, without `answer_with_screen`, `build_new_scene`, and `build_simulation`.
  Then post `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rotate_model","arguments":{"yawDegrees":-45}}}`.
  The result's text is `{"ok":true,"state":{...}}` with `yawDegrees` 45 lower than before, and the model turns on screen.
  The same request with an `Origin` header gets HTTP 403.
- **The brain in the harness.** On a YouTube video with one clear object, run `$V app-launch --brain --harness-brain "pop this out|turn it to the left|zoom in a bit|no, the other way"`, then `$V app-wait`.
  The app log shows one `Brain: turn N on claude-haiku-5-5 stopped for ..., N ms, calls <names>` line per turn, the same chips and spoken confirmations as the old path, and the Worker log has no `[/voice-command]` usage line.
- **The brain keeps a session.** Run `$V app-launch --brain --harness-brain "pop this out|turn it to the left|turn it to the left|zoom in a bit|zoom in a bit|turn it up|reset the zoom|undo the first turn"`.
  The last step turns the model right, and the `Brain: turn` lines show `cache read` growing with the history from the second command on.
  The first command's request has no history, so its `cache read` covers only the tools and the system prompt.
  After a pause of 5 minutes the session folds the older commands into one block of at most the newest 40, so a cold request stays small however many commands came before.
- **The harness undoes the newest change.** Keep the Debug "Log tool call JSON" switch off, since with it on the chip shows code and not plain words.
  Run `$V app-launch --brain --harness-brain "pop this out|turn it to the left|undo that"`, then `$V app-wait`.
  The last step's app log has a `Brain: turn N ... calls undo_last_change` line, then `Voice command: rotate_model(yawDegrees: 45) ran in ... ms, ... ms after the command, ok`, which is the inverse the harness sent for the turn of -45 degrees, and the chip says "Turning it right".
  The inverse's call ID (the model's ID plus `-undo`) is in the app log only as the `id` field of a `Voice command JSON tool call from the harness` line, which `logVoiceCommandJSONIfEnabled` writes only with the switch on, so a switch-off run does not show it.
  For a video, run `$V app-launch --brain --harness-brain "go back ten seconds|undo that"`: the last step logs `Voice command: seek_relative(seconds: 10) ran ... ok` after its `calls undo_last_change` line.
  The harness offers `undo_last_change` only while the newest change has an inverse, so with a pop-out as the newest action, "undo that" is the model's own call to `close_scene`.
  A page call a press cut off keeps its inverse when the app's `cancel_task` names it as running and the page's tour has finished, and a cut-off video call, undo, call during the tour, or call the app never started does not (`aCutOffCallHasRun`).
  A page tool answers in a few milliseconds, so a rehearsal press cannot land inside one, and `cd harness && go test -run 'CutOff|StillRunning' ./...` and `node bench/brainEvals.ts run --label cut-off --backend harness --runs 10 --only session-undo-after-cut-off --port 8797` check it instead.
- **The brain's evals on both backends.** With `$V worker-up 8797` ready, run `node bench/brainEvals.ts run --label harness-parity --backend both --runs 3 --port 8797`.
  It builds the harness, runs every case in `bench/fixtures/brain-evals.json` on the Worker's `/voice-command` and on the harness brain, one after the other, and prints a table for each backend and the parity gate.
  The gate passes when every harness run passes, its p50 to the first `tool_call` is within 100 ms of the Worker's, and its first-turn cost per call is within 1.5 times the Worker's.
  The command exits nonzero when the gate fails.
  The harness backend sends `reset_session` before each case, since the harness keeps a session, and the cases that need earlier commands seed them with `seed_session`.
  The harness takes both only with `CLICKY_BENCH=1`, which the driver sets and the app never does.
  It also runs the cases in `bench/fixtures/brain-sessions.json` (an undo after 7 commands, a correction after a fold, a correction after an interrupted command, an injection in an earlier tool result, and an undo after a zoom, after a seek, and behind a pop-out), and the gate adds a check that every one passes.
  `node bench/brainEvals.ts session-run --label brain-session --runs 3 --port 8797` runs ten commands as one session and again with a reset before each, and prints the cache read share, p50, and cost of both.
  The harness backend scores the `approvalWaiting` cases (7 of the 60 parity cases) from the answer the harness's gate settled: it seeds a waiting request with `seed_approval_request`, names it in `approvalIDWaitingAtPress` and `approvalIDSeenAtPress`, and reads `approval_settled` or the `Brain: approval` log line, because `answer_approval` never reaches the app. The two unrelated cases pass only with their own tool call and no settlement.
  The harness backend scores the first turn from the call names in its `Brain: turn` line, so a call the app never saw, after a hand-off or refused, still counts as the model's choice.
  The harness backend answers each call with the outcome the app gives that tool, so `find_moment` gets `lookedUp` with its scripted caption lines and takes a second turn, and the table's full-command line reports that turn's time and cost beside the first turn's.
  The result goes to `bench/results/<label>-brain-evals-<commit>.json`.
- **The brain's Sonnet turn.** It runs only after 3 Haiku turns that each needed the model, which no ordinary command reaches, so a log with no `Brain: planning on` line is normal.
  When one does, the log shows `Brain: turn 3` on `claude-haiku-5-5`, then `Brain: planning on claude-sonnet-5-5`, then `Brain: turn 4 on claude-sonnet-5-5`, and Clicky speaks the Sonnet turn's own confirmation or the gave-up line.
  The Go tests in `harness/brainloop_test.go` drive this path against a fake Worker, since no real command reaches it on demand.
- **Timing marks and the read at release.** Chrome's front tab needs a YouTube video playing. Run `$V app-launch --harness-brain "pause it|play it|go back ten seconds|play it at one and a half speed|pause it|play it|skip ahead ten seconds|pause it"`, then `$V app-wait`.
  Each routed command ends with `Voice command timing: release_to_transcript_ms=… release_to_screen_state_ms=… transcript_to_request_ms=… request_to_first_call_ms=… first_call_to_first_line_ms=… release_to_first_line_ms=…`, and a `-` is a mark the command never reached.
  A rehearsal step waits 0.7 seconds between its simulated release and its transcript, so `release_to_transcript_ms` is about 730 there and is not a measure of real transcription.
  The loop's media read and the screen read share one read of Chrome's front tab per release (`Release read: read the front tab in N ms`, then `Release read: reused the front tab, ...`), which took `release_to_screen_state_ms` from a steady median of 539 ms to 258 ms on 2026-11-21. Chrome must stay the front app for the loop's read to run (a macOS notification can take it, and the loop then logs `read the front tab's media in 0 ms, none to frame`), and a `pop this out` step ends with `Cursor loop: drawing around the media in the front tab`.
  The screen read starts at the release, so `release_to_screen_state_ms` is about 260 and `transcript_to_request_ms` is under 15 (the first command of a launch about 90). On 2026-11-20 the same eight steps before the read at release gave a `transcript_to_request_ms` median of 326 and `release_to_first_line_ms` of 2188, and after it 8 and 1934.
  A command that asks for what the video's state already shows, such as `pause it` on an ended video, gets no tool call from the model and a `-` for the call marks, which is the model's answer and not a failure.
- **A press during a brain turn.** Run `$V app-launch --harness-brain "^skip to where they talk about the engine|pause it"`.
  The log shows `Live scene rehearsal: pressing push-to-talk during the voice command`, then `Brain: command cancelled during turn 1`, and no `Voice command:` line of the first command after the press.
  The press handler's audio stop is unchanged code that runs before any router code, so this step proves the cancel, not the audio stop.
- **Approvals by voice on the brain.** The harness decides the answer next to its approval gate, so the app sends `approvalIDWaitingAtPress` (the request the card showed at the press), `approvalIDSeenAtPress` (that request, only when its card had shown the whole summary for a second), and no `approvalWaiting`. A rehearsal step "no" declines the waiting request at once, read or not. Run `$V app-launch --brain --harness-brain` on a task that calls `open_url` (see `task-agent.md`), and when the card shows its whole summary for a second, say "yes" with a rehearsal step. The app log shows `Brain: approval <id> given (once)` from the harness, then `Agent harness: approval <id> given (once)` from the desk when `approval_settled` arrives, and the chip says "Allowed it". "Always allow it" gives `given (always)` and the chip "Allowed it for this task", and "no" gives `declined` and "Declined it". A rehearsal step "okay, what is this video about" while the card waits settles nothing: the harness refuses the yes, the card stays, and the question is answered as a question. A click that the harness's gate took first is the answer the desk shows, and a click on a card whose request a voice yes already settled changes nothing (the harness logs `dropped an approval answer`).
- **The app secret on the brain.** The harness calls `/v1/messages`, which needs the app secret. `$V doctor` reports a missing or refused secret (`app secret: MISSING`, `REFUSED`) without printing it. Launch once with `$V app-launch --harness-brain --no-app-secret "turn it to the left"` on a 3D scene: the log says `Brain: no app secret, so voice commands use the Worker router` once, the command turns the model through `/voice-command`, and the Worker log has a `[/voice-command]` usage line and no `/v1/messages` one for it. Launch again with `--wrong-app-secret`: the harness's first turn gets a 401 from the Worker's secret check, the log shows `Brain: the Worker refused the app secret, so this command goes to the Worker router once`, the same command still turns the model through `/voice-command`, and the next command goes there too, with no harness turn line. Both options pass the app's `--app-secret-mode none|wrong` launch argument, so they work on the first try and never write or delete the defaults the everyday Clicky shares, and the next launch with neither copies the real secret again.
- **A failed brain.** Stop the Worker mid-run, and check that the next command takes the keyword path within 8 seconds of its `voice_command` line (`Voice command: the router failed, so its fallback takes it`).
- **A hung brain.** The app always calls port 8787, so the stub takes that port and a second Worker from this checkout answers behind it.
  Run `$V worker-up 8787` and `$V worker-up 8788`, then `$V app-launch --harness-brain "+40 what is this"` on any page.
  Within those 40 seconds, run `$V worker-down 8787`, then `node .claude/skills/verify-clicky/hung-messages-stub.mjs 8787 8788 > "$(ls -td .verify-clicky/runs/*/ | head -1)stub.log" &`.
  The stub holds `POST /v1/messages` open and never answers, and passes every other route through, streams included.
  Its log has one `held POST /v1/messages` line, written when the harness sends the brain's first turn right after it reads the `voice_command` line, and then one `passed POST /chat` line from the keyword path.
  The gap between their millisecond times is about 8 seconds, the brain's turn timeout, and under 10.
  The app log shows `Voice command: the router failed, so its fallback takes it` once, and Clicky answers the question by voice.
  Stop the stub with `kill %1` and the second Worker with `$V worker-down 8788`.
  `worker-down` takes a port here because without one it stops every Worker this script started, the one on 8788 included.
- **Cost ceiling.** One `[/voice-command]` usage line per model turn, `claude-haiku-5-5`, `thinking_tokens` 0, and under 200 output tokens.
  After the first call within 5 minutes, `cache_read_input_tokens` is above 1000, because the tool list and the system prompt are cached.

## Gotchas

- The router runs only while a scene is on screen or a video is in Chrome's front tab, so a command with neither goes through the old screenshot path. With `brainTakesEveryRequest` on, the router runs for those too.
  Check it on the Worker with the fixtures: with only `answer_with_screen`, `build_new_scene`, `build_simulation`, `pop_out`, `animate_picture`, and `start_background_task` offered and `{"page":"none"}` as the scene state, "what is this" picks `answer_with_screen`, "let me try it" `build_simulation`, "animate this" `animate_picture`, and "pop this out" `pop_out`.
- A command during a scene still building goes to the old keyword path, which cancels the build for a plain question.
- The model writes a short line of text next to its tool call, which is never spoken, so do not treat it as the confirmation.
- Push-to-talk itself, the chip's look, and the debug switch in the panel cannot be driven by this skill, so report them as unverified unless Chris checks them by hand.
