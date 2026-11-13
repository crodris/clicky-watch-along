# Clicky verification map

This directory is the maintained source for verifying Clicky's user-facing behavior.
Read [`../SKILL.md`](../SKILL.md) first, then use the matching feature file as the recipe.
`$V` below means `.claude/skills/verify-clicky/verify-clicky.sh`, run from the checkout root.
`$RUN` means the current run folder, `$(readlink .verify-clicky/current)`.

## Baseline preconditions

- `$V doctor` shows `worker/.dev.vars` present.
- Worker recipes run against a Worker this run started with `$V worker-up` on port 8789.
- App recipes need a Worker this run started on 8787, a Debug build that supports `--live-scene-rehearsal`, and no Clicky already running.
- Prefer `--var LIVE_SCENE_MODEL:sonnet` for any run that builds a live scene, unless the change is to the GPT path.
- Start each recipe with `$V new-run <feature-id>` so its evidence has its own folder.

## Driving conventions

- Worker routes are driven with `$V post <route> <body.json>`.
  Bodies that need no image are in `../fixtures/`.
- Bodies that need an image are built in `$RUN` from a fresh screenshot with the one-line Python shown in the recipe.
  Never commit a screenshot into `fixtures/`.
- App features are driven with rehearsal steps through `$V app-launch "<steps>"` and `$V app-wait`.
  Each step is the sentence a learner would say.
- A finished live scene stays up until the app quits, so `$V shot <name>` after `app-wait` captures it.
  A video quiz pop-out clears before the video resumes, so shoot it while the question is asked.

## Proof and skip reporting

- A Worker proof is the HTTP status, the checked field of the response, and the usage lines.
  There is one usage line per model attempt, and more than one means a retry, which the report names.
- An app proof is the rehearsal log lines that name the phase reached, a screenshot with the result visible, and the app usage lines.
- Cost ceilings are loose limits that catch a dropped effort setting or a broken cache.
  Never assert exact token counts.
- Report a path this skill cannot drive (push-to-talk with speech, drag, pinch, menu bar panel) as unverified.
  Do not report it as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior.
It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with verify-clicky.sh` starts with `Preconditions:` and pairs each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a run.

## Features

- [Spoken-answer judge](./spoken-answer-judge.md) covers grading a quiz answer through `/judge-answer`.
  It is the cheapest full proof.
- [Live scene](./live-scene.md) covers building a 3D scene from a question and screenshot, the explore tour, and the quiz after it.
- [Video quiz](./video-quiz.md) covers planning quiz moments from a YouTube transcript and pausing the video at each one.
- [Frame pop-out](./frame-popout.md) covers lifting the subject of a video frame, or of a page image, out in 3D with part labels.
- [Landmark scan](./landmark.md) covers recognizing a famous place in a video frame and showing Google's 3D scan of it.
- [Interrupting a reply](./interrupt-reply.md) covers stopping Clicky mid-answer with Escape or a push-to-talk tap.
- [Voice commands](./voice-commands.md) covers follow-up commands that change the scene or video on screen through `/voice-command` and the voice tools.
