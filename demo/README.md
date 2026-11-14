# Clicky demo video

A Remotion edit of real Clicky recordings, with captions, punch-ins that follow the blue cursor, and blur dissolves between features.
The recordings, cursor tracks, and renders are gitignored, so record them first.

## Record

Run these from the main checkout, whose Debug build holds the Accessibility grant, with the Worker running on port 8787.
The recorder brings a new Chrome window to the front of the MacBook's built-in Retina screen and records its 16:9 area at 3420x1924, so the edit's 3x zooms on Clicky's text stay sharp.
Leave the keyboard and trackpad alone while a shot records, about 2 minutes each.
A YouTube video plays muted with its captions hidden, so the footage carries only Clicky's voice.
The recorder puts YouTube's saved volume setting back when the shot ends.

```bash
TRAILING_SECONDS=12 demo/scripts/record-shot.sh volcano "skip to where they talk about the crater|pop this out|turn it to the left|zoom in on the crater|animate this" "https://www.youtube.com/watch?v=p1eE93vybrc" 58 1110 680
TRAILING_SECONDS=8 demo/scripts/record-shot.sh ejiri "pop this out|animate this" "https://commons.wikimedia.org/wiki/File:%E5%86%A8%E5%B6%BD%E4%B8%89%E5%8D%81%E5%85%AD%E6%99%AF_%E9%A7%BF%E5%B7%9E%E6%B1%9F%E5%B0%BB-Ejiri_in_Suruga_Province_(Sunsh%C5%AB_Ejiri),_from_the_series_Thirty-six_Views_of_Mount_Fuji_(Fugaku_sanj%C5%ABrokkei)_MET_DP140977.jpg" "" 1110 570
```

Each shot writes `<shot>.mov` and `<shot>.events.txt` into `demo/public`.
The events file stamps each app log line with seconds since the recording started.

## Track the cursor

```bash
cd demo
pnpm install
pnpm track public/volcano.mov public/volcano.cursor.json
pnpm track public/ejiri.mov public/ejiri.cursor.json
```

## Music

Each clip has its own bed, both from Mixkit under the Mixkit Stock Music Free License (https://mixkit.co/license/#musicFree):

- The demo uses "Happy Times" by Alejandro Magaña (https://mixkit.co/free-stock-music/happy-times/), saved as `demo/public/music/happy-times.mp3`.
- The quiz clip uses "It's Love" by Michael Ramir C. (https://mixkit.co/free-stock-music/its-love/), saved as `demo/public/music/its-love.mp3`.

That license allows commercial use in social media videos with no credit, but not passing a file on by itself, so the tracks stay out of git.
Download both before rendering.

`scripts/mix-music.ts` runs after the Remotion render.
It gives the voice a high-pass at 80 Hz, a small lift at 3 kHz, and light compression.
It fades the music in over 1 second and out over the last 3, under the end card, keeps it 9 dB under the narration in the pauses, and ducks it about 11 dB more while Clicky speaks, with a sidechain compressor keyed on the voice.
It then normalizes the mix to -14 LUFS integrated, with true peaks under -1 dBTP.
Its optional arguments are where the bed starts in the track, which skips a quiet intro, and a voice gain in dB.
The quiz clip passes `1.5 -5`, so Clicky sits about 15 dB over the music while speaking, against about 20 dB in the demo.

## Edit and render

`src/timeline.ts` holds every shot, caption, and camera move, timed from the events files.
`segments` is the demo, and `quizClipSegments` is the follow-up clip: the facial nerve quiz and the spinning globe.
A new recording has new times, so update `src/timeline.ts` after recording again.

```bash
pnpm studio
export REMOTION_BROWSER_EXECUTABLE=~/Library/Caches/ms-playwright/chromium_headless_shell-1248/chrome-headless-shell-mac-arm64/chrome-headless-shell
pnpm render
pnpm render-quiz
```

`pnpm render` writes the voice-only `out/clicky-demo-voice.mp4`, then the mix writes `out/clicky-demo.mp4`.
`pnpm render-quiz` does the same for `out/clicky-quiz.mp4`.
`pnpm mix` and `pnpm mix-quiz` run only the mix, which is enough after changing the music or its levels.
Set `REMOTION_BROWSER_EXECUTABLE` when Remotion's own headless shell hangs at "Waiting for root component to load".

## Quiz rehearsal

A rehearsal answers a quiz question with `?is it the {answer}`, which becomes the open question's answer label in a Debug build.
When YouTube rate-limits a video's captions with HTTP 429, save its captions as `<video id>.json3` and point the Debug app at them, as `.claude/skills/verify-clicky/features/video-quiz.md` describes.
