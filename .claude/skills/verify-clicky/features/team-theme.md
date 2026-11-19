# Team theme

The learner picks Clicky blue, one of ten Haikyu!! schools, or Random in the menu bar panel's "Team theme" section.
A school turns the cursor into a volleyball in the team's colors, and turns every background agent that starts into one of that team's players, shown as a round portrait in a progress ring in a token beside the notch and as a themed row in the shift + option agent list.

## Sub-features

- `theme-picker` saves the pick under `companionTheme` in UserDefaults and applies it at once, with no relaunch.
- `theme-cursor` draws the cursor as a volleyball in the school's colors, and colors its glow, the spinner, the waveform, and the navigation bubble in the school's accent.
  Nekoma's ball is red with a black outline and white seams, and Inarizaki's is black with white lines.
  Three streaks in the team color trail the ball while it flies to a part and back, and while it follows a fast-moving mouse, turned toward the movement.
  Random and Clicky blue keep the blue triangle.
- `theme-icon` keeps the Clicky cursor menu bar icon under every theme.
- `theme-tokens` shows each agent's player as a 22 point disc right of the notch, in a ring that fills clockwise in the school's color, with a green check on a finished one and a grayscale face in a red ring on a failed one. No words float beside it. Inarizaki's ring is the light `#F4F4F5`.
- `theme-player-pick` gives each new agent the team's best-known player that the agent list does not already show, so one list never shows a player twice while the roster has others.
- `theme-chip` shows an ending agent's portrait as the chip's icon, in the plain spot under the cursor.
- `theme-agent-list` titles each row "<name> #<jersey> · <kind>", heads the list with the school's name and "N on court", borders it in the school's color, and marks a failed row's portrait with a red border.
- `theme-off` keeps today's look under Clicky blue: tokens ringed in each agent's own color around a triangle in that color, the "Agents" header, and "N running".
- `theme-agent-colors` gives each agent its own color under Clicky blue when it starts, so three task agents are teal, amber, and violet, not three teal tokens. The color shows on its ring, its triangle, its ending chip, and its list row, and the agent keeps it for its whole life.
- `theme-portraits` loads `HaikyuPortraits/<slug>.jpg` from the app bundle and draws the school's color with the player's initials when the file is missing.

## How to get to it (user POV)

- Click the menu bar icon, then a school, Random, or Clicky blue under "Team theme".
- Start any background agent by voice, such as "make me a study guide" while a YouTube video plays.
- Click an agent's token beside the notch, or the "+N" disc, to open the agent list under it, or hold shift + option to open the list next to the mouse.

## Driving it with verify-clicky.sh

Preconditions:

- A Debug build that bundles the portraits.
  Run `python3 -I tools/fetch-haikyu-portraits.py` once per checkout, then `$V build`.
- A Worker this run started on 8787, which `app-launch` requires.
  The seeded-agent steps make no model call, and the Volleyball cursor step makes one pointing request (`/voice-command`, `/chat`, and `/tts`).
- The mouse on the main display, since the overlay draws on the screen under it.

- **Seeded agents.** Run `defaults write com.crodris.clicky-watch-along companionTheme school:karasuno`, then `$V app-launch "+600 thanks"`, which keeps the app idle for 10 minutes.
  Post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"debug_seed_agents","arguments":{"runningAgentCount":1}}}` to `http://127.0.0.1:8790/mcp`.
  It puts 1 running agent, 1 finished with its ending chip, and 1 failed straight in the agent store, with no Worker call. `runningAgentCount` is 3 by default.
  Run `$V shot themed-ended` within 4 seconds: Hinata's running token, a finished portrait with a green check, and a grayscale failed portrait in a red ring, all right of the notch, and the "Task done · say what did you find" chip with that portrait under the cursor.
  Run `$V shot themed-running` 5 seconds later: the failed token is gone, the other two keep their positions, and the running one's ring has filled a little.
  Post the call again with `runningAgentCount` 3 for three tokens and a "+N" disc.
- **Agent list.** Click a token with `swift demo/scripts/mouse/mouse.swift click <x> <y>` to open the list under it with that row expanded, and click "+N" to open it with none. Or run `$V key agents-list`, then `$V shot themed-list`.
  The panel says "Karasuno" and "3 on court" with an orange border, the rows read "Hinata #10 · Task", "Kageyama #9 · 3D model", and so on, and no player shows twice.
- **Volleyball cursor.** With `school:karasuno` written, run `$V app-quit` and set `RUN="$(readlink .verify-clicky/current)"`.
  Put the mouse on the display where Chrome shows a YouTube video, run `screencapture -x -V 22 -D <that display> "$RUN/flight.mov"` in the background, then `$V app-launch "where is the YouTube search box? point at it"` and `$V app-wait 120`.
  The log shows `Element pointing`, and the frames from `ffmpeg -i "$RUN/flight.mov" -vf fps=20 "$RUN/flight-%03d.png"` show an orange ball with streaks trailing it on the way to the search box, then the ball and its bubble beside it.
  Claude points on the screen that shows the element, which may not be the main display.
  For the follow motion, run `$V app-quit`, launch with `+40 thanks`, record the mouse's display, and run `swift demo/scripts/mouse/mouse.swift move <x> <y> 0.5` across it: the ball turns toward the movement with streaks behind it, and they fade once the mouse stops.
- **Other teams.** `$V app-quit`, write another value such as `school:inarizaki`, and repeat.
  Inarizaki's white accent is the hardest case for contrast.
- **Agent colors.** Under `clickyBlue`, post `debug_seed_agents` with `{"kinds":["task","task","task"]}`: three tokens right of the notch ringed in teal, amber, and violet, with a triangle in the same color on each face. Add `{"kinds":["threeDModel"]}` for a fourth token in lime, since violet is taken.
- **Theme off.** Write `clickyBlue` and repeat.
  The tokens are ringed in each agent kind's color around a triangle, and the list says "Agents" and "3 running".
- **Picker.** The panel's buttons have no accessibility names, so press one with the real mouse: `swift demo/scripts/mouse/mouse.swift click <x> <y>` at a button's center in global points, read from a `$V shot` of the open panel.
  `defaults read com.crodris.clicky-watch-along companionTheme` shows the new value, the cursor changes at once, and the menu bar icon stays the Clicky cursor.
- Delete the key with `defaults delete com.crodris.clicky-watch-along companionTheme` when done, so the everyday app stays Clicky blue.

## Gotchas

- The bundle ID is shared with the everyday Debug app, so the `companionTheme` key changes Chris's everyday Clicky too until it is deleted.
- Portraits are gitignored.
  A build from a checkout that never ran the script shows initials circles, which is the fallback working, not a bug.
- Seeded agents never end on their own.
  Cancel them from the agent list or quit the app.
- A seeded failed token leaves 4 seconds after it ends, while its list row stays. A seeded finished task answer keeps its token until it is heard or 10 minutes pass.
