# Theme Studio

The learner says "change my theme" and a card opens next to the cursor with three theme ideas.
Each idea is a whole theme: a cursor drawn as SVG shapes, or the picture the learner pointed at, with its own motion, an accent and contrast color, agent token colors, and three sounds.
The learner picks or refines by voice or click, the real cursor previews the highlighted idea, and "save it" saves the theme under `~/Library/Application Support/Clicky/Themes/<id>/` and applies it.
"Make my theme from this picture" draws the loop around the largest picture in Chrome's front tab and builds the ideas from it.

## Sub-features

- `studio-route` is `POST /theme-ideas`: Sonnet 5.5 writes three ideas as schema-checked JSON, and the app parses each one again at its own boundary (`CustomTheme.parse`).
- `studio-open` opens the card from the keyword branch (`asksToDesignATheme`) or the `design_theme` tool, in the designing state with three shimmering placeholders and nothing spoken.
- `studio-preview` puts the highlighted idea on the real cursor, and on the ring, loop, bubble, chips, and agent list, through `CompanionThemeSettings.shownTheme`. Only the saved theme is in UserDefaults.
- `studio-pick` highlights an idea by number (`pick_theme_idea`) or by a tile click.
- `studio-refine` sends the ideas on the card and `basedOnIdea` back to the route (`design_theme`), dims the old ideas while it runs, and returns to them with "Sorry, I couldn't design that one." when it fails.
- `studio-picture` captures the largest picture in Chrome's front tab for "make my theme from this picture", draws the loop, and lets an idea use it as the cursor (whole or round, with an outline and a tint) or as the agent tokens' faces.
- `studio-save` writes `theme.json` and `picture.jpg`, sets `companionTheme` to `custom:<id>`, closes the card, stops the line Clicky is saying about the ideas, and plays the theme's done sound.
  The saved tile shows a check stamp, that idea's cursor flies from the tile into the real cursor on the carrier, and then the card closes into the cursor.
  A click on Save shows a chip above the cursor, "Theme saved", or "Couldn't save the theme" when the write fails, and the card stays open on a failure. The voice tool's chip comes from the router instead.
- `studio-close` closes the card and keeps the old theme, from `close_theme_studio`, the Close button, or Escape, and stops the line Clicky is saying about the ideas, or a line still waiting to be said.
  It stops only the studio's own line, so an answer Clicky is giving for a request the router handed off keeps playing.
- `studio-router` sends every word spoken with the card open to `/voice-command`, with no keyword branch ahead of it, so "two" or "save it" reaches the router even while a scene builds. Quiz phrases such as "can we stop" are the router's too, unless a quiz question is open.
  A failed router request says "Sorry, I couldn't do that one." and leaves the card as it was, instead of answering the words as a question about the screen.
- `studio-manage` renames or deletes a saved theme from its card in the menu bar panel (`ThemeCard`, `CompanionThemeSettings.renameSavedTheme` and `deleteSavedTheme`). A rename changes only the name in `theme.json` and keeps its modification date, and a delete removes the theme's folder. Escape in the rename field cancels only the rename, and leaves an open studio card or scene alone.
- `studio-agents` gives each new agent the first theme agent color no running agent or waiting result has, and the picture as its round face when the theme uses it.

## How to get to it (user POV)

- Hold ctrl+option and say "change my theme", "make me a new theme", or "make my theme from this picture" over a picture in Chrome's front tab.
- With the card open, say "two", "two, but make the cursor a star that spins while it thinks", "use this picture instead", "save it", or "never mind".
- Click a tile, Save, or Close on the card, or press Escape.
- Click a saved theme's card in the menu bar panel, on the home or under "All themes", to switch to it later.
- Hover or Tab to a saved theme's card for a pencil, which renames it, and a trash can, which deletes it after a second click, or right click the card for Rename and Delete.

## Driving it with verify-clicky.sh

Preconditions:

- A Worker this run started on 8787 with `POST /theme-ideas`, and a Debug build newer than the last commit under `leanring-buddy/`.
  The route costs one Sonnet 5.5 call for each design, and a picture request sends the picture too.
- The Debug app launched with `$V app-launch "+600 thanks"`, which keeps it idle and starts the tool endpoint at `http://127.0.0.1:8790/mcp`.
  Every tool call below is a `tools/call` post with `content-type: application/json`, such as `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"design_theme","arguments":{"request":"something cozy for night"}}}`.
- Back up the learner's theme first: `defaults read com.crodris.clicky-watch-along companionTheme`.
  The bundle ID is shared with the everyday app, so a saved theme changes Chris's everyday Clicky until it is reset.
- The mouse on the main display, since the card and the cursor draw on the screen under it.

- **Route.** Save `{"request":"something cozy for night"}` as `$RUN/words.json`, then run `$V post /theme-ideas "$RUN/words.json"`.
  The result is HTTP 200 with a `title`, a `spokenLine`, and 3 `ideas`.
  Each idea is a version 2 theme.json (`version` 2) with an `accent` that reads on `#101211`, a `cursor` with `kind` `shapes` (1 to 6 shapes) or `picture`, a `motion`, `agents` with a `ring` of `perAgent` (3 to 6 `colors` with no red or green) or `accent` (empty `colors`) and `faces.kind` `triangle` or `picture`, and three `sounds`.
  There is one `[/theme-ideas]` usage line, `claude-sonnet-5-5`, with 0 `thinking_tokens`.
  A body whose `picture` is a fresh screenshot of a page image, built in `$RUN` the way the frame pop-out recipe builds its body, returns ideas where at least one has a `picture` cursor or `agents.faces.kind` `picture`.
- **Open and preview.** Post `tools/call` for `design_theme` with `{"request":"something cozy for night"}`.
  The result is `{"ok":true}`, and the card shows "Designing your theme" with three placeholders under the mouse. Run `$V shot studio-designing` within 2 seconds.
  About 10 seconds later the card shows three named tiles with the first outlined in its accent, the tags, and "Say one, two, or three · or what to change · say save it", and the real cursor has the first idea's shape and color.
  Run `$V shot studio-ideas`, and zoom a crop of the card at 2x: text stays inside its tile, and no white corners show around a round token.
  The app log has `Theme studio: designed 3 ideas in N s`.
- **Motion.** Post `design_theme` with `{"request":"make it bouncy"}`, then read each idea's `motion.springs` in the Worker's response (`$V post /theme-ideas`) and the app log's `Theme motion:` line, which prints the springs of the idea on show when you pick it, and the card's tags, which say "bouncy motion": Pop damping 0.55 to 0.65 with a response near 0.3, Glide damping 0.75 to 0.85, and Point response near 0.4, all inside the limits (Pop response 0.2 to 0.45 and damping 0.55 to 1, Glide response 0.3 to 0.55 and damping 0.75 to 1, Point response 0.3 to 0.6).
  `{"request":"make it calmer"}` gives dampingFraction 1 and slower responses, and a request that says nothing about movement gives `springs` null.
  The Worker route is the source: `$V post /theme-ideas` with `{"request":"bouncy"}` returns ideas whose `motion.springs` is present and clamped.
  In the app, pick the bouncy idea and open the card's neighbors: the picked tile springs up with visible overshoot, the real cursor's Callouts pop with the idea's springs, and `DS.Move.themeSprings` is the idea's (the card's next Glide, such as the agent list from a disc, uses it).
  Save it and relaunch: the theme's `theme.json` keeps `motion.springs`.
- **Pick.** Post `pick_theme_idea` with `{"number":2}`.
  The result is `{"ok":true,"state":{"themeStudio":{"designing":false,"highlighted":2,...}}}`, the second tile is outlined, and the cursor changes to the second idea.
  `{"number":4}` returns `{"ok":false,...}` and changes nothing.
- **Refine.** Post `design_theme` with `{"request":"make the cursor a star that spins while it thinks","basedOnIdea":2}`.
  The old tiles dim while it runs, then three new tiles show, where the first is idea 2 changed as asked.
  The route's request, in the Worker log, has `currentIdeas` with 3 ideas and `basedOnIdea` 2.
- **From a picture.** With a page image in Chrome's front tab, post `design_theme` with `{"request":"make my theme from this picture","fromPicture":true}`.
  The loop draws around the picture while the ideas are designed, Clicky does not say it sees no picture, and at least one tile shows the picture as its token face.
  Then `{"request":"use this whole image as my cursor and tint it blue"}` leaves `fromPicture` out, which keeps the card's picture: the first tile's cursor is the picture at 32 points, with an outline and a blue tint.
- **Save.** Post `save_theme`.
  The result is `{"ok":true,"state":{"themeSaved":"<name>"}}`, the card closes, "Theme saved" shows as a chip, the done sound plays once, and `defaults read com.crodris.clicky-watch-along companionTheme` is `custom:<id>`.
  `~/Library/Application Support/Clicky/Themes/<id>/theme.json` holds the idea, with `picture.jpg` beside it when the theme uses the picture.
  Post `{"name":"debug_seed_agents","arguments":{"kinds":["task","task","task"]}}`: the three tokens beside the notch take the first three theme agent colors, and with a picture theme their faces are the picture. Run `$V shot studio-agents`.
  Relaunch the app: the theme is still applied, the menu bar panel's home shows its card first among the themes (the three newest saved themes come first), and "All themes" lists it after the built-in themes.
- **Save click.** Open the card again and click Save with the real mouse: read the button's point from a `$V shot`, then run `swift demo/scripts/mouse/mouse.swift click <x> <y>`.
  The card closes, a "Theme saved" chip shows above the cursor for about 1.4 seconds, and `companionTheme` is `custom:<id>`.
  Run `chmod a-w ~/Library/Application\ Support/Clicky/Themes`, open the card, and click Save again: the card stays open and the chip says "Couldn't save the theme".
  Put it back with `chmod u+w` on the same folder.
- **Rename and delete.** Start from a saved theme (the Save step) and the idle Debug app, then click the Clicky menu bar icon with the real mouse, reading the point from a `$V shot`, or post `debug_click_menu_bar_icon`.
  The saved theme shows as a card in the panel's theme grid, ahead of the built-in themes.
  The panel can open on either display, and `$V shot` captures whole displays, so take the panel alone by its window ID.
  List Clicky's windows with `swift -e 'import CoreGraphics; let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]; for window in windows where window["kCGWindowOwnerName"] as? String == "Clicky" { print(window["kCGWindowNumber"]!, window["kCGWindowBounds"]!) }'`, where the panel is the window about 396 points wide at the top of a display, then run `screencapture -x -o -l <id> "$RUN/<name>.png"`.
  Move the mouse over the card: a pencil and a trash can show at its top right corner, the pointer is the pointing hand over each, and each lights up under the pointer.
  Capture the panel as `card-hover` and zoom a crop at 2x: both buttons sit inside the card and the name stays inside it.
  Click the pencil: the name becomes a text field with the keyboard focus.
  Select all with `osascript -e 'tell application "System Events" to keystroke "a" using command down'`, type with `keystroke "Night Owl"` in the same way, then press Return with `key code 36`.
  The card shows the new name, `theme.json` has it, the folder keeps its name, and `companionTheme` is still `custom:<id>` when this was the theme in use.
  Open the field again and press Return on an empty field, then on a name of 25 characters: the field stays open, its border turns red, and the card says "1 to 24 characters".
  Press `$V key escape`: the field closes and the old name stays.
  Open it once more and click another theme in the panel: the field closes and that theme is picked.
  With the studio card open (say "change my theme" first, or launch with that step), open the panel through the dial's More token, click a card's pencil, and press `$V key escape`: the rename field closes and the studio card is still open with its ideas.
  Rename a saved card to the 24 character name "Moonlit Harbor Night Owl", then press Tab with `osascript -e 'tell application "System Events" to key code 48'` until that card shows its focus ring.
  Its full-name pill wraps inside the card and never reaches the next card or the panel's edge.
  Move the mouse over the card and click the trash can once: a red "Delete" button shows across the bottom of the card, and it goes away after 3 seconds with no second click.
  Capture the panel as `delete-armed` within those 3 seconds, to read the Delete button's point.
  Seed agents with `debug_seed_agents` before the delete: they keep their colors after it.
  Save a second theme first, so a card slides into the deleted one's place.
  Compile the mouse tool once with `swiftc -O demo/scripts/mouse/mouse.swift -o "$RUN/mouse"`, since the interpreter's start-up takes most of the 3 seconds.
  The mouse tool takes global points with a top-left origin, and a window capture is in pixels from the window's corner, so convert a point as `x = X + pixelX / scale` and `y = Y + pixelY / scale`, with `X` and `Y` from the window list's bounds and a scale of 2 on a Retina display.
  Hover the card, then run `"$RUN/mouse" click <trash x> <trash y>; sleep 0.5; "$RUN/mouse" click <Delete x> <Delete y>` as one command.
  The card goes, the theme's folder is gone from `~/Library/Application Support/Clicky/Themes/`, and when it was the theme in use, `companionTheme` is `bundled:clicky-blue` and the cursor is the blue triangle.
  Keep the pointer still and capture the panel as `after-delete`: only the card that slid under the pointer looks hovered, and the cards the delete moved elsewhere stay dim.
- **Close and Escape.** Open the card again, then post `close_theme_studio`, or run `$V key escape`.
  The card closes, the cursor goes back to the saved theme, and the saved `companionTheme` is unchanged.
- **Closing stops the studio's own line.** Open the card and, while Clicky is still saying the ideas' line (about 5 seconds after the tiles show), post `close_theme_studio`, or click Save.
  The audio stops at once, and the app log shows no later `ElevenLabs TTS: playing` for that line.
  Then launch with `$V app-launch "change my theme | +30 what is on my screen"`, post `close_theme_studio` while the screen answer plays, and hear it play to its end.
- **Router failure.** Launch with `$V app-launch "change my theme | +40 two"`, run `$V worker-down` once the three tiles show, and wait for the second step.
  Speech also goes through the Worker, so Clicky's system voice says "Sorry, I lost my voice for a second. Please try that again." in place of "Sorry, I couldn't do that one.". Check the state instead: the card stays open with the first idea highlighted, and the app log has `Voice command: the router failed, so its fallback takes it` with no screen answer for "two".
- **Failure.** Stop the Worker this run started, then post `design_theme`: the card closes, and the app log has `Theme studio: the design failed`. Speech also goes through the Worker, so the system voice says "Sorry, I lost my voice for a second. Please try that again." in place of "Sorry, I couldn't design that one."
  With ideas on the card, the same failure on a refinement brings the previous ideas back.
- Put the learner's theme back when done: `defaults write com.crodris.clicky-watch-along companionTheme <the value read first>`, or `defaults delete` it, and remove the test theme's folder from `~/Library/Application Support/Clicky/Themes/`.

## Gotchas

- The spoken phrases ("change my theme", "two, but make it a star") go through push-to-talk and speech recognition, which this skill cannot drive. The rehearsal flag feeds a sentence to the same pipeline, so `$V app-launch "change my theme"` opens the studio, but the router steps that follow need the Worker's `/voice-command`.
  Report a spoken refinement checked only through the tool endpoint as verified at the tool layer, not through speech.
- The card sits one level below the cursor overlay windows, so the previewed cursor draws over it. A cursor that looks cut off by the card is a window level bug.
- An idea that uses the picture cannot be saved without the picture's JPEG, and a saved folder without `picture.jpg` is skipped at load with a `Custom themes: skipped` log line.
- A hand-edited `theme.json` that breaks a rule (a path with an arc, an accent too dark to read) is skipped at load, not repaired.
- With Show Clicky off, the cursor overlay fades a second after the last interaction (transient cursor mode), so the preview shows on the card's tiles only until the next push-to-talk.
- Agents started while only a preview shows take the saved theme's colors, not the preview's.
- The menu bar panel's frame follows the card each time the card's size changes, a delete included. After a delete, check that no card is clipped and the panel's top stays under the menu bar.
- Escape in the rename field cancels only the rename: `closeLiveSceneOnEscape` returns while a text field in Clicky's own window is being edited. That check runs after the field editor takes the key, so the Escape-with-the-card-open step in the Rename and delete step above is what proves it.
- Seeded agents never end on their own. Cancel them from the agent list or quit the app.
