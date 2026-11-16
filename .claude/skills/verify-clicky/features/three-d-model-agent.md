# 3D model agent

While a video plays in Chrome's front tab, the learner asks Clicky to build a 3D model, and a background agent builds it while the video keeps playing.
A violet wingman flies behind the blue cursor while `POST /live-scene` builds the page, next to any study guide agent's amber one.
When the model is ready and the screen is free, Clicky pauses the video, the model rises out of it, and Clicky says what it shows.
When something else is on screen, the model waits, and the chip says "3D model ready · say show the model".

The experiment agent behind "let me try it" (see [Let me try it simulation](./simulation.md)) runs the same code with a lime wingman, the steps "Grabbing the frame" and "Building the experiment", and the chip "Experiment ready · say show the experiment".
Its log lines start with `Experiment:` instead of `3D model:`.

## Sub-features

- `model-router-split` sends "build me a 3D model of this engine" to `build_model_in_background`, and "show me this in 3D" or a famous place to `build_new_scene`.
- `model-background` builds without pausing the video and without a status line, and logs `3D model: built "<what>" in N s`.
- `model-wingman` shows a violet outline wingman with the step line "Grabbing the frame" and then "Building the 3D model".
- `model-rises` pauses the video and lifts the model out of it when Clicky is idle, done speaking, and nothing is on screen, and logs `3D model: showing "<what>", rising out of the video true`.
- `model-waits` logs `3D model: the screen is busy, so the model waits for "show the model"` when a scene or pop-out is up, and `show_ready_model` then clears it and shows the model.
- `several-agents` runs guide and model agents at once, so the agent list says "2 running" or more, and a second `make_study_guide` on the same video fails with "This video's study guide is still being written".

## How to get to it (user POV)

- With a video in Chrome's front tab, hold ctrl+option and say "build me a 3D model of this engine".
- While it builds, say "make me a Notion study guide for this", then hold shift + option to see both agents.
- If the chip says "say show the model", say "show the model".

## Driving it with verify-clicky.sh

Preconditions:

- The app and Chrome preconditions in [Video quiz](./video-quiz.md) apply, with a YouTube video playing in the front tab.
- A Worker this run started on 8787 with `--var LIVE_SCENE_MODEL:sonnet`, and `worker/.dev.vars` with `NOTION_API_KEY` and `CLICKY_APP_SECRET` for the guide.

- **Router split.** Post `/voice-command` bodies whose `tools` hold the app's descriptions of `build_new_scene` and `build_model_in_background`, one per phrasing.
  The reply's `tool_use` name is `build_model_in_background` for build, make, or create, and `build_new_scene` for show, see, render, and a famous place.
- **Several agents.** Run `$V app-launch "play the video"`, then post `tools/call` for `make_study_guide` to `http://127.0.0.1:8790/mcp`, twice.
  The first returns `{"studyGuide":"started"}`, and the second fails with "This video's study guide is still being written".
  Post `tools/call` for `build_model_in_background` with `{"whatToBuild":"this jet engine"}`, then run `$V key agents-list` and `$V shot agents-two`.
  The screenshot shows an amber and a violet wingman behind the blue triangle and a "2 running" header.
- **Rise.** Leave the mouse on a display other than Chrome's and the screen alone until the app log shows `3D model: showing`, then run `$V shot model-risen`.
  The video is paused and the model rises on Chrome's display, not the mouse's.
- **Wait.** Press Escape to clear the model, post `build_model_in_background` again, then post `pop_out` at once.
  When the build ends the log shows `the model waits`, and `$V shot model-waiting` shows the chip with "say show the model".
  Post `show_ready_model`, and the pop-out goes back and the model rises.

## Gotchas

- A tool name may hold only lowercase letters and underscores, since the Worker's `/voice-command` check refuses digits, so `build_3d_...` gets a 400.
- The model rises only while the tab it was built from is in front, so switching tabs during the build makes it wait.
  An experiment rises over any tab when it was built with no tab URL.
- Each guide run creates a real Notion page, so trash the test pages afterwards.
