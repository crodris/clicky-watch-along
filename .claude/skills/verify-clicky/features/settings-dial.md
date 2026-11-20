# Settings dial

Holding shift + option for 0.3 seconds opens a round dial under the mouse, so settings no longer need the menu bar panel.
Moving the pointer previews a slice, releasing the keys commits the highlighted item, and releasing in the center or pressing Escape cancels.
Team and Model fan their choices on an outer arc, Agents opens the agent list, Show toggles Show Clicky, and More opens the menu bar panel.

## Sub-features

- `dial-open` opens after a shift + option hold of 0.3 s, centered on the mouse, with five tokens (Team, Model, Agents, Show, More) around the cursor glyph.
  A key, a left, right, or middle mouse press, control, or command during the hold breaks it, and so does a mouse button already down from a drag.
- `dial-hint` shows "hold ⇧⌥ · flick, release to pick" under the dial the first time it opens (`settingsDialHintWasShown` in UserDefaults), and never again.
- `dial-preview` fills the token at the pointer's angle with the team's color and draws its icon in the team's ink color, while the pointer is inside the plate.
- `dial-team-fan` opens Clicky blue, the ten schools, and Random on an arc over the top when the pointer is on Team, with the item under the pointer larger and named.
- `dial-fan-travel` keeps a fan open while the pointer travels outward past the plate, even across another slice's angle, and changes the slice only when the pointer comes back inside the plate.
- `dial-commit` applies the highlighted item on release: a Team item sets the theme, a Model item sets the voice model, Agents opens the agent list at the mouse, Show toggles Show Clicky, and More opens the menu bar panel.
- `dial-cancel` commits nothing when the keys are released in the center, on Team or Model with no item highlighted, or far past the fan, and when Escape or another key is pressed.
  It also closes an open dial when the event tap stops or macOS cuts it off.
  A main thread stalled past the tap's timeout can cause that, and the learner then holds the keys again.
  This skill cannot drive that path, so it is unverified on the real app.
- `dial-edge` shifts the dial and its fans inward near a screen edge, so nothing is cut off, and picks nothing until the pointer has moved 10 points.
- `dial-passthrough` lets every click reach the app under the dial, and never takes the keyboard.

## How to get to it (user POV)

- Hold shift + option for a moment, flick toward a token, and let go.
- Hold, flick to Team, flick out to a ball, and let go to change the team.
- Hold, flick to Agents, and let go to open the agent list.

## Driving it with verify-clicky.sh

Preconditions:

- Accessibility granted to this build (`Clicky start` logs `accessibility: true`, which may take a few seconds after launch), since the event tap needs it.
- A Worker this run started on 8787, which `app-launch` requires. The dial makes no model call.
- A Debug build that bundles the portraits for the themed agent list: run `python3 -I tools/fetch-haikyu-portraits.py` once per checkout, then `$V build`.
- Nobody else moving the mouse. Read the mouse with `swift demo/scripts/mouse/mouse.swift where` right after the keys go down, since the dial centers on the mouse where it was at 0.3 s.

Steps:

- **Open.** Run `defaults delete com.crodris.clicky-watch-along settingsDialHintWasShown`, then `$V app-launch "+600 thanks"`, which keeps the app idle for 10 minutes.
  Move the mouse well inside the main display, such as `swift demo/scripts/mouse/mouse.swift move 700 450 0.3`, run `$V key dial-hold`, wait 0.8 s, and run `$V shot dial-open`.
  The screenshot shows a dark round plate under the mouse with Team at the top, Model and Agents on the right, Show and More on the left, the cursor glyph in the center, and the hint under the plate.
  Run `$V key dial-release` to cancel, since the pointer never left the center.
- **Team fan and commit.** Hold, then move the pointer from the dial's center straight up 78 points onto Team, out to 135 points, and along the arc to a ball.
  Run `$V shot dial-fan`: the Team token is filled with the team's color, the ball under the pointer is larger with its school's name above it, and the plate stays.
  Run `$V key dial-release`, then `defaults read com.crodris.clicky-watch-along companionTheme`, which now names that school, such as `school:nekoma`.
  Write the original value back when done, since the key is shared with the everyday app.
- **Agents.** Post `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"debug_seed_agents","arguments":{}}}` to `http://127.0.0.1:8790/mcp`, then run `$V key agents-list` and `$V shot dial-agents-list`.
  The agent list opens at the mouse with the seeded agents, and stays until `$V key escape` or a click outside.
- **Escape.** Run `$V key dial-hold`, wait 0.8 s, run `$V key escape`, then `$V shot dial-escaped`.
  The dial is gone, and `$V key dial-release` after it commits nothing.
- **Reduce Motion.** Turn on System Settings > Accessibility > Display > Reduce motion and repeat Open: the dial and fan appear with no scale or stagger.

## Gotchas

- Each rebuild can drop Clicky's Accessibility grant, and then the dial never opens, since the event tap needs it.
  Check that the app log says `accessibility: true` before the first `$V key dial-hold`.
- The mouse must sit at least 250 points from every screen edge, or the dial shifts inward and the Agents token is no longer 46 points right and 63 down of where the mouse was.
- The first-run hint shows once per Mac, so run `defaults delete com.crodris.clicky-watch-along settingsDialHintWasShown` before a run that photographs it.
- A Team or Model commit writes `companionTheme` or `selectedClaudeModel`, and Show writes `isClickyCursorEnabled`, in the defaults the everyday Debug app shares.
  Write the original values back when the run ends, and delete `selectedClaudeModel`, `isClickyCursorEnabled`, and `settingsDialHintWasShown`, which did not exist before.
- `$V key dial-hold` leaves shift and option down until `$V key dial-release`, so release them even when a step in between fails.
- Shift + option + a key is how some apps type special characters, so pressing any key while the dial is open cancels it, as Escape does.
