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
| 9 Cursor and ring | B | 2 | Glyph, stretch and landing ring, nod, shake, hop, ticks to dots to bubble. |
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

1. Take the lock with `/bin/mkdir /tmp/clicky-app-check.lock` (plain `mkdir` is aliased to `mkdir -p` and never fails), and write your branch name into `/tmp/clicky-app-check.lock/owner`.
   If it fails, another agent holds it: wait and retry every 60 seconds.
2. Run `pgrep -fl "Clicky.app/Contents/MacOS/Clicky"`.
   If any Clicky is running, release the lock, wait 5 minutes, and start again.
3. Build with `verify-clicky.sh build`.
4. If Chris's Worker holds port 8787 (tmux session `clicky-worker-8787`, serving the main checkout's `worker/`), stop it with `tmux send-keys -t clicky-worker-8787 C-c` and wait for the port to free.
5. Run `verify-clicky.sh worker-up 8787`, then `app-launch`, and take your evidence.
6. Run `verify-clicky.sh cleanup`.
7. Restart Chris's Worker in its tmux session with exactly:
   `tmux send-keys -t clicky-worker-8787 'WRANGLER_SEND_METRICS=false pnpm wrangler dev --port 8787 --ip 127.0.0.1 --var LIVE_SCENE_MODEL:sonnet 2>&1 | tee -a ~/Library/Logs/clicky-worker-8787.log' Enter`
   Then confirm `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8787/judge-answer -H 'Content-Type: application/json' -d '{}'` prints 400, once at once and again a minute later.
8. Release the lock with `rm -r /tmp/clicky-app-check.lock`.

Hold the lock for at most 20 minutes.
Never change a system setting such as Reduce Motion; check Reduce Motion paths with renders and tests.

## Status

| PR | Status |
|---|---|
| 1 Quick fixes | Open, shipping: [#66](https://github.com/crodris/clicky-watch-along/pull/66) |
| 2, 3, 12 | Starting in parallel |
| 4, 5, 6, 7, 9, 10, 11 | Waiting for PR 2 |
| 8 | Waiting for PRs 2, 3, 7 |
| 13 to 18 | After the build order |
