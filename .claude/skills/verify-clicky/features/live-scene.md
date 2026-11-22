# Live scene

When the learner asks to see something ("show me the inside of a heart", "what does a cell look like", "render this in 3D"), Clicky builds a three.js scene from the question and a screenshot.
The scene rises out of the video or image it was asked about, a camera tour visits each labeled part while Clicky explains it, and the finished scene stays on screen until Escape or until the learner says "put it back".
Saying "quiz" or "test me" plays the same scene with one label hidden as "?", then asks what that part is and what it does.

## Sub-features

- `scene-explore` builds a scene and tours every labeled part.
- `scene-quiz` hides one label, asks about it after the tour, and grades the spoken answer.
- `scene-failure` says "Sorry, I couldn't build that one." on a timeout, an error, or a 422, and resumes a video it paused.
- `scene-tour-deadline` ends a tour that its page never ended 30 seconds after the page started, so the narration or the quiz question still comes.
- `scene-route` is the Worker's `/live-scene` route, which returns the page and the quiz.

## How to get to it (user POV)

- Hold ctrl+option and say a sentence with "inside", "look like", "show me", "3D", or "render".
- Hold ctrl+option and say "quiz me on this" or "test me" with one of those words.

## Driving it with verify-clicky.sh

Preconditions:

- For the app, run `$V worker-up 8787 -- --var LIVE_SCENE_MODEL:sonnet`.
  `$V doctor` then shows that Worker as started by this script, a Debug build that supports `--live-scene-rehearsal`, and no Clicky running.
- For the route alone, run `$V worker-up 8789 -- --var LIVE_SCENE_MODEL:sonnet`.

- **Explore in the app.** Ask to see inside a heart.
  Run `$V app-launch "show me the inside of a heart"`, then `$V app-wait`.
  The log shows `Live scene status spoken: Building your 3D scene`, then `Live scene rehearsal: finished, phase allLabelsShowing`.
  It has no `Live scene request failed`, `giving up on the page`, or `screen capture failed` line.
  The finished scene stays up until the app quits, so run `$V shot scene-up` after `app-wait` and before cleanup.
  The display under the mouse shows the labeled model over the video.
  On 2026-11-05 a Sonnet heart showed Aorta, Right atrium, Left atrium, Heart wall, Right ventricle, and Left ventricle, risen out of the YouTube video.
- **Quiz in the app.** Ask to be quizzed, then answer.
  Run `$V app-launch "quiz me on the inside of a heart|?I think that is the left ventricle, it pumps blood to the body"`.
  The log shows the first step finishing, then the `?` step saying the answer in phase `awaitingAnswer`.
  `app.usage.log` holds one `[/live-scene]` line and one `[/judge-answer]` line.
- **Route alone.** Build a body from a fresh screenshot, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && screencapture -x -t jpg "$RUN/scene.jpg" && python3 -c "import base64,json,sys;print(json.dumps({'question':'show me the inside of a heart','screenshotBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'screenshotMediaType':'image/jpeg'}))" "$RUN/scene.jpg" > "$RUN/scene-body.json"`, then `$V post /live-scene "$RUN/scene-body.json"`.
  The result is HTTP 200 with a page that imports `clicky-asset://three/three.module.js` and a quiz.
- **OpenAI fallback.** Start a Worker with a key OpenAI refuses, run `$V worker-up 8787 -- --var OPENAI_API_KEY:sk-invalid`, with no `LIVE_SCENE_MODEL`, then post the same body with `$V post /live-scene "$RUN/scene-body.json"`.
  A key in `worker/.dev.vars` may win over `--var`, so if the log shows no 401, point the Worker at a copy of `.dev.vars` that holds the bad key.
  The Worker log shows `OpenAI API error 401`, then `[/live-scene] gpt-6.1-sol could not answer (HTTP 401), so the scene falls back to claude-sonnet-5-5`, then a `[/live-scene] usage` line, and the reply is HTTP 200 with a page.
  The usage line has `"model":"claude-sonnet-5-5"`.
- **A tour that never ends.** A generated page can hang with no error and never post `tourFinished`, and Clicky then ends the tour itself after 30 seconds (`LiveSceneTourEnd`).
  The app calls port 8787 unless `app-launch --worker-port` names another, so the stub takes the app's port and a second Worker from this checkout answers behind it.
  Run `$V worker-up 8796` and `$V worker-up 8797`, then `$V app-launch --worker-port 8796 "+25 show me what a cell looks like"`.
  Within those 25 seconds, run `$V worker-down 8796`, then `node .claude/skills/verify-clicky/stuck-tour-scene-stub.mjs 8796 8797 > "$(ls -td .verify-clicky/runs/*/ | head -1)stub.log" &`.
  The stub answers `POST /live-scene` with a page that shows two labels and never ends its tour, and passes every other route through.
  Run `$V app-wait 120`.
  About 30 seconds after the stub's `answered POST /live-scene` line, the app log shows `Live scene: the page did not end its tour within 30 seconds, so Clicky ended it`, the narration is spoken, and the rehearsal finishes in phase `allLabelsShowing`.
  A rehearsal that never finishes, with nothing spoken after the stub's `passed POST /chat` line, means the deadline did not run.
  The Worker on 8796 is gone after the swap, so `app-wait` prints `usage lines: unavailable`, and the passed requests' usage lines are in `worker-8797.log`.
  Stop the stub with `pkill -f stuck-tour-scene-stub.mjs` after `$V cleanup`.
- **Cost ceiling.** One `[/live-scene]` usage line per request.
  Two lines mean the reply failed the page checks once and the route retried, and the report names the retry.
  A GPT line has `output_tokens` under 14000 and a Sonnet line under 64000, because each model stops at that cap (`max_output_tokens` and `claudeLiveSceneMaxTokens` in `worker/src/liveScene.ts`), and a reply at the cap is a cut-off page.
  Sonnet runs at low effort and showed 0 thinking tokens with 4145 and 4884 output tokens on 2026-11-05.

## Gotchas

- GPT scenes cost about $0.37 each at medium effort and Sonnet scenes about $0.04.
  Use Sonnet unless the change is to the GPT path.
- The scene appears on the display under the mouse pointer, so a screenshot of another display shows nothing.
- `app-wait` returns after the tour, so the tour itself is only visible in screenshots taken during it.
- "Almost there" is spoken only when the build takes longer than 10 seconds, so its absence is not a failure.
- With a YouTube video in Chrome's front tab, an explore request first asks `/landmark` whether the frame is a famous place.
  A `[/landmark]` usage line in an explore run is expected, not a retry.
  A quiz request skips that lookup.
- The rise animation reads the largest video or image in Chrome's front tab.
  With no Chrome window, the scene starts full screen, and that is expected.
- Drag orbit and pinch zoom cannot be driven.
  Report them as unverified when a change touches them.
- Escape on a finished scene is sent with `$V key escape`.
