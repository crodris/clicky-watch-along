---
name: verify-clicky
description: Verify Clicky end to end by driving its Cloudflare Worker with curl and its Debug macOS app with the --live-scene-rehearsal launch flag, capturing responses, token usage lines, app logs, and screenshots. Use before reporting a change to Clicky's behavior as done, or when asked to verify, prove, or e2e test a Clicky feature.
---

# verify-clicky

Clicky has two surfaces.
The Worker in `worker/` is an HTTP proxy, and every model route can be driven with curl.
The macOS menu bar app is what the learner touches.
An agent drives it by launching the Debug build with `--live-scene-rehearsal`, which feeds transcripts to the same pipeline push-to-talk feeds.

All commands below run from the checkout root through one helper:

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
$V            # prints usage
```

## Hard rules

- Never run `xcodebuild` on this Mac. It resets the app's TCC permissions. Chris builds the Debug app in Xcode (Cmd+B). CI builds it on a GitHub runner, which is fine.
- Never stop, quit, or drive a Worker or a Clicky instance this script did not start. Doctor names the owner of each.
- Never run `wrangler deploy`. Deploying is Chris's call.
- A run on the app speaks out loud through ElevenLabs and draws over the screen under the mouse. Expect that, and tell Chris before a long app run.

## Doctor

Run this first, and again whenever anything looks off.
It is read-only.

```bash
$V doctor
```

It reports:

- The checkout, branch, and HEAD.
- Whether `worker/.dev.vars` exists, with its key names. A new worktree has none, so copy it from the main checkout (`cp ../clicky-watch-along/worker/.dev.vars worker/`).
- Ports 8787 and 8789: the listener PID, whether this script started it, which checkout it serves, and whether it answers the free probe. The free probe posts `{}` to `/judge-answer`. This checkout's Zod check answers 400 without any model call.
- The Debug `Clicky.app` in DerivedData, its build time, whether it is older than the last commit under `leanring-buddy/`, and whether the binary contains `--live-scene-rehearsal`.
- Running Clicky PIDs and whether this script launched them.
- Chrome's front tab URL, which the video features read.

A build older than the last app commit may not match HEAD.
A build without `--live-scene-rehearsal` cannot be driven at all.
In both cases ask Chris to press Cmd+B in Xcode, and report the app surface as unverified until he does.

## Launch

Start an evidence folder first.
Every later command writes into the current run.

```bash
$V new-run <short-name>
```

**Worker only.**
Start a Worker from this checkout on port 8789.
It is isolated from whatever runs on 8787, and it logs to `.verify-clicky/runs/<run>/worker-8789.log`.
Ready means the free probe answered, which the command waits for (up to 60 seconds).

```bash
$V worker-up                                        # GPT builds live scenes (about $0.23 each)
$V worker-up 8789 -- --var LIVE_SCENE_MODEL:sonnet  # Sonnet builds them (about $0.04 each)
```

**App.**
The app calls `http://127.0.0.1:8787` in every build (`CompanionManager.swift`), so only a Worker on 8787 serves it.
If doctor says port 8787 is free, start one there so its usage lines are captured:

```bash
$V worker-up 8787 -- --var LIVE_SCENE_MODEL:sonnet
```

If 8787 is taken by a Worker this script did not start, do not stop it.
The app run still works when that Worker answers the free probe and serves a checkout with the Worker code you need.
That run captures no usage lines, and the report must say so.

Then launch the app with rehearsal steps.
It refuses when any Clicky is already running, because two instances fight over the event tap and the overlay.
It also quits the app and stops when the app's `Clicky start` log line shows `screen: false`.
macOS keys privacy grants to the bundle ID that doctor prints, so a build with a new ID has none.
Only Chris can grant them, in System Settings > Privacy & Security > Screen & System Audio Recording, and Accessibility for the video features.

```bash
$V app-launch "show me the inside of a heart"
$V app-wait 240
```

Steps are separated by `|`.
The app waits 3 seconds, then sends each step as if it were spoken, and waits for the tour, the reply, and the speech to finish before the next step.
A step that starts with `?` first waits up to 4 minutes for a quiz question to be asked and spoken, then answers it.
A step that starts with `~` lets the next step interrupt it after 6 seconds.
`app-wait` returns when the app logs `Live scene rehearsal: done`, prints the relevant log lines, and saves the usage lines the 8787 Worker logged during the run.

## Drive

Each feature in [`features/README.md`](features/README.md) has the exact steps.
The two drive primitives are:

```bash
$V post <route> <body.json> [port]   # default port 8789
$V shot <name>                       # one PNG per display
```

`post` saves the response body to the run, prints it, then prints one line per model attempt with input, cache read, output, and thinking tokens, and saves those lines to `<response>.usage.log`.
Request bodies for routes that need no image are in `fixtures/`.

The app log is `.verify-clicky/runs/<run>/app.log`.
Swift `print()` output reaches it line by line because `app-launch` sets `NSUnbufferedIO=YES`.
Unified logging does not capture `print()`, so `log stream` shows nothing useful.

## What this skill cannot drive

- Push-to-talk itself. It needs the microphone and a ctrl+option press through the CGEvent tap. Rehearsal steps enter the pipeline right after transcription, so the transcription providers (AssemblyAI, OpenAI, Apple Speech) stay unverified.
- The menu bar panel, the model picker, and the permission prompts.
- Mouse drag orbit, trackpad pinch, and Escape on a finished scene.
- Streamed `/chat`, which logs no usage line. Prove it through the app's spoken reply and the log line `🗣️ Companion received transcript`.

Report each of these as unverified when a change touches it.
Do not report it as verified through a different path.

## Evidence

Proof goes in `.verify-clicky/runs/<timestamp>-<name>/` in the checkout, which git ignores.
A run folder holds what its commands wrote: `worker-<port>.log`, `response-*.json` with matching `*.usage.log`, `rehearsal-steps.txt`, `app.log`, `app.err`, `app.usage.log`, and `<name>-display<N>.png`.

Proof standards:

- Drive the real user path. For the app, that is a rehearsal step, never a call into internal state.
- Capture the action and the resulting state: a screenshot after the scene is up, and the log lines that name the phase it reached.
- A usage line is the proof that the real model call ran. Count them: two lines for one request mean one retry, which costs money and goes in the report.
- Check each route's cost ceiling in its feature file. Ceilings are loose on purpose. Model output varies between runs, so never assert exact token counts.
- When a route's reply is checked, say what was checked (the verdict, the moment count) rather than "it worked".

A worktree removal deletes its `.verify-clicky/`.
Copy what the report or PR needs before that.

## Cleanup

```bash
$V cleanup
```

It quits the Clicky instance and stops the Workers this script started, killing each process tree by its recorded PID.
It never kills by process name, and it never deletes `.verify-clicky/runs/`.
Run it after every failed attempt too, so no Worker keeps a port.
