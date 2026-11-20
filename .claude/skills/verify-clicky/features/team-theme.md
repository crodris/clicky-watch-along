# Team theme

The learner picks Clicky blue, one of ten Haikyu!! schools, or Random in the menu bar panel's "Team theme" section.
A school turns the cursor into a volleyball in the team's colors, and turns every background agent that starts into one of that team's players, shown as a round portrait in a progress ring beside the cursor and as a themed row in the shift + option agent list.

## Sub-features

- `theme-picker` saves the pick under `companionTheme` in UserDefaults and applies it at once, with no relaunch.
- `theme-cursor` draws the cursor as a volleyball in the school's colors, and colors its glow, the ring's ticks and dots, the loop, and the navigation bubble in the school's accent.
  Nekoma's ball is red with a black outline and white seams, and Inarizaki's is black with white lines.
  Three streaks in the team color trail the ball while it flies to a part and back, and while it follows a fast-moving mouse, turned toward the movement.
  Random and Clicky blue keep the blue triangle.
- `theme-icon` keeps the Clicky cursor menu bar icon under every theme.
- `theme-wingmen` shows each agent's player in a ring that fills clockwise in the school's color, the nearest one with "<name> · <step>", a finished one ahead of the tip with a green check, and a failed one in grayscale with a red ring.
- `theme-player-pick` gives each new agent the team's best-known player that the agent list does not already show, so one list never shows a player twice while the roster has others.
- `theme-chip` shows an ending agent's portrait as the chip's icon, and moves the chip above and to the right of the cursor while player wingmen trail under it, or below the whole trail at the screen's top edge.
- `theme-agent-list` titles each row "<name> #<jersey> · <kind>", heads the list with the school's name and "N on court", borders it in the school's color, and marks a failed row's portrait with a red border.
- `theme-off` keeps today's look under Clicky blue: colored triangles, the "Agents" header, and "N running".
- `theme-portraits` loads `HaikyuPortraits/<slug>.jpg` from the app bundle and draws the school's color with the player's initials when the file is missing.

## How to get to it (user POV)

- Click the menu bar icon, then a school, Random, or Clicky blue under "Team theme".
- Start any background agent by voice, such as "make me a study guide" while a YouTube video plays.
- Hold shift + option to open the agent list.

## Driving it with verify-clicky.sh

Preconditions:

- A Debug build that bundles the portraits.
  Run `python3 -I tools/fetch-haikyu-portraits.py` once per checkout, then `$V build`.
- A Worker this run started on 8787, which `app-launch` requires.
  The seeded-agent steps make no model call, and the Volleyball cursor step makes one pointing request (`/voice-command`, `/chat`, and `/tts`).
- The mouse on the main display, since the overlay draws on the screen under it.

- **Seeded agents.** Run `defaults write com.crodris.clicky-watch-along companionTheme school:karasuno`, then `$V app-launch "+600 thanks"`, which keeps the app idle for 10 minutes.
  Post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"debug_seed_agents","arguments":{}}}` to `http://127.0.0.1:8790/mcp`.
  It puts 3 running agents, 1 finished with its ending chip, and 1 failed straight in the agent store, with no Worker call.
  Run `$V shot themed-ended` within 4 seconds: a finished portrait with a green check ahead of the tip, the "Task done · say what did you find" chip with that portrait above and right of the cursor, Hinata and Kageyama leading, a grayscale failed portrait with a red ring in the third slot, and "+1".
  Run `$V shot themed-running` 5 seconds later: three running players in orange rings, the nearest with "Hinata · Reading the Haikyuu wiki".
- **Agent list.** Run `$V key agents-list`, then `$V shot themed-list`.
  The panel says "Karasuno" and "3 on court" with an orange border, the rows read "Hinata #10 · Task", "Kageyama #9 · 3D model", and so on, and no player shows twice.
- **Volleyball cursor.** With `school:karasuno` written, run `$V app-quit` and set `RUN="$(readlink .verify-clicky/current)"`.
  Put the mouse on the display where Chrome shows a YouTube video, run `screencapture -x -V 22 -D <that display> "$RUN/flight.mov"` in the background, then `$V app-launch "where is the YouTube search box? point at it"` and `$V app-wait 120`.
  The log shows `Element pointing`, and the frames from `ffmpeg -i "$RUN/flight.mov" -vf fps=20 "$RUN/flight-%03d.png"` show an orange ball with streaks trailing it on the way to the search box, then the ball and its bubble beside it.
  Claude points on the screen that shows the element, which may not be the main display.
  For the follow motion, run `$V app-quit`, launch with `+40 thanks`, record the mouse's display, and run `swift demo/scripts/mouse/mouse.swift move <x> <y> 0.5` across it: the ball turns toward the movement with streaks behind it, and they fade once the mouse stops.
- **Other teams.** `$V app-quit`, write another value such as `school:inarizaki`, and repeat.
  Inarizaki's white accent is the hardest case for contrast.
- **Theme off.** Write `clickyBlue` and repeat.
  The wingmen are colored triangles and the list says "Agents" and "3 running".
- **Picker.** The panel's buttons have no accessibility names, so press one with the real mouse: `swift demo/scripts/mouse/mouse.swift click <x> <y>` at a button's center in global points, read from a `$V shot` of the open panel.
  `defaults read com.crodris.clicky-watch-along companionTheme` shows the new value, the cursor changes at once, and the menu bar icon stays the Clicky cursor.
- Delete the key with `defaults delete com.crodris.clicky-watch-along companionTheme` when done, so the everyday app stays Clicky blue.

## Gotchas

- The bundle ID is shared with the everyday Debug app, so the `companionTheme` key changes Chris's everyday Clicky too until it is deleted.
- Portraits are gitignored.
  A build from a checkout that never ran the script shows initials circles, which is the fallback working, not a bug.
- Seeded agents never end on their own.
  Cancel them from the agent list or quit the app.
- A seeded finished or failed wingman leaves 4 seconds after it ends, while its list row stays.
