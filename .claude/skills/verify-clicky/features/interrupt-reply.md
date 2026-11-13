# Interrupting a reply

While Clicky is thinking about or speaking an answer, Escape or a quick tap of ctrl+option stops it.
The answer's request is cancelled, its speech stops within a fraction of a second, and nothing new is asked, since a tap with no words sends no transcript.
With a 3D scene or pop-out on screen, Escape keeps its scene behavior instead, and a tap stops the speech but leaves the scene up until the learner says "put it back" (see [Live scene](./live-scene.md) and [Frame pop-out](./frame-popout.md)).

## Sub-features

- `interrupt-escape` stops a plain answer on Escape and logs `Escape: stopped the reply`.
- `interrupt-tap` stops any answer or narration on a push-to-talk press, and a release with no words asks nothing.

## How to get to it (user POV)

- Ask Clicky something with push-to-talk, then press Escape while it talks.
- Ask Clicky something, then tap ctrl+option without saying anything.

## Driving it with verify-clicky.sh

Preconditions:

- The app preconditions in [Video quiz](./video-quiz.md) apply: a Worker this script started on 8787, a Debug build that supports `--live-scene-rehearsal`, and no Clicky already running.
- Chrome's front tab shows a page worth explaining, such as a Wikipedia article with a diagram, and the question asks how something works, so the answer runs long enough to interrupt.

- **Escape.** Run `$V app-launch "how does air move through this engine from front to back?"`.
  Once `🔊 ElevenLabs TTS: playing` appears in `$RUN/app.log`, run `$V key escape`.
  The log shows `Escape: stopped the reply` within about half a second of the key.
  `Live scene rehearsal: done` follows within about 2 seconds, because the rehearsal waits 1.5 seconds after a step finishes.
- **Push-to-talk tap.** Run `$V app-quit`, launch the same question again, and once speech starts run `$V key push-to-talk-tap`.
  When the answer has not printed `Live scene rehearsal: finished` yet, that line follows within about half a second of the key, and `done` within about 2 seconds.
  No `🗣️ Companion received transcript` line appears.
- **Control.** The same question with no key runs about 30 seconds of speech on Sonnet 5.5 before `Live scene rehearsal: done`.
  Measured 2026-11-13: Escape stopped speech 0.26 s after the key, the tap 0.05 s after it, and the uninterrupted answer spoke for 34 s.

## Gotchas

- `Live scene rehearsal: finished` can print before speech starts, because the voice state goes idle when the cursor flies to its target while the speech still loads. Time the interruption from `🔊 ElevenLabs TTS: playing`, and judge the stop by `Live scene rehearsal: done`.
- The app speaks out loud and the key events go to whatever app is in front, so Chrome should be in front and nobody should be typing.
- System Events needs the Accessibility permission for the app that runs `osascript`. Without it, `key` fails with an error that names System Events.
