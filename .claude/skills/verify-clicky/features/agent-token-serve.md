# Agent token serve

When a tool starts a background agent, that agent's own token leaves the blue cursor and arcs into its slot beside the notch in half a second.
The slot shows as a dashed outline until the token lands.
The router's spoken confirmation, and the "Sure, I'll build that while you watch." line of the direct "let me try it" path, start after the landing.
With no slot for the agent, or no room for discs on the mouse's display, nothing flies and the line plays at once.

## Sub-features

- `serve-fly` flies the token from the cursor glyph (35 points right and 25 below the mouse) to the next open slot along a curved arc, in 0.5 seconds, on the shared carrier panel, under Clicky blue and under a team theme.
- `serve-tether` draws a 1 point line in the cursor's color from the cursor glyph to the flying token, which fades out within 0.25 seconds of the landing, and no carrier window (level 1002) stays on screen afterward.
  The disc looks the same in flight and in the dock, and the cursor stays with the mouse.
- `serve-open-slot` shows a dashed outline at the slot from the start of the flight, and the token replaces it on landing.
- `serve-confirmation-waits` plays the spoken line after the landing.
  The log says `Agent token serve: the spoken line waited N ms for the token to land`.
- `serve-no-slot` flies nothing when the new agent goes to the "+N" disc, and the line plays at once.
  The log says `no serve, the agent has no slot on the display the mouse is on`.
- `serve-no-room` does the same when the mouse's display has no free space, a hidden menu bar, or a full-screen space.
- `serve-reduce-motion` fades the token in at its slot, with the line at once, when Reduce Motion is on.
- `serve-cursor-display` flies the token to the dock on the display the mouse is on, and the other displays' discs fade in as usual.
- `serve-push-to-talk` lands the token in its slot at once when push-to-talk is pressed during the flight, and the press cancels the line that was waiting.
  The log says `the token lands at once`.
- `serve-next-agent` lands a token still in flight at once when another agent's serve starts.
- `serve-quiz-refresh` gives a study guide refresh after a quiz miss no serve, since the learner asked for nothing.

## How to get to it (user POV)

- Say "let me try it" while no experiment is building, and the experiment agent's token flies to the notch before Clicky says "Sure, I'll build that while you watch."
- Ask the router for a background task, a 3D model, or a study guide with a video in Chrome's front tab, and the agent's token flies before the router's confirmation.

## Driving it with verify-clicky.sh

Preconditions:

- A Debug build of this checkout (`$V build`) and a Worker this run started on 8787 (`$V worker-up 8787 -- --var LIVE_SCENE_MODEL:sonnet`).
- The mouse on a display whose menu bar shows with free space beside the notch.
  `$V shot` numbers displays in its own order, so look at each picture to see which display it is.
- Push-to-talk needs the Accessibility grant, which every new Debug build loses.
  The seeded and rehearsal recipes below need none.

- **Flight with no model call.** Run `$V app-launch "+600 thanks"`, then `swift demo/scripts/mouse/mouse.swift move 700 520 0.2`.
  Start `screencapture -x -V 6 -D 1 "$RUN/serve.mov" &` (`-D 1` is the main display), wait 2 seconds, then post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"debug_seed_agents","arguments":{"kinds":["task"],"serveTheToken":true}}}` to `http://127.0.0.1:8790/mcp`.
  The log shows `the token flies to its slot in 0.5 s` and, half a second later, `the token landed in its slot`.
  `ffmpeg -ss 1.5 -t 1.5 -i "$RUN/serve.mov" -vf "fps=30,crop=1000:1240:1200:0,scale=300:-1,tile=9x3" -frames:v 1 "$RUN/sheet.png"` shows a dashed circle beside the notch, then the token moving from the cursor up to it along an arc with a thin line in the cursor's color behind it, then the token in its place and the line gone.
  Seed one kind per call, since a serve in flight lands at once when the next starts.
- **Confirmation after landing.** Put the mouse on the main display, then run `$V app-launch "+8 let me try it"`, and record as above 2 seconds after launch.
  The log shows `flies`, `landed`, then `the spoken line waited 230 to 270 ms for the token to land` (the build's Chrome reads use the rest of the half second), then `ElevenLabs TTS: playing streamed audio`.
  Under Clicky blue the token is lime for the experiment agent.
- **"+N" (no serve).** Run `$V app-launch "+15 let me try it"`, and 3 seconds in post `debug_seed_agents` with `{"kinds":["task","threeDModel","studyGuide"]}` and no `serveTheToken`.
  The log shows `no serve, the agent has no slot on the display the mouse is on`, no `waited` line, and the TTS line follows at once.
  `$V shot plus-n` shows three tokens and a "+1" disc.
- **Another serve starts mid-flight.** Post `debug_seed_agents` with `serveTheToken` for one kind, wait 0.2 seconds, and post it for another.
  The log shows `the token lands at once` before the second serve.
- **Push-to-talk press.** With Accessibility granted, post one seeded serve and run `$V key push-to-talk-tap` about 0.05 seconds after it, for example `( sleep 0.05; $V key push-to-talk-tap ) &` before the `curl`.
  The log shows `the token lands at once`.
  The tap holds the keys for 0.3 seconds with no words, so it asks nothing.
- **Real spoken request.** With Accessibility granted, output not muted, and the mouse on the main display, hold control and option through System Events, run `say -r 170 "let me try it"` while they are held, then release.
  The log shows `Companion received transcript: Let me try` (the last word may be cut), `flies`, `landed`, `waited`.
- **Cursor display.** Move the mouse onto each display in turn (`swift demo/scripts/mouse/mouse.swift move 2600 400 0.2` for a display to the right of the main one) and record that display with `screencapture -x -V 6 -D 2`.
  The token flies on that display's strip, which starts at the display's center when it has no notch.
- **Team theme.** Run `defaults write com.crodris.clicky-watch-along companionTheme school:karasuno` before the launch.
  The flying token is the player's portrait in a ring in the team's color.

## Gotchas

- Reduce Motion is a system setting this skill does not flip.
  `agentTokenServePlan` is unit tested for it, so report the real fade-in as unverified.
- A full-screen space on the mouse's display hides every app window beside the notch, so no disc shows and nothing flies.
- The theme key is shared with the everyday Debug app.
  Write back the value it had before the run.
- Every new Debug build loses the Accessibility grant, so a push-to-talk recipe needs Chris to grant it to that build first.
  The log's `accessibility: true` line says when it holds.
- `say` reaches the microphone only through the speakers, so a muted or headphone output gives `No speech detected`.
- The flight is a Core Animation keyframe animation.
  A move on the main thread, such as the build's Apple Event reads, would have frozen a timer-driven token, so a frozen-then-jumping token in a recording is a regression.
- `$V build` reports "up to date" when the dylib is newer than every Swift file, so check the dylib's time after an edit.
