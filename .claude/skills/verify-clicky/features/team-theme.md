# Team theme

The learner picks Clicky blue, one of ten Haikyu!! schools, or Random in the menu bar panel's "Team theme" section.
A school recolors the cursor, swaps the menu bar icon for a volleyball, and turns every background agent that starts into one of that team's players, shown as a round portrait in a progress ring beside the cursor and as a themed row in the shift + option agent list.

## Sub-features

- `theme-picker` saves the pick under `companionTheme` in UserDefaults and applies it at once, with no relaunch.
- `theme-cursor` colors the cursor triangle, its glow, the spinner, the waveform, and the navigation bubble in the school's accent, outlined in its contrast color.
  Random and Clicky blue keep the blue cursor.
- `theme-icon` shows the volleyball menu bar icon under a school or Random, and the triangle under Clicky blue.
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
  The recipe makes no model call.
- The mouse on the main display, since the overlay draws on the screen under it.

- **Seeded agents.** Run `defaults write com.crodris.clicky-watch-along companionTheme school:karasuno`, then `$V app-launch "+600 thanks"`, which keeps the app idle for 10 minutes.
  Post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"debug_seed_agents","arguments":{}}}` to `http://127.0.0.1:8790/mcp`.
  It starts 3 running agents, then 1 finished with its ending chip and 1 failed, straight in the agent store with no Worker call.
  Run `$V shot themed-ended` within 4 seconds: a finished portrait with a green check ahead of the tip, the "Task done · say what did you find" chip with that portrait above and right of the cursor, a grayscale failed portrait with a red ring, two running portraits, and "+1".
  Run `$V shot themed-running` 5 seconds later: three running players in orange rings, the nearest with "Tsukishima · Searching the web".
- **Agent list.** Run `$V key agents-list`, then `$V shot themed-list`.
  The panel says "Karasuno" and "3 on court" with an orange border, the rows read "Hinata #10 · Study guide" and so on, and no player shows twice.
- **Other teams.** `$V app-quit`, write another value such as `school:inarizaki`, and repeat.
  Inarizaki's white accent is the hardest case for contrast.
- **Theme off.** Write `clickyBlue` and repeat.
  The wingmen are colored triangles and the list says "Agents" and "3 running".
- **Picker.** The panel's buttons have no accessibility names, so press one with the real mouse: `swift demo/scripts/mouse/mouse.swift click <x> <y>` at a button's center in global points, read from a `$V shot` of the open panel.
  `defaults read com.crodris.clicky-watch-along companionTheme` shows the new value, and the cursor and menu bar icon change at once.
- Delete the key with `defaults delete com.crodris.clicky-watch-along companionTheme` when done, so the everyday app stays Clicky blue.

## Gotchas

- The bundle ID is shared with the everyday Debug app, so the `companionTheme` key changes Chris's everyday Clicky too until it is deleted.
- Portraits are gitignored.
  A build from a checkout that never ran the script shows initials circles, which is the fallback working, not a bug.
- Seeded agents never end on their own.
  Cancel them from the agent list or quit the app.
- A seeded finished or failed wingman leaves 4 seconds after it ends, while its list row stays.
