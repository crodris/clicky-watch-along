# Clicky benchmark

`bench.ts` measures the latency, tokens, and cost of every Worker route the demo uses, and checks each reply for quality on fixed fixtures.
It runs on top of the `verify-clicky` skill, which starts and stops the local Worker and keeps its log.
Results are JSON files in `results/`, named `<label>-<kind>-<commit>.json`.

## Run it

Run every command from the checkout root.
A worker run sends real requests with the Worker's API keys, so estimate its cost first.
At 5 runs per case it costs about $1.60, and the GPT live scene is $1.15 of that.

```bash
V=.claude/skills/verify-clicky/verify-clicky.sh
(cd bench && pnpm install)
$V new-run bench
$V worker-up
node bench/bench.ts worker --label baseline --runs 5
$V cleanup
```

`--only chat-first,tts` limits the run to some cases.
Case IDs are the `id` fields in `benchCases`.

## Compare two commits

Run the two Workers side by side and let the benchmark alternate between them, so drift in upstream latency hits both sides equally.
Each side is `label:port:checkout`.
Each side sends what its own app version sends: the benchmark reads the chat model, effort, system prompt, speech model, and speech format from that checkout's Swift source, and prints them as the side's app profile.
The second checkout is a git worktree at the other commit, with its own `worker/.dev.vars` and its own `verify-clicky.sh worker-up <port>`.

```bash
node bench/bench.ts worker --label compare --runs 5 \
  --side baseline:8790:/path/to/baseline-worktree \
  --side after:8789:"$PWD"
```

## App timings

`node bench/bench.ts app --label baseline --runs 3` launches the Debug app with rehearsal steps and times two paths a learner waits on.
Swift `print()` lines carry no timestamps, so the benchmark watches `app.log` every 25 ms and stamps each line as it appears.

- `app-voice-reply` runs from the transcript reaching the pipeline to `🔊 ElevenLabs TTS: playing`, the first spoken word.
- `app-image-popout` runs from "pop this out" to `Frame pop-out: lifting`, when the pop-out page starts.

It needs a Worker this checkout started on port 8787, Chrome's front tab showing a page with one large image, and nobody using the Mac, because the app speaks and draws over the screen.

## Charts

`report.ts` turns result files into CSV tables for a chart page: `routes.csv` (one row per case and side), `samples.csv` (one row per request), and `app.csv` (app timings).

```bash
node bench/report.ts --out /tmp/clicky-report bench/results/before-worker-*.json bench/results/after-worker-*.json bench/results/*-app-*.json
```

CI runs it on every committed result, so a result file that no longer parses fails the build.

## What each number means

- `totalMs` is request start to the last byte. The app waits for the whole body on every route except streamed `/tts`.
- `firstTokenMs` is request start to the first text token of a streamed `/chat` reply.
- `firstAudioMs` is when the app could start speaking a `/tts` reply: the first buffer of streamed PCM, or the whole body for an MP3, which the older app downloads in full before it plays.
- Tokens come from the Worker's `[/route] usage {...}` log lines, one per model call, so two lines for one request mean one retry.
  Streamed `/chat` logs no usage line, so its tokens come from the stream's `message_start` and `message_delta` events.
- `costUSD` prices each usage line by the model it names. `/tts` is priced per character. A GPT live scene uses the repo's $0.23 estimate.
- `quality` is a per-case check of the reply, such as the pointer landing on a "Download PDF" control or the landmark within 0.003 degrees of the Eiffel Tower.
