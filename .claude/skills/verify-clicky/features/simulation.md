# Let me try it simulation

When the learner ends what they say with "let me try it", "let me play with it", or "can I try it", or says "simulate this", an experiment agent builds a hands-on science experiment of what the screen shows, with sliders and a Run button drawn by `scene-tools.js`.
The video keeps playing while a lime-ringed token floats beside the notch, and the experiment rises out of the video when it is ready, like a 3D model (see [3D model agent](./three-d-model-agent.md)).
`/live-scene` takes `kind: "simulation"`, and the page adds `controls`, `setControl`, `run`, readouts, a hidden dashed path, faded past paths, and a challenge.
The lesson runs in four stages: Clicky asks a hypothesis and waits for a guess, the learner explores with the dashed path, Clicky says whether the guess was right and why once the trials answer it, and a challenge ends with a hit.

## Sub-features

- `simulation-route` is `/live-scene` with `kind: "simulation"`, which rejects a page with no `controls`, `setControl`, `run`, or `readouts`, or with its own input or button.
- `simulation-panel` is the panel `scene-tools.js` draws: sliders, Run (labeled "Say your guess" while locked), the hypothesis while Clicky waits for the guess, readouts, the challenge line, and the trials table.
- `simulation-guess` is `record_guess`, which the router picks for an answer to the hypothesis and which unlocks Run and the dashed path.
- `simulation-check` is the guess check through `/chat` after each explore run once the trials hold two settings, logged as `Simulation: guess check after run N, settled <bool>`. Before that it logs `Simulation: guess check skipped after run N, one setting tried`, and from run 3 the lesson moves on without the call.
- `simulation-challenge` starts once the guess is settled, hides the dashed path, and counts tries until a hit, which plays "Glass".
- `simulation-agent` is the background build, which logs `Experiment: built "<what>" in N s` and then `Experiment: showing "<what>", rising out of the video <bool>`, or `Experiment: the screen is busy, so it waits for "show the experiment"`.
- `simulation-voice` is `set_control` and `run_simulation` from the router, such as "make the angle 30 degrees" and "run it".
- `simulation-midrun-change` abandons a run when a slider drag or `set_control` changes a control while it plays, so its end adds no trial and Clicky says nothing about it. A change the page refuses leaves the run going.
- `simulation-challenge-declined` skips the challenge when no readout carries the challenge's `readoutLabel`, since that target could never be hit, and the lesson ends without one.
- `simulation-build-once` leaves `build_simulation` out of the router's tools while Clicky's own record says an experiment is on screen, so "let me try it" over one cannot start a second paid build.

## How to get to it (user POV)

- With a science video or picture in front, hold ctrl+option and say "let me try it".
  Clicky says "Sure, I'll build that while you watch." and the video keeps playing for about 30 to 40 seconds.
  When the experiment rises, answer the question out loud, drag a slider or say a setting, and press Run.

## Driving it with verify-clicky.sh

Preconditions:

- For the route, `$V worker-up` reported the Worker ready on port 8789.
  Use the default GPT model for anything a demo shows, since Sonnet pages look rough.
- For the app, a Worker this run started on 8787, a fresh `$V build`, and the experiment's picture showing on the display under the mouse.

- **Route.** Build a body from a bench frame, then post it.
  Run `RUN="$(readlink .verify-clicky/current)" && python3 -c "import base64,json,sys;print(json.dumps({'question':'let me try it','screenshotBase64':base64.b64encode(open(sys.argv[1],'rb').read()).decode(),'screenshotMediaType':'image/jpeg','kind':'simulation'}))" bench/fixtures/projectile-frame.jpg > "$RUN/sim-body.json"`, then `$V post /live-scene "$RUN/sim-body.json"`.
  The result is HTTP 200 with one usage line, and the page defines `controls`, `setControl`, `run`, `setPreviewVisible`, and `challenge`.
  The other bench frames are `lever-frame.jpg`, `pendulum-frame.jpg`, `dissolving-frame.jpg`, and `cooling-frame.jpg`.
- **Physics.** Load the page in a headless browser with `scene-tools.js` added at document start, call `clickyTools.simulation.guessHeard()`, then `set_control` and `run_simulation`, and compare the readouts with the topic's formula, such as v squared times sin 2 theta over g for the cannon.
  GPT pages matched within 1 percent on 2026-11-15.
- **App.** Run `$V app-launch "let me try it | &I think 60 degrees will go farther | make the angle 30 degrees | run it | +8 make the angle 60 degrees | run it"`.
  The "&" prefix makes the guess wait for the build, the rise, and the spoken question, since the experiment now builds in the background.
  The log shows `Experiment: built`, `Experiment: showing`, `Simulation: asked for the guess` before `Live scene rehearsal: saying "I think`, `Voice command: record_guess(...)`, `Simulation: guess recorded`, two `run_simulation()` calls, `Simulation: guess check skipped after run 1, one setting tried`, and `Simulation: guess check after run 2`.
  Run `$V shot simulation` once the log shows `Simulation: challenge started`.
- **Change during a run.** After the App recipe, with the experiment still up, post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_simulation","arguments":{}}}` to `http://127.0.0.1:8790/mcp`, wait 0.5 seconds, then post `set_control` with `{"name":"angle","value":45}`.
  After 8 seconds the log has no new `Simulation: saying "That run gave` line, and a third `run_simulation` adds one, such as 40.77 meters for 45 degrees at 20 m/s.
  Run `$V shot simulation-midrun` and check the trials table lists only the runs that finished.
  On 2026-11-16 the table held 3 trials (30, 60, and 45 degrees) after one abandoned run.
- **Cost ceiling.** One `[/live-scene]` usage line per page with GPT output under 10,000 tokens, and one streamed `/chat` request per guess check.

## Gotchas

- The experiment is built from the screen showing the video, or the display under the mouse when no video matches.
  Put the experiment's picture in Chrome's front tab and check the tab with AppleScript, because "front window" can be a different Chrome window, such as one a browser tool drives.
  An experiment rises only while the tab it was built from is in front, unless Chrome gave no tab URL when it started.
- A guess about something the experiment cannot test never settles, so the challenge starts after 3 runs.
- Chrome's Allow JavaScript from Apple Events must be on to pause a YouTube video for the scene, and the log says `javaScriptFromAppleEventsIsOff` when it is not.
- A headless harness that adds `scene-tools.js` twice draws two panels, and the first one goes stale.
  Use a fresh page for each load.
- A Debug build in a new checkout folder starts without the Accessibility grant, so Escape and push-to-talk do nothing.
  Close the scene with `close_scene` on the debug endpoint, or grant Accessibility in the panel first.
