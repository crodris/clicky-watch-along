# Tether redesign: build plan and status

Tether is the redesign of every Clicky surface that Chris approved on 2026-11-21.
Every surface opens out of its origin, a 1 point tether line shows while it moves, and it returns there.
This file is the shared brief for every agent that builds a part of it, and the status table at the end is kept current as PRs merge.

## Sources

- The design spec is the approved artifact, kept in git: `git show prototype/tether-phase-zero:prototype/tether/tether-spec.html > /tmp/tether-spec.html`, then read the section for your PR.
- The phase-zero prototype results are in the same local branch: `git show prototype/tether-phase-zero:prototype/tether/<materials|carrier|approval|replay>/README.md`.
  Read the "Findings" and "Changes to the spec" sections for your PR; they override the spec where they differ.
- The branch `prototype/tether-phase-zero` exists only in this Mac's repository, so a fresh clone does not have it.

## Decisions Chris made

- Speech, status lines, and chips use the dark Callout: a solid `#14171e` pill with an accent rim, an accent icon disc, and a tail.
  The prototype showed that a background blur fails contrast on light pages, so the Callout is solid.
- Icons on the accent disc use near-black ink on every accent, Clicky blue included.
- Instant replay of a narrated pop-out is built.
- Every theme, the built-in ones included, becomes a `.clickytheme` file, and Random becomes a Shuffle switch that keeps the cursor.
- Scene labels move from cream paper to dark glass.
- The cursor stretches in flight and gains a nod, a shake, and a hop.
- A No on an approval counts at once, by click or by voice, while Yes and Always keep the seen-whole rule and the 1 second clock.
- The sound kit comes after the visuals.
- Clicky is desktop only, the redesign reads only theme fields (no Haikyu names in the UI), and every new surface animates, with a Reduce Motion form.

## Build order

Each PR is one branch from the latest `origin/main`, shipped with `/ship and merge` (squash).
A PR in a later wave starts once every PR it depends on has merged.

| PR | Wave | Depends on | What |
|---|---|---|---|
| 1 Quick fixes | 0 | none | Every row of the spec's defects table. [#66](https://github.com/crodris/clicky-watch-along/pull/66) |
| 2 Tether tokens and the carrier panel | A | 1 | `DS.Type`, `DS.Move`, Card and Callout modifiers; `AgentTokenFlight` becomes the shared carrier with the tether line. |
| 3 Theme files | A | 1 | Schema version 2 in the app and the Worker's `checkThemeIdeas`, bundled `.clickytheme` files, Shuffle, migration of every saved default, double-click install. |
| 12 App icon | A | 1 | Icon Composer layers and AccentColor. |
| 4 Callouts and speech | B | 2 | Speech with voice-paced words, status lines, chips, endings, errors on the Callout. |
| 5 Approval card | B | 2 | Read rail, ring, equal buttons, desk-driven states, per-surface seen state and clock, the stored transcript for "You said", instant No. |
| 6 Agent list, Theme Studio, dial | B | 2, 3 | Glide from origin, live lines, result buttons, studio states and sound preview, dial plate. |
| 7 Menu bar | B | 2 | Icon states, the disc dot, the approval disc, peek, right-click menu, and Bring back. |
| 9 Cursor and ring | B | 2 | Glyph, stretch and landing ring, nod, shake, hop, ticks to dots to the speech Callout. |
| 10 Quiz, scenes, edges | B | 2 | Quiz states and summary, scene stylesheet with dark glass labels, lesson stages, error and full-screen states. |
| 11 Instant replay | B | 2 | Record each stop's label, sentence, and camera pose; voice and click controls; cancelation; the Reduce Motion list. |
| 8 Panel, onboarding, keyboard | C | 2, 3, 7 | Home panel, banner slot, theme cards, all-themes grid, six-step setup, keyboard and VoiceOver paths. |

The 6 bigger ideas follow the build order as PRs 13 to 18: Theme Studio designs motion, the loop carries background work, the end-of-video recap, pausing every agent by voice, scrubbing by voice, and sharing themes as files.

## Prototype findings to build in

- Carrier (PR 2): one carrier panel per display, since a flight across two displays was clipped to one; a solid 1 point tether in the origin's color; call `CATransaction.flush()` after adding the flight animation, so a main-thread stall in the same turn cannot eat the flight.
- Approval card (PR 5): track the summary's position with `onGeometryChange`; give the buttons plain `.focusable()` so Tab reaches them with Full Keyboard Access off; "Allow for this task" does not fit at 340 points; a spoken instant No needs the harness to offer `answer_approval` for a waiting request that was not seen at the press.
- Replay (PR 11): a stop restores the recorded camera angle and zoom, not only `focusPart`; `endFocus()` freezes every eased camera value; clamp the camera's pan so the lifted model stays inside the video; put stop numbers on the labels.
- Materials (PR 2 and 4): the Callout rim is 1.5 points on speech and may be 1 point on chips; under Reduce Motion the failure shake does nothing, so the red color and the cross badge carry failure.

## Rules for every PR agent

- Read `AGENTS.md` first; its conventions are binding, and every PR updates it for what it changes.
- Never run `xcodebuild`, since it resets Chris's privacy permissions.
  Build the Debug app only with `.claude/skills/verify-clicky/verify-clicky.sh build`, inside the app check lock below.
- Run `tools/swift-check.sh`, and `cd worker && pnpm test && pnpm run typecheck` when the Worker changes, before every push.
- Write one runnable check per logic change, and break each new guard with `~/.claude-config/mutate.sh` to confirm a test fails.
- Check every view change rendered at 2x (with `ImageRenderer` or the app) before shipping: text stays inside its background, and icon tiles match their icon's shape.
- Upload PR images to a `pr-assets/<topic>` branch, cropped to Clicky's own windows.
- Ship with `/ship and merge`; PR bodies go through the `rewrite` skill, as the global rules require.
- Rebase on `origin/main` right before opening the PR and again before merging, since every PR edits `AGENTS.md`.
- Do not ask Chris anything.
  Make the reversible choice, write it in the PR body's Tradeoffs, and keep going.
  Stop only for something destructive or outside this repository.

## App check lock

Only one Clicky and one Worker on port 8787 can run at a time on this Mac, and other sessions use them too.

1. Take the lock with `.claude/skills/verify-clicky/verify-clicky.sh lock-take <your branch name>`.
   It names the owner in its error while another agent holds the lock: wait and retry every 60 seconds.
2. Run `pgrep -fl "Clicky.app/Contents/MacOS/Clicky"`.
   If any Clicky is running, run `lock-release <your branch name>`, wait 5 minutes, and start again.
3. Build with `verify-clicky.sh build`.
4. If Chris's Worker holds port 8787 (tmux session `clicky-worker-8787`, serving the main checkout's `worker/`), stop it with `tmux send-keys -t clicky-worker-8787 C-c` and wait for the port to free.
5. Run `verify-clicky.sh worker-up 8787`, then `app-launch`, and take your evidence.
6. Run `verify-clicky.sh cleanup`.
7. Restart Chris's Worker in its tmux session with exactly:
   `tmux send-keys -t clicky-worker-8787 'WRANGLER_SEND_METRICS=false pnpm wrangler dev --port 8787 --ip 127.0.0.1 --var LIVE_SCENE_MODEL:sonnet 2>&1 | tee -a ~/Library/Logs/clicky-worker-8787.log' Enter`
   Then confirm `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8787/judge-answer -H 'Content-Type: application/json' -d '{}'` prints 400, once at once and again a minute later.
8. Release the lock with `verify-clicky.sh lock-release <your branch name>`.

Hold the lock for at most 20 minutes.
Never remove `/tmp/clicky-app-check.lock` by hand: `lock-release` refuses a lock that another owner holds and names that owner, and a lock you did not take is another agent's running check.
Never change a system setting such as Reduce Motion; check Reduce Motion paths with renders and tests.

## Status

| PR | Status |
|---|---|
| 1 Quick fixes | Merged: [#66](https://github.com/crodris/clicky-watch-along/pull/66) |
| 2 Tokens and carrier | Merged: [#72](https://github.com/crodris/clicky-watch-along/pull/72) |
| 3 Theme files | Merged: [#74](https://github.com/crodris/clicky-watch-along/pull/74) |
| 12 App icon | Merged: [#73](https://github.com/crodris/clicky-watch-along/pull/73). Dark, tinted, and clear modes still need the layers imported into Icon Composer by hand. |
| 4 Callouts and speech | Merged: [#81](https://github.com/crodris/clicky-watch-along/pull/81) |
| 6 Agent list, Theme Studio, dial | Merged: [#87](https://github.com/crodris/clicky-watch-along/pull/87) |
| 7 Menu bar | Merged: [#86](https://github.com/crodris/clicky-watch-along/pull/86) |
| 5 Approval card | Merged: [#84](https://github.com/crodris/clicky-watch-along/pull/84) |
| 9 Cursor and ring | Merged: [#83](https://github.com/crodris/clicky-watch-along/pull/83) |
| 10 Quiz, scenes, edges | Merged: [#85](https://github.com/crodris/clicky-watch-along/pull/85). The quiz states and the summary Card are not yet seen in the app, since Chrome's "Allow JavaScript from Apple Events" was off. |
| 11 Instant replay | Open: [#88](https://github.com/crodris/clicky-watch-along/pull/88) |
| 8 Panel, onboarding, keyboard | Merged: [#95](https://github.com/crodris/clicky-watch-along/pull/95). The approval banner and the quiz line are not yet seen live |
| 13 Theme Studio designs motion | Merged: [#92](https://github.com/crodris/clicky-watch-along/pull/92). The Debug app check and the motion recording are still owed, since Xcode would not load the project |
| 14 The loop carries background work | Open: [#97](https://github.com/crodris/clicky-watch-along/pull/97) |
| 15 End-of-video recap | Building |
| 16 Pause every agent by voice | Open: [#94](https://github.com/crodris/clicky-watch-along/pull/94). CI and review pass, and the Debug app check waits for Xcode to load the project |
| 17 Scrub by voice | Starts when PR 11 merges |
| 18 Share themes as files | Building |
| 19 Tether polish | After the build order: what earlier PRs left open that no later PR owns |

Deferred from PR 1, to fold into later PRs: the Chrome control row hides after onboarding (PR 8), a hover that shows only after the next mouse move on a still pointer (PR 8), the dimmed No button's low contrast (PR 5), a pop-out label's leader line that can point off screen after a resize (PR 10), and the menu bar icon not found beside the notch (PR 7).

Left open by PR 2, folded into PR 7: the serve has no still ring under Reduce Motion, the tether fades for about 200 ms after a disc covers its slot, and the flush is unchecked through a real Apple Event stall. PR 6 writes the first Glide caller.

Deferred from PR 3: the "Add theme?" card shown before an install (done in PR 6), and a parent-folder race during install on a hostile network volume, graded informational (PR 18).

Left open by PR 4: a push-to-talk press during a narration leaves the bubble with a rise instead of shrinking it into the cursor (PR 11).
PR 19 takes the rest, plus PR 7's leftovers: Bring back's drop to the cursor can cross the video, no unit test pins the tether cut when a disc slides, the right-click menu's quiz check, or the press-handler order, and the app icon's cursor points down and right while the app's cursor points up and left. PR 4's leftovers in PR 19: stacked chips (a new chip pushes the old one up, which needs a second panel), the speech underline at exactly 2 points, and the `start_background_task` description that still says "a chip under the cursor", with its three fixtures and recorded evals.

Folded into PR 8 from PR 7: keyboard focus on the agent discs, and the status badge on a light menu bar.

Left open by PR 6, for PR 19: the disc right-click menu has no "Try again" item, `AgentTriangleView` is now unused, and a click in the agent list's shadow margin hits faint shadow pixels. PR 8 makes the panel's theme cards match the studio tiles.

Left open by PR 5, for PR 19: the approval card should glide back into its agent disc when answered, and the disc's "!" should turn into a check.
Left open by PR 9, for PR 19: a ring dot crosses about 3 points into a status line's Callout at the top of its orbit, the shake, hop, and Reduce Motion tints are checked only on rendered frames, and the failure flag `isAFailure` defaults to false, so make it required once the parallel PRs have merged.
Left open by PR 10: the panel header's quiz progress line (PR 8), and for PR 19, Escape during the summary Card's 0.42 second glide-in shows the whole Card for 0.05 seconds (needs a carrier option), a video pause stays held when a scene build is cancelled on the quiz tab and a jump back to a question then fails, and an experiment built on the Sonnet scene model took 63 seconds, past the app's 60 second wait. The flaky test PR takes the two timing tests that failed under load.
Left open by PR 8, for PR 19: a double flight when the agent list is open under a disc and that agent's chip is picked in the panel, the spec's red menu bar badge for the permission-off and offline banners, a full-name pill wider than its card for a long theme name, and a live look at the approval banner and the quiz line.
Left open by PR 11, for PR 19: under PR 13's slowest theme a long replay flight leaves about 0.72 seconds of dwell at a stop instead of 1.0.
