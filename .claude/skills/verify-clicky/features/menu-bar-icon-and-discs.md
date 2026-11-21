# Menu bar icon and agent discs

The menu bar icon mirrors what Clicky is doing, and each background agent's disc beside the notch shows how that agent is doing.
Hovering a disc shows a peek card, a right click opens a menu of the agent list's actions, and an ending agent's chip arrives at the cursor on a spark that runs from its disc.

## Sub-features

- `icon-states` shows the shown theme's cursor as a 26 point template image: idle, listening (two sound waves), and thinking (a small cursor and an orbiting dot).
  States crossfade in 150 ms.
- `icon-badge` puts an amber dot on the icon's top right while an approval waits, over any state, and takes it off when the request is answered.
- `icon-find` logs `Menu bar icon: frame ..., on screen ..., visible ...` a second after launch, and `$V menu-icon click` opens the panel through the app.
- `disc-dot` circles a running agent's ring with a bright dot every 3 seconds.
- `disc-approval` shows an amber "!" in place of the face, a notch in the ring, and a ring that pulses once every 1.6 seconds.
- `peek-card` shows a card 8 points under a hovered disc after 0.3 seconds: kind and subject, current step with elapsed time, and a meter. For a waiting approval it names only the capability.
- `disc-menu` pops Review request, Show model or experiment, Hear answer, Open page, and Cancel agent on a right click, as each applies, or Open agent list when none does.
- `bring-back` runs a spark from the ending agent's disc along the top edge and down to the cursor, with a tether in the agent's color, and the chip shows as it lands.
- `bring-back-no-disc` shows the chip at once when the agent has no disc on the mouse's display.

## How to get to it (user POV)

- Watch the menu bar icon while holding control and option (listening), and while Clicky works on a request (thinking).
- Start a background agent, then hover its disc, or right click it.
- Let an agent finish, and watch the cursor.

## Driving it with verify-clicky.sh

Preconditions:

- A Debug build of this checkout (`$V build`), a Worker this run started on 8787, and the app launched with `$V app-launch "+600 thanks"`.
- The Debug tool server is on (`app-launch` passes it), at `http://127.0.0.1:8790/mcp`.
- Seed with `debug_seed_agents`: `{"kinds":["task"],"waitingForApproval":true}` starts a running agent and puts it in the approval-waiting state, and `{"runningAgentCount":1}` also finishes one agent, which plays Bring back.
- `swift demo/scripts/mouse/mouse.swift move X Y 0.3` hovers at a point, and `rightclick X Y` right clicks it.

- **Find and click the icon.** `$V menu-icon status` prints the log line, and `$V menu-icon click` opens the panel. `$V shot panel` shows it.
  The status item may sit on a display other than the one you expect, and it may be absent from the window list beside the notch, so do not search for its window.
- **Icon states.** Record the built-in display's menu bar with `screencapture -x -V 5 -D 1 "$RUN/icon.mov" &`, run `$V key push-to-talk-tap` 1.5 seconds in (needs Accessibility), then crop the icon with `ffmpeg -ss T -i "$RUN/icon.mov" -frames:v 1 -vf "crop=70:60:X:2,scale=280:240:flags=neighbor"`.
  Listening shows two waves, and a half second later thinking shows the dot.
  A rehearsal step starting with `^` does the same through the pipeline.
- **Badge.** Post the waiting seed, then `$V shot badge`. The icon shows an amber dot at its top right.
- **Discs, peek, and menu.** Post three seeds with one kind each, hover the "!" disc, wait 1 second, and `$V shot peek`. `rightclick` on the disc shows the menu the same way, and `$V key escape` closes it.
  A disc's point in the mouse tool's coordinates is its screenshot pixel divided by the display's scale factor.
- **Bring back.** Move the mouse to the middle of the display, record with `screencapture -V 5 -D 1`, post the second seed, and tile frames with `ffmpeg -vf "fps=15,crop=...,tile=6x3"`.
  The log says `the spark runs from its disc to the cursor in 0.6 s`. A spark runs along the top, a thin line follows it, and the chip shows at the cursor.

## Gotchas

- A status item only draws its image, so the badge state is a colored image in white or black picked from the button's appearance. Report the badge's color on a light menu bar as checked only when a light bar was shot.
- Reduce Motion is a system setting this skill does not flip. The orbit's opacity form, the pulse's still halo, the Reduce Motion Bring back ring, and the peek's fade are unit tested, so report the real ones as unverified.
- The theme key is shared with the everyday Debug app, so the icon shows that theme's cursor. Write the theme back if a run sets one.
- `debug_seed_agents` finishes its seeded agent and Bring back waits 0.3 seconds so the dock has made the disc. A real agent has had its disc since it started.
- A display with a notch shows the discs to the notch's right, and a 1080p display shows them from its center, so both are worth one shot.
