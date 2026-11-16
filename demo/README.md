# Clicky demo video

A Remotion edit of real Clicky recordings, with captions, punch-ins that follow the blue cursor, and blur dissolves between features.
The recordings, cursor tracks, and renders are gitignored, so record them first.
The scripts assume a MacBook with its built-in Retina screen as the main display, Chrome, the Debug app with its permissions granted, and the local Worker.
The study guide and task agent shots also need `NOTION_API_KEY` and `CLICKY_APP_SECRET` in `worker/.dev.vars`.
The mouse positions in the commands below fit that screen, so another machine needs its own.

## Record

Run these from the main checkout, whose Debug build holds the Accessibility grant, with the Worker running on port 8787.
The recorder brings a new Chrome window to the front of the MacBook's built-in Retina screen and records its 16:9 area at 3420x1924, so the edit's 3x zooms on Clicky's text stay sharp.
Leave the keyboard and trackpad alone while a shot records, about 2 minutes each.
A YouTube video plays muted with its captions hidden, so the footage carries only Clicky's voice.
The recording leaves out the macOS pointer, since Clicky's blue cursor already shows where the mouse is.
The recorder puts YouTube's saved volume setting back when the shot ends.

```bash
TRAILING_SECONDS=12 demo/scripts/record-shot.sh volcano "skip to where they talk about the crater|pop this out|turn it to the left|zoom in on the crater|animate this" "https://www.youtube.com/watch?v=p1eE93vybrc" 58 1110 680
TRAILING_SECONDS=8 demo/scripts/record-shot.sh ejiri "pop this out|animate this" "https://commons.wikimedia.org/wiki/File:%E5%86%A8%E5%B6%BD%E4%B8%89%E5%8D%81%E5%85%AD%E6%99%AF_%E9%A7%BF%E5%B7%9E%E6%B1%9F%E5%B0%BB-Ejiri_in_Suruga_Province_(Sunsh%C5%AB_Ejiri),_from_the_series_Thirty-six_Views_of_Mount_Fuji_(Fugaku_sanj%C5%ABrokkei)_MET_DP140977.jpg" "" 1110 570
```

The quiz clip uses 2 more shots. The quiz answers its own question through the `{answer}` token, and the facial nerve video's captions sometimes need the Debug captions file below.

```bash
TRAILING_SECONDS=6 demo/scripts/record-shot.sh nerve-quiz "watch this video with me and quiz me|?is it the {answer}|stop the quiz" "https://www.youtube.com/watch?v=heOiSg21Lx8" 35 1110 680
TRAILING_SECONDS=6 demo/scripts/record-shot.sh earth "pop this out" "https://commons.wikimedia.org/wiki/File:Rotating_earth_(large).gif" "" 1110 570
```

The study guide clip and the quiz miss clip use 1 shot each, with the Worker's `NOTION_API_KEY` set.
In the study guide shot, "pop this out" runs while the guide is written, so the guide finishes during the pop-out's tour.
Its `&` step waits for the guide to finish before asking to open it.
Start the driver just before that shot, so it glides the mouse right after the request, opens the agent list with shift + option while the pop-out builds, and once the page opens, scrolls to the key terms and clicks the timestamp of the term about the stator vanes or the compressor.
The click is a real mouse event from `scripts/recorder/click-mouse.swift`, which needs the Accessibility permission for the app that runs the script.
The quiz miss shot plays Science ABC's "How Submarines Work", a 2D illustration, which lifts out as a puffed-up drawing.
It writes the guide first, which the edit leaves out, and answers the buoyancy question right.
It then answers the diving planes question wrong and then right, and the ballast tanks question right on the first try.
After each right name, Clicky asks what the part does, and the "I'm not sure" step lets the video play on.
A first-try answer stays off the guide's review list, so the guide opens with only the miss at the top.
Start the driver before it too, so once the page opens it scrolls to the key terms and clicks the same timestamp.
That miss spawns a "Study guide update" helper, so the guide opens with the question under "Review these first".
Each run writes a new private page into the Notion account, so trash the test pages afterwards.
The app saves one guide per YouTube video and never writes a second, so `record-shot.sh` deletes the saved guide for the shot's video before it launches the app.

```bash
demo/scripts/drive-study-guide-shot.sh demo/public/study-guide.events.txt.raw &
TRAILING_SECONDS=16 demo/scripts/record-shot.sh study-guide "make me a Notion study guide for this video|pop this out|put it back|&open my study guide" "https://www.youtube.com/watch?v=L24Wf0VlTE0" 60 1110 680
demo/scripts/drive-study-guide-shot.sh demo/public/quiz-miss.events.txt.raw &
TRAILING_SECONDS=18 demo/scripts/record-shot.sh quiz-miss "make me a Notion study guide for this video|&watch this video with me and quiz me|?is it {answer}|I'm not sure what it does|?is it the propeller|?is it the {answer}|I'm not sure what they do|?is it the {answer}|stop the quiz|&open my study guide" "https://www.youtube.com/watch?v=-AiUnUbL5hA" 5 1110 680
```

The parallel agents clip uses 1 shot of SpaceX's own 93 second clip of Starship Flight 15's tower catch, on x.com, with Chrome logged in to X.
The reel credits it on its first shot (`sourceCredit`) and on its end card (`endCard.credit`).
It hands a general task agent a research question with a Notion page, then asks for a 3D model, so the teal and violet sub-agents run at once, and needs the Worker's `NOTION_API_KEY`.
Its Worker runs without `LIVE_SCENE_MODEL`, so GPT builds the model at medium effort, since a Sonnet model came out plain in two takes.
The driver's second argument starts the clip at 50 seconds, during the descent, so the catch plays while the task agent searches.
The `+15` step waits until the wide shot of the ship in the tower arms, about 74 seconds into the clip, before asking for the model.
The driver hides X's side columns, replies, reply box, and floating buttons, keeps the clip muted, and pauses it 0.6 seconds before its end, so the model rises out of the last frame.
It also opens the agent list while both sub-agents run, glides the mouse so both wingmen trail the blue one, and brings the task agent's Notion page forward while Clicky speaks its answer.
Clicky has no captions to read on x.com, so the task agent works from the post, a look at the video, and web search.
The hiding runs about 3 seconds into the recording, so the edit starts after it, since the page shows the account's name and avatar until then.

```bash
demo/scripts/drive-agents-shot.sh demo/public/agents.events.txt.raw 50 &
TRAILING_SECONDS=6 demo/scripts/record-shot.sh agents "find out how this catch compares to the first booster catch, and make me a Notion page about it|+15 build me a 3D model of this Starship|&put it back|what did you find" "https://x.com/SpaceX/status/2121715216597827756" "" 1110 680
```

An experiment's control panel sits at the bottom of the MacBook screen, below the default recorded area, so a "let me try it" shot stretches the Chrome window to the bottom and records the lower 16:9 area instead.
That area starts below Chrome's toolbar, so the experiment clip's shots use `pageOnlyCrop`, and the camera cuts nothing off the page.
The rehearsal sets the first run by voice.
`scripts/drive-trebuchet-shot.sh` then sets the second run and the challenge with the real mouse, dragging the sliders and clicking Run, since the clip shows both ways to change the experiment.
It finds the sliders in a screenshot with `scripts/experiment-panel.py`, moves the mouse with `scripts/mouse/mouse.swift`, and reads the challenge target through the voice tool endpoint, since the target is new in every build: one overshoot, then corrections until a run lands in the ring.
The terminal that runs it needs the Accessibility permission to move the mouse.
The driver runs in the background and stops on its own once the challenge ends, or when a step fails.
When a take fails before the challenge, stop it with `kill %1` before the next take, since it waits up to 400 seconds for each log line.
The montage takes speak their runs as rehearsal steps instead, with a pause between runs so Clicky finishes reading each result.

```bash
take() { DEMO_WINDOW_BOUNDS="0, 38, 1710, 1107" RECORDING_SOURCE_RECT="0,145,1710,962" TRAILING_SECONDS=${4:-15} demo/scripts/record-shot.sh "$1" "$3" "https://www.youtube.com/watch?v=$2" "$5"; }
demo/scripts/drive-trebuchet-shot.sh demo/public/trebuchet.events.txt.raw &
take trebuchet jTBDc19eW2o "+3 let me try it|&I think the bigger one will throw it farther|set the angle to 45 degrees and run it" 130 384
take montage-circuit HsLLq6Rm5tU "+3 let me try it|&I think more resistance means less current|set the resistance to 12 ohms and run it|+8 make the resistance 1 ohm and run it" 15 268
take montage-refraction zarxpu43-ls "+3 let me try it|&I think the light bends more when it comes in at a steeper angle|set the light angle to 20 degrees and run it|+8 make the light angle 70 degrees and run it" 15 178
take montage-buoyancy nMlXU97E-uQ "+3 let me try it|&I think a denser ball sinks deeper|run it|+8 make the ball much denser and run it" 15 148
take montage-molecule FJ0gy48IIzU "+3 let me try it|&I think more lone pairs will squeeze the bonds closer|set the bonded atoms to 2 and the lone pairs to 0 and run it|+10 set the lone pairs to 2 and run it" 15 294
```

Each shot writes `<shot>.mov` and `<shot>.events.txt` into `demo/public`.
The script exits with an error, and keeps no events file, when the rehearsal never logs that it finished.
The events file stamps each app log line with seconds since the recording started.

## Track the cursor

```bash
cd demo
pnpm install
pnpm track public/volcano.mov public/volcano.cursor.json
pnpm track public/ejiri.mov public/ejiri.cursor.json
pnpm track public/study-guide.mov public/study-guide.cursor.json
pnpm track public/quiz-miss.mov public/quiz-miss.cursor.json
pnpm track public/agents.mov public/agents.cursor.json
pnpm track public/trebuchet.mov public/trebuchet.cursor.json
```

## Music

Each clip has its own bed.
The first two come from Mixkit under the Mixkit Stock Music Free License (https://mixkit.co/license/#musicFree):

- The demo uses "Happy Times" by Alejandro Magaña (https://mixkit.co/free-stock-music/happy-times/), saved as `demo/public/music/happy-times.mp3`.
- The quiz clip uses "It's Love" by Michael Ramir C. (https://mixkit.co/free-stock-music/its-love/), saved as `demo/public/music/its-love.mp3`.

The study guide clip and the combined clip use "Feel Good - It Feels So Good" (96 second version) by Easy_Eva (https://pixabay.com/music/small-emotions-feel-good-it-feels-so-good-96sec-605780/), saved as `demo/public/music/it-feels-so-good.mp3`, under the Pixabay Content License (https://pixabay.com/service/license-summary/).
The quiz miss clip uses "Pop - Friends Like Us" (122 second version) by Easy_Eva (https://pixabay.com/music/pop-pop-friends-like-us-122sec-564062/), saved as `demo/public/music/friends-like-us.mp3`, under the same license.
Neither is registered with YouTube Content ID, so a YouTube upload gets no claim, and neither is AI-generated.
The parallel agents clip uses the same "Feel Good - It Feels So Good" track as the study guide clip.
The experiment clip uses "Upbeat Lo-Fi Instrumental with Electric Guitar" by NickPanek (https://pixabay.com/music/beats-upbeat-lo-fi-instrumental-with-electric-guitar-251405/), saved as `demo/public/music/upbeat-lo-fi-electric-guitar.mp3`, under the Pixabay Content License, which needs no credit.
Pixabay blocks scripted downloads, so download it from that page by hand.
The track is 2:02 and the clip about 2:38, so `pnpm music-experiment` joins two copies with a 4 second crossfade.
The crossfade covers the last 4 seconds of the first copy's music, from 1:56.3 to 2:00.3, so the seam falls on the dissolve into the title card.
It writes the joined bed as `upbeat-lo-fi-electric-guitar-twice.wav`, so the mix encodes the music only once, and `pnpm mix-experiment` rebuilds it every time.

Both licenses allow commercial use in social media videos with no credit, but not passing a file on by itself, so the tracks stay out of git.
Download all five before rendering.

`scripts/mix-music.ts` runs after the Remotion render.
It gives the voice a high-pass at 80 Hz, a small lift at 3 kHz, and light compression.
It fades the music in over 1 second and out over the last 3, under the end card, keeps it 9 dB under the narration in the pauses, and ducks it about 11 dB more while Clicky speaks, with a sidechain compressor keyed on the voice.
It then normalizes the mix to -14 LUFS integrated, with true peaks under -1 dBTP.
Its optional arguments are where the bed starts in the track, which skips a quiet intro, and a voice gain in dB.
The quiz clip passes `1.5 -5`, so Clicky sits about 15 dB over the music while speaking, against about 20 dB in the demo.

## Edit and render

`src/timeline.ts` holds every shot, caption, and camera move, timed from the events files.
`segments` is the demo, `quizClipSegments` is the follow-up clip (the facial nerve quiz and the spinning globe), `studyGuideClipSegments` is the Notion study guide clip, `parallelAgentsClipSegments` is the parallel sub-agents clip over the Starship catch, posted first, `quizMissClipSegments` is the quiz miss clip, which follows it and leaves the sub-agent mechanics to it, and `experimentClipSegments` is the "let me try it" clip: the trebuchet experiment end to end, a title card, and a montage of four more experiments, each after a short muted glimpse of its source video.
`src/theme.ts` gives each clip its own look: the demo and the quiz clip use Inter on dark pills with yellow accent words, the study guide and quiz miss clips use Fraunces on a paper card with an amber highlighter, and the parallel agents clip uses Space Grotesk on a navy card, with each sub-agent's captions in its wingman's color, teal for the task agent and violet for the 3D model.
The experiment clip uses the demo's dark pills with the experiment wingman's lime on key words.
A new recording has new times, so update `src/timeline.ts` after recording again.

```bash
pnpm studio
export REMOTION_BROWSER_EXECUTABLE="$(ls -td ~/Library/Caches/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-mac-arm64/chrome-headless-shell | head -1)"
pnpm render
pnpm render-quiz
pnpm render-study-guide
pnpm render-quiz-miss
pnpm render-parallel-agents
pnpm render-experiment
```

`pnpm render` writes the voice-only `out/clicky-demo-voice.mp4`, then the mix writes `out/clicky-demo.mp4`.
`pnpm render-quiz` does the same for `out/clicky-quiz.mp4`, `pnpm render-study-guide` for `out/clicky-study-guide.mp4`, `pnpm render-quiz-miss` for `out/clicky-quiz-miss.mp4`, `pnpm render-parallel-agents` for `out/clicky-parallel-agents.mp4`, and `pnpm render-experiment` for `out/clicky-experiment.mp4`.
`pnpm mix`, `pnpm mix-quiz`, `pnpm mix-study-guide`, `pnpm mix-quiz-miss`, `pnpm mix-parallel-agents`, and `pnpm mix-experiment` run only the mix, which is enough after changing the music or its levels.
Set `REMOTION_BROWSER_EXECUTABLE` when Remotion's own headless shell hangs at "Waiting for root component to load".

## Quiz rehearsal

A rehearsal answers a quiz question with `?is it the {answer}`, which becomes the open question's answer label in a Debug build.
When YouTube rate-limits a video's captions with HTTP 429, save its captions as `<video id>.json3` and point the Debug app at them, as `.claude/skills/verify-clicky/features/video-quiz.md` describes.
