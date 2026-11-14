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
- `voice-handoff` sends "show me a different model", "pop this out", and questions about the screen to the old path.
- `voice-quiz-controls` lets the judge hear skip, repeat, a hint request, or a view command during a quiz question.
- `voice-chip` shows each call under the cursor in plain words for 1.4 seconds, with a fade only, and no chip for a hand-off (`pop_out`, `build_new_scene`, `answer_with_screen`) whose own status line or spinner follows.
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
- **Debug MCP endpoint.** While the Debug app runs, post `{"jsonrpc":"2.0","id":1,"method":"tools/list"}` to `http://127.0.0.1:8790/mcp` with `content-type: application/json`.
  The result lists the page tools of the scene on screen and the app tools that can work now, without `answer_with_screen` and `build_new_scene`.
  Then post `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"rotate_model","arguments":{"yawDegrees":-45}}}`.
  The result's text is `{"ok":true,"state":{...}}` with `yawDegrees` 45 lower than before, and the model turns on screen.
  The same request with an `Origin` header gets HTTP 403.
- **Cost ceiling.** One `[/voice-command]` usage line per model turn, `claude-haiku-5-5`, `thinking_tokens` 0, and under 200 output tokens.
  After the first call within 5 minutes, `cache_read_input_tokens` is above 1000, because the tool list and the system prompt are cached.

## Gotchas

- The router runs only while a scene is on screen or a video is in Chrome's front tab, so a command with neither goes through the old screenshot path.
- A command during a scene still building goes to the old keyword path, which cancels the build for a plain question.
- The model writes a short line of text next to its tool call, which is never spoken, so do not treat it as the confirmation.
- Push-to-talk itself, the chip's look, and the debug switch in the panel cannot be driven by this skill, so report them as unverified unless Chris checks them by hand.
