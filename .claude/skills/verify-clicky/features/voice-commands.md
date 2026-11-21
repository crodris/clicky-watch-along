# Voice commands

A follow-up command spoken while a 3D scene is on screen or a video is in Chrome's front tab, on any site, changes what is already there, in about a second, instead of building a new scene.
`POST /voice-command` asks Haiku 5.5 which tools to call from the list the app sends: the page's tools from `scene-tools.js` and the app's video, quiz, and hand-off tools.
The app runs each call, shows a chip under the cursor in plain words such as "Turning it left" (or as code, `rotate_model(yawDegrees: -45)`, in a Debug build with the "Log tool call JSON" switch on), and then speaks the short confirmation the model wrote into the call.
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
- `voice-harness-brain` runs the same Haiku loop in the agent harness instead of `POST /voice-command` when `brainRunsInTheHarness` is on (`defaults write com.crodris.clicky-watch-along brainRunsInTheHarness -bool YES`, or `--brain-runs-in-the-harness` on a Debug build, which `app-launch --harness-brain` passes). It is off by default. The harness (`harness/brain.go`, `harness/brainloop.go`) sends each call as a `tool_call` with its `turnIndex`, and the app runs it through the same `runVoiceTool` code, chips, and action lines. The harness keeps no memory yet, so the app still sends the last 5 actions. A turn with no reply in 8 seconds fails the command with no retry, and 10 seconds with no harness event fails it on the app's side, and both take the router failure fallback.
- `voice-quiz-controls` lets the judge hear skip, repeat, a hint request, or a view command during a quiz question.
- `voice-chip` shows each call under the cursor in plain words for 1.4 seconds, with a fade only, and no chip for a hand-off (`pop_out`, `build_new_scene`, `answer_with_screen`, `show_ready_model`, `hear_task_answer`) whose own scene, speech, status line, or thinking dots follow.
- `voice-give-up` says "Sorry, I couldn't do that one." when the third turn still needs the model, and never the model's own text, which it writes before a tool call runs and can claim a success that failed.
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
- **Video tools through the endpoint.** With a YouTube video playing in Chrome's front tab, post `tools/call` for `pause_video`, `seek_relative` with `{"seconds":30}`, `set_speed` with `{"rate":1.5}`, `play_video`, and `find_moment` with `{"query":"crater"}` on the volcano video `https://www.youtube.com/watch?v=p1eE93vybrc`.
  Each result is `{"ok":true,...}`, the video's own state (read with `execute active tab of front window javascript`) matches, and `find_moment` returns caption lines with their seconds, such as 91.3 for the crater.
  These calls go through the 2 second Chrome timeout, and all five passed on 2026-11-16.
- **Debug MCP endpoint.** While the Debug app runs, post `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` to `http://127.0.0.1:8790/mcp` with `content-type: application/json`.
  The result lists the page tools of the scene on screen and the app tools that can work now, without `answer_with_screen`, `build_new_scene`, and `build_simulation`.
  Then post `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rotate_model","arguments":{"yawDegrees":-45}}}`.
  The result's text is `{"ok":true,"state":{...}}` with `yawDegrees` 45 lower than before, and the model turns on screen.
  The same request with an `Origin` header gets HTTP 403.
- **The brain in the harness.** On a YouTube video with one clear object, run `$V app-launch --brain --harness-brain "pop this out|turn it to the left|zoom in a bit|no, the other way"`, then `$V app-wait`.
  The app log shows one `Brain: turn N on claude-haiku-5-5 stopped for ..., N ms, calls <names>` line per turn, the same chips and spoken confirmations as the old path, and the Worker log has no `[/voice-command]` usage line.
- **The brain's evals on both backends.** With `$V worker-up 8797` ready, run `node bench/brainEvals.ts run --label harness-parity --backend both --runs 3 --port 8797`.
  It builds the harness, runs every case in `bench/fixtures/brain-evals.json` on the Worker's `/voice-command` and on the harness brain, one after the other, and prints a table for each backend and the parity gate.
  The gate passes when every harness run passes, its p50 to the first `tool_call` is within 100 ms of the Worker's, and its first-turn cost per call is within 1.5 times the Worker's.
  The command exits nonzero when the gate fails.
  The harness backend scores the first turn from the call names in its `Brain: turn` line, so a call the app never saw, after a hand-off or refused, still counts as the model's choice.
  The harness backend answers each call with the outcome the app gives that tool, so `find_moment` gets `lookedUp` with its scripted caption lines and takes a second turn, and the table's full-command line reports that turn's time and cost beside the first turn's.
  The result goes to `bench/results/<label>-brain-evals-<commit>.json`.
- **A press during a brain turn.** Run `$V app-launch --harness-brain "^skip to where they talk about the engine|pause it"`.
  The log shows `Live scene rehearsal: pressing push-to-talk during the voice command`, then `Brain: command cancelled during turn 1`, and no `Voice command:` line of the first command after the press.
  The press handler's audio stop is unchanged code that runs before any router code, so this step proves the cancel, not the audio stop.
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
