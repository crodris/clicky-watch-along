# Cursor ring and loop

Clicky's voice states share a ring around the cursor: ticks that follow the voice while the learner talks, and three orbiting dots while Clicky thinks.
When a request becomes a look at the video or image in Chrome's front tab, a hand-drawn loop goes around that media, and a spark draws it and keeps lapping until the answer, a scene, or a clear event ends it.
A turn that only runs tools, such as "turn it left", never draws a loop.
A background agent that works on the video in front laps its own spark around the same line, in its token's color, and speeds up as its progress grows.

## Sub-features

- `ring-listening` shows 24 ticks around the cursor while push-to-talk is held, with lengths that follow the microphone.
- `ring-thinking` shows three dots orbiting the cursor once every 1.2 seconds while a request runs and no loop shows.
- `loop-draws` draws the loop around the front tab's video when the router hands off to `answer_with_screen`, `build_new_scene`, or `pop_out`, or the keyword path starts a scene or pop-out.
- `loop-clears` fades the loop on idle, a new press, a scroll, a front tab or media rect change, an app switch, the answer's speech, or a scene starting to show.
- `loop-popout` fades the loop when a pop-out lifts, so the pop-out rises from the line.
- `loop-agent-spark` laps one spark for each agent working on the video in front, in the agent's color, over a quiet track when no request loop shows.
  The log says `Cursor loop: agent sparks lap the media in the front tab`.
- `loop-agent-pace` laps a spark in 4 seconds at no progress and 1.2 seconds at full progress.
- `loop-agent-finish` completes the lap a finished agent's spark is on, then fades the line with its last agent. A failed or cancelled agent's spark goes at once.
- `loop-agent-clears` keeps the agent line through a push-to-talk press and the answer's speech, and clears it on a scroll, a tab or media change, an app switch, or a scene starting to show.
- `loop-agent-reduce-motion` draws a still arc for each agent, as long as its progress, with no spark. Only tests and renders cover it, since this skill never flips Reduce Motion.

## How to get to it (user POV)

- Hold ctrl+option and talk, then release, with a YouTube video in Chrome's front tab and ask "what is this?" or "pop this out".
- Ask for a tool-only change such as "pause the video" and see that no loop appears.

## Driving it with verify-clicky.sh

Preconditions:

- The app preconditions in [Video quiz](./video-quiz.md) apply, and the verify lock in the redesign notes is held while a parallel run shares the Mac.
- Chrome is the front app, and its front tab plays a YouTube video that is not a face or a heart, such as a machine, a volcano, or a landmark.
- The rehearsal presses and releases push-to-talk before each step, so the media rect read starts as it does for a spoken request.

- **Draw and clear on an answer.** Run `$V app-launch "what is this?"`, then `$V shot loop-answer` while the thinking dots would show.
  The log shows `Media rect:` lines from the read, and `Cursor loop: ended because speechStarted` when the answer's speech starts.
- **Pop-out rise.** Run `$V app-launch "pop this out"`.
  The loop shows while the status label "Popping it out" shows, and `Cursor loop: ended because aSceneStartedToShow` appears when the lift starts.
- **No loop for a tool-only turn.** Run `$V app-launch "pause the video"`.
  No `Cursor loop:` line appears and no loop shows in a screenshot.
- **Clear on a tab change.** Start `$V app-launch "what is this?"`, and switch Chrome's tab while the answer is thinking.
  The log shows `Cursor loop: ended because tabOrMediaChanged` within about a second.

- **Agent sparks.** Open a YouTube video that is not a face or a heart in a normal Chrome window, make Chrome the front app, and run `$V app-launch --harness-brain "let me try it|build me a 3D model of this|& thanks"`.
  Each step presses and releases push-to-talk first, so the release read puts the media in hand, and each agent started by that step joins the line.
  Record the video's display with `screencapture -x -V 60 -D 1 "$RUN/sparks.mov"` and tile frames with `ffmpeg`: two sparks, one lime and one violet, lap a faint accent track around the video, and the log shows `Cursor loop: agent sparks lap the media in the front tab` once.
  When an agent finishes, its spark finishes its lap and the line fades, and `Cursor loop: ended because aSceneStartedToShow` follows when the scene rises.
  The debug endpoint's `debug_seed_agents` joins no line, since a seeded agent has no source tab and the endpoint makes no press.
- **No line without media.** Run `$V app-launch --harness-brain "build me a 3D model of this"` with Chrome not the front app. No `agent sparks lap` line appears.

## Gotchas

- Chrome must be the front app, or the media rect read returns nothing and no loop or agent line draws.
- The front tab poll runs for as long as an agent line shows, so a long task agent keeps two Apple Events a second going.
- A video that fills the whole screen gets no loop, so shoot with Chrome in a normal window.
- The loop polls the front tab once a second, so a tab left in the background still clears it within that second.
- Take screenshots with `$V shot`, and look at every display before one goes into a pull request.
  For a burst, `screencapture -x -D 2 <file>` captures one chosen display, and a plain `screencapture -x <file>` captures only the main display.
  The loop draws on the display that holds the video, and the ring and status label draw on the display under the mouse, so put the mouse on the video's display to see all three together.
- Another session's automation can bring a different app to the front, which clears the loop as an app switch. The log says `Cursor loop: the front app became <bundle id>`.
- `verify-clicky.sh app-launch` finds a running Clicky with `pgrep -f`, so any shell command whose text contains the app's path makes it refuse to launch.
