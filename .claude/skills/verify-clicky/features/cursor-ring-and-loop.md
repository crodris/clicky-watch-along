# Cursor ring and loop

Clicky's voice states share a ring around the cursor: ticks that follow the voice while the learner talks, and three orbiting dots while Clicky thinks.
When a request becomes a look at the video or image in Chrome's front tab, a hand-drawn loop goes around that media, and a spark draws it and keeps lapping until the answer, a scene, or a clear event ends it.
A turn that only runs tools, such as "turn it left", never draws a loop.

## Sub-features

- `ring-listening` shows 24 ticks around the cursor while push-to-talk is held, with lengths that follow the microphone.
- `ring-thinking` shows three dots orbiting the cursor once every 1.2 seconds while a request runs and no loop shows.
- `loop-draws` draws the loop around the front tab's video when the router hands off to `answer_with_screen`, `build_new_scene`, or `pop_out`, or the keyword path starts a scene or pop-out.
- `loop-clears` fades the loop on idle, a new press, a scroll, a front tab or media rect change, an app switch, the answer's speech, or a scene starting to show.
- `loop-popout` fades the loop when a pop-out lifts, so the pop-out rises from the line.

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

## Gotchas

- Chrome must be the front app, or the media rect read returns nothing and no loop draws.
- A video that fills the whole screen gets no loop, so shoot with Chrome in a normal window.
- The loop polls the front tab once a second, so a tab left in the background still clears it within that second.
- Take screenshots with `$V shot`, and look at every display before one goes into a pull request.
